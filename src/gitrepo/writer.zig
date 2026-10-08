//! The git writer: takes pending rows from git_writes and lands each
//! release in the dataset repository as one commit and one tag
//! (docs/git-repository.md). Speaks plain `git` as an external program —
//! explicit arguments, no shell, timeouts — so any host works.
//!
//! A git failure marks the row failed and never touches the release
//! (invariant 21). Re-running is safe: rendering is deterministic, an
//! unchanged tree produces no commit, an existing tag is left alone.

const std = @import("std");
const dbx = @import("../store/db.zig");
const versions = @import("../core/version.zig");
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
const DatasetRow = struct {
    pub const nilo_table = .projection;
    dataset_id: []const u8,
    git_url: []const u8,
    kind: []const u8,
};

pub fn processDataset(
    arena: std.mem.Allocator,
    io: std.Io,
    db: *dbx.sql.Db,
    scope: anytype,
    config: Config,
    dataset_name: []const u8,
) Error!Outcome {
    const ds = (db.rawOne(DatasetRow, scope, "SELECT dataset_id::text AS dataset_id, git_url, kind FROM datasets WHERE name = $1", .{dataset_name}) catch return error.Db) orelse return error.Db;

    // In release order (git commit order equals release order), never
    // by name: v10 comes after v9.
    const pending = db.raw([]const u8, scope, "SELECT w.release FROM git_writes w JOIN refs r ON r.dataset_id = w.dataset_id AND r.name = w.release AND r.kind = 'release' " ++
        "WHERE w.dataset_id = $1::uuid AND w.status <> 'done' ORDER BY r.commit_id, w.release", .{ds.dataset_id}) catch return error.Db;

    var outcome: Outcome = .{};
    for (pending) |release_name| {
        if (writeOne(arena, io, db, scope, config, ds.dataset_id, dataset_name, ds.git_url, ds.kind, release_name)) |sha| {
            markDone(db, scope, ds.dataset_id, release_name, sha);
            outcome.processed += 1;
        } else |err| {
            markFailed(db, scope, ds.dataset_id, release_name, @errorName(err));
            outcome.failed += 1;
        }
    }
    return outcome;
}

/// The dataset's clone in the workdir, made if missing, pointed at its
/// current git URL (`cid admin rename --git` may have changed it).
fn openClone(arena: std.mem.Allocator, io: std.Io, config: Config, dataset_id: []const u8, git_url: []const u8) ![]const u8 {
    const repo_dir = try std.fmt.allocPrint(arena, "{s}/{s}", .{ config.workdir, dataset_id });
    std.Io.Dir.cwd().access(io, repo_dir, .{}) catch {
        std.Io.Dir.cwd().createDirPath(io, config.workdir) catch return error.GitFailed;
        try git(arena, io, config, null, &.{ "clone", git_url, repo_dir });
    };
    try git(arena, io, config, repo_dir, &.{ "remote", "set-url", "origin", git_url });
    return repo_dir;
}

/// Puts a render of `input` on main, as the remote has it, and commits it
/// with `message` when anything differs. Answers whether it committed.
fn commitRendered(arena: std.mem.Allocator, io: std.Io, config: Config, repo_dir: []const u8, input: render.Input, message: []const u8) !bool {
    const files = try render.renderAll(arena, input);
    // Always sync to the remote first; our own branch is always 'main'.
    try git(arena, io, config, repo_dir, &.{ "fetch", "origin" });
    if (gitOk(arena, io, config, repo_dir, &.{ "rev-parse", "--verify", "origin/main" })) {
        try git(arena, io, config, repo_dir, &.{ "checkout", "-B", "main", "origin/main" });
    } else {
        try git(arena, io, config, repo_dir, &.{ "checkout", "-B", "main" });
    }

    var repo = std.Io.Dir.cwd().openDir(io, repo_dir, .{}) catch return error.GitFailed;
    defer repo.close(io);
    // cid's files are exactly this render's: whatever an earlier release
    // wrote and this one does not (files.txt once a dataset is restricted
    // or too large) goes. Only cid's own paths: anything else in the
    // repository, someone's code or docs, is left as it is.
    for (render.owned_paths) |name| {
        repo.deleteFile(io, name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return error.GitFailed,
        };
    }
    for (files) |f| {
        repo.writeFile(io, .{ .sub_path = f.path, .data = f.contents }) catch return error.GitFailed;
    }

    try git(arena, io, config, repo_dir, &.{ "add", "-A" });
    const dirty = try gitOutput(arena, io, config, repo_dir, &.{ "status", "--porcelain" });
    if (dirty.len == 0) return false;
    try git(arena, io, config, repo_dir, &.{
        "-c",     "user.name=cid",
        "-c",     "user.email=cid@invalid",
        "commit", "-m",
        message,
    });
    return true;
}

pub const Refreshed = union(enum) {
    /// Nothing is in the repository yet: the first release writes it all.
    nothing_released,
    /// The repository already says what cid would.
    up_to_date,
    /// One commit on main, pushed; its sha.
    committed: []const u8,
};

/// After a rename, the repository's files still name the old path and
/// URL — the `.cid` marker most of all, which `cid clone <git-url>`
/// reads. This renders the newest release the repository holds again,
/// with the dataset's current name and git URL, and pushes the result to
/// main as one commit (`message`), with plain git and no
/// help from the host. No tag moves; nothing is pushed when nothing
/// differs, so running it twice is safe.
pub fn refresh(
    arena: std.mem.Allocator,
    io: std.Io,
    db: *dbx.sql.Db,
    scope: anytype,
    config: Config,
    dataset_name: []const u8,
    message: []const u8,
) Error!Refreshed {
    const ds = (db.rawOne(DatasetRow, scope, "SELECT dataset_id::text AS dataset_id, git_url, kind FROM datasets WHERE name = $1", .{dataset_name}) catch return error.Db) orelse return error.Db;
    const newest = (db.rawOne([]const u8, scope, "SELECT w.release FROM git_writes w JOIN refs r ON r.dataset_id = w.dataset_id AND r.name = w.release AND r.kind = 'release' " ++
        "WHERE w.dataset_id = $1::uuid AND w.status = 'done' ORDER BY r.commit_id DESC, w.release DESC LIMIT 1", .{ds.dataset_id}) catch return error.Db) orelse
        return .nothing_released;
    const repo_dir = openClone(arena, io, config, ds.dataset_id, ds.git_url) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.GitFailed,
    };
    const input = loadInput(arena, db, scope, config, ds.dataset_id, dataset_name, ds.git_url, ds.kind, newest) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Db,
    };
    const committed = commitRendered(arena, io, config, repo_dir, input, message) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.GitFailed,
    };
    if (!committed) return .up_to_date;
    git(arena, io, config, repo_dir, &.{ "push", "origin", "main" }) catch return error.GitFailed;
    const sha = gitOutput(arena, io, config, repo_dir, &.{ "rev-parse", "HEAD" }) catch return error.GitFailed;
    return .{ .committed = std.mem.trim(u8, sha, " \n") };
}

/// Renders and pushes one release. Returns the git commit sha.
fn writeOne(
    arena: std.mem.Allocator,
    io: std.Io,
    db: *dbx.sql.Db,
    scope: anytype,
    config: Config,
    dataset_id: []const u8,
    dataset_name: []const u8,
    git_url: []const u8,
    kind: []const u8,
    release_name: []const u8,
) ![]const u8 {
    const repo_dir = try openClone(arena, io, config, dataset_id, git_url);

    // A release whose tag the repository already has is written: nothing
    // to do, ever. Rendering it again would put an older release's files
    // on top of newer ones.
    const tag_ref = try std.fmt.allocPrint(arena, "refs/tags/{s}", .{release_name});
    const remote_tag = try gitOutput(arena, io, config, repo_dir, &.{ "ls-remote", "origin", tag_ref });
    if (remote_tag.len > 0) {
        try git(arena, io, config, repo_dir, &.{ "fetch", "origin", "--tags" });
        const sha = try gitOutput(arena, io, config, repo_dir, &.{ "rev-parse", try std.fmt.allocPrint(arena, "{s}^{{commit}}", .{tag_ref}) });
        return std.mem.trim(u8, sha, " \n");
    }

    const input = try loadInput(arena, db, scope, config, dataset_id, dataset_name, git_url, kind, release_name);
    _ = try commitRendered(arena, io, config, repo_dir, input, try std.fmt.allocPrint(arena, "release: {s}", .{release_name}));
    if (!gitOk(arena, io, config, repo_dir, &.{ "rev-parse", "--verify", try std.fmt.allocPrint(arena, "refs/tags/{s}", .{release_name}) })) {
        try git(arena, io, config, repo_dir, &.{ "tag", release_name });
    }
    try git(arena, io, config, repo_dir, &.{ "push", "origin", "main", "--tags" });

    const sha = try gitOutput(arena, io, config, repo_dir, &.{ "rev-parse", "HEAD" });
    return std.mem.trim(u8, sha, " \n");
}

const RefInfo = struct {
    pub const nilo_table = .projection;
    commit_id: []const u8,
    manifest_hex: []const u8,
    created_ms: i64,
    message: []const u8,
    card: ?[]const u8,
    restricted: bool,
};

fn loadInput(
    arena: std.mem.Allocator,
    db: *dbx.sql.Db,
    scope: anytype,
    config: Config,
    dataset_id: []const u8,
    dataset_name: []const u8,
    git_url: []const u8,
    kind: []const u8,
    release_name: []const u8,
) !render.Input {
    const ref = (db.rawOne(RefInfo, scope, "SELECT r.commit_id::text AS commit_id, encode(r.manifest_hash, 'hex') AS manifest_hex, " ++
        "(extract(epoch from c.recorded_at) * 1000)::bigint AS created_ms, c.message, r.card::text AS card, d.restricted " ++
        "FROM refs r JOIN commits c ON c.commit_id = r.commit_id JOIN datasets d ON d.dataset_id = r.dataset_id " ++
        "WHERE r.dataset_id = $1::uuid AND r.name = $2 AND r.kind = 'release'", .{ dataset_id, release_name }) catch return error.Db) orelse return error.Db;
    const commit_id = ref.commit_id;
    const manifest_hex = ref.manifest_hex;
    const created_ms: u64 = @intCast(@max(0, ref.created_ms));

    // Counts, types, classes and splits: the commit's statistics, one
    // aggregate kept on the commit (never the version held in memory).
    const st = versions.stats(arena, db, scope, dataset_id, commit_id) catch return error.Db;
    const files: []const render.Item = if (st.items < render.files_txt_limit) blk: {
        const listed = versions.firstItems(arena, db, scope, dataset_id, commit_id, render.files_txt_limit) catch return error.Db;
        const out = try arena.alloc(render.Item, listed.len);
        for (out, listed) |*f, l| f.* = .{ .path = l.path, .hash_hex = l.hash_hex, .size = @intCast(l.size_bytes) };
        break :blk out;
    } else &.{};

    // Every release, newest first, each counted from its own commit's
    // statistics (kept, so a long history costs one row read per release).
    const All = struct {
        pub const nilo_table = .projection;
        name: []const u8,
        message: []const u8,
        created_ms: i64,
        commit_id: []const u8,
        changes_from: ?[]const u8,
        changes: ?[]const u8,
    };
    const all = db.raw(All, scope, "SELECT r.name, c.message, (extract(epoch from c.recorded_at) * 1000)::bigint AS created_ms, " ++
        "c.commit_id::text AS commit_id, r.changes_from, r.changes::text AS changes FROM refs r JOIN commits c ON c.commit_id = r.commit_id " ++
        "WHERE r.dataset_id = $1::uuid AND r.kind = 'release' ORDER BY r.commit_id DESC, r.name DESC", .{dataset_id}) catch return error.Db;
    const releases = try arena.alloc(render.ReleaseInfo, all.len);
    for (releases, all) |*r, row| {
        const their = versions.stats(arena, db, scope, dataset_id, row.commit_id) catch return error.Db;
        r.* = .{
            .name = row.name,
            .message = row.message,
            .created_at_ms = @intCast(@max(0, row.created_ms)),
            .items = their.items,
            .changes_from = row.changes_from,
            .changes = if (row.changes) |text|
                std.json.parseFromSliceLeaky(render.Changes, arena, text, .{ .ignore_unknown_fields = true }) catch null
            else
                null,
        };
    }

    const classes = try arena.alloc(render.ClassCount, st.classes.len);
    for (classes, st.classes) |*c, x| c.* = .{ .name = x.name, .count = x.count };
    const splits = try arena.alloc(render.ClassCount, st.splits.len);
    for (splits, st.splits) |*c, x| c.* = .{ .name = x.name, .count = x.count };
    const types = try arena.alloc(render.ClassCount, st.types.len);
    for (types, st.types) |*c, x| c.* = .{ .name = x.name, .count = x.count };
    var policy: ?render.Policy = null;
    if (std.mem.eql(u8, kind, "annotated")) if (st.policy) |version| {
        const body = db.rawOne([]const u8, scope, "SELECT body::text FROM policy_versions WHERE dataset_id = $1::uuid AND version = $2", .{ dataset_id, version }) catch return error.Db;
        if (body) |b| policy = .{ .version = version, .body_json = b };
    };

    return .{
        .dataset_name = dataset_name,
        .kind = kind,
        .classes = if (std.mem.eql(u8, kind, "annotated")) classes else &.{},
        .splits = if (std.mem.eql(u8, kind, "annotated")) splits else &.{},
        .policy = policy,
        .git_url = git_url,
        .server_url = config.server_url,
        .release = release_name,
        .commit_id = commit_id,
        .manifest_hash_hex = manifest_hex,
        .created_at_ms = created_ms,
        .items = st.items,
        .bytes = st.bytes,
        .types = types,
        .files = files,
        .releases = releases,
        .card = ref.card,
        .restricted = ref.restricted,
    };
}

fn markDone(db: *dbx.sql.Db, scope: anytype, dataset_id: []const u8, release_name: []const u8, sha: []const u8) void {
    _ = db.exec(
        scope,
        "UPDATE git_writes SET status = 'done', git_commit = $3, attempts = attempts + 1, last_error = NULL, updated_at = now() " ++
            "WHERE dataset_id = $1::uuid AND release = $2",
        .{ dataset_id, release_name, sha },
    ) catch {};
}

fn markFailed(db: *dbx.sql.Db, scope: anytype, dataset_id: []const u8, release_name: []const u8, err_name: []const u8) void {
    _ = db.exec(
        scope,
        "UPDATE git_writes SET status = 'failed', attempts = attempts + 1, last_error = $3, updated_at = now() " ++
            "WHERE dataset_id = $1::uuid AND release = $2",
        .{ dataset_id, release_name, err_name },
    ) catch {};
}

// --- plain git, explicit args, never a shell -----------------------------

pub const Probe = union(enum) {
    ok,
    /// git could not reach the repository; git's own words.
    unreachable_repo: []const u8,
    /// Reached, but a push was refused; git's own words.
    not_writable: []const u8,
};

/// Whether cid can write the dataset repository, checked the honest way
/// when a dataset is created: a throwaway ref (refs/cid/write-check) is
/// pushed, then deleted. Branches and tags are never touched.
pub fn probe(arena: std.mem.Allocator, io: std.Io, config: Config, git_url: []const u8) error{ GitFailed, OutOfMemory }!Probe {
    var rand: [6]u8 = undefined;
    io.random(&rand);
    const dir = try std.fmt.allocPrint(arena, "{s}/probe-{x}", .{ config.workdir, &rand });
    std.Io.Dir.cwd().createDirPath(io, dir) catch return error.GitFailed;
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try git(arena, io, config, dir, &.{ "init", "-q" });
    try git(arena, io, config, dir, &.{ "-c", "user.name=cid", "-c", "user.email=cid@invalid", "commit", "-q", "--allow-empty", "-m", "cid write check" });

    const reach = try runGit(arena, io, config, dir, &.{ "ls-remote", "--quiet", git_url });
    if (reach.term != .exited or reach.term.exited != 0) return .{ .unreachable_repo = firstLine(reach.stderr) };
    const push = try runGit(arena, io, config, dir, &.{ "push", "--quiet", git_url, "HEAD:refs/cid/write-check" });
    if (push.term != .exited or push.term.exited != 0) return .{ .not_writable = firstLine(push.stderr) };
    _ = gitOk(arena, io, config, dir, &.{ "push", "--quiet", git_url, ":refs/cid/write-check" });
    return .ok;
}

fn firstLine(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \r\n");
    const end = std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len;
    return if (end == 0) "git gave no reason" else trimmed[0..end];
}

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
