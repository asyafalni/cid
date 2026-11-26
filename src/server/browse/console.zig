//! The SQL console (docs/dashboard.md, 4.3): a SELECT someone writes, run
//! on the server over one version's browse index, as two views: `items`
//! and `annotations`. Sandboxed, non-negotiably:
//!
//!   - a fresh in-memory DuckDB per query, which may read exactly the
//!     version's two index files (`allowed_paths`) and write only in a
//!     scratch folder of its own; external access off and the
//!     configuration locked, so nothing in the query can loosen it;
//!   - exactly one statement, and that a SELECT, by DuckDB's own reading;
//!   - one thread, a memory ceiling, stopped after `timeout_ms`;
//!   - at most `max_rows` rows and about `max_bytes` back, said when cut.
//!
//! Restricted datasets get no console (the server refuses them). A
//! query's errors are its writer's to read: answered, never logged.

const std = @import("std");
const duck = @import("../../store/duck.zig");
const browse = @import("browse.zig");

pub const max_rows = 1000;
pub const max_bytes = 2 * 1024 * 1024;
pub const timeout_ms = 10_000;
pub const max_sql = 64 * 1024;

/// The result as JSON (`{columns: [{name, type}], rows: [{…}], truncated}`),
/// or why the query was not run or did not finish, in words.
pub const Answer = union(enum) { result: []const u8, refused: []const u8 };

pub fn run(arena: std.mem.Allocator, io: std.Io, scratch: []const u8, files: browse.Files, sql_in: []const u8) duck.Error!Answer {
    const sql = std.mem.trimEnd(u8, std.mem.trim(u8, sql_in, " \t\r\n"), "; \t\r\n");
    if (sql.len == 0) return .{ .refused = "write a SELECT, e.g. SELECT split, count(*) FROM items GROUP BY split" };
    if (sql.len > max_sql) return .{ .refused = "the query is longer than 64 KB" };

    var db = try duck.Db.open(arena, .{
        .allowed_dir = scratch,
        .allowed_paths = &.{ files.items, files.anns },
        .threads = 1,
        .memory_limit = "256MB",
    });
    defer db.close();
    const views = try std.fmt.allocPrint(arena,
        \\CREATE VIEW items AS SELECT path, hash, size, split, ext AS type, item_id, ann_count AS annotations,
        \\  class_set AS classes, attr_set AS attributes, ident_set AS identities, author_set AS authors, policy_set AS policies, num_set AS numbers
        \\  FROM read_parquet({s});
        \\CREATE VIEW annotations AS SELECT id, item_id, kind, class, geometry, attrs AS attributes, author, policy_ver
        \\  FROM read_parquet({s});
    , .{ try literal(arena, files.items), try literal(arena, files.anns) });
    switch (try db.scalarTextQuiet(arena, views)) {
        .text => {},
        .failed => return error.QueryFailed, // the index itself is unreadable: the server's fault
    }

    switch (try db.checkSelect(arena, sql)) {
        .select => {},
        .not_select => return .{ .refused = "only a single SELECT runs here: the console reads, it never changes anything" },
        .invalid => |why| return .{ .refused = why },
    }

    // Stopped after the time limit, by another thread.
    var watch: Watch = .{ .db = &db, .io = io };
    const thread = std.Thread.spawn(.{}, Watch.run, .{&watch}) catch null;
    defer if (thread) |t| {
        watch.done.store(true, .release);
        t.join();
    };

    const columns_sql = try std.fmt.allocPrint(arena, "SELECT json_group_array(json_object('name', column_name, 'type', column_type)) FROM (DESCRIBE SELECT * FROM ({s}) q)", .{sql});
    const columns = switch (try db.scalarTextQuiet(arena, columns_sql)) {
        .text => |t| t orelse "[]",
        .failed => |why| return .{ .refused = if (watch.fired.load(.acquire)) timeout_words else why },
    };
    const rows_sql = try std.fmt.allocPrint(arena, "SELECT to_json(coalesce(list(q), [])) FROM (SELECT * FROM ({s}) q LIMIT {d}) q", .{ sql, max_rows + 1 });
    var rows = switch (try db.scalarTextQuiet(arena, rows_sql)) {
        .text => |t| t orelse "[]",
        .failed => |why| return .{ .refused = if (watch.fired.load(.acquire)) timeout_words else why },
    };
    const Row = std.json.Value;
    var list = std.json.parseFromSliceLeaky([]Row, arena, rows, .{}) catch return error.QueryFailed;
    var truncated = false;
    if (list.len > max_rows) {
        list = list[0..max_rows];
        truncated = true;
    }
    // Rows past the byte budget are left off too, a page never so heavy
    // that the browser chokes on it.
    var size: usize = 0;
    var keep: usize = 0;
    for (list) |row| {
        size += (try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(row, .{})})).len;
        if (size > max_bytes) {
            truncated = true;
            break;
        }
        keep += 1;
    }
    rows = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(list[0..keep], .{})});
    return .{ .result = try std.fmt.allocPrint(arena, "{{\"columns\":{s},\"rows\":{s},\"truncated\":{}}}", .{ columns, rows, truncated }) };
}

const timeout_words = "the query ran longer than 10 seconds and was stopped; narrow it (a WHERE, a LIMIT) and run it again";

const Watch = struct {
    db: *duck.Db,
    io: std.Io,
    done: std.atomic.Value(bool) = .init(false),
    fired: std.atomic.Value(bool) = .init(false),

    fn run(self: *Watch) void {
        var waited: u32 = 0;
        while (waited < timeout_ms) : (waited += 50) {
            if (self.done.load(.acquire)) return;
            std.Io.sleep(self.io, .fromNanoseconds(50 * std.time.ns_per_ms), .awake) catch return;
        }
        if (self.done.load(.acquire)) return;
        self.fired.store(true, .release);
        self.db.interrupt();
    }
};

fn literal(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '\'');
    for (text) |ch| {
        if (ch == '\'') try out.append(arena, '\'');
        try out.append(arena, ch);
    }
    try out.append(arena, '\'');
    return out.items;
}

test "a SELECT over the version's items and annotations, and nothing else" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", arena);
    var conv = try duck.Db.open(arena, .{ .allowed_dir = dir });
    defer conv.close();
    const files = try browse.Files.of(arena, dir, "v1");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = files.items_lines, .data =
        \\{"path":"img/a.png","hash":"aa","size":1,"split":"train","item_id":"i1","ext":".png","classes":["car","car"],"attrs":["occluded=true"],"idents":[]}
        \\{"path":"img/b.png","hash":"bb","size":2,"split":"val","item_id":"i2","ext":".png","classes":[],"attrs":[],"idents":[]}
        \\
    });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = files.ann_lines, .data =
        \\{"id":"x1","item_id":"i1","kind":"box","class":"car","geometry":{"x":1,"y":2,"w":3,"h":4},"attrs":null,"author":"agent","policy_ver":"p1"}
        \\{"id":"x2","item_id":"i1","kind":"box","class":"car","geometry":{"x":0,"y":0,"w":1,"h":1},"attrs":null,"author":"user:r","policy_ver":"p1"}
        \\
    });
    try browse.convertIndex(arena, io, &conv, files);
    // Another version's index beside it: out of reach.
    const other = try browse.Files.of(arena, dir, "v2");
    try std.Io.Dir.cwd().copyFile(files.items, std.Io.Dir.cwd(), other.items, io, .{});
    try tmp.dir.createDirPath(io, "scratch");
    const scratch = try std.fmt.allocPrint(arena, "{s}/scratch", .{dir});

    const Result = struct { columns: []const struct { name: []const u8, type: []const u8 }, rows: []const std.json.Value, truncated: bool };
    const got = try run(arena, io, scratch, files, "SELECT split, count(*) AS n FROM items GROUP BY split ORDER BY split;");
    const r = try std.json.parseFromSliceLeaky(Result, arena, got.result, .{});
    try std.testing.expectEqualStrings("split", r.columns[0].name);
    try std.testing.expectEqual(@as(usize, 2), r.rows.len);
    try std.testing.expectEqualStrings("train", r.rows[0].object.get("split").?.string);
    try std.testing.expect(!r.truncated);
    const joined = try run(arena, io, scratch, files, "SELECT i.path, count(*) AS boxes FROM annotations a JOIN items i USING (item_id) GROUP BY 1");
    try std.testing.expect(std.mem.indexOf(u8, joined.result, "\"boxes\":2") != null);

    // Nothing but a SELECT, nothing but this version, errors in words.
    try std.testing.expect(std.mem.startsWith(u8, (try run(arena, io, scratch, files, "DROP VIEW items")).refused, "only a single SELECT"));
    try std.testing.expect((try run(arena, io, scratch, files, try std.fmt.allocPrint(arena, "SELECT count(*) FROM read_parquet('{s}')", .{other.items}))) == .refused);
    try std.testing.expect((try run(arena, io, scratch, files, "SELECT * FROM read_csv('/etc/passwd')")) == .refused);
    try std.testing.expect((try run(arena, io, scratch, files, "SELECT nope FROM items")) == .refused);
    try std.testing.expect((try run(arena, io, scratch, files, "")) == .refused);
    // More rows than a page: cut, and said.
    const many = try run(arena, io, scratch, files, "SELECT * FROM range(5000)");
    try std.testing.expect(std.mem.endsWith(u8, many.result, "\"truncated\":true}"));
}
