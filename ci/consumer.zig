//! What a project that depends on ladar and nothing else writes. Built by
//! `zig build check-consumer` with no packages to fetch beyond aegis, so
//! ladar's build.zig must work without any of its own CI dependencies.
const std = @import("std");
const ladar = @import("ladar");

pub fn main() void {
    std.debug.assert(ladar.features().supersetOf(ladar.guaranteed));
    std.debug.assert(ladar.features().contains(.x86_avx2) == ladar.has(.x86_avx2));
}
