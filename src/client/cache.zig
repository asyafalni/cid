//! The user-wide item cache: ~/.cache/cid/items/<aa>/<hex>, shared by every
//! clone and release. `cid add` hashes files and copies them here, which is
//! what makes `cid commit` instant and offline (CLAUDE.md, storage layout).

const std = @import("std");

pub const Error = error{CacheWriteFailed} || std.mem.Allocator.Error ||
    std.Io.File.OpenError || std.Io.File.Reader.Error;

pub const Stored = struct {
    hash_hex: [64]u8,
    size: u64,
};

/// Hashes `rel_path` (inside `work_dir`) while copying it into the cache.
/// Already-cached content is left alone: items are immutable by hash.
pub fn storeFile(
    io: std.Io,
    work_dir: std.Io.Dir,
    rel_path: []const u8,
    cache_dir: std.Io.Dir,
) Error!Stored {
    var file = try work_dir.openFile(io, rel_path, .{});
    defer file.close(io);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var size: u64 = 0;

    var tmp_name_buf: [64]u8 = undefined;
    var tmp_random: [8]u8 = undefined;
    io.random(&tmp_random);
    const tmp_name = std.fmt.bufPrint(&tmp_name_buf, "tmp-{x}", .{&tmp_random}) catch unreachable;
    var tmp_file = cache_dir.createFile(io, tmp_name, .{ .truncate = true }) catch
        return error.CacheWriteFailed;
    var tmp_ok = false;
    defer if (!tmp_ok) cache_dir.deleteFile(io, tmp_name) catch {};

    {
        defer tmp_file.close(io);
        var rbuf: [64 * 1024]u8 = undefined;
        var wbuf: [64 * 1024]u8 = undefined;
        var fr = file.reader(io, &rbuf);
        var fw = tmp_file.writer(io, &wbuf);
        while (true) {
            const n = fr.interface.readSliceShort(&rbuf) catch return error.CacheWriteFailed;
            if (n == 0) break;
            hasher.update(rbuf[0..n]);
            fw.interface.writeAll(rbuf[0..n]) catch return error.CacheWriteFailed;
            size += n;
        }
        fw.interface.flush() catch return error.CacheWriteFailed;
    }

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);

    var item_path_buf: [80]u8 = undefined;
    const item_dir = std.fmt.bufPrint(&item_path_buf, "items/{s}", .{hex[0..2]}) catch unreachable;
    cache_dir.createDirPath(io, item_dir) catch return error.CacheWriteFailed;
    var final_path_buf: [80]u8 = undefined;
    const final_path = std.fmt.bufPrint(&final_path_buf, "items/{s}/{s}", .{ hex[0..2], hex }) catch unreachable;

    if (cache_dir.access(io, final_path, .{})) |_| {
        // Already cached; drop the temp copy.
    } else |_| {
        std.Io.Dir.rename(cache_dir, tmp_name, cache_dir, final_path, io) catch
            return error.CacheWriteFailed;
        tmp_ok = true;
    }

    return .{ .hash_hex = hex, .size = size };
}

/// Hash only, no copy — for re-checking files already in the cache.
pub fn hashFile(io: std.Io, work_dir: std.Io.Dir, rel_path: []const u8) Error!Stored {
    var file = try work_dir.openFile(io, rel_path, .{});
    defer file.close(io);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var size: u64 = 0;
    var rbuf: [64 * 1024]u8 = undefined;
    var fr = file.reader(io, &rbuf);
    while (true) {
        const n = fr.interface.readSliceShort(&rbuf) catch return error.CacheWriteFailed;
        if (n == 0) break;
        hasher.update(rbuf[0..n]);
        size += n;
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return .{ .hash_hex = std.fmt.bytesToHex(digest, .lower), .size = size };
}

test "store computes the right hash, deduplicates, and survives re-adds" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cache_tmp = std.testing.tmpDir(.{});
    defer cache_tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "hello.txt", .data = "hello cid\n" });

    const first = try storeFile(io, tmp.dir, "hello.txt", cache_tmp.dir);
    try std.testing.expectEqual(@as(u64, 10), first.size);

    // Verify against a known-good SHA-256 of "hello cid\n".
    var expected_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("hello cid\n", &expected_digest, .{});
    const expected_hex = std.fmt.bytesToHex(expected_digest, .lower);
    try std.testing.expectEqualStrings(&expected_hex, &first.hash_hex);

    // The cached copy exists, byte for byte.
    var path_buf: [80]u8 = undefined;
    const cached = std.fmt.bufPrint(&path_buf, "items/{s}/{s}", .{ first.hash_hex[0..2], first.hash_hex }) catch unreachable;
    const bytes = try cache_tmp.dir.readFileAlloc(io, cached, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("hello cid\n", bytes);

    // Storing again is a no-op that still reports the same hash.
    const again = try storeFile(io, tmp.dir, "hello.txt", cache_tmp.dir);
    try std.testing.expectEqualStrings(&first.hash_hex, &again.hash_hex);

    // hashFile agrees without writing anything.
    const only = try hashFile(io, tmp.dir, "hello.txt");
    try std.testing.expectEqualStrings(&first.hash_hex, &only.hash_hex);
}
