//! The SSH front door's brain (docs/access.md): key lookup for sshd's
//! AuthorizedKeysCommand, and the forced command that checks permission
//! and mints a scoped token. SSH authenticates; these hand out HTTPS
//! credentials and nothing else (invariant 22).

const std = @import("std");
const dbx = @import("../store/db.zig");
const token_mod = @import("token.zig");
const host_mod = @import("host.zig");

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
    // A deploy key's last use, which its owners see (`cid deploy-key list`).
    if (std.mem.startsWith(u8, req.account, "deploy:"))
        _ = db.exec(scope, "UPDATE ssh_keys SET last_used_at = now() WHERE account_id = $1 AND source = 'deploy'", .{req.account}) catch {};

    const tok = token_mod.mint(arena, secret, .{
        .expiry_unix = now_unix + token_mod.default_ttl_secs,
        .level = req.level,
        .account = req.account,
        .dataset = req.dataset,
    }) catch return error.BadCommand;
    return .{ .token = tok, .url = server_url, .expires_in_secs = token_mod.default_ttl_secs };
}

/// Why a create over SSH was refused, in the words the person sees.
pub const CreateRefusal = enum { exists, no_host, not_host_account };

/// The refusal in words; `kind` is the host the server takes access from.
pub fn createRefusalText(arena: std.mem.Allocator, why: CreateRefusal, dataset: []const u8, kind: ?host_mod.Kind) error{OutOfMemory}![]const u8 {
    return switch (why) {
        .exists => std.fmt.allocPrint(arena, "{s} already exists. Run 'cid clone' to work with it.", .{dataset}),
        .no_host => std.fmt.allocPrint(arena, "this server takes access from no git host (neither CID_GITLAB_TOKEN nor CID_GITHUB_TOKEN is set), so it cannot check roles to create {s} over SSH. Ask the administrator to create it, then run 'cid clone' on it.", .{dataset}),
        .not_host_account => std.fmt.allocPrint(arena, "only {s} accounts can create datasets over SSH. Ask the administrator to create {s}, then run 'cid clone' on it.", .{ if (kind) |k| k.name() else "git host", dataset }),
    };
}

/// A token to create `req.dataset`, for an account on the server's host. The role itself
/// is checked when the dataset is created (checkCreate), where the git
/// URL that names its repository is known: `cid-auth` sees only the name.
/// A dataset that already exists is refused; its owners have their way in.
pub fn authorizeCreate(
    arena: std.mem.Allocator,
    io: std.Io,
    db: *dbx.sql.Db,
    scope: anytype,
    secret: []const u8,
    server_url: []const u8,
    now_unix: u64,
    host_config: ?host_mod.Config,
    req: AuthRequest,
) AuthError!union(enum) { granted: Grant, refused: CreateRefusal } {
    std.debug.assert(req.create);
    const refused: ?CreateRefusal = blk: {
        const exists = db.rawOne(i64, scope, "SELECT 1::bigint FROM datasets WHERE name = $1", .{req.dataset}) catch return error.Db;
        if (exists != null) break :blk .exists;
        const cfg = host_config orelse break :blk .no_host;
        _ = cfg.userIdOf(req.account) orelse break :blk .not_host_account;
        break :blk null;
    };
    _ = io;
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

/// Why creating a dataset was refused: what, and what to do next.
pub const Refused = struct {
    why: enum { other_host, not_an_account, not_maintainer, no_answer },
    what: []const u8,
    next: []const u8,
};

/// Whether a dataset may be created with this git URL, on a server that
/// takes access from a git host (docs/access.md): its repository must be
/// on that host, so cid and git agree from the start, and a person
/// creating it (`account`; null for the server's own token) must own that
/// repository there (GitLab Maintainer or Owner, GitHub Admin or
/// Maintain), asked live.
pub fn checkCreate(arena: std.mem.Allocator, io: std.Io, cfg: host_mod.Config, dataset: []const u8, git_url: []const u8, account: ?[]const u8) error{OutOfMemory}!?Refused {
    const where = cfg.hostName();
    const project = cfg.projectOf(git_url) orelse return .{
        .why = .other_host,
        .what = try std.fmt.allocPrint(arena, "this server takes access from {s}, and {s} is not a repository there", .{ where, git_url }),
        .next = try std.fmt.allocPrint(arena, "Create the dataset's repository on {s}, then run 'cid init' again with its URL.", .{where}),
    };
    const who = account orelse return null;
    const user_id = cfg.userIdOf(who) orelse return .{
        .why = .not_an_account,
        .what = try std.fmt.allocPrint(arena, "only {s} accounts can create datasets", .{cfg.kind().name()}),
        .next = try std.fmt.allocPrint(arena, "Ask the administrator to create {s}, then run 'cid clone' on it.", .{dataset}),
    };
    return switch (try cfg.maintainerOf(arena, io, project, user_id)) {
        .yes => null,
        .no => .{
            .why = .not_maintainer,
            .what = try std.fmt.allocPrint(arena, "creating {s} needs the {s} role on {s} on {s}", .{ dataset, switch (cfg.kind()) {
                .gitlab => "Maintainer",
                .github => "Admin or Maintain",
            }, project, where }),
            .next = "Ask the repository's owner for that role, then run 'cid init' again.",
        },
        .unknown => .{
            .why = .no_answer,
            .what = try std.fmt.allocPrint(arena, "{s} did not answer, so the server cannot check your role on {s}", .{ where, project }),
            .next = "Run 'cid init' again in a moment.",
        },
    };
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
    const gitlab = @import("gitlab_sync.zig");
    try std.testing.expectEqual(host_mod.Answer.yes, gitlab.judgeMember(a, 200, "{\"id\":7,\"access_level\":40}"));
    try std.testing.expectEqual(host_mod.Answer.yes, gitlab.judgeMember(a, 200, "{\"id\":7,\"access_level\":50}"));
    try std.testing.expectEqual(host_mod.Answer.no, gitlab.judgeMember(a, 200, "{\"id\":7,\"access_level\":30}"));
    try std.testing.expectEqual(host_mod.Answer.no, gitlab.judgeMember(a, 404, "{\"message\":\"404 Not found\"}"));
    try std.testing.expectEqual(host_mod.Answer.unknown, gitlab.judgeMember(a, 500, ""));
    try std.testing.expectEqual(@as(?u64, 42), host_mod.userId(.gitlab, "gitlab:42"));
    try std.testing.expectEqual(@as(?u64, null), host_mod.userId(.gitlab, "local:42"));
}
