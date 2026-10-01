//! Folder scan: every regular file under the working folder, with size and
//! mtime, sorted by path. `.cid/` is never scanned; `.cidignore` rules come
//! later and will hook in here.

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

    var walker = try work_dir.walkSelectively(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                // Never descend into cid's own state.
                if (entry.depth() == 1 and std.mem.eql(u8, entry.basename, ".cid")) continue;
                try walker.enter(io, entry);
            },
            .file => {
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
