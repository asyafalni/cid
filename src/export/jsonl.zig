//! The `jsonl` export: universal, one line per item with its annotations
//! (CLAUDE.md, formats), in one file, `annotations.jsonl`. Works for any
//! media. Written an item at a time as the version streams by
//! (bundle.zig): items in path order, annotations in id order.

const std = @import("std");
const bundle = @import("bundle.zig");

pub const file = "annotations.jsonl";

pub fn writeItem(out: bundle.Bundle, arena: std.mem.Allocator, item: bundle.Item, anns: []const bundle.Ann) !void {
    const Ann = struct {
        id: []const u8,
        kind: ?[]const u8,
        class: ?[]const u8,
        geometry: ?std.json.Value,
        attrs: ?std.json.Value,
    };
    const list = try arena.alloc(Ann, anns.len);
    for (list, anns) |*a, src| a.* = .{
        .id = src.id,
        .kind = src.kind,
        .class = src.class,
        .geometry = try valueOf(arena, src.geometry),
        .attrs = try valueOf(arena, src.attrs),
    };
    const line = try std.fmt.allocPrint(arena, "{f}\n", .{std.json.fmt(.{
        .path = item.path,
        .hash = item.hash,
        .size = item.size,
        .split = item.split,
        .width = item.width,
        .height = item.height,
        .annotations = list,
    }, .{ .emit_null_optional_fields = false })});
    try out.put(file, line);
}

fn valueOf(arena: std.mem.Allocator, text: ?[]const u8) !?std.json.Value {
    const t = text orelse return null;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, t, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

test "one line per item, annotations inline, empties included" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buf: std.Io.Writer.Allocating = .init(arena);
    const out: bundle.Bundle = .{ .w = &buf.writer };

    try writeItem(out, arena, .{ .path = "a.jpg", .hash = "ab" ** 32, .size = 10, .split = "train", .item_id = "i1", .width = 640, .height = 480 }, &.{
        .{ .id = "ann-1", .kind = "box", .class = "person", .geometry = "{\"x\": 1, \"y\": 2}", .attrs = null },
    });
    try writeItem(out, arena, .{ .path = "b.jpg", .hash = "cd" ** 32, .size = 5, .split = null, .item_id = null, .width = null, .height = null }, &.{});

    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, buf.written(), "\n"), '\n');
    const Line = struct { path: []const u8, text: []const u8 };
    const l1 = try std.json.parseFromSliceLeaky(Line, arena, lines.next().?, .{});
    const l2 = try std.json.parseFromSliceLeaky(Line, arena, lines.next().?, .{});
    try std.testing.expect(lines.next() == null);
    try std.testing.expectEqualStrings(file, l1.path);
    try std.testing.expect(std.mem.indexOf(u8, l1.text, "\"path\":\"a.jpg\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, l1.text, "\"class\":\"person\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, l1.text, "\"x\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, l2.text, "\"annotations\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, l2.text, "\"split\"") == null); // nulls left out
}
