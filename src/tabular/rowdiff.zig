//! Row-level diff of two versions of a table file (CLAUDE.md, Formats):
//! rows added and removed, by whole-row comparison, with multiplicity — a
//! row that appears twice where it appeared once is one row added. A row
//! edited in place shows as one removed and one added, unless the table
//! has a key (`.cidkeys`, keys.zig): then rows pair up by it, and a pair
//! that differs is a row changed, shown cell by cell. A key that does not
//! hold (a column missing, a value repeated or empty) is said, and rows
//! are compared whole. When the columns themselves changed, rows are not
//! compared (they cannot line up) and the column change is the answer.
//!
//! One DuckDB query per question, answered as JSON; nothing here parses a
//! table. Runs on the server only.

const std = @import("std");
const duck = @import("../store/duck.zig");
const stats = @import("stats.zig");

/// How many added and removed rows are shown, each.
pub const sample_rows = 20;

/// A JSON object: `{rows_a, rows_b, columns_a, columns_b, columns_changed,
/// added, removed, added_sample, removed_sample}`. Both files must sit in
/// the directory `db` is confined to; they may be different kinds (a CSV
/// that became Parquet compares by its rows).
pub fn compute(
    arena: std.mem.Allocator,
    db: *duck.Db,
    a: []const u8,
    a_kind: stats.Kind,
    b: []const u8,
    b_kind: stats.Kind,
    /// The table's key columns (`.cidkeys`), or none.
    key: []const []const u8,
) duck.Error![]const u8 {
    const src_a = try stats.sourceOf(arena, a, a_kind);
    const src_b = try stats.sourceOf(arena, b, b_kind);

    const shape = (try db.scalarText(arena, try std.fmt.allocPrint(arena,
        \\WITH ca AS (SELECT list(column_name || ' ' || column_type) c FROM (DESCRIBE SELECT * FROM {s})),
        \\     cb AS (SELECT list(column_name || ' ' || column_type) c FROM (DESCRIBE SELECT * FROM {s}))
        \\SELECT json_object('columns_a', (SELECT c FROM ca), 'columns_b', (SELECT c FROM cb),
        \\  'names', (SELECT list(column_name) FROM (DESCRIBE SELECT * FROM {s})),
        \\  'same', (SELECT c FROM ca) = (SELECT c FROM cb),
        \\  'rows_a', (SELECT count(*) FROM {s}), 'rows_b', (SELECT count(*) FROM {s}))::VARCHAR
    , .{ src_a, src_b, src_b, src_a, src_b }))) orelse return error.QueryFailed;

    const Shape = struct { columns_a: []const []const u8, columns_b: []const []const u8, names: []const []const u8, same: bool, rows_a: u64, rows_b: u64 };
    const s = std.json.parseFromSliceLeaky(Shape, arena, shape, .{}) catch return error.QueryFailed;
    if (!s.same) {
        return std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{
            .rows_a = s.rows_a,
            .rows_b = s.rows_b,
            .columns_a = s.columns_a,
            .columns_b = s.columns_b,
            .columns_changed = true,
        }, .{})}) catch error.OutOfMemory;
    }

    if (key.len > 0) {
        const why = try keyProblem(arena, db, src_a, src_b, s.names, key);
        if (why == null) return keyed(arena, db, src_a, src_b, s.rows_a, s.rows_b, s.columns_a, s.columns_b, s.names, key);
        return whole(arena, db, src_a, src_b, s.rows_a, s.rows_b, s.columns_a, s.columns_b, why);
    }
    return whole(arena, db, src_a, src_b, s.rows_a, s.rows_b, s.columns_a, s.columns_b, null);
}

/// Rows compared whole, with multiplicity. `key_note` says why a declared
/// key was not used.
fn whole(
    arena: std.mem.Allocator,
    db: *duck.Db,
    src_a: []const u8,
    src_b: []const u8,
    rows_a: u64,
    rows_b: u64,
    columns_a: []const []const u8,
    columns_b: []const []const u8,
    key_note: ?[]const u8,
) duck.Error![]const u8 {
    const rows = (try db.scalarText(arena, try std.fmt.allocPrint(arena,
        \\WITH added AS (SELECT * FROM {s} EXCEPT ALL SELECT * FROM {s}),
        \\     removed AS (SELECT * FROM {s} EXCEPT ALL SELECT * FROM {s})
        \\SELECT json_object(
        \\  'added', (SELECT count(*) FROM added), 'removed', (SELECT count(*) FROM removed),
        \\  'added_sample', (SELECT coalesce(json_group_array(to_json(r)), '[]') FROM (SELECT * FROM added LIMIT {d}) r),
        \\  'removed_sample', (SELECT coalesce(json_group_array(to_json(r)), '[]') FROM (SELECT * FROM removed LIMIT {d}) r)
        \\)::VARCHAR
    , .{ src_b, src_a, src_a, src_b, sample_rows, sample_rows }))) orelse return error.QueryFailed;

    const Rows = struct { added: u64, removed: u64, added_sample: std.json.Value, removed_sample: std.json.Value };
    const r = std.json.parseFromSliceLeaky(Rows, arena, rows, .{}) catch return error.QueryFailed;
    return std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{
        .rows_a = rows_a,
        .rows_b = rows_b,
        .columns_a = columns_a,
        .columns_b = columns_b,
        .columns_changed = false,
        .added = r.added,
        .removed = r.removed,
        .added_sample = r.added_sample,
        .removed_sample = r.removed_sample,
        .key = @as(?[]const []const u8, null),
        .key_note = key_note,
    }, .{})}) catch error.OutOfMemory;
}

/// An identifier as DuckDB reads one: double-quoted.
fn ident(arena: std.mem.Allocator, name: []const u8) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '"');
    for (name) |c| {
        if (c == '"') try out.append(arena, '"');
        try out.append(arena, c);
    }
    try out.append(arena, '"');
    return out.items;
}

/// A string literal: single-quoted.
fn literal(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '\'');
    for (text) |c| {
        if (c == '\'') try out.append(arena, '\'');
        try out.append(arena, c);
    }
    try out.append(arena, '\'');
    return out.items;
}

fn has(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// Why the key cannot pair rows up, in words, or null when it can: every
/// key column there, no key empty, none repeated in either version.
fn keyProblem(arena: std.mem.Allocator, db: *duck.Db, src_a: []const u8, src_b: []const u8, names: []const []const u8, key: []const []const u8) duck.Error!?[]const u8 {
    for (key) |k| if (!has(names, k))
        return try std.fmt.allocPrint(arena, "the key column '{s}' is not in the table; rows compared whole", .{k});
    var cols: std.ArrayList(u8) = .empty;
    var empty: std.ArrayList(u8) = .empty;
    for (key, 0..) |k, i| {
        try cols.print(arena, "{s}{s}", .{ if (i > 0) ", " else "", try ident(arena, k) });
        try empty.print(arena, "{s}{s} IS NULL", .{ if (i > 0) " OR " else "", try ident(arena, k) });
    }
    const named = try std.mem.join(arena, ",", key);
    for ([_]struct { src: []const u8, side: []const u8 }{ .{ .src = src_a, .side = "the version before" }, .{ .src = src_b, .side = "this version" } }) |v| {
        const text = (try db.scalarText(arena, try std.fmt.allocPrint(arena,
            \\SELECT json_object(
            \\  'empty', (SELECT count(*) FROM {0s} WHERE {2s}),
            \\  'repeated', (SELECT to_json(x) FROM (SELECT {1s}, count(*) AS n FROM {0s} GROUP BY ALL HAVING count(*) > 1 LIMIT 1) x)
            \\)::VARCHAR
        , .{ v.src, cols.items, empty.items }))) orelse return error.QueryFailed;
        const Check = struct { empty: u64, repeated: ?std.json.Value };
        const c = std.json.parseFromSliceLeaky(Check, arena, text, .{}) catch return error.QueryFailed;
        if (c.empty > 0)
            return try std.fmt.allocPrint(arena, "the key '{s}' is empty in {d} rows of {s}; rows compared whole", .{ named, c.empty, v.side });
        if (c.repeated) |r| {
            const n = if (r == .object) (r.object.get("n") orelse std.json.Value{ .integer = 2 }) else std.json.Value{ .integer = 2 };
            var shown = r;
            if (shown == .object) _ = shown.object.orderedRemove("n");
            return try std.fmt.allocPrint(arena, "the key '{s}' repeats in {s} ({f} is on {f} rows); rows compared whole", .{ named, v.side, std.json.fmt(shown, .{}), std.json.fmt(n, .{}) });
        }
    }
    return null;
}

/// Rows paired by their key: added and removed by key, and the pairs
/// that differ, each with its changed cells, old and new.
fn keyed(
    arena: std.mem.Allocator,
    db: *duck.Db,
    src_a: []const u8,
    src_b: []const u8,
    rows_a: u64,
    rows_b: u64,
    columns_a: []const []const u8,
    columns_b: []const []const u8,
    names: []const []const u8,
    key: []const []const u8,
) duck.Error![]const u8 {
    var using: std.ArrayList(u8) = .empty;
    var key_struct: std.ArrayList(u8) = .empty;
    for (key, 0..) |k, i| {
        try using.print(arena, "{s}{s}", .{ if (i > 0) ", " else "", try ident(arena, k) });
        try key_struct.print(arena, "{s}{s} := a.{s}", .{ if (i > 0) ", " else "", try ident(arena, k), try ident(arena, k) });
    }
    // The cells that differ, as {column, before, after}; the key's own
    // columns pair the rows, so they never differ.
    var cells: std.ArrayList(u8) = .empty;
    var any_value = false;
    for (names) |n| {
        if (has(key, n)) continue;
        const id = try ident(arena, n);
        try cells.print(arena, "{s}CASE WHEN a.{s} IS DISTINCT FROM b.{s} THEN {{'column': {s}, 'before': a.{s}::VARCHAR, 'after': b.{s}::VARCHAR}} END", .{
            if (any_value) ", " else "", id, id, try literal(arena, n), id, id,
        });
        any_value = true;
    }
    const cells_sql = if (any_value)
        try std.fmt.allocPrint(arena, "list_filter([{s}], x -> x IS NOT NULL)", .{cells.items})
    else
        "[]::STRUCT(\"column\" VARCHAR, before VARCHAR, after VARCHAR)[]";
    const text = (try db.scalarText(arena, try std.fmt.allocPrint(arena,
        \\WITH a AS (SELECT * FROM {0s}), b AS (SELECT * FROM {1s}),
        \\added AS (SELECT b.* FROM b ANTI JOIN a USING ({2s})),
        \\removed AS (SELECT a.* FROM a ANTI JOIN b USING ({2s})),
        \\pairs AS (SELECT struct_pack({3s}) AS k, {4s} AS cells FROM a JOIN b USING ({2s})),
        \\changed AS (SELECT * FROM pairs WHERE len(cells) > 0)
        \\SELECT json_object(
        \\  'added', (SELECT count(*) FROM added), 'removed', (SELECT count(*) FROM removed),
        \\  'changed', (SELECT count(*) FROM changed),
        \\  'added_sample', (SELECT coalesce(json_group_array(to_json(r)), '[]') FROM (SELECT * FROM added LIMIT {5d}) r),
        \\  'removed_sample', (SELECT coalesce(json_group_array(to_json(r)), '[]') FROM (SELECT * FROM removed LIMIT {5d}) r),
        \\  'changed_sample', (SELECT coalesce(json_group_array(json_object('key', k, 'cells', cells)), '[]')
        \\     FROM (SELECT * FROM changed ORDER BY k LIMIT {5d}))
        \\)::VARCHAR
    , .{ src_a, src_b, using.items, key_struct.items, cells_sql, sample_rows }))) orelse return error.QueryFailed;
    const R = struct { added: u64, removed: u64, changed: u64, added_sample: std.json.Value, removed_sample: std.json.Value, changed_sample: std.json.Value };
    const r = std.json.parseFromSliceLeaky(R, arena, text, .{}) catch return error.QueryFailed;
    return std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{
        .rows_a = rows_a,
        .rows_b = rows_b,
        .columns_a = columns_a,
        .columns_b = columns_b,
        .columns_changed = false,
        .added = r.added,
        .removed = r.removed,
        .changed = r.changed,
        .added_sample = r.added_sample,
        .removed_sample = r.removed_sample,
        .changed_sample = r.changed_sample,
        .key = key,
        .key_note = @as(?[]const u8, null),
    }, .{})}) catch error.OutOfMemory;
}

test "rows added and removed, duplicates counted, edits as a pair: CSV, Parquet and JSONL" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", arena);
    var db = try duck.Db.open(arena, .{ .allowed_dir = dir });
    defer db.close();

    // people.csv, then: Budi deleted, Citra's score edited, Dewi appended twice.
    const fixtures = try std.Io.Dir.cwd().openDir(io, "tests/fixtures", .{});
    try fixtures.copyFile("people.csv", tmp.dir, "a.csv", io, .{});
    try fixtures.copyFile("people.parquet", tmp.dir, "a.parquet", io, .{});
    try tmp.dir.writeFile(io, .{ .sub_path = "b.csv", .data =
        \\id,name,city,score
        \\1,Ana Wijaya,Bandung,91.5
        \\3,Citra,Bandung,79
        \\4,Dewi,Surabaya,88.25
        \\5,Eko,Jakarta,64
        \\6,Fajar,Medan,70
        \\6,Fajar,Medan,70
        \\
    });
    const path = struct {
        fn of(al: std.mem.Allocator, d: []const u8, f: []const u8) ![]const u8 {
            return std.fmt.allocPrint(al, "{s}/{s}", .{ d, f });
        }
    }.of;

    const Diff = struct {
        rows_a: u64,
        rows_b: u64,
        columns_changed: bool,
        added: u64 = 0,
        removed: u64 = 0,
        added_sample: []const struct { name: []const u8 } = &.{},
        removed_sample: []const struct { name: []const u8 } = &.{},
    };
    for ([_]struct { file: []const u8, kind: stats.Kind }{ .{ .file = "a.csv", .kind = .csv }, .{ .file = "a.parquet", .kind = .parquet } }) |before| {
        const text = try compute(arena, &db, try path(arena, dir, before.file), before.kind, try path(arena, dir, "b.csv"), .csv, &.{});
        const d = try std.json.parseFromSliceLeaky(Diff, arena, text, .{ .ignore_unknown_fields = true });
        try std.testing.expect(!d.columns_changed);
        try std.testing.expectEqual(@as(u64, 5), d.rows_a);
        try std.testing.expectEqual(@as(u64, 6), d.rows_b);
        try std.testing.expectEqual(@as(u64, 3), d.added); // Citra (edited), Fajar ×2
        try std.testing.expectEqual(@as(u64, 2), d.removed); // Budi, Citra (old)
    }

    // JSONL, the same story: one object a row.
    const row = struct {
        fn line(id: u32, name: []const u8, city: []const u8, score: []const u8) [128]u8 {
            var buf: [128]u8 = @splat(' ');
            _ = std.fmt.bufPrint(&buf, "{{\"id\":{d},\"name\":\"{s}\",\"city\":\"{s}\",\"score\":{s}}}", .{ id, name, city, score }) catch unreachable;
            return buf;
        }
    }.line;
    var a_lines: std.ArrayList(u8) = .empty;
    var b_lines: std.ArrayList(u8) = .empty;
    for ([_]struct { u32, []const u8, []const u8, []const u8 }{
        .{ 1, "Ana Wijaya", "Bandung", "91.5" }, .{ 2, "Budi", "Jakarta", "72" },
        .{ 3, "Citra", "Bandung", "78" },        .{ 4, "Dewi", "Surabaya", "88.25" },
        .{ 5, "Eko", "Jakarta", "64" },
    }) |r| try a_lines.print(arena, "{s}\n", .{std.mem.trimEnd(u8, &row(r[0], r[1], r[2], r[3]), " ")});
    for ([_]struct { u32, []const u8, []const u8, []const u8 }{
        .{ 1, "Ana Wijaya", "Bandung", "91.5" }, .{ 3, "Citra", "Bandung", "79" },
        .{ 4, "Dewi", "Surabaya", "88.25" },     .{ 5, "Eko", "Jakarta", "64" },
        .{ 6, "Fajar", "Medan", "70" },          .{ 6, "Fajar", "Medan", "70" },
    }) |r| try b_lines.print(arena, "{s}\n", .{std.mem.trimEnd(u8, &row(r[0], r[1], r[2], r[3]), " ")});
    try tmp.dir.writeFile(io, .{ .sub_path = "a.jsonl", .data = a_lines.items });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.jsonl", .data = b_lines.items });
    const jd = try std.json.parseFromSliceLeaky(Diff, arena, try compute(arena, &db, try path(arena, dir, "a.jsonl"), .jsonl, try path(arena, dir, "b.jsonl"), .jsonl, &.{}), .{ .ignore_unknown_fields = true });
    try std.testing.expect(!jd.columns_changed);
    try std.testing.expectEqual(@as(u64, 5), jd.rows_a);
    try std.testing.expectEqual(@as(u64, 6), jd.rows_b);
    try std.testing.expectEqual(@as(u64, 3), jd.added);
    try std.testing.expectEqual(@as(u64, 2), jd.removed);

    // A column added: rows are not compared, the column change is the answer.
    try tmp.dir.writeFile(io, .{ .sub_path = "c.csv", .data = "id,name,city,score,team\n1,Ana Wijaya,Bandung,91.5,red\n" });
    const wider = try std.json.parseFromSliceLeaky(struct { columns_changed: bool, columns_b: []const []const u8 }, arena, try compute(arena, &db, try path(arena, dir, "a.csv"), .csv, try path(arena, dir, "c.csv"), .csv, &.{}), .{ .ignore_unknown_fields = true });
    try std.testing.expect(wider.columns_changed);
    try std.testing.expectEqualStrings("team VARCHAR", wider.columns_b[4]);
}

test "a key pairs rows up: added, removed and changed cell by cell; a key that does not hold is said" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", arena);
    var db = try duck.Db.open(arena, .{ .allowed_dir = dir });
    defer db.close();
    const fixtures = try std.Io.Dir.cwd().openDir(io, "tests/fixtures", .{});
    try fixtures.copyFile("people.csv", tmp.dir, "a.csv", io, .{});
    try fixtures.copyFile("people.parquet", tmp.dir, "a.parquet", io, .{});
    // Budi gone, Citra's score 78 → 79, Fajar in.
    try tmp.dir.writeFile(io, .{ .sub_path = "b.csv", .data = "id,name,city,score\n1,Ana Wijaya,Bandung,91.5\n3,Citra,Bandung,79\n4,Dewi,Surabaya,88.25\n5,Eko,Jakarta,64\n6,Fajar,Medan,70\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "twice.csv", .data = "id,name,city,score\n1,Ana Wijaya,Bandung,91.5\n6,Fajar,Medan,70\n6,Fajar,Medan,70\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "blank.csv", .data = "id,name,city,score\n,Ana Wijaya,Bandung,91.5\n2,Budi,Jakarta,72\n" });
    const at = struct {
        fn of(al: std.mem.Allocator, d: []const u8, f: []const u8) ![]const u8 {
            return std.fmt.allocPrint(al, "{s}/{s}", .{ d, f });
        }
    }.of;
    const Cell = struct { column: []const u8, before: ?[]const u8, after: ?[]const u8 };
    const Diff = struct {
        added: u64,
        removed: u64,
        changed: u64 = 0,
        key: ?[]const []const u8,
        key_note: ?[]const u8,
        added_sample: []const struct { name: []const u8 } = &.{},
        removed_sample: []const struct { name: []const u8 } = &.{},
        changed_sample: []const struct { key: struct { id: i64 }, cells: []const Cell } = &.{},
    };
    const id = [_][]const u8{"id"};
    for ([_]struct { []const u8, stats.Kind }{ .{ "a.csv", .csv }, .{ "a.parquet", .parquet } }) |before| {
        const d = try std.json.parseFromSliceLeaky(Diff, arena, try compute(arena, &db, try at(arena, dir, before[0]), before[1], try at(arena, dir, "b.csv"), .csv, &id), .{ .ignore_unknown_fields = true });
        try std.testing.expectEqual(@as(u64, 1), d.added);
        try std.testing.expectEqualStrings("Fajar", d.added_sample[0].name);
        try std.testing.expectEqual(@as(u64, 1), d.removed);
        try std.testing.expectEqualStrings("Budi", d.removed_sample[0].name);
        try std.testing.expectEqual(@as(u64, 1), d.changed);
        try std.testing.expectEqual(@as(i64, 3), d.changed_sample[0].key.id);
        try std.testing.expectEqual(@as(usize, 1), d.changed_sample[0].cells.len); // only the score
        try std.testing.expectEqualStrings("score", d.changed_sample[0].cells[0].column);
        try std.testing.expectEqualStrings("79.0", d.changed_sample[0].cells[0].after.?);
        try std.testing.expectEqualStrings("id", d.key.?[0]);
        try std.testing.expect(d.key_note == null);
    }
    // A key that does not hold: rows compared whole, and the reason said.
    const twice = try std.json.parseFromSliceLeaky(Diff, arena, try compute(arena, &db, try at(arena, dir, "a.csv"), .csv, try at(arena, dir, "twice.csv"), .csv, &id), .{ .ignore_unknown_fields = true });
    try std.testing.expect(twice.key == null);
    try std.testing.expect(std.mem.indexOf(u8, twice.key_note.?, "the key 'id' repeats in this version ({\"id\":6} is on 2 rows)") != null);
    const blank = try std.json.parseFromSliceLeaky(Diff, arena, try compute(arena, &db, try at(arena, dir, "a.csv"), .csv, try at(arena, dir, "blank.csv"), .csv, &id), .{ .ignore_unknown_fields = true });
    try std.testing.expect(std.mem.indexOf(u8, blank.key_note.?, "is empty in 1 rows of this version") != null);
    const nope = try std.json.parseFromSliceLeaky(Diff, arena, try compute(arena, &db, try at(arena, dir, "a.csv"), .csv, try at(arena, dir, "b.csv"), .csv, &.{"nope"}), .{ .ignore_unknown_fields = true });
    try std.testing.expect(std.mem.indexOf(u8, nope.key_note.?, "the key column 'nope' is not in the table") != null);
    try std.testing.expectEqual(@as(u64, 2), nope.added); // Citra (edited) and Fajar, whole rows
}
