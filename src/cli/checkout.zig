//! `cid checkout <commit>`: switch the folder to another commit; only
//! changed files transfer. Releases and branches join when `cid tag` and
//! `cid branch` land.

const std = @import("std");
const common = @import("common.zig");
const workspace = @import("../client/workspace.zig");
const sync = @import("../client/sync.zig");

pub fn run(ctx: *const common.Context, args: []const [:0]const u8) common.ExitCode {
    if (args.len != 1)
        return common.fail(ctx, .usage, "run 'cid checkout <commit>' with an id from 'cid log'.", .{});
    const commit_id = args[0];

    var ws = common.openWorkspace(ctx) catch
        return common.fail(ctx, .usage, common.not_a_dataset_msg, .{});
    const cache_dir = common.openCacheDir(ctx) catch
        return common.fail(ctx, .network, "cannot open the cache folder (~/.cache/cid). Check HOME, then run 'cid checkout' again.", .{});
    const name = workspace.datasetPathOf(ws.config.address) orelse
        return common.fail(ctx, .integrity, ".cid/config.zon holds a broken address. Clone again, or fix it to cid@host:org/path.", .{});
    const remote = common.remoteFor(ctx, name) catch
        return common.fail(ctx, .usage, common.no_server_msg, .{});

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

fn plural(n: u32) []const u8 {
    return if (n == 1) "" else "s";
}
