//! `cid status`: current version, staged and unstaged changes, local commits.

const std = @import("std");
const common = @import("common.zig");
const workspace = @import("../client/workspace.zig");
const sync = @import("../client/sync.zig");

pub fn run(ctx: *const common.Context) common.ExitCode {
    var ws = common.openWorkspace(ctx) catch
        return common.fail(ctx, .usage, common.not_a_dataset_msg, .{});

    const st = workspace.status(ctx.arena, ctx.io, &ws) catch
        return common.fail(ctx, .integrity, ".cid/ state is unreadable. If this folder matters, keep it and report the problem; otherwise clone again.", .{});

    const out = ctx.out;
    if (ctx.json) {
        const subset = workspace.Subset.of(ws.config);
        _ = common.emitJson(ctx, .{
            .status = st,
            .subset = if (subset.active()) subset.describe(ctx.arena) catch null else null,
            .pull_conflicts = sync.pendingConflicts(ctx.arena, ctx.io, &ws),
            .merge = sync.loadMerge(ctx.arena, ctx.io, &ws),
        });
        return .ok;
    }
    print(out, st) catch return .network;
    const subset = workspace.Subset.of(ws.config);
    if (subset.active()) {
        const what = subset.describe(ctx.arena) catch return .network;
        out.print("Subset: {s} (read-only; 'cid pull' keeps it current)\n", .{what}) catch return .network;
    }

    if (sync.pendingConflicts(ctx.arena, ctx.io, &ws)) |conflicts| {
        var undecided: usize = 0;
        for (conflicts) |c| {
            if (c.choice == .undecided) undecided += 1;
        }
        out.print("\nA pull is waiting on conflict decisions ({d} of {d} files undecided).\nRun 'cid pull' to list them.\n", .{ undecided, conflicts.len }) catch return .network;
    }
    return .ok;
}

fn print(out: *std.Io.Writer, st: workspace.Status) !void {
    try out.print("On branch {s}\n", .{st.branch});
    if (st.local_commits > 0) {
        try out.print("{d} local commit{s}, not pushed ('cid push' when ready)\n", .{ st.local_commits, plural(st.local_commits) });
    }

    const clean = st.staged.len == 0 and st.unstaged_new.len == 0 and
        st.unstaged_modified.len == 0 and st.unstaged_deleted.len == 0;
    if (clean) {
        try out.writeAll("nothing to commit, working folder clean\n");
        try printLinks(out, st);
        return;
    }
    defer printLinks(out, st) catch {};

    if (st.staged.len > 0) {
        try out.writeAll("\nChanges staged for commit ('cid commit -m \"...\"'):\n");
        for (st.staged) |e| {
            switch (e.op) {
                .add => try out.print("  added     {s}\n", .{e.path}),
                .delete => try out.print("  deleted   {s}\n", .{e.path}),
            }
        }
    }
    if (st.unstaged_new.len + st.unstaged_modified.len + st.unstaged_deleted.len > 0) {
        try out.writeAll("\nChanges not staged ('cid add <path>' to stage):\n");
        for (st.unstaged_new) |p| try out.print("  new       {s}\n", .{p});
        for (st.unstaged_modified) |p| try out.print("  modified  {s}\n", .{p});
        for (st.unstaged_deleted) |p| try out.print("  deleted   {s}\n", .{p});
    }
}

/// Links are in no commit and `cid add` refuses them: said here too, so a
/// folder of links never reads as a clean, empty dataset.
fn printLinks(out: *std.Io.Writer, st: workspace.Status) !void {
    if (st.links.len == 0) return;
    try out.writeAll("\nSymbolic links, not stored (cid stores files; copy them in with 'cp -L', or name them in .cidignore):\n");
    for (st.links[0..@min(st.links.len, 10)]) |p| try out.print("  link      {s}\n", .{p});
    if (st.links.len > 10) try out.print("  … and {d} more\n", .{st.links.len - 10});
}

fn plural(n: u32) []const u8 {
    return if (n == 1) "" else "s";
}
