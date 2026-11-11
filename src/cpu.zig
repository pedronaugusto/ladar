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
    // not one warp has.
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
        .linux => {
            const hwcap = std.os.linux.getauxval(std.elf.AT.HWCAP);
            // asm/hwcap.h for arm64.
            if (hwcap & (1 << 7) != 0) set.insert(.arm_crc);
            if (hwcap & (1 << 4) != 0) set.insert(.arm_pmull);
            if (hwcap & (1 << 3) != 0) set.insert(.arm_aes);
            if (hwcap & (1 << 6) != 0) set.insert(.arm_sha2);
            if (hwcap & (1 << 17) != 0) set.insert(.arm_sha3);
            if (hwcap & (1 << 20) != 0) set.insert(.arm_dotprod);
        },
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
    const leaf1 = cpuid(1, 0);
    const sse41 = leaf1[2] & (1 << 19) != 0;
    const pclmul = leaf1[2] & (1 << 1) != 0;
    if (leaf1[2] & (1 << 9) != 0) set.insert(.x86_ssse3);
    if (leaf1[2] & (1 << 20) != 0) set.insert(.x86_sse42);
    if (sse41 and pclmul) set.insert(.x86_pclmul);
    if (leaf1[2] & (1 << 25) != 0) set.insert(.x86_aes);
    if (cpuid(0, 0)[0] < 7) return;
    const leaf7 = cpuid(7, 0);
    // Scalar and 128-bit: no operating system state beyond SSE's.
    if (leaf7[1] & (1 << 8) != 0 and leaf7[1] & (1 << 19) != 0) set.insert(.x86_bmi2_adx);
    if (leaf7[1] & (1 << 29) != 0) set.insert(.x86_sha);
    // AVX state saved by the operating system: OSXSAVE, then XCR0's SSE
    // and AVX bits.
    const osxsave = leaf1[2] & (1 << 27) != 0;
    if (!osxsave or xgetbv() & 0b110 != 0b110) return;
    const avx2 = leaf7[1] & (1 << 5) != 0;
    if (avx2) set.insert(.x86_avx2);
    if (avx2 and pclmul and leaf7[2] & (1 << 10) != 0) set.insert(.x86_vpclmul);
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
