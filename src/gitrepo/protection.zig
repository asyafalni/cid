//! Is the dataset repository's `main` safe from everyone but cid? Asked
//! once, when a dataset is created, and only ever warned about: cid works
//! with any git host and never refuses a repository for this.
//!
//! Two things go wrong. An unprotected `main` (or one that allows force
//! pushes) lets anyone who can push rewrite the dataset's git history,
//! which cid treats as written by it alone (invariant 21). A `main` nobody
//! may push to passes the creation check, which pushes a scratch ref, and
//! then fails at the first release.
//!
//! On a GitLab the server has a token for, GitLab's protected-branches API
//! answers. Anywhere else cid cannot tell, and says so once.

const std = @import("std");
const gitlab = @import("../access/gitlab_sync.zig");

/// Where a git URL points: its host, and the project path without `.git`.
pub const Location = struct { host: []const u8, path: []const u8 };

/// The host and path of a remote git URL: `git@host:group/repo.git`,
/// `ssh://git@host:22/group/repo.git`, `https://host/group/repo.git`.
/// Null for a local repository (a path or `file://`), which has no host to
/// ask and no one else to push to it.
pub fn locate(url: []const u8) ?Location {
    var rest: []const u8 = undefined;
    var host: []const u8 = undefined;
    if (std.mem.indexOf(u8, url, "://")) |scheme_end| {
        const scheme = url[0..scheme_end];
        if (std.mem.eql(u8, scheme, "file")) return null;
        const after = url[scheme_end + 3 ..];
        const slash = std.mem.indexOfScalar(u8, after, '/') orelse return null;
        var authority = after[0..slash];
        if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority = authority[at + 1 ..];
        if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| authority = authority[0..colon];
        host = authority;
        rest = after[slash + 1 ..];
    } else {
        // scp-like: [user@]host:path, the colon before any slash.
        const colon = std.mem.indexOfScalar(u8, url, ':') orelse return null;
        if (std.mem.indexOfScalar(u8, url[0..colon], '/') != null) return null;
        host = url[0..colon];
        if (std.mem.lastIndexOfScalar(u8, host, '@')) |at| host = host[at + 1 ..];
        rest = url[colon + 1 ..];
    }
    rest = std.mem.trim(u8, rest, "/");
    if (std.mem.endsWith(u8, rest, ".git")) rest = rest[0 .. rest.len - 4];
    if (host.len == 0 or rest.len == 0) return null;
    return .{ .host = host, .path = rest };
}

/// The host of a GitLab base URL (`https://gitlab.example.com[:port][/]`).
pub fn hostOf(base_url: []const u8) []const u8 {
    const start = if (std.mem.indexOf(u8, base_url, "://")) |i| i + 3 else 0;
    const tail = base_url[start..];
    return tail[0 .. std.mem.indexOfAny(u8, tail, ":/") orelse tail.len];
}

/// What GitLab said about `main`, read from its answer. A 404 means "not
/// protected" only when GitLab could see the project: a project the token
/// cannot see is a 404 too, saying "404 Project Not Found", and that is no
/// answer at all.
pub const Verdict = enum { protected, unprotected, force_push_allowed, nobody_may_push, unknown };

pub fn judge(status: u16, body: []const u8, arena: std.mem.Allocator) Verdict {
    if (status == 404) return if (std.mem.indexOf(u8, body, "Project Not Found") != null) .unknown else .unprotected;
    if (status != 200) return .unknown;
    const Level = struct {
        access_level: u32 = 0,
        user_id: ?u64 = null,
        group_id: ?u64 = null,
        deploy_key_id: ?u64 = null,
    };
    const Branch = struct {
        push_access_levels: []const Level = &.{},
        allow_force_push: bool = false,
    };
    const parsed = std.json.parseFromSliceLeaky(Branch, arena, body, .{ .ignore_unknown_fields = true }) catch return .unknown;
    if (parsed.allow_force_push) return .force_push_allowed;
    for (parsed.push_access_levels) |l| {
        if (l.access_level > 0 or l.user_id != null or l.group_id != null or l.deploy_key_id != null) return .protected;
    }
    return .nobody_may_push;
}

/// The warning to print for a verdict, or null when there is nothing to say.
pub fn warning(arena: std.mem.Allocator, verdict: Verdict, url: []const u8) error{OutOfMemory}!?[]const u8 {
    return switch (verdict) {
        .protected => null,
        .unprotected => try std.fmt.allocPrint(arena, "main is not protected in {s}: anyone who can push there can rewrite the dataset's history. " ++
            "Protect main so only cid's account may push (Settings > Repository > Protected branches).", .{url}),
        .force_push_allowed => try std.fmt.allocPrint(arena, "main in {s} allows force pushes, which can rewrite the dataset's history. " ++
            "Turn off 'Allowed to force push' for main (Settings > Repository > Protected branches).", .{url}),
        .nobody_may_push => try std.fmt.allocPrint(arena, "no one may push to main in {s}, so cid cannot write releases there. " ++
            "Allow cid's account to push to main (Settings > Repository > Protected branches).", .{url}),
        .unknown => try std.fmt.allocPrint(arena, "cid could not check whether main is protected in {s}. " ++
            "Make sure only cid's account may push to main.", .{url}),
    };
}

/// The warning for a dataset repository, if any: GitLab's answer when the
/// server has a token for that host, otherwise one note that it cannot
/// tell. A local repository says nothing. Blocks on the network; the
/// server runs it off its event loop.
pub fn check(arena: std.mem.Allocator, io: std.Io, config: ?gitlab.Config, url: []const u8) error{OutOfMemory}!?[]const u8 {
    const loc = locate(url) orelse return null;
    const cfg = config orelse return try note(arena, loc.host, url);
    if (!std.ascii.eqlIgnoreCase(loc.host, hostOf(cfg.base_url))) return try note(arena, loc.host, url);
    const project = gitlab.urlEncodePath(arena, loc.path) catch return error.OutOfMemory;
    const got = gitlab.fetchOne(arena, io, cfg, "/api/v4/projects/{s}/protected_branches/main", .{project}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return try warning(arena, .unknown, url),
    };
    return try warning(arena, judge(got.status, got.body, arena), url);
}

fn note(arena: std.mem.Allocator, host: []const u8, url: []const u8) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(arena, "cid cannot check branch protection on {s}. Make sure only cid's account may push to main in {s}.", .{ host, url });
}

test "locate: the git URL shapes, and local repositories" {
    const cases = .{
        .{ "git@gitlab.com:org/datasets/speech.git", "gitlab.com", "org/datasets/speech" },
        .{ "ssh://git@gitlab.example.com:2222/org/x.git", "gitlab.example.com", "org/x" },
        .{ "https://gitlab.com/org/x", "gitlab.com", "org/x" },
        .{ "https://user:pw@gitlab.com/org/x.git/", "gitlab.com", "org/x" },
    };
    inline for (cases) |c| {
        const loc = locate(c[0]).?;
        try std.testing.expectEqualStrings(c[1], loc.host);
        try std.testing.expectEqualStrings(c[2], loc.path);
    }
    try std.testing.expect(locate("/srv/git/demo.git") == null);
    try std.testing.expect(locate("./demo.git") == null);
    try std.testing.expect(locate("file:///srv/git/demo.git") == null);
    try std.testing.expectEqualStrings("gitlab.example.com", hostOf("https://gitlab.example.com"));
    try std.testing.expectEqualStrings("gitlab.example.com", hostOf("https://gitlab.example.com:8443/"));
}

test "judge: what GitLab's protected-branch answer means" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqual(Verdict.unprotected, judge(404, "{\"message\":\"404 Not found\"}", a));
    try std.testing.expectEqual(Verdict.unknown, judge(404, "{\"message\":\"404 Project Not Found\"}", a));
    try std.testing.expectEqual(Verdict.protected, judge(200, "{\"name\":\"main\",\"push_access_levels\":[{\"access_level\":40}],\"allow_force_push\":false}", a));
    try std.testing.expectEqual(Verdict.protected, judge(200, "{\"push_access_levels\":[{\"access_level\":0,\"deploy_key_id\":7}]}", a));
    try std.testing.expectEqual(Verdict.nobody_may_push, judge(200, "{\"push_access_levels\":[{\"access_level\":0}]}", a));
    try std.testing.expectEqual(Verdict.force_push_allowed, judge(200, "{\"push_access_levels\":[{\"access_level\":40}],\"allow_force_push\":true}", a));
    try std.testing.expectEqual(Verdict.unknown, judge(403, "", a));
    try std.testing.expectEqual(Verdict.unknown, judge(200, "not json", a));
}

test "check: a local repository says nothing; another host gets one note" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expect((try check(a, std.testing.io, null, "/srv/git/demo.git")) == null);
    const n = (try check(a, std.testing.io, null, "git@github.com:org/x.git")).?;
    try std.testing.expect(std.mem.indexOf(u8, n, "cannot check branch protection on github.com") != null);
    const other = (try check(a, std.testing.io, .{ .base_url = "https://gitlab.com", .token = "t" }, "git@github.com:org/x.git")).?;
    try std.testing.expect(std.mem.indexOf(u8, other, "github.com") != null);
}
