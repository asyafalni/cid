//! GitHub as the host a server takes access from (docs/access.md, "Other
//! git hosts"): the collaborators of the repository a dataset's git URL
//! names become access rows, with the level their role gives; their
//! public SSH keys become ssh_keys rows; and creating a dataset needs Admin
//! or Maintain on its repository, asked live. Read with one fine-grained
//! token ('Metadata: read' on the repositories), CID_GITHUB_TOKEN.
//!
//! The JSON readers are pure (fixture-testable); only `fetch*` talk HTTP.

const std = @import("std");
const dbx = @import("../store/db.zig");
const host = @import("host.zig");
const gitlab = @import("gitlab_sync.zig");

pub const Error = host.SyncError;

pub const Config = struct {
    /// Where people and git reach GitHub: https://github.com, or a GitHub
    /// Enterprise Server's address.
    web_url: []const u8,
    /// Its REST API: https://api.github.com, or <web>/api/v3 on a server.
    api_url: []const u8,
    token: []const u8,

    /// A configuration from the address people use (CID_GITHUB_URL).
    pub fn of(arena: std.mem.Allocator, web_url: []const u8, token: []const u8) error{OutOfMemory}!Config {
        const web = std.mem.trimEnd(u8, web_url, "/");
        const api = if (std.ascii.eqlIgnoreCase(gitlab.hostOf(web), "github.com"))
            "https://api.github.com"
        else
            try std.fmt.allocPrint(arena, "{s}/api/v3", .{web});
        return .{ .web_url = web, .api_url = api, .token = token };
    }
};

/// A repository's collaborator, as GitHub lists them: their base role as
/// flags, whatever the role is called (custom roles included).
pub const Collaborator = struct {
    id: u64,
    login: []const u8,
    permissions: struct {
        admin: bool = false,
        maintain: bool = false,
        push: bool = false,
        triage: bool = false,
        pull: bool = false,
    } = .{},
};

/// Admin and Maintain maintain, Write writes, Triage and Read read.
pub fn levelFor(c: Collaborator) ?[]const u8 {
    const p = c.permissions;
    if (p.admin or p.maintain) return "maintain";
    if (p.push) return "write";
    if (p.triage or p.pull) return "read";
    return null;
}

pub fn parseCollaborators(arena: std.mem.Allocator, json: []const u8) Error![]const Collaborator {
    return std.json.parseFromSliceLeaky([]const Collaborator, arena, json, .{ .ignore_unknown_fields = true }) catch error.BadResponse;
}

/// A GitHub user's public key: GitHub gives no title.
pub const UserKey = struct { id: u64 = 0, key: []const u8 };

pub fn parseKeys(arena: std.mem.Allocator, json: []const u8) Error![]const UserKey {
    return std.json.parseFromSliceLeaky([]const UserKey, arena, json, .{ .ignore_unknown_fields = true }) catch error.BadResponse;
}

/// `owner/name`, the repository a git URL names on this GitHub, or null:
/// another host, or a path that is not exactly owner and name.
pub fn repoOf(git_url: []const u8, web_url: []const u8) ?[]const u8 {
    const path = gitlab.projectOf(git_url, web_url) orelse return null;
    return if (std.mem.count(u8, path, "/") == 1) path else null;
}

// ---------------------------------------------------------------------------
// The HTTP side: GitHub's REST API, its headers, its page numbers.
// ---------------------------------------------------------------------------

/// Every array page of `path` (which may carry its own query), joined.
pub fn fetchPaged(arena: std.mem.Allocator, io: std.Io, config: Config, path: []const u8) Error![]const u8 {
    var http: std.http.Client = .{ .allocator = arena, .io = io };
    defer http.deinit();
    var joined: std.ArrayList(u8) = .empty;
    try joined.append(arena, '[');
    const sep: u8 = if (std.mem.indexOfScalar(u8, path, '?') != null) '&' else '?';
    var page: u32 = 1;
    while (page < 100) : (page += 1) {
        const url = try std.fmt.allocPrint(arena, "{s}{s}{c}per_page=100&page={d}", .{ config.api_url, path, sep, page });
        const got = try get(arena, &http, config, url);
        if (got.status != 200) return error.BadResponse;
        const body = std.mem.trim(u8, got.body, " \n");
        if (body.len < 2 or body[0] != '[') return error.BadResponse;
        const inner = std.mem.trim(u8, body[1 .. body.len - 1], " \n");
        if (inner.len == 0) break;
        if (joined.items.len > 1) try joined.append(arena, ',');
        try joined.appendSlice(arena, inner);
        // Each entry has one "id" at its top: a short page is the last.
        const Entry = struct { id: u64 = 0 };
        const entries = std.json.parseFromSliceLeaky([]const Entry, arena, body, .{ .ignore_unknown_fields = true }) catch return error.BadResponse;
        if (entries.len < 100) break;
    }
    try joined.append(arena, ']');
    return joined.items;
}

/// An answer whose status matters as much as its body.
pub const Got = struct { status: u16, body: []const u8 };

/// One GET.
pub fn fetchOne(arena: std.mem.Allocator, io: std.Io, config: Config, path: []const u8) Error!Got {
    var http: std.http.Client = .{ .allocator = arena, .io = io };
    defer http.deinit();
    return get(arena, &http, config, try std.fmt.allocPrint(arena, "{s}{s}", .{ config.api_url, path }));
}

fn get(arena: std.mem.Allocator, http: *std.http.Client, config: Config, url: []const u8) Error!Got {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const auth = try std.fmt.allocPrint(arena, "Bearer {s}", .{config.token});
    const res = http.fetch(.{
        .location = .{ .url = url },
        .raw_uri = true,
        .keep_alive = false,
        .response_writer = &aw.writer,
        // GitHub refuses a request without a User-Agent.
        .headers = .{ .user_agent = .{ .override = "cid" } },
        .extra_headers = &.{
            .{ .name = "Accept", .value = "application/vnd.github+json" },
            .{ .name = "X-GitHub-Api-Version", .value = "2022-11-28" },
        },
        // Dropped if a redirect leaves the host.
        .privileged_headers = &.{.{ .name = "Authorization", .value = auth }},
    }) catch return error.HostUnreachable;
    return .{ .status = @backingInt(res.status), .body = aw.writer.buffered() };
}

/// Every dataset's repository: its collaborators (direct, through teams
/// and as organization owners: `affiliation=all`), then each one's keys.
pub fn syncAll(arena: std.mem.Allocator, io: std.Io, db: *dbx.sql.Db, scope: anytype, config: Config) Error!host.SyncOutcome {
    const Row = struct {
        pub const nilo_table = .projection;
        name: []const u8,
        git_url: []const u8,
    };
    const rows = db.raw(Row, scope, "SELECT name, git_url FROM datasets ORDER BY name", .{}) catch return error.Db;
    var outcome: host.SyncOutcome = .{};
    var synced: std.ArrayList(u64) = .empty;
    for (rows) |row| {
        const repo = repoOf(row.git_url, config.web_url) orelse {
            std.log.info("github sync: {s}'s repository is not on {s}; its access is granted by hand", .{ row.name, gitlab.hostOf(config.web_url) });
            continue;
        };
        const json = fetchPaged(arena, io, config, try std.fmt.allocPrint(arena, "/repos/{s}/collaborators?affiliation=all", .{repo})) catch {
            std.log.warn("github sync: cannot read the collaborators of {s}; skipped", .{row.name});
            outcome.datasets_failed += 1;
            continue;
        };
        const collaborators = try parseCollaborators(arena, json);
        var members: std.ArrayList(host.Member) = .empty;
        for (collaborators) |c| {
            const level = levelFor(c) orelse continue;
            try members.append(arena, .{ .id = c.id, .display = c.login, .level = level });
        }
        const applied = try host.applyMembers(arena, db, scope, .github, row.name, members.items);
        outcome.datasets += 1;
        outcome.members += applied.upserted;
        outcome.access_removed += applied.removed;

        for (collaborators) |c| {
            if (std.mem.indexOfScalar(u64, synced.items, c.id) != null) continue;
            try synced.append(arena, c.id);
            const keys_json = fetchPaged(arena, io, config, try std.fmt.allocPrint(arena, "/users/{s}/keys", .{c.login})) catch continue;
            const user_keys = try parseKeys(arena, keys_json);
            const keys = try arena.alloc(host.Key, user_keys.len);
            for (keys, user_keys) |*k, u| k.* = .{ .key = u.key };
            const applied_keys = try host.applyKeys(arena, db, scope, .github, c.id, keys);
            outcome.keys += applied_keys.upserted;
            outcome.keys_removed += applied_keys.removed;
        }
    }
    return outcome;
}

/// Whether a GitHub user (by id) holds Admin or Maintain on `repo`
/// (owner/name), asked live: their login first, then their permission.
pub fn maintainerOf(arena: std.mem.Allocator, io: std.Io, config: Config, repo: []const u8, user_id: u64) error{OutOfMemory}!host.Answer {
    const user = fetchOne(arena, io, config, try std.fmt.allocPrint(arena, "/user/{d}", .{user_id})) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .unknown,
    };
    if (user.status == 404) return .no;
    if (user.status != 200) return .unknown;
    const User = struct { login: []const u8 };
    const who = std.json.parseFromSliceLeaky(User, arena, user.body, .{ .ignore_unknown_fields = true }) catch return .unknown;
    const got = fetchOne(arena, io, config, try std.fmt.allocPrint(arena, "/repos/{s}/collaborators/{s}/permission", .{ repo, who.login })) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .unknown,
    };
    return judgePermission(arena, got.status, got.body);
}

/// GitHub's answer about one person's permission on a repository: 404 is
/// "no such repository for this token, or not a collaborator", the same
/// refusal; `role_name` names Maintain, which `permission` folds into write.
pub fn judgePermission(arena: std.mem.Allocator, status: u16, body: []const u8) host.Answer {
    if (status == 404) return .no;
    if (status != 200) return .unknown;
    const P = struct { permission: []const u8 = "", role_name: []const u8 = "" };
    const p = std.json.parseFromSliceLeaky(P, arena, body, .{ .ignore_unknown_fields = true }) catch return .unknown;
    const yes = std.mem.eql(u8, p.role_name, "admin") or std.mem.eql(u8, p.role_name, "maintain") or std.mem.eql(u8, p.permission, "admin");
    return if (yes) .yes else .no;
}

test "GitHub roles, repositories and answers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const json =
        \\[{"login":"ana","id":1,"role_name":"admin","permissions":{"admin":true,"maintain":true,"push":true,"triage":true,"pull":true}},
        \\ {"login":"budi","id":2,"role_name":"write","permissions":{"admin":false,"maintain":false,"push":true,"triage":true,"pull":true}},
        \\ {"login":"citra","id":3,"role_name":"triage","permissions":{"admin":false,"maintain":false,"push":false,"triage":true,"pull":true}},
        \\ {"login":"dewi","id":4,"role_name":"maintain","permissions":{"admin":false,"maintain":true,"push":true,"triage":true,"pull":true}}]
    ;
    const cs = try parseCollaborators(a, json);
    try std.testing.expectEqualStrings("maintain", levelFor(cs[0]).?);
    try std.testing.expectEqualStrings("write", levelFor(cs[1]).?);
    try std.testing.expectEqualStrings("read", levelFor(cs[2]).?);
    try std.testing.expectEqualStrings("maintain", levelFor(cs[3]).?);

    try std.testing.expectEqualStrings("org/speech-id", repoOf("git@github.com:org/speech-id.git", "https://github.com").?);
    try std.testing.expectEqualStrings("org/speech-id", repoOf("https://github.com/org/speech-id", "https://github.com").?);
    try std.testing.expect(repoOf("git@gitlab.com:org/speech-id.git", "https://github.com") == null);
    try std.testing.expect(repoOf("git@github.com:org/datasets/speech-id.git", "https://github.com") == null);

    try std.testing.expectEqual(host.Answer.yes, judgePermission(a, 200, "{\"permission\":\"admin\",\"role_name\":\"admin\"}"));
    try std.testing.expectEqual(host.Answer.yes, judgePermission(a, 200, "{\"permission\":\"write\",\"role_name\":\"maintain\"}"));
    try std.testing.expectEqual(host.Answer.no, judgePermission(a, 200, "{\"permission\":\"write\",\"role_name\":\"write\"}"));
    try std.testing.expectEqual(host.Answer.no, judgePermission(a, 404, "{}"));
    try std.testing.expectEqual(host.Answer.unknown, judgePermission(a, 502, ""));

    const com = try Config.of(a, "https://github.com/", "t");
    try std.testing.expectEqualStrings("https://api.github.com", com.api_url);
    const ghes = try Config.of(a, "https://git.example.com", "t");
    try std.testing.expectEqualStrings("https://git.example.com/api/v3", ghes.api_url);
}
