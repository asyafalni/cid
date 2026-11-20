//! The `voc` export: Pascal VOC. One `Annotations/<path>.xml` per image
//! (same relative path, extension .xml) with its size and boxes, and
//! `ImageSets/Main/<split>.txt` listing the images of each split by that
//! path without its extension (`unsplit` for items with none). Boxes only,
//! as VOC holds; coordinates in VOC's own convention, whole pixels from 1:
//! a box at x 10, width 30 is xmin 11, xmax 40.
//!
//! Every image with recorded dimensions gets its file, boxes or not, so a
//! split list never names a missing one; an item without dimensions and
//! without boxes (a file that is not an image) is left out, and one
//! without dimensions but with boxes fails the export, path named, as yolo
//! and coco do.

const std = @import("std");
const repeat = @import("../util/repeat.zig").repeat;
const bundle = @import("bundle.zig");

pub const Failure = struct { path: []const u8, why: []const u8 };

/// Whether the item got its annotation file (and so belongs in a split
/// list), or a failure naming it.
pub const Outcome = union(enum) { written, left_out, failed: Failure };

pub fn writeItem(out: bundle.Bundle, arena: std.mem.Allocator, item: bundle.Item, anns: []const bundle.Ann) !Outcome {
    var objects: std.ArrayList(u8) = .empty;
    var boxes: usize = 0;
    for (anns) |ann| {
        const kind = ann.kind orelse continue;
        if (!std.mem.eql(u8, kind, "box")) continue;
        boxes += 1;
        const class = ann.class orelse return .{ .failed = .{ .path = item.path, .why = "a box has no class" } };
        const text = ann.geometry orelse return .{ .failed = .{ .path = item.path, .why = "a box has no geometry" } };
        const geo = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch
            return .{ .failed = .{ .path = item.path, .why = "box geometry is not JSON" } };
        if (geo != .object) return .{ .failed = .{ .path = item.path, .why = "box geometry is not an object" } };
        const x = num(geo.object.get("x")) orelse return .{ .failed = .{ .path = item.path, .why = "box geometry misses x/y/w/h" } };
        const y = num(geo.object.get("y")) orelse return .{ .failed = .{ .path = item.path, .why = "box geometry misses x/y/w/h" } };
        const w = num(geo.object.get("w")) orelse return .{ .failed = .{ .path = item.path, .why = "box geometry misses x/y/w/h" } };
        const h = num(geo.object.get("h")) orelse return .{ .failed = .{ .path = item.path, .why = "box geometry misses x/y/w/h" } };
        try objects.print(arena,
            \\  <object>
            \\    <name>{f}</name>
            \\    <pose>Unspecified</pose>
            \\    <truncated>0</truncated>
            \\    <difficult>0</difficult>
            \\    <bndbox>
            \\      <xmin>{d}</xmin>
            \\      <ymin>{d}</ymin>
            \\      <xmax>{d}</xmax>
            \\      <ymax>{d}</ymax>
            \\    </bndbox>
            \\  </object>
            \\
        , .{ Xml{ .text = class }, pixel(x) + 1, pixel(y) + 1, pixel(x + w), pixel(y + h) });
    }
    const width = item.width orelse return if (boxes > 0)
        .{ .failed = .{ .path = item.path, .why = "no recorded width/height; register items with dimensions" } }
    else
        .left_out;
    const height = item.height orelse return .{ .failed = .{ .path = item.path, .why = "no recorded width/height; register items with dimensions" } };
    const base = item.path[if (std.mem.lastIndexOfScalar(u8, item.path, '/')) |s| s + 1 else 0..];
    const folder = if (std.mem.lastIndexOfScalar(u8, item.path, '/')) |s| item.path[0..s] else "";
    try out.put(try annotationPath(arena, item.path), try std.fmt.allocPrint(arena,
        \\<annotation>
        \\  <folder>{f}</folder>
        \\  <filename>{f}</filename>
        \\  <path>{f}</path>
        \\  <source><database>cid</database></source>
        \\  <size>
        \\    <width>{d}</width>
        \\    <height>{d}</height>
        \\    <depth>3</depth>
        \\  </size>
        \\  <segmented>0</segmented>
        \\{s}</annotation>
        \\
    , .{ Xml{ .text = folder }, Xml{ .text = base }, Xml{ .text = item.path }, width, height, objects.items }));
    return .written;
}

/// img/a.jpg → Annotations/img/a.xml
pub fn annotationPath(arena: std.mem.Allocator, image_path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "Annotations/{s}.xml", .{stem(image_path)});
}

/// An image's id in a split list: its path without the extension.
pub fn stem(path: []const u8) []const u8 {
    const slash = if (std.mem.lastIndexOfScalar(u8, path, '/')) |s| s + 1 else 0;
    const dot = std.mem.lastIndexOfScalar(u8, path[slash..], '.') orelse return path;
    return if (dot == 0) path else path[0 .. slash + dot];
}

/// `ImageSets/Main/<split>.txt`: a split name as a file name.
pub fn listFor(arena: std.mem.Allocator, split: []const u8) ![]const u8 {
    const name = try arena.dupe(u8, if (split.len == 0) "unsplit" else split);
    for (name) |*c| if (!(std.ascii.isAlphanumeric(c.*) or c.* == '_' or c.* == '-' or c.* == '.')) {
        c.* = '_';
    };
    return std.fmt.allocPrint(arena, "ImageSets/Main/{s}.txt", .{name});
}

fn pixel(v: f64) i64 {
    return @intFromFloat(@round(v));
}

fn num(value: ?std.json.Value) ?f64 {
    const v = value orelse return null;
    return switch (v) {
        .integer => |n| @floatFromInt(n),
        .float => |f| f,
        else => null,
    };
}

/// Text escaped for an XML element.
const Xml = struct {
    text: []const u8,
    pub fn format(self: Xml, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.text) |c| switch (c) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            else => try w.writeByte(c),
        };
    }
};

test "one XML per image with its boxes in VOC pixels; names escaped; failures named" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buf: std.Io.Writer.Allocating = .init(arena);
    const out: bundle.Bundle = .{ .w = &buf.writer, .raw = true };

    const item: bundle.Item = .{ .path = "street/cam1/a.jpg", .hash = repeat("ab", 32), .size = 1, .split = "train", .item_id = "i1", .width = 640, .height = 480 };
    try std.testing.expect((try writeItem(out, arena, item, &.{
        .{ .id = "1", .kind = "box", .class = "car & van", .geometry = "{\"x\": 10, \"y\": 20, \"w\": 30, \"h\": 40}", .attrs = null },
        .{ .id = "2", .kind = "polygon", .class = "road", .geometry = "{\"points\": [[0,0],[1,0],[1,1]]}", .attrs = null },
    })) == .written);
    const xml = buf.written();
    try std.testing.expect(std.mem.indexOf(u8, xml, "<filename>a.jpg</filename>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<folder>street/cam1</folder>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<width>640</width>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<name>car &amp; van</name>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<xmin>11</xmin>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<ymin>21</ymin>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<xmax>40</xmax>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<ymax>60</ymax>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "road") == null); // not a box
    try std.testing.expectEqualStrings("Annotations/street/cam1/a.xml", try annotationPath(arena, item.path));
    try std.testing.expectEqualStrings("street/cam1/a", stem(item.path));
    try std.testing.expectEqualStrings("README", stem("README"));
    try std.testing.expectEqualStrings("ImageSets/Main/unsplit.txt", try listFor(arena, ""));

    // Not an image (no dimensions, no boxes): left out. Boxes on an item
    // without dimensions: named.
    const text: bundle.Item = .{ .path = "notes.txt", .hash = repeat("cd", 32), .size = 1, .split = null, .item_id = "i2", .width = null, .height = null };
    try std.testing.expect((try writeItem(out, arena, text, &.{})) == .left_out);
    const failed = try writeItem(out, arena, text, &.{.{ .id = "3", .kind = "box", .class = "x", .geometry = "{\"x\":1,\"y\":1,\"w\":1,\"h\":1}", .attrs = null }});
    try std.testing.expectEqualStrings("notes.txt", failed.failed.path);
}
