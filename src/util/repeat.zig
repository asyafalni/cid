//! A string repeated at compile time, as `"ab" ** 32` wrote it before Zig
//! 0.17 removed the operator: fixed-width fixtures in tests (a 64-character
//! hash, a long path). The result is an array, so `++` takes it.

const std = @import("std");

pub fn repeat(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    return &Repeated(s, n).value;
}

/// Built once per (string, count), as a constant in the binary.
fn Repeated(comptime s: []const u8, comptime n: usize) type {
    return struct {
        const value: [s.len * n]u8 = blk: {
            var out: [s.len * n]u8 = undefined;
            for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
            break :blk out;
        };
    };
}

test "repeat writes the string n times, at compile time" {
    try std.testing.expectEqualStrings("abababab", repeat("ab", 4));
    try std.testing.expectEqualStrings("x", "x" ++ repeat("y", 0));
    try std.testing.expectEqual(@as(usize, 64), repeat("ab", 32).len);
}
