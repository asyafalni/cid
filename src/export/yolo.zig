//! The `yolo` export: one label file per image (same relative path under
//! labels/, extension .txt), classes.txt with the index map, per-split
//! image lists and a dataset.yaml. Boxes only; geometry is pixel
//! {x, y, w, h} (top-left), normalized against the item's recorded
//! width and height.
//!
//! Written an item at a time as the version streams by (bundle.zig):
//! classes sorted by name (known before the first label), items in path
//! order, boxes in annotation order. An image whose box cannot be
//! exported (missing dimensions, non-object geometry) fails the export
//! with the path named — a training set with silently dropped boxes is
//! worse than no export.

const std = @import("std");
const bundle = @import("bundle.zig");

pub const split_names = [_][]const u8{ "train", "val", "test" };

pub const Failure = struct { path: []const u8, why: []const u8 };

pub const Writer = struct {
    /// Every box class in the export, sorted: a label's class index.
    classes: []const []const u8,

    pub fn begin(self: Writer, out: bundle.Bundle) !void {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(std.heap.page_allocator);
        for (self.classes) |name| try text.print(std.heap.page_allocator, "{s}\n", .{name});
        try out.put("classes.txt", text.items);
    }

    /// The item's label file, when it has boxes; a failure names it.
    pub fn writeItem(self: Writer, out: bundle.Bundle, arena: std.mem.Allocator, item: bundle.Item, anns: []const bundle.Ann) !?Failure {
        var label: std.ArrayList(u8) = .empty;
        for (anns) |ann| {
            if (!isBox(ann)) continue;
            const w_img = item.width orelse return .{ .path = item.path, .why = "no recorded width/height; register items with dimensions" };
            const h_img = item.height orelse return .{ .path = item.path, .why = "no recorded width/height; register items with dimensions" };
            const text = ann.geometry orelse return .{ .path = item.path, .why = "a box has no geometry" };
            const geo = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch
                return .{ .path = item.path, .why = "box geometry is not JSON" };
            if (geo != .object) return .{ .path = item.path, .why = "box geometry is not an object" };
            const x = num(geo.object.get("x")) orelse return .{ .path = item.path, .why = "box geometry misses x/y/w/h" };
            const y = num(geo.object.get("y")) orelse return .{ .path = item.path, .why = "box geometry misses x/y/w/h" };
            const w = num(geo.object.get("w")) orelse return .{ .path = item.path, .why = "box geometry misses x/y/w/h" };
            const h = num(geo.object.get("h")) orelse return .{ .path = item.path, .why = "box geometry misses x/y/w/h" };
            const class_index = indexOf(self.classes, ann.class orelse return .{ .path = item.path, .why = "a box has no class" }) orelse
                return .{ .path = item.path, .why = "a box's class is not in the export" };
            const fw: f64 = @floatFromInt(w_img);
            const fh: f64 = @floatFromInt(h_img);
            try label.print(arena, "{d} {d:.6} {d:.6} {d:.6} {d:.6}\n", .{
                class_index, (x + w / 2) / fw, (y + h / 2) / fh, w / fw, h / fh,
            });
        }
        if (label.items.len > 0) try out.put(try labelPath(arena, item.path), label.items);
        return null;
    }

    /// dataset.yaml, after the split lists (`present`: which were written).
    pub fn end(self: Writer, out: bundle.Bundle, arena: std.mem.Allocator, present: [split_names.len]bool) !void {
        var yaml: std.ArrayList(u8) = .empty;
        try yaml.appendSlice(arena, "path: .\n");
        for (split_names, present) |name, here| {
            if (here) try yaml.print(arena, "{s}: {s}.txt\n", .{ name, name });
        }
        try yaml.print(arena, "nc: {d}\nnames:\n", .{self.classes.len});
        for (self.classes, 0..) |name, i| try yaml.print(arena, "  {d}: {s}\n", .{ i, name });
        try out.put("dataset.yaml", yaml.items);
    }
};

fn isBox(ann: bundle.Ann) bool {
    const kind = ann.kind orelse return false;
    return std.mem.eql(u8, kind, "box");
}

fn num(value: ?std.json.Value) ?f64 {
    const v = value orelse return null;
    return switch (v) {
        .integer => |n| @floatFromInt(n),
        .float => |f| f,
        else => null,
    };
}

fn indexOf(classes: []const []const u8, name: []const u8) ?usize {
    for (classes, 0..) |c, i| {
        if (std.mem.eql(u8, c, name)) return i;
    }
    return null;
}

/// img/a.jpg → labels/img/a.txt
fn labelPath(arena: std.mem.Allocator, image_path: []const u8) ![]const u8 {
    const stem = if (std.mem.lastIndexOfScalar(u8, image_path, '.')) |dot| image_path[0..dot] else image_path;
    return std.fmt.allocPrint(arena, "labels/{s}.txt", .{stem});
}

test "normalized boxes, sorted classes, the yaml, named failures" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buf: std.Io.Writer.Allocating = .init(arena);
    const out: bundle.Bundle = .{ .w = &buf.writer };
    const writer: Writer = .{ .classes = &.{ "person", "vehicle" } };

    try writer.begin(out);
    const a: bundle.Item = .{ .path = "img/a.jpg", .hash = "ab" ** 32, .size = 1, .split = "train", .item_id = "i1", .width = 640, .height = 480 };
    try std.testing.expect((try writer.writeItem(out, arena, a, &.{
        .{ .id = "1", .kind = "box", .class = "vehicle", .geometry = "{\"x\": 32, \"y\": 48, \"w\": 64, \"h\": 96}", .attrs = null },
        .{ .id = "2", .kind = "box", .class = "person", .geometry = "{\"x\": 0, \"y\": 0, \"w\": 320, \"h\": 240}", .attrs = null },
    })) == null);
    try writer.end(out, arena, .{ true, false, false });

    const Line = struct { path: []const u8, text: []const u8 };
    var files: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, buf.written(), "\n"), '\n');
    while (lines.next()) |l| {
        const parsed = try std.json.parseFromSliceLeaky(Line, arena, l, .{});
        try files.put(arena, parsed.path, parsed.text);
    }
    try std.testing.expectEqualStrings("person\nvehicle\n", files.get("classes.txt").?);
    // vehicle=1: cx=(32+32)/640=0.1, cy=(48+48)/480=0.2, w=0.1, h=0.2
    try std.testing.expectEqualStrings(
        "1 0.100000 0.200000 0.100000 0.200000\n0 0.250000 0.250000 0.500000 0.500000\n",
        files.get("labels/img/a.txt").?,
    );
    const yaml = files.get("dataset.yaml").?;
    try std.testing.expect(std.mem.indexOf(u8, yaml, "train: train.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "nc: 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "0: person") != null);

    // Missing dimensions name the offender instead of guessing.
    const nodims: bundle.Item = .{ .path = "img/nodims.jpg", .hash = "ef" ** 32, .size = 1, .split = null, .item_id = "i2", .width = null, .height = null };
    const failed = (try writer.writeItem(out, arena, nodims, &.{.{ .id = "1", .kind = "box", .class = "person", .geometry = "{\"x\":1,\"y\":1,\"w\":1,\"h\":1}", .attrs = null }})).?;
    try std.testing.expectEqualStrings("img/nodims.jpg", failed.path);
}
