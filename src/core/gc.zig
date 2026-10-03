//! `cid admin gc`: cleanup of unreferenced bytes (invariant 10). Shows by
//! default; deletes only with `apply`.
//!
//! Kept, always: every item in the state of every release and every branch
//! head, of every dataset, and every item a revision named within the
//! retention period (work in flight, the platform's newest writes).
//! Candidates are the other items no push or registration has touched for
//! the whole period, not purged, not already collected. Abandoned staged
//! uploads older than the period go too.
//!
//! Racing pushes are safe by lock order. Each batch locks its items rows
//! and re-checks `touched_at` under the lock, records the collection, and
//! deletes the bytes before it commits. A push or registration upserts the
//! same row (waiting for that commit), then refuses a collected hash, and
//! the client's retry uploads the bytes again.

const std = @import("std");
const dbx = @import("../store/db.zig");
const blob = @import("../store/blob.zig");
const version = @import("version.zig");
const worker = @import("../preview/worker.zig");
const content_hash = @import("../util/hash.zig");

pub const Error = error{ Db, Storage, OutOfMemory };

pub const Options = struct {
    /// Retention period: nothing touched more recently is a candidate.
    days: u32 = 30,
    /// Delete; otherwise only count what would go.
    apply: bool = false,
};

pub const Report = struct {
    items: u64 = 0,
    bytes: u64 = 0,
    /// Abandoned uploads in the staging area.
    staged: u64 = 0,
};

const batch_rows = 1000;

pub fn run(gpa: std.mem.Allocator, db: *dbx.sql.Db, scope: anytype, s3: *blob.Client, options: Options) Error!Report {
    const days: i64 = options.days;
    var report: Report = .{};

    // Every ref's position, resolved before the transaction.
    const Ref = struct {
        pub const nilo_table = .projection;
        dataset_id: []const u8,
        commit_id: []const u8,
    };
    const refs = db.raw(Ref, scope, "SELECT dataset_id::text AS dataset_id, commit_id::text AS commit_id FROM refs", .{}) catch
        return error.Db;
    const ats = try scope.arena().alloc(version.At, refs.len);
    for (ats, refs) |*at, ref| at.* = version.at(db, scope, ref.dataset_id, ref.commit_id) catch return error.Db;

    // The keep set and the candidates, in one transaction.
    {
        var tx = db.begin(scope, .{}) catch return error.Db;
        defer tx.deinit();
        inline for (.{
            "TRUNCATE gc_candidates",
            "CREATE TEMP TABLE gc_keep (item_hash bytea PRIMARY KEY) ON COMMIT DROP",
        }) |sql| _ = tx.exec(scope, sql, .{}) catch return error.Db;
        for (ats, refs) |at, ref| {
            _ = tx.exec(scope, "INSERT INTO gc_keep WITH " ++ version.live_cte ++
                " SELECT DISTINCT item_hash FROM live ON CONFLICT DO NOTHING", .{ ref.dataset_id, at.branch, at.cutoff, at.main_cutoff }) catch
                return error.Db;
        }
        _ = tx.exec(scope, "INSERT INTO gc_keep SELECT DISTINCT item_hash FROM item_revisions " ++
            "WHERE item_hash IS NOT NULL AND ts > now() - $1::bigint * interval '1 day' ON CONFLICT DO NOTHING", .{days}) catch
            return error.Db;
        _ = tx.exec(scope, "INSERT INTO gc_candidates SELECT i.item_hash FROM items i " ++
            "WHERE i.touched_at < now() - $1::bigint * interval '1 day' " ++
            "AND NOT EXISTS (SELECT 1 FROM gc_keep k WHERE k.item_hash = i.item_hash) " ++
            "AND NOT EXISTS (SELECT 1 FROM purged_items p WHERE p.item_hash = i.item_hash) " ++
            "AND NOT EXISTS (SELECT 1 FROM collected_items c WHERE c.item_hash = i.item_hash)", .{days}) catch
            return error.Db;
        tx.commit() catch return error.Db;
    }

    const Totals = struct {
        pub const nilo_table = .projection;
        n: i64,
        bytes: i64,
    };
    if (!options.apply) {
        const t = (db.rawOne(Totals, scope, "SELECT count(*)::bigint AS n, coalesce(sum(i.size_bytes), 0)::bigint AS bytes " ++
            "FROM gc_candidates g JOIN items i USING (item_hash)", .{}) catch return error.Db).?;
        report.items = @intCast(t.n);
        report.bytes = @intCast(t.bytes);
    } else {
        try collect(gpa, db, s3, days, &report);
    }

    try clearStaged(gpa, db, scope, s3, days, options.apply, &report);
    return report;
}

/// Deletes the candidates a batch at a time, each batch its own
/// transaction (see the lock order above).
fn collect(gpa: std.mem.Allocator, db: *dbx.sql.Db, s3: *blob.Client, days: i64, report: *Report) Error!void {
    const Row = struct {
        pub const nilo_table = .projection;
        hash_hex: []const u8,
        size_bytes: i64,
    };
    var after: []const u8 = "";
    var after_buf: [64]u8 = undefined;
    while (true) {
        var batch = dbx.Run.init(gpa);
        defer batch.deinit();
        const arena = batch.arena();
        const page = db.raw([]const u8, &batch, "SELECT encode(item_hash, 'hex') FROM gc_candidates " ++
            "WHERE item_hash > decode($1, 'hex') ORDER BY item_hash LIMIT " ++ std.fmt.comptimePrint("{d}", .{batch_rows}), .{after}) catch
            return error.Db;
        if (page.len == 0) return;
        @memcpy(after_buf[0..64], page[page.len - 1][0..64]);
        after = &after_buf;

        var list: std.ArrayList(u8) = .empty;
        try list.append(arena, '{');
        for (page, 0..) |h, i| {
            if (i > 0) try list.append(arena, ',');
            try list.appendSlice(arena, h);
        }
        try list.append(arena, '}');

        var tx = db.begin(&batch, .{}) catch return error.Db;
        defer tx.deinit();
        // Still untouched, under the lock a push's upsert waits on.
        const rows = tx.raw(Row, &batch, "SELECT encode(i.item_hash, 'hex') AS hash_hex, i.size_bytes FROM items i " ++
            "WHERE i.item_hash IN (SELECT decode(h, 'hex') FROM unnest($1::text[]) h) " ++
            "AND i.touched_at < now() - $2::bigint * interval '1 day' " ++
            "AND NOT EXISTS (SELECT 1 FROM collected_items c WHERE c.item_hash = i.item_hash) " ++
            "FOR UPDATE OF i", .{ list.items, days }) catch return error.Db;
        for (rows) |r| {
            _ = tx.exec(&batch, "INSERT INTO collected_items (item_hash) VALUES (decode($1, 'hex'))", .{r.hash_hex}) catch return error.Db;
            _ = tx.exec(&batch, "DELETE FROM previews WHERE item_hash = decode($1, 'hex')", .{r.hash_hex}) catch return error.Db;
            const key = try content_hash.itemKey(arena, r.hash_hex);
            inline for (.{ worker.thumbKey, worker.blurKey }) |keyOf| {
                s3.deleteObject(&batch, try keyOf(arena, r.hash_hex)) catch |err| switch (err) {
                    error.NotFound => {},
                    else => return error.Storage,
                };
            }
            s3.deleteObject(&batch, key) catch |err| switch (err) {
                error.NotFound => {},
                else => return error.Storage,
            };
            report.items += 1;
            report.bytes += @intCast(r.size_bytes);
        }
        tx.commit() catch return error.Db;
        if (page.len < batch_rows) return;
    }
}

/// Staged uploads (uploads/<dataset_id>/<hash>) never recorded by a push
/// within the retention period: a push abandoned for good.
fn clearStaged(gpa: std.mem.Allocator, db: *dbx.sql.Db, scope: anytype, s3: *blob.Client, days: i64, apply: bool, report: *Report) Error!void {
    // LastModified is ISO 8601 in UTC (2026-09-18T10:11:12Z, with or
    // without milliseconds): its first 19 characters compare as text.
    const cutoff = (db.rawOne([]const u8, scope, "SELECT to_char((now() - $1::bigint * interval '1 day') AT TIME ZONE 'UTC', " ++
        "'YYYY-MM-DD\"T\"HH24:MI:SS')", .{days}) catch return error.Db).?;
    var cursor: ?[]const u8 = null;
    var cursor_buf: std.ArrayList(u8) = .empty;
    defer cursor_buf.deinit(gpa);
    while (true) {
        var batch = dbx.Run.init(gpa);
        defer batch.deinit();
        const page = s3.list(&batch, "uploads/", cursor) catch return error.Storage;
        for (page.objects) |object| {
            const stamp = object.last_modified.view();
            if (stamp.len < 19 or std.mem.order(u8, stamp[0..19], cutoff) != .lt) continue;
            if (apply) s3.deleteObject(&batch, object.key.view()) catch |err| switch (err) {
                error.NotFound => {},
                else => return error.Storage,
            };
            report.staged += 1;
        }
        const next = page.next orelse return;
        cursor_buf.clearRetainingCapacity();
        try cursor_buf.appendSlice(gpa, next.view());
        cursor = cursor_buf.items;
    }
}
