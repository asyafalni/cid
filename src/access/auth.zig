//! The SSH front door's brain (docs/access.md): key lookup for sshd's
//! AuthorizedKeysCommand, and the forced command that checks permission
//! and mints a scoped token. SSH authenticates; these hand out HTTPS
//! credentials and nothing else (invariant 22).

const std = @import("std");
const dbx = @import("../store/db.zig");
const token_mod = @import("token.zig");
const gitlab = @import("gitlab_sync.zig");

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
    /// `cid-auth <dataset> create`: a maintain token for a dataset that
    /// does not exist yet, so its creator can make it (see authorizeCreate).
    create: bool = false,
};

pub const AuthError = error{
    BadCommand,
    AccessDenied,
    Db,
    OutOfMemory,
};

/// Parses SSH_ORIGINAL_COMMAND. Only
/// `cid-auth <dataset> <read|write|maintain|create>` is accepted; anything
/// else is refused and logged (invariant 22).
pub fn parseOriginalCommand(original: []const u8, account: []const u8) AuthError!AuthRequest {
    var it = std.mem.tokenizeScalar(u8, original, ' ');
    const verb = it.next() orelse return error.BadCommand;
    if (!std.mem.eql(u8, verb, "cid-auth")) return error.BadCommand;
    const dataset = it.next() orelse return error.BadCommand;
    const level_text = it.next() orelse return error.BadCommand;
    if (it.next() != null) return error.BadCommand;
    if (dataset.len == 0 or std.mem.indexOfScalar(u8, dataset, ':') != null) return error.BadCommand;
    if (std.mem.eql(u8, level_text, "create")) return .{ .account = account, .dataset = dataset, .level = .maintain, .create = true };
    const level = std.meta.stringToEnum(token_mod.Level, level_text) orelse return error.BadCommand;
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

/// Why a create was refused, in the words the person sees.
pub const CreateRefusal = enum { exists, no_gitlab, not_gitlab_account, not_maintainer, gitlab_unreachable };

pub fn createRefusalText(arena: std.mem.Allocator, why: CreateRefusal, dataset: []const u8) error{OutOfMemory}![]const u8 {
    return switch (why) {
        .exists => std.fmt.allocPrint(arena, "{s} already exists. Run 'cid clone' to work with it.", .{dataset}),
        .no_gitlab => std.fmt.allocPrint(arena, "this server cannot check GitLab roles (CID_GITLAB_TOKEN unset), so it cannot create {s} over SSH. Ask the administrator to create it, then run 'cid clone' on it.", .{dataset}),
        .not_gitlab_account => std.fmt.allocPrint(arena, "only GitLab accounts can create datasets over SSH. Ask the administrator to create {s}, then run 'cid clone' on it.", .{dataset}),
        .not_maintainer => std.fmt.allocPrint(arena, "creating {s} needs the Maintainer role on the GitLab project {s}. Create the project there, or ask its owner, then run 'cid init' again.", .{ dataset, dataset }),
        .gitlab_unreachable => std.fmt.allocPrint(arena, "GitLab did not answer, so the server cannot check your role on {s}. Run 'cid init' again in a moment.", .{dataset}),
    };
}

/// A token to create `req.dataset`, for the GitLab Maintainer (or Owner)
/// of the project at the same path, checked live with GitLab: the role
/// that will own the dataset once it exists, asked at the moment it
/// matters rather than at the last sync. A dataset that already exists
/// is refused; its owners already have their way in.
pub fn authorizeCreate(
    arena: std.mem.Allocator,
    io: std.Io,
    db: *dbx.sql.Db,
    scope: anytype,
    secret: []const u8,
    server_url: []const u8,
    now_unix: u64,
    gitlab_config: ?gitlab.Config,
    req: AuthRequest,
) AuthError!union(enum) { granted: Grant, refused: CreateRefusal } {
    std.debug.assert(req.create);
    const refused: ?CreateRefusal = blk: {
        const exists = db.rawOne(i64, scope, "SELECT 1::bigint FROM datasets WHERE name = $1", .{req.dataset}) catch return error.Db;
        if (exists != null) break :blk .exists;
        const cfg = gitlab_config orelse break :blk .no_gitlab;
        const user_id = gitlabUserId(req.account) orelse break :blk .not_gitlab_account;
        break :blk switch (try maintainerOf(arena, io, cfg, req.dataset, user_id)) {
            .yes => null,
            .no => .not_maintainer,
            .unknown => .gitlab_unreachable,
        };
    };
    logAuthEvent(db, scope, req, refused == null);
    if (refused) |why| return .{ .refused = why };
    const tok = token_mod.mint(arena, secret, .{
        .expiry_unix = now_unix + token_mod.default_ttl_secs,
        .level = .maintain,
        .account = req.account,
        .dataset = req.dataset,
    }) catch return error.BadCommand;
    return .{ .granted = .{ .token = tok, .url = server_url, .expires_in_secs = token_mod.default_ttl_secs } };
}

/// The GitLab user id of a `gitlab:<id>` account.
fn gitlabUserId(account: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, account, "gitlab:")) return null;
    return std.fmt.parseInt(u64, account["gitlab:".len..], 10) catch null;
}

const Answer = enum { yes, no, unknown };

/// Whether the user is a Maintainer or Owner of the project at `path`,
/// directly or through a group (`members/all`).
fn maintainerOf(arena: std.mem.Allocator, io: std.Io, cfg: gitlab.Config, path: []const u8, user_id: u64) error{OutOfMemory}!Answer {
    const project = gitlab.urlEncodePath(arena, path) catch return error.OutOfMemory;
    const got = gitlab.fetchOne(arena, io, cfg, "/api/v4/projects/{s}/members/all/{d}", .{ project, user_id }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .unknown,
    };
    return judgeMember(arena, got.status, got.body);
}

/// GitLab's answer about one member: 404 is "not a member" (or no such
/// project, which is the same refusal); Maintainer is 40, Owner 50.
fn judgeMember(arena: std.mem.Allocator, status: u16, body: []const u8) Answer {
    if (status == 404) return .no;
    if (status != 200) return .unknown;
    const Member = struct { access_level: u32 = 0 };
    const m = std.json.parseFromSliceLeaky(Member, arena, body, .{ .ignore_unknown_fields = true }) catch return .unknown;
    return if (m.access_level >= 40) .yes else .no;
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
    const create = try parseOriginalCommand("cid-auth org/datasets/new create", "gitlab:1");
    try std.testing.expect(create.create);
    try std.testing.expectEqual(token_mod.Level.maintain, create.level);
}

test "a GitLab member answer: Maintainer and Owner may create, others may not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqual(Answer.yes, judgeMember(a, 200, "{\"id\":7,\"access_level\":40}"));
    try std.testing.expectEqual(Answer.yes, judgeMember(a, 200, "{\"id\":7,\"access_level\":50}"));
    try std.testing.expectEqual(Answer.no, judgeMember(a, 200, "{\"id\":7,\"access_level\":30}"));
    try std.testing.expectEqual(Answer.no, judgeMember(a, 404, "{\"message\":\"404 Not found\"}"));
    try std.testing.expectEqual(Answer.unknown, judgeMember(a, 500, ""));
    try std.testing.expectEqual(@as(?u64, 42), gitlabUserId("gitlab:42"));
    try std.testing.expectEqual(@as(?u64, null), gitlabUserId("local:42"));
}
