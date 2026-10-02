//! `cid merge <name>`: merge a branch into main, on the server. Stops
//! and lists conflicts; a person decides each one (invariant 9): `cid
//! checkout --mine <path>` keeps main's version, `--theirs` takes the
//! branch's, then `cid merge --continue` finishes it, as in git.

const std = @import("std");
const common = @import("common.zig");
const workspace = @import("../client/workspace.zig");
const sync = @import("../client/sync.zig");
const remote_mod = @import("../client/remote.zig");

pub fn run(ctx: *const common.Context, args: []const [:0]const u8) common.ExitCode {
    if (args.len != 1)
        return common.fail(ctx, .usage, "run 'cid merge <branch>', e.g. cid merge cleanup, or 'cid merge --continue' once conflicts are decided", .{});
    var ws = common.openWorkspace(ctx) catch
        return common.fail(ctx, .usage, common.not_a_dataset_msg, .{});

    // The branch, and any decisions taken since the merge stopped.
    const continuing = std.mem.eql(u8, args[0], "--continue");
    var resolve: []const remote_mod.Remote.Resolution = &.{};
    const name: []const u8 = if (continuing) blk: {
        const state = sync.loadMerge(ctx.arena, ctx.io, &ws) orelse
            return common.fail(ctx, .usage, "no merge is waiting for decisions. Run 'cid merge <branch>'.", .{});
        var undecided: usize = 0;
        const list = ctx.arena.alloc(remote_mod.Remote.Resolution, state.conflicts.len) catch return .network;
        for (state.conflicts, list) |c, *r| {
            if (c.choice == .undecided) undecided += 1;
            r.* = .{ .path = c.path, .take = if (c.choice == .mine) "main" else "branch" };
        }
        if (undecided > 0) {
            listConflicts(ctx, state.branch, state.conflicts, "still undecided");
            return .conflict;
        }
        resolve = list;
        break :blk state.branch;
    } else args[0];

    const dataset = workspace.datasetPathOf(ws.config.address) orelse
        return common.fail(ctx, .integrity, ".cid/config.zon holds a broken address. Clone again, or fix it to cid@host:org/path.", .{});
    const remote = common.remoteFor(ctx, dataset, .maintain, ws.config.address) catch |err|
        return common.noRemote(ctx, err, "cid merge");

    const author = common.author(ctx) catch return .network;
    const result = remote.merge(ctx.arena, name, author, resolve) catch |err| switch (err) {
        error.NoSuchBranch => return common.fail(ctx, .usage, "no branch named '{s}'. Run 'cid branch {s}' to create it.", .{ name, name }),
        error.AccessDenied => return common.denied(ctx, "cid merge"),
        error.ServerUnreachable => return common.fail(ctx, .network, "cannot reach the server. Check the connection, then run 'cid merge' again.", .{}),
        else => return common.fail(ctx, .network, "the server refused. Check the server logs, then run 'cid merge' again.", .{}),
    };
    switch (result) {
        .merged => |m| {
            sync.finishMerge(ctx.io, &ws);
            ctx.out.print("Merged '{s}' into main as {s} ({d} change{s}). Run 'cid checkout main' then 'cid pull' to see it.\n", .{
                name, m.commit[0..13], m.changes, plural(m.changes),
            }) catch return .network;
        },
        .nothing_to_merge => {
            sync.finishMerge(ctx.io, &ws);
            ctx.out.writeAll("Main already has everything from that branch. Nothing to do.\n") catch return .network;
        },
        .conflicts => |paths| {
            // New ones (main moved meanwhile) join the list, undecided.
            sync.startMerge(ctx.arena, ctx.io, &ws, name, paths) catch
                return common.fail(ctx, .integrity, ".cid/ state is unwritable. Check the folder, then run 'cid merge {s}' again.", .{name});
            const state = sync.loadMerge(ctx.arena, ctx.io, &ws).?;
            listConflicts(ctx, name, state.conflicts, "nothing was merged");
            return .conflict;
        },
    }
    return .ok;
}

fn listConflicts(ctx: *const common.Context, branch: []const u8, conflicts: []const sync.Conflict, what: []const u8) void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writer(ctx.io, &buf);
    const err_w = &w.interface;
    err_w.print("cid: both main and '{s}' changed these files; {s}:\n", .{ branch, what }) catch {};
    for (conflicts) |c| if (c.choice == .undecided) err_w.print("  {s}\n", .{c.path}) catch {};
    err_w.writeAll("Decide each: 'cid checkout --mine <path>' keeps main's version, 'cid checkout --theirs <path>'\n" ++
        "takes the branch's. Then run 'cid merge --continue'.\n") catch {};
    err_w.flush() catch {};
}

fn plural(n: anytype) []const u8 {
    return if (n == 1) "" else "s";
}
