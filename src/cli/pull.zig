//! `cid pull`: fast-forward the folder to the server's newest commit.
//! Replaying unpushed local commits onto new history is a coming slice;
//! until then pull says so instead of guessing.

const std = @import("std");
const common = @import("common.zig");
const workspace = @import("../client/workspace.zig");
const sync = @import("../client/sync.zig");

pub fn run(ctx: *const common.Context) common.ExitCode {
    var ws = common.openWorkspace(ctx) catch
        return common.fail(ctx, .usage, common.not_a_dataset_msg, .{});
    const cache_dir = common.openCacheDir(ctx) catch
        return common.fail(ctx, .network, "cannot open the cache folder (~/.cache/cid). Check HOME, then run 'cid pull' again.", .{});
    const name = workspace.datasetPathOf(ws.config.address) orelse
        return common.fail(ctx, .integrity, ".cid/config.zon holds a broken address. Clone again, or fix it to cid@host:org/path.", .{});
    const remote = common.remoteFor(ctx, name) catch
        return common.fail(ctx, .usage, common.no_server_msg, .{});

    const outcome = sync.pull(ctx.arena, ctx.io, &ws, cache_dir, remote) catch |err| switch (err) {
        error.UnpushedCommits => return common.fail(ctx, .conflict, "you have local commits not pushed. Run 'cid push' first. (Replaying them onto new history is not built yet.)", .{}),
        error.LocalChangesInTheWay => return common.fail(ctx, .conflict, "local edits would be overwritten. Commit them ('cid commit -a -m \"...\"') or move them aside, then run 'cid pull' again.", .{}),
        error.EmptyDataset => return common.fail(ctx, .usage, "the server has nothing for this dataset yet. Run 'cid push' first.", .{}),
        error.ServerUnreachable => return common.fail(ctx, .network, "cannot reach the server. Check CID_SERVER, then run 'cid pull' again.", .{}),
        error.TransferFailed => return common.fail(ctx, .integrity, "a download failed its hash check or the connection broke. Run 'cid pull' again.", .{}),
        else => return common.fail(ctx, .integrity, ".cid/ state is unreadable. Run 'cid status' for details.", .{}),
    };

    switch (outcome) {
        .already_up_to_date => ctx.out.writeAll("Already up to date.\n") catch return .network,
        .fast_forwarded => |ff| ctx.out.print("Updated to {s}: {d} file{s} changed.\n", .{
            ff.head_commit[0..13], ff.files_changed, plural(ff.files_changed),
        }) catch return .network,
    }
    return .ok;
}

fn plural(n: u32) []const u8 {
    return if (n == 1) "" else "s";
}
