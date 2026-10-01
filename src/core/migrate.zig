//! The migration runner behind `cid admin setup` and `cid admin migrate`.
//! Migrations are embedded at build time (the `migrations` module is
//! generated from sql/migrations/ by build.zig), applied in order, each in
//! its own transaction together with its bookkeeping row.

const std = @import("std");
const dbx = @import("../store/db.zig");
const migrations = @import("migrations");

pub const Summary = struct {
    applied: u32,
    total: u32,
};

/// Applies every migration not yet recorded in schema_migrations.
/// Prints one "Applied NNNN_name." line per migration to `out`.
/// `scope` is a `*nilo.Run` (admin commands have no request).
///
/// Concurrent migrators are serialized inside each migration's own
/// transaction: a transaction-level advisory lock (session locks cannot
/// span a pool's connections), then a re-check that the version is still
/// unapplied before running it.
pub fn run(
    db: *dbx.sql.Db,
    scope: anytype,
    out: *std.Io.Writer,
) !Summary {
    const applied = try appliedVersions(db, scope);
    var summary: Summary = .{ .applied = 0, .total = migrations.all.len };

    inline for (migrations.all) |m| {
        if (!contains(applied, m.version)) {
            var tx = try db.begin(scope, .{});
            defer tx.deinit();
            _ = try tx.exec(scope, "SELECT pg_advisory_xact_lock(7193546127)", .{});
            // Re-check under the lock — a concurrent migrator may have won.
            // On a fresh database the table itself does not exist yet, and
            // merely naming it in a query fails at parse, CASE or no CASE.
            const table = try tx.rawExactlyOne(Count, scope, "SELECT count(*)::bigint AS n FROM pg_tables " ++
                "WHERE schemaname = 'public' AND tablename = 'schema_migrations'", .{});
            const landed = if (table.n == 0) Count{ .n = 0 } else try tx.rawExactlyOne(Count, scope, "SELECT count(*)::bigint AS n FROM schema_migrations WHERE version = $1", .{@as(i64, m.version)});
            if (landed.n == 0) {
                _ = try tx.exec(scope, m.sql, .{});
                _ = try tx.exec(scope, "INSERT INTO schema_migrations (version, name) VALUES ($1, $2)", .{ @as(i64, m.version), @as([]const u8, m.name) });
                try tx.commit();
                try out.print("Applied {s}.\n", .{m.name});
                summary.applied += 1;
            }
        }
    }
    return summary;
}

const Count = struct {
    pub const nilo_table = .projection;
    n: i64,
};

const Version = struct {
    pub const nilo_table = .projection;
    version: i64,
};

fn appliedVersions(db: *dbx.sql.Db, scope: anytype) ![]const Version {
    const exists = try db.rawExactlyOne(Count, scope, "SELECT count(*)::bigint AS n FROM pg_tables " ++
        "WHERE schemaname = 'public' AND tablename = 'schema_migrations'", .{});
    if (exists.n == 0) return &.{};
    return db.raw(Version, scope, "SELECT version FROM schema_migrations ORDER BY version", .{});
}

fn contains(haystack: []const Version, version: u32) bool {
    for (haystack) |v| {
        if (v.version == version) return true;
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
