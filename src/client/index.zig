//! The staging area (.cid/index) and the tracked tree (.cid/tracked):
//! both are sorted text files, one entry per line, tab-separated.
//!
//!   cid-index 1                      cid-tracked 1
//!   A\tpath\thash\tsize\tmtime_ns    path\thash\tsize\tmtime_ns
//!   D\tpath\t-\t0\t0
//!
//! `tracked` is the tree as of the last local commit (or the cloned
//! manifest, later); `index` is the changes chosen for the next commit.
//! Paths are repo-relative with '/' separators and may not contain
//! control characters; writers keep lines sorted by path.

const std = @import("std");

pub const hash_hex_len = 64;

pub const Op = enum {
    add, // new path, or changed content: staged upsert
    delete,

    fn letter(self: Op) u8 {
        return switch (self) {
            .add => 'A',
            .delete => 'D',
        };
    }

    fn fromLetter(ch: u8) ?Op {
        return switch (ch) {
            'A' => .add,
            'D' => .delete,
            else => null,
        };
    }
};

pub const Entry = struct {
    op: Op,
    path: []const u8,
    hash_hex: [hash_hex_len]u8, // undefined for delete
    size: u64,
    mtime_ns: i64,
};

pub const TrackedEntry = struct {
    path: []const u8,
    hash_hex: [hash_hex_len]u8,
    size: u64,
    mtime_ns: i64,
};

pub const Error = error{ CorruptIndex, BadPath } || std.mem.Allocator.Error;

/// Paths cid will accept: relative, '/'-separated, no control characters,
/// no empty or dot segments.
pub fn validPath(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/') return false;
    for (path) |ch| {
        if (ch < 0x20 or ch == 0x7f) return false;
    }
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) return false;
        if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return false;
    }
    return true;
}

pub const Index = struct {
    /// Sorted by path; owned by `arena`.
    entries: std.ArrayList(Entry),
    arena: std.mem.Allocator,

    pub fn init(arena: std.mem.Allocator) Index {
        return .{ .entries = .empty, .arena = arena };
    }

    pub fn get(self: *const Index, path: []const u8) ?Entry {
        const i = self.find(path) orelse return null;
        return self.entries.items[i];
    }

    /// Insert or replace the entry for `path`, keeping order.
    pub fn put(self: *Index, entry: Entry) Error!void {
        if (!validPath(entry.path)) return error.BadPath;
        const copy: Entry = .{
            .op = entry.op,
            .path = try self.arena.dupe(u8, entry.path),
            .hash_hex = entry.hash_hex,
            .size = entry.size,
            .mtime_ns = entry.mtime_ns,
        };
        if (self.find(entry.path)) |i| {
            self.entries.items[i] = copy;
            return;
        }
        const at = self.insertionPoint(entry.path);
        try self.entries.insert(self.arena, at, copy);
    }

    pub fn remove(self: *Index, path: []const u8) bool {
        const i = self.find(path) orelse return false;
        _ = self.entries.orderedRemove(i);
        return true;
    }

    pub fn len(self: *const Index) usize {
        return self.entries.items.len;
    }

    fn find(self: *const Index, path: []const u8) ?usize {
        const i = self.insertionPoint(path);
        if (i < self.entries.items.len and std.mem.eql(u8, self.entries.items[i].path, path))
            return i;
        return null;
    }

    fn insertionPoint(self: *const Index, path: []const u8) usize {
        var lo: usize = 0;
        var hi: usize = self.entries.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (std.mem.lessThan(u8, self.entries.items[mid].path, path)) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return lo;
    }

    pub fn serialize(self: *const Index, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("cid-index 1\n");
        for (self.entries.items) |e| {
            switch (e.op) {
                .add => try w.print("{c}\t{s}\t{s}\t{d}\t{d}\n", .{ e.op.letter(), e.path, &e.hash_hex, e.size, e.mtime_ns }),
                .delete => try w.print("D\t{s}\t-\t0\t0\n", .{e.path}),
            }
        }
    }

    pub fn parse(arena: std.mem.Allocator, text: []const u8) Error!Index {
        var self = Index.init(arena);
        var lines = std.mem.splitScalar(u8, text, '\n');
        const header = lines.next() orelse return error.CorruptIndex;
        if (!std.mem.eql(u8, header, "cid-index 1")) return error.CorruptIndex;
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var cols = std.mem.splitScalar(u8, line, '\t');
            const op_col = cols.next() orelse return error.CorruptIndex;
            if (op_col.len != 1) return error.CorruptIndex;
            const op = Op.fromLetter(op_col[0]) orelse return error.CorruptIndex;
            const path = cols.next() orelse return error.CorruptIndex;
            const hash_col = cols.next() orelse return error.CorruptIndex;
            const size_col = cols.next() orelse return error.CorruptIndex;
            const mtime_col = cols.next() orelse return error.CorruptIndex;
            var e: Entry = .{
                .op = op,
                .path = path,
                .hash_hex = undefined,
                .size = std.fmt.parseInt(u64, size_col, 10) catch return error.CorruptIndex,
                .mtime_ns = std.fmt.parseInt(i64, mtime_col, 10) catch return error.CorruptIndex,
            };
            if (op == .add) {
                if (hash_col.len != hash_hex_len) return error.CorruptIndex;
                @memcpy(&e.hash_hex, hash_col);
            }
            try self.put(e);
        }
        return self;
    }
};

pub const Tracked = struct {
    entries: std.ArrayList(TrackedEntry),
    arena: std.mem.Allocator,

    pub fn init(arena: std.mem.Allocator) Tracked {
        return .{ .entries = .empty, .arena = arena };
    }

    pub fn get(self: *const Tracked, path: []const u8) ?TrackedEntry {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.path, path)) return e;
        }
        return null;
    }

    pub fn put(self: *Tracked, entry: TrackedEntry) Error!void {
        if (!validPath(entry.path)) return error.BadPath;
        const copy: TrackedEntry = .{
            .path = try self.arena.dupe(u8, entry.path),
            .hash_hex = entry.hash_hex,
            .size = entry.size,
            .mtime_ns = entry.mtime_ns,
        };
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.path, entry.path)) {
                e.* = copy;
                return;
            }
        }
        try self.entries.append(self.arena, copy);
    }

    pub fn remove(self: *Tracked, path: []const u8) bool {
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.path, path)) {
                _ = self.entries.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    pub fn serialize(self: *Tracked, w: *std.Io.Writer) std.Io.Writer.Error!void {
        std.mem.sort(TrackedEntry, self.entries.items, {}, pathLessThan);
        try w.writeAll("cid-tracked 1\n");
        for (self.entries.items) |e| {
            try w.print("{s}\t{s}\t{d}\t{d}\n", .{ e.path, &e.hash_hex, e.size, e.mtime_ns });
        }
    }

    pub fn parse(arena: std.mem.Allocator, text: []const u8) Error!Tracked {
        var self = Tracked.init(arena);
        var lines = std.mem.splitScalar(u8, text, '\n');
        const header = lines.next() orelse return error.CorruptIndex;
        if (!std.mem.eql(u8, header, "cid-tracked 1")) return error.CorruptIndex;
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var cols = std.mem.splitScalar(u8, line, '\t');
            const path = cols.next() orelse return error.CorruptIndex;
            const hash_col = cols.next() orelse return error.CorruptIndex;
            const size_col = cols.next() orelse return error.CorruptIndex;
            const mtime_col = cols.next() orelse return error.CorruptIndex;
            if (hash_col.len != hash_hex_len) return error.CorruptIndex;
            var e: TrackedEntry = .{
                .path = path,
                .hash_hex = undefined,
                .size = std.fmt.parseInt(u64, size_col, 10) catch return error.CorruptIndex,
                .mtime_ns = std.fmt.parseInt(i64, mtime_col, 10) catch return error.CorruptIndex,
            };
            @memcpy(&e.hash_hex, hash_col);
            try self.put(e);
        }
        return self;
    }
};

fn pathLessThan(_: void, a: TrackedEntry, b: TrackedEntry) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

const test_hash: [hash_hex_len]u8 = @splat('a');

test "path validation" {
    try std.testing.expect(validPath("a.txt"));
    try std.testing.expect(validPath("audio/2026-03/x.wav"));
    try std.testing.expect(!validPath("/abs"));
    try std.testing.expect(!validPath("a//b"));
    try std.testing.expect(!validPath("../escape"));
    try std.testing.expect(!validPath("a/./b"));
    try std.testing.expect(!validPath("tab\there"));
    try std.testing.expect(!validPath(""));
}

test "index round trip stays sorted and replaces on re-add" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var idx = Index.init(arena_state.allocator());

    try idx.put(.{ .op = .add, .path = "b.txt", .hash_hex = test_hash, .size = 2, .mtime_ns = 20 });
    try idx.put(.{ .op = .add, .path = "a.txt", .hash_hex = test_hash, .size = 1, .mtime_ns = 10 });
    try idx.put(.{ .op = .delete, .path = "c.txt", .hash_hex = undefined, .size = 0, .mtime_ns = 0 });
    try idx.put(.{ .op = .add, .path = "a.txt", .hash_hex = test_hash, .size = 9, .mtime_ns = 90 });
    try std.testing.expectEqual(@as(usize, 3), idx.len());
    try std.testing.expectEqual(@as(u64, 9), idx.get("a.txt").?.size);

    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try idx.serialize(&w);

    const parsed = try Index.parse(arena_state.allocator(), w.buffered());
    try std.testing.expectEqual(@as(usize, 3), parsed.len());
    try std.testing.expectEqualStrings("a.txt", parsed.entries.items[0].path);
    try std.testing.expectEqualStrings("b.txt", parsed.entries.items[1].path);
    try std.testing.expectEqual(Op.delete, parsed.entries.items[2].op);
}

test "tracked round trip" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var t = Tracked.init(arena_state.allocator());
    try t.put(.{ .path = "x/y.bin", .hash_hex = test_hash, .size = 5, .mtime_ns = 7 });

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try t.serialize(&w);
    var parsed = try Tracked.parse(arena_state.allocator(), w.buffered());
    try std.testing.expectEqual(@as(u64, 5), parsed.get("x/y.bin").?.size);
    try std.testing.expect(parsed.get("missing") == null);
}

test "corrupt input is refused, not guessed at" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectError(error.CorruptIndex, Index.parse(arena, "garbage\n"));
    try std.testing.expectError(error.CorruptIndex, Index.parse(arena, "cid-index 1\nX\tp\t-\t0\t0\n"));
    try std.testing.expectError(error.CorruptIndex, Tracked.parse(arena, "cid-tracked 1\nonlypath\n"));
}
