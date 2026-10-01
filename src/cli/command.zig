//! Everyday-command parsing. One place decides what the user asked for;
//! each command lives in its own file (CLAUDE.md, repository layout).

const std = @import("std");

pub const Parsed = union(enum) {
    help,
    version,
    /// `cid admin …`; the payload is everything after `admin`.
    admin: []const [:0]const u8,
    /// Not a cid command; the payload is what the user typed.
    unknown: []const u8,
};

pub fn parse(args: []const [:0]const u8) Parsed {
    if (args.len == 0) return .help;
    const first = args[0];
    if (eql(first, "help") or eql(first, "--help") or eql(first, "-h")) return .help;
    if (eql(first, "version") or eql(first, "--version")) return .version;
    if (eql(first, "admin")) return .{ .admin = args[1..] };
    return .{ .unknown = first };
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test "no arguments means help" {
    try std.testing.expect(parse(&.{}) == .help);
}

test "help spellings" {
    const spellings = [_][:0]const u8{ "help", "--help", "-h" };
    for (spellings) |s| {
        try std.testing.expect(parse(&.{s}) == .help);
    }
}

test "version spellings" {
    const spellings = [_][:0]const u8{ "version", "--version" };
    for (spellings) |s| {
        try std.testing.expect(parse(&.{s}) == .version);
    }
}

test "admin captures its subcommand arguments" {
    const args = [_][:0]const u8{ "admin", "migrate" };
    const parsed = parse(&args);
    try std.testing.expect(parsed == .admin);
    try std.testing.expectEqual(@as(usize, 1), parsed.admin.len);
    try std.testing.expectEqualStrings("migrate", parsed.admin[0]);
}

test "unknown command carries the user's word back" {
    const parsed = parse(&.{"comit"});
    try std.testing.expect(parsed == .unknown);
    try std.testing.expectEqualStrings("comit", parsed.unknown);
}
