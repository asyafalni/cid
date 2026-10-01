//! `cid checkout <commit>`: switch the folder to another commit; only
//! changed files transfer. Releases and branches join when `cid tag` and
//! `cid branch` land.

const std = @import("std");
const common = @import("common.zig");
const workspace = @import("../client/workspace.zig");
const sync = @import("../client/sync.zig");

pub fn run(ctx: *const common.Context, args: []const [:0]const u8) common.ExitCode {
    // During a conflicted pull: 'cid checkout --mine|--theirs <path>...'.
    if (args.len >= 1 and (std.mem.eql(u8, args[0], "--mine") or std.mem.eql(u8, args[0], "--theirs"))) {
        return decide(ctx, args);
    }

    if (args.len != 1)
        return common.fail(ctx, .usage, "run 'cid checkout <release|commit>' with a name or id from 'cid log'.", .{});
    const target = args[0];

    var ws = common.openWorkspace(ctx) catch
        return common.fail(ctx, .usage, common.not_a_dataset_msg, .{});
    const cache_dir = common.openCacheDir(ctx) catch
        return common.fail(ctx, .network, "cannot open the cache folder (~/.cache/cid). Check HOME, then run 'cid checkout' again.", .{});
    const name = workspace.datasetPathOf(ws.config.address) orelse
        return common.fail(ctx, .integrity, ".cid/config.zon holds a broken address. Clone again, or fix it to cid@host:org/path.", .{});
    const remote = common.remoteFor(ctx, name) catch
        return common.fail(ctx, .usage, common.no_server_msg, .{});

    // A release name resolves to its commit; a 36-char id is used as-is.
    const commit_id: []const u8 = blk: {
        if (target.len == 36) break :blk target;
        const list = remote.releases(ctx.arena) catch
            return common.fail(ctx, .network, "cannot reach the server to resolve '{s}'. Check CID_SERVER, then run 'cid checkout' again.", .{target});
        for (list) |r| {
            if (std.mem.eql(u8, r.name, target)) break :blk r.commit;
        }
        return common.fail(ctx, .usage, "no release named '{s}'. Run 'cid log' for commits, or ask the owner which releases exist.", .{target});
    };

    const changed = sync.checkout(ctx.arena, ctx.io, &ws, cache_dir, remote, commit_id) catch |err| switch (err) {
        error.LocalChangesInTheWay => return common.fail(ctx, .conflict, "local edits would be overwritten. Commit them ('cid commit -a -m \"...\"') or move them aside, then run 'cid checkout' again.", .{}),
        error.NoSuchDataset => return common.fail(ctx, .usage, "no such commit here. Run 'cid log' to list commits.", .{}),
        error.ServerUnreachable => return common.fail(ctx, .network, "cannot reach the server. Check CID_SERVER, then run 'cid checkout' again.", .{}),
        error.TransferFailed => return common.fail(ctx, .integrity, "a download failed its hash check. Run 'cid checkout' again.", .{}),
        else => return common.fail(ctx, .integrity, ".cid/ state is unreadable. Run 'cid status' for details.", .{}),
    };

    ctx.out.print("Switched to {s}: {d} file{s} changed. 'cid pull' returns to the latest.\n", .{
        commit_id[0..@min(13, commit_id.len)], changed, plural(changed),
    }) catch return .network;
    return .ok;
}

fn decide(ctx: *const common.Context, args: []const [:0]const u8) common.ExitCode {
    const choice: sync.Choice = if (std.mem.eql(u8, args[0], "--mine")) .mine else .theirs;
    if (args.len < 2)
        return common.fail(ctx, .usage, "name the file, e.g. 'cid checkout {s} data.csv'.", .{args[0]});

    var ws = common.openWorkspace(ctx) catch
        return common.fail(ctx, .usage, common.not_a_dataset_msg, .{});

    var remaining: usize = 0;
    for (args[1..]) |path| {
        const result = sync.decide(ctx.arena, ctx.io, &ws, path, choice) catch
            return common.fail(ctx, .integrity, ".cid/ state is unreadable. Run 'cid status' for details.", .{});
        switch (result) {
            .no_conflicts => return common.fail(ctx, .usage, "no conflicted pull is in progress. Run 'cid pull'.", .{}),
            .unknown_path => return common.fail(ctx, .usage, "'{s}' is not one of the conflicted files. Run 'cid pull' to list them.", .{path}),
            .remaining => |n| remaining = n,
        }
    }
    if (remaining == 0) {
        ctx.out.writeAll("Every conflict is decided. Run 'cid pull' to finish.\n") catch return .network;
    } else {
        ctx.out.print("{d} file{s} still undecided. Run 'cid pull' to list them.\n", .{ remaining, plural(@intCast(remaining)) }) catch return .network;
    }
    return .ok;
}

fn plural(n: u32) []const u8 {
    return if (n == 1) "" else "s";
}
