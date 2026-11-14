//! The questions ladar asks the processor and the operating system, each one call past std's
//! checked layer: CPUID and XGETBV on x86-64, and each system's report of AArch64 features.
//! Nothing here decides what a feature is; `cpu.zig` reads the answers. glint's P007 seam is
//! this file alone (glint.json).
const std = @import("std");

/// CPUID's four registers (EAX, EBX, ECX, EDX) for `leaf` and `subleaf`. The caller asks only for
/// a leaf at most leaf 0's EAX, the highest the processor defines.
pub fn cpuid(leaf: u32, subleaf: u32) [4]u32 {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    // CPUID writes the four registers bound to its outputs and nothing else.
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (subleaf),
    );
    return .{ eax, ebx, ecx, edx };
}

/// XCR0, the register of the state the operating system saves. The caller asks only where CPUID
/// leaf 1 sets OSXSAVE, without which XGETBV faults.
pub fn xgetbv() u32 {
    // XGETBV reads ECX and writes EAX and EDX, which it declares.
    return asm volatile ("xgetbv"
        : [eax] "={eax}" (-> u32),
        : [ecx] "{ecx}" (@as(u32, 0)),
        : .{ .edx = true });
}

/// Whether Darwin's sysctl `name` is a 32-bit value that is not zero: false where the name is
/// unknown, as it is for a feature the system predates.
pub fn sysctlFlag(name: [:0]const u8) bool {
    var value: u32 = 0;
    var len: usize = @sizeOf(u32);
    return std.c.sysctlbyname(name, &value, &len, null, 0) == 0 and value != 0;
}

/// Linux's AT_HWCAP word from the auxiliary vector the kernel gave the process.
pub fn hwcap() usize {
    return std.os.linux.getauxval(std.elf.AT.HWCAP);
}

/// Whether Windows reports the processor feature `feature`.
pub fn processorFeature(feature: std.os.windows.PF) bool {
    return std.os.windows.IsProcessorFeaturePresent(feature);
}
