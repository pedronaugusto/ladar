//! The instruction-set extensions kernels beyond the target's baseline use,
//! as this CPU has them: a closed list per architecture. A feature the target guarantees is
//! known at compile time and costs nothing (`has` is comptime-true, no check
//! runs); any other is detected on first use and kept: one atomic cell,
//! written by whichever thread asks first (every writer writes the same
//! value). A feature neither guaranteed nor detectable on the target is
//! comptime-false, so a kernel that needs it is never referenced.
//!
//! Detection: CPUID and XGETBV on x86-64 (every OS), `sysctlbyname` on
//! Darwin, the auxiliary vector on Linux, `IsProcessorFeaturePresent` on
//! Windows. Elsewhere only what the target guarantees is used.
//!
//! A feature not listed is added here, with its detection on each OS (or a
//! line saying where only the baseline gives it), never detected by a
//! consumer itself. The kernels stay with their users, each a module built
//! with the feature enabled, since Zig sets CPU features per module.

const std = @import("std");
const builtin = @import("builtin");
const aegis = @import("aegis");

/// One extension or a group the kernels need together. NEON (AArch64) and
/// SSE2 (x86-64) are their architectures' baselines and are not listed.
pub const Feature = enum(u5) {
    /// AArch64 CRC32 instructions (FEAT_CRC32).
    arm_crc,
    /// AArch64 polynomial multiply, PMULL and PMULL2 (FEAT_PMULL).
    arm_pmull,
    /// AArch64 AES instructions (FEAT_AES).
    arm_aes,
    /// AArch64 SHA-256 instructions (FEAT_SHA256).
    arm_sha2,
    /// AArch64 three-way exclusive or, EOR3 (FEAT_SHA3).
    arm_sha3,
    /// AArch64 UDOT (FEAT_DotProd).
    arm_dotprod,
    /// x86 PSHUFB and the other SSSE3 instructions.
    x86_ssse3,
    /// x86 CRC32 (SSE4.2).
    x86_sse42,
    /// x86 PCLMULQDQ with SSE4.1.
    x86_pclmul,
    /// x86 AES-NI.
    x86_aes,
    /// x86 AVX2 with the operating system saving YMM state.
    x86_avx2,
    /// x86 VPCLMULQDQ on 256-bit registers (with AVX2).
    x86_vpclmul,
    /// x86 MULX, ADCX and ADOX (BMI2 and ADX together).
    x86_bmi2_adx,
    /// x86 SHA extensions.
    x86_sha,
};

pub const Set = std.EnumSet(Feature);

/// The features the target guarantees at compile time.
pub const guaranteed: Set = blk: {
    var set: Set = .empty;
    const cpu = builtin.cpu;
    switch (cpu.arch) {
        .aarch64 => {
            if (cpu.has(.aarch64, .crc)) set.insert(.arm_crc);
            // LLVM's `aes` holds both AES and PMULL (FEAT_AES and FEAT_PMULL).
            if (cpu.has(.aarch64, .aes)) set.insert(.arm_pmull);
            if (cpu.has(.aarch64, .aes)) set.insert(.arm_aes);
            if (cpu.has(.aarch64, .sha2)) set.insert(.arm_sha2);
            if (cpu.has(.aarch64, .sha3)) set.insert(.arm_sha3);
            if (cpu.has(.aarch64, .dotprod)) set.insert(.arm_dotprod);
        },
        .x86_64 => {
            if (cpu.has(.x86, .ssse3)) set.insert(.x86_ssse3);
            if (cpu.has(.x86, .sse4_2)) set.insert(.x86_sse42);
            if (cpu.has(.x86, .pclmul) and cpu.has(.x86, .sse4_1)) set.insert(.x86_pclmul);
            if (cpu.has(.x86, .aes)) set.insert(.x86_aes);
            if (cpu.has(.x86, .avx2)) set.insert(.x86_avx2);
            if (cpu.has(.x86, .avx2) and cpu.has(.x86, .vpclmulqdq)) set.insert(.x86_vpclmul);
            if (cpu.has(.x86, .bmi2) and cpu.has(.x86, .adx)) set.insert(.x86_bmi2_adx);
            if (cpu.has(.x86, .sha)) set.insert(.x86_sha);
        },
        else => {},
    }
    break :blk set;
};

/// The detected set's mask, with bit 31 saying it has been detected.
const Detection = enum(u32) { pending = 0, _ };
var detected: aegis.Atomic(Detection) = .init(.pending);
const done: u32 = 1 << 31;

/// Whether this CPU has `feature`.
pub fn has(comptime feature: Feature) bool {
    if (comptime guaranteed.contains(feature)) return true;
    if (comptime !detectable(feature)) return false;
    return features().contains(feature);
}

/// Whether `feature` can be had on this target at all: guaranteed, or found
/// at run time and a kernel that needs it entered from code built without
/// it. A user builds a kernel module for a feature only where this holds.
pub fn available(comptime feature: Feature) bool {
    return comptime guaranteed.contains(feature) or detectable(feature);
}

/// Every feature this CPU has that its kernels can use.
pub fn features() Set {
    var word: u32 = @backingInt(detected.load(.monotonic));
    if (word & done == 0) {
        word = @as(u32, detect().bits.mask) | done;
        detected.store(@fromBackingInt(@intCast(word)), .monotonic);
    }
    var set: Set = .empty;
    // safe: the mask's bits are the set's, below the done bit
    set.bits.mask = @truncate(word);
    return set;
}

/// Whether `feature` can be found at run time on this target, and a kernel
/// that needs it entered from code built without it.
fn detectable(feature: Feature) bool {
    return switch (builtin.cpu.arch) {
        .aarch64 => switch (feature) {
            .arm_crc, .arm_pmull, .arm_aes, .arm_sha2, .arm_sha3, .arm_dotprod => switch (builtin.os.tag) {
                .macos, .ios, .tvos, .watchos, .visionos, .linux, .windows => true,
                else => false,
            },
            else => false,
        },
        .x86_64 => switch (feature) {
            .x86_ssse3, .x86_sse42, .x86_pclmul, .x86_aes, .x86_bmi2_adx, .x86_sha => true,
            // A 256-bit kernel keeps 32-byte vectors on its stack, which
            // the x86-64 ABI aligns only to 16 bytes. LLVM realigns the
            // frame of a function that needs more; Zig's own x86-64
            // backend (Debug's default on Linux) does not, and assumes
            // its caller left the stack as aligned as the kernel needs,
            // which code built for the baseline does not: an aligned
            // store then faults. Under that backend these kernels run
            // only where the target guarantees AVX2, so every caller is
            // built with it too.
            .x86_avx2, .x86_vpclmul => builtin.zig_backend == .stage2_llvm,
            else => false,
        },
        else => false,
    };
}

fn detect() Set {
    var set = guaranteed;
    switch (builtin.cpu.arch) {
        .aarch64 => detectArm(&set),
        .x86_64 => detectX86(&set),
        else => {},
    }
    // A feature the kernels cannot use beyond the target's guarantees is
    // not reported.
    inline for (comptime std.enums.values(Feature)) |f| {
        if (comptime !guaranteed.contains(f) and !detectable(f)) set.remove(f);
    }
    return set;
}

fn detectArm(set: *Set) void {
    switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => {
            const names = [_]struct { [:0]const u8, Feature }{
                .{ "hw.optional.armv8_crc32", .arm_crc },
                .{ "hw.optional.arm.FEAT_PMULL", .arm_pmull },
                .{ "hw.optional.arm.FEAT_AES", .arm_aes },
                .{ "hw.optional.arm.FEAT_SHA256", .arm_sha2 },
                .{ "hw.optional.arm.FEAT_SHA3", .arm_sha3 },
                .{ "hw.optional.arm.FEAT_DotProd", .arm_dotprod },
            };
            for (names) |n| {
                var value: u32 = 0;
                var len: usize = @sizeOf(u32);
                if (std.c.sysctlbyname(n[0], &value, &len, null, 0) == 0 and value != 0) set.insert(n[1]);
            }
        },
        .linux => set.setUnion(decodeHwcap(std.os.linux.getauxval(std.elf.AT.HWCAP))),
        .windows => {
            const w = std.os.windows;
            if (w.IsProcessorFeaturePresent(.ARM_V8_CRC32_INSTRUCTIONS_AVAILABLE)) set.insert(.arm_crc);
            // One flag for the cryptographic extension: AES, PMULL, SHA-1 and SHA-256.
            if (w.IsProcessorFeaturePresent(.ARM_V8_CRYPTO_INSTRUCTIONS_AVAILABLE)) {
                set.insert(.arm_pmull);
                set.insert(.arm_aes);
                set.insert(.arm_sha2);
            }
            if (w.IsProcessorFeaturePresent(.ARM_SHA3_INSTRUCTIONS_AVAILABLE)) set.insert(.arm_sha3);
            if (w.IsProcessorFeaturePresent(.ARM_V82_DP_INSTRUCTIONS_AVAILABLE)) set.insert(.arm_dotprod);
        },
        else => {},
    }
}

fn detectX86(set: *Set) void {
    if (builtin.cpu.arch != .x86_64) return;
    const max_leaf = cpuid(0, 0)[0];
    const leaf1 = cpuid(1, 0);
    const leaf7 = if (max_leaf >= 7) cpuid(7, 0) else [4]u32{ 0, 0, 0, 0 };
    // XGETBV is an invalid instruction where the operating system has not
    // enabled it (OSXSAVE clear).
    const xcr0 = if (leaf1[2] & (1 << 27) != 0) xgetbv() else 0;
    set.setUnion(decodeX86(.{ .max_leaf = max_leaf, .leaf1_ecx = leaf1[2], .leaf7_ebx = leaf7[1], .leaf7_ecx = leaf7[2], .xcr0 = xcr0 }));
}

/// What CPUID and XGETBV said: the words x86-64 detection reads.
const X86Words = struct {
    /// CPUID leaf 0's EAX: the highest leaf there is.
    max_leaf: u32,
    leaf1_ecx: u32,
    /// Leaf 7's words, read only where `max_leaf` reaches it.
    leaf7_ebx: u32,
    leaf7_ecx: u32,
    /// XCR0's low word, read only where OSXSAVE is set.
    xcr0: u32,
};

/// The features CPUID's words say, on any target: detection on x86-64
/// reads the registers and decodes them here, so the decoding is tested
/// everywhere, on any words.
fn decodeX86(w: X86Words) Set {
    var set: Set = .empty;
    const sse41 = w.leaf1_ecx & (1 << 19) != 0;
    const pclmul = w.leaf1_ecx & (1 << 1) != 0;
    if (w.leaf1_ecx & (1 << 9) != 0) set.insert(.x86_ssse3);
    if (w.leaf1_ecx & (1 << 20) != 0) set.insert(.x86_sse42);
    if (sse41 and pclmul) set.insert(.x86_pclmul);
    if (w.leaf1_ecx & (1 << 25) != 0) set.insert(.x86_aes);
    if (w.max_leaf < 7) return set;
    // Scalar and 128-bit: no operating system state beyond SSE's.
    if (w.leaf7_ebx & (1 << 8) != 0 and w.leaf7_ebx & (1 << 19) != 0) set.insert(.x86_bmi2_adx);
    if (w.leaf7_ebx & (1 << 29) != 0) set.insert(.x86_sha);
    // AVX state saved by the operating system: OSXSAVE, then XCR0's SSE
    // and AVX bits.
    const osxsave = w.leaf1_ecx & (1 << 27) != 0;
    if (!osxsave or w.xcr0 & 0b110 != 0b110) return set;
    const avx2 = w.leaf7_ebx & (1 << 5) != 0;
    if (avx2) set.insert(.x86_avx2);
    if (avx2 and pclmul and w.leaf7_ecx & (1 << 10) != 0) set.insert(.x86_vpclmul);
    return set;
}

/// The features Linux's `AT_HWCAP` says on AArch64 (asm/hwcap.h for
/// arm64), on any target.
fn decodeHwcap(hwcap: usize) Set {
    const bits = [_]struct { u6, Feature }{
        .{ 7, .arm_crc }, .{ 4, .arm_pmull }, .{ 3, .arm_aes }, .{ 6, .arm_sha2 }, .{ 17, .arm_sha3 }, .{ 20, .arm_dotprod },
    };
    var set: Set = .empty;
    for (bits) |b| if (@as(u64, hwcap) & (@as(u64, 1) << b[0]) != 0) set.insert(b[1]);
    return set;
}

fn cpuid(leaf: u32, subleaf: u32) [4]u32 {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid" // aegis: boundary(A019): CPUID writes the four registers bound to its outputs and nothing else
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (subleaf),
    );
    return .{ eax, ebx, ecx, edx };
}

fn xgetbv() u32 {
    return asm volatile ("xgetbv" // aegis: boundary(A019): XGETBV reads ECX and writes EAX and EDX, which it declares
        : [eax] "={eax}" (-> u32),
        : [ecx] "{ecx}" (@as(u32, 0)),
        : .{ .edx = true });
}

test "the detected features include the guaranteed ones, and asking twice gives the same set" {
    const first = features();
    try std.testing.expect(first.supersetOf(guaranteed));
    try std.testing.expectEqual(first.bits.mask, features().bits.mask);
    inline for (comptime std.enums.values(Feature)) |f| try std.testing.expectEqual(first.contains(f), has(f));
}

test "a feature is had only where it is available, and the guaranteed ones always" {
    const set = features();
    inline for (comptime std.enums.values(Feature)) |f| {
        if (comptime guaranteed.contains(f)) {
            try std.testing.expect(available(f) and has(f));
        }
        if (comptime !available(f)) try std.testing.expect(!has(f) and !set.contains(f));
        // Each feature belongs to one architecture: on any other it is never available.
        const arm = comptime std.mem.startsWith(u8, @tagName(f), "arm_");
        if (comptime (arm and builtin.cpu.arch != .aarch64) or (!arm and builtin.cpu.arch != .x86_64)) try std.testing.expect(!available(f));
    }
}

test "on this machine, what the operating system reports agrees with the features" {
    // Apple silicon has every AArch64 feature listed; Darwin's sysctl says so.
    if (builtin.cpu.arch == .aarch64 and builtin.os.tag == .macos) {
        inline for (.{ Feature.arm_crc, .arm_pmull, .arm_aes, .arm_sha2, .arm_sha3, .arm_dotprod }) |f| try std.testing.expect(has(f));
    }
}

/// The README's table for x86-64, as words: a feature is had exactly where
/// every bit it names is set (leaf 7's only where the leaf exists), and an
/// AVX one only with OSXSAVE and XCR0's SSE and AVX bits.
const x86_table = [_]struct { feature: Feature, leaf1_ecx: u32 = 0, leaf7_ebx: u32 = 0, leaf7_ecx: u32 = 0, avx: bool = false }{
    .{ .feature = .x86_ssse3, .leaf1_ecx = 1 << 9 },
    .{ .feature = .x86_sse42, .leaf1_ecx = 1 << 20 },
    .{ .feature = .x86_pclmul, .leaf1_ecx = 1 << 1 | 1 << 19 },
    .{ .feature = .x86_aes, .leaf1_ecx = 1 << 25 },
    .{ .feature = .x86_avx2, .leaf7_ebx = 1 << 5, .avx = true },
    .{ .feature = .x86_vpclmul, .leaf1_ecx = 1 << 1, .leaf7_ebx = 1 << 5, .leaf7_ecx = 1 << 10, .avx = true },
    .{ .feature = .x86_bmi2_adx, .leaf7_ebx = 1 << 8 | 1 << 19 },
    .{ .feature = .x86_sha, .leaf7_ebx = 1 << 29 },
};

/// The README's table for Linux on AArch64: one `AT_HWCAP` bit each.
const hwcap_table = [_]struct { Feature, u6 }{
    .{ .arm_crc, 7 }, .{ .arm_pmull, 4 }, .{ .arm_aes, 3 }, .{ .arm_sha2, 6 }, .{ .arm_sha3, 17 }, .{ .arm_dotprod, 20 },
};

fn x86Agrees(w: X86Words) !void {
    const set = decodeX86(w);
    const avx = w.leaf1_ecx & (1 << 27) != 0 and w.xcr0 & 0b110 == 0b110;
    var named: Set = .empty;
    for (x86_table) |row| {
        named.insert(row.feature);
        const leaf7 = row.leaf7_ebx | row.leaf7_ecx != 0;
        const want = w.leaf1_ecx & row.leaf1_ecx == row.leaf1_ecx and
            (!leaf7 or (w.max_leaf >= 7 and w.leaf7_ebx & row.leaf7_ebx == row.leaf7_ebx and w.leaf7_ecx & row.leaf7_ecx == row.leaf7_ecx)) and
            (!row.avx or avx);
        try std.testing.expectEqual(want, set.contains(row.feature));
    }
    // Nothing the table does not name: no AArch64 feature from x86 words.
    try std.testing.expect(named.supersetOf(set));
}

fn hwcapAgrees(hwcap: u64) !void {
    const set = decodeHwcap(@truncate(hwcap));
    var named: Set = .empty;
    for (hwcap_table) |row| {
        named.insert(row[0]);
        try std.testing.expectEqual(@as(usize, @truncate(hwcap)) & (@as(usize, 1) << row[1]) != 0, set.contains(row[0]));
    }
    try std.testing.expect(named.supersetOf(set));
}

/// Words that reach every row: each bit set half the time, leaf 7 missing
/// one time in eight.
fn randomWords(random: std.Random) X86Words {
    return .{
        .max_leaf = if (random.uintLessThan(u8, 8) == 0) random.uintLessThan(u32, 7) else random.int(u32),
        .leaf1_ecx = random.int(u32),
        .leaf7_ebx = random.int(u32),
        .leaf7_ecx = random.int(u32),
        .xcr0 = random.int(u32),
    };
}

test "CPUID's words decode as the README's table says, on any words" {
    var prng: std.Random.DefaultPrng = .init(0x1ad4);
    const random = prng.random();
    var reached: Set = .empty;
    for (0..20_000) |_| {
        const w = randomWords(random);
        try x86Agrees(w);
        reached.setUnion(decodeX86(w));
    }
    // Every x86 row was had at least once.
    for (x86_table) |row| try std.testing.expect(reached.contains(row.feature));
    // Words a CPU gives: an AVX2 part whose operating system saves YMM state, and the same
    // part where it does not (XCR0 without the AVX bit), which has no 256-bit feature.
    const avx2_cpu: X86Words = .{ .max_leaf = 0xd, .leaf1_ecx = 0x7ffafbff, .leaf7_ebx = 0x029c67af, .leaf7_ecx = 0x00000400, .xcr0 = 0x7 };
    try std.testing.expect(decodeX86(avx2_cpu).contains(.x86_avx2) and decodeX86(avx2_cpu).contains(.x86_vpclmul));
    var no_ymm = avx2_cpu;
    no_ymm.xcr0 = 0x3;
    try std.testing.expect(!decodeX86(no_ymm).contains(.x86_avx2) and !decodeX86(no_ymm).contains(.x86_vpclmul));
    try std.testing.expect(decodeX86(no_ymm).contains(.x86_ssse3));
}

test "AT_HWCAP decodes as the README's table says, on any word" {
    var prng: std.Random.DefaultPrng = .init(0x4ca9);
    const random = prng.random();
    for (0..20_000) |_| try hwcapAgrees(random.int(u64));
}

test "fuzz: CPUID's and AT_HWCAP's words decode as the README's table says" {
    try std.testing.fuzz({}, fuzzDecode, .{});
}

fn fuzzDecode(_: void, smith: *std.testing.Smith) anyerror!void {
    try x86Agrees(.{
        .max_leaf = smith.value(u32),
        .leaf1_ecx = smith.value(u32),
        .leaf7_ebx = smith.value(u32),
        .leaf7_ecx = smith.value(u32),
        .xcr0 = smith.value(u32),
    });
    try hwcapAgrees(smith.value(u64));
}
