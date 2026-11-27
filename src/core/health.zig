//! A version's health (docs/dashboard.md, 4.5): the checks cid computes
//! from the version itself, as one SQL aggregate over its live items and
//! annotations, computed once and kept on the commit (`commits.health`),
//! like its statistics: never on page load, and prepared in the background
//! for releases and branch heads. The raw numbers are kept; pass, warning
//! and fail are judged when read (`checks`), by fixed rules, so a rule can
//! change without recomputing anything.
//!
//! The Validator's tiles (miss rate, audited accuracy) are not here: they
//! come from the annotation platform's reports, in a later round.

const std = @import("std");
const dbx = @import("../store/db.zig");
const versions = @import("version.zig");
const table_stats = @import("../tabular/stats.zig");

pub const Error = versions.Error;

/// 1: the first shape; 2: unreadable tables by the worker's own verdict
/// only; 3: tables still waiting for the worker. A kept health of another
/// version is computed again.
pub const health_version: u32 = 3;

/// A few paths, so a check names what it found.
pub const Sample = struct { count: u64 = 0, sample: []const []const u8 = &.{} };

pub const Bucket = struct { b: []const u8, n: u64 };

/// What a version holds, counted.
pub const Raw = struct {
    v: u32 = health_version,
    items: u64 = 0,
    images: u64 = 0,
    annotations: u64 = 0,
    /// The same content in two splits: training on what is evaluated.
    leakage: Sample = .{},
    /// The same content at more than one path within one split: the extra copies.
    duplicates: Sample = .{},
    empty_files: Sample = .{},
    /// Tables (CSV, Parquet, JSONL) the preview worker could not read.
    unreadable_tables: Sample = .{},
    /// Tables the worker has not reached yet: until none are left, the
    /// health is not kept (the verdict on them is still to come).
    tables_waiting: u64 = 0,
    /// Items without one annotation (annotated datasets).
    unannotated: Sample = .{},
    /// Pictures with no recorded width and height: image exports fail on them.
    no_dimensions: Sample = .{},
    /// Boxes with a side of a pixel or less, or reaching outside their image.
    bad_boxes: Sample = .{},
    /// Annotations per class and split.
    class_split: []const struct { class: []const u8, split: []const u8, n: u64 } = &.{},
    objects_per_item: []const Bucket = &.{},
    /// Box area as a share of its image.
    box_sizes: []const Bucket = &.{},
    /// Image width over height.
    aspect: []const Bucket = &.{},
    /// Box centres on a 10×10 grid over the image, row by row (100 counts).
    heat: []const u64 = &.{},
};

const visual_types = "('.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.tif', '.tiff')";
const table_types = "('.csv', '.parquet', '.jsonl', '.ndjson')";

fn sample(comptime from: []const u8, comptime path: []const u8) []const u8 {
    return "(SELECT json_build_object('count', count(*), 'sample', coalesce((SELECT json_agg(p) FROM (SELECT " ++ path ++ " AS p FROM " ++ from ++
        " ORDER BY " ++ path ++ " COLLATE \"C\" LIMIT 20) s), '[]')) FROM " ++ from ++ ")";
}

const health_sql = "WITH " ++ versions.live_cte ++ ", " ++ versions.alive_cte ++ ", " ++
    "li AS MATERIALIZED (SELECT live.path, coalesce(live.split, '') AS split, live.item_hash, live.item_id, i.size_bytes, " ++
    "  lower(substring(live.path from '\\.[^./]*$')) AS ext, (i.meta->>'width')::float8 AS w, (i.meta->>'height')::float8 AS h " ++
    "  FROM live JOIN items i USING (item_hash)), " ++
    "an AS MATERIALIZED (SELECT item_id, kind, class, geometry FROM alive), " ++
    "per_item AS (SELECT item_id, count(*) AS n FROM an GROUP BY item_id), " ++
    "leak AS (SELECT min(path) AS path FROM li GROUP BY item_hash HAVING count(DISTINCT split) > 1), " ++
    "dup AS (SELECT path FROM (SELECT path, row_number() OVER (PARTITION BY item_hash, split ORDER BY path COLLATE \"C\") AS r FROM li) d WHERE r > 1), " ++
    "empty AS (SELECT path FROM li WHERE size_bytes = 0), " ++
    // Only the worker's own verdict on the table, not a skip for size or
    // any other reason.
    "unread AS (SELECT li.path FROM li JOIN previews p USING (item_hash) WHERE li.ext IN " ++ table_types ++
    " AND p.status = 'skipped' AND p.reason = '" ++ table_stats.unreadable_reason ++ "'), " ++
    "bare AS (SELECT li.path FROM li WHERE NOT EXISTS (SELECT 1 FROM per_item p WHERE p.item_id = li.item_id)), " ++
    "nodim AS (SELECT path FROM li WHERE ext IN " ++ visual_types ++ " AND (w IS NULL OR h IS NULL)), " ++
    "bx AS MATERIALIZED (SELECT li.path, (a.geometry->>'x')::float8 AS x, (a.geometry->>'y')::float8 AS y, " ++
    "  (a.geometry->>'w')::float8 AS bw, (a.geometry->>'h')::float8 AS bh, li.w, li.h " ++
    "  FROM an a JOIN li USING (item_id) WHERE a.kind = 'box' AND jsonb_typeof(a.geometry) = 'object' AND li.w > 0 AND li.h > 0), " ++
    "badbox AS (SELECT path FROM bx WHERE bw <= 1 OR bh <= 1 OR x < 0 OR y < 0 OR x + bw > w + 1 OR y + bh > h + 1) " ++
    "SELECT json_build_object('v', 3, " ++
    "'items', (SELECT count(*) FROM li), " ++
    "'images', (SELECT count(*) FROM li WHERE w > 0 AND h > 0), " ++
    "'annotations', (SELECT count(*) FROM an), " ++
    "'leakage', " ++ sample("leak", "path") ++ ", " ++
    "'duplicates', " ++ sample("dup", "path") ++ ", " ++
    "'empty_files', " ++ sample("empty", "path") ++ ", " ++
    "'unreadable_tables', " ++ sample("unread", "path") ++ ", " ++
    "'tables_waiting', (SELECT count(*) FROM li LEFT JOIN previews p USING (item_hash) WHERE li.ext IN " ++ table_types ++
    "  AND (p.status IS NULL OR p.status IN ('pending', 'building'))), " ++
    "'unannotated', " ++ sample("bare", "path") ++ ", " ++
    "'no_dimensions', " ++ sample("nodim", "path") ++ ", " ++
    "'bad_boxes', " ++ sample("badbox", "path") ++ ", " ++
    "'class_split', (SELECT coalesce(json_agg(json_build_object('class', class, 'split', split, 'n', n) ORDER BY class COLLATE \"C\", split COLLATE \"C\"), '[]') " ++
    "  FROM (SELECT coalesce(a.class, '') AS class, li.split, count(*) AS n FROM an a JOIN li USING (item_id) GROUP BY 1, 2 ORDER BY 1, 2 LIMIT 5000) c), " ++
    "'objects_per_item', (SELECT coalesce(json_agg(json_build_object('b', b, 'n', n) ORDER BY o), '[]') FROM (SELECT b, o, count(*) AS n FROM (" ++
    "  SELECT CASE WHEN coalesce(p.n, 0) = 0 THEN '0' WHEN p.n = 1 THEN '1' WHEN p.n <= 4 THEN '2-4' WHEN p.n <= 9 THEN '5-9' ELSE '10+' END AS b, " ++
    "  CASE WHEN coalesce(p.n, 0) = 0 THEN 0 WHEN p.n = 1 THEN 1 WHEN p.n <= 4 THEN 2 WHEN p.n <= 9 THEN 3 ELSE 4 END AS o " ++
    "  FROM li LEFT JOIN per_item p USING (item_id)) x GROUP BY 1, 2) y), " ++
    "'box_sizes', (SELECT coalesce(json_agg(json_build_object('b', b, 'n', n) ORDER BY o), '[]') FROM (SELECT b, o, count(*) AS n FROM (" ++
    "  SELECT CASE WHEN r < 0.0001 THEN 'under 0.01%' WHEN r < 0.001 THEN '0.01-0.1%' WHEN r < 0.01 THEN '0.1-1%' WHEN r < 0.1 THEN '1-10%' WHEN r < 0.5 THEN '10-50%' ELSE '50% and more' END AS b, " ++
    "  CASE WHEN r < 0.0001 THEN 0 WHEN r < 0.001 THEN 1 WHEN r < 0.01 THEN 2 WHEN r < 0.1 THEN 3 WHEN r < 0.5 THEN 4 ELSE 5 END AS o " ++
    "  FROM (SELECT greatest(bw, 0) * greatest(bh, 0) / (w * h) AS r FROM bx) s) x GROUP BY 1, 2) y), " ++
    "'aspect', (SELECT coalesce(json_agg(json_build_object('b', b, 'n', n) ORDER BY o), '[]') FROM (SELECT b, o, count(*) AS n FROM (" ++
    "  SELECT CASE WHEN r < 0.5 THEN 'tall, under 1:2' WHEN r < 0.9 THEN 'portrait' WHEN r <= 1.1 THEN 'square' WHEN r <= 2 THEN 'landscape' ELSE 'wide, over 2:1' END AS b, " ++
    "  CASE WHEN r < 0.5 THEN 0 WHEN r < 0.9 THEN 1 WHEN r <= 1.1 THEN 2 WHEN r <= 2 THEN 3 ELSE 4 END AS o " ++
    "  FROM (SELECT w / h AS r FROM li WHERE w > 0 AND h > 0) s) x GROUP BY 1, 2) y), " ++
    "'heat', (SELECT json_agg(coalesce(c.n, 0) ORDER BY g.i) FROM generate_series(0, 99) g(i) LEFT JOIN (" ++
    "  SELECT least(9, greatest(0, floor((y + bh / 2) / h * 10)))::int * 10 + least(9, greatest(0, floor((x + bw / 2) / w * 10)))::int AS i, count(*) AS n " ++
    "  FROM bx GROUP BY 1) c ON c.i = g.i)" ++
    ")::text";

/// The kept health of a version, computed the first time it is asked for.
pub fn of(arena: std.mem.Allocator, db: *dbx.sql.Db, scope: anytype, dataset_id: []const u8, commit_id: []const u8) Error!Raw {
    const stored = db.rawOne(?[]const u8, scope, "SELECT health::text FROM commits WHERE commit_id = $1::uuid AND dataset_id = $2::uuid", .{ commit_id, dataset_id }) catch return error.Db;
    // A row whose health is not kept yet, or is kept in another shape.
    if (stored) |column| if (column) |text| if (std.json.parseFromSliceLeaky(Raw, arena, text, .{ .ignore_unknown_fields = true })) |raw| {
        if (raw.v == health_version) return raw;
    } else |_| {};
    const where = try versions.at(db, scope, dataset_id, commit_id);
    const text = (db.rawOne([]const u8, scope, health_sql, .{ dataset_id, where.branch, where.cutoff, where.main_cutoff }) catch return error.Db) orelse return error.Db;
    const raw = std.json.parseFromSliceLeaky(Raw, arena, text, .{ .ignore_unknown_fields = true }) catch return error.Db;
    // Kept once nothing it reads can still change: a table the preview
    // worker has not reached yet would get its verdict later. A cache
    // that failed to store is computed again next time.
    if (raw.tables_waiting == 0)
        _ = db.exec(scope, "UPDATE commits SET health = $2::jsonb WHERE commit_id = $1::uuid", .{ commit_id, text }) catch {};
    return raw;
}

pub const Status = enum { pass, warn, fail, info };

/// One check as people read it: a mark, a title, what was found in words,
/// and the paths it found (a few).
pub const Check = struct {
    id: []const u8,
    status: Status,
    title: []const u8,
    says: []const u8,
    sample: []const []const u8 = &.{},
};

/// The fixed rules (decided 2026-11-22): fail only for what is always a
/// mistake, the same content in two splits; warn for what is worth a look;
/// the distributions are information.
pub fn checks(arena: std.mem.Allocator, raw: Raw, annotated: bool) error{OutOfMemory}![]const Check {
    var out: std.ArrayList(Check) = .empty;
    const found = struct {
        fn of(a: std.mem.Allocator, list: *std.ArrayList(Check), id: []const u8, title: []const u8, s: Sample, bad: Status, none: []const u8, some: []const u8) !void {
            try list.append(a, .{
                .id = id,
                .status = if (s.count == 0) .pass else bad,
                .title = title,
                .says = if (s.count == 0) none else try std.fmt.allocPrint(a, "{d} {s}", .{ s.count, some }),
                .sample = s.sample,
            });
        }
    }.of;
    try found(arena, &out, "leakage", "Splits kept apart", raw.leakage, .fail, "No content is in two splits.", if (raw.leakage.count == 1) "file's content is in more than one split: what is trained on is also what is evaluated. Keep it in one split." else "files' content is in more than one split: what is trained on is also what is evaluated. Keep each in one split.");
    try found(arena, &out, "duplicates", "No duplicate files", raw.duplicates, .warn, "No content appears twice within a split.", if (raw.duplicates.count == 1) "extra copy of content already in the same split." else "extra copies of content already in the same split.");
    try found(arena, &out, "empty_files", "No empty files", raw.empty_files, .warn, "No file is empty.", if (raw.empty_files.count == 1) "file is empty (0 bytes)." else "files are empty (0 bytes).");
    if (raw.unreadable_tables.count == 0 and raw.tables_waiting > 0) {
        try out.append(arena, .{
            .id = "unreadable_tables",
            .status = .info,
            .title = "Tables read",
            .says = try std.fmt.allocPrint(arena, "{d} {s} not been read yet; this check settles when the preview worker reaches {s}.", .{
                raw.tables_waiting, if (raw.tables_waiting == 1) "table has" else "tables have", if (raw.tables_waiting == 1) "it" else "them",
            }),
        });
    } else try found(arena, &out, "unreadable_tables", "Tables read", raw.unreadable_tables, .warn, "Every table the preview worker reached could be read.", if (raw.unreadable_tables.count == 1) "table could not be read as its file name says." else "tables could not be read as their file names say.");
    if (annotated) {
        try found(arena, &out, "unannotated", "Every item annotated", raw.unannotated, .warn, "Every item has at least one annotation.", if (raw.unannotated.count == 1) "item has no annotation yet." else "items have no annotation yet.");
        try found(arena, &out, "no_dimensions", "Image sizes recorded", raw.no_dimensions, .warn, "Every picture has its width and height recorded.", if (raw.no_dimensions.count == 1) "picture has no recorded size: the yolo, coco and voc exports fail on it. Register it with its dimensions." else "pictures have no recorded size: the yolo, coco and voc exports fail on them. Register them with their dimensions.");
        try found(arena, &out, "bad_boxes", "Boxes inside their images", raw.bad_boxes, .warn, "Every box is larger than a pixel and inside its image.", if (raw.bad_boxes.count == 1) "box is a pixel thin or reaches outside its image." else "boxes are a pixel thin or reach outside their image.");
        try out.append(arena, try balance(arena, raw));
    }
    return out.items;
}

/// Class balance: a class ten times rarer than the most common is worth a
/// look (a model rarely learns it); one class, or none, says so.
fn balance(arena: std.mem.Allocator, raw: Raw) error{OutOfMemory}!Check {
    var totals: std.StringArrayHashMapUnmanaged(u64) = .empty;
    for (raw.class_split) |c| {
        const slot = try totals.getOrPut(arena, c.class);
        if (!slot.found_existing) slot.value_ptr.* = 0;
        slot.value_ptr.* += c.n;
    }
    if (totals.count() < 2) return .{ .id = "balance", .status = .info, .title = "Class balance", .says = if (totals.count() == 0) "No annotations yet." else "One class only." };
    var most: u64 = 0;
    var least: u64 = std.math.maxInt(u64);
    var rare: []const u8 = "";
    for (totals.keys(), totals.values()) |k, n| {
        most = @max(most, n);
        if (n < least) {
            least = n;
            rare = k;
        }
    }
    if (least * 10 < most)
        return .{ .id = "balance", .status = .warn, .title = "Class balance", .says = try std.fmt.allocPrint(arena, "'{s}' has {d} annotation{s}, under a tenth of the most common class's {d}.", .{ if (rare.len == 0) "(no class)" else rare, least, if (least == 1) "" else "s", most }) };
    return .{ .id = "balance", .status = .pass, .title = "Class balance", .says = try std.fmt.allocPrint(arena, "{d} classes, the rarest at least a tenth of the most common.", .{totals.count()}) };
}

test "the rules: leakage fails, the rest warns, balance by tenths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const clean = try checks(a, .{ .class_split = &.{ .{ .class = "car", .split = "train", .n = 10 }, .{ .class = "person", .split = "train", .n = 2 } } }, true);
    for (clean) |c| try std.testing.expect(c.status == .pass);
    const bad = try checks(a, .{
        .leakage = .{ .count = 1, .sample = &.{"img/a.png"} },
        .unannotated = .{ .count = 3 },
        .class_split = &.{ .{ .class = "car", .split = "train", .n = 100 }, .{ .class = "truck", .split = "val", .n = 9 } },
    }, true);
    try std.testing.expectEqual(Status.fail, bad[0].status);
    try std.testing.expectEqualStrings("img/a.png", bad[0].sample[0]);
    try std.testing.expectEqual(Status.warn, bad[4].status);
    try std.testing.expectEqual(Status.warn, bad[7].status);
    try std.testing.expect(std.mem.indexOf(u8, bad[7].says, "'truck' has 9 annotations,") != null);
    const one = try checks(a, .{ .class_split = &.{ .{ .class = "car", .split = "train", .n = 100 }, .{ .class = "sign", .split = "train", .n = 1 } } }, true);
    try std.testing.expect(std.mem.indexOf(u8, one[7].says, "'sign' has 1 annotation,") != null);
    // Tables not read yet: a note, not a pass.
    const waiting = try checks(a, .{ .tables_waiting = 2 }, false);
    try std.testing.expectEqual(Status.info, waiting[3].status);
    try std.testing.expect(std.mem.indexOf(u8, waiting[3].says, "2 tables have not been read yet") != null);
    // A file dataset has no annotation checks.
    try std.testing.expectEqual(@as(usize, 4), (try checks(a, .{}, false)).len);
}
