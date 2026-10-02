//! The browse engine (docs/dashboard.md §4.3 and "Browse API"): each version kept as a browse index — its items in path
//! order, its annotations by item, two Parquet files — and every question
//! the dashboard and the CLI ask of versions answered by one DuckDB query
//! over them:
//!
//!   page        one page of items with their annotations, the counts, the
//!               facets (each counted against every *other* filter), a cursor
//!   size        how many items and bytes a subset (splits × classes) holds
//!   dir         one folder's subfolders (counted) and files (paged)
//!   compare     what changed between two versions: items and annotations,
//!               as a page for the dashboard or as lines for `cid diff`
//!
//! An index holds only what the sealed commit fixes: paths, hashes,
//! sizes, splits and annotations. Media metadata (an image's dimensions)
//! arrives later, when the preview worker sniffs the bytes, so it is
//! joined per page by the caller, never frozen into an index. Paths order
//! bytewise, so a cursor is a path. Every request value is a bound
//! parameter, never SQL.

const std = @import("std");
const duck = @import("../../store/duck.zig");

pub const default_limit = 60;
pub const max_limit = 200;

/// What a browse request asks; null means "not filtered by this".
pub const Query = struct {
    q: ?[]const u8 = null,
    split: ?[]const u8 = null,
    class: ?[]const u8 = null,
    type: ?[]const u8 = null,
    /// The cursor: the last path of the previous page.
    after: ?[]const u8 = null,
    limit: u32 = default_limit,
    /// The open item's path, answered beside the page (it may be on no
    /// page loaded yet: a shared link opens straight onto it).
    item: ?[]const u8 = null,
};

pub const Ann = struct {
    id: []const u8,
    item_id: []const u8,
    kind: ?[]const u8,
    class: ?[]const u8,
    geometry: ?std.json.Value,
    attrs: ?std.json.Value,
    author: []const u8,
    policy_ver: []const u8,
};

/// An item as the dashboard holds it: the state item, plus its
/// annotations at this version.
pub const Item = struct {
    path: []const u8,
    hash: []const u8,
    size: u64,
    split: ?[]const u8,
    item_id: ?[]const u8,
    /// Filled per page from the items' metadata (see the top of the file).
    width: ?u32 = null,
    height: ?u32 = null,
    annotations: []const Ann,
};

pub const Facet = struct { value: []const u8, count: u64 };

pub const Facets = struct { split: []Facet, class: []Facet, type: []Facet };

pub const Answer = struct {
    total: u64,
    matched: u64,
    items: []const Item,
    next: ?[]const u8,
    open: ?Item,
    facets: Facets,
    /// Annotations per class across the whole version (the overlay chips).
    classes: []Facet,
};

pub const Error = error{ OutOfMemory, QueryFailed, OpenFailed, WriteFailed };

/// DuckDB threads for one browse query: two halve an unfiltered page at
/// 1M items (0.48 s to 0.27 s); index builds keep to one.
pub const query_threads = 2;

/// What one place in the dashboard calls "the answer": facets ordered,
/// active filters kept listed.
fn finish(arena: std.mem.Allocator, answer: Answer, q: Query) !Answer {
    var a = answer;
    a.facets.split = try keepActive(arena, a.facets.split, q.split);
    a.facets.class = try keepActive(arena, a.facets.class, q.class);
    a.facets.type = try keepActive(arena, a.facets.type, q.type);
    inline for (.{ a.facets.split, a.facets.class, a.facets.type }) |list| std.mem.sort(Facet, list, {}, byCount);
    std.mem.sort(Facet, a.classes, {}, byValue);
    return a;
}

fn keepActive(arena: std.mem.Allocator, list: []Facet, active: ?[]const u8) ![]Facet {
    const want = active orelse return list;
    for (list) |f| if (std.mem.eql(u8, f.value, want)) return list;
    const out = try arena.alloc(Facet, list.len + 1);
    @memcpy(out[0..list.len], list);
    out[list.len] = .{ .value = want, .count = 0 };
    return out;
}

fn byCount(_: void, a: Facet, b: Facet) bool {
    if (a.count != b.count) return a.count > b.count;
    return std.mem.lessThan(u8, a.value, b.value);
}

fn byValue(_: void, a: Facet, b: Facet) bool {
    return std.mem.lessThan(u8, a.value, b.value);
}

// ---------------------------------------------------------------------------
// The DuckDB engine: a Parquet index per version, one query per request.
// ---------------------------------------------------------------------------

/// A version's browse index: its items in path order, and its annotations
/// by item, as two Parquet files — and the JSON lines they are made from.
/// Annotations are never nested into item rows: building that nesting
/// cost Postgres 15 s at 1M items, and a page needs at most 200 items'.
pub const Files = struct {
    items_lines: []const u8,
    ann_lines: []const u8,
    items: []const u8,
    anns: []const u8,

    pub fn of(arena: std.mem.Allocator, dir: []const u8, name: []const u8) Error!Files {
        return .{
            .items_lines = try std.fmt.allocPrint(arena, "{s}/{s}.items.jsonl", .{ dir, name }),
            .ann_lines = try std.fmt.allocPrint(arena, "{s}/{s}.anns.jsonl", .{ dir, name }),
            .items = try std.fmt.allocPrint(arena, "{s}/{s}.items.parquet", .{ dir, name }),
            .anns = try std.fmt.allocPrint(arena, "{s}/{s}.anns.parquet", .{ dir, name }),
        };
    }

    /// The same index, with working files of this build's own: servers
    /// sharing a browse folder may build the same version at once, and
    /// only the final rename into place may be shared, never a file one is
    /// still writing (one truncating the other's lines left an empty index).
    pub fn forBuild(self: Files, arena: std.mem.Allocator, io: std.Io) error{OutOfMemory}!Files {
        var token: [8]u8 = undefined;
        io.random(&token);
        var copy = self;
        copy.items_lines = try std.fmt.allocPrint(arena, "{s}.{x}", .{ self.items_lines, &token });
        copy.ann_lines = try std.fmt.allocPrint(arena, "{s}.{x}", .{ self.ann_lines, &token });
        return copy;
    }
};

/// The lines → the two Parquet files, each renamed into place when
/// complete, annotations first: an index exists once its items file does.
/// The lines are removed either way. `db` must be confined to their
/// folder; one thread keeps the conversion near 250 MB at 1M items.
pub fn convertIndex(arena: std.mem.Allocator, io: std.Io, db: *duck.Db, files: Files) Error!void {
    const cwd = std.Io.Dir.cwd();
    defer cwd.deleteFile(io, files.items_lines) catch {};
    defer cwd.deleteFile(io, files.ann_lines) catch {};
    const steps = [_]struct { lines: []const u8, out: []const u8, columns: []const u8 }{
        .{ .lines = files.ann_lines, .out = files.anns, .columns = "id: 'VARCHAR', item_id: 'VARCHAR', kind: 'VARCHAR', class: 'VARCHAR', " ++
            "geometry: 'JSON', attrs: 'JSON', author: 'VARCHAR', policy_ver: 'VARCHAR'" },
        .{ .lines = files.items_lines, .out = files.items, .columns = "path: 'VARCHAR', hash: 'VARCHAR', size: 'BIGINT', split: 'VARCHAR', " ++
            "item_id: 'VARCHAR', ext: 'VARCHAR', classes: 'VARCHAR[]'" },
    };
    for (steps) |step| {
        // Named after this build's lines, so no other build writes it.
        const tmp = try std.fmt.allocPrint(arena, "{s}.parquet.tmp", .{step.lines});
        defer cwd.deleteFile(io, tmp) catch {};
        _ = try db.scalarText(arena, try std.fmt.allocPrint(arena, "COPY (SELECT * FROM read_json('{s}', format = 'newline_delimited', columns = {{{s}}})) TO '{s}' (FORMAT parquet)", .{ step.lines, step.columns, tmp }));
        std.Io.Dir.rename(cwd, tmp, cwd, step.out, io) catch return error.WriteFailed;
    }
}

fn quote(arena: std.mem.Allocator, path: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (path) |ch| {
        if (ch == '\'') try out.append(arena, '\'');
        try out.append(arena, ch);
    }
    return out.items;
}

/// The contract, answered from the index (inside the folder `db` is
/// confined to). Every request value is a bound parameter.
pub fn queryIndex(arena: std.mem.Allocator, db: *duck.Db, files: Files, q: Query) Error!Answer {
    // Paths are the server's own (a commit id under its cache folder),
    // never the request's; quoted all the same.
    const items = try quote(arena, files.items);
    const anns = try quote(arena, files.anns);
    // Filters and facets read only the light columns of every row; the
    // page's rows alone (and the open item) are read whole, with their
    // annotations. Shared CTEs are materialized, so carrying heavy
    // columns through them would cost seconds at 1M items.
    const sql = try std.fmt.allocPrint(arena,
        \\WITH m AS (SELECT path, split, ext, classes,
        \\    ($1::VARCHAR IS NULL OR contains(lower(path), lower($1::VARCHAR))) AS fq,
        \\    ($2::VARCHAR IS NULL OR coalesce(split, '') = $2::VARCHAR) AS fs,
        \\    ($3::VARCHAR IS NULL OR list_contains(classes, $3::VARCHAR)) AS fc,
        \\    ($4::VARCHAR IS NULL OR ext = $4::VARCHAR) AS ft
        \\  FROM read_parquet('{0s}')),
        \\sel AS (SELECT path FROM m WHERE fq AND fs AND fc AND ft),
        \\page AS (SELECT path FROM sel WHERE $5::VARCHAR IS NULL OR path > $5::VARCHAR ORDER BY path LIMIT $6),
        \\last AS (SELECT max(path) AS p, count(*) AS n FROM page),
        \\whole AS (SELECT path, hash, size, split, item_id FROM read_parquet('{0s}') WHERE path IN (SELECT path FROM page)),
        \\opened AS (SELECT path, hash, size, split, item_id FROM read_parquet('{0s}') WHERE path = $7::VARCHAR LIMIT 1),
        \\boxes AS (SELECT item_id, to_json(list(json_object('id', id, 'item_id', item_id, 'kind', kind, 'class', class,
        \\      'geometry', geometry, 'attrs', attrs, 'author', author, 'policy_ver', policy_ver) ORDER BY id)) AS j
        \\  FROM read_parquet('{1s}')
        \\  WHERE item_id IN (SELECT item_id FROM whole UNION ALL SELECT item_id FROM opened) GROUP BY item_id)
        \\SELECT json_object(
        \\  'total', (SELECT count(*) FROM m),
        \\  'matched', (SELECT count(*) FROM sel),
        \\  'items', (SELECT coalesce(to_json(list(json_object('path', w.path, 'hash', w.hash, 'size', w.size, 'split', w.split,
        \\      'item_id', w.item_id, 'annotations', coalesce(b.j, '[]'::JSON)) ORDER BY w.path)), '[]'::JSON)
        \\      FROM whole w LEFT JOIN boxes b USING (item_id)),
        \\  'next', (SELECT CASE WHEN n = $6 AND EXISTS (SELECT 1 FROM sel WHERE sel.path > last.p) THEN p END FROM last),
        \\  'open', (SELECT json_object('path', o.path, 'hash', o.hash, 'size', o.size, 'split', o.split,
        \\      'item_id', o.item_id, 'annotations', coalesce(b.j, '[]'::JSON)) FROM opened o LEFT JOIN boxes b USING (item_id)),
        \\  'split', (SELECT coalesce(json_group_array(json_object('value', v, 'count', n)), '[]'::JSON)
        \\      FROM (SELECT coalesce(split, '') AS v, count(*) AS n FROM m WHERE fq AND fc AND ft GROUP BY 1)),
        \\  'class', (SELECT coalesce(json_group_array(json_object('value', v, 'count', n)), '[]'::JSON)
        \\      FROM (SELECT v, count(*) AS n FROM (SELECT unnest(list_distinct(classes)) AS v FROM m WHERE fq AND fs AND ft) GROUP BY 1)),
        \\  'type', (SELECT coalesce(json_group_array(json_object('value', v, 'count', n)), '[]'::JSON)
        \\      FROM (SELECT ext AS v, count(*) AS n FROM m WHERE fq AND fs AND fc GROUP BY 1)),
        \\  'classes', (SELECT coalesce(json_group_array(json_object('value', v, 'count', n)), '[]'::JSON)
        \\      FROM (SELECT v, count(*) AS n FROM (SELECT unnest(classes) AS v FROM m) GROUP BY 1))
        \\)::VARCHAR
    , .{ items, anns });

    const text = (try db.scalarTextArgs(arena, sql, &.{
        .{ .text = q.q },
        .{ .text = q.split },
        .{ .text = q.class },
        .{ .text = q.type },
        .{ .text = q.after },
        .{ .int = q.limit },
        .{ .text = q.item },
    })) orelse return error.QueryFailed;

    const Raw = struct {
        total: u64,
        matched: u64,
        items: []const Item,
        next: ?[]const u8,
        open: ?Item,
        split: []Facet,
        class: []Facet,
        type: []Facet,
        classes: []Facet,
    };
    const raw = std.json.parseFromSliceLeaky(Raw, arena, text, .{ .ignore_unknown_fields = true }) catch
        return error.QueryFailed;
    return finish(arena, .{
        .total = raw.total,
        .matched = raw.matched,
        .items = raw.items,
        .next = raw.next,
        .open = raw.open,
        .facets = .{ .split = raw.split, .class = raw.class, .type = raw.type },
        .classes = raw.classes,
    }, q);
}

// ---------------------------------------------------------------------------
// Subset size, folder listing, compare.
// ---------------------------------------------------------------------------

/// How much of a version a clone with `--split`/`--class` would take:
/// items in any of `splits` (none given: every item, split or not) that
/// carry at least one of `classes` (none given: all), with their bytes.
pub const Size = struct { items: u64, bytes: u64, total: u64 };

pub fn subsetSize(arena: std.mem.Allocator, db: *duck.Db, files: Files, splits: []const []const u8, classes: []const []const u8) Error!Size {
    const sql = try std.fmt.allocPrint(arena,
        \\SELECT json_object('items', count(*) FILTER (WHERE kept), 'bytes', coalesce(sum(size) FILTER (WHERE kept), 0), 'total', count(*))::VARCHAR
        \\FROM (SELECT size,
        \\  (len(from_json($1::VARCHAR, '["VARCHAR"]')) = 0 OR (split IS NOT NULL AND list_contains(from_json($1::VARCHAR, '["VARCHAR"]'), split)))
        \\  AND (len(from_json($2::VARCHAR, '["VARCHAR"]')) = 0 OR list_has_any(classes, from_json($2::VARCHAR, '["VARCHAR"]'))) AS kept
        \\  FROM read_parquet('{s}'))
    , .{try quote(arena, files.items)});
    const text = (try db.scalarTextArgs(arena, sql, &.{
        .{ .text = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(splits, .{})}) },
        .{ .text = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(classes, .{})}) },
    })) orelse return error.QueryFailed;
    return std.json.parseFromSliceLeaky(Size, arena, text, .{}) catch error.QueryFailed;
}

/// One folder of a version: its subfolders, each with the items and bytes
/// under it (at most `max_folders`, by name), and a page of the files
/// directly in it, by path. `prefix` is "" for the top, else ends in '/'.
pub const max_folders = 1000;

pub const Listing = struct {
    folders: []const struct { name: []const u8, items: u64, bytes: u64 },
    folders_total: u64,
    files: []const struct { path: []const u8, size: u64, hash: []const u8 },
    files_total: u64,
    next: ?[]const u8,
};

pub fn listDir(arena: std.mem.Allocator, db: *duck.Db, files: Files, prefix: []const u8, after: ?[]const u8, limit: u32) Error!Listing {
    const sql = try std.fmt.allocPrint(arena,
        \\WITH under AS (SELECT path, size, hash, substr(path, length($1::VARCHAR) + 1) AS rest
        \\  FROM read_parquet('{s}') WHERE starts_with(path, $1::VARCHAR)),
        \\folders AS (SELECT split_part(rest, '/', 1) AS name, count(*) AS items, sum(size) AS bytes
        \\  FROM under WHERE contains(rest, '/') GROUP BY 1),
        \\here AS (SELECT path, size, hash FROM under WHERE NOT contains(rest, '/')),
        \\page AS (SELECT * FROM here WHERE $2::VARCHAR IS NULL OR path > $2::VARCHAR ORDER BY path LIMIT $3),
        \\last AS (SELECT max(path) AS p, count(*) AS n FROM page)
        \\SELECT json_object(
        \\  'folders', (SELECT coalesce(to_json(list(json_object('name', name, 'items', items, 'bytes', bytes) ORDER BY name)), '[]'::JSON)
        \\     FROM (SELECT * FROM folders ORDER BY name LIMIT {d})),
        \\  'folders_total', (SELECT count(*) FROM folders),
        \\  'files', (SELECT coalesce(to_json(list(json_object('path', path, 'size', size, 'hash', hash) ORDER BY path)), '[]'::JSON) FROM page),
        \\  'files_total', (SELECT count(*) FROM here),
        \\  'next', (SELECT CASE WHEN n = $3 AND EXISTS (SELECT 1 FROM here WHERE here.path > last.p) THEN p END FROM last)
        \\)::VARCHAR
    , .{ try quote(arena, files.items), max_folders });
    const text = (try db.scalarTextArgs(arena, sql, &.{ .{ .text = prefix }, .{ .text = after }, .{ .int = limit } })) orelse return error.QueryFailed;
    return std.json.parseFromSliceLeaky(Listing, arena, text, .{ .ignore_unknown_fields = true }) catch error.QueryFailed;
}

pub const DiffSummary = struct {
    added: u64 = 0,
    modified: u64 = 0,
    deleted: u64 = 0,
    ann_added: u64 = 0,
    ann_changed: u64 = 0,
    ann_removed: u64 = 0,
};

/// The joins every compare shares, after WITH: `ch` (items whose bytes
/// differ, by path), `acp` (annotations added, removed, or changed in
/// kind, class, geometry or attributes, with their item's path and both
/// versions of the shape). Geometry compares as stored text, which
/// Postgres normalized from jsonb, so formatting never counts.
fn compareCtes(arena: std.mem.Allocator, a: Files, b: Files) Error![]const u8 {
    return std.fmt.allocPrint(arena,
        \\ia AS (SELECT path, hash, size, item_id FROM read_parquet('{0s}')),
        \\ib AS (SELECT path, hash, size, item_id FROM read_parquet('{1s}')),
        \\ch AS (SELECT coalesce(x.path, y.path) AS path,
        \\    CASE WHEN x.path IS NULL THEN 'added' WHEN y.path IS NULL THEN 'deleted' ELSE 'modified' END AS change,
        \\    x.hash AS hash_a, y.hash AS hash_b, x.size AS size_a, y.size AS size_b
        \\  FROM ia x FULL JOIN ib y USING (path) WHERE x.hash IS DISTINCT FROM y.hash),
        \\ac AS (SELECT coalesce(x.id, y.id) AS id,
        \\    CASE WHEN x.id IS NULL THEN 'added' WHEN y.id IS NULL THEN 'removed' ELSE 'changed' END AS change,
        \\    coalesce(y.kind, x.kind) AS kind, coalesce(y.class, x.class) AS class,
        \\    coalesce(y.item_id, x.item_id) AS item,
        \\    CASE WHEN x.id IS NULL THEN NULL ELSE json_object('id', x.id, 'item_id', x.item_id, 'kind', x.kind, 'class', x.class,
        \\      'geometry', x.geometry, 'attrs', x.attrs, 'author', x.author, 'policy_ver', x.policy_ver) END AS before,
        \\    CASE WHEN y.id IS NULL THEN NULL ELSE json_object('id', y.id, 'item_id', y.item_id, 'kind', y.kind, 'class', y.class,
        \\      'geometry', y.geometry, 'attrs', y.attrs, 'author', y.author, 'policy_ver', y.policy_ver) END AS after
        \\  FROM read_parquet('{2s}') x FULL JOIN read_parquet('{3s}') y USING (id)
        \\  WHERE x.id IS NULL OR y.id IS NULL OR x.kind IS DISTINCT FROM y.kind OR x.class IS DISTINCT FROM y.class
        \\    OR x.geometry::VARCHAR IS DISTINCT FROM y.geometry::VARCHAR OR x.attrs::VARCHAR IS DISTINCT FROM y.attrs::VARCHAR),
        \\acp AS (SELECT ac.*, coalesce(yi.path, xi.path) AS item_path
        \\  FROM ac LEFT JOIN ib yi ON yi.item_id = ac.item LEFT JOIN ia xi ON xi.item_id = ac.item)
    , .{ try quote(arena, a.items), try quote(arena, b.items), try quote(arena, a.anns), try quote(arena, b.anns) });
}

/// The dashboard's compare: the summary, a page of item changes by path,
/// and — on the first page — the visual diff: the first `visual_items`
/// items an annotation changed on, by path, each at both versions with
/// its changed shapes before and after.
pub const visual_items = 60;

pub const VisualSide = struct { path: []const u8, hash: []const u8, item_id: ?[]const u8 = null, width: ?u32 = null, height: ?u32 = null };

pub const ComparePage = struct {
    summary: DiffSummary,
    changes: []const struct { change: []const u8, path: []const u8, hash_a: ?[]const u8, hash_b: ?[]const u8, size_b: ?u64 },
    next: ?[]const u8,
    visual: []const struct {
        path: []const u8,
        before: ?VisualSide,
        after: ?VisualSide,
        shapes_before: []const Ann,
        shapes_after: []const Ann,
    },
    /// The first annotation changes, by item path (first page only).
    ann_changes: []const struct { change: []const u8, kind: ?[]const u8, class: ?[]const u8, item_path: ?[]const u8 },
};

/// A pair's diff, computed once and kept (both versions are sealed): the
/// changed items by path, and the changed annotations by item path, each
/// with its shape before and after. Every compare reads these — a page,
/// or every line for `cid diff` — so the whole-version joins run once.
pub const DiffFiles = struct {
    items: []const u8,
    anns: []const u8,

    pub fn of(arena: std.mem.Allocator, dir: []const u8, a: []const u8, b: []const u8) Error!DiffFiles {
        return .{
            .items = try std.fmt.allocPrint(arena, "{s}/{s}-{s}.diff-items.parquet", .{ dir, a, b }),
            .anns = try std.fmt.allocPrint(arena, "{s}/{s}-{s}.diff-anns.parquet", .{ dir, a, b }),
        };
    }
};

/// Joins the two versions' indexes into the pair's diff files, each
/// renamed into place when complete, annotations first: a diff exists
/// once its items file does. `db` must be confined to their folder.
pub fn buildDiff(arena: std.mem.Allocator, io: std.Io, db: *duck.Db, a: Files, b: Files, out: DiffFiles) Error!void {
    const cwd = std.Io.Dir.cwd();
    const ctes = try compareCtes(arena, a, b);
    const steps = [_]struct { out: []const u8, select: []const u8 }{
        .{ .out = out.anns, .select = "SELECT change, id, kind, class, item, item_path, before, after FROM acp ORDER BY item_path, id" },
        .{ .out = out.items, .select = "SELECT change, path, hash_a, hash_b, size_a, size_b FROM ch ORDER BY path" },
    };
    var token: [8]u8 = undefined;
    io.random(&token);
    for (steps) |step| {
        // This build's own temp name: another server may diff the same
        // pair at once, and only the rename into place is shared.
        const tmp = try std.fmt.allocPrint(arena, "{s}.{x}.tmp", .{ step.out, &token });
        defer cwd.deleteFile(io, tmp) catch {};
        _ = try db.scalarText(arena, try std.fmt.allocPrint(arena, "COPY (WITH {s} {s}) TO '{s}' (FORMAT parquet)", .{ ctes, step.select, try quote(arena, tmp) }));
        std.Io.Dir.rename(cwd, tmp, cwd, step.out, io) catch return error.WriteFailed;
    }
}

fn summaryOf(arena: std.mem.Allocator, d: DiffFiles) Error![]const u8 {
    return std.fmt.allocPrint(arena,
        \\json_object('added', (SELECT count(*) FROM read_parquet('{0s}') WHERE change = 'added'),
        \\  'modified', (SELECT count(*) FROM read_parquet('{0s}') WHERE change = 'modified'),
        \\  'deleted', (SELECT count(*) FROM read_parquet('{0s}') WHERE change = 'deleted'),
        \\  'ann_added', (SELECT count(*) FROM read_parquet('{1s}') WHERE change = 'added'),
        \\  'ann_changed', (SELECT count(*) FROM read_parquet('{1s}') WHERE change = 'changed'),
        \\  'ann_removed', (SELECT count(*) FROM read_parquet('{1s}') WHERE change = 'removed'))
    , .{ try quote(arena, d.items), try quote(arena, d.anns) });
}

pub fn comparePage(arena: std.mem.Allocator, db: *duck.Db, a: Files, b: Files, d: DiffFiles, after: ?[]const u8, limit: u32) Error!ComparePage {
    const sql = try std.fmt.allocPrint(arena,
        \\WITH ch AS (SELECT * FROM read_parquet('{0s}')),
        \\acp AS (SELECT * FROM read_parquet('{1s}')),
        \\page AS (SELECT * FROM ch WHERE $1::VARCHAR IS NULL OR path > $1::VARCHAR ORDER BY path LIMIT $2),
        \\last AS (SELECT max(path) AS p, count(*) AS n FROM page),
        \\vis AS (SELECT item, min(item_path) AS item_path FROM acp WHERE $1::VARCHAR IS NULL GROUP BY item ORDER BY 2 LIMIT {4d}),
        \\sa AS (SELECT path, hash, item_id FROM read_parquet('{2s}') WHERE item_id IN (SELECT item FROM vis)),
        \\sb AS (SELECT path, hash, item_id FROM read_parquet('{3s}') WHERE item_id IN (SELECT item FROM vis))
        \\SELECT json_object(
        \\  'summary', {5s},
        \\  'changes', (SELECT coalesce(to_json(list(json_object('change', change, 'path', path, 'hash_a', hash_a, 'hash_b', hash_b, 'size_b', size_b) ORDER BY path)), '[]'::JSON) FROM page),
        \\  'next', (SELECT CASE WHEN n = $2 AND EXISTS (SELECT 1 FROM ch WHERE ch.path > last.p) THEN p END FROM last),
        \\  'visual', (SELECT coalesce(to_json(list(json_object('path', v.item_path,
        \\      'before', (SELECT json_object('path', path, 'hash', hash, 'item_id', item_id) FROM sa WHERE sa.item_id = v.item LIMIT 1),
        \\      'after', (SELECT json_object('path', path, 'hash', hash, 'item_id', item_id) FROM sb WHERE sb.item_id = v.item LIMIT 1),
        \\      'shapes_before', (SELECT coalesce(to_json(list(before ORDER BY id) FILTER (WHERE before IS NOT NULL)), '[]'::JSON) FROM acp WHERE acp.item = v.item),
        \\      'shapes_after', (SELECT coalesce(to_json(list(after ORDER BY id) FILTER (WHERE after IS NOT NULL)), '[]'::JSON) FROM acp WHERE acp.item = v.item))
        \\    ORDER BY v.item_path)), '[]'::JSON) FROM vis v),
        \\  'ann_changes', (SELECT coalesce(to_json(list(json_object('change', change, 'kind', kind, 'class', class, 'item_path', item_path)
        \\      ORDER BY item_path, id)), '[]'::JSON)
        \\    FROM (SELECT * FROM acp WHERE $1::VARCHAR IS NULL ORDER BY item_path, id LIMIT {6d}))
        \\)::VARCHAR
    , .{ try quote(arena, d.items), try quote(arena, d.anns), try quote(arena, a.items), try quote(arena, b.items), visual_items, try summaryOf(arena, d), max_limit });
    const text = (try db.scalarTextArgs(arena, sql, &.{ .{ .text = after }, .{ .int = limit } })) orelse return error.QueryFailed;
    return std.json.parseFromSliceLeaky(ComparePage, arena, text, .{ .ignore_unknown_fields = true }) catch error.QueryFailed;
}

/// The CLI's compare: every change, as two JSON-lines files DuckDB writes
/// in its folder (items by path; annotations by item path and id) from
/// the pair's diff, and the summary. The caller turns the files into the
/// diff `cid diff` reads.
pub const CompareFiles = struct { items: []const u8, anns: []const u8 };

pub fn compareLines(arena: std.mem.Allocator, db: *duck.Db, d: DiffFiles, out: CompareFiles) Error!DiffSummary {
    _ = try db.scalarText(arena, try std.fmt.allocPrint(arena, "COPY (SELECT change, path, hash_a, hash_b, size_a, size_b FROM read_parquet('{s}') ORDER BY path) TO '{s}' (FORMAT json)", .{ try quote(arena, d.items), try quote(arena, out.items) }));
    _ = try db.scalarText(arena, try std.fmt.allocPrint(arena, "COPY (SELECT change AS ann, id, kind, class, item_path FROM read_parquet('{s}') ORDER BY item_path, id) TO '{s}' (FORMAT json)", .{ try quote(arena, d.anns), try quote(arena, out.anns) }));
    const text = (try db.scalarText(arena, try std.fmt.allocPrint(arena, "SELECT {s}::VARCHAR", .{try summaryOf(arena, d)}))) orelse return error.QueryFailed;
    return std.json.parseFromSliceLeaky(DiffSummary, arena, text, .{}) catch error.QueryFailed;
}

// ---------------------------------------------------------------------------

/// A small annotated version, as index lines: three items in two splits,
/// one without an extension, boxes of two classes, one with no class.
const fixture_items =
    \\{"path":"README","hash":"dd","size":4,"split":null,"item_id":null,"ext":"file","classes":[]}
    \\{"path":"img/a.jpg","hash":"aa","size":1,"split":"train","item_id":"i1","ext":".jpg","classes":["person","person"]}
    \\{"path":"img/b.JPG","hash":"bb","size":2,"split":"train","item_id":"i2","ext":".jpg","classes":["car"]}
    \\{"path":"img/c.png","hash":"cc","size":3,"split":"val","item_id":"i3","ext":".png","classes":[""]}
    \\
;
const fixture_anns =
    \\{"id":"x1","item_id":"i1","kind":"box","class":"person","geometry":{"x":1,"y":2,"w":3,"h":4},"attrs":null,"author":"agent","policy_ver":"p1"}
    \\{"id":"x2","item_id":"i1","kind":"box","class":"person","geometry":{"x":0,"y":0,"w":1,"h":1},"attrs":null,"author":"agent","policy_ver":"p1"}
    \\{"id":"x3","item_id":"i2","kind":"box","class":"car","geometry":null,"attrs":{"occluded":true},"author":"agent","policy_ver":"p1"}
    \\{"id":"x4","item_id":"i3","kind":"point","class":null,"geometry":null,"attrs":null,"author":"user:r","policy_ver":"p1"}
    \\
;

fn writeFixture(arena: std.mem.Allocator, io: std.Io, db: *duck.Db, dir: []const u8, name: []const u8, items: []const u8, anns: []const u8) !Files {
    const files = try Files.of(arena, dir, name);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = files.items_lines, .data = items });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = files.ann_lines, .data = anns });
    try convertIndex(arena, io, db, files);
    return files;
}

fn countOf(list: []const Facet, value: []const u8) ?u64 {
    for (list) |f| if (std.mem.eql(u8, f.value, value)) return f.count;
    return null;
}

test "browse: pages, facets, cursor, the open item, sizes, folders and compare" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", arena);
    var db = try duck.Db.open(arena, .{ .allowed_dir = dir });
    defer db.close();
    const v1 = try writeFixture(arena, io, &db, dir, "v1", fixture_items, fixture_anns);

    // Everything: bytewise path order (uppercase sorts first), counts,
    // facets and the class chips.
    const all = try queryIndex(arena, &db, v1, .{});
    try std.testing.expectEqual(@as(u64, 4), all.total);
    try std.testing.expectEqualStrings("README", all.items[0].path);
    try std.testing.expectEqualStrings("img/a.jpg", all.items[1].path);
    try std.testing.expect(all.next == null);
    try std.testing.expectEqual(@as(?u64, 2), countOf(all.facets.split, "train"));
    try std.testing.expectEqual(@as(?u64, 1), countOf(all.facets.split, ""));
    try std.testing.expectEqual(@as(?u64, 2), countOf(all.facets.type, ".jpg"));
    try std.testing.expectEqual(@as(?u64, 1), countOf(all.facets.class, "person")); // items, not boxes
    try std.testing.expectEqualStrings("train", all.facets.split[0].value); // biggest first
    try std.testing.expectEqualStrings("", all.classes[0].value); // chips by name
    try std.testing.expectEqual(@as(?u64, 2), countOf(all.classes, "person")); // boxes, not items
    try std.testing.expectEqual(@as(usize, 2), all.items[1].annotations.len);
    try std.testing.expectEqual(@as(i64, 3), all.items[1].annotations[0].geometry.?.object.get("w").?.integer);

    // Each facet counts against the other filters, never its own.
    const train = try queryIndex(arena, &db, v1, .{ .split = "train" });
    try std.testing.expectEqual(@as(u64, 2), train.matched);
    try std.testing.expectEqual(@as(?u64, 1), countOf(train.facets.split, "val"));
    try std.testing.expectEqual(@as(?u64, null), countOf(train.facets.class, ""));
    const cars = try queryIndex(arena, &db, v1, .{ .class = "car", .q = "IMG/" });
    try std.testing.expectEqualStrings("img/b.JPG", cars.items[0].path);
    // An active value with no match stays listed, at zero.
    const none = try queryIndex(arena, &db, v1, .{ .type = ".wav" });
    try std.testing.expectEqual(@as(?u64, 0), countOf(none.facets.type, ".wav"));
    // The cursor walks every match exactly once.
    var seen: usize = 0;
    var after: ?[]const u8 = null;
    while (true) {
        const page = try queryIndex(arena, &db, v1, .{ .limit = 3, .after = after });
        seen += page.items.len;
        after = page.next orelse break;
    }
    try std.testing.expectEqual(@as(usize, 4), seen);
    // The open item comes with any page, whatever the filters.
    const open = try queryIndex(arena, &db, v1, .{ .split = "val", .item = "README" });
    try std.testing.expectEqualStrings("README", open.open.?.path);
    // A hostile filter is a value, not SQL.
    try std.testing.expectEqual(@as(u64, 0), (try queryIndex(arena, &db, v1, .{ .q = "'); DROP TABLE x; --" })).matched);

    // Subset sizes: splits × classes, as `cid clone --split --class` keeps.
    const everything = try subsetSize(arena, &db, v1, &.{}, &.{});
    try std.testing.expectEqual(Size{ .items = 4, .bytes = 10, .total = 4 }, everything);
    try std.testing.expectEqual(Size{ .items = 2, .bytes = 3, .total = 4 }, try subsetSize(arena, &db, v1, &.{"train"}, &.{}));
    try std.testing.expectEqual(Size{ .items = 1, .bytes = 2, .total = 4 }, try subsetSize(arena, &db, v1, &.{ "train", "val" }, &.{"car"}));

    // Folders: the top holds README and one folder of three.
    const top = try listDir(arena, &db, v1, "", null, 100);
    try std.testing.expectEqual(@as(usize, 1), top.folders.len);
    try std.testing.expectEqualStrings("img", top.folders[0].name);
    try std.testing.expectEqual(@as(u64, 3), top.folders[0].items);
    try std.testing.expectEqual(@as(u64, 6), top.folders[0].bytes);
    try std.testing.expectEqualStrings("README", top.files[0].path);
    const img = try listDir(arena, &db, v1, "img/", null, 2);
    try std.testing.expectEqual(@as(u64, 3), img.files_total);
    try std.testing.expectEqualStrings("img/b.JPG", img.next.?);
    const rest = try listDir(arena, &db, v1, "img/", img.next, 2);
    try std.testing.expectEqualStrings("img/c.png", rest.files[0].path);

    // Compare: README gone, a.jpg's bytes changed, d.txt new; box x1
    // moved, x3 removed, x5 added on b.JPG.
    const v2 = try writeFixture(arena, io, &db, dir, "v2",
        \\{"path":"d.txt","hash":"ee","size":5,"split":null,"item_id":null,"ext":".txt","classes":[]}
        \\{"path":"img/a.jpg","hash":"a2","size":1,"split":"train","item_id":"i1","ext":".jpg","classes":["person","person"]}
        \\{"path":"img/b.JPG","hash":"bb","size":2,"split":"train","item_id":"i2","ext":".jpg","classes":["car"]}
        \\{"path":"img/c.png","hash":"cc","size":3,"split":"val","item_id":"i3","ext":".png","classes":[""]}
        \\
    ,
        \\{"id":"x1","item_id":"i1","kind":"box","class":"person","geometry":{"y":2,"x":9,"h":4,"w":3},"attrs":null,"author":"user:r","policy_ver":"p1"}
        \\{"id":"x2","item_id":"i1","kind":"box","class":"person","geometry":{"x":0,"y":0,"w":1,"h":1},"attrs":null,"author":"agent","policy_ver":"p1"}
        \\{"id":"x4","item_id":"i3","kind":"point","class":null,"geometry":null,"attrs":null,"author":"user:r","policy_ver":"p1"}
        \\{"id":"x5","item_id":"i2","kind":"box","class":"car","geometry":{"x":5,"y":5,"w":5,"h":5},"attrs":null,"author":"user:r","policy_ver":"p1"}
        \\
    );
    const d12 = try DiffFiles.of(arena, dir, "v1", "v2");
    try buildDiff(arena, io, &db, v1, v2, d12);
    const cmp = try comparePage(arena, &db, v1, v2, d12, null, 2);
    try std.testing.expectEqual(DiffSummary{ .added = 1, .modified = 1, .deleted = 1, .ann_added = 1, .ann_changed = 1, .ann_removed = 1 }, cmp.summary);
    try std.testing.expectEqualStrings("README", cmp.changes[0].path);
    try std.testing.expectEqualStrings("deleted", cmp.changes[0].change);
    try std.testing.expectEqualStrings("d.txt", cmp.changes[1].path);
    try std.testing.expectEqualStrings("d.txt", cmp.next.?);
    try std.testing.expectEqual(@as(usize, 2), cmp.visual.len); // a.jpg (moved box), b.JPG (one gone, one new)
    try std.testing.expectEqualStrings("img/a.jpg", cmp.visual[0].path);
    try std.testing.expectEqual(@as(i64, 1), cmp.visual[0].shapes_before[0].geometry.?.object.get("x").?.integer);
    try std.testing.expectEqual(@as(i64, 9), cmp.visual[0].shapes_after[0].geometry.?.object.get("x").?.integer);
    try std.testing.expectEqualStrings("aa", cmp.visual[0].before.?.hash);
    try std.testing.expectEqualStrings("a2", cmp.visual[0].after.?.hash);
    const page2 = try comparePage(arena, &db, v1, v2, d12, cmp.next, 2);
    try std.testing.expectEqualStrings("img/a.jpg", page2.changes[0].path);
    try std.testing.expectEqual(@as(usize, 0), page2.visual.len);
    try std.testing.expectEqual(@as(usize, 3), cmp.ann_changes.len);
    try std.testing.expectEqualStrings("img/a.jpg", cmp.ann_changes[0].item_path.?);
    try std.testing.expectEqual(@as(usize, 0), page2.ann_changes.len);

    // The CLI's lines: the same changes, in files DuckDB writes.
    const out: CompareFiles = .{
        .items = try std.fmt.allocPrint(arena, "{s}/c.items.jsonl", .{dir}),
        .anns = try std.fmt.allocPrint(arena, "{s}/c.anns.jsonl", .{dir}),
    };
    const sum = try compareLines(arena, &db, d12, out);
    try std.testing.expectEqual(cmp.summary, sum);
    const lines = try std.Io.Dir.cwd().readFileAlloc(io, out.items, arena, .limited(1 << 20));
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, lines, "\n"));
    try std.testing.expect(std.mem.startsWith(u8, lines, "{\"change\":\"deleted\",\"path\":\"README\""));
    const ann_lines = try std.Io.Dir.cwd().readFileAlloc(io, out.anns, arena, .limited(1 << 20));
    try std.testing.expect(std.mem.indexOf(u8, ann_lines, "\"ann\":\"changed\",\"id\":\"x1\",\"kind\":\"box\",\"class\":\"person\",\"item_path\":\"img/a.jpg\"") != null);
}
