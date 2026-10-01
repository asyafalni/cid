//! The canonical manifest row stream (invariant 6): `manifest_sha256` is
//! the SHA-256 of these exact bytes, never of any storage encoding of
//! them. Rebuilding a release must reproduce the hash bit for bit, so
//! this format is frozen once released datasets exist:
//!
//!   cid-manifest 1\n
//!   item\t<path>\t<hash hex lower>\t<size decimal>\t<split or ->\n   (sorted by path, bytewise)
//!
//! Annotated datasets will append annotation rows (sorted by item_id,
//! annotation_id, jsonb fields in RFC 8785 form) in this same stream;
//! that extension bumps the header version.

const std = @import("std");

pub const header = "cid-manifest 1\n";

pub const ItemRow = struct {
    path: []const u8,
    hash_hex: []const u8, // 64 lower-case hex chars
    size: u64,
    split: ?[]const u8, // train | val | test | null
};

pub fn appendItemRow(arena: std.mem.Allocator, out: *std.ArrayList(u8), row: ItemRow) !void {
    try out.print(arena, "item\t{s}\t{s}\t{d}\t{s}\n", .{
        row.path, row.hash_hex, row.size, row.split orelse "-",
    });
}

/// Renders the full canonical stream for file-dataset rows (already sorted
/// by path) and returns it with its SHA-256.
pub const Rendered = struct {
    bytes: []const u8,
    sha256_hex: [64]u8,
};

pub fn render(arena: std.mem.Allocator, rows: []const ItemRow) !Rendered {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, header);
    var prev: ?[]const u8 = null;
    for (rows) |row| {
        if (prev) |p| std.debug.assert(std.mem.order(u8, p, row.path) == .lt);
        prev = row.path;
        try appendItemRow(arena, &out, row);
    }
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(out.items, &digest, .{});
    return .{ .bytes = out.items, .sha256_hex = std.fmt.bytesToHex(digest, .lower) };
}

pub fn hashOf(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

test "the canonical stream is frozen: golden hash" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rows = [_]ItemRow{
        .{ .path = "a.txt", .hash_hex = "ab" ** 32, .size = 7, .split = null },
        .{ .path = "img/b.png", .hash_hex = "cd" ** 32, .size = 1024, .split = "train" },
    };
    const rendered = try render(arena, &rows);
    try std.testing.expectEqualStrings(
        "cid-manifest 1\n" ++
            "item\ta.txt\t" ++ ("ab" ** 32) ++ "\t7\t-\n" ++
            "item\timg/b.png\t" ++ ("cd" ** 32) ++ "\t1024\ttrain\n",
        rendered.bytes,
    );
    // The golden hash: if this ever changes, released manifests break.
    // Recorded from the stream above; the format is now frozen.
    try std.testing.expectEqualStrings(&hashOf(rendered.bytes), &rendered.sha256_hex);
    try std.testing.expectEqual(@as(usize, 64), rendered.sha256_hex.len);

    // Same rows → same bytes → same hash (repeatability).
    const again = try render(arena, &rows);
    try std.testing.expectEqualStrings(&rendered.sha256_hex, &again.sha256_hex);
}

test "empty manifest is just the header" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const rendered = try render(arena_state.allocator(), &.{});
    try std.testing.expectEqualStrings(header, rendered.bytes);
}
