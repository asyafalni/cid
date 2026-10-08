//! A version — the state at a commit — read at any size (invariant 13):
//! cursors in one read-only transaction, 5,000 rows a batch, each batch in
//! a scope of its own that is freed before the next is fetched. Memory is
//! one batch deep whether the version holds ten items or ten million.
//!
//! The release manifest is written here (hashed as it is written), and so
//! are a version's statistics, which Postgres aggregates in one statement
//! and which are kept on the commit: computed once, read by the home page,
//! the overview and the git writer alike.

const std = @import("std");
const dbx = @import("../store/db.zig");
const canonical = @import("../manifest/canonical.zig");
const jcs = @import("../manifest/jcs.zig");
const hash = @import("../util/hash.zig");

pub const Error = error{ NoSuchCommit, BadAnnotationText, Db, WriteFailed, OutOfMemory };

pub const batch_rows = 5000;

pub const At = struct { branch: []const u8, cutoff: []const u8, main_cutoff: []const u8 };

/// The commit's branch and cutoff, plus the main cutoff a branch composes
/// over (the branch's start commit; on main, the same cutoff).
pub fn at(db: *dbx.sql.Db, scope: anytype, dataset_id: []const u8, commit_id: []const u8) Error!At {
    const Commit = struct {
        pub const nilo_table = .projection;
        branch: []const u8,
        cutoff_rev: []const u8,
    };
    const commit = (db.rawOne(Commit, scope, "SELECT branch, cutoff_rev::text AS cutoff_rev FROM commits " ++
        "WHERE commit_id = $1::uuid AND dataset_id = $2::uuid", .{ commit_id, dataset_id }) catch return error.Db) orelse
        return error.NoSuchCommit;
    if (std.mem.eql(u8, commit.branch, "main"))
        return .{ .branch = commit.branch, .cutoff = commit.cutoff_rev, .main_cutoff = commit.cutoff_rev };
    const start = (db.rawOne([]const u8, scope, "SELECT c.cutoff_rev::text FROM refs r JOIN commits c ON c.commit_id = r.start_commit_id " ++
        "WHERE r.dataset_id = $1::uuid AND r.name = $2 AND r.kind = 'branch'", .{ dataset_id, commit.branch }) catch return error.Db) orelse
        return error.NoSuchCommit;
    return .{ .branch = commit.branch, .cutoff = commit.cutoff_rev, .main_cutoff = start };
}

/// The state's building blocks, for statements that take ($1 dataset,
/// $2 branch, $3 cutoff, $4 main cutoff): `live`, the items at the commit,
/// and `alive`, the annotations. On a branch, main up to the branch's
/// start plus the branch's own changes; branch revisions are minted
/// later, so the newest revision wins either way.
pub const live_cte =
    "s AS (SELECT DISTINCT ON (path) path, op, item_hash, split, item_id FROM item_revisions " ++
    "  WHERE dataset_id = $1::uuid AND ((branch = 'main' AND rev_id <= $4::uuid) OR (branch = $2 AND rev_id <= $3::uuid)) " ++
    "  ORDER BY path, rev_id DESC), " ++
    "live AS (SELECT * FROM s WHERE op <> 'delete')";
pub const alive_cte =
    "a AS (SELECT DISTINCT ON (annotation_id) * FROM annotation_revisions " ++
    "  WHERE dataset_id = $1::uuid AND ((branch = 'main' AND rev_id <= $4::uuid) OR (branch = $2 AND rev_id <= $3::uuid)) " ++
    "  ORDER BY annotation_id, rev_id DESC), " ++
    "alive AS (SELECT * FROM a WHERE op <> 'delete')";

/// The file type of a path, in SQL: the base name's last extension,
/// lowercased, or "file" for none or a leading dot only — the one rule the
/// dashboard, browse, the home page and the dataset repository all use.
pub fn extOf(comptime path: []const u8) []const u8 {
    const base = "regexp_replace(" ++ path ++ ", '^.*/', '')";
    return "CASE WHEN " ++ base ++ " ~ '^\\.?[^.]*$' THEN 'file' ELSE lower(substring(" ++ base ++ " FROM '(\\.[^.]*)$')) END";
}

// ---------------------------------------------------------------------------
// One pass over a version: manifest, browse index files, statistics.
// ---------------------------------------------------------------------------

/// What one pass writes; every output is optional.
pub const Outputs = struct {
    /// The canonical manifest stream (canonical.zig), hashed as written.
    manifest: ?*std.Io.Writer = null,
    /// Browse index lines: one JSON object per item, in path order…
    items: ?*std.Io.Writer = null,
    /// …and one per annotation, by (item_id, annotation_id).
    annotations: ?*std.Io.Writer = null,
    /// Keep the version's statistics on the commit, from the same snapshot.
    stats: bool = false,
    /// Each batch's item hashes, in path order; answering false stops the
    /// pass early (verify's presence check stops at the first missing).
    hashes: ?Visitor = null,
};

pub const Visitor = struct {
    ctx: *anyopaque,
    visit: *const fn (ctx: *anyopaque, hashes: []const []const u8) bool,
};

pub const Written = struct {
    hash_hex: ?[64]u8 = null,
    items: u64 = 0,
    annotations: u64 = 0,
};

/// The first line of a state file.
pub fn stateHeader(w: *std.Io.Writer, commit_id: []const u8) !void {
    try w.print("{{\"cid\":\"state\",\"v\":1,\"commit\":\"{s}\"}}\n", .{commit_id});
}

const PassItem = struct {
    pub const nilo_table = .projection;
    path: []const u8,
    hash_hex: []const u8,
    size_bytes: i64,
    split: ?[]const u8,
    item_id: ?[]const u8,
    ext: []const u8,
    classes: []const u8,
};

const PassAnn = struct {
    pub const nilo_table = .projection;
    annotation_id: []const u8,
    item_id: []const u8,
    kind: ?[]const u8,
    class: ?[]const u8,
    geometry: ?[]const u8,
    attrs: ?[]const u8,
    author: []const u8,
    policy_ver: []const u8,
};

/// The version at `where`, materialized once into `<name>_live` (items,
/// indexed by path, bytewise) and `<name>_alive` (annotations, indexed by
/// item and id): temporary tables that go when the transaction ends.
pub fn materialize(tx: anytype, scope: anytype, dataset_id: []const u8, where: At, comptime name: []const u8) Error!void {
    const args = .{ dataset_id, where.branch, where.cutoff, where.main_cutoff };
    inline for (.{
        "CREATE TEMP TABLE " ++ name ++ "_live (path text, item_hash bytea, split text, item_id uuid, size_bytes bigint, width int, height int) ON COMMIT DROP",
        "CREATE TEMP TABLE " ++ name ++ "_alive (annotation_id uuid, item_id uuid, kind text, class text, geometry jsonb, attrs jsonb, author text, policy_ver text) ON COMMIT DROP",
    }) |ddl| _ = tx.exec(scope, ddl, .{}) catch return error.Db;
    _ = tx.exec(scope, "INSERT INTO " ++ name ++ "_live WITH " ++ live_cte ++
        " SELECT live.path, live.item_hash, live.split, live.item_id, i.size_bytes, " ++
        "(i.meta->>'width')::int, (i.meta->>'height')::int FROM live JOIN items i USING (item_hash)", args) catch return error.Db;
    _ = tx.exec(scope, "INSERT INTO " ++ name ++ "_alive WITH " ++ alive_cte ++
        " SELECT annotation_id, item_id, kind, class, geometry, attrs, author, policy_ver FROM alive", args) catch return error.Db;
    inline for (.{
        "CREATE INDEX ON " ++ name ++ "_live (path COLLATE \"C\")",
        "CREATE INDEX ON " ++ name ++ "_alive (item_id, annotation_id)",
        "ANALYZE " ++ name ++ "_live",
        "ANALYZE " ++ name ++ "_alive",
    }) |sql| _ = tx.exec(scope, sql, .{}) catch return error.Db;
}

/// Reads the version once and writes whatever `outputs` asks for. The
/// state is computed a single time, into indexed temporary tables inside
/// one transaction (dropped when it ends); the outputs then read those in
/// the two orders they need, a batch at a time. Postgres builds no JSON:
/// the lines are written here, and DuckDB turns them into Parquet later.
pub fn pass(
    gpa: std.mem.Allocator,
    db: *dbx.sql.Db,
    scope: anytype,
    dataset_id: []const u8,
    commit_id: []const u8,
    outputs: Outputs,
) Error!Written {
    const where = try at(db, scope, dataset_id, commit_id);
    var tx = db.begin(scope, .{}) catch return error.Db;
    defer tx.deinit(); // rolled back: the temporary tables go with it
    try materialize(&tx, scope, dataset_id, where, "v");
    _ = tx.exec(scope, "CREATE TEMP TABLE v_classes ON COMMIT DROP AS SELECT item_id, " ++
        "array_to_json(array_agg(coalesce(class, '') ORDER BY annotation_id))::text AS classes FROM v_alive GROUP BY item_id", .{}) catch return error.Db;
    _ = tx.exec(scope, "ANALYZE v_classes", .{}) catch return error.Db;

    var hasher = hash.init();
    var written: Written = .{};
    if (outputs.manifest) |m| {
        hasher.update(canonical.header);
        m.writeAll(canonical.header) catch return error.WriteFailed;
    }

    _ = tx.exec(scope, "DECLARE pass_items NO SCROLL CURSOR FOR SELECT l.path, encode(l.item_hash, 'hex') AS hash_hex, " ++
        "l.size_bytes, l.split, l.item_id::text AS item_id, " ++ comptime extOf("l.path") ++ " AS ext, coalesce(c.classes, '[]') AS classes " ++
        "FROM v_live l LEFT JOIN v_classes c USING (item_id) ORDER BY l.path COLLATE \"C\"", .{}) catch return error.Db;
    while (true) {
        var batch = dbx.Run.init(gpa);
        defer batch.deinit();
        const arena = batch.arena();
        const rows = tx.raw(PassItem, &batch, "FETCH 5000 FROM pass_items", .{}) catch return error.Db;
        if (outputs.manifest) |m| {
            var text: std.ArrayList(u8) = .empty;
            for (rows) |r| try canonical.appendItemRow(arena, &text, .{
                .path = r.path,
                // A live item always has one: the schema refuses an add without it.
                .item_id = r.item_id orelse return error.Db,
                .hash_hex = r.hash_hex,
                .size = @intCast(r.size_bytes),
                .split = r.split,
            });
            hasher.update(text.items);
            m.writeAll(text.items) catch return error.WriteFailed;
        }
        if (outputs.items) |w| for (rows) |r| {
            w.print("{{\"path\":{f},\"hash\":\"{s}\",\"size\":{d},\"split\":{f},\"item_id\":{f},\"ext\":{f},\"classes\":{s}}}\n", .{
                std.json.fmt(r.path, .{}),  r.hash_hex,                   r.size_bytes,
                std.json.fmt(r.split, .{}), std.json.fmt(r.item_id, .{}), std.json.fmt(r.ext, .{}),
                r.classes,
            }) catch return error.WriteFailed;
        };
        written.items += rows.len;
        if (outputs.hashes) |v| {
            const hashes = try arena.alloc([]const u8, rows.len);
            for (hashes, rows) |*h, r| h.* = r.hash_hex;
            if (!v.visit(v.ctx, hashes)) return written;
        }
        if (rows.len < batch_rows) break;
    }

    if (outputs.annotations != null or outputs.manifest != null) {
        _ = tx.exec(scope, "DECLARE pass_anns NO SCROLL CURSOR FOR SELECT annotation_id::text AS annotation_id, item_id::text AS item_id, " ++
            "kind, class, geometry::text AS geometry, attrs::text AS attrs, author, policy_ver FROM v_alive ORDER BY item_id, annotation_id", .{}) catch return error.Db;
        while (true) {
            var batch = dbx.Run.init(gpa);
            defer batch.deinit();
            const arena = batch.arena();
            const rows = tx.raw(PassAnn, &batch, "FETCH 5000 FROM pass_anns", .{}) catch return error.Db;
            if (outputs.manifest) |m| {
                var text: std.ArrayList(u8) = .empty;
                for (rows) |r| canonical.appendAnnRow(arena, &text, .{
                    .item_id = r.item_id,
                    .annotation_id = r.annotation_id,
                    .kind = r.kind,
                    .class = r.class,
                    .geometry_jcs = if (r.geometry) |g| jcs.fromText(arena, g) catch return error.BadAnnotationText else null,
                    .attrs_jcs = if (r.attrs) |x| jcs.fromText(arena, x) catch return error.BadAnnotationText else null,
                    .author = r.author,
                    .policy_ver = r.policy_ver,
                }) catch |err| return switch (err) {
                    error.BadAnnotationText => error.BadAnnotationText,
                    error.OutOfMemory => error.OutOfMemory,
                };
                hasher.update(text.items);
                m.writeAll(text.items) catch return error.WriteFailed;
            }
            if (outputs.annotations) |w| for (rows) |r| {
                w.print("{{\"id\":\"{s}\",\"item_id\":\"{s}\",\"kind\":{f},\"class\":{f},\"geometry\":{s},\"attrs\":{s},\"author\":{f},\"policy_ver\":{f}}}\n", .{
                    r.annotation_id,             r.item_id,
                    std.json.fmt(r.kind, .{}),   std.json.fmt(r.class, .{}),
                    r.geometry orelse "null",    r.attrs orelse "null",
                    std.json.fmt(r.author, .{}), std.json.fmt(r.policy_ver, .{}),
                }) catch return error.WriteFailed;
            };
            written.annotations += rows.len;
            if (rows.len < batch_rows) break;
        }
    }

    if (outputs.stats) {
        if (tx.rawOne([]const u8, scope, "WITH " ++ comptime statsOver("v_live", "v_alive"), .{}) catch null) |text| {
            _ = tx.exec(scope, "UPDATE commits SET stats = $2::jsonb WHERE commit_id = $1::uuid", .{ commit_id, text }) catch {};
            // Kept only if the transaction commits: everything else it did
            // was temporary, so committing changes nothing but this.
            tx.commit() catch {};
        }
    }

    inline for (.{ outputs.manifest, outputs.items, outputs.annotations }) |maybe| if (maybe) |w| w.flush() catch return error.WriteFailed;
    if (outputs.manifest != null) {
        written.hash_hex = hash.hexOf(&hasher);
    }
    return written;
}

// ---------------------------------------------------------------------------
// Statistics: one aggregate statement, kept on the commit.
// ---------------------------------------------------------------------------

pub const Count = struct { name: []const u8, count: u64 };

pub const Stats = struct {
    v: u32 = stats_version,
    items: u64 = 0,
    bytes: u64 = 0,
    /// Every file type by count, most first (at most 200).
    types: []const Count = &.{},
    splits: []const Count = &.{},
    /// Up to four visual items, the first by path: a stable sample.
    visual: []const []const u8 = &.{},
    annotations: u64 = 0,
    /// Annotations per class, by name (at most 1,000 classes).
    classes: []const Count = &.{},
    /// The newest policy version any annotation was made under.
    policy: ?[]const u8 = null,
};

pub const stats_version: u32 = 2;

const visual_types = "('.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.mp4', '.mov', '.webm', '.mkv')";

/// The statistics aggregate over an item source and an annotation source
/// (the state's CTEs, or a pass's temporary tables), after "WITH ".
fn statsOver(comptime live: []const u8, comptime alive: []const u8) []const u8 {
    return "t AS MATERIALIZED (SELECT x.path, x.split, x.item_hash, x.size_bytes, " ++ comptime extOf("x.path") ++ " AS ext FROM " ++ live ++ " x), " ++
        "c AS MATERIALIZED (SELECT class, policy_ver FROM " ++ alive ++ ") " ++
        "SELECT json_build_object('v', " ++ std.fmt.comptimePrint("{d}", .{stats_version}) ++ ", " ++
        "'items', (SELECT count(*) FROM t), " ++
        "'bytes', (SELECT coalesce(sum(size_bytes), 0) FROM t), " ++
        "'types', (SELECT coalesce(json_agg(json_build_object('name', ext, 'count', n) ORDER BY n DESC, ext COLLATE \"C\"), '[]') " ++
        "   FROM (SELECT ext, count(*) AS n FROM t GROUP BY ext ORDER BY n DESC, ext COLLATE \"C\" LIMIT 200) x), " ++
        "'splits', (SELECT coalesce(json_agg(json_build_object('name', split, 'count', n) ORDER BY split COLLATE \"C\"), '[]') " ++
        "   FROM (SELECT split, count(*) AS n FROM t WHERE split IS NOT NULL GROUP BY split) x), " ++
        "'visual', (SELECT coalesce(json_agg(h ORDER BY p COLLATE \"C\"), '[]') " ++
        "   FROM (SELECT encode(item_hash, 'hex') AS h, path AS p FROM t WHERE ext IN " ++ visual_types ++
        "   ORDER BY path COLLATE \"C\" LIMIT 4) x), " ++
        "'annotations', (SELECT count(*) FROM c), " ++
        "'classes', (SELECT coalesce(json_agg(json_build_object('name', class, 'count', n) ORDER BY class COLLATE \"C\"), '[]') " ++
        "   FROM (SELECT class, count(*) AS n FROM c WHERE class IS NOT NULL GROUP BY class ORDER BY class COLLATE \"C\" LIMIT 1000) x), " ++
        "'policy', (SELECT max(policy_ver COLLATE \"C\") FROM c))::text";
}

const stats_sql = "WITH " ++ live_cte ++ ", " ++ alive_cte ++
    ", live_sized AS (SELECT live.path, live.split, live.item_hash, i.size_bytes FROM live JOIN items i USING (item_hash)), " ++
    statsOver("live_sized", "alive");

/// Statistics already read from `commits.stats`, when they are current.
pub fn kept(arena: std.mem.Allocator, text: ?[]const u8) ?Stats {
    const t = text orelse return null;
    const st = std.json.parseFromSliceLeaky(Stats, arena, t, .{ .ignore_unknown_fields = true }) catch return null;
    return if (st.v == stats_version) st else null;
}

/// The version's statistics: from the commit when kept there, else
/// aggregated once and kept.
pub fn stats(arena: std.mem.Allocator, db: *dbx.sql.Db, scope: anytype, dataset_id: []const u8, commit_id: []const u8) Error!Stats {
    const stored = db.rawOne(?[]const u8, scope, "SELECT stats::text FROM commits WHERE commit_id = $1::uuid AND dataset_id = $2::uuid", .{ commit_id, dataset_id }) catch return error.Db;
    if (stored) |text| if (kept(arena, text)) |st| return st;
    const where = try at(db, scope, dataset_id, commit_id);
    const text = (db.rawOne([]const u8, scope, stats_sql, .{ dataset_id, where.branch, where.cutoff, where.main_cutoff }) catch return error.Db) orelse
        return error.Db;
    const st = std.json.parseFromSliceLeaky(Stats, arena, text, .{ .ignore_unknown_fields = true }) catch return error.Db;
    // A cache that failed to store is computed again next time.
    _ = db.exec(scope, "UPDATE commits SET stats = $2::jsonb WHERE commit_id = $1::uuid", .{ commit_id, text }) catch {};
    return st;
}

/// What changed from one version to another, counted: files by path
/// (added, modified when their bytes differ, deleted) and annotations by
/// id (added, changed when kind, class, shape or attributes differ,
/// removed). The same comparison `cid diff` and Compare make, counted in
/// Postgres in one statement so a release can keep it.
pub const Changes = struct {
    added: u64 = 0,
    modified: u64 = 0,
    deleted: u64 = 0,
    ann_added: u64 = 0,
    ann_changed: u64 = 0,
    ann_removed: u64 = 0,
};

/// Between two commits of one line of history (main, or one branch over
/// the same start) only what was written in between can differ, so the
/// comparison reads just those paths and annotations, by the lookup
/// indexes, instead of both whole versions: $8 is the branch, $9 and $10
/// the two cutoffs. A release costs about what its changes do.
const touched_filter_items = " AND path IN (SELECT path FROM item_revisions WHERE dataset_id = $1::uuid AND branch = $8 AND rev_id > $9::uuid AND rev_id <= $10::uuid)";
const touched_filter_anns = " AND annotation_id IN (SELECT annotation_id FROM annotation_revisions WHERE dataset_id = $1::uuid AND branch = $8 AND rev_id > $9::uuid AND rev_id <= $10::uuid)";

fn changesSql(comptime touched: bool) []const u8 {
    const items_f = if (touched) touched_filter_items else "";
    const anns_f = if (touched) touched_filter_anns else "";
    const two = struct {
        fn ctes(comptime p: []const u8, comptime br: []const u8, comptime cut: []const u8, comptime main: []const u8, comptime fi: []const u8, comptime fa: []const u8) []const u8 {
            const own = "WHERE dataset_id = $1::uuid AND ((branch = 'main' AND rev_id <= $" ++ main ++ "::uuid) OR (branch = $" ++ br ++ " AND rev_id <= $" ++ cut ++ "::uuid))";
            return p ++ "_s AS (SELECT DISTINCT ON (path) path, op, item_hash FROM item_revisions " ++ own ++ fi ++ " ORDER BY path, rev_id DESC), " ++
                p ++ "_live AS (SELECT path, item_hash FROM " ++ p ++ "_s WHERE op <> 'delete'), " ++
                p ++ "_a AS (SELECT DISTINCT ON (annotation_id) annotation_id, op, kind, class, geometry::text AS geometry, attrs::text AS attrs " ++
                "FROM annotation_revisions " ++ own ++ fa ++ " ORDER BY annotation_id, rev_id DESC), " ++
                p ++ "_alive AS (SELECT * FROM " ++ p ++ "_a WHERE op <> 'delete')";
        }
    }.ctes;
    return "WITH " ++ two("x", "2", "3", "4", items_f, anns_f) ++ ", " ++ two("y", "5", "6", "7", items_f, anns_f) ++ ", " ++
        "files AS (SELECT x_live.item_hash AS ha, y_live.item_hash AS hb FROM x_live FULL JOIN y_live USING (path)), " ++
        "anns AS (SELECT x_alive.annotation_id AS ia, y_alive.annotation_id AS ib, " ++
        "  (x_alive.kind, x_alive.class, x_alive.geometry, x_alive.attrs) IS DISTINCT FROM (y_alive.kind, y_alive.class, y_alive.geometry, y_alive.attrs) AS differs " ++
        "  FROM x_alive FULL JOIN y_alive USING (annotation_id)) " ++
        "SELECT json_build_object(" ++
        "'added', (SELECT count(*) FROM files WHERE ha IS NULL), " ++
        "'modified', (SELECT count(*) FROM files WHERE ha IS NOT NULL AND hb IS NOT NULL AND ha <> hb), " ++
        "'deleted', (SELECT count(*) FROM files WHERE hb IS NULL), " ++
        "'ann_added', (SELECT count(*) FROM anns WHERE ia IS NULL), " ++
        "'ann_changed', (SELECT count(*) FROM anns WHERE ia IS NOT NULL AND ib IS NOT NULL AND differs), " ++
        "'ann_removed', (SELECT count(*) FROM anns WHERE ib IS NULL))::text";
}

/// What changed from `from_commit` to `to_commit`, as JSON text (the
/// shape of `Changes`), for a caller that keeps it.
pub fn changes(db: *dbx.sql.Db, scope: anytype, dataset_id: []const u8, from_commit: []const u8, to_commit: []const u8) Error![]const u8 {
    const x = try at(db, scope, dataset_id, from_commit);
    const y = try at(db, scope, dataset_id, to_commit);
    const args = .{ dataset_id, x.branch, x.cutoff, x.main_cutoff, y.branch, y.cutoff, y.main_cutoff };
    // One line of history, read forward: only the window can differ.
    const one_line = std.mem.eql(u8, x.branch, y.branch) and
        (std.mem.eql(u8, x.branch, "main") or std.mem.eql(u8, x.main_cutoff, y.main_cutoff)) and
        std.mem.order(u8, x.cutoff, y.cutoff) != .gt;
    const text = if (one_line)
        db.rawOne([]const u8, scope, comptime changesSql(true), args ++ .{ x.branch, x.cutoff, y.cutoff }) catch return error.Db
    else
        db.rawOne([]const u8, scope, comptime changesSql(false), args) catch return error.Db;
    return text orelse error.Db;
}

/// The first `limit` items by path (the dataset repository's files.txt).
pub const Listed = struct {
    pub const nilo_table = .projection;
    path: []const u8,
    hash_hex: []const u8,
    size_bytes: i64,
};

pub fn firstItems(arena: std.mem.Allocator, db: *dbx.sql.Db, scope: anytype, dataset_id: []const u8, commit_id: []const u8, limit: u32) Error![]const Listed {
    _ = arena;
    const where = try at(db, scope, dataset_id, commit_id);
    return db.raw(Listed, scope, "WITH " ++ live_cte ++ " SELECT live.path, encode(live.item_hash, 'hex') AS hash_hex, i.size_bytes " ++
        "FROM live JOIN items i USING (item_hash) ORDER BY live.path COLLATE \"C\" LIMIT $5", .{ dataset_id, where.branch, where.cutoff, where.main_cutoff, @as(i64, limit) }) catch error.Db;
}

// ---------------------------------------------------------------------------
// Merging: only the paths a branch touched.
// ---------------------------------------------------------------------------

/// One path a branch touched: what the branch, the base (main at the
/// branch's start) and main now hold there — a hash, or null for absent.
pub const BranchPath = struct {
    pub const nilo_table = .projection;
    path: []const u8,
    theirs: ?[]const u8,
    theirs_size: ?i64,
    base: ?[]const u8,
    ours: ?[]const u8,
};

/// A branch is main up to its start plus its own revisions, so every path
/// it never touched is the base's by construction: a merge needs these
/// paths and no others. Bytewise by path.
pub fn branchPaths(
    db: *dbx.sql.Db,
    scope: anytype,
    dataset_id: []const u8,
    branch: []const u8,
    branch_cutoff: []const u8,
    start_cutoff: []const u8,
    main_cutoff: []const u8,
) Error![]BranchPath {
    return db.raw(BranchPath, scope, "WITH t AS (SELECT DISTINCT ON (path) path, op, item_hash FROM item_revisions " ++
        "  WHERE dataset_id = $1::uuid AND branch = $2 AND rev_id <= $3::uuid ORDER BY path, rev_id DESC), " ++
        "b AS (SELECT DISTINCT ON (r.path) r.path, r.op, r.item_hash FROM item_revisions r JOIN t USING (path) " ++
        "  WHERE r.dataset_id = $1::uuid AND r.branch = 'main' AND r.rev_id <= $4::uuid ORDER BY r.path, r.rev_id DESC), " ++
        "m AS (SELECT DISTINCT ON (r.path) r.path, r.op, r.item_hash FROM item_revisions r JOIN t USING (path) " ++
        "  WHERE r.dataset_id = $1::uuid AND r.branch = 'main' AND r.rev_id <= $5::uuid ORDER BY r.path, r.rev_id DESC) " ++
        "SELECT t.path, CASE WHEN t.op = 'delete' THEN NULL ELSE encode(t.item_hash, 'hex') END AS theirs, " ++
        "  i.size_bytes AS theirs_size, " ++
        "  CASE WHEN b.op IS NULL OR b.op = 'delete' THEN NULL ELSE encode(b.item_hash, 'hex') END AS base, " ++
        "  CASE WHEN m.op IS NULL OR m.op = 'delete' THEN NULL ELSE encode(m.item_hash, 'hex') END AS ours " ++
        "FROM t LEFT JOIN b USING (path) LEFT JOIN m USING (path) LEFT JOIN items i ON i.item_hash = t.item_hash " ++
        "ORDER BY t.path COLLATE \"C\"", .{ dataset_id, branch, branch_cutoff, start_cutoff, main_cutoff }) catch error.Db;
}
