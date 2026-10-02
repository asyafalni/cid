//! Releases: tagging a commit with a manifest, and verifying that a
//! release can be rebuilt exactly (invariants 5 and 6). Used by the
//! server's tag route and by `cid admin verify`.
//!
//! The manifest is stored as the canonical text stream itself
//! (manifests/<dataset_id>/<commit_id>.manifest), which is what the hash
//! covers, written in one streamed pass over history (version.zig) at any
//! size. The release's browse index (.items.parquet, .anns.parquet) sits
//! beside it, written in the same pass by the server: derived,
//! rebuildable, never hashed, so it cannot break a release.

const std = @import("std");
const dbx = @import("../store/db.zig");
const blob = @import("../store/blob.zig");
const version = @import("version.zig");
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

const RawState = struct {
    pub const nilo_table = .projection;
    path: []const u8,
    hash_hex: []const u8,
    size_bytes: i64,
    split: ?[]const u8,
    width: ?i32,
    height: ?i32,
    item_id: ?[]const u8,
};

/// The whole state at a commit, in memory, bytewise by path. For what
/// still answers with a whole version at once (the CLI's state route,
/// merges); releases, statistics and
/// browse indexes stream through version.zig instead.
pub fn stateRows(
    arena: std.mem.Allocator,
    db: *dbx.sql.Db,
    scope: anytype,
    dataset_id: []const u8,
    commit_id: []const u8,
) Error![]StateRow {
    const where = version.at(db, scope, dataset_id, commit_id) catch |err| return mapVersion(err);
    const rows = db.raw(RawState, scope, "WITH " ++ version.live_cte ++
        " SELECT live.path, encode(live.item_hash, 'hex') AS hash_hex, i.size_bytes, live.split, " ++
        "(i.meta->>'width')::int AS width, (i.meta->>'height')::int AS height, live.item_id::text AS item_id " ++
        "FROM live JOIN items i USING (item_hash) ORDER BY live.path COLLATE \"C\"", .{ dataset_id, where.branch, where.cutoff, where.main_cutoff }) catch return error.Db;
    // Rows already live in the scope's arena: converted, never copied.
    const out = arena.alloc(StateRow, rows.len) catch return error.OutOfMemory;
    for (out, rows) |*row, raw| row.* = .{
        .path = raw.path,
        .hash_hex = raw.hash_hex,
        .size = @intCast(raw.size_bytes),
        .split = raw.split,
        .width = if (raw.width) |v| @intCast(v) else null,
        .height = if (raw.height) |v| @intCast(v) else null,
        .item_id = raw.item_id,
    };
    return out;
}

pub const AnnotationRow = struct {
    pub const nilo_table = .projection;
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

/// Annotation state at a commit, by (item_id, annotation_id), in memory.
pub fn annotationRows(
    arena: std.mem.Allocator,
    db: *dbx.sql.Db,
    scope: anytype,
    dataset_id: []const u8,
    commit_id: []const u8,
) Error![]AnnotationRow {
    _ = arena;
    const where = version.at(db, scope, dataset_id, commit_id) catch |err| return mapVersion(err);
    return db.raw(AnnotationRow, scope, "WITH " ++ version.alive_cte ++
        " SELECT annotation_id::text AS annotation_id, item_id::text AS item_id, kind, class, " ++
        "geometry::text AS geometry, attrs::text AS attrs, author, policy_ver " ++
        "FROM alive ORDER BY item_id, annotation_id", .{ dataset_id, where.branch, where.cutoff, where.main_cutoff }) catch error.Db;
}

fn mapVersion(err: version.Error) Error {
    return switch (err) {
        error.NoSuchCommit => error.NoSuchCommit,
        error.BadAnnotationText => error.BadAnnotationText,
        error.OutOfMemory => error.OutOfMemory,
        error.Db => error.Db,
        error.WriteFailed => error.Storage,
    };
}

fn isAnnotated(db: *dbx.sql.Db, scope: anytype, dataset_id: []const u8) Error!bool {
    const kind = (db.rawOne([]const u8, scope, "SELECT kind FROM datasets WHERE dataset_id = $1::uuid", .{dataset_id}) catch
        return error.Db) orelse return error.Db;
    return std.mem.eql(u8, kind, "annotated");
}

pub fn manifestKey(arena: std.mem.Allocator, dataset_id: []const u8, commit_id: []const u8) Error![]const u8 {
    return std.fmt.allocPrint(arena, "manifests/{s}/{s}.manifest", .{ dataset_id, commit_id }) catch
        error.OutOfMemory;
}

pub const Created = struct {
    name: []const u8,
    commit_id: []const u8,
    manifest_sha256: [64]u8,
    items: u64,
};

/// Where a release's work happens: the allocator each streamed batch
/// takes and gives back, and a folder for the manifest on its way to
/// storage.
pub const Work = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    /// The browse index lines, written in the same pass when given (the
    /// server turns them into the release's Parquet index).
    items: ?*std.Io.Writer = null,
    annotations: ?*std.Io.Writer = null,
};

/// Tags `commit_id` as release `name`: streams the manifest to a file
/// while hashing it, uploads the file, then inserts the release ref
/// (which can never move again). Memory stays one batch deep at any size.
pub fn create(
    arena: std.mem.Allocator,
    work: Work,
    db: *dbx.sql.Db,
    scope: anytype,
    s3: *blob.Client,
    dataset_id: []const u8,
    name: []const u8,
    commit_id: []const u8,
) Error!Created {
    if (!validName(name)) return error.BadName;
    const existing = db.rawOne(i64, scope, "SELECT 1::bigint FROM refs WHERE dataset_id = $1::uuid AND name = $2", .{ dataset_id, name }) catch return error.Db;
    if (existing != null) return error.ReleaseExists;
    const annotated = try isAnnotated(db, scope, dataset_id);

    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(work.io, work.dir) catch return error.Storage;
    const path = std.fmt.allocPrint(arena, "{s}/{s}.manifest", .{ work.dir, commit_id }) catch return error.OutOfMemory;
    defer cwd.deleteFile(work.io, path) catch {};
    const written = blk: {
        var file = cwd.createFile(work.io, path, .{ .truncate = true }) catch return error.Storage;
        defer file.close(work.io);
        var buf: [64 * 1024]u8 = undefined;
        var fw = file.writer(work.io, &buf);
        break :blk version.pass(work.gpa, db, scope, dataset_id, commit_id, .{
            .manifest = &fw.interface,
            .annotated = annotated,
            .items = work.items,
            .annotations = work.annotations,
            .stats = true,
        }) catch |err| return mapVersion(err);
    };

    const key = try manifestKey(arena, dataset_id, commit_id);
    s3.putFile(scope, work.io, key, path) catch return error.Storage;
    _ = db.exec(
        scope,
        "INSERT INTO refs (dataset_id, name, kind, commit_id, manifest_path, manifest_sha256) " ++
            "VALUES ($1::uuid, $2, 'release', $3::uuid, $4, decode($5, 'hex'))",
        .{ dataset_id, name, commit_id, key, @as([]const u8, &written.sha256_hex.?) },
    ) catch return error.Db;
    return .{ .name = name, .commit_id = commit_id, .manifest_sha256 = written.sha256_hex.?, .items = written.items };
}

pub const VerifyProblem = enum {
    recomputed_hash_differs, // history under the cutoff changed: corruption
    stored_manifest_differs, // the stored manifest object was tampered with
    stored_manifest_missing,
    item_missing_from_storage,
};

pub const VerifyResult = struct {
    ok: bool,
    items: u64,
    /// Items whose bytes were purged (docs/data-model.md): the release is
    /// "intact except N purged items", which is not a verification failure.
    purged: usize = 0,
    problems: []const VerifyProblem,
};

const RefRow = struct {
    pub const nilo_table = .projection;
    commit_id: []const u8,
    manifest_path: []const u8,
    manifest_sha256: []const u8,
};

/// Rebuilds the release from history and checks everything that must
/// still match: the recomputed canonical hash against the recorded one,
/// the stored manifest's bytes (hashed as they stream in), and every
/// referenced item's presence, a batch at a time.
pub fn verify(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    db: *dbx.sql.Db,
    scope: anytype,
    s3: *blob.Client,
    dataset_id: []const u8,
    release_name: []const u8,
) Error!VerifyResult {
    const ref = (db.rawOne(
        RefRow,
        scope,
        "SELECT commit_id::text AS commit_id, manifest_path, " ++
            "encode(manifest_sha256, 'hex') AS manifest_sha256 FROM refs " ++
            "WHERE dataset_id = $1::uuid AND name = $2 AND kind = 'release'",
        .{ dataset_id, release_name },
    ) catch return error.Db) orelse return error.NoSuchCommit;
    var problems: std.ArrayList(VerifyProblem) = .empty;

    const Presence = struct {
        arena: std.mem.Allocator,
        db: *dbx.sql.Db,
        s3: *blob.Client,
        scope: @TypeOf(scope),
        purged: usize = 0,
        missing: bool = false,
        failed: ?Error = null,

        fn visit(ctx: *anyopaque, hashes: []const []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.missing) return true; // one is enough; the hash still needs the rest
            for (hashes) |h| {
                var key_buf: [96]u8 = undefined;
                const key = std.fmt.bufPrint(&key_buf, "items/sha256/{s}/{s}/{s}", .{ h[0..2], h[2..4], h }) catch {
                    self.failed = error.Storage;
                    return false;
                };
                const present = self.s3.headObject(self.scope, key) catch {
                    self.failed = error.Storage;
                    return false;
                };
                if (present != null) continue;
                const tomb = self.db.rawOne(i64, self.scope, "SELECT 1::bigint FROM purged_items WHERE item_hash = decode($1, 'hex')", .{h}) catch {
                    self.failed = error.Db;
                    return false;
                };
                if (tomb == null) {
                    self.missing = true;
                    return true;
                }
                self.purged += 1;
            }
            return true;
        }
    };
    var presence: Presence = .{ .arena = arena, .db = db, .s3 = s3, .scope = scope };

    // One pass: the manifest rebuilt (hashed, then discarded) and every
    // item's presence checked as its batch goes by, up to the first one
    // missing (one is enough to fail; the hash still needs every row).
    var discard: std.Io.Writer.Discarding = .init(&.{});
    const annotated = try isAnnotated(db, scope, dataset_id);
    const rebuilt = version.pass(gpa, db, scope, dataset_id, ref.commit_id, .{
        .manifest = &discard.writer,
        .annotated = annotated,
        .hashes = .{ .ctx = &presence, .visit = Presence.visit },
    }) catch |err| return mapVersion(err);
    if (presence.failed) |err| return err;
    if (!std.mem.eql(u8, &rebuilt.sha256_hex.?, ref.manifest_sha256))
        problems.append(arena, .recomputed_hash_differs) catch return error.OutOfMemory;
    if (presence.missing) problems.append(arena, .item_missing_from_storage) catch return error.OutOfMemory;

    var buf: [64 * 1024]u8 = undefined;
    var hashing: std.Io.Writer.Hashing(std.crypto.hash.sha2.Sha256) = .init(&buf);
    if (s3.streamTo(scope, ref.manifest_path, &hashing.writer)) |_| {
        hashing.writer.flush() catch return error.Storage;
        var digest: [32]u8 = undefined;
        hashing.hasher.final(&digest);
        if (!std.mem.eql(u8, &std.fmt.bytesToHex(digest, .lower), ref.manifest_sha256))
            problems.append(arena, .stored_manifest_differs) catch return error.OutOfMemory;
    } else |_| {
        problems.append(arena, .stored_manifest_missing) catch return error.OutOfMemory;
    }

    return .{ .ok = problems.items.len == 0, .items = rebuilt.items, .purged = presence.purged, .problems = problems.items };
}

test "release names" {
    try std.testing.expect(validName("v1.0.0"));
    try std.testing.expect(validName("2026-10-01_nightly"));
    try std.testing.expect(!validName(""));
    try std.testing.expect(!validName("v1/0"));
    try std.testing.expect(!validName("has space"));
    try std.testing.expect(!validName("01a0f5e3-49a3-7ae3-a919-41a8a5666c35")); // commit-shaped
}
