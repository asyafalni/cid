//! `cid admin purge`: the one sanctioned exception to append-only
//! (docs/data-model.md). Deletes an item's bytes, tombstones the hash,
//! logs the act — and never touches history rows, so affected releases
//! report "intact except N purged items" instead of silently changing.

const std = @import("std");
const dbx = @import("../store/db.zig");
const blob = @import("../store/blob.zig");

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
    db: *dbx.sql.Db,
    scope: anytype,
    s3: *blob.Client,
    dataset_name: []const u8,
    target: []const u8,
    reason: []const u8,
    purged_by: []const u8,
) Error!Purged {
    const dataset_id = (db.rawOne([]const u8, scope, "SELECT dataset_id::text FROM datasets WHERE name = $1", .{dataset_name}) catch
        return error.Db) orelse return error.NoSuchDataset;

    // Resolve the hash and make sure this dataset actually references it.
    const hash_hex: []const u8 = blk: {
        if (target.len == 64) {
            const found = db.rawOne(i64, scope, "SELECT 1::bigint FROM item_revisions " ++
                "WHERE dataset_id = $1::uuid AND item_hash = decode($2, 'hex') LIMIT 1", .{ dataset_id, target }) catch return error.Db;
            if (found == null) return error.NoSuchItem;
            break :blk target;
        }
        const newest = db.rawOne([]const u8, scope, "SELECT encode(item_hash, 'hex') FROM item_revisions " ++
            "WHERE dataset_id = $1::uuid AND branch = 'main' AND path = $2 AND op <> 'delete' " ++
            "ORDER BY rev_id DESC LIMIT 1", .{ dataset_id, target }) catch return error.Db;
        break :blk (newest orelse return error.NoSuchItem);
    };

    const tomb = db.rawOne(i64, scope, "SELECT 1::bigint FROM purged_items WHERE item_hash = decode($1, 'hex')", .{hash_hex}) catch
        return error.Db;
    if (tomb != null) return error.AlreadyPurged;

    // Tombstone and audit first: if the byte deletion then fails, re-running
    // finishes the job and nothing was lost silently.
    _ = db.exec(
        scope,
        "INSERT INTO purged_items (item_hash, dataset_id, reason, purged_by) " ++
            "VALUES (decode($1, 'hex'), $2::uuid, $3, $4)",
        .{ hash_hex, dataset_id, reason, purged_by },
    ) catch return error.Db;
    const detail = std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{ .reason = reason }, .{})}) catch
        return error.OutOfMemory;
    _ = db.exec(
        scope,
        "INSERT INTO activity_events (ts, dataset_id, account_id, action, ref, detail) " ++
            "VALUES (now(), $1::uuid, $2, 'purge', $3, $4::jsonb)",
        .{ dataset_id, purged_by, hash_hex, detail },
    ) catch return error.Db;

    const key = std.fmt.allocPrint(arena, "items/sha256/{s}/{s}/{s}", .{
        hash_hex[0..2], hash_hex[2..4], hash_hex,
    }) catch return error.OutOfMemory;
    s3.deleteObject(scope, key) catch return error.Storage;

    const affected = db.rawExactlyOne(i64, scope, "SELECT count(DISTINCT r.name) FROM refs r JOIN commits c ON c.commit_id = r.commit_id " ++
        "JOIN item_revisions ir ON ir.dataset_id = r.dataset_id AND ir.rev_id <= c.cutoff_rev " ++
        "WHERE r.dataset_id = $1::uuid AND r.kind = 'release' AND ir.item_hash = decode($2, 'hex')", .{ dataset_id, hash_hex }) catch return error.Db;

    return .{ .hash_hex = hash_hex, .releases_affected = @intCast(affected) };
}
