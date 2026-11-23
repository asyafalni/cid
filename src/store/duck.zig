//! DuckDB, in-process (CLAUDE.md, DuckDB): always linked.
//!
//! Each `Db` is an in-memory database held to the same discipline the
//! preview worker holds ffmpeg to: one thread, a memory ceiling, no
//! extension downloads, and file access confined to one directory, with
//! the configuration locked so a query cannot loosen any of it.

const std = @import("std");
const c = @import("duckdb_c");

pub const Error = error{ OpenFailed, QueryFailed, OutOfMemory };

pub const Limits = struct {
    /// The one directory queries may read and write files in.
    allowed_dir: []const u8,
    /// Files, besides, that queries may read: exactly these (the SQL
    /// console's two index files).
    allowed_paths: []const []const u8 = &.{},
    memory_limit: []const u8 = "256MB",
    threads: u8 = 1,
};

/// A database and one connection to it. A server opens one and hands each
/// request a connection of its own (`connect`): one memory ceiling and one
/// thread count then cover every query at once, however many run.
pub const Db = struct {
    db: c.duckdb_database,
    conn: c.duckdb_connection,
    /// Whether closing this also closes the database (false for `connect`'s).
    owns_db: bool = true,

    pub fn open(arena: std.mem.Allocator, limits: Limits) Error!Db {
        var config: c.duckdb_config = null;
        if (c.duckdb_create_config(&config) != c.DuckDBSuccess) return error.OpenFailed;
        defer c.duckdb_destroy_config(&config);

        const threads = std.fmt.allocPrintSentinel(arena, "{d}", .{limits.threads}, 0) catch return error.OutOfMemory;
        const memory = arena.dupeSentinel(u8, limits.memory_limit, 0) catch return error.OutOfMemory;
        const settings = [_][2][*:0]const u8{
            .{ "threads", threads },
            .{ "memory_limit", memory },
            .{ "autoinstall_known_extensions", "false" },
            .{ "autoload_known_extensions", "false" },
        };
        for (settings) |kv| {
            if (c.duckdb_set_config(config, kv[0], kv[1]) != c.DuckDBSuccess) {
                std.log.warn("duckdb: setting {s} was refused", .{kv[0]});
                return error.OpenFailed;
            }
        }

        var self: Db = undefined;
        var why: [*c]u8 = null;
        if (c.duckdb_open_ext(null, &self.db, config, &why) != c.DuckDBSuccess) {
            if (why) |w| {
                std.log.warn("duckdb: open failed: {s}", .{std.mem.span(w)});
                c.duckdb_free(w);
            }
            return error.OpenFailed;
        }
        errdefer c.duckdb_close(&self.db);
        if (c.duckdb_connect(self.db, &self.conn) != c.DuckDBSuccess) return error.OpenFailed;
        // Files only from the one directory, then nothing a query sends can
        // undo any of it. A list setting, so SQL rather than the config API.
        var quoted: std.ArrayList(u8) = .empty;
        for (std.mem.trimEnd(u8, limits.allowed_dir, "/")) |ch| {
            if (ch == '\'') quoted.append(arena, '\'') catch return error.OutOfMemory;
            quoted.append(arena, ch) catch return error.OutOfMemory;
        }
        // A join larger than the memory ceiling spills here, inside the
        // folder, rather than failing.
        var paths: std.ArrayList(u8) = .empty;
        if (limits.allowed_paths.len > 0) {
            paths.appendSlice(arena, "SET allowed_paths = [") catch return error.OutOfMemory;
            for (limits.allowed_paths, 0..) |path, i| {
                if (i > 0) paths.append(arena, ',') catch return error.OutOfMemory;
                paths.append(arena, '\'') catch return error.OutOfMemory;
                for (path) |ch| {
                    if (ch == '\'') paths.append(arena, '\'') catch return error.OutOfMemory;
                    paths.append(arena, ch) catch return error.OutOfMemory;
                }
                paths.append(arena, '\'') catch return error.OutOfMemory;
            }
            paths.appendSlice(arena, "]; ") catch return error.OutOfMemory;
        }
        const confine = std.fmt.allocPrintSentinel(arena, "SET allowed_directories = ['{0s}/']; {1s}SET temp_directory = '{0s}/.duckdb-spill'; " ++
            "SET enable_external_access = false; SET lock_configuration = true;", .{ quoted.items, paths.items }, 0) catch return error.OutOfMemory;
        var locked: c.duckdb_result = undefined;
        defer c.duckdb_destroy_result(&locked);
        if (c.duckdb_query(self.conn, confine, &locked) != c.DuckDBSuccess) {
            const refused = c.duckdb_result_error(&locked);
            std.log.warn("duckdb: confining failed: {s}", .{if (refused != null) std.mem.span(refused) else "?"});
            c.duckdb_disconnect(&self.conn);
            return error.OpenFailed;
        }
        return self;
    }

    /// Another connection to this database, under its confinement and
    /// limits; closing it leaves the database open.
    pub fn connect(self: *Db) Error!Db {
        var other: Db = .{ .db = self.db, .conn = undefined, .owns_db = false };
        if (c.duckdb_connect(self.db, &other.conn) != c.DuckDBSuccess) return error.OpenFailed;
        return other;
    }

    pub fn close(self: *Db) void {
        c.duckdb_disconnect(&self.conn);
        if (self.owns_db) c.duckdb_close(&self.db);
    }

    /// The first column of the first row, as text in `arena`; null when the
    /// query answered no rows or a SQL NULL. A failed query logs DuckDB's
    /// own words (never the data) and answers QueryFailed.
    pub fn scalarText(self: *Db, arena: std.mem.Allocator, sql: []const u8) Error!?[]const u8 {
        const sql_z = arena.dupeSentinel(u8, sql, 0) catch return error.OutOfMemory;
        var result: c.duckdb_result = undefined;
        defer c.duckdb_destroy_result(&result);
        if (c.duckdb_query(self.conn, sql_z, &result) != c.DuckDBSuccess) {
            const why = c.duckdb_result_error(&result);
            std.log.warn("duckdb: {s}", .{if (why != null) std.mem.span(why) else "query failed"});
            return error.QueryFailed;
        }
        return firstText(arena, &result);
    }

    /// A value bound to a prepared query's `$n`: text (or NULL) and
    /// integers. Whatever a request carries reaches DuckDB this way, never
    /// spliced into the SQL.
    pub const Arg = union(enum) { text: ?[]const u8, int: i64 };

    /// scalarText for a query with `$1…$n` bound to `args`, in order.
    pub fn scalarTextArgs(self: *Db, arena: std.mem.Allocator, sql: []const u8, args: []const Arg) Error!?[]const u8 {
        const sql_z = arena.dupeSentinel(u8, sql, 0) catch return error.OutOfMemory;
        var stmt: c.duckdb_prepared_statement = null;
        defer c.duckdb_destroy_prepare(&stmt);
        if (c.duckdb_prepare(self.conn, sql_z, &stmt) != c.DuckDBSuccess) {
            const why = c.duckdb_prepare_error(stmt);
            std.log.warn("duckdb: {s}", .{if (why != null) std.mem.span(why) else "prepare failed"});
            return error.QueryFailed;
        }
        for (args, 1..) |arg, i| {
            const bound = switch (arg) {
                .text => |t| if (t) |v|
                    c.duckdb_bind_varchar_length(stmt, i, v.ptr, v.len)
                else
                    c.duckdb_bind_null(stmt, i),
                .int => |n| c.duckdb_bind_int64(stmt, i, n),
            };
            if (bound != c.DuckDBSuccess) return error.QueryFailed;
        }
        var result: c.duckdb_result = undefined;
        defer c.duckdb_destroy_result(&result);
        if (c.duckdb_execute_prepared(stmt, &result) != c.DuckDBSuccess) {
            const why = c.duckdb_result_error(&result);
            std.log.warn("duckdb: {s}", .{if (why != null) std.mem.span(why) else "query failed"});
            return error.QueryFailed;
        }
        return firstText(arena, &result);
    }

    /// Stops the query running on this connection, from another thread.
    pub fn interrupt(self: *Db) void {
        c.duckdb_interrupt(self.conn);
    }

    /// A query someone wrote, checked before it runs: exactly one
    /// statement, and that a SELECT (a WITH … SELECT is one), by DuckDB's
    /// own reading of it, never by matching text. Its error, if any, is
    /// theirs to read, so it is answered, not logged.
    pub const Checked = union(enum) { select, not_select, invalid: []const u8 };

    pub fn checkSelect(self: *Db, arena: std.mem.Allocator, sql: []const u8) Error!Checked {
        // Parsed first, never bound: DuckDB serializes only SELECTs, so a
        // DELETE on a view is "not a SELECT", not a binder's complaint, and
        // two statements are two.
        const parsed = (try self.scalarTextArgs(arena, "SELECT json_serialize_sql($1::VARCHAR)", &.{.{ .text = sql }})) orelse return error.QueryFailed;
        const Tree = struct { @"error": bool = false, error_message: []const u8 = "", statements: []const std.json.Value = &.{} };
        const tree = std.json.parseFromSliceLeaky(Tree, arena, parsed, .{ .ignore_unknown_fields = true }) catch return error.QueryFailed;
        if (tree.@"error") return if (std.mem.indexOf(u8, tree.error_message, "Only SELECT") != null)
            .not_select
        else
            .{ .invalid = tree.error_message };
        if (tree.statements.len != 1) return .not_select;
        const sql_z = arena.dupeSentinel(u8, sql, 0) catch return error.OutOfMemory;
        var stmt: c.duckdb_prepared_statement = null;
        defer c.duckdb_destroy_prepare(&stmt);
        if (c.duckdb_prepare(self.conn, sql_z, &stmt) != c.DuckDBSuccess) {
            const why = c.duckdb_prepare_error(stmt);
            return .{ .invalid = arena.dupe(u8, if (why != null) std.mem.span(why) else "the query could not be read") catch return error.OutOfMemory };
        }
        return if (c.duckdb_prepared_statement_type(stmt) == c.DUCKDB_STATEMENT_TYPE_SELECT) .select else .not_select;
    }

    /// scalarText for a query someone wrote: its error answered, not logged.
    pub const Quiet = union(enum) { text: ?[]const u8, failed: []const u8 };

    pub fn scalarTextQuiet(self: *Db, arena: std.mem.Allocator, sql: []const u8) Error!Quiet {
        const sql_z = arena.dupeSentinel(u8, sql, 0) catch return error.OutOfMemory;
        var result: c.duckdb_result = undefined;
        defer c.duckdb_destroy_result(&result);
        if (c.duckdb_query(self.conn, sql_z, &result) != c.DuckDBSuccess) {
            const why = c.duckdb_result_error(&result);
            return .{ .failed = arena.dupe(u8, if (why != null) std.mem.span(why) else "the query failed") catch return error.OutOfMemory };
        }
        return .{ .text = try firstText(arena, &result) };
    }

    fn firstText(arena: std.mem.Allocator, result: *c.duckdb_result) Error!?[]const u8 {
        if (c.duckdb_row_count(result) == 0 or c.duckdb_column_count(result) == 0) return null;
        if (c.duckdb_value_is_null(result, 0, 0)) return null;
        const text = c.duckdb_value_varchar(result, 0, 0) orelse return null;
        defer c.duckdb_free(text);
        return arena.dupe(u8, std.mem.span(text)) catch error.OutOfMemory;
    }
};

test "a query runs under its limits, confined and locked" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try Db.open(arena, .{ .allowed_dir = "/nonexistent-cid-dir" });
    defer db.close();
    try std.testing.expectEqualStrings("42", (try db.scalarText(arena, "SELECT 40 + 2")).?);
    // Locked: a query cannot widen what it may read.
    try std.testing.expectError(error.QueryFailed, db.scalarText(arena, "SET enable_external_access = true"));
    // And outside the allowed directory, nothing is readable.
    try std.testing.expectError(error.QueryFailed, db.scalarText(arena, "SELECT count(*) FROM read_csv('/etc/passwd')"));
    // A second connection shares the database and its locked confinement.
    var other = try db.connect();
    defer other.close();
    try std.testing.expectEqualStrings("42", (try other.scalarText(arena, "SELECT 40 + 2")).?);
    try std.testing.expectError(error.QueryFailed, other.scalarText(arena, "SELECT count(*) FROM read_csv('/etc/passwd')"));
    // Bound values stay values: a quote is just a character.
    const echoed = try db.scalarTextArgs(arena, "SELECT $1::VARCHAR || '/' || ($2 + 1)::VARCHAR || '/' || coalesce($3::VARCHAR, 'null')", &.{ .{ .text = "it's'; DROP" }, .{ .int = 41 }, .{ .text = null } });
    try std.testing.expectEqualStrings("it's'; DROP/42/null", echoed.?);
}

test "a database that may read exactly two files, and only a SELECT" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", arena);
    try tmp.dir.writeFile(io, .{ .sub_path = "mine.csv", .data = "a\n1\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "other.csv", .data = "a\n2\n" });
    try tmp.dir.createDirPath(io, "scratch");
    const mine = try std.fmt.allocPrint(arena, "{s}/mine.csv", .{dir});
    var db = try Db.open(arena, .{ .allowed_dir = try std.fmt.allocPrint(arena, "{s}/scratch", .{dir}), .allowed_paths = &.{mine} });
    defer db.close();
    const got = try db.scalarTextQuiet(arena, try std.fmt.allocPrint(arena, "SELECT a FROM read_csv('{s}')", .{mine}));
    try std.testing.expectEqualStrings("1", got.text.?);
    // Its neighbour in the same folder is out of reach, and said so.
    const other = try db.scalarTextQuiet(arena, try std.fmt.allocPrint(arena, "SELECT a FROM read_csv('{s}/other.csv')", .{dir}));
    try std.testing.expect(other == .failed);
    try std.testing.expect(try db.checkSelect(arena, "WITH x AS (SELECT 1) SELECT * FROM x") == .select);
    try std.testing.expect(try db.checkSelect(arena, "CREATE TABLE t (a int)") == .not_select);
    try std.testing.expect(try db.checkSelect(arena, "COPY (SELECT 1) TO 'x.csv'") != .select);
    try std.testing.expect(try db.checkSelect(arena, "SELECT 1; SELECT 2") != .select);
    try std.testing.expect(try db.checkSelect(arena, "SELEC 1") == .invalid);
}
