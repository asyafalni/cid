//! `cid diff [<a>] [<b>]`: what changed. No arguments = unstaged edits,
//! --staged = staged changes, one or two versions = compare them (a
//! release name or commit id; one argument compares against the folder's
//! current commit). Two versions are compared on the server and the
//! changes stream in, printed as they arrive; a modified CSV, Parquet or
//! JSONL file also shows its rows added and removed, which the server
//! computes too (CLAUDE.md, Formats) — the CLI never reads a table.

const std = @import("std");
const common = @import("common.zig");
const workspace = @import("../client/workspace.zig");
const local = @import("../client/local.zig");
const remote_mod = @import("../client/remote.zig");

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

    // The server compares (core/version.zig) and the changes stream in,
    // printed as they arrive: a million-item diff holds one line at a time.
    ctx.out.print("Comparing {s} → {s}\n", .{ a_label, b_label }) catch return .network;
    var printer: Printer = .{ .ctx = ctx, .remote = remote };
    const sum = remote.compare(ctx.arena, a_commit, b_commit, .{ .ctx = &printer, .visit = Printer.visit }) catch |err| switch (err) {
        error.ServerRefused => return common.fail(ctx, .integrity, "the diff from the server failed its check; the lines above are void. Run 'cid diff' again.", .{}),
        else => return common.fail(ctx, .network, "cannot compare '{s}' and '{s}' on the server. Check CID_SERVER, then run 'cid diff' again.", .{ a_label, b_label }),
    };
    if (printer.failed) return .network;

    const items = sum.added + sum.modified + sum.deleted;
    const anns = sum.ann_added + sum.ann_changed + sum.ann_removed;
    if (items == 0 and anns == 0) {
        ctx.out.writeAll("No differences.\n") catch return .network;
    } else if (anns == 0) {
        ctx.out.print("{d} change{s}: {d} added, {d} modified, {d} deleted\n", .{
            items, plural(items), sum.added, sum.modified, sum.deleted,
        }) catch return .network;
    } else {
        ctx.out.print("items: {d} added, {d} modified, {d} deleted · annotations: {d} added, {d} changed, {d} removed\n", .{
            sum.added, sum.modified, sum.deleted, sum.ann_added, sum.ann_changed, sum.ann_removed,
        }) catch return .network;
    }
    return .ok;
}

/// Prints each change as it streams in; a modified table also gets its
/// row line, asked of the server right then.
const Printer = struct {
    ctx: *const common.Context,
    remote: *const remote_mod.Remote,
    failed: bool = false,

    fn visit(raw: *anyopaque, line: remote_mod.Remote.DiffLine) anyerror!void {
        const self: *Printer = @ptrCast(@alignCast(raw));
        self.print(line) catch {
            self.failed = true;
            return error.WriteFailed;
        };
    }

    fn print(self: *Printer, line: remote_mod.Remote.DiffLine) !void {
        const ctx = self.ctx;
        if (line.change) |change| {
            const path = line.path orelse return;
            if (std.mem.eql(u8, change, "deleted")) {
                try printLine(ctx, "deleted", path, null);
            } else {
                try printLine(ctx, change, path, line.size_b);
                if (std.mem.eql(u8, change, "modified") and isTable(path))
                    try printRows(ctx, self.remote, path, line.hash_a.?, line.hash_b.?);
            }
        } else if (line.ann) |change| {
            try ctx.out.print("  ann {s: <8} {s} {s} on {s}\n", .{
                change, line.kind orelse "?", line.class orelse "?", line.item_path orelse "?",
            });
        }
    }
};

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
fn printRows(ctx: *const common.Context, remote: *const remote_mod.Remote, path: []const u8, hash_a: []const u8, hash_b: []const u8) !void {
    const indent = "              ";
    var tries: u32 = 0;
    const rd = while (true) : (tries += 1) {
        const got = remote.rowDiff(ctx.arena, hash_a, path, hash_b, path) catch {
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
