//! GitLab sync (docs/access.md): who may do what comes from GitLab, so
//! there is nothing to manage in cid. For every dataset, the members of
//! the GitLab project with the same path become access rows; members'
//! public SSH keys become ssh_keys rows. Removal works the same way:
//! gone from GitLab means gone here at the next sync.
//!
//! The JSON appliers are pure (fixture-testable); only `fetch` talks HTTP.

const std = @import("std");
const pg = @import("../store/pg.zig");
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
    db: *pg.Db,
    dataset_name: []const u8,
    members: []const Member,
) Error!MemberOutcome {
    const dataset_z = arena.dupeZ(u8, dataset_name) catch return error.OutOfMemory;
    var outcome: MemberOutcome = .{};
    var keep_ids: std.ArrayList(u8) = .empty; // comma-joined for the removal query

    for (members) |m| {
        const level = levelFor(m.access_level) orelse continue;
        if (!std.mem.eql(u8, m.state, "active")) continue;
        const account = try accountId(arena, m.id);
        const display = if (m.name.len > 0) m.name else m.username;
        db.execParams(
            "INSERT INTO accounts (account_id, display_name, source, synced_at) VALUES ($1, $2, 'gitlab', now()) " ++
                "ON CONFLICT (account_id) DO UPDATE SET display_name = excluded.display_name, synced_at = now()",
            &.{ account, arena.dupeZ(u8, display) catch return error.OutOfMemory },
            null,
        ) catch return error.Db;
        db.execParams(
            "INSERT INTO access (dataset_id, account_id, level, source) " ++
                "SELECT d.dataset_id, $2, $3, 'gitlab' FROM datasets d WHERE d.name = $1 " ++
                "ON CONFLICT (dataset_id, account_id) DO UPDATE SET level = excluded.level, source = 'gitlab'",
            &.{ dataset_z, account, arena.dupeZ(u8, level) catch return error.OutOfMemory },
            null,
        ) catch return error.Db;
        outcome.upserted += 1;
        if (keep_ids.items.len > 0) try keep_ids.append(arena, ',');
        try keep_ids.appendSlice(arena, account);
    }

    // Removing someone from GitLab removes their cid access at the next
    // sync. Only gitlab-sourced rows: dashboard grants are not GitLab's.
    const keep_z = arena.dupeZ(u8, keep_ids.items) catch return error.OutOfMemory;
    var removed = db.query(
        "DELETE FROM access a USING datasets d " ++
            "WHERE a.dataset_id = d.dataset_id AND d.name = $1 AND a.source = 'gitlab' " ++
            "AND a.account_id <> ALL (string_to_array($2, ',')) RETURNING a.account_id",
        &.{ dataset_z, keep_z },
        null,
    ) catch return error.Db;
    defer removed.deinit();
    outcome.removed = @intCast(removed.count());
    return outcome;
}

pub const KeyOutcome = struct {
    upserted: u32 = 0,
    removed: u32 = 0,
    skipped_invalid: u32 = 0,
};

/// Applies one user's key list: fingerprints computed here, stale
/// gitlab-synced keys for that account removed.
pub fn applyKeys(
    arena: std.mem.Allocator,
    db: *pg.Db,
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
        db.execParams(
            "INSERT INTO ssh_keys (fingerprint, account_id, public_key, synced_at) VALUES ($1, $2, $3, now()) " ++
                "ON CONFLICT (fingerprint) DO UPDATE SET account_id = excluded.account_id, " ++
                "public_key = excluded.public_key, synced_at = now()",
            &.{
                arena.dupeZ(u8, fp) catch return error.OutOfMemory,
                account,
                arena.dupeZ(u8, k.key) catch return error.OutOfMemory,
            },
            null,
        ) catch return error.Db;
        outcome.upserted += 1;
        if (keep.items.len > 0) try keep.append(arena, ',');
        try keep.appendSlice(arena, fp);
    }

    const keep_z = arena.dupeZ(u8, keep.items) catch return error.OutOfMemory;
    var removed = db.query(
        "DELETE FROM ssh_keys WHERE account_id = $1 " ++
            "AND fingerprint <> ALL (string_to_array($2, ',')) RETURNING fingerprint",
        &.{ account, keep_z },
        null,
    ) catch return error.Db;
    defer removed.deinit();
    outcome.removed = @intCast(removed.count());
    return outcome;
}

fn accountId(arena: std.mem.Allocator, gitlab_user_id: u64) Error![:0]const u8 {
    return std.fmt.allocPrintSentinel(arena, "gitlab:{d}", .{gitlab_user_id}, 0) catch
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

/// Everything, for every dataset: members of the same-path project, then
/// each member's keys. Datasets whose project cannot be read are reported
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
    db: *pg.Db,
    config: Config,
) Error!SyncOutcome {
    var names = db.query("SELECT name FROM datasets ORDER BY name", &.{}, null) catch return error.Db;
    defer names.deinit();

    var outcome: SyncOutcome = .{};
    var synced_users: std.ArrayList(u64) = .empty;

    var i: usize = 0;
    while (i < names.count()) : (i += 1) {
        const dataset_name = arena.dupe(u8, names.get(i, 0)) catch return error.OutOfMemory;
        const encoded = try urlEncodePath(arena, dataset_name);
        const json = fetchPaged(arena, io, config, "/api/v4/projects/{s}/members/all", .{encoded}) catch {
            std.log.warn("gitlab sync: cannot read members of {s}; skipped", .{dataset_name});
            outcome.datasets_failed += 1;
            continue;
        };
        const members = try parseMembers(arena, json);
        const applied = try applyMembers(arena, db, dataset_name, members);
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
            const key_applied = try applyKeys(arena, db, m.id, user_keys);
            outcome.keys += key_applied.upserted;
            outcome.keys_removed += key_applied.removed;
        }
    }
    return outcome;
}

/// GitLab wants the project path URL-encoded, '/' included (%2F).
fn urlEncodePath(arena: std.mem.Allocator, path: []const u8) Error![]const u8 {
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
