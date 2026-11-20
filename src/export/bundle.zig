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
const coco = @import("coco.zig");
const voc = @import("voc.zig");

/// `hf`: the jsonl export's lines alone, no bundle framing or header: a
/// plain JSON-lines file, as the Hugging Face door serves it.
pub const Kind = enum { state, jsonl, yolo, hf, coco, voc };

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
    /// The text alone, unframed (an export of one file, `hf`).
    raw: bool = false,

    pub fn put(self: Bundle, path: []const u8, text: []const u8) !void {
        if (self.raw) return self.w.writeAll(text);
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
        "WHERE (jsonb_array_length($1::jsonb) = 0 OR coalesce(l.split, '') IN (SELECT jsonb_array_elements_text($1::jsonb))) " ++
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
    const bundle: Bundle = .{ .w = out, .raw = kind == .hf };

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
        .coco => {
            bundleHeader(out, kind, commit_id) catch return error.WriteFailed;
            if (try writeCoco(gpa, arena, &tx, scope, bundle)) |failure| return .{ .failed = failure };
        },
        .jsonl, .yolo, .hf, .voc => {
            if (kind != .hf) bundleHeader(out, kind, commit_id) catch return error.WriteFailed;
            var renderer: union(enum) { jsonl, yolo: yolo.Writer, voc } = if (kind == .voc) .voc else .jsonl;
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
                        .voc => switch (voc.writeItem(bundle, sa, itemOf(r), mine.items) catch |err| return switch (err) {
                            error.OutOfMemory => error.OutOfMemory,
                            else => error.WriteFailed,
                        }) {
                            .written, .left_out => {},
                            .failed => |failure| return .{ .failed = .{ .path = try gpa.dupe(u8, failure.path), .why = failure.why } },
                        },
                    }
                }
                if (rows.len < version.batch_rows) break;
            }

            if (renderer == .voc) try vocLists(gpa, arena, &tx, scope, bundle);
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

/// A split's value as an SQL literal: the splits come from history, and
/// a cursor's query takes no parameters, so it is quoted here.
fn literal(arena: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '\'');
    for (value) |c| {
        if (c == '\'') try out.append(arena, '\'');
        try out.append(arena, c);
    }
    try out.append(arena, '\'');
    return out.items;
}

/// Every split value in the export, sorted ("" for items with none).
fn splitsOf(arena: std.mem.Allocator, tx: anytype, scope: anytype) version.Error![]const []const u8 {
    const rows = tx.raw([]const u8, scope, "SELECT s FROM (SELECT DISTINCT coalesce(split, '') AS s FROM x_items) d ORDER BY s COLLATE \"C\"", .{}) catch return error.Db;
    return dupeAll(arena, rows);
}

/// VOC's split lists: each image that got its annotation file (it has
/// dimensions), by its id, a batch of ids per piece.
fn vocLists(gpa: std.mem.Allocator, arena: std.mem.Allocator, tx: anytype, scope: anytype, out: Bundle) version.Error!void {
    for (try splitsOf(arena, tx, scope)) |split| {
        const file = try voc.listFor(arena, split);
        _ = tx.exec(scope, try std.fmt.allocPrint(arena, "DECLARE x_list NO SCROLL CURSOR FOR SELECT path FROM x_items " ++
            "WHERE coalesce(split, '') = {s} AND width > 0 AND height > 0 ORDER BY path COLLATE \"C\"", .{try literal(arena, split)}), .{}) catch return error.Db;
        while (true) {
            var batch = dbx.Run.init(gpa);
            defer batch.deinit();
            const paths = tx.raw([]const u8, &batch, "FETCH 5000 FROM x_list", .{}) catch return error.Db;
            var text: std.ArrayList(u8) = .empty;
            for (paths) |p| try text.print(batch.arena(), "{s}\n", .{voc.stem(p)});
            if (text.items.len > 0) out.put(file, text.items) catch return error.WriteFailed;
            if (paths.len < version.batch_rows) break;
        }
        _ = tx.exec(scope, "CLOSE x_list", .{}) catch return error.Db;
    }
}

const CocoImageRow = struct {
    pub const nilo_table = .projection;
    path: []const u8,
    hash: []const u8,
    size_bytes: i64,
    split: ?[]const u8,
    item_id: ?[]const u8,
    width: ?i32,
    height: ?i32,
    image_id: i64,
    shapes: bool,
};

const CocoAnnRow = struct {
    pub const nilo_table = .projection;
    path: []const u8,
    id: []const u8,
    kind: ?[]const u8,
    class: ?[]const u8,
    geometry: ?[]const u8,
    attrs: ?[]const u8,
    image_id: i64,
};

/// COCO: per split, one instances file written whole before the next:
/// header, images, annotations, footer. Image ids are the items' places in
/// path order across the export, annotation ids a count in writing order,
/// so the same version always writes the same files.
fn writeCoco(gpa: std.mem.Allocator, arena: std.mem.Allocator, tx: anytype, scope: anytype, out: Bundle) version.Error!?Failure {
    const shapes = "kind IN " ++ coco.exported_kinds;
    if (tx.rawOne([]const u8, scope, "SELECT path FROM x_anns WHERE " ++ shapes ++ " AND class IS NULL ORDER BY path COLLATE \"C\" LIMIT 1", .{}) catch return error.Db) |path|
        return .{ .path = try gpa.dupe(u8, path), .why = "a shape has no class" };
    const categories = try dupeAll(arena, tx.raw([]const u8, scope, "SELECT class FROM (SELECT DISTINCT class FROM x_anns WHERE " ++ shapes ++ ") d ORDER BY class COLLATE \"C\"", .{}) catch return error.Db);
    _ = tx.exec(scope, "CREATE TEMP TABLE x_img ON COMMIT DROP AS SELECT i.path, i.item_hash, i.split, i.item_id, i.width, i.height, " ++
        "row_number() OVER (ORDER BY i.path COLLATE \"C\") AS image_id, " ++
        "EXISTS (SELECT 1 FROM x_anns a WHERE a.path = i.path AND a." ++ shapes ++ ") AS shapes FROM x_items i", .{}) catch return error.Db;
    _ = tx.exec(scope, "CREATE INDEX ON x_img (path COLLATE \"C\")", .{}) catch return error.Db;

    var next_ann: u64 = 1;
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    for (try splitsOf(arena, tx, scope)) |split| {
        const file = try coco.fileFor(arena, split);
        const where = try std.fmt.allocPrint(arena, "coalesce(split, '') = {s}", .{try literal(arena, split)});
        coco.header(out, arena, file, categories) catch return error.WriteFailed;

        // Its images: every item with dimensions, and any with shapes
        // (which then must have them); a file that is not an image, with
        // nothing to draw on it, is not one.
        _ = tx.exec(scope, try std.fmt.allocPrint(arena, "DECLARE x_ci NO SCROLL CURSOR FOR SELECT path, encode(item_hash, 'hex') AS hash, 0::bigint AS size_bytes, split, " ++
            "item_id::text AS item_id, width, height, image_id, shapes FROM x_img WHERE {s} AND (shapes OR (width > 0 AND height > 0)) ORDER BY path COLLATE \"C\"", .{where}), .{}) catch return error.Db;
        var first = true;
        while (true) {
            var batch = dbx.Run.init(gpa);
            defer batch.deinit();
            const rows = tx.raw(CocoImageRow, &batch, "FETCH 5000 FROM x_ci", .{}) catch return error.Db;
            for (rows) |r| {
                _ = scratch.reset(.retain_capacity);
                const item = itemOf(.{ .path = r.path, .hash = r.hash, .size_bytes = 0, .split = r.split, .item_id = r.item_id, .width = r.width, .height = r.height });
                if (coco.image(out, scratch.allocator(), file, first, @intCast(r.image_id), item) catch return error.WriteFailed) |failure|
                    return .{ .path = try gpa.dupe(u8, failure.path), .why = failure.why };
                first = false;
            }
            if (rows.len < version.batch_rows) break;
        }
        _ = tx.exec(scope, "CLOSE x_ci", .{}) catch return error.Db;
        coco.between(out, file) catch return error.WriteFailed;

        _ = tx.exec(scope, try std.fmt.allocPrint(arena, "DECLARE x_ca NO SCROLL CURSOR FOR SELECT a.path, a.annotation_id::text AS id, a.kind, a.class, " ++
            "a.geometry::text AS geometry, a.attrs::text AS attrs, i.image_id FROM x_anns a JOIN x_img i USING (path) " ++
            "WHERE coalesce(i.split, '') = {s} AND a.{s} ORDER BY i.image_id, a.annotation_id", .{ try literal(arena, split), shapes }), .{}) catch return error.Db;
        first = true;
        while (true) {
            var batch = dbx.Run.init(gpa);
            defer batch.deinit();
            const rows = tx.raw(CocoAnnRow, &batch, "FETCH 5000 FROM x_ca", .{}) catch return error.Db;
            for (rows) |r| {
                _ = scratch.reset(.retain_capacity);
                const ann: Ann = .{ .id = r.id, .kind = r.kind, .class = r.class, .geometry = r.geometry, .attrs = r.attrs };
                if (coco.annotation(out, scratch.allocator(), file, first, next_ann, @intCast(r.image_id), r.path, categories, ann) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.WriteFailed,
                }) |failure| return .{ .path = try gpa.dupe(u8, failure.path), .why = failure.why };
                first = false;
                next_ann += 1;
            }
            if (rows.len < version.batch_rows) break;
        }
        _ = tx.exec(scope, "CLOSE x_ca", .{}) catch return error.Db;
        coco.footer(out, file) catch return error.WriteFailed;
    }
    return null;
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
