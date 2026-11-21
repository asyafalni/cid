//! The path patterns of `.cidignore` and `.cidkeys` (CLAUDE.md, rules for
//! every command): a small subset of `.gitignore`'s, the same on the CLI
//! and the server. An exact path, a folder (`dir/`, everything under it),
//! or an extension (`*.ext`, at any depth).

const std = @import("std");

pub fn matches(pattern: []const u8, path: []const u8) bool {
    if (std.mem.eql(u8, pattern, path)) return true;
    if (std.mem.endsWith(u8, pattern, "/") and std.mem.startsWith(u8, path, pattern)) return true;
    if (std.mem.startsWith(u8, pattern, "*.")) {
        const base_start = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| i + 1 else 0;
        if (std.mem.endsWith(u8, path[base_start..], pattern[1..])) return true;
    }
    return false;
}

test "exact paths, folders and extensions" {
    try std.testing.expect(matches("people.csv", "people.csv"));
    try std.testing.expect(!matches("people.csv", "data/people.csv"));
    try std.testing.expect(matches("data/", "data/a/people.csv"));
    try std.testing.expect(!matches("data/", "database.csv"));
    try std.testing.expect(matches("*.csv", "data/a/people.csv"));
    try std.testing.expect(!matches("*.csv", "people.csv.gz"));
}
