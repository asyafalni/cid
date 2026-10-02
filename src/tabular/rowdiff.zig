//! Row-level diff of two versions of a table file (CLAUDE.md, Formats):
//! rows added and removed, by whole-row comparison, with multiplicity — a
//! row that appears twice where it appeared once is one row added. A row
//! edited in place shows as one removed and one added: telling an edit
//! from a delete-and-insert needs a key column, which a dataset cannot
//! declare yet. When the columns themselves changed, rows are not
//! compared (they cannot line up) and the column change is the answer.
//!
//! One DuckDB query per question, answered as JSON; nothing here parses a
//! table. Runs on the server only, in the server build.

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
) duck.Error![]const u8 {
    const src_a = try stats.sourceOf(arena, a, a_kind);
    const src_b = try stats.sourceOf(arena, b, b_kind);

    const shape = (try db.scalarText(arena, try std.fmt.allocPrint(arena,
        \\WITH ca AS (SELECT list(column_name || ' ' || column_type) c FROM (DESCRIBE SELECT * FROM {s})),
        \\     cb AS (SELECT list(column_name || ' ' || column_type) c FROM (DESCRIBE SELECT * FROM {s}))
        \\SELECT json_object('columns_a', (SELECT c FROM ca), 'columns_b', (SELECT c FROM cb),
        \\  'same', (SELECT c FROM ca) = (SELECT c FROM cb),
        \\  'rows_a', (SELECT count(*) FROM {s}), 'rows_b', (SELECT count(*) FROM {s}))::VARCHAR
    , .{ src_a, src_b, src_a, src_b }))) orelse return error.QueryFailed;

    const Shape = struct { columns_a: []const []const u8, columns_b: []const []const u8, same: bool, rows_a: u64, rows_b: u64 };
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
        .rows_a = s.rows_a,
        .rows_b = s.rows_b,
        .columns_a = s.columns_a,
        .columns_b = s.columns_b,
        .columns_changed = false,
        .added = r.added,
        .removed = r.removed,
        .added_sample = r.added_sample,
        .removed_sample = r.removed_sample,
    }, .{})}) catch error.OutOfMemory;
}

test "rows added and removed, duplicates counted, edits as a pair, across formats" {
    if (comptime !duck.enabled) return error.SkipZigTest;
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
        const text = try compute(arena, &db, try path(arena, dir, before.file), before.kind, try path(arena, dir, "b.csv"), .csv);
        const d = try std.json.parseFromSliceLeaky(Diff, arena, text, .{ .ignore_unknown_fields = true });
        try std.testing.expect(!d.columns_changed);
        try std.testing.expectEqual(@as(u64, 5), d.rows_a);
        try std.testing.expectEqual(@as(u64, 6), d.rows_b);
        try std.testing.expectEqual(@as(u64, 3), d.added); // Citra (edited), Fajar ×2
        try std.testing.expectEqual(@as(u64, 2), d.removed); // Budi, Citra (old)
    }

    // A column added: rows are not compared, the column change is the answer.
    try tmp.dir.writeFile(io, .{ .sub_path = "c.csv", .data = "id,name,city,score,team\n1,Ana Wijaya,Bandung,91.5,red\n" });
    const wider = try std.json.parseFromSliceLeaky(struct { columns_changed: bool, columns_b: []const []const u8 }, arena, try compute(arena, &db, try path(arena, dir, "a.csv"), .csv, try path(arena, dir, "c.csv"), .csv), .{ .ignore_unknown_fields = true });
    try std.testing.expect(wider.columns_changed);
    try std.testing.expectEqualStrings("team VARCHAR", wider.columns_b[4]);
}
