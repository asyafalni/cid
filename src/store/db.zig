//! TimescaleDB access via nilo_sql (pg.zig underneath: native wire
//! protocol, a connection pool, no C). This is replacing the libpq
//! wrapper in pg.zig module by module; when the last caller moves,
//! pg.zig and the libpq dependency go with it.
//!
//! One shape to know: a query takes a Scope — the request's `*nilo.Ctx`
//! inside the server, a `nilo.Run` anywhere else. The pool is opened by
//! `listen()` in the server; a program that never listens (admin
//! commands, the preview worker) opens it with `Standalone`.

const std = @import("std");
pub const sql = @import("nilo_sql");
pub const Run = @import("nilo_http").Run;

/// CID_DB accepts both spellings: a `postgres://` URL (what nilo_sql
/// takes) and libpq's `key=value` form (what cid accepted first). This
/// renders either as a URL, allocated in `arena`.
pub fn urlFrom(arena: std.mem.Allocator, spec: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, spec, " \t\n");
    if (std.mem.startsWith(u8, trimmed, "postgres://") or
        std.mem.startsWith(u8, trimmed, "postgresql://"))
        return arena.dupe(u8, trimmed);

    var host: []const u8 = "127.0.0.1";
    var port: []const u8 = "5432";
    var user: []const u8 = "postgres";
    var password: []const u8 = "";
    var dbname: []const u8 = "postgres";
    var it = std.mem.tokenizeAny(u8, trimmed, " \t\n");
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = pair[0..eq];
        const value = pair[eq + 1 ..];
        if (std.mem.eql(u8, key, "host")) host = value;
        if (std.mem.eql(u8, key, "port")) port = value;
        if (std.mem.eql(u8, key, "user")) user = value;
        if (std.mem.eql(u8, key, "password")) password = value;
        if (std.mem.eql(u8, key, "dbname")) dbname = value;
    }
    if (password.len == 0)
        return std.fmt.allocPrint(arena, "postgres://{s}@{s}:{s}/{s}", .{ user, host, port, dbname });
    return std.fmt.allocPrint(arena, "postgres://{s}:{s}@{s}:{s}/{s}", .{
        user, password, host, port, dbname,
    });
}

/// A pool for a program that never calls `listen()`: `cid admin setup`,
/// `migrate`, `verify`, `gc`, the preview worker. Holds everything whose
/// lifetime the Db borrows (the URL, the Io). Under `std.Io.Threaded`
/// the whole pool must dial at start (`connect_on_init = size`): pg.zig's
/// lazy reconnector parks on a sync primitive Threaded cannot serve.
pub const Standalone = struct {
    gpa: std.mem.Allocator,
    url: []const u8,
    threaded: std.Io.Threaded,
    db: sql.Db,

    pub fn open(self: *Standalone, gpa: std.mem.Allocator, spec: []const u8) !void {
        self.gpa = gpa;
        self.url = try urlFrom(gpa, spec);
        errdefer gpa.free(self.url);
        self.threaded = .init(gpa, .{});
        errdefer self.threaded.deinit();
        self.db = sql.Db.init(gpa, self.url, .{
            .size = 2,
            .connect_on_init = 2,
            .unchecked = true,
        });
        errdefer self.db.deinit();
        try self.db.nilo_start(self.threaded.io(), .none);
    }

    pub fn close(self: *Standalone) void {
        self.db.deinit();
        self.threaded.deinit();
        self.gpa.free(self.url);
    }
};

test "urlFrom passes URLs through and renders libpq key=value pairs" {
    const a = std.testing.allocator;
    const passthrough = try urlFrom(a, "postgres://cid:pw@db:5433/cid_test");
    defer a.free(passthrough);
    try std.testing.expectEqualStrings("postgres://cid:pw@db:5433/cid_test", passthrough);

    const rendered = try urlFrom(a, "host=127.0.0.1 port=5433 user=cid password=cid-test dbname=cid_test");
    defer a.free(rendered);
    try std.testing.expectEqualStrings("postgres://cid:cid-test@127.0.0.1:5433/cid_test", rendered);

    const no_pw = try urlFrom(a, "host=db user=cid dbname=cid");
    defer a.free(no_pw);
    try std.testing.expectEqualStrings("postgres://cid@db:5432/cid", no_pw);
}
