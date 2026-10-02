//! What the CLI downloads to fill a folder, built on the server from a
//! version in one streamed pass (invariant 13) and kept in storage:
//!
//!   state   the items the folder holds (`cid-state 1`: one JSON line each,
//!           by path, with dimensions) — what clone, pull and checkout fetch
//!   jsonl   the `jsonl` export (jsonl.zig)
//!   yolo    the `yolo` export (yolo.zig)
//!
//! Each may be narrowed to a subset (`--split`, `--class`): items in any of
//! the splits that carry at least one of the classes, with only those
//! classes' annotations — chosen in SQL, so nothing of what is left out
//! ever leaves the database.
//!
//! An export is a bundle of files as JSON lines, `{"path":…,"text":…}`;
//! a file's lines are contiguous and its text is their concatenation, so
//! the client writes one file at a time as the bundle streams in.
//!
//! The version is materialized once in its transaction (version.zig);
//! items and their annotations then arrive through two cursors in path
//! order and are merged here, a batch at a time.

const std = @import("std");
const dbx = @import("../store/db.zig");
const version = @import("../core/version.zig");
const jsonl = @import("jsonl.zig");
const yolo = @import("yolo.zig");

pub const Kind = enum { state, jsonl, yolo };

pub const Subset = struct {
    splits: []const []const u8 = &.{},
    classes: []const []const u8 = &.{},
};

/// An item as the exports see it.
pub const Item = struct {
    path: []const u8,
    hash: []const u8,
    size: u64,
    split: ?[]const u8,
    item_id: ?[]const u8,
    width: ?u32,
    height: ?u32,
};

/// An annotation as the exports see it; JSON fields as stored text.
pub const Ann = struct {
    id: []const u8,
    kind: ?[]const u8,
    class: ?[]const u8,
    geometry: ?[]const u8,
    attrs: ?[]const u8,
};

/// Why an export cannot be made, naming the first item at fault.
pub const Failure = struct { path: []const u8, why: []const u8 };

pub const Outcome = union(enum) {
    /// `media_pending`: some item still waits for its media metadata, so
    /// what was written is provisional.
    written: struct { media_pending: bool },
    failed: Failure,
};

/// Writes the files of an export as bundle lines.
pub const Bundle = struct {
    w: *std.Io.Writer,

    pub fn put(self: Bundle, path: []const u8, text: []const u8) !void {
        try self.w.print("{{\"path\":{f},\"text\":{f}}}\n", .{ std.json.fmt(path, .{}), std.json.fmt(text, .{}) });
    }
};

/// The bundle's first line, which the client checks.
pub fn bundleHeader(w: *std.Io.Writer, kind: Kind, commit_id: []const u8) !void {
    try w.print("{{\"cid\":\"bundle\",\"v\":1,\"kind\":\"{t}\",\"commit\":\"{s}\"}}\n", .{ kind, commit_id });
}

const ItemRow = struct {
    pub const nilo_table = .projection;
    path: []const u8,
    hash: []const u8,
    size_bytes: i64,
    split: ?[]const u8,
    item_id: ?[]const u8,
    width: ?i32,
    height: ?i32,
};

const AnnRow = struct {
    pub const nilo_table = .projection;
    path: []const u8,
    id: []const u8,
    kind: ?[]const u8,
    class: ?[]const u8,
    geometry: ?[]const u8,
    attrs: ?[]const u8,
};

fn itemOf(r: ItemRow) Item {
    return .{
        .path = r.path,
        .hash = r.hash,
        .size = @intCast(r.size_bytes),
        .split = r.split,
        .item_id = r.item_id,
        .width = if (r.width) |w| (if (w > 0) @intCast(w) else null) else null,
        .height = if (r.height) |h| (if (h > 0) @intCast(h) else null) else null,
    };
}

pub fn build(
    gpa: std.mem.Allocator,
    db: *dbx.sql.Db,
    scope: anytype,
    dataset_id: []const u8,
    commit_id: []const u8,
    kind: Kind,
    subset: Subset,
    out: *std.Io.Writer,
) version.Error!Outcome {
    const where = try version.at(db, scope, dataset_id, commit_id);
    var tx = db.begin(scope, .{}) catch return error.Db;
    defer tx.deinit(); // rolled back: the temporary tables go with it
    try version.materialize(&tx, scope, dataset_id, where, "x");

    // The subset, in SQL. Lists arrive as JSON arrays of strings.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const splits = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(subset.splits, .{})});
    const classes = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(subset.classes, .{})});
    inline for (.{
        "CREATE TEMP TABLE x_items (LIKE x_live) ON COMMIT DROP",
        "CREATE TEMP TABLE x_anns (path text, annotation_id uuid, kind text, class text, geometry jsonb, attrs jsonb) ON COMMIT DROP",
    }) |ddl| _ = tx.exec(scope, ddl, .{}) catch return error.Db;
    _ = tx.exec(scope, "INSERT INTO x_items SELECT l.* FROM x_live l " ++
        "WHERE (jsonb_array_length($1::jsonb) = 0 OR l.split IN (SELECT jsonb_array_elements_text($1::jsonb))) " ++
        "AND (jsonb_array_length($2::jsonb) = 0 OR EXISTS (SELECT 1 FROM x_alive a WHERE a.item_id = l.item_id " ++
        "  AND coalesce(a.class, '') IN (SELECT jsonb_array_elements_text($2::jsonb))))", .{ splits, classes }) catch return error.Db;
    if (kind != .state) {
        _ = tx.exec(scope, "INSERT INTO x_anns SELECT i.path, a.annotation_id, a.kind, a.class, a.geometry, a.attrs " ++
            "FROM x_alive a JOIN x_items i USING (item_id) " ++
            "WHERE jsonb_array_length($1::jsonb) = 0 OR coalesce(a.class, '') IN (SELECT jsonb_array_elements_text($1::jsonb))", .{classes}) catch return error.Db;
    }
    inline for (.{
        "CREATE INDEX ON x_items (path COLLATE \"C\")",
        "CREATE INDEX ON x_anns (path COLLATE \"C\", annotation_id)",
        "ANALYZE x_items",
        "ANALYZE x_anns",
    }) |sql| _ = tx.exec(scope, sql, .{}) catch return error.Db;

    const media_pending = (tx.rawOne(i64, scope, "SELECT 1::bigint FROM x_items l JOIN previews p USING (item_hash) " ++
        "WHERE p.status IN ('pending', 'building') LIMIT 1", .{}) catch return error.Db) != null;
    const bundle: Bundle = .{ .w = out };

    _ = tx.exec(scope, "DECLARE x_ic NO SCROLL CURSOR FOR SELECT path, encode(item_hash, 'hex') AS hash, size_bytes, split, " ++
        "item_id::text AS item_id, width, height FROM x_items ORDER BY path COLLATE \"C\"", .{}) catch return error.Db;

    switch (kind) {
        .state => {
            version.stateHeader(out, commit_id) catch return error.WriteFailed;
            while (true) {
                var batch = dbx.Run.init(gpa);
                defer batch.deinit();
                const rows = tx.raw(ItemRow, &batch, "FETCH 5000 FROM x_ic", .{}) catch return error.Db;
                for (rows) |r| out.print("{{\"path\":{f},\"hash\":\"{s}\",\"size\":{d},\"split\":{f},\"item_id\":{f},\"width\":{f},\"height\":{f}}}\n", .{
                    std.json.fmt(r.path, .{}),   r.hash,                       r.size_bytes,
                    std.json.fmt(r.split, .{}),  std.json.fmt(r.item_id, .{}), std.json.fmt(r.width, .{}),
                    std.json.fmt(r.height, .{}),
                }) catch return error.WriteFailed;
                if (rows.len < version.batch_rows) break;
            }
        },
        .jsonl, .yolo => {
            bundleHeader(out, kind, commit_id) catch return error.WriteFailed;
            var renderer: union(enum) { jsonl, yolo: yolo.Writer } = .jsonl;
            if (kind == .yolo) {
                const nameless = tx.rawOne([]const u8, scope, "SELECT path FROM x_anns WHERE kind = 'box' AND class IS NULL " ++
                    "ORDER BY path COLLATE \"C\" LIMIT 1", .{}) catch return error.Db;
                if (nameless) |path| return .{ .failed = .{ .path = try gpa.dupe(u8, path), .why = "a box has no class" } };
                const names = tx.raw([]const u8, scope, "SELECT class FROM (SELECT DISTINCT class FROM x_anns WHERE kind = 'box') d ORDER BY class COLLATE \"C\"", .{}) catch return error.Db;
                renderer = .{ .yolo = .{ .classes = try dupeAll(arena, names) } };
                renderer.yolo.begin(bundle, arena) catch return error.WriteFailed;
            }

            _ = tx.exec(scope, "DECLARE x_ac NO SCROLL CURSOR FOR SELECT path, annotation_id::text AS id, kind, class, " ++
                "geometry::text AS geometry, attrs::text AS attrs FROM x_anns ORDER BY path COLLATE \"C\", annotation_id", .{}) catch return error.Db;
            var anns: AnnStream = .{ .gpa = gpa };
            defer anns.deinit();
            var scratch = std.heap.ArenaAllocator.init(gpa);
            defer scratch.deinit();
            while (true) {
                var batch = dbx.Run.init(gpa);
                defer batch.deinit();
                const rows = tx.raw(ItemRow, &batch, "FETCH 5000 FROM x_ic", .{}) catch return error.Db;
                for (rows) |r| {
                    _ = scratch.reset(.retain_capacity);
                    const sa = scratch.allocator();
                    // This item's annotations: the next ones in path order.
                    var mine: std.ArrayList(Ann) = .empty;
                    while (try anns.peek(&tx)) |a| {
                        if (!std.mem.eql(u8, a.path, r.path)) break;
                        try mine.append(sa, .{
                            .id = try sa.dupe(u8, a.id),
                            .kind = if (a.kind) |v| try sa.dupe(u8, v) else null,
                            .class = if (a.class) |v| try sa.dupe(u8, v) else null,
                            .geometry = if (a.geometry) |v| try sa.dupe(u8, v) else null,
                            .attrs = if (a.attrs) |v| try sa.dupe(u8, v) else null,
                        });
                        anns.skip();
                    }
                    switch (renderer) {
                        .jsonl => jsonl.writeItem(bundle, sa, itemOf(r), mine.items) catch |err| return switch (err) {
                            error.OutOfMemory => error.OutOfMemory,
                            else => error.WriteFailed,
                        },
                        .yolo => |*y| if (y.writeItem(bundle, sa, itemOf(r), mine.items) catch |err| return switch (err) {
                            error.OutOfMemory => error.OutOfMemory,
                            else => error.WriteFailed,
                        }) |failure| return .{ .failed = .{ .path = try gpa.dupe(u8, failure.path), .why = failure.why } },
                    }
                }
                if (rows.len < version.batch_rows) break;
            }

            if (renderer == .yolo) {
                // The split lists, each one file, a batch of paths per line.
                var present: [yolo.split_names.len]bool = @splat(false);
                inline for (yolo.split_names, 0..) |name, i| {
                    _ = tx.exec(scope, "DECLARE x_split_" ++ name ++ " NO SCROLL CURSOR FOR SELECT path FROM x_items WHERE split = '" ++ name ++
                        "' ORDER BY path COLLATE \"C\"", .{}) catch return error.Db;
                    while (true) {
                        var batch = dbx.Run.init(gpa);
                        defer batch.deinit();
                        const paths = tx.raw([]const u8, &batch, "FETCH 5000 FROM x_split_" ++ name, .{}) catch return error.Db;
                        if (paths.len > 0) {
                            present[i] = true;
                            var text: std.ArrayList(u8) = .empty;
                            for (paths) |p| try text.print(batch.arena(), "{s}\n", .{p});
                            bundle.put(name ++ ".txt", text.items) catch return error.WriteFailed;
                        }
                        if (paths.len < version.batch_rows) break;
                    }
                }
                renderer.yolo.end(bundle, arena, present) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.WriteFailed,
                };
            }
        },
    }
    out.flush() catch return error.WriteFailed;
    return .{ .written = .{ .media_pending = media_pending } };
}

fn dupeAll(arena: std.mem.Allocator, list: []const []const u8) ![]const []const u8 {
    const out = try arena.alloc([]const u8, list.len);
    for (out, list) |*o, v| o.* = try arena.dupe(u8, v);
    return out;
}

/// The annotation cursor, read a batch at a time, one row peeked ahead.
const AnnStream = struct {
    gpa: std.mem.Allocator,
    batch: ?dbx.Run = null,
    rows: []const AnnRow = &.{},
    at: usize = 0,
    done: bool = false,

    fn peek(self: *AnnStream, tx: anytype) version.Error!?AnnRow {
        if (self.at < self.rows.len) return self.rows[self.at];
        if (self.done) return null;
        if (self.batch) |*b| b.deinit();
        self.batch = dbx.Run.init(self.gpa);
        self.rows = tx.raw(AnnRow, &self.batch.?, "FETCH 5000 FROM x_ac", .{}) catch return error.Db;
        self.at = 0;
        if (self.rows.len < version.batch_rows) self.done = true;
        return if (self.rows.len > 0) self.rows[0] else null;
    }

    fn skip(self: *AnnStream) void {
        self.at += 1;
    }

    fn deinit(self: *AnnStream) void {
        if (self.batch) |*b| b.deinit();
    }
};
