//! Releases: tagging a commit with a manifest, and verifying that a
//! release can be rebuilt exactly (invariants 5 and 6). Used by the
//! server's tag route and by `cid admin verify`.
//!
//! v0 stores the manifest as the canonical text stream itself
//! (manifests/<dataset_id>/<commit_id>.manifest). Parquet via DuckDB is a
//! storage upgrade for the browse API later; the hash is defined over the
//! canonical stream either way, so the upgrade cannot break releases.

const std = @import("std");
const pg = @import("../store/pg.zig");
const s3_mod = @import("../store/s3.zig");
const canonical = @import("../manifest/canonical.zig");
const jcs = @import("../manifest/jcs.zig");
const Uuid = @import("../util/uuid7.zig").Uuid;

pub const Error = error{
    NoSuchCommit,
    ReleaseExists,
    BadName,
    BadAnnotationText,
    Db,
    Storage,
    OutOfMemory,
};

/// Release names: what you would tag in git. No slashes, no control
/// characters, and never shaped like a commit id.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 100) return false;
    for (name) |ch| switch (ch) {
        'A'...'Z', 'a'...'z', '0'...'9', '.', '_', '-' => {},
        else => return false,
    };
    if (Uuid.parse(name)) |_| return false else |_| {}
    return true;
}

pub const StateRow = struct {
    path: []const u8,
    hash_hex: []const u8,
    size: u64,
    split: ?[]const u8,
    item_id: ?[]const u8 = null,
    width: ?u32 = null,
    height: ?u32 = null,
};

/// State at a commit, sorted by path — the one query both the browse API
/// and manifests are built from. On a branch: main up to the branch's
/// start cutoff, plus the branch's own changes (CLAUDE.md, data model);
/// branch revisions are minted later, so plain rev_id ordering gives them
/// precedence.
pub fn stateRows(
    arena: std.mem.Allocator,
    db: *pg.Db,
    dataset_id: [:0]const u8,
    commit_id: [:0]const u8,
) Error![]StateRow {
    var commit_rows = db.query(
        "SELECT branch, cutoff_rev::text FROM commits WHERE commit_id = $1::uuid AND dataset_id = $2::uuid",
        &.{ commit_id, dataset_id },
        null,
    ) catch return error.Db;
    defer commit_rows.deinit();
    if (commit_rows.count() == 0) return error.NoSuchCommit;
    const branch = arena.dupeZ(u8, commit_rows.get(0, 0)) catch return error.OutOfMemory;
    const cutoff = arena.dupeZ(u8, commit_rows.get(0, 1)) catch return error.OutOfMemory;

    // The branch's base: main as of the start commit's cutoff.
    var main_cutoff: [:0]const u8 = cutoff;
    if (!std.mem.eql(u8, branch, "main")) {
        var start_rows = db.query(
            "SELECT c.cutoff_rev::text FROM refs r JOIN commits c ON c.commit_id = r.start_commit_id " ++
                "WHERE r.dataset_id = $1::uuid AND r.name = $2 AND r.kind = 'branch'",
            &.{ dataset_id, branch },
            null,
        ) catch return error.Db;
        defer start_rows.deinit();
        if (start_rows.count() == 0) return error.NoSuchCommit;
        main_cutoff = arena.dupeZ(u8, start_rows.get(0, 0)) catch return error.OutOfMemory;
    }

    var rows = db.query(
        "SELECT path, encode(item_hash, 'hex'), i.size_bytes::text, s.split, " ++
            "i.meta->>'width', i.meta->>'height', s.item_id::text FROM (" ++
            "  SELECT DISTINCT ON (path) path, op, item_hash, split, item_id FROM item_revisions " ++
            "  WHERE dataset_id = $1::uuid AND (" ++
            "    (branch = 'main' AND rev_id <= $4::uuid) OR (branch = $2 AND rev_id <= $3::uuid)) " ++
            "  ORDER BY path, rev_id DESC) s " ++
            "JOIN items i USING (item_hash) WHERE s.op <> 'delete' ORDER BY path",
        &.{ dataset_id, branch, cutoff, main_cutoff },
        null,
    ) catch return error.Db;
    defer rows.deinit();

    const out = arena.alloc(StateRow, rows.count()) catch return error.OutOfMemory;
    for (out, 0..) |*row, i| {
        row.* = .{
            .path = arena.dupe(u8, rows.get(i, 0)) catch return error.OutOfMemory,
            .hash_hex = arena.dupe(u8, rows.get(i, 1)) catch return error.OutOfMemory,
            .size = std.fmt.parseInt(u64, rows.get(i, 2), 10) catch return error.Db,
            .split = if (rows.isNull(i, 3)) null else arena.dupe(u8, rows.get(i, 3)) catch return error.OutOfMemory,
            .width = if (rows.isNull(i, 4)) null else std.fmt.parseInt(u32, rows.get(i, 4), 10) catch null,
            .height = if (rows.isNull(i, 5)) null else std.fmt.parseInt(u32, rows.get(i, 5), 10) catch null,
            .item_id = if (rows.isNull(i, 6)) null else arena.dupe(u8, rows.get(i, 6)) catch return error.OutOfMemory,
        };
    }
    return out;
}

fn datasetKind(arena: std.mem.Allocator, db: *pg.Db, dataset_id: [:0]const u8) Error![]const u8 {
    var rows = db.query("SELECT kind FROM datasets WHERE dataset_id = $1::uuid", &.{dataset_id}, null) catch
        return error.Db;
    defer rows.deinit();
    if (rows.count() == 0) return error.Db;
    return arena.dupe(u8, rows.get(0, 0)) catch error.OutOfMemory;
}

/// The whole release stream: v1 for file datasets (hashes frozen since the
/// first release ever), v2 with annotation rows for annotated ones.
fn renderManifest(
    arena: std.mem.Allocator,
    db: *pg.Db,
    dataset_id: [:0]const u8,
    commit_id: [:0]const u8,
    rows: []const StateRow,
) Error!canonical.Rendered {
    const item_rows = arena.alloc(canonical.ItemRow, rows.len) catch return error.OutOfMemory;
    for (item_rows, 0..) |*r, i| {
        r.* = .{ .path = rows[i].path, .hash_hex = rows[i].hash_hex, .size = rows[i].size, .split = rows[i].split };
    }
    const kind = try datasetKind(arena, db, dataset_id);
    if (!std.mem.eql(u8, kind, "annotated")) {
        return canonical.render(arena, item_rows) catch error.OutOfMemory;
    }

    const anns = try annotationRows(arena, db, dataset_id, commit_id);
    const ann_rows = arena.alloc(canonical.AnnRow, anns.len) catch return error.OutOfMemory;
    for (ann_rows, 0..) |*r, i| {
        r.* = .{
            .item_id = anns[i].item_id,
            .annotation_id = anns[i].annotation_id,
            .kind = anns[i].kind,
            .class = anns[i].class,
            .geometry_jcs = if (anns[i].geometry) |g| jcs.fromText(arena, g) catch return error.BadAnnotationText else null,
            .attrs_jcs = if (anns[i].attrs) |a| jcs.fromText(arena, a) catch return error.BadAnnotationText else null,
            .author = anns[i].author,
            .policy_ver = anns[i].policy_ver,
        };
    }
    const bytes = canonical.renderAnnotated(arena, item_rows, ann_rows) catch |err| switch (err) {
        error.BadAnnotationText => return error.BadAnnotationText,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return .{ .bytes = bytes, .sha256_hex = canonical.hashOf(bytes) };
}

pub const AnnotationRow = struct {
    annotation_id: []const u8,
    item_id: []const u8,
    kind: ?[]const u8,
    class: ?[]const u8,
    /// Raw JSON text (or null), exactly as stored.
    geometry: ?[]const u8,
    attrs: ?[]const u8,
    author: []const u8,
    policy_ver: []const u8,
};

/// Annotation state at a commit: for each annotation_id, the latest change
/// up to the cutoff, deletes dropped — composed over main like items.
/// Sorted by (item_id, annotation_id), the manifest order.
pub fn annotationRows(
    arena: std.mem.Allocator,
    db: *pg.Db,
    dataset_id: [:0]const u8,
    commit_id: [:0]const u8,
) Error![]AnnotationRow {
    var commit_rows = db.query(
        "SELECT branch, cutoff_rev::text FROM commits WHERE commit_id = $1::uuid AND dataset_id = $2::uuid",
        &.{ commit_id, dataset_id },
        null,
    ) catch return error.Db;
    defer commit_rows.deinit();
    if (commit_rows.count() == 0) return error.NoSuchCommit;
    const branch = arena.dupeZ(u8, commit_rows.get(0, 0)) catch return error.OutOfMemory;
    const cutoff = arena.dupeZ(u8, commit_rows.get(0, 1)) catch return error.OutOfMemory;

    var main_cutoff: [:0]const u8 = cutoff;
    if (!std.mem.eql(u8, branch, "main")) {
        var start_rows = db.query(
            "SELECT c.cutoff_rev::text FROM refs r JOIN commits c ON c.commit_id = r.start_commit_id " ++
                "WHERE r.dataset_id = $1::uuid AND r.name = $2 AND r.kind = 'branch'",
            &.{ dataset_id, branch },
            null,
        ) catch return error.Db;
        defer start_rows.deinit();
        if (start_rows.count() == 0) return error.NoSuchCommit;
        main_cutoff = arena.dupeZ(u8, start_rows.get(0, 0)) catch return error.OutOfMemory;
    }

    var rows = db.query(
        "SELECT annotation_id::text, item_id::text, kind, class, geometry::text, attrs::text, author, policy_ver FROM (" ++
            "  SELECT DISTINCT ON (annotation_id) * FROM annotation_revisions " ++
            "  WHERE dataset_id = $1::uuid AND (" ++
            "    (branch = 'main' AND rev_id <= $4::uuid) OR (branch = $2 AND rev_id <= $3::uuid)) " ++
            "  ORDER BY annotation_id, rev_id DESC) s " ++
            "WHERE s.op <> 'delete' ORDER BY item_id, annotation_id",
        &.{ dataset_id, branch, cutoff, main_cutoff },
        null,
    ) catch return error.Db;
    defer rows.deinit();

    const out = arena.alloc(AnnotationRow, rows.count()) catch return error.OutOfMemory;
    for (out, 0..) |*row, i| {
        row.* = .{
            .annotation_id = arena.dupe(u8, rows.get(i, 0)) catch return error.OutOfMemory,
            .item_id = arena.dupe(u8, rows.get(i, 1)) catch return error.OutOfMemory,
            .kind = if (rows.isNull(i, 2)) null else arena.dupe(u8, rows.get(i, 2)) catch return error.OutOfMemory,
            .class = if (rows.isNull(i, 3)) null else arena.dupe(u8, rows.get(i, 3)) catch return error.OutOfMemory,
            .geometry = if (rows.isNull(i, 4)) null else arena.dupe(u8, rows.get(i, 4)) catch return error.OutOfMemory,
            .attrs = if (rows.isNull(i, 5)) null else arena.dupe(u8, rows.get(i, 5)) catch return error.OutOfMemory,
            .author = arena.dupe(u8, rows.get(i, 6)) catch return error.OutOfMemory,
            .policy_ver = arena.dupe(u8, rows.get(i, 7)) catch return error.OutOfMemory,
        };
    }
    return out;
}

pub fn manifestKey(arena: std.mem.Allocator, dataset_id: []const u8, commit_id: []const u8) Error![]const u8 {
    return std.fmt.allocPrint(arena, "manifests/{s}/{s}.manifest", .{ dataset_id, commit_id }) catch
        error.OutOfMemory;
}

pub const Created = struct {
    name: []const u8,
    commit_id: []const u8,
    manifest_sha256: [64]u8,
    items: usize,
};

/// Tags `commit_id` as release `name`: renders the manifest, stores it,
/// then inserts the release ref (which can never move again).
pub fn create(
    arena: std.mem.Allocator,
    db: *pg.Db,
    s3: *s3_mod.Client,
    dataset_id: [:0]const u8,
    name: []const u8,
    commit_id: [:0]const u8,
) Error!Created {
    if (!validName(name)) return error.BadName;

    {
        const name_z = arena.dupeZ(u8, name) catch return error.OutOfMemory;
        var existing = db.query(
            "SELECT 1 FROM refs WHERE dataset_id = $1::uuid AND name = $2",
            &.{ dataset_id, name_z },
            null,
        ) catch return error.Db;
        defer existing.deinit();
        if (existing.count() > 0) return error.ReleaseExists;
    }

    const rows = try stateRows(arena, db, dataset_id, commit_id);
    const rendered = try renderManifest(arena, db, dataset_id, commit_id, rows);

    const key = try manifestKey(arena, dataset_id, commit_id);
    s3.putObject(arena, key, rendered.bytes) catch return error.Storage;

    const name_z = arena.dupeZ(u8, name) catch return error.OutOfMemory;
    const key_z = arena.dupeZ(u8, key) catch return error.OutOfMemory;
    const sha_z = arena.dupeZ(u8, &rendered.sha256_hex) catch return error.OutOfMemory;
    db.execParams(
        "INSERT INTO refs (dataset_id, name, kind, commit_id, manifest_path, manifest_sha256) " ++
            "VALUES ($1::uuid, $2, 'release', $3::uuid, $4, decode($5, 'hex'))",
        &.{ dataset_id, name_z, commit_id, key_z, sha_z },
        null,
    ) catch return error.Db;

    return .{
        .name = name,
        .commit_id = commit_id,
        .manifest_sha256 = rendered.sha256_hex,
        .items = rows.len,
    };
}

pub const VerifyProblem = enum {
    recomputed_hash_differs, // history under the cutoff changed: corruption
    stored_manifest_differs, // the stored manifest object was tampered with
    stored_manifest_missing,
    item_missing_from_storage,
};

pub const VerifyResult = struct {
    ok: bool,
    items: usize,
    /// Items whose bytes were purged (docs/data-model.md): the release is
    /// "intact except N purged items", which is not a verification failure.
    purged: usize = 0,
    problems: []const VerifyProblem,
};

/// Rebuilds the release from history and checks everything that must
/// still match: the recomputed canonical hash against the recorded one,
/// the stored manifest bytes, and every referenced item's presence.
pub fn verify(
    arena: std.mem.Allocator,
    db: *pg.Db,
    s3: *s3_mod.Client,
    dataset_id: [:0]const u8,
    release_name: []const u8,
) Error!VerifyResult {
    const name_z = arena.dupeZ(u8, release_name) catch return error.OutOfMemory;
    var ref_rows = db.query(
        "SELECT commit_id::text, manifest_path, encode(manifest_sha256, 'hex') FROM refs " ++
            "WHERE dataset_id = $1::uuid AND name = $2 AND kind = 'release'",
        &.{ dataset_id, name_z },
        null,
    ) catch return error.Db;
    defer ref_rows.deinit();
    if (ref_rows.count() == 0) return error.NoSuchCommit;
    const commit_id = arena.dupeZ(u8, ref_rows.get(0, 0)) catch return error.OutOfMemory;
    const manifest_path = arena.dupe(u8, ref_rows.get(0, 1)) catch return error.OutOfMemory;
    const recorded_hash = arena.dupe(u8, ref_rows.get(0, 2)) catch return error.OutOfMemory;

    var problems: std.ArrayList(VerifyProblem) = .empty;
    const rows = try stateRows(arena, db, dataset_id, commit_id);
    const rendered = try renderManifest(arena, db, dataset_id, commit_id, rows);

    if (!std.mem.eql(u8, &rendered.sha256_hex, recorded_hash))
        problems.append(arena, .recomputed_hash_differs) catch return error.OutOfMemory;

    if (s3.getObjectAlloc(arena, manifest_path, 1024 * 1024 * 1024)) |stored| {
        if (!std.mem.eql(u8, &canonical.hashOf(stored), recorded_hash))
            problems.append(arena, .stored_manifest_differs) catch return error.OutOfMemory;
    } else |_| {
        problems.append(arena, .stored_manifest_missing) catch return error.OutOfMemory;
    }

    var purged: usize = 0;
    for (rows) |row| {
        const key = std.fmt.allocPrint(arena, "items/sha256/{s}/{s}/{s}", .{
            row.hash_hex[0..2], row.hash_hex[2..4], row.hash_hex,
        }) catch return error.OutOfMemory;
        const present = s3.headObject(arena, key) catch return error.Storage;
        if (present == null) {
            const hash_z = arena.dupeZ(u8, row.hash_hex) catch return error.OutOfMemory;
            var tomb = db.query("SELECT 1 FROM purged_items WHERE item_hash = decode($1, 'hex')", &.{hash_z}, null) catch
                return error.Db;
            defer tomb.deinit();
            if (tomb.count() > 0) {
                purged += 1;
            } else {
                problems.append(arena, .item_missing_from_storage) catch return error.OutOfMemory;
                break; // one is enough to fail; listing all comes later
            }
        }
    }

    return .{ .ok = problems.items.len == 0, .items = rows.len, .purged = purged, .problems = problems.items };
}

test "release names" {
    try std.testing.expect(validName("v1.0.0"));
    try std.testing.expect(validName("2026-10-01_nightly"));
    try std.testing.expect(!validName(""));
    try std.testing.expect(!validName("v1/0"));
    try std.testing.expect(!validName("has space"));
    try std.testing.expect(!validName("01a0f5e3-49a3-7ae3-a919-41a8a5666c35")); // commit-shaped
}
