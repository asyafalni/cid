//! push, clone, pull, checkout: moving history and content between the
//! local folder and the server. Content rides presigned URLs; history
//! rides the API. Every downloaded file is hash-verified before it lands.
//!
//! Pull fast-forwards when the folder has nothing unpushed, and otherwise
//! REPLAYS the unpushed commits onto the server's new history: when both
//! sides touched different files this is automatic; when the same file
//! changed on both sides, pull lists the conflicts and a person decides
//! per path with 'cid checkout --mine|--theirs <path>' (invariant: nothing
//! is merged silently). Branches beyond the current one are untouched.

const std = @import("std");
const workspace = @import("workspace.zig");
const local = @import("local.zig");
const index_mod = @import("index.zig");
const scan = @import("scan.zig");
const remote_mod = @import("remote.zig");

pub const Remote = remote_mod.Remote;

pub const Error = error{
    EmptyDataset,
    NoSuchRelease,
    UnpushedCommits,
    StagedChanges,
    LocalChangesInTheWay,
    CorruptLocalState,
} || remote_mod.Error || remote_mod.TransferError || std.mem.Allocator.Error;

pub const PushOutcome = struct {
    pushed_commits: u32 = 0,
    uploaded_files: u32 = 0,
};

/// Uploads unpushed local commits: content first (only what the server
/// lacks), then the commits in one call. Re-running after any failure is
/// safe: uploads are idempotent by hash and the server records commits
/// all-or-nothing.
pub fn push(
    arena: std.mem.Allocator,
    io: std.Io,
    ws: *workspace.Workspace,
    cache_dir: std.Io.Dir,
    remote: *const Remote,
) Error!PushOutcome {
    const head = local.loadHead(arena, io, ws.cid_dir) catch return error.CorruptLocalState;
    const last_pushed = local.readLastPushed(arena, io, ws.cid_dir);
    const newest_first = local.listUnpushed(arena, io, ws.cid_dir, last_pushed) catch
        return error.CorruptLocalState;
    if (newest_first.len == 0) return .{};
    // Oldest first for the wire.
    const unpushed = try arena.alloc(local.Commit, newest_first.len);
    for (unpushed, 0..) |*slot, i| slot.* = newest_first[newest_first.len - 1 - i];

    // The dataset may not exist on the server yet (init is local in this
    // build): create it from the folder's configuration.
    _ = remote.head(arena, head.branch) catch |err| switch (err) {
        error.NoSuchDataset => try remote.createDataset(arena, ws.config.git_url),
        else => return err,
    };

    // Unique hashes across the unpushed adds.
    var hashes: std.ArrayList([]const u8) = .empty;
    for (unpushed) |commit| {
        for (commit.changes) |ch| {
            if (ch.op != .add) continue;
            var seen = false;
            for (hashes.items) |h| {
                if (std.mem.eql(u8, h, &ch.hash_hex)) {
                    seen = true;
                    break;
                }
            }
            if (!seen) try hashes.append(arena, try arena.dupe(u8, &ch.hash_hex));
        }
    }

    var outcome: PushOutcome = .{};
    if (hashes.items.len > 0) {
        const missing = try remote.checkHashes(arena, hashes.items);
        for (missing) |m| {
            const size = sizeOf(unpushed, m.hash) orelse return error.CorruptLocalState;
            try remote_mod.uploadFromCache(arena, io, cache_dir, m.hash, size, m.url);
            outcome.uploaded_files += 1;
        }
    }

    try remote.push(arena, head.branch, unpushed);
    outcome.pushed_commits = @intCast(unpushed.len);
    local.writeLastPushed(io, ws.cid_dir, &unpushed[unpushed.len - 1].id.toString()) catch
        return error.CorruptLocalState;
    return outcome;
}

pub const CloneOutcome = struct {
    files: u32,
    downloaded: u32,
    head_commit: []const u8,
    /// The release the folder sits at, when one was used.
    release: ?[]const u8,
};

/// Fills an empty folder and writes `.cid/`. The default is the newest
/// release ("defaults that just work"); a dataset without releases gives
/// the branch head. `want_release` pins a specific one.
pub fn clone(
    arena: std.mem.Allocator,
    io: std.Io,
    dest_dir: std.Io.Dir,
    cache_dir: std.Io.Dir,
    remote: *const Remote,
    address: []const u8,
    want_release: ?[]const u8,
) Error!CloneOutcome {
    const info = try remote.info(arena);
    const head_commit = (try remote.head(arena, "main")) orelse return error.EmptyDataset;

    var at_commit: []const u8 = head_commit;
    var at_release: ?[]const u8 = null;
    const releases = try remote.releases(arena);
    if (want_release) |wanted| {
        for (releases) |r| {
            if (std.mem.eql(u8, r.name, wanted)) {
                at_commit = r.commit;
                at_release = r.name;
                break;
            }
        }
        if (at_release == null) return error.NoSuchRelease;
    } else if (releases.len > 0) {
        at_commit = releases[0].commit; // newest first
        at_release = releases[0].name;
    }

    const items = try remote.state(arena, at_commit);

    workspace.init(arena, io, dest_dir, address, info.git_url) catch
        return error.CorruptLocalState;
    var ws = workspace.open(arena, io, dest_dir) catch return error.CorruptLocalState;

    const downloaded = try materialize(arena, io, &ws, cache_dir, remote, items);

    try setPosition(io, &ws, "main", at_commit);
    // Server history reaches the branch head even when the folder sits at
    // an older release; 'cid pull' moves up to it.
    local.writeLastPushed(io, ws.cid_dir, head_commit) catch return error.CorruptLocalState;
    return .{ .files = @intCast(items.len), .downloaded = downloaded, .head_commit = at_commit, .release = at_release };
}

pub const PullOutcome = union(enum) {
    already_up_to_date,
    fast_forwarded: struct { files_changed: u32, head_commit: []const u8 },
    replayed: struct { commits: u32, files_changed: u32, head_commit: []const u8 },
    /// Same files changed on both sides; a person decides per path.
    conflicts: []const Conflict,
};

pub const Choice = enum { undecided, mine, theirs };
pub const Conflict = struct { path: []const u8, choice: Choice };

/// Brings the folder up to the server head. With unpushed commits it
/// replays them on top; overlapping file changes become conflicts that
/// must each be decided before the pull completes.
pub fn pull(
    arena: std.mem.Allocator,
    io: std.Io,
    ws: *workspace.Workspace,
    cache_dir: std.Io.Dir,
    remote: *const Remote,
) Error!PullOutcome {
    const head = local.loadHead(arena, io, ws.cid_dir) catch return error.CorruptLocalState;
    const server_head = (try remote.head(arena, head.branch)) orelse return error.EmptyDataset;
    if (head.commit) |c| {
        if (std.mem.eql(u8, &c.toString(), server_head)) {
            deletePullState(io, ws);
            return .already_up_to_date;
        }
    }
    if (try stagedCount(arena, io, ws) > 0) return error.StagedChanges;

    const last_pushed = local.readLastPushed(arena, io, ws.cid_dir);
    const unpushed_newest_first = local.listUnpushed(arena, io, ws.cid_dir, last_pushed) catch
        return error.CorruptLocalState;

    if (unpushed_newest_first.len == 0) {
        const items = try remote.state(arena, server_head);
        const changed = try materialize(arena, io, ws, cache_dir, remote, items);
        try setPosition(io, ws, head.branch, server_head);
        local.writeLastPushed(io, ws.cid_dir, server_head) catch return error.CorruptLocalState;
        deletePullState(io, ws);
        return .{ .fast_forwarded = .{ .files_changed = changed, .head_commit = server_head } };
    }

    // Replay. Oldest first.
    const unpushed = try arena.alloc(local.Commit, unpushed_newest_first.len);
    for (unpushed, 0..) |*slot, i| slot.* = unpushed_newest_first[unpushed_newest_first.len - 1 - i];

    const server_state = try remote.state(arena, server_head);
    const base_state: []const remote_mod.Remote.StateItem = if (last_pushed) |base|
        try remote.state(arena, base)
    else
        &.{};

    // What each side changed since the common base.
    var server_changed: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (server_state) |item| {
        const in_base = findState(base_state, item.path);
        if (in_base == null or !std.mem.eql(u8, in_base.?.hash, item.hash))
            try server_changed.put(arena, item.path, {});
    }
    for (base_state) |item| {
        if (findState(server_state, item.path) == null)
            try server_changed.put(arena, item.path, {});
    }

    const LocalChange = union(enum) { add: struct { hash_hex: [64]u8, size: u64 }, delete };
    var local_map: std.StringArrayHashMapUnmanaged(LocalChange) = .empty;
    for (unpushed) |commit| {
        for (commit.changes) |ch| {
            switch (ch.op) {
                .add => try local_map.put(arena, ch.path, .{ .add = .{ .hash_hex = ch.hash_hex, .size = ch.size } }),
                .delete => try local_map.put(arena, ch.path, .delete),
            }
        }
    }

    // Conflicts: both sides changed the path, differently. Identical
    // changes resolve themselves.
    var conflicts: std.StringArrayHashMapUnmanaged(Choice) = .empty;
    for (local_map.keys()) |path| {
        if (server_changed.get(path) == null) continue;
        const server_item = findState(server_state, path);
        const same = switch (local_map.get(path).?) {
            .add => |a| server_item != null and std.mem.eql(u8, server_item.?.hash, &a.hash_hex),
            .delete => server_item == null,
        };
        if (same) {
            _ = local_map.swapRemove(path);
        } else {
            try conflicts.put(arena, path, .undecided);
        }
    }

    // Fold in earlier decisions for paths still in conflict.
    if (loadPullState(arena, io, ws)) |prior| {
        for (prior) |c| {
            if (conflicts.getPtr(c.path)) |slot| slot.* = c.choice;
        }
    }

    var undecided: usize = 0;
    for (conflicts.values()) |choice| {
        if (choice == .undecided) undecided += 1;
    }
    if (undecided > 0) {
        try savePullState(arena, io, ws, conflicts);
        const out = try arena.alloc(Conflict, conflicts.count());
        for (out, conflicts.keys(), conflicts.values()) |*slot, path, choice| {
            slot.* = .{ .path = path, .choice = choice };
        }
        return .{ .conflicts = out };
    }

    // Decided: 'theirs' drops the local change for that path.
    for (conflicts.keys(), conflicts.values()) |path, choice| {
        if (choice == .theirs) _ = local_map.swapRemove(path);
    }

    // Target tree = server state overridden by the surviving local changes.
    var target: std.StringArrayHashMapUnmanaged(remote_mod.Remote.StateItem) = .empty;
    for (server_state) |item| try target.put(arena, item.path, item);
    for (local_map.keys(), local_map.values()) |path, change| {
        switch (change) {
            .add => |a| try target.put(arena, path, .{ .path = path, .hash = try arena.dupe(u8, &a.hash_hex), .size = a.size }),
            .delete => _ = target.swapRemove(path),
        }
    }
    const changed = try materialize(arena, io, ws, cache_dir, remote, target.values());

    // Rewrite the unpushed commits onto the new base: strip dropped paths,
    // skip commits that became empty, remint ids strictly after the server
    // head so ordering holds.
    const Uuid = @import("../util/uuid7.zig").Uuid;
    var prev = Uuid.parse(server_head) catch return error.CorruptLocalState;
    var kept: u32 = 0;
    for (unpushed) |commit| {
        var kept_changes: std.ArrayList(local.Change) = .empty;
        for (commit.changes) |ch| {
            const still_mine = switch (local_map.get(ch.path) orelse continue) {
                .add => |a| ch.op == .add and std.mem.eql(u8, &a.hash_hex, &ch.hash_hex),
                .delete => ch.op == .delete,
            };
            // Keep only the final surviving change for each path, in the
            // commit where it was made last.
            if (still_mine) try kept_changes.append(arena, ch);
        }
        deleteCommitFile(io, ws, commit.id);
        if (kept_changes.items.len == 0) continue;
        const new_id = Uuid.nextAfter(io, prev);
        const rewritten: local.Commit = .{
            .id = new_id,
            .parent = prev,
            .branch = commit.branch,
            .author = commit.author,
            .authored_at_ms = commit.authored_at_ms,
            .message = commit.message,
            .changes = kept_changes.items,
        };
        local.saveCommit(arena, io, ws.cid_dir, rewritten) catch return error.CorruptLocalState;
        prev = new_id;
        kept += 1;
    }

    local.saveHead(io, ws.cid_dir, .{ .branch = head.branch, .commit = prev }) catch
        return error.CorruptLocalState;
    local.writeLastPushed(io, ws.cid_dir, server_head) catch return error.CorruptLocalState;

    // The replayed commits' changes are part of the folder again: tracked
    // must reflect them (materialize already wrote the merged tree).
    deletePullState(io, ws);
    return .{ .replayed = .{ .commits = kept, .files_changed = changed, .head_commit = server_head } };
}

/// 'cid checkout --mine|--theirs <path>': records one decision for a
/// conflicted pull. Returns how many paths are still undecided.
pub fn decide(
    arena: std.mem.Allocator,
    io: std.Io,
    ws: *workspace.Workspace,
    path: []const u8,
    choice: Choice,
) Error!union(enum) { remaining: usize, no_conflicts, unknown_path } {
    const prior = loadPullState(arena, io, ws) orelse return .no_conflicts;
    var map: std.StringArrayHashMapUnmanaged(Choice) = .empty;
    for (prior) |c| try map.put(arena, c.path, c.choice);
    const slot = map.getPtr(path) orelse return .unknown_path;
    slot.* = choice;
    try savePullState(arena, io, ws, map);
    var remaining: usize = 0;
    for (map.values()) |c| {
        if (c == .undecided) remaining += 1;
    }
    return .{ .remaining = remaining };
}

pub fn pendingConflicts(arena: std.mem.Allocator, io: std.Io, ws: *workspace.Workspace) ?[]const Conflict {
    return loadPullState(arena, io, ws);
}

// --- pull-state: .cid/pull-state, one conflict per line -------------------

fn loadPullState(arena: std.mem.Allocator, io: std.Io, ws: *workspace.Workspace) ?[]const Conflict {
    const text = ws.cid_dir.readFileAlloc(io, "pull-state", arena, .limited(16 * 1024 * 1024)) catch return null;
    var out: std.ArrayList(Conflict) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    const header = lines.next() orelse return null;
    if (!std.mem.eql(u8, header, "cid-pull 1")) return null;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return null;
        const choice = std.meta.stringToEnum(Choice, line[0..tab]) orelse return null;
        out.append(arena, .{ .path = line[tab + 1 ..], .choice = choice }) catch return null;
    }
    return out.items;
}

fn savePullState(arena: std.mem.Allocator, io: std.Io, ws: *workspace.Workspace, map: std.StringArrayHashMapUnmanaged(Choice)) Error!void {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "cid-pull 1\n");
    for (map.keys(), map.values()) |path, choice| {
        try out.print(arena, "{t}\t{s}\n", .{ choice, path });
    }
    local.writeFileAtomic(io, ws.cid_dir, "pull-state", out.items) catch return error.CorruptLocalState;
}

fn deletePullState(io: std.Io, ws: *workspace.Workspace) void {
    ws.cid_dir.deleteFile(io, "pull-state") catch {};
}

fn deleteCommitFile(io: std.Io, ws: *workspace.Workspace, id: anytype) void {
    var buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "commits/{s}", .{&id.toString()}) catch return;
    ws.cid_dir.deleteFile(io, name) catch {};
}

fn stagedCount(arena: std.mem.Allocator, io: std.Io, ws: *workspace.Workspace) Error!usize {
    const text = ws.cid_dir.readFileAlloc(io, "index", arena, .limited(256 * 1024 * 1024)) catch
        return error.CorruptLocalState;
    const idx = index_mod.Index.parse(arena, text) catch return error.CorruptLocalState;
    return idx.len();
}

/// Switches the folder to any commit, on `branch`. The same safety rules
/// as pull; a branch switch also moves where server history is rooted.
pub fn checkout(
    arena: std.mem.Allocator,
    io: std.Io,
    ws: *workspace.Workspace,
    cache_dir: std.Io.Dir,
    remote: *const Remote,
    branch: []const u8,
    commit_id: []const u8,
    move_root: bool,
) Error!u32 {
    const last_pushed = local.readLastPushed(arena, io, ws.cid_dir);
    const unpushed = local.listUnpushed(arena, io, ws.cid_dir, last_pushed) catch
        return error.CorruptLocalState;
    if (unpushed.len > 0) return error.UnpushedCommits;

    const items = try remote.state(arena, commit_id);
    const changed = try materialize(arena, io, ws, cache_dir, remote, items);
    try setPosition(io, ws, branch, commit_id);
    if (move_root)
        local.writeLastPushed(io, ws.cid_dir, commit_id) catch return error.CorruptLocalState;
    return changed;
}

/// Brings the working folder and tracked tree to exactly `items`:
/// downloads what the cache lacks, places changed files, removes tracked
/// files that no longer exist. Only touched files transfer. Refuses when
/// an affected path carries local unstaged edits.
fn materialize(
    arena: std.mem.Allocator,
    io: std.Io,
    ws: *workspace.Workspace,
    cache_dir: std.Io.Dir,
    remote: *const Remote,
    items: []const remote_mod.Remote.StateItem,
) Error!u32 {
    var tracked = loadTracked(arena, io, ws) catch return error.CorruptLocalState;
    const files = scan.scanWorkdir(arena, io, ws.work_dir) catch return error.CorruptLocalState;

    // Safety first: an affected path with local edits stops everything.
    for (items) |item| {
        if (tracked.get(item.path)) |t| {
            if (std.mem.eql(u8, &t.hash_hex, item.hash)) continue; // unchanged
            if (findFile(files, item.path)) |f| {
                if (f.size != t.size or f.mtime_ns != t.mtime_ns) return error.LocalChangesInTheWay;
            }
        }
    }
    for (tracked.entries.items) |t| {
        if (findState(items, t.path) == null) {
            if (findFile(files, t.path)) |f| {
                if (f.size != t.size or f.mtime_ns != t.mtime_ns) return error.LocalChangesInTheWay;
            }
        }
    }

    // Download what the cache lacks, in one presign batch.
    var need: std.ArrayList([]const u8) = .empty;
    for (items) |item| {
        if (!remote_mod.inCache(io, cache_dir, item.hash)) {
            var seen = false;
            for (need.items) |h| {
                if (std.mem.eql(u8, h, item.hash)) {
                    seen = true;
                    break;
                }
            }
            if (!seen) try need.append(arena, item.hash);
        }
    }
    if (need.items.len > 0) {
        const urls = try remote.downloads(arena, need.items);
        for (urls) |dl| try remote_mod.downloadToCache(arena, io, cache_dir, dl.hash, dl.url);
    }

    // Place changed and new files; drop vanished ones; rebuild tracked.
    var changed: u32 = 0;
    var new_tracked = index_mod.Tracked.init(arena);
    for (items) |item| {
        const unchanged = if (tracked.get(item.path)) |t| std.mem.eql(u8, &t.hash_hex, item.hash) else false;
        if (!unchanged) {
            try remote_mod.placeFromCache(io, cache_dir, item.hash, ws.work_dir, item.path);
            changed += 1;
        }
        const stat = ws.work_dir.statFile(io, item.path, .{}) catch return error.CorruptLocalState;
        var entry: index_mod.TrackedEntry = .{
            .path = item.path,
            .hash_hex = undefined,
            .size = stat.size,
            .mtime_ns = @intCast(stat.mtime.nanoseconds),
        };
        @memcpy(&entry.hash_hex, item.hash);
        new_tracked.put(entry) catch return error.CorruptLocalState;
    }
    for (tracked.entries.items) |t| {
        if (findState(items, t.path) == null) {
            ws.work_dir.deleteFile(io, t.path) catch {};
            changed += 1;
        }
    }

    saveTracked(arena, io, ws, &new_tracked) catch return error.CorruptLocalState;
    local.writeFileAtomic(io, ws.cid_dir, "index", "cid-index 1\n") catch return error.CorruptLocalState;
    return changed;
}

// --------------------------------------------------------------------------
// Position bookkeeping: `.cid/HEAD` holds the commit this folder sits on —
// local and server commits share one id space, so after clone, pull or
// checkout it is simply the server commit. `.cid/last-pushed` marks where
// server history begins (no local files below it).
// --------------------------------------------------------------------------

fn setPosition(io: std.Io, ws: *workspace.Workspace, branch: []const u8, commit_id: []const u8) Error!void {
    const Uuid = @import("../util/uuid7.zig").Uuid;
    const id = Uuid.parse(commit_id) catch return error.CorruptLocalState;
    local.saveHead(io, ws.cid_dir, .{ .branch = branch, .commit = id }) catch
        return error.CorruptLocalState;
}

fn sizeOf(commits: []const local.Commit, hash: []const u8) ?u64 {
    for (commits) |commit| {
        for (commit.changes) |ch| {
            if (ch.op == .add and std.mem.eql(u8, &ch.hash_hex, hash)) return ch.size;
        }
    }
    return null;
}

fn findFile(files: []const scan.FileInfo, path: []const u8) ?scan.FileInfo {
    for (files) |f| {
        if (std.mem.eql(u8, f.path, path)) return f;
    }
    return null;
}

fn findState(items: []const remote_mod.Remote.StateItem, path: []const u8) ?remote_mod.Remote.StateItem {
    for (items) |item| {
        if (std.mem.eql(u8, item.path, path)) return item;
    }
    return null;
}

fn loadTracked(arena: std.mem.Allocator, io: std.Io, ws: *workspace.Workspace) !index_mod.Tracked {
    const text = try ws.cid_dir.readFileAlloc(io, "tracked", arena, .limited(256 * 1024 * 1024));
    return index_mod.Tracked.parse(arena, text);
}

fn saveTracked(arena: std.mem.Allocator, io: std.Io, ws: *workspace.Workspace, tracked: *index_mod.Tracked) !void {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try tracked.serialize(&aw.writer);
    try local.writeFileAtomic(io, ws.cid_dir, "tracked", aw.writer.buffered());
}
