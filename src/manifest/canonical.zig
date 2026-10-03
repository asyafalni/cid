//! The canonical manifest row stream (invariant 6): `manifest_hash` is
//! the BLAKE3 (util/hash.zig) of these exact bytes, never of any storage
//! encoding of them. Rebuilding a release must reproduce the hash bit for
//! bit, so this format is frozen at the first public release. One format
//! for both kinds of dataset:
//!
//!   cid-manifest 1\n
//!   item\t<path>\t<item_id>\t<hash hex>\t<size>\t<split or ->\n   sorted by path, bytewise
//!   ann\t<item_id>\t<annotation_id>\t<kind>\t<class>\t<geometry>\t<attrs>\t<author>\t<policy_ver>\n
//!                                          sorted by (item_id, annotation_id)
//!
//! An item row names the item's identity as well as its content, so a
//! release records which item each path is: a rename or a re-encode is
//! visible in it, and every `ann` row points at an item row. A file
//! dataset has no `ann` rows. JSON fields are in RFC 8785 form (jcs.zig);
//! `-` stands for null.

const std = @import("std");
const hash = @import("../util/hash.zig");

pub const header = "cid-manifest 1\n";

pub const ItemRow = struct {
    path: []const u8,
    item_id: []const u8, // UUID, lower-case, hyphenated
    hash_hex: []const u8, // 64 lower-case hex chars
    size: u64,
    split: ?[]const u8, // train | val | test | null
};

pub fn appendItemRow(arena: std.mem.Allocator, out: *std.ArrayList(u8), row: ItemRow) !void {
    try out.print(arena, "item\t{s}\t{s}\t{s}\t{d}\t{s}\n", .{
        row.path, row.item_id, row.hash_hex, row.size, row.split orelse "-",
    });
}

pub const AnnRow = struct {
    item_id: []const u8,
    annotation_id: []const u8,
    kind: ?[]const u8,
    class: ?[]const u8,
    /// Already in RFC 8785 form (jcs.zig), or null.
    geometry_jcs: ?[]const u8,
    attrs_jcs: ?[]const u8,
    author: []const u8,
    policy_ver: []const u8,
};

pub const RenderError = error{ OutOfMemory, BadAnnotationText };

/// One `ann` row. A tab or newline in a text column is an error, never a
/// silent mangling (JCS already escapes them inside JSON strings).
pub fn appendAnnRow(arena: std.mem.Allocator, out: *std.ArrayList(u8), ann: AnnRow) RenderError!void {
    inline for (.{ ann.kind, ann.class, @as(?[]const u8, ann.author), @as(?[]const u8, ann.policy_ver) }) |field| {
        if (field) |text| {
            if (std.mem.indexOfAny(u8, text, "\t\n") != null) return error.BadAnnotationText;
        }
    }
    try out.print(arena, "ann\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\n", .{
        ann.item_id,
        ann.annotation_id,
        ann.kind orelse "-",
        ann.class orelse "-",
        ann.geometry_jcs orelse "-",
        ann.attrs_jcs orelse "-",
        ann.author,
        ann.policy_ver,
    });
}

/// The whole stream at once, with its hash: what the server writes a batch
/// at a time (core/version.zig), for tests. Rows must already be sorted.
pub const Rendered = struct {
    bytes: []const u8,
    hash_hex: hash.Hex,
};

pub fn render(arena: std.mem.Allocator, items: []const ItemRow, anns: []const AnnRow) RenderError!Rendered {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, header);
    var prev_path: ?[]const u8 = null;
    for (items) |row| {
        if (prev_path) |p| std.debug.assert(std.mem.order(u8, p, row.path) == .lt);
        prev_path = row.path;
        try appendItemRow(arena, &out, row);
    }
    var prev: ?AnnRow = null;
    for (anns) |ann| {
        if (prev) |p| {
            const item_order = std.mem.order(u8, p.item_id, ann.item_id);
            std.debug.assert(item_order == .lt or
                (item_order == .eq and std.mem.order(u8, p.annotation_id, ann.annotation_id) == .lt));
        }
        prev = ann;
        try appendAnnRow(arena, &out, ann);
    }
    return .{ .bytes = out.items, .hash_hex = hash.hex(out.items) };
}

const id_a = "0190a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b";
const id_b = "0190a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5c";

test "the canonical stream is frozen: golden hash, files only" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rows = [_]ItemRow{
        .{ .path = "a.txt", .item_id = id_a, .hash_hex = "ab" ** 32, .size = 7, .split = null },
        .{ .path = "img/b.png", .item_id = id_b, .hash_hex = "cd" ** 32, .size = 1024, .split = "train" },
    };
    const rendered = try render(arena, &rows, &.{});
    try std.testing.expectEqualStrings(
        "cid-manifest 1\n" ++
            "item\ta.txt\t" ++ id_a ++ "\t" ++ ("ab" ** 32) ++ "\t7\t-\n" ++
            "item\timg/b.png\t" ++ id_b ++ "\t" ++ ("cd" ** 32) ++ "\t1024\ttrain\n",
        rendered.bytes,
    );
    // The golden hash: once released manifests exist, a change here
    // breaks them.
    try std.testing.expectEqualStrings("7714fc44e638acd55c27fceef136337fc75a25cb45d27552d0209d8bf178959f", &rendered.hash_hex);

    // Same rows → same bytes → same hash (repeatability).
    const again = try render(arena, &rows, &.{});
    try std.testing.expectEqualStrings(&rendered.hash_hex, &again.hash_hex);
}

test "the canonical stream is frozen: golden hash, with annotations" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const items = [_]ItemRow{
        .{ .path = "img/a.jpg", .item_id = id_a, .hash_hex = "ab" ** 32, .size = 7, .split = "val" },
    };
    const anns = [_]AnnRow{
        .{ .item_id = id_a, .annotation_id = id_b, .kind = "box", .class = "person", .geometry_jcs = "{\"h\":4,\"w\":3,\"x\":1,\"y\":2}", .attrs_jcs = null, .author = "agent:x", .policy_ver = "p1" },
    };
    const rendered = try render(arena, &items, &anns);
    try std.testing.expectEqualStrings(
        "cid-manifest 1\n" ++
            "item\timg/a.jpg\t" ++ id_a ++ "\t" ++ ("ab" ** 32) ++ "\t7\tval\n" ++
            "ann\t" ++ id_a ++ "\t" ++ id_b ++ "\tbox\tperson\t{\"h\":4,\"w\":3,\"x\":1,\"y\":2}\t-\tagent:x\tp1\n",
        rendered.bytes,
    );
    try std.testing.expectEqualStrings("82cbad57a0e544f82a34e01d78e5b64c7bf022d874ba01efcb764fd1073ecccb", &rendered.hash_hex);
}

test "empty manifest is just the header" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const rendered = try render(arena_state.allocator(), &.{}, &.{});
    try std.testing.expectEqualStrings(header, rendered.bytes);
}

test "a tab in a text column is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const anns = [_]AnnRow{
        .{ .item_id = id_a, .annotation_id = id_b, .kind = "box", .class = "per\tson", .geometry_jcs = null, .attrs_jcs = null, .author = "a", .policy_ver = "p" },
    };
    try std.testing.expectError(error.BadAnnotationText, render(arena_state.allocator(), &.{}, &anns));
}
