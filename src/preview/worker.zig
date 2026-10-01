//! The preview worker: drains the `previews` queue — the only code in
//! cid that ever runs ffmpeg. The law (CLAUDE.md): work scales with
//! ingested content, never with traffic; one build per content hash;
//! bounded attempts; a file that cannot be previewed is skipped with the
//! reason on record, never retried in a loop.
//!
//! Every invocation is disciplined: nice -19, -nostdin, -threads 1, a
//! hard timeout, and a size guard before any byte is fetched. Outputs
//! land in SeaweedFS at previews/<aa>/<hex>/thumb.webp, immutable.

const std = @import("std");
const pg = @import("../store/pg.zig");
const s3_mod = @import("../store/s3.zig");

pub const Config = struct {
    /// Scratch space for input/output files; created if missing.
    tmpdir: []const u8 = "/tmp/cid-previews",
    /// Items larger than this are skipped, not fetched.
    max_input_bytes: u64 = 256 * 1024 * 1024,
    timeout_ns: i96 = 30 * std.time.ns_per_s,
    video_timeout_ns: i96 = 120 * std.time.ns_per_s,
    max_attempts: i32 = 3,
    /// How many queue rows one pass claims.
    batch: u32 = 16,
};

pub const Error = error{ Db, Storage, OutOfMemory };

pub const Outcome = struct {
    built: u32 = 0,
    skipped: u32 = 0,
    failed: u32 = 0,
};

pub fn thumbKey(arena: std.mem.Allocator, hash_hex: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "previews/{s}/{s}/thumb.webp", .{ hash_hex[0..2], hash_hex });
}

/// One pass over the queue. Serial on purpose: the default concurrency
/// is one ffmpeg in flight; raise it by running more passes in more
/// processes, never by letting traffic fan out.
pub fn processPending(
    arena: std.mem.Allocator,
    io: std.Io,
    db: *pg.Db,
    s3: *s3_mod.Client,
    config: Config,
) Error!Outcome {
    std.Io.Dir.cwd().createDirPath(io, config.tmpdir) catch return error.Storage;

    const batch_z = std.fmt.allocPrintSentinel(arena, "{d}", .{config.batch}, 0) catch
        return error.OutOfMemory;
    var rows = db.query(
        "SELECT encode(p.item_hash, 'hex'), i.media_type, i.size_bytes::text, p.attempts " ++
            "FROM previews p JOIN items i USING (item_hash) " ++
            "WHERE p.status = 'pending' ORDER BY p.updated_at LIMIT $1",
        &.{batch_z},
        null,
    ) catch return error.Db;
    defer rows.deinit();

    var outcome: Outcome = .{};
    var i: usize = 0;
    while (i < rows.count()) : (i += 1) {
        const hash = arena.dupe(u8, rows.get(i, 0)) catch return error.OutOfMemory;
        const media_type = arena.dupe(u8, rows.get(i, 1)) catch return error.OutOfMemory;
        const size = std.fmt.parseInt(u64, rows.get(i, 2), 10) catch 0;
        const attempts = std.fmt.parseInt(i32, rows.get(i, 3), 10) catch 0;

        const result = buildOne(arena, io, db, s3, config, hash, media_type, size);
        switch (result) {
            .built => {
                mark(arena, db, hash, "done", null);
                outcome.built += 1;
            },
            .skipped => |reason| {
                mark(arena, db, hash, "skipped", reason);
                outcome.skipped += 1;
            },
            .failed => |reason| {
                if (attempts + 1 >= config.max_attempts) {
                    mark(arena, db, hash, "skipped", reason);
                    outcome.skipped += 1;
                } else {
                    markRetry(arena, db, hash, reason);
                    outcome.failed += 1;
                }
                std.log.warn("preview {s}: {s}", .{ hash[0..12], reason });
            },
        }
    }
    return outcome;
}

const BuildResult = union(enum) {
    built,
    skipped: []const u8,
    failed: []const u8,
};

fn buildOne(
    arena: std.mem.Allocator,
    io: std.Io,
    db: *pg.Db,
    s3: *s3_mod.Client,
    config: Config,
    hash: []const u8,
    media_type: []const u8,
    size: u64,
) BuildResult {
    _ = db;
    const is_image = std.mem.startsWith(u8, media_type, "image/");
    const is_video = std.mem.startsWith(u8, media_type, "video/");
    if (!is_image and !is_video)
        return .{ .skipped = "not previewable: only images and video get thumbnails today" };
    if (size > config.max_input_bytes)
        return .{ .skipped = "too large to preview; raise the worker's limit to include it" };

    // Fetch the bytes to scratch (never previewed twice, so no cache).
    const item_key = std.fmt.allocPrint(arena, "items/sha256/{s}/{s}/{s}", .{
        hash[0..2], hash[2..4], hash,
    }) catch return .{ .failed = "out of memory" };
    const bytes = s3.getObjectAlloc(arena, item_key, config.max_input_bytes) catch
        return .{ .failed = "could not fetch the item from storage" };

    const in_path = std.fmt.allocPrint(arena, "{s}/{s}.in", .{ config.tmpdir, hash }) catch
        return .{ .failed = "out of memory" };
    const out_path = std.fmt.allocPrint(arena, "{s}/{s}.webp", .{ config.tmpdir, hash }) catch
        return .{ .failed = "out of memory" };
    defer std.Io.Dir.cwd().deleteFile(io, in_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, out_path) catch {};
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = in_path, .data = bytes }) catch
        return .{ .failed = "could not write scratch input" };

    // The disciplined invocation. -frames:v 1 makes images and posters
    // the same shape; video seeks fast to its first second.
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(arena, &.{ "nice", "-n", "19", "ffmpeg", "-nostdin", "-threads", "1", "-y", "-loglevel", "error" }) catch
        return .{ .failed = "out of memory" };
    if (is_video) argv.appendSlice(arena, &.{ "-ss", "1" }) catch return .{ .failed = "out of memory" };
    argv.appendSlice(arena, &.{
        "-i",        in_path,
        "-vf",       "scale='min(320,iw)':-2",
        "-frames:v", "1",
        out_path,
    }) catch return .{ .failed = "out of memory" };

    const run = std.process.run(arena, io, .{
        .argv = argv.items,
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .{
            .nanoseconds = if (is_video) config.video_timeout_ns else config.timeout_ns,
        } } },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return .{ .failed = "ffmpeg could not run (is it installed?)" };
    if (run.term != .exited or run.term.exited != 0) {
        const tail = std.mem.trim(u8, run.stderr, " \n");
        const reason = std.fmt.allocPrint(arena, "ffmpeg refused the file: {s}", .{
            tail[if (tail.len > 160) tail.len - 160 else 0..],
        }) catch "ffmpeg refused the file";
        return .{ .failed = reason };
    }

    const thumb = std.Io.Dir.cwd().readFileAlloc(io, out_path, arena, .limited(8 * 1024 * 1024)) catch
        return .{ .failed = "ffmpeg wrote nothing" };
    const key = thumbKey(arena, hash) catch return .{ .failed = "out of memory" };
    s3.putObject(arena, key, thumb) catch
        return .{ .failed = "could not store the thumbnail" };
    return .built;
}

fn mark(arena: std.mem.Allocator, db: *pg.Db, hash: []const u8, status: []const u8, reason: ?[]const u8) void {
    const hash_z = arena.dupeZ(u8, hash) catch return;
    const status_z = arena.dupeZ(u8, status) catch return;
    if (reason) |r| {
        const reason_z = arena.dupeZ(u8, r) catch return;
        db.execParams(
            "UPDATE previews SET status = $2, reason = $3, attempts = attempts + 1, updated_at = now() " ++
                "WHERE item_hash = decode($1, 'hex')",
            &.{ hash_z, status_z, reason_z },
            null,
        ) catch {};
    } else {
        db.execParams(
            "UPDATE previews SET status = $2, reason = NULL, attempts = attempts + 1, updated_at = now() " ++
                "WHERE item_hash = decode($1, 'hex')",
            &.{ hash_z, status_z },
            null,
        ) catch {};
    }
}

fn markRetry(arena: std.mem.Allocator, db: *pg.Db, hash: []const u8, reason: []const u8) void {
    const hash_z = arena.dupeZ(u8, hash) catch return;
    const reason_z = arena.dupeZ(u8, reason) catch return;
    db.execParams(
        "UPDATE previews SET reason = $2, attempts = attempts + 1, updated_at = now() " ++
            "WHERE item_hash = decode($1, 'hex')",
        &.{ hash_z, reason_z },
        null,
    ) catch {};
}
