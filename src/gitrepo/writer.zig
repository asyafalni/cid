//! The git writer: takes pending rows from git_writes and lands each
//! release in the dataset repository as one commit and one tag
//! (docs/git-repository.md). Speaks plain `git` as an external program —
//! explicit arguments, no shell, timeouts — so any host works.
//!
//! A git failure marks the row failed and never touches the release
//! (invariant 21). Re-running is safe: rendering is deterministic, an
//! unchanged tree produces no commit, an existing tag is left alone.

const std = @import("std");
const pg = @import("../store/pg.zig");
const release_core = @import("../core/release.zig");
const render = @import("render.zig");

pub const Config = struct {
    /// Where repository clones live, one folder per dataset id.
    workdir: []const u8,
    /// Shown in README links and the .cid marker.
    server_url: []const u8,
    git_timeout_ns: i96 = 60 * std.time.ns_per_s,
};

pub const Error = error{ Db, GitFailed, OutOfMemory };

pub const Outcome = struct {
    processed: u32 = 0,
    failed: u32 = 0,
};

/// Handles every pending or failed git_writes row of one dataset.
pub fn processDataset(
    arena: std.mem.Allocator,
    io: std.Io,
    db: *pg.Db,
    config: Config,
    dataset_name: []const u8,
) Error!Outcome {
    const name_z = arena.dupeZ(u8, dataset_name) catch return error.OutOfMemory;
    var ds_rows = db.query(
        "SELECT dataset_id::text, git_url FROM datasets WHERE name = $1",
        &.{name_z},
        null,
    ) catch return error.Db;
    defer ds_rows.deinit();
    if (ds_rows.count() == 0) return error.Db;
    const dataset_id = arena.dupeZ(u8, ds_rows.get(0, 0)) catch return error.OutOfMemory;
    const git_url = arena.dupe(u8, ds_rows.get(0, 1)) catch return error.OutOfMemory;

    var pending = db.query(
        "SELECT release FROM git_writes WHERE dataset_id = $1::uuid AND status <> 'done' ORDER BY release",
        &.{dataset_id},
        null,
    ) catch return error.Db;
    defer pending.deinit();

    var outcome: Outcome = .{};
    var i: usize = 0;
    while (i < pending.count()) : (i += 1) {
        const release_name = arena.dupe(u8, pending.get(i, 0)) catch return error.OutOfMemory;
        if (writeOne(arena, io, db, config, dataset_id, dataset_name, git_url, release_name)) |sha| {
            markDone(arena, db, dataset_id, release_name, sha);
            outcome.processed += 1;
        } else |err| {
            markFailed(arena, db, dataset_id, release_name, @errorName(err));
            outcome.failed += 1;
        }
    }
    return outcome;
}

/// Renders and pushes one release. Returns the git commit sha.
fn writeOne(
    arena: std.mem.Allocator,
    io: std.Io,
    db: *pg.Db,
    config: Config,
    dataset_id: [:0]const u8,
    dataset_name: []const u8,
    git_url: []const u8,
    release_name: []const u8,
) ![]const u8 {
    const input = try loadInput(arena, db, config, dataset_id, dataset_name, git_url, release_name);
    const files = try render.renderAll(arena, input);

    const repo_dir = try std.fmt.allocPrint(arena, "{s}/{s}", .{ config.workdir, dataset_id });
    std.Io.Dir.cwd().access(io, repo_dir, .{}) catch {
        std.Io.Dir.cwd().createDirPath(io, config.workdir) catch return error.GitFailed;
        try git(arena, io, config, null, &.{ "clone", git_url, repo_dir });
    };
    // Always sync to the remote first; our own branch is always 'main'.
    try git(arena, io, config, repo_dir, &.{ "fetch", "origin" });
    if (gitOk(arena, io, config, repo_dir, &.{ "rev-parse", "--verify", "origin/main" })) {
        try git(arena, io, config, repo_dir, &.{ "checkout", "-B", "main", "origin/main" });
    } else {
        try git(arena, io, config, repo_dir, &.{ "checkout", "-B", "main" });
    }

    var repo = std.Io.Dir.cwd().openDir(io, repo_dir, .{}) catch return error.GitFailed;
    defer repo.close(io);
    for (files) |f| {
        repo.writeFile(io, .{ .sub_path = f.path, .data = f.contents }) catch return error.GitFailed;
    }

    try git(arena, io, config, repo_dir, &.{ "add", "-A" });
    const dirty = try gitOutput(arena, io, config, repo_dir, &.{ "status", "--porcelain" });
    if (dirty.len > 0) {
        const msg = try std.fmt.allocPrint(arena, "release: {s}", .{release_name});
        try git(arena, io, config, repo_dir, &.{
            "-c",     "user.name=cid",
            "-c",     "user.email=cid@invalid",
            "commit", "-m",
            msg,
        });
    }
    if (!gitOk(arena, io, config, repo_dir, &.{ "rev-parse", "--verify", try std.fmt.allocPrint(arena, "refs/tags/{s}", .{release_name}) })) {
        try git(arena, io, config, repo_dir, &.{ "tag", release_name });
    }
    try git(arena, io, config, repo_dir, &.{ "push", "origin", "main", "--tags" });

    const sha = try gitOutput(arena, io, config, repo_dir, &.{ "rev-parse", "HEAD" });
    return std.mem.trim(u8, sha, " \n");
}

fn loadInput(
    arena: std.mem.Allocator,
    db: *pg.Db,
    config: Config,
    dataset_id: [:0]const u8,
    dataset_name: []const u8,
    git_url: []const u8,
    release_name: []const u8,
) !render.Input {
    const name_z = arena.dupeZ(u8, release_name) catch return error.OutOfMemory;
    var ref_rows = db.query(
        "SELECT r.commit_id::text, encode(r.manifest_sha256, 'hex'), " ++
            "(extract(epoch from c.recorded_at) * 1000)::bigint::text, c.message " ++
            "FROM refs r JOIN commits c ON c.commit_id = r.commit_id " ++
            "WHERE r.dataset_id = $1::uuid AND r.name = $2 AND r.kind = 'release'",
        &.{ dataset_id, name_z },
        null,
    ) catch return error.Db;
    defer ref_rows.deinit();
    if (ref_rows.count() == 0) return error.Db;
    const commit_id = arena.dupeZ(u8, ref_rows.get(0, 0)) catch return error.OutOfMemory;
    const manifest_hex = arena.dupe(u8, ref_rows.get(0, 1)) catch return error.OutOfMemory;
    const created_ms = std.fmt.parseInt(u64, ref_rows.get(0, 2), 10) catch 0;

    const rows = release_core.stateRows(arena, db, dataset_id, commit_id) catch return error.Db;
    const items = try arena.alloc(render.Item, rows.len);
    for (items, 0..) |*item, i| {
        item.* = .{ .path = rows[i].path, .hash_hex = rows[i].hash_hex, .size = rows[i].size };
    }

    // Every release, newest first, with item counts for the changelog.
    var all = db.query(
        "SELECT r.name, c.message, (extract(epoch from c.recorded_at) * 1000)::bigint::text, " ++
            "(SELECT count(*) FROM (SELECT DISTINCT ON (path) op FROM item_revisions ir " ++
            "  WHERE ir.dataset_id = r.dataset_id AND ir.branch = c.branch AND ir.rev_id <= c.cutoff_rev " ++
            "  ORDER BY path, rev_id DESC) s WHERE s.op <> 'delete') " ++
            "FROM refs r JOIN commits c ON c.commit_id = r.commit_id " ++
            "WHERE r.dataset_id = $1::uuid AND r.kind = 'release' ORDER BY r.commit_id DESC, r.name DESC",
        &.{dataset_id},
        null,
    ) catch return error.Db;
    defer all.deinit();
    const releases = try arena.alloc(render.ReleaseInfo, all.count());
    for (releases, 0..) |*r, i| {
        r.* = .{
            .name = arena.dupe(u8, all.get(i, 0)) catch return error.OutOfMemory,
            .message = arena.dupe(u8, all.get(i, 1)) catch return error.OutOfMemory,
            .created_at_ms = std.fmt.parseInt(u64, all.get(i, 2), 10) catch 0,
            .items = std.fmt.parseInt(usize, all.get(i, 3), 10) catch 0,
        };
    }

    return .{
        .dataset_name = dataset_name,
        .git_url = git_url,
        .server_url = config.server_url,
        .release = release_name,
        .commit_id = commit_id,
        .manifest_sha256_hex = manifest_hex,
        .created_at_ms = created_ms,
        .items = items,
        .releases = releases,
    };
}

fn markDone(arena: std.mem.Allocator, db: *pg.Db, dataset_id: [:0]const u8, release_name: []const u8, sha: []const u8) void {
    const name_z = arena.dupeZ(u8, release_name) catch return;
    const sha_z = arena.dupeZ(u8, sha) catch return;
    db.execParams(
        "UPDATE git_writes SET status = 'done', git_commit = $3, attempts = attempts + 1, last_error = NULL, updated_at = now() " ++
            "WHERE dataset_id = $1::uuid AND release = $2",
        &.{ dataset_id, name_z, sha_z },
        null,
    ) catch {};
}

fn markFailed(arena: std.mem.Allocator, db: *pg.Db, dataset_id: [:0]const u8, release_name: []const u8, err_name: []const u8) void {
    const name_z = arena.dupeZ(u8, release_name) catch return;
    const err_z = arena.dupeZ(u8, err_name) catch return;
    db.execParams(
        "UPDATE git_writes SET status = 'failed', attempts = attempts + 1, last_error = $3, updated_at = now() " ++
            "WHERE dataset_id = $1::uuid AND release = $2",
        &.{ dataset_id, name_z, err_z },
        null,
    ) catch {};
}

// --- plain git, explicit args, never a shell -----------------------------

fn git(arena: std.mem.Allocator, io: std.Io, config: Config, repo_dir: ?[]const u8, args: []const []const u8) !void {
    const result = try runGit(arena, io, config, repo_dir, args);
    if (result.term != .exited or result.term.exited != 0) {
        std.log.warn("git {s} failed: {s}", .{ args[0], std.mem.trim(u8, result.stderr, " \n") });
        return error.GitFailed;
    }
}

fn gitOk(arena: std.mem.Allocator, io: std.Io, config: Config, repo_dir: ?[]const u8, args: []const []const u8) bool {
    const result = runGit(arena, io, config, repo_dir, args) catch return false;
    return result.term == .exited and result.term.exited == 0;
}

fn gitOutput(arena: std.mem.Allocator, io: std.Io, config: Config, repo_dir: ?[]const u8, args: []const []const u8) ![]const u8 {
    const result = try runGit(arena, io, config, repo_dir, args);
    if (result.term != .exited or result.term.exited != 0) return error.GitFailed;
    return result.stdout;
}

fn runGit(
    arena: std.mem.Allocator,
    io: std.Io,
    config: Config,
    repo_dir: ?[]const u8,
    args: []const []const u8,
) !std.process.RunResult {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, "git");
    try argv.appendSlice(arena, args);
    return std.process.run(arena, io, .{
        .argv = argv.items,
        .cwd = if (repo_dir) |d| .{ .path = d } else .inherit,
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .{ .nanoseconds = config.git_timeout_ns } } },
        .stdout_limit = .limited(16 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    }) catch |err| {
        std.log.warn("could not run git: {t}", .{err});
        return error.GitFailed;
    };
}
