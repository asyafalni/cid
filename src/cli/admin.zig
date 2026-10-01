//! `cid admin …`: server administration. Hidden from plain `cid help` (rule 6).

const std = @import("std");
const root = @import("../cid.zig");
const pg = @import("../store/pg.zig");
const migrate = @import("../core/migrate.zig");

const ExitCode = root.ExitCode;

const admin_help =
    \\usage: cid admin <command>
    \\
    \\Server administration:
    \\
    \\  setup      create the database schema (applies all migrations)
    \\  migrate    apply new SQL migrations
    \\
    \\Both read the server database from the CID_DB environment variable.
    \\
;

const conninfo_example =
    "export CID_DB='host=127.0.0.1 port=5433 user=cid password=cid-test dbname=cid_test'";

pub fn run(
    arena: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    env: *const std.process.Environ.Map,
    args: []const [:0]const u8,
) ExitCode {
    if (args.len == 0) {
        out.writeAll(admin_help) catch return .network;
        return .ok;
    }
    const sub = args[0];
    if (eql(sub, "setup") or eql(sub, "migrate")) {
        return runMigrate(arena, io, out, env, sub);
    }
    return fail(io, .usage, "'cid admin {s}' is not an admin command. Run 'cid admin'.", .{sub});
}

fn runMigrate(
    arena: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    env: *const std.process.Environ.Map,
    sub: []const u8,
) ExitCode {
    const conninfo_raw = env.get("CID_DB") orelse {
        return fail(io, .usage, "CID_DB is not set.\nSet it to the server database connection, e.g.\n  {s}\nThen run 'cid admin {s}' again.", .{ conninfo_example, sub });
    };
    const conninfo = arena.dupeZ(u8, conninfo_raw) catch return .network;

    var diag: pg.Diag = .{};
    var db = pg.Db.connect(conninfo, &diag) catch {
        return fail(io, .network, "cannot connect to the database: {s}\nCheck the database is running and CID_DB is right, then run 'cid admin {s}' again.", .{ diag.message(), sub });
    };
    defer db.close();

    const summary = migrate.run(arena, &db, out, &diag) catch {
        return fail(io, .network, "migration failed: {s}\nFix the cause, then run 'cid admin {s}' again; the failed migration was rolled back.", .{ diag.message(), sub });
    };
    if (summary.applied == 0) {
        out.print("Nothing to apply. Database is up to date ({d} migration{s}).\n", .{ summary.total, plural(summary.total) }) catch return .network;
    } else {
        out.print("Database is up to date ({d} applied, {d} total).\n", .{ summary.applied, summary.total }) catch return .network;
    }
    out.flush() catch return .network;
    return .ok;
}

/// Every error ends with the command to run next (already in the formats above).
fn fail(io: std.Io, code: ExitCode, comptime fmt: []const u8, fmt_args: anytype) ExitCode {
    var buf: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &buf);
    const err = &stderr_writer.interface;
    err.print("cid: " ++ fmt ++ "\n", fmt_args) catch {};
    err.flush() catch {};
    return code;
}

fn plural(n: anytype) []const u8 {
    return if (n == 1) "" else "s";
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test "admin help names its commands and the env variable" {
    try std.testing.expect(std.mem.indexOf(u8, admin_help, "setup") != null);
    try std.testing.expect(std.mem.indexOf(u8, admin_help, "migrate") != null);
    try std.testing.expect(std.mem.indexOf(u8, admin_help, "CID_DB") != null);
}
