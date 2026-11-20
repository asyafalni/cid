//! The `coco` export: one COCO instances file per split,
//! `annotations/instances_<split>.json` (`unsplit` for items with none),
//! with the images, the annotations and the categories (every class of an
//! exported shape, sorted by name, numbered from 1). Boxes, polygons and
//! masks are exported; other kinds (points, transcripts, spans…) have no
//! COCO instance form and are left out. A mask stays COCO RLE as stored
//! (docs/data-model.md: chosen so this needs no conversion); its `bbox`
//! and `area` are read from its runs.
//!
//! Written in pieces as the version streams by (bundle.zig): for each
//! split, the header, then its images in path order, then its annotations
//! by image and id, then the footer; a file's pieces arrive together. An
//! image without recorded dimensions, or a shape without a class or with
//! geometry that is not its kind's, fails the export with the path named,
//! as yolo does.

const std = @import("std");
const repeat = @import("../util/repeat.zig").repeat;
const bundle = @import("bundle.zig");

pub const Failure = struct { path: []const u8, why: []const u8 };

/// The kinds COCO instances hold.
pub const exported_kinds = "('box', 'polygon', 'mask')";

/// `annotations/instances_<split>.json`: a split name as a file name.
pub fn fileFor(arena: std.mem.Allocator, split: []const u8) ![]const u8 {
    const name = try arena.dupe(u8, if (split.len == 0) "unsplit" else split);
    for (name) |*c| if (!(std.ascii.isAlphanumeric(c.*) or c.* == '_' or c.* == '-' or c.* == '.')) {
        c.* = '_';
    };
    return std.fmt.allocPrint(arena, "annotations/instances_{s}.json", .{name});
}

pub fn header(out: bundle.Bundle, arena: std.mem.Allocator, file: []const u8, categories: []const []const u8) !void {
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(arena, "{\"info\":{\"description\":\"exported by cid\"},\"licenses\":[],\"categories\":[");
    for (categories, 0..) |name, i| {
        if (i > 0) try text.append(arena, ',');
        try text.print(arena, "{{\"id\":{d},\"name\":{f},\"supercategory\":\"\"}}", .{ i + 1, std.json.fmt(name, .{}) });
    }
    try text.appendSlice(arena, "],\"images\":[");
    try out.put(file, text.items);
}

/// One image; the first of a file has no comma before it.
pub fn image(out: bundle.Bundle, arena: std.mem.Allocator, file: []const u8, first: bool, id: u64, item: bundle.Item) !?Failure {
    const w = item.width orelse return .{ .path = item.path, .why = "no recorded width/height; register items with dimensions" };
    const h = item.height orelse return .{ .path = item.path, .why = "no recorded width/height; register items with dimensions" };
    try out.put(file, try std.fmt.allocPrint(arena, "{s}{{\"id\":{d},\"file_name\":{f},\"width\":{d},\"height\":{d}}}", .{
        if (first) "" else ",", id, std.json.fmt(item.path, .{}), w, h,
    }));
    return null;
}

pub fn between(out: bundle.Bundle, file: []const u8) !void {
    try out.put(file, "],\"annotations\":[");
}

pub fn footer(out: bundle.Bundle, file: []const u8) !void {
    try out.put(file, "]}\n");
}

/// One annotation of an exported kind; a failure names its image.
pub fn annotation(
    out: bundle.Bundle,
    arena: std.mem.Allocator,
    file: []const u8,
    first: bool,
    id: u64,
    image_id: u64,
    path: []const u8,
    categories: []const []const u8,
    ann: bundle.Ann,
) !?Failure {
    const kind = ann.kind orelse return .{ .path = path, .why = "an annotation has no kind" };
    const class = ann.class orelse return .{ .path = path, .why = "a shape has no class" };
    const category = (indexOf(categories, class) orelse return .{ .path = path, .why = "a shape's class is not in the export" }) + 1;
    const text = ann.geometry orelse return .{ .path = path, .why = "a shape has no geometry" };
    const geo = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch
        return .{ .path = path, .why = "a shape's geometry is not JSON" };
    if (geo != .object) return .{ .path = path, .why = "a shape's geometry is not an object" };

    var seg: []const u8 = undefined;
    var bbox: [4]f64 = undefined;
    var area: f64 = undefined;
    var crowd: u8 = 0;
    if (std.mem.eql(u8, kind, "box")) {
        const x = num(geo.object.get("x")) orelse return .{ .path = path, .why = "box geometry misses x/y/w/h" };
        const y = num(geo.object.get("y")) orelse return .{ .path = path, .why = "box geometry misses x/y/w/h" };
        const w = num(geo.object.get("w")) orelse return .{ .path = path, .why = "box geometry misses x/y/w/h" };
        const h = num(geo.object.get("h")) orelse return .{ .path = path, .why = "box geometry misses x/y/w/h" };
        bbox = .{ x, y, w, h };
        area = w * h;
        // The box as its own polygon: every COCO reader can then make a
        // mask of it (pycocotools' annToMask fails on an empty one).
        seg = try std.fmt.allocPrint(arena, "[[{d},{d},{d},{d},{d},{d},{d},{d}]]", .{ x, y, x + w, y, x + w, y + h, x, y + h });
    } else if (std.mem.eql(u8, kind, "polygon")) {
        const pts = geo.object.get("points") orelse return .{ .path = path, .why = "polygon geometry misses points" };
        if (pts != .array or pts.array.items.len < 3) return .{ .path = path, .why = "a polygon needs three points or more" };
        var flat: std.ArrayList(u8) = .empty;
        try flat.appendSlice(arena, "[[");
        var min_x = std.math.inf(f64);
        var min_y = std.math.inf(f64);
        var max_x = -std.math.inf(f64);
        var max_y = -std.math.inf(f64);
        var twice: f64 = 0; // the shoelace sum
        const items = pts.array.items;
        for (items, 0..) |p, i| {
            const xy = point(p) orelse return .{ .path = path, .why = "a polygon point is not [x, y]" };
            const next = point(items[(i + 1) % items.len]) orelse return .{ .path = path, .why = "a polygon point is not [x, y]" };
            twice += xy[0] * next[1] - next[0] * xy[1];
            min_x = @min(min_x, xy[0]);
            min_y = @min(min_y, xy[1]);
            max_x = @max(max_x, xy[0]);
            max_y = @max(max_y, xy[1]);
            try flat.print(arena, "{s}{d},{d}", .{ if (i == 0) "" else ",", xy[0], xy[1] });
        }
        try flat.appendSlice(arena, "]]");
        seg = flat.items;
        bbox = .{ min_x, min_y, max_x - min_x, max_y - min_y };
        area = @abs(twice) / 2;
    } else if (std.mem.eql(u8, kind, "mask")) {
        const size = geo.object.get("size") orelse return .{ .path = path, .why = "mask geometry misses size" };
        if (size != .array or size.array.items.len != 2) return .{ .path = path, .why = "a mask's size is not [h, w]" };
        const h = num(size.array.items[0]) orelse return .{ .path = path, .why = "a mask's size is not [h, w]" };
        const counts = geo.object.get("counts") orelse return .{ .path = path, .why = "mask geometry misses counts" };
        const runs = switch (counts) {
            .string => |s| decodeCounts(arena, s) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return .{ .path = path, .why = "a mask's counts are not COCO RLE" },
            },
            .array => |a| blk: {
                const list = try arena.alloc(u64, a.items.len);
                for (list, a.items) |*r, v| r.* = if (v == .integer and v.integer >= 0) @intCast(v.integer) else return .{ .path = path, .why = "a mask's counts are not run lengths" };
                break :blk list;
            },
            else => return .{ .path = path, .why = "a mask's counts are not COCO RLE" },
        };
        const box = maskBox(runs, @intFromFloat(h));
        bbox = box.bbox;
        area = @floatFromInt(box.area);
        // The stored RLE, as stored: size and counts are already COCO's.
        seg = text;
        // pycocotools reads RLE segmentation with either flag; COCO marks
        // RLE crowd, but these are single objects, and say so.
        crowd = 0;
    } else return null; // not a COCO instance: left out
    try out.put(file, try std.fmt.allocPrint(arena, "{s}{{\"id\":{d},\"image_id\":{d},\"category_id\":{d},\"segmentation\":{s},\"area\":{d},\"bbox\":[{d},{d},{d},{d}],\"iscrowd\":{d}}}", .{
        if (first) "" else ",", id, image_id, category, seg, area, bbox[0], bbox[1], bbox[2], bbox[3], crowd,
    }));
    return null;
}

/// COCO's compressed RLE string (pycocotools' `rleFrString`) as runs.
pub fn decodeCounts(arena: std.mem.Allocator, s: []const u8) error{ OutOfMemory, BadCounts }![]const u64 {
    var runs: std.ArrayList(i64) = .empty;
    var p: usize = 0;
    while (p < s.len) {
        var x: i64 = 0;
        var k: u6 = 0;
        var more = true;
        while (more) {
            if (p >= s.len or k > 12) return error.BadCounts;
            const c: i64 = @as(i64, s[p]) - 48;
            if (c < 0 or c > 63) return error.BadCounts;
            x |= (c & 0x1f) << (5 * k);
            more = (c & 0x20) != 0;
            p += 1;
            k += 1;
            if (!more and (c & 0x10) != 0) x |= @as(i64, -1) << (5 * k);
        }
        if (runs.items.len > 2) x += runs.items[runs.items.len - 2];
        if (x < 0) return error.BadCounts;
        try runs.append(arena, x);
    }
    const out = try arena.alloc(u64, runs.items.len);
    for (out, runs.items) |*o, r| o.* = @intCast(r);
    return out;
}

/// A mask's box and pixel count from its column-major runs (background
/// first), as pycocotools' `toBbox` and `area` read them.
pub fn maskBox(runs: []const u64, h: u64) struct { bbox: [4]f64, area: u64 } {
    var area: u64 = 0;
    var pos: u64 = 0;
    var min_x: u64 = std.math.maxInt(u64);
    var min_y: u64 = std.math.maxInt(u64);
    var max_x: u64 = 0;
    var max_y: u64 = 0;
    for (runs, 0..) |len, i| {
        defer pos += len;
        if (i % 2 == 0 or len == 0 or h == 0) continue;
        area += len;
        const first = pos;
        const last = pos + len - 1;
        const x0 = first / h;
        const x1 = last / h;
        min_x = @min(min_x, x0);
        max_x = @max(max_x, x1);
        if (x0 == x1) {
            min_y = @min(min_y, first % h);
            max_y = @max(max_y, last % h);
        } else {
            // Down to the column's foot, and from the next one's head.
            min_y = 0;
            max_y = h - 1;
        }
    }
    if (area == 0) return .{ .bbox = .{ 0, 0, 0, 0 }, .area = 0 };
    return .{
        .bbox = .{ @floatFromInt(min_x), @floatFromInt(min_y), @floatFromInt(max_x - min_x + 1), @floatFromInt(max_y - min_y + 1) },
        .area = area,
    };
}

fn num(value: ?std.json.Value) ?f64 {
    const v = value orelse return null;
    return switch (v) {
        .integer => |n| @floatFromInt(n),
        .float => |f| f,
        else => null,
    };
}

fn point(v: std.json.Value) ?[2]f64 {
    if (v != .array or v.array.items.len != 2) return null;
    return .{ num(v.array.items[0]) orelse return null, num(v.array.items[1]) orelse return null };
}

fn indexOf(classes: []const []const u8, name: []const u8) ?usize {
    for (classes, 0..) |c, i| if (std.mem.eql(u8, c, name)) return i;
    return null;
}

test "COCO RLE strings decode to pycocotools' runs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Encoded by a port of pycocotools' rleToString.
    try std.testing.expectEqualSlices(u64, &.{ 5, 2, 2, 2, 5 }, try decodeCounts(arena, "52203"));
    try std.testing.expectEqualSlices(u64, &.{ 0, 6, 10 }, try decodeCounts(arena, "06:"));
    try std.testing.expectEqualSlices(u64, &.{ 3, 40, 100, 2 }, try decodeCounts(arena, "3X1T3jN"));
    try std.testing.expectError(error.BadCounts, decodeCounts(arena, "\x01"));
    // A 4×4 mask, rows 1–2 of columns 1–2: a 2×2 box at (1, 1).
    const box = maskBox(&.{ 5, 2, 2, 2, 5 }, 4);
    try std.testing.expectEqual(@as(u64, 4), box.area);
    try std.testing.expectEqual([4]f64{ 1, 1, 2, 2 }, box.bbox);
    // A run across columns reaches the top and the bottom.
    try std.testing.expectEqual([4]f64{ 0, 0, 2, 4 }, maskBox(&.{ 2, 4 }, 4).bbox);

    // Random masks, encoded, measured and boxed by pycocotools 2.0 itself.
    const Vector = struct { h: u64, counts: []const u8, area: u64, bbox: [4]f64 };
    for ([_]Vector{
        .{ .h = 37, .counts = "Qc0<i00000000000000000000000000000000000000000000^2Eo9", .area = 277, .bbox = .{ 16, 17, 26, 12 } },
        .{ .h = 5, .counts = "1190h0", .area = 2, .bbox = .{ 0, 1, 3, 1 } },
        .{ .h = 64, .counts = "d=1Vm00iTO000000000000000000000Um0", .area = 13, .bbox = .{ 6, 27, 27, 26 } },
    }) |v| {
        const got = maskBox(try decodeCounts(arena, v.counts), v.h);
        try std.testing.expectEqual(v.area, got.area);
        try std.testing.expectEqual(v.bbox, got.bbox);
    }
}

test "a split file: header, images, annotations, footer; failures named" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buf: std.Io.Writer.Allocating = .init(arena);
    const out: bundle.Bundle = .{ .w = &buf.writer, .raw = true };
    const cats = [_][]const u8{ "car", "person" };
    const file = try fileFor(arena, "train");
    try std.testing.expectEqualStrings("annotations/instances_train.json", file);
    try std.testing.expectEqualStrings("annotations/instances_unsplit.json", try fileFor(arena, ""));

    try header(out, arena, file, &cats);
    const item: bundle.Item = .{ .path = "img/a.jpg", .hash = repeat("ab", 32), .size = 1, .split = "train", .item_id = "i1", .width = 640, .height = 480 };
    try std.testing.expect((try image(out, arena, file, true, 1, item)) == null);
    try between(out, file);
    try std.testing.expect((try annotation(out, arena, file, true, 1, 1, item.path, &cats, .{ .id = "a", .kind = "box", .class = "person", .geometry = "{\"x\": 10, \"y\": 20, \"w\": 30, \"h\": 40}", .attrs = null })) == null);
    try std.testing.expect((try annotation(out, arena, file, false, 2, 1, item.path, &cats, .{ .id = "b", .kind = "polygon", .class = "car", .geometry = "{\"points\": [[0, 0], [4, 0], [4, 3]]}", .attrs = null })) == null);
    try std.testing.expect((try annotation(out, arena, file, false, 3, 1, item.path, &cats, .{ .id = "c", .kind = "mask", .class = "person", .geometry = "{\"size\": [4, 4], \"counts\": \"52203\"}", .attrs = null })) == null);
    // Not an instance kind: nothing written, nothing failed.
    try std.testing.expect((try annotation(out, arena, file, false, 4, 1, item.path, &cats, .{ .id = "d", .kind = "points", .class = "person", .geometry = "{\"points\": [[1, 1]]}", .attrs = null })) == null);
    try footer(out, file);

    const Doc = struct {
        categories: []const struct { id: u64, name: []const u8 },
        images: []const struct { id: u64, file_name: []const u8, width: u32, height: u32 },
        annotations: []const struct { id: u64, image_id: u64, category_id: u64, bbox: [4]f64, area: f64, segmentation: std.json.Value },
    };
    const doc = try std.json.parseFromSliceLeaky(Doc, arena, buf.written(), .{ .ignore_unknown_fields = true });
    try std.testing.expectEqualStrings("car", doc.categories[0].name);
    try std.testing.expectEqual(@as(u64, 2), doc.categories[1].id);
    try std.testing.expectEqualStrings("img/a.jpg", doc.images[0].file_name);
    try std.testing.expectEqual(@as(usize, 3), doc.annotations.len);
    try std.testing.expectEqual([4]f64{ 10, 20, 30, 40 }, doc.annotations[0].bbox);
    try std.testing.expectEqual(@as(f64, 1200), doc.annotations[0].area);
    try std.testing.expectEqual(@as(usize, 8), doc.annotations[0].segmentation.array.items[0].array.items.len);
    try std.testing.expectEqual(@as(u64, 1), doc.annotations[1].category_id);
    try std.testing.expectEqual([4]f64{ 0, 0, 4, 3 }, doc.annotations[1].bbox);
    try std.testing.expectEqual(@as(f64, 6), doc.annotations[1].area);
    try std.testing.expectEqual([4]f64{ 1, 1, 2, 2 }, doc.annotations[2].bbox);
    try std.testing.expectEqualStrings("52203", doc.annotations[2].segmentation.object.get("counts").?.string);

    // Missing dimensions, a classless shape: named, not guessed.
    const nodims: bundle.Item = .{ .path = "img/b.jpg", .hash = repeat("cd", 32), .size = 1, .split = null, .item_id = "i2", .width = null, .height = null };
    try std.testing.expectEqualStrings("img/b.jpg", (try image(out, arena, file, false, 2, nodims)).?.path);
    const classless = (try annotation(out, arena, file, false, 5, 1, item.path, &cats, .{ .id = "e", .kind = "box", .class = null, .geometry = "{\"x\":1,\"y\":1,\"w\":1,\"h\":1}", .attrs = null })).?;
    try std.testing.expectEqualStrings("a shape has no class", classless.why);
}
