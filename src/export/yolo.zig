//! The `yolo` export: one label file per image (same relative path under
//! labels/, extension .txt), classes.txt with the index map, per-split
//! image lists and a dataset.yaml. Boxes only; geometry is pixel
//! {x, y, w, h} (top-left), normalized against the item's recorded
//! width and height.
//!
//! Deterministic: classes sorted by name, items in path order, boxes in
//! annotation order. An image whose box cannot be exported (missing
//! dimensions, missing class, non-object geometry) fails the export with
//! the path named — a training set with silently dropped boxes is worse
//! than no export.

const std = @import("std");
const jsonl = @import("jsonl.zig");

pub const File = jsonl.File;
pub const LinkedItem = jsonl.LinkedItem;

pub const Error = error{OutOfMemory};

pub const Result = union(enum) {
    files: []const File,
    /// The first offending item and why.
    failed: struct { path: []const u8, why: []const u8 },
};

pub fn renderLinked(arena: std.mem.Allocator, linked: []const LinkedItem) Error!Result {
    // Classes: sorted unique names across box annotations.
    var class_set: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (linked) |entry| {
        for (entry.annotations) |ann| {
            if (!isBox(ann)) continue;
            const class = ann.class orelse
                return .{ .failed = .{ .path = entry.item.path, .why = "a box has no class" } };
            try class_set.put(arena, class, {});
        }
    }
    const classes = try arena.dupe([]const u8, class_set.keys());
    std.mem.sort([]const u8, classes, {}, strLess);

    var files: std.ArrayList(File) = .empty;

    var classes_txt: std.ArrayList(u8) = .empty;
    for (classes) |name| try classes_txt.print(arena, "{s}\n", .{name});
    try files.append(arena, .{ .path = "classes.txt", .contents = classes_txt.items });

    var split_lists: [3]std.ArrayList(u8) = .{ .empty, .empty, .empty };
    const split_names = [_][]const u8{ "train", "val", "test" };

    for (linked) |entry| {
        var label: std.ArrayList(u8) = .empty;
        for (entry.annotations) |ann| {
            if (!isBox(ann)) continue;
            const w_img = entry.item.width orelse
                return .{ .failed = .{ .path = entry.item.path, .why = "no recorded width/height; register items with dimensions" } };
            const h_img = entry.item.height orelse
                return .{ .failed = .{ .path = entry.item.path, .why = "no recorded width/height; register items with dimensions" } };
            const geo = ann.geometry orelse
                return .{ .failed = .{ .path = entry.item.path, .why = "a box has no geometry" } };
            if (geo != .object)
                return .{ .failed = .{ .path = entry.item.path, .why = "box geometry is not an object" } };
            const x = num(geo.object.get("x")) orelse
                return .{ .failed = .{ .path = entry.item.path, .why = "box geometry misses x/y/w/h" } };
            const y = num(geo.object.get("y")) orelse
                return .{ .failed = .{ .path = entry.item.path, .why = "box geometry misses x/y/w/h" } };
            const w = num(geo.object.get("w")) orelse
                return .{ .failed = .{ .path = entry.item.path, .why = "box geometry misses x/y/w/h" } };
            const h = num(geo.object.get("h")) orelse
                return .{ .failed = .{ .path = entry.item.path, .why = "box geometry misses x/y/w/h" } };

            const class_index = indexOf(classes, ann.class.?);
            const fw: f64 = @floatFromInt(w_img);
            const fh: f64 = @floatFromInt(h_img);
            try label.print(arena, "{d} {d:.6} {d:.6} {d:.6} {d:.6}\n", .{
                class_index, (x + w / 2) / fw, (y + h / 2) / fh, w / fw, h / fh,
            });
        }
        if (label.items.len > 0) {
            try files.append(arena, .{
                .path = try labelPath(arena, entry.item.path),
                .contents = label.items,
            });
        }
        if (entry.item.split) |split| {
            for (split_names, 0..) |name, i| {
                if (std.mem.eql(u8, split, name))
                    try split_lists[i].print(arena, "{s}\n", .{entry.item.path});
            }
        }
    }

    var yaml: std.ArrayList(u8) = .empty;
    try yaml.appendSlice(arena, "path: .\n");
    for (split_names, 0..) |name, i| {
        if (split_lists[i].items.len > 0) {
            const list_path = try std.fmt.allocPrint(arena, "{s}.txt", .{name});
            try files.append(arena, .{ .path = list_path, .contents = split_lists[i].items });
            try yaml.print(arena, "{s}: {s}.txt\n", .{ name, name });
        }
    }
    try yaml.print(arena, "nc: {d}\nnames:\n", .{classes.len});
    for (classes, 0..) |name, i| try yaml.print(arena, "  {d}: {s}\n", .{ i, name });
    try files.append(arena, .{ .path = "dataset.yaml", .contents = yaml.items });

    return .{ .files = files.items };
}

fn isBox(ann: anytype) bool {
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

fn indexOf(classes: []const []const u8, name: []const u8) usize {
    for (classes, 0..) |c, i| {
        if (std.mem.eql(u8, c, name)) return i;
    }
    unreachable; // collected above
}

/// img/a.jpg → labels/img/a.txt
fn labelPath(arena: std.mem.Allocator, image_path: []const u8) ![]const u8 {
    const stem = if (std.mem.lastIndexOfScalar(u8, image_path, '.')) |dot| image_path[0..dot] else image_path;
    return std.fmt.allocPrint(arena, "labels/{s}.txt", .{stem});
}

fn strLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

test "normalized boxes, sorted classes, split lists, named failures" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const geo1 = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"x\":32,\"y\":48,\"w\":64,\"h\":96}", .{});
    const geo2 = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"x\":0,\"y\":0,\"w\":320,\"h\":240}", .{});
    const ok = [_]LinkedItem{
        .{
            .item = .{ .path = "img/a.jpg", .hash = "ab" ** 32, .size = 1, .split = "train", .width = 640, .height = 480 },
            .annotations = &.{
                .{ .id = "1", .item_id = "i1", .kind = "box", .class = "vehicle", .geometry = geo1, .author = "x", .policy_ver = "p" },
                .{ .id = "2", .item_id = "i1", .kind = "box", .class = "person", .geometry = geo2, .author = "x", .policy_ver = "p" },
            },
        },
        .{ .item = .{ .path = "img/b.jpg", .hash = "cd" ** 32, .size = 1, .split = "val", .width = 100, .height = 100 }, .annotations = &.{} },
    };
    const result = try renderLinked(arena, &ok);
    try std.testing.expect(result == .files);
    var classes: []const u8 = "";
    var label_a: []const u8 = "";
    var yaml: []const u8 = "";
    var train: []const u8 = "";
    for (result.files) |f| {
        if (std.mem.eql(u8, f.path, "classes.txt")) classes = f.contents;
        if (std.mem.eql(u8, f.path, "labels/img/a.txt")) label_a = f.contents;
        if (std.mem.eql(u8, f.path, "dataset.yaml")) yaml = f.contents;
        if (std.mem.eql(u8, f.path, "train.txt")) train = f.contents;
    }
    try std.testing.expectEqualStrings("person\nvehicle\n", classes); // sorted
    // vehicle=1: cx=(32+32)/640=0.1, cy=(48+48)/480=0.2, w=0.1, h=0.2
    try std.testing.expectEqualStrings(
        "1 0.100000 0.200000 0.100000 0.200000\n0 0.250000 0.250000 0.500000 0.500000\n",
        label_a,
    );
    try std.testing.expect(std.mem.indexOf(u8, yaml, "nc: 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "0: person") != null);
    try std.testing.expectEqualStrings("img/a.jpg\n", train);

    // Missing dimensions name the offender instead of guessing.
    const bad = [_]LinkedItem{.{
        .item = .{ .path = "img/nodims.jpg", .hash = "ef" ** 32, .size = 1 },
        .annotations = &.{.{ .id = "1", .item_id = "i2", .kind = "box", .class = "person", .geometry = geo1, .author = "x", .policy_ver = "p" }},
    }};
    const failed = try renderLinked(arena, &bad);
    try std.testing.expect(failed == .failed);
    try std.testing.expectEqualStrings("img/nodims.jpg", failed.failed.path);
}
