//! Folder scan: every regular file under the working folder, with size and
//! mtime, sorted by path. `.cid/` is never scanned. `.cidignore` (same
//! spirit as .gitignore, deliberately smaller) excludes files: one pattern
//! per line — an exact path, a `dir/` prefix, or a `*.ext` suffix;
//! comments with #. Generated export sidecars ride on this.

const std = @import("std");
const index_mod = @import("index.zig");

pub const FileInfo = struct {
    path: []const u8,
    size: u64,
    mtime_ns: i64,
};

pub const Error = error{BadPath} || std.mem.Allocator.Error ||
    std.Io.Dir.SelectiveWalker.Error || std.Io.Dir.StatFileError;

pub fn scanWorkdir(arena: std.mem.Allocator, io: std.Io, work_dir: std.Io.Dir) Error![]FileInfo {
    var out: std.ArrayList(FileInfo) = .empty;
    const ignore = loadIgnore(arena, io, work_dir);

    var walker = try work_dir.walkSelectively(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                // Never descend into cid's own state, nor ignored trees.
                if (entry.depth() == 1 and std.mem.eql(u8, entry.basename, ".cid")) continue;
                if (ignoredDir(ignore, entry.path)) continue;
                try walker.enter(io, entry);
            },
            .file => {
                if (ignored(ignore, entry.path)) continue;
                if (!index_mod.validPath(entry.path)) return error.BadPath;
                const stat = try entry.dir.statFile(io, entry.basename, .{});
                try out.append(arena, .{
                    .path = try arena.dupe(u8, entry.path),
                    .size = stat.size,
                    .mtime_ns = @intCast(stat.mtime.nanoseconds),
                });
            },
            else => {}, // symlinks and specials are skipped, for now loudly nothing
        }
    }

    std.mem.sort(FileInfo, out.items, {}, lessThan);
    return out.items;
}

fn lessThan(_: void, a: FileInfo, b: FileInfo) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

/// The element of `items` (sorted bytewise by `.path`, as scans, states
/// and the index all are) at `path`, by binary search: lookups inside a
/// loop over every file stay O(n log n), never O(n²).
pub fn findByPath(comptime T: type, items: []const T, path: []const u8) ?T {
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (std.mem.order(u8, items[mid].path, path)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return items[mid],
        }
    }
    return null;
}

test "findByPath: bytewise order, hits and misses" {
    const Item = struct { path: []const u8 };
    const items = [_]Item{ .{ .path = "B" }, .{ .path = "a" }, .{ .path = "a/b" }, .{ .path = "c" } };
    try std.testing.expectEqualStrings("a/b", findByPath(Item, &items, "a/b").?.path);
    try std.testing.expectEqualStrings("B", findByPath(Item, &items, "B").?.path);
    try std.testing.expect(findByPath(Item, &items, "b") == null);
    try std.testing.expect(findByPath(Item, items[0..0], "a") == null);
}

fn loadIgnore(arena: std.mem.Allocator, io: std.Io, work_dir: std.Io.Dir) []const []const u8 {
    const text = work_dir.readFileAlloc(io, ".cidignore", arena, .limited(1024 * 1024)) catch
        return &.{};
    var patterns: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        if (line.len == 0 or line[0] == '#') continue;
        patterns.append(arena, line) catch return patterns.items;
    }
    return patterns.items;
}

fn ignored(patterns: []const []const u8, path: []const u8) bool {
    for (patterns) |p| {
        if (std.mem.eql(u8, p, path)) return true;
        if (std.mem.endsWith(u8, p, "/") and std.mem.startsWith(u8, path, p)) return true;
        if (std.mem.startsWith(u8, p, "*.")) {
            const base_start = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| i + 1 else 0;
            if (std.mem.endsWith(u8, path[base_start..], p[1..])) return true;
        }
    }
    return false;
}

fn ignoredDir(patterns: []const []const u8, dir_path: []const u8) bool {
    for (patterns) |p| {
        if (std.mem.endsWith(u8, p, "/") and std.mem.eql(u8, p[0 .. p.len - 1], dir_path)) return true;
    }
    return false;
}

test ".cidignore: exact, directory and extension patterns" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "labels/img");
    try tmp.dir.writeFile(io, .{ .sub_path = ".cidignore", .data = "# generated\nannotations.jsonl\nlabels/\n*.tmp\n.cidignore\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "annotations.jsonl", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "labels/img/a.txt", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "scratch.tmp", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "keep.jpg", .data = "x" });

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const files = try scanWorkdir(arena_state.allocator(), io, tmp.dir);
    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqualStrings("keep.jpg", files[0].path);
}

test "scan finds nested files, skips .cid, sorts by path" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "audio/march");
    try tmp.dir.createDirPath(io, ".cid/commits");
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "b" });
    try tmp.dir.writeFile(io, .{ .sub_path = "audio/march/a.wav", .data = "aaaa" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".cid/index", .data = "cid-index 1\n" });

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const files = try scanWorkdir(arena_state.allocator(), io, tmp.dir);
    try std.testing.expectEqual(@as(usize, 2), files.len);
    try std.testing.expectEqualStrings("audio/march/a.wav", files[0].path);
    try std.testing.expectEqual(@as(u64, 4), files[0].size);
    try std.testing.expectEqualStrings("b.txt", files[1].path);
}
