//! Table statistics for the dashboard (docs/dashboard.md, Phase 2: table
//! statistics): row count, per-column type, range, distinct count and
//! nulls, and the first rows, for a CSV, Parquet or JSONL file — built by
//! the preview worker once per content hash, like a thumbnail, and never on
//! a request. Reading a table is one of the two places cid interprets file
//! contents at all (invariant 15).
//!
//! One DuckDB query answers the whole thing as a JSON value, so nothing
//! here parses a table.

const std = @import("std");
const duck = @import("../store/duck.zig");

pub const Kind = enum { csv, parquet, jsonl };

/// The table kind a path names, by extension; null for anything else.
pub fn kindOf(path: []const u8) ?Kind {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return null;
    const ext = path[dot..];
    if (std.ascii.eqlIgnoreCase(ext, ".csv")) return .csv;
    if (std.ascii.eqlIgnoreCase(ext, ".parquet")) return .parquet;
    if (std.ascii.eqlIgnoreCase(ext, ".jsonl") or std.ascii.eqlIgnoreCase(ext, ".ndjson")) return .jsonl;
    return null;
}

/// A JSON object `{rows, columns: [{name, type, min, max, distinct,
/// null_percent}], sample: [{…}]}` for the file at `path`, which must sit
/// in the directory `db` was confined to. The sample shrinks, then goes,
/// so the answer stays a small database row whatever the cells hold.
pub fn compute(arena: std.mem.Allocator, db: *duck.Db, path: []const u8, kind: Kind) duck.Error![]const u8 {
    for ([_]u32{ 20, 5, 0 }) |rows| {
        const text = (try db.scalarText(arena, try query(arena, path, kind, rows))) orelse return error.QueryFailed;
        if (text.len <= max_bytes or rows == 0) return text;
    }
    unreachable;
}

/// What one table's statistics may weigh in `previews.table_stats`.
pub const max_bytes = 64 * 1024;

/// The DuckDB reader for a table file: `read_csv('…')` and its kin, with
/// the path quoted as a SQL string.
pub fn sourceOf(arena: std.mem.Allocator, path: []const u8, kind: Kind) duck.Error![]const u8 {
    var quoted: std.ArrayList(u8) = .empty;
    for (path) |ch| {
        if (ch == '\'') quoted.append(arena, '\'') catch return error.OutOfMemory;
        quoted.append(arena, ch) catch return error.OutOfMemory;
    }
    return switch (kind) {
        .csv => std.fmt.allocPrint(arena, "read_csv('{s}')", .{quoted.items}),
        .parquet => std.fmt.allocPrint(arena, "read_parquet('{s}')", .{quoted.items}),
        .jsonl => std.fmt.allocPrint(arena, "read_json('{s}', format = 'newline_delimited')", .{quoted.items}),
    } catch error.OutOfMemory;
}

fn query(arena: std.mem.Allocator, path: []const u8, kind: Kind, sample_rows: u32) duck.Error![]const u8 {
    const source = try sourceOf(arena, path, kind);
    const sample = if (sample_rows == 0)
        "'[]'::JSON"
    else
        std.fmt.allocPrint(arena, "(SELECT coalesce(json_group_array(to_json(r)), '[]') FROM (SELECT * FROM src LIMIT {d}) r)", .{sample_rows}) catch
            return error.OutOfMemory;
    return std.fmt.allocPrint(arena,
        \\WITH src AS (SELECT * FROM {s})
        \\SELECT json_object(
        \\  'rows', (SELECT count(*) FROM src),
        \\  'columns', (SELECT json_group_array(json_object(
        \\      'name', column_name, 'type', column_type, 'min', min, 'max', max,
        \\      'distinct', approx_unique, 'null_percent', null_percentage))
        \\    FROM (SUMMARIZE SELECT * FROM src)),
        \\  'sample', {s}
        \\)::VARCHAR
    , .{ source, sample }) catch error.OutOfMemory;
}

test "table kinds by extension" {
    try std.testing.expectEqual(Kind.csv, kindOf("people.CSV").?);
    try std.testing.expectEqual(Kind.parquet, kindOf("events/date=2026-03-01/part-0.parquet").?);
    try std.testing.expectEqual(Kind.jsonl, kindOf("labels.jsonl").?);
    try std.testing.expect(kindOf("photo.png") == null);
    try std.testing.expect(kindOf("README") == null);
}

test "statistics for every table fixture, read the same way" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    // The fixtures are copied into a scratch folder the database is
    // confined to, which is how the worker uses it.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", arena);
    var db = try duck.Db.open(arena, .{ .allowed_dir = dir });
    defer db.close();

    const Stats = struct {
        rows: u64,
        columns: []const struct { name: []const u8, type: []const u8, min: ?[]const u8, max: ?[]const u8, null_percent: f64 },
        sample: []const std.json.Value,
    };
    const cases = [_]struct { file: []const u8, kind: Kind, rows: u64, cols: usize }{
        .{ .file = "people.csv", .kind = .csv, .rows = 5, .cols = 4 },
        .{ .file = "people.parquet", .kind = .parquet, .rows = 5, .cols = 4 },
        .{ .file = "events.jsonl", .kind = .jsonl, .rows = 3, .cols = 4 },
    };
    const fixtures = try std.Io.Dir.cwd().openDir(io, "tests/fixtures", .{});
    for (cases) |case| {
        try fixtures.copyFile(case.file, tmp.dir, case.file, io, .{});
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, case.file });
        const text = try compute(arena, &db, path, case.kind);
        const stats = try std.json.parseFromSliceLeaky(Stats, arena, text, .{ .ignore_unknown_fields = true });
        try std.testing.expectEqual(case.rows, stats.rows);
        try std.testing.expectEqual(case.cols, stats.columns.len);
        try std.testing.expectEqual(case.rows, stats.sample.len);
    }

    // The CSV and the Parquet hold the same table and say so.
    const csv = try std.json.parseFromSliceLeaky(Stats, arena, try compute(arena, &db, try std.fmt.allocPrint(arena, "{s}/people.csv", .{dir}), .csv), .{ .ignore_unknown_fields = true });
    try std.testing.expectEqualStrings("score", csv.columns[3].name);
    try std.testing.expectEqualStrings("64.0", csv.columns[3].min.?);
    try std.testing.expectEqualStrings("91.5", csv.columns[3].max.?);
    try std.testing.expectEqual(@as(f64, 20.0), csv.columns[3].null_percent);

    // A file that is not the table it claims to be is a failed query,
    // never a crash: one bad file breaks only itself (invariant 18).
    try tmp.dir.writeFile(io, .{ .sub_path = "broken.parquet", .data = "not a parquet file at all" });
    const broken = try std.fmt.allocPrint(arena, "{s}/broken.parquet", .{dir});
    try std.testing.expectError(error.QueryFailed, compute(arena, &db, broken, .parquet));
}
