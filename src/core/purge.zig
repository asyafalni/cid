//! `cid admin purge`: the one sanctioned exception to append-only
//! (docs/data-model.md). Deletes an item's bytes, tombstones the hash,
//! logs the act — and never touches history rows, so affected releases
//! report "intact except N purged items" instead of silently changing.

const std = @import("std");
const pg = @import("../store/pg.zig");
const s3_mod = @import("../store/s3.zig");

pub const Error = error{
    NoSuchDataset,
    NoSuchItem,
    AlreadyPurged,
    Db,
    Storage,
    OutOfMemory,
};

pub const Purged = struct {
    hash_hex: []const u8,
    releases_affected: usize,
};

/// `target` is a 64-hex item hash, or a path whose newest main-branch
/// content is meant.
pub fn purge(
    arena: std.mem.Allocator,
    db: *pg.Db,
    s3: *s3_mod.Client,
    dataset_name: []const u8,
    target: []const u8,
    reason: []const u8,
    purged_by: []const u8,
) Error!Purged {
    const name_z = arena.dupeZ(u8, dataset_name) catch return error.OutOfMemory;
    const dataset_id: [:0]const u8 = blk: {
        var rows = db.query("SELECT dataset_id::text FROM datasets WHERE name = $1", &.{name_z}, null) catch
            return error.Db;
        defer rows.deinit();
        if (rows.count() == 0) return error.NoSuchDataset;
        break :blk arena.dupeZ(u8, rows.get(0, 0)) catch return error.OutOfMemory;
    };

    // Resolve the hash and make sure this dataset actually references it.
    const hash_hex: []const u8 = blk: {
        if (target.len == 64) {
            const target_z = arena.dupeZ(u8, target) catch return error.OutOfMemory;
            var rows = db.query(
                "SELECT 1 FROM item_revisions WHERE dataset_id = $1::uuid AND item_hash = decode($2, 'hex') LIMIT 1",
                &.{ dataset_id, target_z },
                null,
            ) catch return error.Db;
            defer rows.deinit();
            if (rows.count() == 0) return error.NoSuchItem;
            break :blk target;
        }
        const target_z = arena.dupeZ(u8, target) catch return error.OutOfMemory;
        var rows = db.query(
            "SELECT encode(item_hash, 'hex') FROM item_revisions " ++
                "WHERE dataset_id = $1::uuid AND branch = 'main' AND path = $2 AND op <> 'delete' " ++
                "ORDER BY rev_id DESC LIMIT 1",
            &.{ dataset_id, target_z },
            null,
        ) catch return error.Db;
        defer rows.deinit();
        if (rows.count() == 0) return error.NoSuchItem;
        break :blk arena.dupe(u8, rows.get(0, 0)) catch return error.OutOfMemory;
    };
    const hash_z = arena.dupeZ(u8, hash_hex) catch return error.OutOfMemory;

    {
        var rows = db.query("SELECT 1 FROM purged_items WHERE item_hash = decode($1, 'hex')", &.{hash_z}, null) catch
            return error.Db;
        defer rows.deinit();
        if (rows.count() > 0) return error.AlreadyPurged;
    }

    // Tombstone and audit first: if the byte deletion then fails, re-running
    // finishes the job and nothing was lost silently.
    db.execParams(
        "INSERT INTO purged_items (item_hash, dataset_id, reason, purged_by) " ++
            "VALUES (decode($1, 'hex'), $2::uuid, $3, $4)",
        &.{ hash_z, dataset_id, arena.dupeZ(u8, reason) catch return error.OutOfMemory, arena.dupeZ(u8, purged_by) catch return error.OutOfMemory },
        null,
    ) catch return error.Db;
    db.execParams(
        "INSERT INTO activity_events (ts, dataset_id, account_id, action, ref, detail) " ++
            "VALUES (now(), $1::uuid, $2, 'purge', $3, $4::jsonb)",
        &.{
            dataset_id,
            arena.dupeZ(u8, purged_by) catch return error.OutOfMemory,
            hash_z,
            std.fmt.allocPrintSentinel(arena, "{f}", .{std.json.fmt(.{ .reason = reason }, .{})}, 0) catch return error.OutOfMemory,
        },
        null,
    ) catch return error.Db;

    const key = std.fmt.allocPrint(arena, "items/sha256/{s}/{s}/{s}", .{
        hash_hex[0..2], hash_hex[2..4], hash_hex,
    }) catch return error.OutOfMemory;
    s3.deleteObject(arena, key) catch return error.Storage;

    var releases = db.query(
        "SELECT count(DISTINCT r.name) FROM refs r JOIN commits c ON c.commit_id = r.commit_id " ++
            "JOIN item_revisions ir ON ir.dataset_id = r.dataset_id AND ir.rev_id <= c.cutoff_rev " ++
            "WHERE r.dataset_id = $1::uuid AND r.kind = 'release' AND ir.item_hash = decode($2, 'hex')",
        &.{ dataset_id, hash_z },
        null,
    ) catch return error.Db;
    defer releases.deinit();
    const affected = std.fmt.parseInt(usize, releases.get(0, 0), 10) catch 0;

    return .{ .hash_hex = hash_hex, .releases_affected = affected };
}
