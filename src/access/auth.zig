//! The SSH front door's brain (docs/access.md): key lookup for sshd's
//! AuthorizedKeysCommand, and the forced command that checks permission
//! and mints a scoped token. SSH authenticates; these hand out HTTPS
//! credentials and nothing else (invariant 22).

const std = @import("std");
const pg = @import("../store/pg.zig");
const token_mod = @import("token.zig");

/// `cid ssh-keys --fingerprint=SHA256:…`, run by sshd as
/// AuthorizedKeysCommand. Prints zero or one authorized_keys line that
/// pins the forced command to the key's account and forbids everything
/// else (no pty, no forwarding — "restrict").
pub fn authorizedKeysLine(
    arena: std.mem.Allocator,
    db: *pg.Db,
    fingerprint: []const u8,
) !?[]const u8 {
    const fp_z = try arena.dupeZ(u8, fingerprint);
    var rows = db.query(
        "SELECT account_id, public_key FROM ssh_keys WHERE fingerprint = $1",
        &.{fp_z},
        null,
    ) catch return error.Db;
    defer rows.deinit();
    if (rows.count() == 0) return null;
    const account = rows.get(0, 0);
    const public_key = rows.get(0, 1);
    if (std.mem.indexOfAny(u8, account, "\"\n\r") != null) return error.Db;
    const line = try std.fmt.allocPrint(
        arena,
        "restrict,command=\"cid ssh-auth --account={s}\" {s}\n",
        .{ account, std.mem.trim(u8, public_key, " \n") },
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

/// Parses SSH_ORIGINAL_COMMAND. Only `cid-auth <dataset> <read|write>`
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
    db: *pg.Db,
    secret: []const u8,
    server_url: []const u8,
    now_unix: u64,
    req: AuthRequest,
) AuthError!Grant {
    const account_z = try arena.dupeZ(u8, req.account);
    const dataset_z = try arena.dupeZ(u8, req.dataset);

    var rows = db.query(
        "SELECT level FROM access a JOIN datasets d USING (dataset_id) " ++
            "WHERE d.name = $1 AND a.account_id = $2",
        &.{ dataset_z, account_z },
        null,
    ) catch return error.Db;
    defer rows.deinit();

    const granted = blk: {
        if (rows.count() == 0) break :blk false;
        const have_text = rows.get(0, 0);
        // access levels: read < write < maintain; maintain covers write.
        const have: token_mod.Level = if (std.mem.eql(u8, have_text, "read")) .read else .write;
        break :blk have.covers(req.level);
    };
    logAuthEvent(arena, db, req, granted);
    if (!granted) return error.AccessDenied;

    const tok = token_mod.mint(arena, secret, .{
        .expiry_unix = now_unix + token_mod.default_ttl_secs,
        .level = req.level,
        .account = req.account,
        .dataset = req.dataset,
    }) catch return error.BadCommand;
    return .{ .token = tok, .url = server_url, .expires_in_secs = token_mod.default_ttl_secs };
}

fn logAuthEvent(arena: std.mem.Allocator, db: *pg.Db, req: AuthRequest, granted: bool) void {
    const account_z = arena.dupeZ(u8, req.account) catch return;
    const dataset_z = arena.dupeZ(u8, req.dataset) catch return;
    const level_z = arena.dupeZ(u8, @tagName(req.level)) catch return;
    db.execParams(
        "INSERT INTO auth_events (ts, account_id, dataset_id, level, granted) " ++
            "SELECT now(), $1, d.dataset_id, $2, $3::boolean FROM (SELECT 1) one " ++
            "LEFT JOIN datasets d ON d.name = $4",
        &.{ account_z, level_z, if (granted) "true" else "false", dataset_z },
        null,
    ) catch {};
}

test "original command parsing accepts exactly one shape" {
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
