//! The SSH front door's brain (docs/access.md): key lookup for sshd's
//! AuthorizedKeysCommand, and the forced command that checks permission
//! and mints a scoped token. SSH authenticates; these hand out HTTPS
//! credentials and nothing else (invariant 22).

const std = @import("std");
const dbx = @import("../store/db.zig");
const token_mod = @import("token.zig");

const KeyRow = struct {
    pub const nilo_table = .projection;
    account_id: []const u8,
    public_key: []const u8,
};

/// `cid ssh-keys --fingerprint=SHA256:…`, run by sshd as
/// AuthorizedKeysCommand. Prints zero or one authorized_keys line that
/// pins the forced command to the key's account and forbids everything
/// else (no pty, no forwarding — "restrict").
pub fn authorizedKeysLine(
    arena: std.mem.Allocator,
    db: *dbx.sql.Db,
    scope: anytype,
    fingerprint: []const u8,
) !?[]const u8 {
    const found = db.rawOne(KeyRow, scope,
        \\SELECT account_id, public_key FROM ssh_keys WHERE fingerprint = $1
    , .{fingerprint}) catch return error.Db;
    const key = found orelse return null;
    if (std.mem.indexOfAny(u8, key.account_id, "\"\n\r") != null) return error.Db;
    const line = try std.fmt.allocPrint(
        arena,
        "restrict,command=\"cid ssh-auth --account={s}\" {s}\n",
        .{ key.account_id, std.mem.trim(u8, key.public_key, " \n") },
    );
    return line;
}

pub const AuthRequest = struct {
    account: []const u8,
    dataset: []const u8,
    level: token_mod.Level,
};

pub const AuthError = error{
    BadCommand,
    AccessDenied,
    Db,
    OutOfMemory,
};

/// Parses SSH_ORIGINAL_COMMAND. Only `cid-auth <dataset> <read|write|maintain>`
/// is accepted; anything else is refused and logged (invariant 22).
pub fn parseOriginalCommand(original: []const u8, account: []const u8) AuthError!AuthRequest {
    var it = std.mem.tokenizeScalar(u8, original, ' ');
    const verb = it.next() orelse return error.BadCommand;
    if (!std.mem.eql(u8, verb, "cid-auth")) return error.BadCommand;
    const dataset = it.next() orelse return error.BadCommand;
    const level_text = it.next() orelse return error.BadCommand;
    if (it.next() != null) return error.BadCommand;
    const level = std.meta.stringToEnum(token_mod.Level, level_text) orelse return error.BadCommand;
    if (dataset.len == 0 or std.mem.indexOfScalar(u8, dataset, ':') != null) return error.BadCommand;
    return .{ .account = account, .dataset = dataset, .level = level };
}

pub const Grant = struct {
    token: []const u8,
    url: []const u8,
    expires_in_secs: u64,
};

/// Checks the access table and mints the token. Every decision lands in
/// auth_events, granted or not.
pub fn authorize(
    arena: std.mem.Allocator,
    db: *dbx.sql.Db,
    scope: anytype,
    secret: []const u8,
    server_url: []const u8,
    now_unix: u64,
    req: AuthRequest,
) AuthError!Grant {
    const have_text = db.rawOne([]const u8, scope,
        \\SELECT a.level FROM access a JOIN datasets d USING (dataset_id)
        \\WHERE d.name = $1 AND a.account_id = $2
    , .{ req.dataset, req.account }) catch return error.Db;

    const granted = blk: {
        const text = have_text orelse break :blk false;
        // The access table's levels are the token levels, one for one.
        const have = std.meta.stringToEnum(token_mod.Level, text) orelse break :blk false;
        break :blk have.covers(req.level);
    };
    logAuthEvent(db, scope, req, granted);
    if (!granted) return error.AccessDenied;

    const tok = token_mod.mint(arena, secret, .{
        .expiry_unix = now_unix + token_mod.default_ttl_secs,
        .level = req.level,
        .account = req.account,
        .dataset = req.dataset,
    }) catch return error.BadCommand;
    return .{ .token = tok, .url = server_url, .expires_in_secs = token_mod.default_ttl_secs };
}

fn logAuthEvent(db: *dbx.sql.Db, scope: anytype, req: AuthRequest, granted: bool) void {
    _ = db.exec(scope,
        \\INSERT INTO auth_events (ts, account_id, dataset_id, level, granted)
        \\SELECT now(), $1, d.dataset_id, $2, $3 FROM (SELECT 1) one
        \\LEFT JOIN datasets d ON d.name = $4
    , .{ req.account, @tagName(req.level), granted, req.dataset }) catch {};
}

test "original command parsing accepts exactly one shape" {
    const owner = try parseOriginalCommand("cid-auth org/datasets/x maintain", "gitlab:1");
    try std.testing.expectEqual(token_mod.Level.maintain, owner.level);
    const ok = try parseOriginalCommand("cid-auth org/datasets/x write", "gitlab:1");
    try std.testing.expectEqualStrings("org/datasets/x", ok.dataset);
    try std.testing.expectEqual(token_mod.Level.write, ok.level);

    const bad = [_][]const u8{
        "",
        "bash",
        "cid-auth",
        "cid-auth ds",
        "cid-auth ds admin",
        "cid-auth ds read extra",
        "scp -f x",
        "cid-auth evil:colon read",
    };
    for (bad) |cmd| {
        try std.testing.expectError(error.BadCommand, parseOriginalCommand(cmd, "gitlab:1"));
    }
}
