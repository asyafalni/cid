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
const dbx = @import("../store/db.zig");
const blob = @import("../store/blob.zig");
const sniff_mod = @import("../media/sniff.zig");

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
const QueueRow = struct {
    pub const nilo_table = .projection;
    hash: []const u8,
    media_type: []const u8,
    size_bytes: i64,
    attempts: i32,
};

pub fn processPending(
    arena: std.mem.Allocator,
    io: std.Io,
    db: *dbx.sql.Db,
    scope: anytype,
    s3: *blob.Client,
    config: Config,
) Error!Outcome {
    std.Io.Dir.cwd().createDirPath(io, config.tmpdir) catch return error.Storage;

    const rows = db.raw(QueueRow, scope, "SELECT encode(p.item_hash, 'hex') AS hash, i.media_type, i.size_bytes, p.attempts " ++
        "FROM previews p JOIN items i USING (item_hash) " ++
        "WHERE p.status = 'pending' ORDER BY p.updated_at LIMIT $1", .{@as(i64, config.batch)}) catch return error.Db;

    var outcome: Outcome = .{};
    for (rows) |row| {
        const hash = row.hash;
        const size: u64 = @intCast(@max(0, row.size_bytes));

        const result = buildOne(arena, io, db, scope, s3, config, hash, row.media_type, size);
        switch (result) {
            .built => {
                mark(db, scope, hash, "done", null);
                outcome.built += 1;
            },
            .skipped => |reason| {
                mark(db, scope, hash, "skipped", reason);
                outcome.skipped += 1;
            },
            .failed => |reason| {
                if (row.attempts + 1 >= config.max_attempts) {
                    mark(db, scope, hash, "skipped", reason);
                    outcome.skipped += 1;
                } else {
                    markRetry(db, scope, hash, reason);
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
    db: *dbx.sql.Db,
    scope: anytype,
    s3: *blob.Client,
    config: Config,
    hash: []const u8,
    media_type: []const u8,
    size: u64,
) BuildResult {
    var is_image = std.mem.startsWith(u8, media_type, "image/");
    var is_video = std.mem.startsWith(u8, media_type, "video/");
    const unknown = std.mem.eql(u8, media_type, "application/octet-stream");
    if (!is_image and !is_video and !unknown)
        return .{ .skipped = "not previewable: only images and video get thumbnails today" };
    if (size > config.max_input_bytes)
        return .{ .skipped = "too large to preview; raise the worker's limit to include it" };

    // Fetch the bytes to scratch (never previewed twice, so no cache).
    const item_key = std.fmt.allocPrint(arena, "items/sha256/{s}/{s}/{s}", .{
        hash[0..2], hash[2..4], hash,
    }) catch return .{ .failed = "out of memory" };
    const bytes = s3.getObjectAlloc(scope, item_key) catch
        return .{ .failed = "could not fetch the item from storage" };

    // The sanctioned look inside (invariant 15): an unknown media type is
    // sniffed here, where the bytes are already in hand — this is how a
    // CLI-pushed image earns its preview and its dimensions.
    if (unknown) {
        const found = sniff_mod.sniff(bytes) orelse
            return .{ .skipped = "not previewable: the content is not a known media format" };
        recordSniff(arena, db, scope, hash, found);
        is_image = std.mem.startsWith(u8, found.media_type, "image/");
        is_video = std.mem.startsWith(u8, found.media_type, "video/");
        if (!is_image and !is_video)
            return .{ .skipped = "not previewable: only images and video get thumbnails today" };
    }

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
    s3.putObject(scope, key, thumb) catch
        return .{ .failed = "could not store the thumbnail" };
    return .built;
}

fn recordSniff(arena: std.mem.Allocator, db: *dbx.sql.Db, scope: anytype, hash: []const u8, found: sniff_mod.Sniffed) void {
    const meta = std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{
        .width = found.width,
        .height = found.height,
    }, .{ .emit_null_optional_fields = false })}) catch return;
    _ = db.exec(
        scope,
        "UPDATE items SET media_type = $2, meta = meta || $3::jsonb WHERE item_hash = decode($1, 'hex')",
        .{ hash, found.media_type, meta },
    ) catch {};
}

fn mark(db: *dbx.sql.Db, scope: anytype, hash: []const u8, status: []const u8, reason: ?[]const u8) void {
    _ = db.exec(
        scope,
        "UPDATE previews SET status = $2, reason = $3, attempts = attempts + 1, updated_at = now() " ++
            "WHERE item_hash = decode($1, 'hex')",
        .{ hash, status, reason },
    ) catch {};
}

fn markRetry(db: *dbx.sql.Db, scope: anytype, hash: []const u8, reason: []const u8) void {
    _ = db.exec(
        scope,
        "UPDATE previews SET reason = $2, attempts = attempts + 1, updated_at = now() " ++
            "WHERE item_hash = decode($1, 'hex')",
        .{ hash, reason },
    ) catch {};
}
