//! The host a server takes access from (docs/access.md, "Other git
//! hosts"): GitLab or GitHub, one per server. Each adapter does four
//! things: a repository's members with their levels (the sync), one
//! person's level on a repository asked live (creating a dataset), a
//! person's public SSH keys (the sync), and sign-in (server/signin.zig).
//! What the adapters share lives here: the accounts, access rows and keys
//! a sync writes, named after the host ('gitlab:42', source 'gitlab'),
//! and the words a person reads about the host and its roles.

const std = @import("std");
const dbx = @import("../store/db.zig");
const keys_mod = @import("keys.zig");
const gitlab = @import("gitlab_sync.zig");
const github = @import("github_sync.zig");

pub const Kind = enum {
    gitlab,
    github,

    /// The host's own name, as people write it.
    pub fn name(k: Kind) []const u8 {
        return switch (k) {
            .gitlab => "GitLab",
            .github => "GitHub",
        };
    }

    /// The host's role that gives a cid level, as its people know it.
    pub fn role(k: Kind, level: []const u8) []const u8 {
        const gl = std.meta.stringToEnum(enum { read, write, maintain }, level) orelse return level;
        return switch (k) {
            .gitlab => switch (gl) {
                .read => "Reporter",
                .write => "Developer",
                .maintain => "Maintainer",
            },
            .github => switch (gl) {
                .read => "Read",
                .write => "Write",
                .maintain => "Maintain",
            },
        };
    }
};

/// One server's host and how to reach it.
pub const Config = union(Kind) {
    gitlab: gitlab.Config,
    github: github.Config,

    pub fn kind(c: Config) Kind {
        return std.meta.activeTag(c);
    }

    /// Where people reach the host, for messages: "gitlab.com".
    pub fn hostName(c: Config) []const u8 {
        return switch (c) {
            .gitlab => |g| gitlab.hostOf(g.base_url),
            .github => |g| gitlab.hostOf(g.web_url),
        };
    }

    /// The repository a dataset's git URL names on this host, or null for
    /// a repository elsewhere (its access is granted by hand).
    pub fn projectOf(c: Config, git_url: []const u8) ?[]const u8 {
        return switch (c) {
            .gitlab => |g| gitlab.projectOf(git_url, g.base_url),
            .github => |g| github.repoOf(git_url, g.web_url),
        };
    }

    /// Whether a person (their account's id on this host) is an owner of
    /// the repository, asked live.
    pub fn maintainerOf(c: Config, arena: std.mem.Allocator, io: std.Io, project: []const u8, user_id: u64) error{OutOfMemory}!Answer {
        return switch (c) {
            .gitlab => |g| gitlab.maintainerOf(arena, io, g, project, user_id),
            .github => |g| github.maintainerOf(arena, io, g, project, user_id),
        };
    }

    /// Members and keys of every dataset's repository, written as access.
    pub fn syncAll(c: Config, arena: std.mem.Allocator, io: std.Io, db: *dbx.sql.Db, scope: anytype) SyncError!SyncOutcome {
        return switch (c) {
            .gitlab => |g| gitlab.syncAll(arena, io, db, scope, g),
            .github => |g| github.syncAll(arena, io, db, scope, g),
        };
    }

    /// The host's account id for a person on it: `gitlab:42`.
    pub fn userIdOf(c: Config, account: []const u8) ?u64 {
        return userId(c.kind(), account);
    }
};

/// The host this server takes access from, as its environment names it:
/// CID_GITLAB_TOKEN (and CID_GITLAB_URL, default https://gitlab.com) or
/// CID_GITHUB_TOKEN (and CID_GITHUB_URL, default https://github.com); none
/// is the manual tier. Both is refused: one host per server.
pub fn fromEnv(arena: std.mem.Allocator, env: anytype) error{ BothHosts, OutOfMemory }!?Config {
    const gl = env.get("CID_GITLAB_TOKEN");
    const gh = env.get("CID_GITHUB_TOKEN");
    if (gl != null and gh != null) return error.BothHosts;
    if (gl) |t| return .{ .gitlab = .{ .base_url = env.get("CID_GITLAB_URL") orelse "https://gitlab.com", .token = t } };
    if (gh) |t| return .{ .github = try github.Config.of(arena, env.get("CID_GITHUB_URL") orelse "https://github.com", t) };
    return null;
}

/// What to do when both hosts are set.
pub const both_hosts_message = "both CID_GITLAB_TOKEN and CID_GITHUB_TOKEN are set; a server takes access from one host. Unset one, then start it again.";

pub const Answer = enum { yes, no, unknown };

pub const SyncError = error{ Db, HostUnreachable, BadResponse, OutOfMemory };

/// Everything, for every dataset: datasets whose repository cannot be read
/// are reported and skipped; one broken repository never stops the sync.
pub const SyncOutcome = struct {
    datasets: u32 = 0,
    datasets_failed: u32 = 0,
    members: u32 = 0,
    access_removed: u32 = 0,
    keys: u32 = 0,
    keys_removed: u32 = 0,
};

/// `<host>:<user id>`, the account a person on the host is here.
pub fn accountId(arena: std.mem.Allocator, kind: Kind, user_id: u64) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(arena, "{t}:{d}", .{ kind, user_id });
}

/// The user id of a `<host>:<id>` account on this host, or null.
pub fn userId(kind: Kind, account: []const u8) ?u64 {
    const prefix = @tagName(kind);
    if (!std.mem.startsWith(u8, account, prefix) or account.len <= prefix.len or account[prefix.len] != ':') return null;
    return std.fmt.parseInt(u64, account[prefix.len + 1 ..], 10) catch null;
}

/// A repository member, as an adapter reads it: their id on the host, the
/// name people see, and the cid level their role gives.
pub const Member = struct { id: u64, display: []const u8, level: []const u8 };

/// A person's public key on the host.
pub const Key = struct { key: []const u8, title: []const u8 = "" };

pub const MemberOutcome = struct { upserted: u32 = 0, removed: u32 = 0 };

/// Applies one repository's members to one dataset: accounts created or
/// refreshed, access set to their level, and this host's access rows for
/// people no longer members removed. Rows granted by hand or to deploy
/// keys are not the host's, and stay.
pub fn applyMembers(arena: std.mem.Allocator, db: *dbx.sql.Db, scope: anytype, kind: Kind, dataset_name: []const u8, members: []const Member) SyncError!MemberOutcome {
    var outcome: MemberOutcome = .{};
    var keep: std.ArrayList(u8) = .empty; // comma-joined for the removal query
    const source = @tagName(kind);
    for (members) |m| {
        const account = try accountId(arena, kind, m.id);
        _ = db.exec(scope, "INSERT INTO accounts (account_id, display_name, source, synced_at) VALUES ($1, $2, $3, now()) " ++
            "ON CONFLICT (account_id) DO UPDATE SET display_name = excluded.display_name, synced_at = now()", .{ account, m.display, source }) catch return error.Db;
        _ = db.exec(scope, "INSERT INTO access (dataset_id, account_id, level, source) " ++
            "SELECT d.dataset_id, $2, $3, $4 FROM datasets d WHERE d.name = $1 " ++
            "ON CONFLICT (dataset_id, account_id) DO UPDATE SET level = excluded.level, source = excluded.source", .{ dataset_name, account, m.level, source }) catch return error.Db;
        outcome.upserted += 1;
        if (keep.items.len > 0) try keep.append(arena, ',');
        try keep.appendSlice(arena, account);
    }
    const removed = db.exec(scope, "DELETE FROM access a USING datasets d " ++
        "WHERE a.dataset_id = d.dataset_id AND d.name = $1 AND a.source = $3 " ++
        "AND a.account_id <> ALL (string_to_array($2, ','))", .{ dataset_name, keep.items, source }) catch return error.Db;
    outcome.removed = @intCast(removed);
    return outcome;
}

pub const KeyOutcome = struct { upserted: u32 = 0, removed: u32 = 0, skipped_invalid: u32 = 0 };

/// Applies one person's keys on the host: fingerprints computed here, the
/// host's stale keys for that account removed. Keys the person added in
/// the dashboard stay theirs; the host, which keeps each key on one
/// account, wins a key some other account holds.
pub fn applyKeys(arena: std.mem.Allocator, db: *dbx.sql.Db, scope: anytype, kind: Kind, user_id: u64, user_keys: []const Key) SyncError!KeyOutcome {
    const account = try accountId(arena, kind, user_id);
    const source = @tagName(kind);
    var outcome: KeyOutcome = .{};
    var keep: std.ArrayList(u8) = .empty;
    for (user_keys) |k| {
        const fp = keys_mod.fingerprint(arena, k.key) orelse {
            outcome.skipped_invalid += 1;
            continue;
        };
        _ = db.exec(scope, "INSERT INTO ssh_keys (fingerprint, account_id, public_key, title, source, synced_at) VALUES ($1, $2, $3, $4, $5, now()) " ++
            "ON CONFLICT (fingerprint) DO UPDATE SET account_id = excluded.account_id, " ++
            "public_key = excluded.public_key, title = excluded.title, source = excluded.source, synced_at = now()", .{ fp, account, k.key, k.title, source }) catch return error.Db;
        outcome.upserted += 1;
        if (keep.items.len > 0) try keep.append(arena, ',');
        try keep.appendSlice(arena, fp);
    }
    const removed = db.exec(scope, "DELETE FROM ssh_keys WHERE account_id = $1 AND source = $3 " ++
        "AND fingerprint <> ALL (string_to_array($2, ','))", .{ account, keep.items, source }) catch return error.Db;
    outcome.removed = @intCast(removed);
    return outcome;
}

test "accounts and role words, per host" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings("github:42", try accountId(arena_state.allocator(), .github, 42));
    try std.testing.expectEqual(@as(?u64, 42), userId(.gitlab, "gitlab:42"));
    try std.testing.expectEqual(@as(?u64, null), userId(.github, "gitlab:42"));
    try std.testing.expectEqual(@as(?u64, null), userId(.github, "githubx:42"));
    try std.testing.expectEqualStrings("Maintainer", Kind.gitlab.role("maintain"));
    try std.testing.expectEqualStrings("Write", Kind.github.role("write"));
}
