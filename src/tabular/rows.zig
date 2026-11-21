//! A table item's rows, a page at a time, narrowed by its columns' values,
//! with each column's distribution counted against the other columns'
//! filters (docs/roadmap.md, U6), as Browse counts its facets. Read from
//! the table converted once to Parquet (`convert`), in the browse folder.
//!
//! A number column's distribution is 20 bins of equal width across the
//! whole column's range; a filter on it names a bin, and the server applies
//! the same formula that counted it, so a bar and its rows always agree.
//! Any other column's distribution is its 10 most common values, with how
//! many rows hold another value or none. Rows keep their place in the file
//! (`__row`, from 0), so a row can be linked to.

const std = @import("std");
const duck = @import("../store/duck.zig");
const stats = @import("stats.zig");
const sql = @import("rowdiff.zig");

/// Bins of a number column's distribution.
pub const bins = 20;
/// Values of any other column's distribution.
pub const top_values = 10;
/// Columns that get a distribution; a wider table's later columns show
/// their rows without one.
pub const max_hist_columns = 30;
pub const max_limit = 200;

/// One column's filter: a bin of a number column, a value of any other,
/// or the rows where the column holds nothing.
pub const Filter = struct {
    column: []const u8,
    bin: ?u32 = null,
    value: ?[]const u8 = null,
    null: bool = false,
};

/// A page, or a filter the table cannot answer (a column it does not have,
/// or a bin on a column that is not a number), said as such.
pub const Answer = union(enum) { page: []const u8, refused: []const u8 };

/// The table at `src` as Parquet at `out`, both inside the folder `db`
/// was confined to: read once, so every page after reads columns, not CSV.
pub fn convert(arena: std.mem.Allocator, db: *duck.Db, src: []const u8, kind: stats.Kind, out: []const u8) duck.Error!void {
    const source = try stats.sourceOf(arena, src, kind);
    _ = try db.scalarText(arena, try std.fmt.allocPrint(arena, "COPY (SELECT * FROM {s}) TO {s} (FORMAT parquet)", .{ source, try sql.literal(arena, out) }));
}

const Column = struct { name: []const u8, type: []const u8 };

fn isNumber(column_type: []const u8) bool {
    inline for (.{ "TINYINT", "SMALLINT", "INTEGER", "BIGINT", "HUGEINT", "UTINYINT", "USMALLINT", "UINTEGER", "UBIGINT", "FLOAT", "DOUBLE", "DECIMAL" }) |t|
        if (std.mem.startsWith(u8, column_type, t)) return true;
    return false;
}

/// `{total, matched, offset, columns: [{name, type, hist}], rows: [{__row, …}]}`.
/// `hist` is `{kind: "bins", lo, hi, counts: [20], nulls}` or `{kind:
/// "values", top: [{v, n}], other, nulls}`, or null past the first 30
/// columns.
pub fn page(arena: std.mem.Allocator, db: *duck.Db, parquet: []const u8, filters: []const Filter, offset: u64, limit: u32) duck.Error!Answer {
    const src = try std.fmt.allocPrint(arena, "read_parquet({s}, file_row_number = true)", .{try sql.literal(arena, parquet)});
    const described = (try db.scalarText(arena, try std.fmt.allocPrint(arena, "SELECT json_group_array(json_object('name', column_name, 'type', column_type)) FROM (DESCRIBE SELECT * FROM read_parquet({s}))", .{try sql.literal(arena, parquet)}))) orelse return error.QueryFailed;
    const columns = std.json.parseFromSliceLeaky([]const Column, arena, described, .{}) catch return error.QueryFailed;

    // One condition per filter, its values bound as parameters.
    var args: std.ArrayList(duck.Db.Arg) = .empty;
    const conds = try arena.alloc([]const u8, filters.len);
    for (filters, conds) |f, *cond| {
        const col = for (columns) |c| {
            if (std.mem.eql(u8, c.name, f.column)) break c;
        } else return .{ .refused = f.column };
        const id = try sql.ident(arena, col.name);
        if (f.null) {
            cond.* = try std.fmt.allocPrint(arena, "{s} IS NULL", .{id});
        } else if (f.bin) |b| {
            if (!isNumber(col.type) or b >= bins) return .{ .refused = f.column };
            // NOT NULL first: least() skips a NULL, so it would land in the top bin.
            cond.* = try std.fmt.allocPrint(arena, "({s} IS NOT NULL AND ({s}) = {d})", .{ id, try binOf(arena, id), b });
        } else if (f.value) |v| {
            try args.append(arena, .{ .text = v });
            cond.* = try std.fmt.allocPrint(arena, "{s}::VARCHAR = ${d}", .{ id, args.items.len });
        } else return .{ .refused = f.column };
    }

    var out: std.ArrayList(u8) = .empty;
    const w = struct {
        fn all(a: std.mem.Allocator, parts: []const []const u8, skip: ?usize) ![]const u8 {
            var t: std.ArrayList(u8) = .empty;
            try t.appendSlice(a, "true");
            for (parts, 0..) |p, i| if (skip == null or skip.? != i) {
                try t.appendSlice(a, " AND ");
                try t.appendSlice(a, p);
            };
            return t.items;
        }
    };
    try out.print(arena, "WITH t AS (SELECT * EXCLUDE (file_row_number), file_row_number AS __row FROM {s}) SELECT json_object(" ++
        "'total', (SELECT count(*) FROM t), 'matched', (SELECT count(*) FROM t WHERE {s}), 'offset', {d}, " ++
        "'rows', (SELECT coalesce(json_group_array(to_json(r)), '[]') FROM (SELECT * FROM t WHERE {s} ORDER BY __row LIMIT {d} OFFSET {d}) r), " ++
        "'columns', json_array(", .{ src, try w.all(arena, conds, null), offset, try w.all(arena, conds, null), limit, offset });
    for (columns, 0..) |col, i| {
        if (i > 0) try out.appendSlice(arena, ", ");
        const id = try sql.ident(arena, col.name);
        // Counted against every filter but this column's own.
        var others: std.ArrayList([]const u8) = .empty;
        for (filters, conds) |f, cond| if (!std.mem.eql(u8, f.column, col.name)) try others.append(arena, cond);
        const where = try w.all(arena, others.items, null);
        const hist = if (i >= max_hist_columns)
            "NULL"
        else if (isNumber(col.type))
            try std.fmt.allocPrint(arena, "json_object('kind', 'bins', 'lo', (SELECT min({0s})::DOUBLE FROM t), 'hi', (SELECT max({0s})::DOUBLE FROM t), " ++
                "'counts', (SELECT list(coalesce(n, 0) ORDER BY b) FROM range({2d}) g(b) LEFT JOIN " ++
                "(SELECT ({3s}) AS k, count(*) AS n FROM t WHERE {0s} IS NOT NULL AND {1s} GROUP BY 1) c ON c.k = g.b), " ++
                "'nulls', (SELECT count(*) FROM t WHERE {0s} IS NULL AND {1s}))", .{ id, where, bins, try binOf(arena, id) })
        else
            try std.fmt.allocPrint(arena, "json_object('kind', 'values', " ++
                "'top', (SELECT coalesce(json_group_array(json_object('v', v, 'n', n)), '[]') FROM " ++
                "(SELECT {0s}::VARCHAR AS v, count(*) AS n FROM t WHERE {0s} IS NOT NULL AND {1s} GROUP BY 1 ORDER BY n DESC, v LIMIT {2d})), " ++
                "'nonnull', (SELECT count({0s}) FROM t WHERE {1s}), " ++
                "'nulls', (SELECT count(*) FROM t WHERE {0s} IS NULL AND {1s}))", .{ id, where, top_values });
        try out.print(arena, "json_object('name', {s}, 'type', {s}, 'hist', {s})", .{ try sql.literal(arena, col.name), try sql.literal(arena, col.type), hist });
    }
    try out.appendSlice(arena, "))::VARCHAR");
    return .{ .page = (try db.scalarTextArgs(arena, out.items, args.items)) orelse return error.QueryFailed };
}

/// The bin a number column's value falls in, 0…19, across the whole
/// column's range; the top value lands in the last bin.
fn binOf(arena: std.mem.Allocator, id: []const u8) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(arena, "least({1d}, CASE WHEN (SELECT max({0s}) FROM t) = (SELECT min({0s}) FROM t) THEN 0 " ++
        "ELSE floor(({0s}::DOUBLE - (SELECT min({0s})::DOUBLE FROM t)) / ((SELECT max({0s})::DOUBLE FROM t) - (SELECT min({0s})::DOUBLE FROM t)) * {2d})::BIGINT END)", .{ id, bins - 1, bins });
}

test "rows a page at a time, narrowed by a bin or a value, each column counted against the others" {
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
    try fixtures.copyFile("people.csv", tmp.dir, "people.csv", io, .{});
    const parquet = try std.fmt.allocPrint(arena, "{s}/people.parquet", .{dir});
    try convert(arena, &db, try std.fmt.allocPrint(arena, "{s}/people.csv", .{dir}), .csv, parquet);

    const Hist = struct { kind: []const u8, counts: ?[]const u64 = null, top: ?[]const struct { v: []const u8, n: u64 } = null, nulls: u64 = 0 };
    const Page = struct {
        total: u64,
        matched: u64,
        columns: []const struct { name: []const u8, type: []const u8, hist: ?Hist },
        rows: []const std.json.Value,
    };
    const all = try std.json.parseFromSliceLeaky(Page, arena, (try page(arena, &db, parquet, &.{}, 0, 2)).page, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(u64, 5), all.total);
    try std.testing.expectEqual(@as(u64, 5), all.matched);
    try std.testing.expectEqual(@as(usize, 2), all.rows.len);
    try std.testing.expectEqual(@as(i64, 0), all.rows[0].object.get("__row").?.integer);
    // score: a number, binned; one row has none. city: values.
    const score = all.columns[3].hist.?;
    try std.testing.expectEqualStrings("bins", score.kind);
    try std.testing.expectEqual(@as(usize, bins), score.counts.?.len);
    try std.testing.expectEqual(@as(u64, 1), score.nulls);
    var binned: u64 = 0;
    for (score.counts.?) |n| binned += n;
    try std.testing.expectEqual(@as(u64, 4), binned);
    try std.testing.expectEqual(@as(u64, 1), score.counts.?[bins - 1]); // the top score, 91.5
    try std.testing.expectEqualStrings("values", all.columns[2].hist.?.kind);

    // The top bin's rows; the score column still counts every score, the
    // others only that row.
    const top = try std.json.parseFromSliceLeaky(Page, arena, (try page(arena, &db, parquet, &.{.{ .column = "score", .bin = bins - 1 }}, 0, 50)).page, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(u64, 1), top.matched);
    var still: u64 = 0;
    for (top.columns[3].hist.?.counts.?) |n| still += n;
    try std.testing.expectEqual(@as(u64, 4), still);
    try std.testing.expectEqual(@as(u64, 1), top.columns[2].hist.?.top.?.len);

    // A value, bound, never spliced; an unknown column refused.
    const one = try std.json.parseFromSliceLeaky(Page, arena, (try page(arena, &db, parquet, &.{.{ .column = "name", .value = "x' OR '1'='1" }}, 0, 50)).page, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(u64, 0), one.matched);
    try std.testing.expectEqualStrings("nope", (try page(arena, &db, parquet, &.{.{ .column = "nope", .value = "1" }}, 0, 50)).refused);
    try std.testing.expectEqualStrings("name", (try page(arena, &db, parquet, &.{.{ .column = "name", .bin = 0 }}, 0, 50)).refused);
    const none = try std.json.parseFromSliceLeaky(Page, arena, (try page(arena, &db, parquet, &.{.{ .column = "score", .null = true }}, 0, 50)).page, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(u64, 1), none.matched);
}
