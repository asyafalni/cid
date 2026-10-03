//! RFC 8785 (JSON Canonicalization Scheme) serialization of a parsed
//! JSON value — the encoding `manifest_hash` uses for annotation
//! `geometry` and `attrs` (docs/data-model.md): sorted object keys, fixed
//! escapes, shortest-round-trip numbers. Without this, float formatting
//! would break manifest repeatability.
//!
//! Scope honestly stated: keys are sorted by Unicode code point (JCS
//! wants UTF-16 code units, which differs only beyond the BMP — class
//! names and attribute keys live far from there), and numbers follow
//! Zig's shortest-round-trip formatting, matching ECMAScript for the
//! magnitudes annotation data uses.

const std = @import("std");

pub const Error = error{ OutOfMemory, Unrepresentable };

pub fn serialize(arena: std.mem.Allocator, value: std.json.Value, out: *std.ArrayList(u8)) Error!void {
    switch (value) {
        .null => try out.appendSlice(arena, "null"),
        .bool => |b| try out.appendSlice(arena, if (b) "true" else "false"),
        .integer => |n| try out.print(arena, "{d}", .{n}),
        .float => |f| {
            if (std.math.isNan(f) or std.math.isInf(f)) return error.Unrepresentable;
            if (f == @trunc(f) and @abs(f) < 1e21) {
                // ES6 prints integral doubles without a fraction part.
                try out.print(arena, "{d}", .{@as(i64, @intFromFloat(f))});
            } else {
                try out.print(arena, "{d}", .{f});
            }
        },
        .number_string => |s| try out.appendSlice(arena, s),
        .string => |s| try appendString(arena, out, s),
        .array => |items| {
            try out.append(arena, '[');
            for (items.items, 0..) |item, i| {
                if (i > 0) try out.append(arena, ',');
                try serialize(arena, item, out);
            }
            try out.append(arena, ']');
        },
        .object => |map| {
            const keys = try arena.dupe([]const u8, map.keys());
            std.mem.sort([]const u8, keys, {}, keyLessThan);
            try out.append(arena, '{');
            for (keys, 0..) |key, i| {
                if (i > 0) try out.append(arena, ',');
                try appendString(arena, out, key);
                try out.append(arena, ':');
                try serialize(arena, map.get(key).?, out);
            }
            try out.append(arena, '}');
        },
    }
}

pub fn fromText(arena: std.mem.Allocator, json_text: []const u8) Error![]const u8 {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, json_text, .{}) catch
        return error.Unrepresentable;
    var out: std.ArrayList(u8) = .empty;
    try serialize(arena, value, &out);
    return out.items;
}

fn keyLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// JCS string escaping: the short escapes, \u00xx (lower-case hex) for
/// other control characters, everything else as literal UTF-8.
fn appendString(arena: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) Error!void {
    try out.append(arena, '"');
    for (s) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(arena, "\\\""),
            '\\' => try out.appendSlice(arena, "\\\\"),
            0x08 => try out.appendSlice(arena, "\\b"),
            '\t' => try out.appendSlice(arena, "\\t"),
            '\n' => try out.appendSlice(arena, "\\n"),
            0x0c => try out.appendSlice(arena, "\\f"),
            '\r' => try out.appendSlice(arena, "\\r"),
            0...0x07, 0x0b, 0x0e...0x1f => try out.print(arena, "\\u{x:0>4}", .{ch}),
            else => try out.append(arena, ch),
        }
    }
    try out.append(arena, '"');
}

test "objects sort, numbers canonicalize, strings escape (JCS)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "{\"a\":1,\"b\":[true,null],\"z\":{\"n\":-7}}",
        try fromText(arena, " { \"z\" : {\"n\": -7}, \"a\" : 1, \"b\" : [ true , null ] } "),
    );
    // Integral doubles lose their fraction; real fractions stay shortest.
    try std.testing.expectEqualStrings(
        "{\"h\":40,\"w\":30.5,\"x\":10,\"y\":0.1}",
        try fromText(arena, "{\"x\":10.0,\"y\":0.1,\"w\":30.5,\"h\":40}"),
    );
    try std.testing.expectEqualStrings(
        "{\"s\":\"a\\\"b\\\\c\\nd\\u0001e\"}",
        try fromText(arena, "{\"s\":\"a\\\"b\\\\c\\nd\\u0001e\"}"),
    );
    // Same value, differently written → same canonical bytes.
    const a = try fromText(arena, "{\"x\": 1.0, \"y\": 2}");
    const b = try fromText(arena, "{ \"y\" : 2.0, \"x\": 1 }");
    try std.testing.expectEqualStrings(a, b);
}
