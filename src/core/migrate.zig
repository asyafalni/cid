//! The migration runner behind `cid admin setup` and `cid admin migrate`.
//! Migrations are embedded at build time (the `migrations` module is
//! generated from sql/migrations/ by build.zig), applied in order, each in
//! its own transaction together with its bookkeeping row.

const std = @import("std");
const pg = @import("../store/pg.zig");
const migrations = @import("migrations");

/// One process migrates at a time ('cid' advisory lock, arbitrary fixed id).
const lock_sql = "SELECT pg_advisory_lock(7193546127)";
const unlock_sql = "SELECT pg_advisory_unlock(7193546127)";

pub const Summary = struct {
    applied: u32,
    total: u32,
};

pub const Error = pg.Error || std.mem.Allocator.Error || std.Io.Writer.Error;

/// Applies every migration not yet recorded in schema_migrations.
/// Prints one "Applied NNNN_name." line per migration to `out`.
pub fn run(
    arena: std.mem.Allocator,
    db: *pg.Db,
    out: *std.Io.Writer,
    diag: ?*pg.Diag,
) Error!Summary {
    try db.exec(lock_sql, diag);
    defer db.exec(unlock_sql, null) catch {};

    const applied = try appliedVersions(arena, db, diag);
    var summary: Summary = .{ .applied = 0, .total = migrations.all.len };

    inline for (migrations.all) |m| {
        if (!contains(applied, m.version)) {
            try db.exec("BEGIN", diag);
            errdefer db.exec("ROLLBACK", null) catch {};
            try db.exec(m.sql, diag);
            var version_buf: [16]u8 = undefined;
            const version_text = std.fmt.bufPrintSentinel(&version_buf, "{d}", .{m.version}, 0) catch unreachable;
            try db.execParams(
                "INSERT INTO schema_migrations (version, name) VALUES ($1, $2)",
                &.{ version_text, m.name },
                diag,
            );
            try db.exec("COMMIT", diag);
            try out.print("Applied {s}.\n", .{m.name});
            summary.applied += 1;
        }
    }
    return summary;
}

fn appliedVersions(arena: std.mem.Allocator, db: *pg.Db, diag: ?*pg.Diag) Error![]i64 {
    const exists = try db.queryInts(
        arena,
        "SELECT count(*) FROM pg_tables WHERE schemaname = 'public' AND tablename = 'schema_migrations'",
        diag,
    );
    if (exists[0] == 0) return &.{};
    return db.queryInts(arena, "SELECT version FROM schema_migrations ORDER BY version", diag);
}

fn contains(haystack: []const i64, version: u32) bool {
    for (haystack) |v| {
        if (v == version) return true;
    }
    return false;
}

test "embedded migrations are ordered, unique and well-named" {
    var prev: u32 = 0;
    inline for (migrations.all) |m| {
        try std.testing.expect(m.version > prev);
        prev = m.version;
        try std.testing.expect(m.name.len > 5);
        try std.testing.expect(m.sql.len > 0);
        // NNNN_ prefix matches the version
        const prefix = try std.fmt.parseInt(u32, m.name[0..4], 10);
        try std.testing.expectEqual(m.version, prefix);
        try std.testing.expectEqual(@as(u8, '_'), m.name[4]);
    }
    try std.testing.expect(migrations.all.len >= 1);
}
