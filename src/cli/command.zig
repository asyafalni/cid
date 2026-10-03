//! Everyday-command parsing. One place decides what the user asked for;
//! each command lives in its own file (CLAUDE.md, repository layout).

const std = @import("std");

pub const Parsed = union(enum) {
    help,
    help_all,
    version,
    init: []const [:0]const u8,
    add: []const [:0]const u8,
    commit: []const [:0]const u8,
    status,
    push,
    pull: []const [:0]const u8,
    log,
    clone: []const [:0]const u8,
    checkout: []const [:0]const u8,
    tag: []const [:0]const u8,
    restore: []const [:0]const u8,
    diff: []const [:0]const u8,
    branch: []const [:0]const u8,
    merge: []const [:0]const u8,
    /// `cid admin …`; the payload is everything after `admin`.
    admin: []const [:0]const u8,
    /// Plumbing: a file's content hash, as `git hash-object`; never in help.
    hash_object: []const [:0]const u8,
    /// sshd-only entry points; never in help.
    ssh_keys: []const [:0]const u8,
    ssh_auth: []const [:0]const u8,
    /// A real cid command this build does not include yet.
    not_yet: []const u8,
    /// Not a cid command; the payload is what the user typed.
    unknown: []const u8,
};

/// Commands the docs promise but this build does not include yet. Saying
/// "not built yet" beats pretending they are typos.
const not_yet_commands = [_][]const u8{};

pub fn parse(args: []const [:0]const u8) Parsed {
    if (args.len == 0) return .help;
    const first = args[0];
    if (eql(first, "help") or eql(first, "--help") or eql(first, "-h")) {
        if (args.len > 1 and eql(args[1], "--all")) return .help_all;
        return .help;
    }
    if (eql(first, "version") or eql(first, "--version")) return .version;
    if (eql(first, "init")) return .{ .init = args[1..] };
    if (eql(first, "add")) return .{ .add = args[1..] };
    if (eql(first, "commit")) return .{ .commit = args[1..] };
    if (eql(first, "status")) return .status;
    if (eql(first, "push")) return .push;
    if (eql(first, "pull")) return .{ .pull = args[1..] };
    if (eql(first, "log")) return .log;
    if (eql(first, "clone")) return .{ .clone = args[1..] };
    if (eql(first, "checkout")) return .{ .checkout = args[1..] };
    if (eql(first, "tag")) return .{ .tag = args[1..] };
    if (eql(first, "restore")) return .{ .restore = args[1..] };
    if (eql(first, "diff")) return .{ .diff = args[1..] };
    if (eql(first, "branch")) return .{ .branch = args[1..] };
    if (eql(first, "merge")) return .{ .merge = args[1..] };
    if (eql(first, "admin")) return .{ .admin = args[1..] };
    if (eql(first, "hash-object")) return .{ .hash_object = args[1..] };
    if (eql(first, "ssh-keys")) return .{ .ssh_keys = args[1..] };
    if (eql(first, "ssh-auth")) return .{ .ssh_auth = args[1..] };
    for (not_yet_commands) |cmd| {
        if (eql(first, cmd)) return .{ .not_yet = first };
    }
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
