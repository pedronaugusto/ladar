const std = @import("std");
const ladar = @import("ladar");

pub fn main() void {
    const bytes = "every byte counts";
    std.debug.assert(sum(bytes) == sumPortable(bytes));
    // --- README:features ---
    // Every feature this CPU has: at least what the target guarantees.
    const have = ladar.features();
    std.debug.assert(have.supersetOf(ladar.guaranteed));
    // A set to keep or log; `has` is the one to branch on, comptime where it can be.
    std.debug.assert(have.contains(.x86_avx2) == ladar.has(.x86_avx2));
    // --- README:features ---
}

// --- README:dispatch ---
fn sum(bytes: []const u8) u32 {
    // The wide kernel is referenced only where the target can have AVX2 at all,
    // and entered only where this CPU has it; anywhere else, the portable one.
    if (comptime ladar.available(.x86_avx2)) {
        if (ladar.has(.x86_avx2)) return sumWide(bytes);
    }
    return sumPortable(bytes);
}
// --- README:dispatch ---

/// Stands for a kernel in a module of its own, built with AVX2 enabled
/// (Zig sets CPU features per module).
fn sumWide(bytes: []const u8) u32 {
    return sumPortable(bytes);
}

fn sumPortable(bytes: []const u8) u32 {
    var total: u32 = 0;
    for (bytes) |b| total += b;
    return total;
}
