//! push, clone, pull, checkout: moving history and content between the
//! local folder and the server. Content rides presigned URLs; history
//! rides the API. Every downloaded file is hash-verified before it lands.
//!
//! v0 limits, stated loudly where they bite: pull cannot yet replay
//! unpushed local commits onto new server history (it says so and asks
//! you to push or wait for that slice), and branches beyond the current
//! one are untouched.

const std = @import("std");
const workspace = @import("workspace.zig");
const local = @import("local.zig");
const index_mod = @import("index.zig");
const scan = @import("scan.zig");
const remote_mod = @import("remote.zig");

pub const Remote = remote_mod.Remote;

pub const Error = error{
    EmptyDataset,
    UnpushedCommits,
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
};

/// Fills an empty folder from the server's branch head and writes `.cid/`.
pub fn clone(
    arena: std.mem.Allocator,
    io: std.Io,
    dest_dir: std.Io.Dir,
    cache_dir: std.Io.Dir,
    remote: *const Remote,
    address: []const u8,
) Error!CloneOutcome {
    const info = try remote.info(arena);
    const head_commit = (try remote.head(arena, "main")) orelse return error.EmptyDataset;
    const items = try remote.state(arena, head_commit);

    workspace.init(arena, io, dest_dir, address, info.git_url) catch
        return error.CorruptLocalState;
    var ws = workspace.open(arena, io, dest_dir) catch return error.CorruptLocalState;

    const downloaded = try materialize(arena, io, &ws, cache_dir, remote, items);

    try setPosition(io, &ws, head_commit);
    local.writeLastPushed(io, ws.cid_dir, head_commit) catch return error.CorruptLocalState;
    return .{ .files = @intCast(items.len), .downloaded = downloaded, .head_commit = head_commit };
}

pub const PullOutcome = union(enum) {
    already_up_to_date,
    fast_forwarded: struct { files_changed: u32, head_commit: []const u8 },
};

/// Fast-forwards the folder to the server head. Local unstaged edits on
/// affected paths stop the pull (nothing is overwritten silently), and
/// unpushed commits stop it too until replay lands.
pub fn pull(
    arena: std.mem.Allocator,
    io: std.Io,
    ws: *workspace.Workspace,
    cache_dir: std.Io.Dir,
    remote: *const Remote,
) Error!PullOutcome {
    const server_head = (try remote.head(arena, "main")) orelse return error.EmptyDataset;
    const head = local.loadHead(arena, io, ws.cid_dir) catch return error.CorruptLocalState;
    if (head.commit) |c| {
        if (std.mem.eql(u8, &c.toString(), server_head)) return .already_up_to_date;
    }

    const last_pushed = local.readLastPushed(arena, io, ws.cid_dir);
    const unpushed = local.listUnpushed(arena, io, ws.cid_dir, last_pushed) catch
        return error.CorruptLocalState;
    if (unpushed.len > 0) return error.UnpushedCommits;

    const items = try remote.state(arena, server_head);
    const changed = try materialize(arena, io, ws, cache_dir, remote, items);
    try setPosition(io, ws, server_head);
    local.writeLastPushed(io, ws.cid_dir, server_head) catch return error.CorruptLocalState;
    return .{ .fast_forwarded = .{ .files_changed = changed, .head_commit = server_head } };
}

/// Switches the folder to any commit. The same safety rules as pull.
pub fn checkout(
    arena: std.mem.Allocator,
    io: std.Io,
    ws: *workspace.Workspace,
    cache_dir: std.Io.Dir,
    remote: *const Remote,
    commit_id: []const u8,
) Error!u32 {
    const items = try remote.state(arena, commit_id);
    const changed = try materialize(arena, io, ws, cache_dir, remote, items);
    try setPosition(io, ws, commit_id);
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

fn setPosition(io: std.Io, ws: *workspace.Workspace, commit_id: []const u8) Error!void {
    const Uuid = @import("../util/uuid7.zig").Uuid;
    const id = Uuid.parse(commit_id) catch return error.CorruptLocalState;
    local.saveHead(io, ws.cid_dir, .{ .branch = "main", .commit = id }) catch
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
