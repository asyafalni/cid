//! The browse engine (docs/dashboard.md §4.3 and "Browse API"): one page
//! of a version's items with their annotations, how many there are and
//! how many match, the options each filter offers — each counted against
//! every *other* active filter — and a cursor to the next page.
//!
//! One contract, two engines. The server build keeps each version as a
//! Parquet browse index and answers with one DuckDB query (filters,
//! facets, cursor), which is what holds the 1M-item budget. The CLI build
//! has no DuckDB and evaluates the same contract over the state rows in
//! memory, fine at the sizes such a server sees. The integration test
//! runs the same assertions against both, so they cannot drift.
//!
//! An index holds only what the sealed commit fixes: paths, hashes,
//! sizes, splits and annotations. Media metadata (an image's dimensions)
//! arrives later, when the preview worker sniffs the bytes, so it is
//! joined per page by the caller, never frozen into an index.
//!
//! Paths order bytewise in both engines, so a cursor means the same
//! thing to each. A file's type is its lowercased extension ("file" for
//! none), computed here once and stored in the index.

const std = @import("std");
const duck = @import("../../store/duck.zig");
const release = @import("../../core/release.zig");
const version = @import("../../core/version.zig");

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

pub const Row = struct {
    path: []const u8,
    hash: []const u8,
    size: u64,
    split: ?[]const u8,
    item_id: ?[]const u8,
    ext: []const u8,
    anns: []const release.AnnotationRow,
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
    /// "duckdb" or "state": which engine answered (for the curious and
    /// for tests; the contract is the same).
    engine: []const u8,
    total: u64,
    matched: u64,
    items: []const Item,
    next: ?[]const u8,
    open: ?Item,
    facets: Facets,
    /// Annotations per class across the whole version (the overlay chips).
    classes: []Facet,
};

pub const Error = error{ OutOfMemory, QueryFailed, Unavailable, OpenFailed, WriteFailed };

/// DuckDB threads for one browse query: two halve an unfiltered page at
/// 1M items (0.48 s to 0.27 s); index builds keep to one.
pub const query_threads = 2;

/// The file type the type filter speaks: the one rule (version.zig).
pub const extOf = version.extOfPath;

fn classOf(a: release.AnnotationRow) []const u8 {
    return a.class orelse "";
}

fn lessPath(_: void, a: Row, b: Row) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

/// A version's rows: the state items, each with its annotations, sorted
/// bytewise by path.
pub fn rowsOf(
    arena: std.mem.Allocator,
    state: []const release.StateRow,
    anns: []const release.AnnotationRow,
) ![]Row {
    var by_item: std.StringHashMapUnmanaged(std.ArrayList(release.AnnotationRow)) = .empty;
    for (anns) |a| {
        const entry = try by_item.getOrPut(arena, a.item_id);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(arena, a);
    }
    const rows = try arena.alloc(Row, state.len);
    for (rows, state) |*row, s| {
        row.* = .{
            .path = s.path,
            .hash = s.hash_hex,
            .size = s.size,
            .split = s.split,
            .item_id = s.item_id,
            .ext = try extOf(arena, s.path),
            .anns = if (s.item_id) |id| (if (by_item.get(id)) |list| list.items else &.{}) else &.{},
        };
    }
    std.mem.sort(Row, rows, {}, lessPath);
    return rows;
}

// ---------------------------------------------------------------------------
// The state engine: the contract, evaluated in memory.
// ---------------------------------------------------------------------------

const Skip = enum { none, split, class, type };

fn matches(row: Row, q: Query, skip: Skip) bool {
    // ASCII case folding; DuckDB folds Unicode. Only non-ASCII letters in
    // a search can tell the engines apart.
    if (q.q) |text| if (std.ascii.indexOfIgnoreCase(row.path, text) == null) return false;
    if (skip != .split) if (q.split) |want| if (!std.mem.eql(u8, row.split orelse "", want)) return false;
    if (skip != .type) if (q.type) |want| if (!std.mem.eql(u8, row.ext, want)) return false;
    if (skip != .class) if (q.class) |want| {
        for (row.anns) |a| {
            if (std.mem.eql(u8, classOf(a), want)) break;
        } else return false;
    };
    return true;
}

pub fn evaluate(arena: std.mem.Allocator, rows: []const Row, q: Query) !Answer {
    var page: std.ArrayList(Item) = .empty;
    var matched: u64 = 0;
    var next: ?[]const u8 = null;
    var open: ?Item = null;
    for (rows) |row| {
        if (q.item) |want| if (std.mem.eql(u8, row.path, want)) {
            open = try itemOf(arena, row);
        };
        if (!matches(row, q, .none)) continue;
        matched += 1;
        if (q.after) |after| if (!std.mem.lessThan(u8, after, row.path)) continue;
        if (page.items.len < q.limit) {
            try page.append(arena, try itemOf(arena, row));
        } else if (next == null and page.items.len > 0) {
            next = page.items[page.items.len - 1].path;
        }
    }

    var split: Counter = .{};
    var class: Counter = .{};
    var kind: Counter = .{};
    var chips: Counter = .{};
    for (rows) |row| {
        if (matches(row, q, .split)) try split.add(arena, row.split orelse "", 1);
        if (matches(row, q, .type)) try kind.add(arena, row.ext, 1);
        if (matches(row, q, .class)) {
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            for (row.anns) |a| {
                if ((try seen.getOrPut(arena, classOf(a))).found_existing) continue;
                try class.add(arena, classOf(a), 1);
            }
        }
        for (row.anns) |a| try chips.add(arena, classOf(a), 1);
    }

    return finish(arena, .{
        .engine = "state",
        .total = rows.len,
        .matched = matched,
        .items = page.items,
        .next = next,
        .open = open,
        .facets = .{ .split = try split.facets(arena), .class = try class.facets(arena), .type = try kind.facets(arena) },
        .classes = try chips.facets(arena),
    }, q);
}

const Counter = struct {
    map: std.StringArrayHashMapUnmanaged(u64) = .empty,

    fn add(self: *Counter, arena: std.mem.Allocator, key: []const u8, n: u64) !void {
        const entry = try self.map.getOrPut(arena, key);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += n;
    }

    fn facets(self: *Counter, arena: std.mem.Allocator) ![]Facet {
        const out = try arena.alloc(Facet, self.map.count());
        for (out, self.map.keys(), self.map.values()) |*f, k, v| f.* = .{ .value = k, .count = v };
        return out;
    }
};

fn itemOf(arena: std.mem.Allocator, row: Row) !Item {
    const anns = try arena.alloc(Ann, row.anns.len);
    for (anns, row.anns) |*out, a| {
        out.* = .{
            .id = a.annotation_id,
            .item_id = a.item_id,
            .kind = a.kind,
            .class = a.class,
            .geometry = try jsonOf(arena, a.geometry),
            .attrs = try jsonOf(arena, a.attrs),
            .author = a.author,
            .policy_ver = a.policy_ver,
        };
    }
    return .{
        .path = row.path,
        .hash = row.hash,
        .size = row.size,
        .split = row.split,
        .item_id = row.item_id,
        .annotations = anns,
    };
}

fn jsonOf(arena: std.mem.Allocator, text: ?[]const u8) !?std.json.Value {
    const t = text orelse return null;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, t, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

/// What both engines do last, so the order and the rules are one: an
/// active filter value stays listed even with no matches (a shared link
/// never shows a filter you cannot clear); facets by count, then value;
/// class chips by name.
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
};

/// The index for `rows`, written the way the server's pass writes it:
/// the lines, then convertIndex.
pub fn writeIndex(arena: std.mem.Allocator, io: std.Io, db: *duck.Db, files: Files, rows: []const Row) Error!void {
    try writeLines(io, files, rows);
    try convertIndex(arena, io, db, files);
}

/// Item and annotation lines in the shapes core/version.zig's pass
/// writes them (the server's path); here for rows already in memory.
pub fn writeLines(io: std.Io, files: Files, rows: []const Row) Error!void {
    const cwd = std.Io.Dir.cwd();
    var items_file = cwd.createFile(io, files.items_lines, .{ .truncate = true }) catch return error.WriteFailed;
    defer items_file.close(io);
    var anns_file = cwd.createFile(io, files.ann_lines, .{ .truncate = true }) catch return error.WriteFailed;
    defer anns_file.close(io);
    var ibuf: [64 * 1024]u8 = undefined;
    var abuf: [64 * 1024]u8 = undefined;
    var iw = items_file.writer(io, &ibuf);
    var aw = anns_file.writer(io, &abuf);
    for (rows) |row| {
        iw.interface.print("{{\"path\":{f},\"hash\":{f},\"size\":{d},\"split\":{f},\"item_id\":{f},\"ext\":{f},\"classes\":[", .{
            std.json.fmt(row.path, .{}),  std.json.fmt(row.hash, .{}),    row.size,
            std.json.fmt(row.split, .{}), std.json.fmt(row.item_id, .{}), std.json.fmt(row.ext, .{}),
        }) catch return error.WriteFailed;
        for (row.anns, 0..) |a, i| {
            if (i > 0) iw.interface.writeByte(',') catch return error.WriteFailed;
            iw.interface.print("{f}", .{std.json.fmt(classOf(a), .{})}) catch return error.WriteFailed;
            aw.interface.print("{{\"id\":{f},\"item_id\":{f},\"kind\":{f},\"class\":{f},\"geometry\":{s},\"attrs\":{s},\"author\":{f},\"policy_ver\":{f}}}\n", .{
                std.json.fmt(a.annotation_id, .{}), std.json.fmt(a.item_id, .{}),
                std.json.fmt(a.kind, .{}),          std.json.fmt(a.class, .{}),
                a.geometry orelse "null",           a.attrs orelse "null",
                std.json.fmt(a.author, .{}),        std.json.fmt(a.policy_ver, .{}),
            }) catch return error.WriteFailed;
        }
        iw.interface.writeAll("]}\n") catch return error.WriteFailed;
    }
    iw.interface.flush() catch return error.WriteFailed;
    aw.interface.flush() catch return error.WriteFailed;
}

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
        const tmp = try std.fmt.allocPrint(arena, "{s}.tmp", .{step.out});
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
        .engine = "duckdb",
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

/// A small annotated version both engines are tested on: three items in
/// two splits, one without an extension, boxes of two classes, one
/// annotation with no class.
fn fixtureRows(arena: std.mem.Allocator) ![]Row {
    const state = [_]release.StateRow{
        .{ .path = "img/b.JPG", .hash_hex = "bb", .size = 2, .split = "train", .item_id = "i2", .width = 4, .height = 3 },
        .{ .path = "img/a.jpg", .hash_hex = "aa", .size = 1, .split = "train", .item_id = "i1", .width = 4, .height = 3 },
        .{ .path = "img/c.png", .hash_hex = "cc", .size = 3, .split = "val", .item_id = "i3", .width = 4, .height = 3 },
        .{ .path = "README", .hash_hex = "dd", .size = 4, .split = null },
    };
    const anns = [_]release.AnnotationRow{
        .{ .annotation_id = "x1", .item_id = "i1", .kind = "box", .class = "person", .geometry = "{\"x\":1,\"y\":2,\"w\":3,\"h\":4}", .attrs = null, .author = "agent", .policy_ver = "p1" },
        .{ .annotation_id = "x2", .item_id = "i1", .kind = "box", .class = "person", .geometry = "{\"x\":0,\"y\":0,\"w\":1,\"h\":1}", .attrs = null, .author = "agent", .policy_ver = "p1" },
        .{ .annotation_id = "x3", .item_id = "i2", .kind = "box", .class = "car", .geometry = null, .attrs = "{\"occluded\":true}", .author = "agent", .policy_ver = "p1" },
        .{ .annotation_id = "x4", .item_id = "i3", .kind = "point", .class = null, .geometry = null, .attrs = null, .author = "user:r", .policy_ver = "p1" },
    };
    return rowsOf(arena, try arena.dupe(release.StateRow, &state), try arena.dupe(release.AnnotationRow, &anns));
}

fn countOf(list: []const Facet, value: []const u8) ?u64 {
    for (list) |f| if (std.mem.eql(u8, f.value, value)) return f.count;
    return null;
}

/// The contract, checked against whichever engine `run` is.
fn expectContract(arena: std.mem.Allocator, ctx: anytype, run: fn (@TypeOf(ctx), std.mem.Allocator, Query) anyerror!Answer) !void {
    // Everything: bytewise path order (uppercase sorts first), counts,
    // facets and the class chips.
    const all = try run(ctx, arena, .{});
    try std.testing.expectEqual(@as(u64, 4), all.total);
    try std.testing.expectEqual(@as(u64, 4), all.matched);
    try std.testing.expectEqualStrings("README", all.items[0].path);
    try std.testing.expectEqualStrings("img/a.jpg", all.items[1].path);
    try std.testing.expect(all.next == null);
    try std.testing.expectEqual(@as(?u64, 2), countOf(all.facets.split, "train"));
    try std.testing.expectEqual(@as(?u64, 1), countOf(all.facets.split, ""));
    try std.testing.expectEqual(@as(?u64, 2), countOf(all.facets.type, ".jpg")); // a.jpg and b.JPG
    try std.testing.expectEqual(@as(?u64, 1), countOf(all.facets.type, "file"));
    try std.testing.expectEqual(@as(?u64, 1), countOf(all.facets.class, "person")); // items, not boxes
    try std.testing.expectEqual(@as(?u64, 1), countOf(all.facets.class, ""));
    try std.testing.expectEqualStrings("train", all.facets.split[0].value); // biggest first
    try std.testing.expectEqualStrings("", all.classes[0].value); // chips by name
    try std.testing.expectEqual(@as(?u64, 2), countOf(all.classes, "person")); // boxes, not items
    const a = all.items[1];
    try std.testing.expectEqual(@as(usize, 2), a.annotations.len);
    try std.testing.expectEqual(@as(i64, 3), a.annotations[0].geometry.?.object.get("w").?.integer);

    // Each facet counts against the other filters, never its own.
    const train = try run(ctx, arena, .{ .split = "train" });
    try std.testing.expectEqual(@as(u64, 2), train.matched);
    try std.testing.expectEqual(@as(?u64, 1), countOf(train.facets.split, "val"));
    try std.testing.expectEqual(@as(?u64, 1), countOf(train.facets.class, "car"));
    try std.testing.expectEqual(@as(?u64, null), countOf(train.facets.class, ""));

    const cars = try run(ctx, arena, .{ .class = "car", .q = "IMG/" });
    try std.testing.expectEqual(@as(u64, 1), cars.matched);
    try std.testing.expectEqualStrings("img/b.JPG", cars.items[0].path);
    try std.testing.expectEqualStrings("{\"occluded\":true}", try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(cars.items[0].annotations[0].attrs.?, .{})}));

    // An active value with no match stays listed, at zero.
    const none = try run(ctx, arena, .{ .type = ".wav" });
    try std.testing.expectEqual(@as(u64, 0), none.matched);
    try std.testing.expectEqual(@as(usize, 0), none.items.len);
    try std.testing.expectEqual(@as(?u64, 0), countOf(none.facets.type, ".wav"));

    // The cursor walks every match exactly once.
    var seen: usize = 0;
    var after: ?[]const u8 = null;
    while (true) {
        const page = try run(ctx, arena, .{ .limit = 3, .after = after });
        seen += page.items.len;
        after = page.next orelse break;
        try std.testing.expectEqualStrings(page.items[page.items.len - 1].path, after.?);
    }
    try std.testing.expectEqual(@as(usize, 4), seen);

    // The open item comes with any page, whatever the filters.
    const open = try run(ctx, arena, .{ .split = "val", .item = "README" });
    try std.testing.expectEqualStrings("README", open.open.?.path);
    try std.testing.expectEqual(@as(usize, 0), open.open.?.annotations.len);
}

test "file types by extension, the dashboard's way" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings(".jpg", try extOf(arena, "a/b/C.JPG"));
    try std.testing.expectEqualStrings("file", try extOf(arena, "a.d/README"));
    try std.testing.expectEqualStrings("file", try extOf(arena, ".cidignore"));
    try std.testing.expectEqualStrings(".gz", try extOf(arena, "x.tar.gz"));
}

test "the state engine keeps the contract" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rows = try fixtureRows(arena);
    try expectContract(arena, rows, struct {
        fn run(r: []Row, al: std.mem.Allocator, q: Query) anyerror!Answer {
            return evaluate(al, r, q);
        }
    }.run);
}

test "the DuckDB engine keeps the same contract, from a Parquet index" {
    if (comptime !duck.enabled) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", arena);
    var db = try duck.Db.open(arena, .{ .allowed_dir = dir });
    defer db.close();

    const v1 = try Files.of(arena, dir, "v1");
    try writeIndex(arena, io, &db, v1, try fixtureRows(arena));
    const Ctx = struct { db: *duck.Db, files: Files };
    try expectContract(arena, Ctx{ .db = &db, .files = v1 }, struct {
        fn run(c: Ctx, al: std.mem.Allocator, q: Query) anyerror!Answer {
            return queryIndex(al, c.db, c.files, q);
        }
    }.run);

    // An empty version is an index too.
    const none = try Files.of(arena, dir, "empty");
    try writeIndex(arena, io, &db, none, &.{});
    const empty = try queryIndex(arena, &db, none, .{});
    try std.testing.expectEqual(@as(u64, 0), empty.total);
    try std.testing.expectEqual(@as(usize, 0), empty.facets.split.len);

    // A hostile filter is a value, not SQL.
    const odd = try queryIndex(arena, &db, v1, .{ .q = "'); DROP TABLE x; --" });
    try std.testing.expectEqual(@as(u64, 0), odd.matched);
}
