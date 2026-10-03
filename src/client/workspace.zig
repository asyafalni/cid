//! A working folder with its `.cid/` state: find it, create it (`init`),
//! stage into it (`add`), seal a local commit (`commit`), report (`status`).
//! Everything here is offline; the server enters at `push`.

const std = @import("std");
const Progress = @import("../util/progress.zig").Progress;
const index_mod = @import("index.zig");
const local = @import("local.zig");
const scan = @import("scan.zig");
const cache = @import("cache.zig");
const Uuid = @import("../util/uuid7.zig").Uuid;

pub const Config = struct {
    address: []const u8,
    git_url: []const u8,
    /// 'files' | 'annotated'; folders made by older builds default to files.
    kind: []const u8 = "files",
    /// The export format this folder was cloned with ('files' = plain tree).
    format: []const u8 = "files",
    /// A subset clone keeps only items in these splits (empty: all).
    split: []const []const u8 = &.{},
    /// …and, in annotated datasets, only items carrying one of these
    /// classes, with annotations narrowed to them (empty: all).
    class: []const []const u8 = &.{},
};

/// What `cid clone --split/--class` asked for. Recorded in config.zon so
/// `pull` and `checkout` keep the folder the same shape.
pub const Subset = struct {
    split: []const []const u8 = &.{},
    class: []const []const u8 = &.{},

    pub fn active(self: Subset) bool {
        return self.split.len > 0 or self.class.len > 0;
    }

    pub fn of(config: Config) Subset {
        return .{ .split = config.split, .class = config.class };
    }

    /// "split train · class person, vehicle", for status and clone.
    pub fn describe(self: Subset, arena: std.mem.Allocator) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        if (self.split.len > 0) {
            try out.appendSlice(arena, "split ");
            try joinInto(arena, &out, self.split);
        }
        if (self.class.len > 0) {
            if (out.items.len > 0) try out.appendSlice(arena, " \xc2\xb7 ");
            try out.appendSlice(arena, "class ");
            try joinInto(arena, &out, self.class);
        }
        return out.items;
    }

    fn joinInto(arena: std.mem.Allocator, out: *std.ArrayList(u8), values: []const []const u8) !void {
        for (values, 0..) |v, i| {
            if (i > 0) try out.appendSlice(arena, ", ");
            try out.appendSlice(arena, v);
        }
    }
};

/// Why this folder cannot record changes, or null when it can. An
/// annotated export is generated from the platform's annotations, and a
/// subset holds only part of the tree, so a commit from it would read the
/// files it left out as deleted. Both stay current through 'cid pull'.
pub fn readOnlyReason(arena: std.mem.Allocator, config: Config) ?[]const u8 {
    const subset = Subset.of(config);
    if (subset.active()) {
        const what = subset.describe(arena) catch "a subset";
        return std.fmt.allocPrint(
            arena,
            "This folder is a subset ({s}), so it cannot record changes: the files it left out would look deleted. Run 'cid pull' to update it, or clone without --split/--class to change the dataset.",
            .{what},
        ) catch "This folder is a subset, so it cannot record changes. Run 'cid pull' to update it.";
    }
    // Annotated datasets change only in the platform (CLAUDE.md, two
    // kinds of dataset), whatever format the folder was cloned in.
    if (std.mem.eql(u8, config.kind, "annotated")) {
        return "This is an export of an annotated dataset. Annotations change in the annotation platform; run 'cid pull' to update.";
    }
    return null;
}

pub const Workspace = struct {
    work_dir: std.Io.Dir,
    cid_dir: std.Io.Dir,
    config: Config,
    /// Where `add` reports the hashing of large changes (the CLI sets it).
    progress: ?*Progress = null,

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

/// Creates `.cid/` in `dir`: the local half of `cid init` (the command
/// registers the dataset on the server first, which checks its git
/// repository, when a server is reachable).
pub fn init(
    arena: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    address: []const u8,
    git_url: []const u8,
) InitError!void {
    return initFull(arena, io, dir, address, git_url, "files", "files", .{});
}

pub fn initFull(
    arena: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    address: []const u8,
    git_url: []const u8,
    kind: []const u8,
    format: []const u8,
    subset: Subset,
) InitError!void {
    if (datasetPathOf(address) == null) return error.BadAddress;
    if (dir.access(io, ".cid", .{})) |_| return error.AlreadyADataset else |_| {}

    dir.createDirPath(io, ".cid/commits") catch return error.InitFailed;
    var cid_dir = dir.openDir(io, ".cid", .{}) catch return error.InitFailed;
    defer cid_dir.close(io);

    var config_buf: std.ArrayList(u8) = .empty;
    var aw: std.Io.Writer.Allocating = .init(arena);
    std.zon.stringify.serialize(Config{
        // Never a token: a folder is zipped and shared, and credentials
        // given in an https address are for the command they came with.
        .address = withoutCredentials(arena, address) catch return error.InitFailed,
        .git_url = git_url,
        .kind = kind,
        .format = format,
        .split = subset.split,
        .class = subset.class,
    }, .{}, &aw.writer) catch
        return error.InitFailed;
    config_buf.appendSlice(arena, aw.writer.buffered()) catch return error.InitFailed;
    config_buf.append(arena, '\n') catch return error.InitFailed;

    local.writeFileAtomic(io, cid_dir, "config.zon", config_buf.items) catch return error.InitFailed;
    local.saveHead(io, cid_dir, .{ .branch = "main", .commit = null }) catch return error.InitFailed;
    local.writeFileAtomic(io, cid_dir, "index", "cid-index 1\n") catch return error.InitFailed;
    local.writeFileAtomic(io, cid_dir, "tracked", "cid-tracked 1\n") catch return error.InitFailed;
}

/// An HTTPS address: `https://[name:token@]host[:port]/<dataset path>`,
/// for scripts and machines without SSH, as git takes one. `http://` is
/// accepted for a server on the same machine; anything else should be TLS.
pub const Https = struct {
    scheme: []const u8, // "https://" or "http://"
    host: []const u8, // host[:port]
    path: []const u8,
    /// The password of the credentials, if the address carries them; the
    /// name before it is not read.
    token: ?[]const u8,

    /// Where the API is: scheme, host and port.
    pub fn server(self: Https, arena: std.mem.Allocator) error{OutOfMemory}![]const u8 {
        return std.fmt.allocPrint(arena, "{s}{s}", .{ self.scheme, self.host });
    }
};

pub fn httpsOf(address: []const u8) ?Https {
    const scheme: []const u8 = if (std.mem.startsWith(u8, address, "https://"))
        "https://"
    else if (std.mem.startsWith(u8, address, "http://"))
        "http://"
    else
        return null;
    const rest = address[scheme.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    var host = rest[0..slash];
    var token: ?[]const u8 = null;
    if (std.mem.lastIndexOfScalar(u8, host, '@')) |at| {
        const userinfo = host[0..at];
        if (std.mem.indexOfScalar(u8, userinfo, ':')) |c| {
            if (c + 1 < userinfo.len) token = userinfo[c + 1 ..];
        }
        host = host[at + 1 ..];
    }
    var path = std.mem.trim(u8, rest[slash + 1 ..], "/");
    if (std.mem.endsWith(u8, path, ".cid")) path = path[0 .. path.len - ".cid".len];
    if (host.len == 0 or path.len == 0) return null;
    return .{ .scheme = scheme, .host = host, .path = path, .token = token };
}

/// An address fit to print: any credentials in it hidden, even in one
/// that is not a valid cid address (the CLI never prints a token).
pub fn redacted(arena: std.mem.Allocator, address: []const u8) error{OutOfMemory}![]const u8 {
    const scheme_end = (std.mem.indexOf(u8, address, "://") orelse return address) + 3;
    const rest = address[scheme_end..];
    const authority_end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const at = std.mem.lastIndexOfScalar(u8, rest[0..authority_end], '@') orelse return address;
    return std.fmt.allocPrint(arena, "{s}***@{s}", .{ address[0..scheme_end], rest[at + 1 ..] });
}

/// The address as a folder keeps it: an https one without its credentials.
pub fn withoutCredentials(arena: std.mem.Allocator, address: []const u8) error{OutOfMemory}![]const u8 {
    const h = httpsOf(address) orelse return address;
    return std.fmt.allocPrint(arena, "{s}{s}/{s}", .{ h.scheme, h.host, h.path });
}

/// The dataset path inside an address: cid@host:org/datasets/name → org/datasets/name,
/// https://host/org/datasets/name → the same. A trailing .cid is accepted and
/// ignored (CLAUDE.md, words).
pub fn datasetPathOf(address: []const u8) ?[]const u8 {
    if (httpsOf(address)) |h| return h.path;
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
    return stage(arena, io, ws, cache_dir, raw_paths, false);
}

/// What `cid commit -a` stages first, exactly as `git commit -a`: every
/// change and deletion of a tracked file; new files stay untracked.
pub fn addTracked(arena: std.mem.Allocator, io: std.Io, ws: *Workspace, cache_dir: std.Io.Dir) AddError!AddSummary {
    return stage(arena, io, ws, cache_dir, &.{"."}, true);
}

fn stage(
    arena: std.mem.Allocator,
    io: std.Io,
    ws: *Workspace,
    cache_dir: std.Io.Dir,
    raw_paths: []const []const u8,
    tracked_only: bool,
) AddError!AddSummary {
    var idx = loadIndex(arena, io, ws) catch return error.CorruptLocalState;
    var tracked = loadTracked(arena, io, ws) catch return error.CorruptLocalState;
    const files = scan.scanWorkdir(arena, io, ws.work_dir) catch return error.CorruptLocalState;

    var specs = try arena.alloc([]const u8, raw_paths.len);
    for (raw_paths, 0..) |raw, i| specs[i] = normalizeSpec(raw);

    var matched = try arena.alloc(bool, specs.len);
    @memset(matched, false);
    var summary: AddSummary = .{};

    // What has to be hashed: new files and ones whose size or time moved.
    const fresh = try arena.alloc(bool, files.len);
    var hash_files: u64 = 0;
    var hash_bytes: u64 = 0;
    for (files, fresh) |f, *must| {
        must.* = false;
        const spec_i = matchSpec(specs, f.path) orelse continue;
        matched[spec_i] = true;
        if (tracked_only and tracked.get(f.path) == null) continue;
        if (tracked.get(f.path)) |t| if (t.size == f.size and t.mtime_ns == f.mtime_ns) {
            // Unchanged since last commit; drop any stale staged entry.
            if (idx.get(f.path)) |staged| {
                if (staged.op == .delete) _ = idx.remove(f.path);
            }
            continue;
        };
        must.* = true;
        hash_files += 1;
        hash_bytes += f.size;
    }
    if (ws.progress) |p| p.begin("Hashing", hash_files, hash_bytes);
    defer if (ws.progress) |p| p.end();

    // Present files under the given paths: stage when new or changed.
    for (files, fresh) |f, must| {
        if (!must) continue;
        const stored = cache.storeFile(io, ws.work_dir, f.path, cache_dir, ws.progress) catch
            return error.StoreFailed;
        if (ws.progress) |p| p.fileDone();
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

    // Strictly after the parent, even within the same millisecond.
    const id = Uuid.nextAfter(io, head.commit);
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

pub const RestoreError = error{ PathspecUnmatched, CorruptLocalState, StoreFailed } ||
    std.mem.Allocator.Error;

/// `cid restore --staged <path>...`: unstage. Returns how many entries left
/// the index.
pub fn restoreStaged(
    arena: std.mem.Allocator,
    io: std.Io,
    ws: *Workspace,
    raw_paths: []const []const u8,
) RestoreError!u32 {
    var idx = loadIndex(arena, io, ws) catch return error.CorruptLocalState;
    var specs = try arena.alloc([]const u8, raw_paths.len);
    for (raw_paths, 0..) |raw, i| specs[i] = normalizeSpec(raw);

    var removed: u32 = 0;
    var i: usize = 0;
    while (i < idx.entries.items.len) {
        const e = idx.entries.items[i];
        if (matchSpec(specs, e.path) != null) {
            _ = idx.remove(e.path);
            removed += 1;
            continue;
        }
        i += 1;
    }
    if (removed == 0) return error.PathspecUnmatched;
    saveIndex(arena, io, ws, &idx) catch return error.CorruptLocalState;
    return removed;
}

pub const RestoreSummary = struct {
    restored: u32 = 0,
    /// New files never added to cid: restore leaves them alone.
    skipped_untracked: u32 = 0,
};

/// `cid restore <path>...`: throw away local edits, bringing files back to
/// their staged version (if one is staged) or the last committed one. The
/// bytes come from the local cache, where `add` and every download put them.
pub fn restoreWorktree(
    arena: std.mem.Allocator,
    io: std.Io,
    ws: *Workspace,
    cache_dir: std.Io.Dir,
    raw_paths: []const []const u8,
) RestoreError!RestoreSummary {
    const remote_mod = @import("remote.zig");
    var idx = loadIndex(arena, io, ws) catch return error.CorruptLocalState;
    var tracked = loadTracked(arena, io, ws) catch return error.CorruptLocalState;
    const files = scan.scanWorkdir(arena, io, ws.work_dir) catch return error.CorruptLocalState;

    var specs = try arena.alloc([]const u8, raw_paths.len);
    for (raw_paths, 0..) |raw, i| specs[i] = normalizeSpec(raw);

    var summary: RestoreSummary = .{};
    var matched_any = false;

    // Wanted content per path: the staged add wins over tracked.
    // Paths with a staged delete restore to the tracked version (the
    // delete itself stays staged; use --staged to drop it).
    const Want = struct { path: []const u8, hash_hex: [64]u8, from_index: bool };
    var wants: std.ArrayList(Want) = .empty;
    for (idx.entries.items) |e| {
        if (matchSpec(specs, e.path) == null) continue;
        matched_any = true;
        if (e.op == .add)
            try wants.append(arena, .{ .path = e.path, .hash_hex = e.hash_hex, .from_index = true });
    }
    for (tracked.entries.items) |t| {
        if (matchSpec(specs, t.path) == null) continue;
        matched_any = true;
        if (idx.get(t.path)) |staged| {
            if (staged.op == .add) continue; // index version already wanted
        }
        try wants.append(arena, .{ .path = t.path, .hash_hex = t.hash_hex, .from_index = false });
    }
    for (files) |f| {
        if (matchSpec(specs, f.path) == null) continue;
        if (tracked.get(f.path) == null and idx.get(f.path) == null) {
            matched_any = true;
            summary.skipped_untracked += 1;
        }
    }
    if (!matched_any) return error.PathspecUnmatched;

    for (wants.items) |want| {
        // Skip files already at the wanted content (size+mtime unchanged
        // against where that content was last recorded).
        if (findFile(files, want.path)) |f| {
            const recorded: ?struct { size: u64, mtime_ns: i64 } = if (want.from_index) blk: {
                const e = idx.get(want.path).?;
                break :blk .{ .size = e.size, .mtime_ns = e.mtime_ns };
            } else if (tracked.get(want.path)) |t|
                .{ .size = t.size, .mtime_ns = t.mtime_ns }
            else
                null;
            if (recorded) |r| {
                if (r.size == f.size and r.mtime_ns == f.mtime_ns) continue;
            }
        }
        remote_mod.placeFromCache(io, cache_dir, &want.hash_hex, ws.work_dir, want.path) catch
            return error.StoreFailed;
        const stat = ws.work_dir.statFile(io, want.path, .{}) catch return error.CorruptLocalState;
        if (want.from_index) {
            var e = idx.get(want.path).?;
            e.size = stat.size;
            e.mtime_ns = @intCast(stat.mtime.nanoseconds);
            idx.put(e) catch return error.CorruptLocalState;
        } else if (tracked.get(want.path)) |t| {
            var updated = t;
            updated.size = stat.size;
            updated.mtime_ns = @intCast(stat.mtime.nanoseconds);
            tracked.put(updated) catch return error.CorruptLocalState;
        }
        summary.restored += 1;
    }

    saveIndex(arena, io, ws, &idx) catch return error.CorruptLocalState;
    saveTracked(arena, io, ws, &tracked) catch return error.CorruptLocalState;
    return summary;
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
    const last_pushed = local.readLastPushed(arena, io, ws.cid_dir);
    const commits = local.listUnpushed(arena, io, ws.cid_dir, last_pushed) catch return error.CorruptLocalState;

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
    return scan.findByPath(scan.FileInfo, files, path);
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

test "https addresses: path, server and token, and what a folder keeps" {
    const h = httpsOf("https://ci:cidp_secret@cid.example:8443/org/datasets/speech").?;
    try std.testing.expectEqualStrings("org/datasets/speech", h.path);
    try std.testing.expectEqualStrings("cidp_secret", h.token.?);
    const server = try h.server(std.testing.allocator);
    defer std.testing.allocator.free(server);
    try std.testing.expectEqualStrings("https://cid.example:8443", server);
    try std.testing.expectEqualStrings("org/datasets/speech", datasetPathOf("https://cid.example/org/datasets/speech.cid/").?);
    try std.testing.expect(httpsOf("https://cid.example/org/x").?.token == null);
    try std.testing.expect(httpsOf("https://ci@cid.example/org/x").?.token == null);
    try std.testing.expect(httpsOf("https://cid.example/") == null);
    try std.testing.expect(httpsOf("cid@h:o/d") == null);
    const kept = try withoutCredentials(std.testing.allocator, "https://ci:cidp_secret@cid.example/org/x");
    defer std.testing.allocator.free(kept);
    try std.testing.expectEqualStrings("https://cid.example/org/x", kept);
    const shown = try redacted(std.testing.allocator, "https://ci:cidp_secret@cid.example/");
    defer std.testing.allocator.free(shown);
    try std.testing.expectEqualStrings("https://***@cid.example/", shown);
    try std.testing.expectEqualStrings("cid@h:o/d", try redacted(std.testing.allocator, "cid@h:o/d"));
}

test "restore: unstage, throw away edits, leave untracked files alone" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var cache_tmp = std.testing.tmpDir(.{});
    defer cache_tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try tmp.dir.writeFile(io, .{ .sub_path = "keep.txt", .data = "committed content" });
    try init(arena, io, tmp.dir, "cid@h:org/datasets/r", "g@h:r.git");
    var ws = try open(arena, io, tmp.dir);
    _ = try add(arena, io, &ws, cache_tmp.dir, &.{"."});
    _ = try commit(arena, io, &ws, "base", "user:test");

    // restore --staged unstages without touching the file.
    try tmp.dir.writeFile(io, .{ .sub_path = "keep.txt", .data = "edited!" });
    _ = try add(arena, io, &ws, cache_tmp.dir, &.{"."});
    var st = try status(arena, io, &ws);
    try std.testing.expectEqual(@as(usize, 1), st.staged.len);
    const removed = try restoreStaged(arena, io, &ws, &.{"keep.txt"});
    try std.testing.expectEqual(@as(u32, 1), removed);
    st = try status(arena, io, &ws);
    try std.testing.expectEqual(@as(usize, 0), st.staged.len);
    try std.testing.expectEqual(@as(usize, 1), st.unstaged_modified.len);
    try std.testing.expectError(error.PathspecUnmatched, restoreStaged(arena, io, &ws, &.{"keep.txt"}));

    // Plain restore brings the committed bytes back…
    const summary = try restoreWorktree(arena, io, &ws, cache_tmp.dir, &.{"keep.txt"});
    try std.testing.expectEqual(@as(u32, 1), summary.restored);
    const bytes = try tmp.dir.readFileAlloc(io, "keep.txt", arena, .limited(1024));
    try std.testing.expectEqualStrings("committed content", bytes);
    st = try status(arena, io, &ws);
    try std.testing.expectEqual(@as(usize, 0), st.unstaged_modified.len);

    // …recreates a deleted file…
    try tmp.dir.deleteFile(io, "keep.txt");
    const back = try restoreWorktree(arena, io, &ws, cache_tmp.dir, &.{"."});
    try std.testing.expectEqual(@as(u32, 1), back.restored);
    try std.testing.expectEqualStrings(
        "committed content",
        try tmp.dir.readFileAlloc(io, "keep.txt", arena, .limited(1024)),
    );

    // …and never deletes a file cid was never told about.
    try tmp.dir.writeFile(io, .{ .sub_path = "scratch.tmp", .data = "mine" });
    const skipped = try restoreWorktree(arena, io, &ws, cache_tmp.dir, &.{"."});
    try std.testing.expectEqual(@as(u32, 1), skipped.skipped_untracked);
    try std.testing.expectEqualStrings(
        "mine",
        try tmp.dir.readFileAlloc(io, "scratch.tmp", arena, .limited(1024)),
    );

    // A staged version wins over the committed one.
    try tmp.dir.writeFile(io, .{ .sub_path = "keep.txt", .data = "staged version" });
    _ = try add(arena, io, &ws, cache_tmp.dir, &.{"keep.txt"});
    try tmp.dir.writeFile(io, .{ .sub_path = "keep.txt", .data = "edited after staging" });
    _ = try restoreWorktree(arena, io, &ws, cache_tmp.dir, &.{"keep.txt"});
    try std.testing.expectEqualStrings(
        "staged version",
        try tmp.dir.readFileAlloc(io, "keep.txt", arena, .limited(1024)),
    );
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

    const commits = try local.listUnpushed(arena, io, ws.cid_dir, null);
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

test "staging like git: only staged changes are committed; commit -a takes tracked changes only" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var cache_tmp = std.testing.tmpDir(.{});
    defer cache_tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "a1" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "b1" });
    try tmp.dir.writeFile(io, .{ .sub_path = "c.txt", .data = "c1" });
    try init(arena, io, tmp.dir, "cid@h:org/datasets/stage", "g@h:stage.git");
    var ws = try open(arena, io, tmp.dir);
    _ = try add(arena, io, &ws, cache_tmp.dir, &.{"."});
    _ = try commit(arena, io, &ws, "base", "user:test");

    // Edit a and b, stage only a: the commit holds a alone, b stays edited.
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "a2" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "b2" });
    _ = try add(arena, io, &ws, cache_tmp.dir, &.{"a.txt"});
    const only_a = try commit(arena, io, &ws, "only a", "user:test");
    try std.testing.expectEqual(@as(u32, 1), only_a.changes);
    var commits = try local.listUnpushed(arena, io, ws.cid_dir, null);
    try std.testing.expectEqualStrings("a.txt", commits[0].changes[0].path);
    var st = try status(arena, io, &ws);
    try std.testing.expectEqual(@as(usize, 1), st.unstaged_modified.len);
    try std.testing.expectEqualStrings("b.txt", st.unstaged_modified[0]);

    // commit -a: b's edit and c's deletion go in; the new file does not.
    try tmp.dir.deleteFile(io, "c.txt");
    try tmp.dir.writeFile(io, .{ .sub_path = "new.txt", .data = "untracked" });
    const staged = try addTracked(arena, io, &ws, cache_tmp.dir);
    try std.testing.expectEqual(@as(u32, 1), staged.staged_adds);
    try std.testing.expectEqual(@as(u32, 1), staged.staged_deletes);
    const all = try commit(arena, io, &ws, "all tracked", "user:test");
    try std.testing.expectEqual(@as(u32, 2), all.changes);
    commits = try local.listUnpushed(arena, io, ws.cid_dir, null);
    for (commits[0].changes) |ch| try std.testing.expect(!std.mem.eql(u8, ch.path, "new.txt"));
    st = try status(arena, io, &ws);
    try std.testing.expectEqual(@as(usize, 0), st.unstaged_modified.len);
    try std.testing.expectEqual(@as(usize, 0), st.unstaged_deleted.len);
    try std.testing.expectEqual(@as(usize, 1), st.unstaged_new.len);
    try std.testing.expectEqualStrings("new.txt", st.unstaged_new[0]);
}

test "a subset describes itself, and makes its folder read-only" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const both: Subset = .{ .split = &.{"train"}, .class = &.{ "person", "vehicle" } };
    try std.testing.expectEqualStrings("split train \xc2\xb7 class person, vehicle", try both.describe(arena));
    try std.testing.expect(!(Subset{}).active());

    const full: Config = .{ .address = "cid@h:o/d", .git_url = "g" };
    try std.testing.expect(readOnlyReason(arena, full) == null);
    const sub: Config = .{ .address = "cid@h:o/d", .git_url = "g", .split = &.{"val"} };
    try std.testing.expect(std.mem.indexOf(u8, readOnlyReason(arena, sub).?, "split val") != null);
    try std.testing.expect(std.mem.indexOf(u8, readOnlyReason(arena, sub).?, "Run 'cid pull'") != null);
    const ann: Config = .{ .address = "cid@h:o/d", .git_url = "g", .kind = "annotated", .format = "files" };
    try std.testing.expect(std.mem.startsWith(u8, readOnlyReason(arena, ann).?, "This is an export of an annotated dataset."));
}
