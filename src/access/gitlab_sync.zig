//! GitLab sync (docs/access.md): who may do what comes from GitLab, so
//! there is nothing to manage in cid. For every dataset, the members of
//! the GitLab project its git URL names (projectOf) become access rows;
//! members' public SSH keys become ssh_keys rows. Removal works the same way:
//! gone from GitLab means gone here at the next sync.
//!
//! The JSON appliers are pure (fixture-testable); only `fetch` talks HTTP.

const std = @import("std");
const dbx = @import("../store/db.zig");
const keys_mod = @import("keys.zig");

pub const Error = error{ Db, GitLabUnreachable, BadResponse, OutOfMemory };

/// GitLab access levels: 10 guest, 20 reporter, 30 developer,
/// 40 maintainer, 50 owner. Reporter reads, Developer writes,
/// Maintainer maintains (CLAUDE.md, permissions).
pub fn levelFor(access_level: u32) ?[]const u8 {
    if (access_level >= 40) return "maintain";
    if (access_level >= 30) return "write";
    if (access_level >= 20) return "read";
    return null;
}

pub const Member = struct {
    id: u64,
    username: []const u8 = "",
    name: []const u8 = "",
    access_level: u32,
    state: []const u8 = "active",
};

pub const UserKey = struct {
    id: u64,
    key: []const u8,
    title: []const u8 = "",
};

pub const MemberOutcome = struct {
    upserted: u32 = 0,
    removed: u32 = 0,
};

/// Applies one project's member list to one dataset: accounts are
/// created or refreshed, access set to the mapped level, and
/// gitlab-sourced access rows for members no longer present are removed.
pub fn applyMembers(
    arena: std.mem.Allocator,
    db: *dbx.sql.Db,
    scope: anytype,
    dataset_name: []const u8,
    members: []const Member,
) Error!MemberOutcome {
    var outcome: MemberOutcome = .{};
    var keep_ids: std.ArrayList(u8) = .empty; // comma-joined for the removal query

    for (members) |m| {
        const level = levelFor(m.access_level) orelse continue;
        if (!std.mem.eql(u8, m.state, "active")) continue;
        const account = try accountId(arena, m.id);
        const display = if (m.name.len > 0) m.name else m.username;
        _ = db.exec(
            scope,
            "INSERT INTO accounts (account_id, display_name, source, synced_at) VALUES ($1, $2, 'gitlab', now()) " ++
                "ON CONFLICT (account_id) DO UPDATE SET display_name = excluded.display_name, synced_at = now()",
            .{ account, display },
        ) catch return error.Db;
        _ = db.exec(
            scope,
            "INSERT INTO access (dataset_id, account_id, level, source) " ++
                "SELECT d.dataset_id, $2, $3, 'gitlab' FROM datasets d WHERE d.name = $1 " ++
                "ON CONFLICT (dataset_id, account_id) DO UPDATE SET level = excluded.level, source = 'gitlab'",
            .{ dataset_name, account, level },
        ) catch return error.Db;
        outcome.upserted += 1;
        if (keep_ids.items.len > 0) try keep_ids.append(arena, ',');
        try keep_ids.appendSlice(arena, account);
    }

    // Removing someone from GitLab removes their cid access at the next
    // sync. Only gitlab-sourced rows: dashboard grants are not GitLab's.
    const removed = db.exec(
        scope,
        "DELETE FROM access a USING datasets d " ++
            "WHERE a.dataset_id = d.dataset_id AND d.name = $1 AND a.source = 'gitlab' " ++
            "AND a.account_id <> ALL (string_to_array($2, ','))",
        .{ dataset_name, keep_ids.items },
    ) catch return error.Db;
    outcome.removed = @intCast(removed);
    return outcome;
}

pub const KeyOutcome = struct {
    upserted: u32 = 0,
    removed: u32 = 0,
    skipped_invalid: u32 = 0,
};

/// Applies one user's key list: fingerprints computed here, stale
/// gitlab-synced keys for that account removed. Keys the person added in
/// the dashboard are theirs to remove and stay; GitLab, which keeps each
/// key on one account, wins a key some other account holds.
pub fn applyKeys(
    arena: std.mem.Allocator,
    db: *dbx.sql.Db,
    scope: anytype,
    gitlab_user_id: u64,
    user_keys: []const UserKey,
) Error!KeyOutcome {
    const account = try accountId(arena, gitlab_user_id);
    var outcome: KeyOutcome = .{};
    var keep: std.ArrayList(u8) = .empty;

    for (user_keys) |k| {
        const fp = keys_mod.fingerprint(arena, k.key) orelse {
            outcome.skipped_invalid += 1;
            continue;
        };
        _ = db.exec(
            scope,
            "INSERT INTO ssh_keys (fingerprint, account_id, public_key, title, source, synced_at) VALUES ($1, $2, $3, $4, 'gitlab', now()) " ++
                "ON CONFLICT (fingerprint) DO UPDATE SET account_id = excluded.account_id, " ++
                "public_key = excluded.public_key, title = excluded.title, source = 'gitlab', synced_at = now()",
            .{ fp, account, k.key, k.title },
        ) catch return error.Db;
        outcome.upserted += 1;
        if (keep.items.len > 0) try keep.append(arena, ',');
        try keep.appendSlice(arena, fp);
    }

    const removed = db.exec(
        scope,
        "DELETE FROM ssh_keys WHERE account_id = $1 AND source = 'gitlab' " ++
            "AND fingerprint <> ALL (string_to_array($2, ','))",
        .{ account, keep.items },
    ) catch return error.Db;
    outcome.removed = @intCast(removed);
    return outcome;
}

fn accountId(arena: std.mem.Allocator, gitlab_user_id: u64) Error![]const u8 {
    return std.fmt.allocPrint(arena, "gitlab:{d}", .{gitlab_user_id}) catch
        error.OutOfMemory;
}

pub fn parseMembers(arena: std.mem.Allocator, json: []const u8) Error![]const Member {
    return std.json.parseFromSliceLeaky([]const Member, arena, json, .{ .ignore_unknown_fields = true }) catch
        error.BadResponse;
}

pub fn parseKeys(arena: std.mem.Allocator, json: []const u8) Error![]const UserKey {
    return std.json.parseFromSliceLeaky([]const UserKey, arena, json, .{ .ignore_unknown_fields = true }) catch
        error.BadResponse;
}

// ---------------------------------------------------------------------------
// The HTTP side: GET with PRIVATE-TOKEN, following GitLab's page numbers.
// ---------------------------------------------------------------------------

pub const Config = struct {
    base_url: []const u8, // e.g. https://gitlab.com
    token: []const u8, // read_api scope
};

pub fn fetchPaged(
    arena: std.mem.Allocator,
    io: std.Io,
    config: Config,
    comptime path_fmt: []const u8,
    args: anytype,
) Error![]const u8 {
    var http: std.http.Client = .{ .allocator = arena, .io = io };
    defer http.deinit();

    // Join pages into one JSON array: strip the brackets per page.
    var joined: std.ArrayList(u8) = .empty;
    try joined.append(arena, '[');
    var page: u32 = 1;
    while (page < 100) : (page += 1) {
        const url = try std.fmt.allocPrint(arena, "{s}" ++ path_fmt ++ "?per_page=100&page={d}", .{config.base_url} ++ args ++ .{page});
        var aw: std.Io.Writer.Allocating = .init(arena);
        const res = http.fetch(.{
            .location = .{ .url = url },
            .raw_uri = true,
            .keep_alive = false,
            .response_writer = &aw.writer,
            .extra_headers = &.{.{ .name = "PRIVATE-TOKEN", .value = config.token }},
        }) catch return error.GitLabUnreachable;
        if (res.status != .ok) return error.BadResponse;
        const body = std.mem.trim(u8, aw.writer.buffered(), " \n");
        if (body.len < 2 or body[0] != '[') return error.BadResponse;
        const inner = std.mem.trim(u8, body[1 .. body.len - 1], " \n");
        if (inner.len == 0) break;
        if (joined.items.len > 1) try joined.append(arena, ',');
        try joined.appendSlice(arena, inner);
        if (std.mem.count(u8, body, "\"id\"") < 100) break; // short page: done
    }
    try joined.append(arena, ']');
    return joined.items;
}

/// One GET of a single object, for an answer whose status matters as
/// much as its body (a 404 that means "not protected"). The body is
/// whatever came back, read in full.
pub fn fetchOne(
    arena: std.mem.Allocator,
    io: std.Io,
    config: Config,
    comptime path_fmt: []const u8,
    args: anytype,
) Error!struct { status: u16, body: []const u8 } {
    var http: std.http.Client = .{ .allocator = arena, .io = io };
    defer http.deinit();
    const url = try std.fmt.allocPrint(arena, "{s}" ++ path_fmt, .{config.base_url} ++ args);
    var aw: std.Io.Writer.Allocating = .init(arena);
    const res = http.fetch(.{
        .location = .{ .url = url },
        .raw_uri = true,
        .keep_alive = false,
        .response_writer = &aw.writer,
        .extra_headers = &.{.{ .name = "PRIVATE-TOKEN", .value = config.token }},
    }) catch return error.GitLabUnreachable;
    return .{ .status = @intFromEnum(res.status), .body = aw.writer.buffered() };
}

/// Everything, for every dataset: members of the project its git URL
/// names, then each member's keys. Datasets whose project cannot be read are reported
/// and skipped — one broken project never stops the sync.
pub const SyncOutcome = struct {
    datasets: u32 = 0,
    datasets_failed: u32 = 0,
    members: u32 = 0,
    access_removed: u32 = 0,
    keys: u32 = 0,
    keys_removed: u32 = 0,
};

pub fn syncAll(
    arena: std.mem.Allocator,
    io: std.Io,
    db: *dbx.sql.Db,
    scope: anytype,
    config: Config,
) Error!SyncOutcome {
    const Row = struct {
        pub const nilo_table = .projection;
        name: []const u8,
        git_url: []const u8,
    };
    const rows = db.raw(Row, scope, "SELECT name, git_url FROM datasets ORDER BY name", .{}) catch
        return error.Db;

    var outcome: SyncOutcome = .{};
    var synced_users: std.ArrayList(u64) = .empty;

    for (rows) |row| {
        const dataset_name = row.name;
        // Datasets made before this server took access from GitLab, or by
        // hand on another host, have no project here: theirs is hand-granted.
        const project = projectOf(row.git_url, config.base_url) orelse {
            std.log.info("gitlab sync: {s}'s repository is not on {s}; its access is granted by hand", .{ dataset_name, hostOf(config.base_url) });
            continue;
        };
        const encoded = try urlEncodePath(arena, project);
        const json = fetchPaged(arena, io, config, "/api/v4/projects/{s}/members/all", .{encoded}) catch {
            std.log.warn("gitlab sync: cannot read members of {s}; skipped", .{dataset_name});
            outcome.datasets_failed += 1;
            continue;
        };
        const members = try parseMembers(arena, json);
        const applied = try applyMembers(arena, db, scope, dataset_name, members);
        outcome.datasets += 1;
        outcome.members += applied.upserted;
        outcome.access_removed += applied.removed;

        for (members) |m| {
            var seen = false;
            for (synced_users.items) |u| {
                if (u == m.id) {
                    seen = true;
                    break;
                }
            }
            if (seen) continue;
            try synced_users.append(arena, m.id);
            const keys_json = fetchPaged(arena, io, config, "/api/v4/users/{d}/keys", .{m.id}) catch continue;
            const user_keys = try parseKeys(arena, keys_json);
            const key_applied = try applyKeys(arena, db, scope, m.id, user_keys);
            outcome.keys += key_applied.upserted;
            outcome.keys_removed += key_applied.removed;
        }
    }
    return outcome;
}

/// The project a dataset's git repository is, on the GitLab at
/// `base_url`: access comes from the repository its `--git` URL names
/// (docs/access.md). Null for a repository on another host, or a local
/// path, which this GitLab knows nothing about. Takes the forms git takes:
/// `git@host:org/x.git`, `ssh://git@host:2222/org/x.git`,
/// `https://host/org/x.git`; a GitLab served under a path
/// (`https://example.com/gitlab`) has that path left off its projects.
pub fn projectOf(git_url: []const u8, base_url: []const u8) ?[]const u8 {
    const base = splitUrl(base_url) orelse return null;
    const repo: Split = if (std.mem.indexOf(u8, git_url, "://") != null)
        splitUrl(git_url) orelse return null
    else blk: {
        // scp-like: [user@]host:path, the colon before any slash.
        const colon = std.mem.indexOfScalar(u8, git_url, ':') orelse return null;
        if (std.mem.indexOfScalar(u8, git_url[0..colon], '/') != null) return null;
        const at = if (std.mem.lastIndexOfScalar(u8, git_url[0..colon], '@')) |i| i + 1 else 0;
        break :blk .{ .host = git_url[at..colon], .path = git_url[colon + 1 ..] };
    };
    if (!std.ascii.eqlIgnoreCase(repo.host, base.host)) return null;
    var path = std.mem.trim(u8, repo.path, "/");
    const prefix = std.mem.trim(u8, base.path, "/");
    if (prefix.len > 0) {
        if (std.mem.startsWith(u8, path, prefix) and path.len > prefix.len and path[prefix.len] == '/')
            path = path[prefix.len + 1 ..];
    }
    if (std.mem.endsWith(u8, path, ".git")) path = path[0 .. path.len - ".git".len];
    path = std.mem.trimEnd(u8, path, "/");
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, '/') == null) return null;
    return path;
}

/// The host of a URL or git URL, for messages ("gitlab.example").
pub fn hostOf(url: []const u8) []const u8 {
    return (splitUrl(url) orelse return url).host;
}

const Split = struct { host: []const u8, path: []const u8 };

/// scheme://[user@]host[:port][/path] → host (no port) and path.
fn splitUrl(url: []const u8) ?Split {
    const scheme_end = (std.mem.indexOf(u8, url, "://") orelse return null) + 3;
    const rest = url[scheme_end..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    var authority = rest[0..slash];
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority = authority[at + 1 ..];
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| authority = authority[0..colon];
    if (authority.len == 0) return null;
    return .{ .host = authority, .path = rest[slash..] };
}

test "a dataset's project is the repository its git URL names, on this GitLab only" {
    const base = "https://gitlab.example";
    const cases = [_][2][]const u8{
        .{ "git@gitlab.example:org/datasets/x.git", "org/datasets/x" },
        .{ "ssh://git@gitlab.example:2222/org/datasets/x.git", "org/datasets/x" },
        .{ "https://gitlab.example/org/x.git", "org/x" },
        .{ "https://ci:token@GitLab.Example/org/x", "org/x" },
        .{ "gitlab.example:org/x.git/", "org/x" },
    };
    for (cases) |c| try std.testing.expectEqualStrings(c[1], projectOf(c[0], base).?);
    for ([_][]const u8{
        "git@github.com:org/x.git",
        "https://gitlab.example.evil.com/org/x.git",
        "/srv/git/x.git",
        "file:///srv/git/x.git",
        "git@gitlab.example:x.git",
    }) |other| try std.testing.expect(projectOf(other, base) == null);
    // A GitLab served under a path: its projects are below it.
    try std.testing.expectEqualStrings("org/x", projectOf("https://example.com/gitlab/org/x.git", "https://example.com/gitlab").?);
    try std.testing.expectEqualStrings("org/x", projectOf("git@example.com:org/x.git", "https://example.com/gitlab").?);
    try std.testing.expectEqualStrings("gitlab.example", hostOf("https://gitlab.example:8443/x"));
}

/// GitLab wants the project path URL-encoded, '/' included (%2F).
pub fn urlEncodePath(arena: std.mem.Allocator, path: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (path) |ch| {
        switch (ch) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.' => try out.append(arena, ch),
            else => try out.print(arena, "%{X:0>2}", .{ch}),
        }
    }
    return out.items;
}

test "gitlab access levels map to cid levels" {
    try std.testing.expectEqualStrings("maintain", levelFor(50).?);
    try std.testing.expectEqualStrings("maintain", levelFor(40).?);
    try std.testing.expectEqualStrings("write", levelFor(30).?);
    try std.testing.expectEqualStrings("read", levelFor(20).?);
    try std.testing.expect(levelFor(10) == null);
}

test "member and key JSON parse with unknown fields ignored" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const members = try parseMembers(arena,
        \\[{"id":42,"username":"ada","name":"Ada L","access_level":30,"state":"active","web_url":"x"},
        \\ {"id":43,"username":"bot","access_level":10}]
    );
    try std.testing.expectEqual(@as(usize, 2), members.len);
    try std.testing.expectEqual(@as(u64, 42), members[0].id);
    try std.testing.expectEqual(@as(u32, 30), members[0].access_level);

    const user_keys = try parseKeys(arena,
        \\[{"id":1,"title":"laptop","key":"ssh-ed25519 AAAA x","created_at":"2026"}]
    );
    try std.testing.expectEqual(@as(usize, 1), user_keys.len);
}

test "project path encoding" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings(
        "org%2Fdatasets%2Fperson-vehicle",
        try urlEncodePath(arena_state.allocator(), "org/datasets/person-vehicle"),
    );
}
