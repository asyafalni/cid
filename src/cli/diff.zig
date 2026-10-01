//! `cid diff [<a>] [<b>]`: what changed. No arguments = unstaged edits,
//! --staged = staged changes, one or two versions = compare them (a
//! release name or commit id; one argument compares against the folder's
//! current commit). File-level here; row-level tabular diffs are computed
//! on the server and arrive with the tabular slice.

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

pub const Change = struct {
    kind: enum { added, modified, deleted },
    path: []const u8,
    size_a: ?u64,
    size_b: ?u64,
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
                    try out.append(arena, .{ .kind = .modified, .path = a[i].path, .size_a = a[i].size, .size_b = b[j].size });
                i += 1;
                j += 1;
            },
        }
    }
    return out.items;
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
                modified += 1;
            },
            .deleted => {
                printLine(ctx, "deleted", ch.path, null) catch return .network;
                deleted += 1;
            },
        }
    }
    if (changes.len == 0) {
        ctx.out.writeAll("No differences.\n") catch return .network;
    } else {
        ctx.out.print("{d} change{s}: {d} added, {d} modified, {d} deleted\n", .{
            changes.len, plural(changes.len), added, modified, deleted,
        }) catch return .network;
    }
    return .ok;
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

test "human sizes" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("512 B", humanSize(&buf, 512));
    try std.testing.expectEqualStrings("1.5 KB", humanSize(&buf, 1536));
}
