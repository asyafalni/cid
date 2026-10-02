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
        const memory = arena.dupeZ(u8, limits.memory_limit) catch return error.OutOfMemory;
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
        const confine = std.fmt.allocPrintSentinel(arena, "SET allowed_directories = ['{0s}/']; SET temp_directory = '{0s}/.duckdb-spill'; " ++
            "SET enable_external_access = false; SET lock_configuration = true;", .{quoted.items}, 0) catch return error.OutOfMemory;
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
        const sql_z = arena.dupeZ(u8, sql) catch return error.OutOfMemory;
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
        const sql_z = arena.dupeZ(u8, sql) catch return error.OutOfMemory;
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
