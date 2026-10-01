//! The `jsonl` export: universal, one line per item with its annotations
//! (CLAUDE.md, formats). Works for any media. Deterministic: items in
//! path order, annotations in (item_id, annotation_id) order, geometry
//! and attrs embedded as their canonical JCS form.

const std = @import("std");
const remote_mod = @import("../client/remote.zig");
const jcs = @import("../manifest/jcs.zig");

pub const File = struct {
    path: []const u8,
    contents: []const u8,
};

pub const Error = error{ OutOfMemory, BadAnnotation };

/// items and their annotations, already linked by the caller.
pub const LinkedItem = struct {
    item: remote_mod.Remote.StateItem,
    annotations: []const remote_mod.Remote.Annotation,
};

pub fn renderLinked(arena: std.mem.Allocator, linked: []const LinkedItem) Error![]const File {
    var out: std.ArrayList(u8) = .empty;
    for (linked) |entry| {
        const Ann = struct {
            id: []const u8,
            kind: ?[]const u8,
            class: ?[]const u8,
            geometry: ?std.json.Value,
            attrs: ?std.json.Value,
        };
        const anns = try arena.alloc(Ann, entry.annotations.len);
        for (anns, 0..) |*a, i| {
            a.* = .{
                .id = entry.annotations[i].id,
                .kind = entry.annotations[i].kind,
                .class = entry.annotations[i].class,
                .geometry = entry.annotations[i].geometry,
                .attrs = entry.annotations[i].attrs,
            };
        }
        const line = .{
            .path = entry.item.path,
            .hash = entry.item.hash,
            .size = entry.item.size,
            .split = entry.item.split,
            .width = entry.item.width,
            .height = entry.item.height,
            .annotations = anns,
        };
        try out.print(arena, "{f}\n", .{std.json.fmt(line, .{ .emit_null_optional_fields = false })});
    }
    const files = try arena.alloc(File, 1);
    files[0] = .{ .path = "annotations.jsonl", .contents = out.items };
    return files;
}

test "one line per item, annotations inline, empties included" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const geo = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"x\":1,\"y\":2}", .{});
    const linked = [_]LinkedItem{
        .{
            .item = .{ .path = "a.jpg", .hash = "ab" ** 32, .size = 10, .split = "train", .width = 640, .height = 480 },
            .annotations = &.{.{ .id = "ann-1", .item_id = "i1", .kind = "box", .class = "person", .geometry = geo, .author = "x", .policy_ver = "p1" }},
        },
        .{
            .item = .{ .path = "b.jpg", .hash = "cd" ** 32, .size = 5 },
            .annotations = &.{},
        },
    };
    const files = try renderLinked(arena, &linked);
    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqualStrings("annotations.jsonl", files[0].path);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, files[0].contents, "\n"), '\n');
    const l1 = lines.next().?;
    const l2 = lines.next().?;
    try std.testing.expect(lines.next() == null);
    try std.testing.expect(std.mem.indexOf(u8, l1, "\"path\":\"a.jpg\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, l1, "\"class\":\"person\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, l1, "\"x\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, l2, "\"annotations\":[]") != null);
}
