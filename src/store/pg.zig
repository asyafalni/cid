//! TimescaleDB access via libpq (the one allowed C database library).
//! Thin, explicit wrapper: no magic, no globals, errors carry the server's
//! words through `Diag` so callers can print them.

const std = @import("std");
pub const c = @import("libpq");

pub const Error = error{ ConnectFailed, QueryFailed };

/// Carries the last libpq error message across the error return.
pub const Diag = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,

    pub fn message(self: *const Diag) []const u8 {
        const m = std.mem.trimEnd(u8, self.buf[0..self.len], "\n");
        return if (m.len == 0) "no details from the database" else m;
    }

    fn set(self: *Diag, text: [*c]const u8) void {
        if (text == null) {
            self.len = 0;
            return;
        }
        const slice = std.mem.span(@as([*:0]const u8, @ptrCast(text)));
        self.len = @min(slice.len, self.buf.len);
        @memcpy(self.buf[0..self.len], slice[0..self.len]);
    }
};

pub const Db = struct {
    conn: *c.PGconn,

    pub fn connect(conninfo: [:0]const u8, diag: ?*Diag) Error!Db {
        const conn = c.PQconnectdb(conninfo.ptr) orelse return error.ConnectFailed;
        if (c.PQstatus(conn) != c.CONNECTION_OK) {
            if (diag) |d| d.set(c.PQerrorMessage(conn));
            c.PQfinish(conn);
            return error.ConnectFailed;
        }
        return .{ .conn = conn };
    }

    pub fn close(self: *Db) void {
        c.PQfinish(self.conn);
    }

    /// Run SQL and discard the result. Multiple statements are allowed and
    /// run in one implicit transaction (libpq semantics).
    pub fn exec(self: *Db, sql: [:0]const u8, diag: ?*Diag) Error!void {
        const res = c.PQexec(self.conn, sql.ptr) orelse return error.QueryFailed;
        defer c.PQclear(res);
        try self.checkResult(res, diag);
    }

    /// Run SQL with text parameters ($1, $2, …) and discard the result.
    pub fn execParams(
        self: *Db,
        sql: [:0]const u8,
        params: []const [:0]const u8,
        diag: ?*Diag,
    ) Error!void {
        var values: [8][*c]const u8 = undefined;
        std.debug.assert(params.len <= values.len);
        for (params, 0..) |p, i| values[i] = p.ptr;
        const res = c.PQexecParams(
            self.conn,
            sql.ptr,
            @intCast(params.len),
            null,
            &values,
            null,
            null,
            0,
        ) orelse return error.QueryFailed;
        defer c.PQclear(res);
        try self.checkResult(res, diag);
    }

    /// Run a query whose result is a single column of integers.
    pub fn queryInts(
        self: *Db,
        allocator: std.mem.Allocator,
        sql: [:0]const u8,
        diag: ?*Diag,
    ) (Error || std.mem.Allocator.Error)![]i64 {
        const res = c.PQexec(self.conn, sql.ptr) orelse return error.QueryFailed;
        defer c.PQclear(res);
        try self.checkResult(res, diag);
        const n: usize = @intCast(c.PQntuples(res));
        const out = try allocator.alloc(i64, n);
        errdefer allocator.free(out);
        for (out, 0..) |*slot, i| {
            const text = std.mem.span(@as([*:0]const u8, @ptrCast(c.PQgetvalue(res, @intCast(i), 0))));
            slot.* = std.fmt.parseInt(i64, text, 10) catch return error.QueryFailed;
        }
        return out;
    }

    /// Run a query with text parameters; the caller reads rows and calls
    /// `deinit`. Values borrow from the result until then.
    pub fn query(
        self: *Db,
        sql: [:0]const u8,
        params: []const [:0]const u8,
        diag: ?*Diag,
    ) Error!Rows {
        var values: [16][*c]const u8 = undefined;
        std.debug.assert(params.len <= values.len);
        for (params, 0..) |p, i| values[i] = p.ptr;
        const res = c.PQexecParams(
            self.conn,
            sql.ptr,
            @intCast(params.len),
            null,
            &values,
            null,
            null,
            0,
        ) orelse return error.QueryFailed;
        errdefer c.PQclear(res);
        try self.checkResult(res, diag);
        return .{ .res = res };
    }

    fn checkResult(self: *Db, res: *c.PGresult, diag: ?*Diag) Error!void {
        const status = c.PQresultStatus(res);
        if (status == c.PGRES_COMMAND_OK or status == c.PGRES_TUPLES_OK) return;
        if (diag) |d| d.set(c.PQerrorMessage(self.conn));
        return error.QueryFailed;
    }
};

pub const Rows = struct {
    res: *c.PGresult,

    pub fn deinit(self: *Rows) void {
        c.PQclear(self.res);
    }

    pub fn count(self: *const Rows) usize {
        return @intCast(c.PQntuples(self.res));
    }

    pub fn get(self: *const Rows, row: usize, col: usize) []const u8 {
        const v = c.PQgetvalue(self.res, @intCast(row), @intCast(col));
        return std.mem.span(@as([*:0]const u8, @ptrCast(v)));
    }

    pub fn isNull(self: *const Rows, row: usize, col: usize) bool {
        return c.PQgetisnull(self.res, @intCast(row), @intCast(col)) != 0;
    }
};

test "diag trims and survives empty messages" {
    var d: Diag = .{};
    try std.testing.expectEqualStrings("no details from the database", d.message());
    const text = "FATAL: nope\n";
    @memcpy(d.buf[0..text.len], text);
    d.len = text.len;
    try std.testing.expectEqualStrings("FATAL: nope", d.message());
}
