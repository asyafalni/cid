//! `cid diff [<a>] [<b>]`: what changed. No arguments = unstaged edits,
//! --staged = staged changes, one or two versions = compare them (a
//! release name or commit id; one argument compares against the folder's
//! current commit). Files compare by hash here; a modified CSV, Parquet
//! or JSONL file also shows its rows added and removed, which the server
//! computes (CLAUDE.md, Formats) — the CLI never reads a table.

const std = @import("std");
const common = @import("common.zig");
const workspace = @import("../client/workspace.zig");
const local = @import("../client/local.zig");
const remote_mod = @import("../client/remote.zig");
const jcs = @import("../manifest/jcs.zig");

pub fn run(ctx: *const common.Context, args: []const [:0]const u8) common.ExitCode {
    var staged = false;
    var versions: std.ArrayList([]const u8) = .empty;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--staged")) {
            staged = true;
        } else {
            versions.append(ctx.arena, arg) catch return .network;
        }
    }
    if (staged and versions.items.len > 0)
        return common.fail(ctx, .usage, "--staged takes no versions. Run 'cid diff --staged' or 'cid diff <a> <b>'.", .{});
    if (versions.items.len > 2)
        return common.fail(ctx, .usage, "at most two versions. Run 'cid diff <a> <b>'.", .{});

    var ws = common.openWorkspace(ctx) catch
        return common.fail(ctx, .usage, common.not_a_dataset_msg, .{});

    if (versions.items.len == 0) {
        return localDiff(ctx, &ws, staged);
    }
    return versionDiff(ctx, &ws, versions.items);
}

// --- local: unstaged (worktree vs staged-over-tracked) or staged (index vs tracked)

fn localDiff(ctx: *const common.Context, ws: *workspace.Workspace, staged: bool) common.ExitCode {
    const st = workspace.status(ctx.arena, ctx.io, ws) catch
        return common.fail(ctx, .integrity, ".cid/ state is unreadable. Run 'cid status' for details.", .{});

    var lines: u32 = 0;
    if (staged) {
        for (st.staged) |e| {
            switch (e.op) {
                .add => printLine(ctx, "added", e.path, e.size) catch return .network,
                .delete => printLine(ctx, "deleted", e.path, null) catch return .network,
            }
            lines += 1;
        }
        if (lines == 0)
            ctx.out.writeAll("Nothing staged. Run 'cid add <path>' to stage changes.\n") catch return .network;
        return .ok;
    }

    for (st.unstaged_new) |p| {
        printLine(ctx, "new", p, sizeOf(ctx, ws, p)) catch return .network;
        lines += 1;
    }
    for (st.unstaged_modified) |p| {
        printLine(ctx, "modified", p, sizeOf(ctx, ws, p)) catch return .network;
        lines += 1;
    }
    for (st.unstaged_deleted) |p| {
        printLine(ctx, "deleted", p, null) catch return .network;
        lines += 1;
    }
    if (lines == 0)
        ctx.out.writeAll("No unstaged changes.\n") catch return .network;
    return .ok;
}

fn sizeOf(ctx: *const common.Context, ws: *workspace.Workspace, path: []const u8) ?u64 {
    const stat = ws.work_dir.statFile(ctx.io, path, .{}) catch return null;
    return stat.size;
}

// --- versions: resolve names, fetch both states, compare

pub const Change = struct {
    kind: enum { added, modified, deleted },
    path: []const u8,
    size_a: ?u64,
    size_b: ?u64,
    hash_a: ?[]const u8 = null,
    hash_b: ?[]const u8 = null,
};

/// Pure two-state comparison; both inputs sorted by path (as the server
/// returns them).
pub fn diffStates(
    arena: std.mem.Allocator,
    a: []const remote_mod.Remote.StateItem,
    b: []const remote_mod.Remote.StateItem,
) ![]const Change {
    var out: std.ArrayList(Change) = .empty;
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len or j < b.len) {
        const order: std.math.Order = if (i >= a.len)
            .gt
        else if (j >= b.len)
            .lt
        else
            std.mem.order(u8, a[i].path, b[j].path);
        switch (order) {
            .lt => {
                try out.append(arena, .{ .kind = .deleted, .path = a[i].path, .size_a = a[i].size, .size_b = null });
                i += 1;
            },
            .gt => {
                try out.append(arena, .{ .kind = .added, .path = b[j].path, .size_a = null, .size_b = b[j].size });
                j += 1;
            },
            .eq => {
                if (!std.mem.eql(u8, a[i].hash, b[j].hash))
                    try out.append(arena, .{ .kind = .modified, .path = a[i].path, .size_a = a[i].size, .size_b = b[j].size, .hash_a = a[i].hash, .hash_b = b[j].hash });
                i += 1;
                j += 1;
            },
        }
    }
    return out.items;
}

pub const AnnChange = struct {
    kind: enum { added, removed, changed },
    ann_kind: ?[]const u8,
    class: ?[]const u8,
    item_path: []const u8,
};

/// Annotations by id across two states: present only in b → added, only
/// in a → removed, in both with different class/kind/geometry/attrs →
/// changed (JSON compared in canonical form, so formatting never lies).
pub fn diffAnnotations(
    arena: std.mem.Allocator,
    a: remote_mod.Remote.AnnotatedState,
    b: remote_mod.Remote.AnnotatedState,
) ![]const AnnChange {
    var paths: std.StringArrayHashMapUnmanaged([]const u8) = .empty; // item_id → path
    for (a.items) |item| {
        if (item.item_id) |id| try paths.put(arena, id, item.path);
    }
    for (b.items) |item| {
        if (item.item_id) |id| try paths.put(arena, id, item.path);
    }
    var a_by_id: std.StringArrayHashMapUnmanaged(remote_mod.Remote.Annotation) = .empty;
    for (a.annotations) |ann| try a_by_id.put(arena, ann.id, ann);

    var out: std.ArrayList(AnnChange) = .empty;
    for (b.annotations) |ann| {
        const path = paths.get(ann.item_id) orelse "?";
        if (a_by_id.get(ann.id)) |old| {
            _ = a_by_id.swapRemove(ann.id);
            if (!annEqual(arena, old, ann))
                try out.append(arena, .{ .kind = .changed, .ann_kind = ann.kind, .class = ann.class, .item_path = path });
        } else {
            try out.append(arena, .{ .kind = .added, .ann_kind = ann.kind, .class = ann.class, .item_path = path });
        }
    }
    for (a_by_id.values()) |old| {
        try out.append(arena, .{ .kind = .removed, .ann_kind = old.kind, .class = old.class, .item_path = paths.get(old.item_id) orelse "?" });
    }
    return out.items;
}

fn annEqual(arena: std.mem.Allocator, a: remote_mod.Remote.Annotation, b: remote_mod.Remote.Annotation) bool {
    if (!optEql(a.kind, b.kind) or !optEql(a.class, b.class)) return false;
    return valueEql(arena, a.geometry, b.geometry) and valueEql(arena, a.attrs, b.attrs);
}

fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn valueEql(arena: std.mem.Allocator, a: ?std.json.Value, b: ?std.json.Value) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    var ca: std.ArrayList(u8) = .empty;
    var cb: std.ArrayList(u8) = .empty;
    jcs.serialize(arena, a.?, &ca) catch return false;
    jcs.serialize(arena, b.?, &cb) catch return false;
    return std.mem.eql(u8, ca.items, cb.items);
}

fn versionDiff(ctx: *const common.Context, ws: *workspace.Workspace, versions: []const []const u8) common.ExitCode {
    const name = workspace.datasetPathOf(ws.config.address) orelse
        return common.fail(ctx, .integrity, ".cid/config.zon holds a broken address. Clone again, or fix it to cid@host:org/path.", .{});
    const remote = common.remoteFor(ctx, name, .read, ws.config.address) catch
        return common.fail(ctx, .usage, common.no_server_msg, .{});

    const a_label = versions[0];
    const b_label: []const u8 = if (versions.len == 2) versions[1] else blk: {
        const head = local.loadHead(ctx.arena, ctx.io, ws.cid_dir) catch
            return common.fail(ctx, .integrity, ".cid/ state is unreadable. Run 'cid status' for details.", .{});
        const commit = head.commit orelse
            return common.fail(ctx, .usage, "this folder has no commit to compare against. Run 'cid diff <a> <b>' with two versions.", .{});
        break :blk ctx.arena.dupe(u8, &commit.toString()) catch return .network;
    };

    const a_commit = resolve(ctx, remote, a_label) orelse
        return common.fail(ctx, .usage, "'{s}' is neither a release nor a commit here. Run 'cid log'.", .{a_label});
    const b_commit = resolve(ctx, remote, b_label) orelse
        return common.fail(ctx, .usage, "'{s}' is neither a release nor a commit here. Run 'cid log'.", .{b_label});

    const state_a = remote.state(ctx.arena, a_commit) catch
        return common.fail(ctx, .network, "cannot fetch '{s}' from the server. Check CID_SERVER, then run 'cid diff' again.", .{a_label});
    const state_b = remote.state(ctx.arena, b_commit) catch
        return common.fail(ctx, .network, "cannot fetch '{s}' from the server. Check CID_SERVER, then run 'cid diff' again.", .{b_label});

    const changes = diffStates(ctx.arena, state_a, state_b) catch return .network;
    ctx.out.print("Comparing {s} → {s}\n", .{ a_label, b_label }) catch return .network;

    var ann_changes: []const AnnChange = &.{};
    if (std.mem.eql(u8, ws.config.kind, "annotated")) {
        const full_a = remote.stateAnnotated(ctx.arena, a_commit) catch
            return common.fail(ctx, .network, "cannot fetch annotations for '{s}'. Check the connection, then run 'cid diff' again.", .{a_label});
        const full_b = remote.stateAnnotated(ctx.arena, b_commit) catch
            return common.fail(ctx, .network, "cannot fetch annotations for '{s}'. Check the connection, then run 'cid diff' again.", .{b_label});
        ann_changes = diffAnnotations(ctx.arena, full_a, full_b) catch return .network;
    }
    var added: u32 = 0;
    var modified: u32 = 0;
    var deleted: u32 = 0;
    for (changes) |ch| {
        switch (ch.kind) {
            .added => {
                printLine(ctx, "added", ch.path, ch.size_b) catch return .network;
                added += 1;
            },
            .modified => {
                printLine(ctx, "modified", ch.path, ch.size_b) catch return .network;
                if (isTable(ch.path)) printRows(ctx, remote, ch) catch return .network;
                modified += 1;
            },
            .deleted => {
                printLine(ctx, "deleted", ch.path, null) catch return .network;
                deleted += 1;
            },
        }
    }
    var ann_added: u32 = 0;
    var ann_changed: u32 = 0;
    var ann_removed: u32 = 0;
    for (ann_changes) |ch| {
        const verb = switch (ch.kind) {
            .added => blk: {
                ann_added += 1;
                break :blk "added";
            },
            .changed => blk: {
                ann_changed += 1;
                break :blk "changed";
            },
            .removed => blk: {
                ann_removed += 1;
                break :blk "removed";
            },
        };
        ctx.out.print("  ann {s: <8} {s} {s} on {s}\n", .{
            verb, ch.ann_kind orelse "?", ch.class orelse "?", ch.item_path,
        }) catch return .network;
    }

    if (changes.len == 0 and ann_changes.len == 0) {
        ctx.out.writeAll("No differences.\n") catch return .network;
    } else if (ann_changes.len == 0) {
        ctx.out.print("{d} change{s}: {d} added, {d} modified, {d} deleted\n", .{
            changes.len, plural(changes.len), added, modified, deleted,
        }) catch return .network;
    } else {
        ctx.out.print("items: {d} added, {d} modified, {d} deleted · annotations: {d} added, {d} changed, {d} removed\n", .{
            added, modified, deleted, ann_added, ann_changed, ann_removed,
        }) catch return .network;
    }
    return .ok;
}

fn isTable(path: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    const ext = path[dot..];
    for ([_][]const u8{ ".csv", ".parquet", ".jsonl", ".ndjson" }) |t| {
        if (std.ascii.eqlIgnoreCase(ext, t)) return true;
    }
    return false;
}

/// The row-level line under a modified table file. Whatever the server
/// cannot say about rows, the file line above already said the file
/// changed, so this line explains and never fails the command.
fn printRows(ctx: *const common.Context, remote: *const remote_mod.Remote, ch: Change) !void {
    const indent = "              ";
    var tries: u32 = 0;
    const rd = while (true) : (tries += 1) {
        const got = remote.rowDiff(ctx.arena, ch.hash_a.?, ch.path, ch.hash_b.?, ch.path) catch {
            try ctx.out.print("{s}rows: the server could not compare them; run 'cid diff' again\n", .{indent});
            return;
        };
        if (!std.mem.eql(u8, got.status, "busy") or tries == 40) break got;
        std.Io.sleep(ctx.io, .fromMilliseconds(250), .awake) catch {};
    };
    try ctx.out.print("{s}", .{indent});
    try formatRows(ctx.out, rd);
}

fn formatRows(out: *std.Io.Writer, rd: remote_mod.Remote.RowDiff) !void {
    if (!std.mem.eql(u8, rd.status, "done") or rd.diff == null) {
        if (std.mem.eql(u8, rd.status, "busy")) return out.writeAll("rows: the server is busy; run 'cid diff' again\n");
        return out.print("rows: not compared: {s}\n", .{rd.reason orelse rd.status});
    }
    const d = rd.diff.?;
    if (d.columns_changed) {
        try out.writeAll("columns changed, so rows are not compared:");
        for (d.columns_a) |col| if (!contains(d.columns_b, col)) try out.print(" -{s}", .{col});
        for (d.columns_b) |col| if (!contains(d.columns_a, col)) try out.print(" +{s}", .{col});
        if (sameSet(d.columns_a, d.columns_b)) try out.writeAll(" reordered");
        return out.print(" ({d} → {d} rows)\n", .{ d.rows_a, d.rows_b });
    }
    if (d.added == 0 and d.removed == 0)
        return out.print("rows: the same {d} rows, in another order or format\n", .{d.rows_b});
    try out.print("rows: {d} added, {d} removed ({d} → {d})\n", .{ d.added, d.removed, d.rows_a, d.rows_b });
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, item)) return true;
    return false;
}

fn sameSet(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a) |x| if (!contains(b, x)) return false;
    return true;
}

fn resolve(ctx: *const common.Context, remote: *const remote_mod.Remote, label: []const u8) ?[]const u8 {
    if (label.len == 36) return label; // a commit id
    const releases = remote.releases(ctx.arena) catch return null;
    for (releases) |r| {
        if (std.mem.eql(u8, r.name, label)) return r.commit;
    }
    return null;
}

fn printLine(ctx: *const common.Context, verb: []const u8, path: []const u8, size: ?u64) !void {
    if (size) |n| {
        var buf: [32]u8 = undefined;
        try ctx.out.print("  {s: <9} {s}  ({s})\n", .{ verb, path, humanSize(&buf, n) });
    } else {
        try ctx.out.print("  {s: <9} {s}\n", .{ verb, path });
    }
}

fn humanSize(buf: []u8, n: u64) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var value: f64 = @floatFromInt(n);
    var unit: usize = 0;
    while (value >= 1024 and unit < units.len - 1) : (unit += 1) value /= 1024;
    if (unit == 0)
        return std.fmt.bufPrint(buf, "{d} B", .{n}) catch "?";
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ value, units[unit] }) catch "?";
}

fn plural(n: anytype) []const u8 {
    return if (n == 1) "" else "s";
}

test "diffStates walks both sorted lists" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Item = remote_mod.Remote.StateItem;

    const a = [_]Item{
        .{ .path = "a.txt", .hash = "h1", .size = 1 },
        .{ .path = "b.txt", .hash = "h2", .size = 2 },
        .{ .path = "c.txt", .hash = "h3", .size = 3 },
    };
    const b = [_]Item{
        .{ .path = "b.txt", .hash = "h2x", .size = 20 },
        .{ .path = "c.txt", .hash = "h3", .size = 3 },
        .{ .path = "d.txt", .hash = "h4", .size = 4 },
    };
    const changes = try diffStates(arena, &a, &b);
    try std.testing.expectEqual(@as(usize, 3), changes.len);
    try std.testing.expectEqualStrings("a.txt", changes[0].path); // deleted
    try std.testing.expectEqualStrings("b.txt", changes[1].path); // modified
    try std.testing.expectEqualStrings("d.txt", changes[2].path); // added
    try std.testing.expect(changes[0].kind == .deleted);
    try std.testing.expect(changes[1].kind == .modified);
    try std.testing.expect(changes[2].kind == .added);
}

test "row lines: counts, a column change, the same rows, and words when not compared" {
    var buf: [256]u8 = undefined;
    const Rd = remote_mod.Remote.RowDiff;
    const cases = [_]struct { rd: Rd, want: []const u8 }{
        .{ .rd = .{ .status = "done", .diff = .{ .rows_a = 5, .rows_b = 6, .columns_changed = false, .added = 3, .removed = 2 } }, .want = "rows: 3 added, 2 removed (5 → 6)\n" },
        .{ .rd = .{ .status = "done", .diff = .{ .rows_a = 5, .rows_b = 1, .columns_a = &.{ "id BIGINT", "name VARCHAR" }, .columns_b = &.{ "id BIGINT", "name VARCHAR", "team VARCHAR" }, .columns_changed = true } }, .want = "columns changed, so rows are not compared: +team VARCHAR (5 → 1 rows)\n" },
        .{ .rd = .{ .status = "done", .diff = .{ .rows_a = 5, .rows_b = 5, .columns_changed = false } }, .want = "rows: the same 5 rows, in another order or format\n" },
        .{ .rd = .{ .status = "needs_server_build", .reason = "this server is built without row-level diffs" }, .want = "rows: not compared: this server is built without row-level diffs\n" },
    };
    for (cases) |case| {
        var w: std.Io.Writer = .fixed(&buf);
        try formatRows(&w, case.rd);
        try std.testing.expectEqualStrings(case.want, w.buffered());
    }
}

test "human sizes" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("512 B", humanSize(&buf, 512));
    try std.testing.expectEqualStrings("1.5 KB", humanSize(&buf, 1536));
}

test "annotation diff: added, changed (canonically compared), removed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Item = remote_mod.Remote.StateItem;

    const g1a = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"x\":1.0,\"y\":2}", .{});
    const g1b = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"y\":2,\"x\":1}", .{}); // same value
    const g2 = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"x\":9}", .{});

    const items = [_]Item{.{ .path = "a.jpg", .hash = "ab" ** 32, .size = 1, .item_id = "i1" }};
    const a: remote_mod.Remote.AnnotatedState = .{
        .items = &items,
        .annotations = &.{
            .{ .id = "keep", .item_id = "i1", .kind = "box", .class = "person", .geometry = g1a, .author = "x", .policy_ver = "p" },
            .{ .id = "move", .item_id = "i1", .kind = "box", .class = "person", .geometry = g1a, .author = "x", .policy_ver = "p" },
            .{ .id = "gone", .item_id = "i1", .kind = "box", .class = "vehicle", .geometry = g2, .author = "x", .policy_ver = "p" },
        },
    };
    const b: remote_mod.Remote.AnnotatedState = .{
        .items = &items,
        .annotations = &.{
            // Same geometry written differently: NOT a change.
            .{ .id = "keep", .item_id = "i1", .kind = "box", .class = "person", .geometry = g1b, .author = "y", .policy_ver = "p2" },
            .{ .id = "move", .item_id = "i1", .kind = "box", .class = "person", .geometry = g2, .author = "x", .policy_ver = "p" },
            .{ .id = "new", .item_id = "i1", .kind = "box", .class = "bike", .geometry = g2, .author = "x", .policy_ver = "p" },
        },
    };
    const changes = try diffAnnotations(arena, a, b);
    try std.testing.expectEqual(@as(usize, 3), changes.len);
    var added: u32 = 0;
    var changed: u32 = 0;
    var removed: u32 = 0;
    for (changes) |ch| {
        switch (ch.kind) {
            .added => {
                added += 1;
                try std.testing.expectEqualStrings("bike", ch.class.?);
            },
            .changed => changed += 1,
            .removed => {
                removed += 1;
                try std.testing.expectEqualStrings("vehicle", ch.class.?);
            },
        }
        try std.testing.expectEqualStrings("a.jpg", ch.item_path);
    }
    try std.testing.expectEqual(@as(u32, 1), added);
    try std.testing.expectEqual(@as(u32, 1), changed);
    try std.testing.expectEqual(@as(u32, 1), removed);
}
