//! A working folder with its `.cid/` state: find it, create it (`init`),
//! stage into it (`add`), seal a local commit (`commit`), report (`status`).
//! Everything here is offline; the server enters at `push`.

const std = @import("std");
const index_mod = @import("index.zig");
const local = @import("local.zig");
const scan = @import("scan.zig");
const cache = @import("cache.zig");
const Uuid = @import("../util/uuid7.zig").Uuid;

pub const Config = struct {
    address: []const u8,
    git_url: []const u8,
};

pub const Workspace = struct {
    work_dir: std.Io.Dir,
    cid_dir: std.Io.Dir,
    config: Config,

    /// Closes `.cid/`; `work_dir` is caller-owned and stays open.
    pub fn close(self: *Workspace, io: std.Io) void {
        self.cid_dir.close(io);
    }
};

pub const OpenError = error{ NotADataset, CorruptLocalState } || std.mem.Allocator.Error;

/// Opens the dataset folder that contains `dir` (the folder itself; walking
/// up to a parent folder comes with `clone`).
pub fn open(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) OpenError!Workspace {
    const cid_dir = dir.openDir(io, ".cid", .{}) catch return error.NotADataset;
    const config_text = cid_dir.readFileAllocOptions(io, "config.zon", arena, .limited(64 * 1024), .of(u8), 0) catch
        return error.CorruptLocalState;
    const config = std.zon.parse.fromSliceAlloc(Config, arena, config_text, null, .{}) catch
        return error.CorruptLocalState;
    return .{ .work_dir = dir, .cid_dir = cid_dir, .config = config };
}

pub const InitError = error{ AlreadyADataset, BadAddress, InitFailed } || std.mem.Allocator.Error;

/// Creates `.cid/` in `dir`. Server registration and the git-repository
/// checks happen when the server face lands; the local state is final.
pub fn init(
    arena: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    address: []const u8,
    git_url: []const u8,
) InitError!void {
    if (datasetPathOf(address) == null) return error.BadAddress;
    if (dir.access(io, ".cid", .{})) |_| return error.AlreadyADataset else |_| {}

    dir.createDirPath(io, ".cid/commits") catch return error.InitFailed;
    var cid_dir = dir.openDir(io, ".cid", .{}) catch return error.InitFailed;
    defer cid_dir.close(io);

    var config_buf: std.ArrayList(u8) = .empty;
    var aw: std.Io.Writer.Allocating = .init(arena);
    std.zon.stringify.serialize(Config{ .address = address, .git_url = git_url }, .{}, &aw.writer) catch
        return error.InitFailed;
    config_buf.appendSlice(arena, aw.writer.buffered()) catch return error.InitFailed;
    config_buf.append(arena, '\n') catch return error.InitFailed;

    local.writeFileAtomic(io, cid_dir, "config.zon", config_buf.items) catch return error.InitFailed;
    local.saveHead(io, cid_dir, .{ .branch = "main", .commit = null }) catch return error.InitFailed;
    local.writeFileAtomic(io, cid_dir, "index", "cid-index 1\n") catch return error.InitFailed;
    local.writeFileAtomic(io, cid_dir, "tracked", "cid-tracked 1\n") catch return error.InitFailed;
}

/// The dataset path inside an address: cid@host:org/datasets/name → org/datasets/name.
/// A trailing .cid is accepted and ignored (CLAUDE.md, words).
pub fn datasetPathOf(address: []const u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, address, ':') orelse return null;
    const at = std.mem.indexOfScalar(u8, address, '@') orelse return null;
    if (at > colon) return null;
    var path = address[colon + 1 ..];
    if (std.mem.endsWith(u8, path, ".cid")) path = path[0 .. path.len - ".cid".len];
    if (path.len == 0) return null;
    return path;
}

pub const AddError = error{ PathspecUnmatched, CorruptLocalState, StoreFailed } ||
    std.mem.Allocator.Error;

pub const AddSummary = struct {
    staged_adds: u32 = 0,
    staged_deletes: u32 = 0,
};

/// `cid add <paths>`: stage every added, changed and deleted file under the
/// given paths. "." means everything. Files are hashed and copied into the
/// local cache now, so commit never touches content again.
pub fn add(
    arena: std.mem.Allocator,
    io: std.Io,
    ws: *Workspace,
    cache_dir: std.Io.Dir,
    raw_paths: []const []const u8,
) AddError!AddSummary {
    var idx = loadIndex(arena, io, ws) catch return error.CorruptLocalState;
    var tracked = loadTracked(arena, io, ws) catch return error.CorruptLocalState;
    const files = scan.scanWorkdir(arena, io, ws.work_dir) catch return error.CorruptLocalState;

    var specs = try arena.alloc([]const u8, raw_paths.len);
    for (raw_paths, 0..) |raw, i| specs[i] = normalizeSpec(raw);

    var matched = try arena.alloc(bool, specs.len);
    @memset(matched, false);
    var summary: AddSummary = .{};

    // Present files under the given paths: stage when new or changed.
    for (files) |f| {
        const spec_i = matchSpec(specs, f.path) orelse continue;
        matched[spec_i] = true;

        if (tracked.get(f.path)) |t| {
            if (t.size == f.size and t.mtime_ns == f.mtime_ns) {
                // Unchanged since last commit; drop any stale staged entry.
                if (idx.get(f.path)) |staged| {
                    if (staged.op == .delete) _ = idx.remove(f.path);
                }
                continue;
            }
        }
        const stored = cache.storeFile(io, ws.work_dir, f.path, cache_dir) catch
            return error.StoreFailed;
        if (tracked.get(f.path)) |t| {
            if (std.mem.eql(u8, &t.hash_hex, &stored.hash_hex)) {
                // Touched but identical; remember the new mtime to keep status fast.
                tracked.put(.{ .path = f.path, .hash_hex = t.hash_hex, .size = f.size, .mtime_ns = f.mtime_ns }) catch
                    return error.CorruptLocalState;
                _ = idx.remove(f.path);
                continue;
            }
        }
        idx.put(.{ .op = .add, .path = f.path, .hash_hex = stored.hash_hex, .size = stored.size, .mtime_ns = f.mtime_ns }) catch
            return error.CorruptLocalState;
        summary.staged_adds += 1;
    }

    // Tracked or staged paths under the given paths that are gone from disk:
    // stage the delete.
    for (tracked.entries.items) |t| {
        const spec_i = matchSpec(specs, t.path) orelse continue;
        matched[spec_i] = true;
        if (findFile(files, t.path) == null) {
            if (idx.get(t.path) == null or idx.get(t.path).?.op != .delete) {
                idx.put(.{ .op = .delete, .path = t.path, .hash_hex = undefined, .size = 0, .mtime_ns = 0 }) catch
                    return error.CorruptLocalState;
                summary.staged_deletes += 1;
            }
        }
    }
    // A staged add whose file vanished again: unstage it.
    var i: usize = 0;
    while (i < idx.entries.items.len) {
        const e = idx.entries.items[i];
        if (e.op == .add and matchSpec(specs, e.path) != null and findFile(files, e.path) == null and tracked.get(e.path) == null) {
            _ = idx.remove(e.path);
            continue;
        }
        i += 1;
    }

    for (specs, 0..) |spec, si| {
        if (!matched[si] and !std.mem.eql(u8, spec, ".")) return error.PathspecUnmatched;
    }

    saveIndex(arena, io, ws, &idx) catch return error.CorruptLocalState;
    saveTracked(arena, io, ws, &tracked) catch return error.CorruptLocalState;
    return summary;
}

pub const CommitError = error{ NothingStaged, CorruptLocalState } || std.mem.Allocator.Error;

pub const CommitSummary = struct {
    id: Uuid,
    changes: u32,
};

pub fn commit(
    arena: std.mem.Allocator,
    io: std.Io,
    ws: *Workspace,
    message: []const u8,
    author: []const u8,
) CommitError!CommitSummary {
    var idx = loadIndex(arena, io, ws) catch return error.CorruptLocalState;
    if (idx.len() == 0) return error.NothingStaged;
    var tracked = loadTracked(arena, io, ws) catch return error.CorruptLocalState;
    const head = local.loadHead(arena, io, ws.cid_dir) catch return error.CorruptLocalState;

    const changes = try arena.alloc(local.Change, idx.len());
    for (idx.entries.items, 0..) |e, i| {
        changes[i] = .{ .op = e.op, .path = e.path, .hash_hex = e.hash_hex, .size = e.size };
    }

    const id = Uuid.now(io);
    const new_commit: local.Commit = .{
        .id = id,
        .parent = head.commit,
        .branch = head.branch,
        .author = author,
        .authored_at_ms = id.unixMs(),
        .message = message,
        .changes = changes,
    };
    // Order matters for recoverability (invariant 16): the commit file first,
    // then tracked, then the cleared index, then HEAD last. A crash between
    // any two steps is repaired by re-running the command.
    local.saveCommit(arena, io, ws.cid_dir, new_commit) catch return error.CorruptLocalState;
    for (idx.entries.items) |e| {
        switch (e.op) {
            .add => tracked.put(.{ .path = e.path, .hash_hex = e.hash_hex, .size = e.size, .mtime_ns = e.mtime_ns }) catch
                return error.CorruptLocalState,
            .delete => _ = tracked.remove(e.path),
        }
    }
    saveTracked(arena, io, ws, &tracked) catch return error.CorruptLocalState;
    local.writeFileAtomic(io, ws.cid_dir, "index", "cid-index 1\n") catch return error.CorruptLocalState;
    local.saveHead(io, ws.cid_dir, .{ .branch = head.branch, .commit = id }) catch return error.CorruptLocalState;

    return .{ .id = id, .changes = @intCast(changes.len) };
}

pub const Status = struct {
    branch: []const u8,
    local_commits: u32,
    staged: []const index_mod.Entry,
    unstaged_new: []const []const u8,
    unstaged_modified: []const []const u8,
    unstaged_deleted: []const []const u8,
};

pub fn status(arena: std.mem.Allocator, io: std.Io, ws: *Workspace) !Status {
    const idx = loadIndex(arena, io, ws) catch return error.CorruptLocalState;
    const tracked = loadTracked(arena, io, ws) catch return error.CorruptLocalState;
    const head = local.loadHead(arena, io, ws.cid_dir) catch return error.CorruptLocalState;
    const files = scan.scanWorkdir(arena, io, ws.work_dir) catch return error.CorruptLocalState;
    const commits = local.listLocalCommits(arena, io, ws.cid_dir) catch return error.CorruptLocalState;

    var unstaged_new: std.ArrayList([]const u8) = .empty;
    var unstaged_modified: std.ArrayList([]const u8) = .empty;
    var unstaged_deleted: std.ArrayList([]const u8) = .empty;

    for (files) |f| {
        if (idx.get(f.path)) |staged| {
            if (staged.op == .add and (staged.size != f.size or staged.mtime_ns != f.mtime_ns))
                try unstaged_modified.append(arena, f.path);
            if (staged.op == .delete)
                try unstaged_new.append(arena, f.path); // deleted then re-created
            continue;
        }
        if (tracked.get(f.path)) |t| {
            if (t.size != f.size or t.mtime_ns != f.mtime_ns)
                try unstaged_modified.append(arena, f.path);
        } else {
            try unstaged_new.append(arena, f.path);
        }
    }
    for (tracked.entries.items) |t| {
        if (findFile(files, t.path) == null and idx.get(t.path) == null)
            try unstaged_deleted.append(arena, t.path);
    }

    return .{
        .branch = head.branch,
        .local_commits = @intCast(commits.len),
        .staged = idx.entries.items,
        .unstaged_new = unstaged_new.items,
        .unstaged_modified = unstaged_modified.items,
        .unstaged_deleted = unstaged_deleted.items,
    };
}

fn loadIndex(arena: std.mem.Allocator, io: std.Io, ws: *Workspace) !index_mod.Index {
    const text = try ws.cid_dir.readFileAlloc(io, "index", arena, .limited(256 * 1024 * 1024));
    return index_mod.Index.parse(arena, text);
}

fn saveIndex(arena: std.mem.Allocator, io: std.Io, ws: *Workspace, idx: *index_mod.Index) !void {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try idx.serialize(&aw.writer);
    try local.writeFileAtomic(io, ws.cid_dir, "index", aw.writer.buffered());
}

fn loadTracked(arena: std.mem.Allocator, io: std.Io, ws: *Workspace) !index_mod.Tracked {
    const text = try ws.cid_dir.readFileAlloc(io, "tracked", arena, .limited(256 * 1024 * 1024));
    return index_mod.Tracked.parse(arena, text);
}

fn saveTracked(arena: std.mem.Allocator, io: std.Io, ws: *Workspace, tracked: *index_mod.Tracked) !void {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try tracked.serialize(&aw.writer);
    try local.writeFileAtomic(io, ws.cid_dir, "tracked", aw.writer.buffered());
}

fn normalizeSpec(raw: []const u8) []const u8 {
    var spec = raw;
    if (std.mem.startsWith(u8, spec, "./")) spec = spec[2..];
    while (spec.len > 1 and spec[spec.len - 1] == '/') spec = spec[0 .. spec.len - 1];
    if (spec.len == 0) spec = ".";
    return spec;
}

fn matchSpec(specs: []const []const u8, path: []const u8) ?usize {
    for (specs, 0..) |spec, i| {
        if (std.mem.eql(u8, spec, ".")) return i;
        if (std.mem.eql(u8, spec, path)) return i;
        if (path.len > spec.len and std.mem.startsWith(u8, path, spec) and path[spec.len] == '/') return i;
    }
    return null;
}

fn findFile(files: []const scan.FileInfo, path: []const u8) ?scan.FileInfo {
    for (files) |f| {
        if (std.mem.eql(u8, f.path, path)) return f;
    }
    return null;
}

test "address parsing" {
    try std.testing.expectEqualStrings(
        "your-org/datasets/person-vehicle",
        datasetPathOf("cid@cidhub.com:your-org/datasets/person-vehicle").?,
    );
    try std.testing.expectEqualStrings(
        "a/b",
        datasetPathOf("cid@h:a/b.cid").?,
    );
    try std.testing.expect(datasetPathOf("no-colon") == null);
    try std.testing.expect(datasetPathOf("host:path-no-user") == null);
    try std.testing.expect(datasetPathOf("cid@host:") == null);
}

test "init, add, commit, status: the offline loop" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var cache_tmp = std.testing.tmpDir(.{});
    defer cache_tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try tmp.dir.createDirPath(io, "audio");
    try tmp.dir.writeFile(io, .{ .sub_path = "audio/a.wav", .data = "wavwav" });
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "n" });

    try init(arena, io, tmp.dir, "cid@cidhub.com:org/datasets/demo", "git@example.invalid:org/datasets/demo.git");
    try std.testing.expectError(error.AlreadyADataset, init(arena, io, tmp.dir, "cid@h:a/b", "g"));

    var ws = try open(arena, io, tmp.dir);
    try std.testing.expectEqualStrings("cid@cidhub.com:org/datasets/demo", ws.config.address);

    // Stage everything; both files land in the index and the cache.
    const added = try add(arena, io, &ws, cache_tmp.dir, &.{"."});
    try std.testing.expectEqual(@as(u32, 2), added.staged_adds);

    var st = try status(arena, io, &ws);
    try std.testing.expectEqual(@as(usize, 2), st.staged.len);
    try std.testing.expectEqual(@as(u32, 0), st.local_commits);

    // Commit; staging empties, tracked fills, HEAD advances.
    const first = try commit(arena, io, &ws, "first", "user:test");
    try std.testing.expectEqual(@as(u32, 2), first.changes);
    try std.testing.expectError(error.NothingStaged, commit(arena, io, &ws, "again", "user:test"));

    st = try status(arena, io, &ws);
    try std.testing.expectEqual(@as(usize, 0), st.staged.len);
    try std.testing.expectEqual(@as(u32, 1), st.local_commits);
    try std.testing.expectEqual(@as(usize, 0), st.unstaged_new.len);

    // Change one file, delete another, add a third: status sees all three unstaged.
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "changed!" });
    try tmp.dir.deleteFile(io, "audio/a.wav");
    try tmp.dir.writeFile(io, .{ .sub_path = "new.bin", .data = "\x00\x01" });

    st = try status(arena, io, &ws);
    try std.testing.expectEqual(@as(usize, 1), st.unstaged_modified.len);
    try std.testing.expectEqual(@as(usize, 1), st.unstaged_deleted.len);
    try std.testing.expectEqual(@as(usize, 1), st.unstaged_new.len);

    // Partial staging: only the delete under audio/.
    const partial = try add(arena, io, &ws, cache_tmp.dir, &.{"audio"});
    try std.testing.expectEqual(@as(u32, 0), partial.staged_adds);
    try std.testing.expectEqual(@as(u32, 1), partial.staged_deletes);

    // A pathspec that matches nothing is an error.
    try std.testing.expectError(error.PathspecUnmatched, add(arena, io, &ws, cache_tmp.dir, &.{"nope.txt"}));

    // Stage the rest and commit; the second commit chains to the first.
    _ = try add(arena, io, &ws, cache_tmp.dir, &.{"."});
    const second = try commit(arena, io, &ws, "second", "user:test");
    try std.testing.expectEqual(@as(u32, 3), second.changes);

    const commits = try local.listLocalCommits(arena, io, ws.cid_dir);
    try std.testing.expectEqual(@as(usize, 2), commits.len);
    try std.testing.expectEqualStrings("second", commits[0].message);
    try std.testing.expectEqualSlices(u8, &first.id.bytes, &commits[0].parent.?.bytes);

    st = try status(arena, io, &ws);
    try std.testing.expectEqual(@as(usize, 0), st.staged.len);
    try std.testing.expectEqual(@as(usize, 0), st.unstaged_new.len);
    try std.testing.expectEqual(@as(usize, 0), st.unstaged_modified.len);
    try std.testing.expectEqual(@as(usize, 0), st.unstaged_deleted.len);
    try std.testing.expectEqual(@as(u32, 2), st.local_commits);
}
