//! `cid push`: upload local commits and their new files; resumable by
//! re-running (uploads are idempotent by hash, recording is all-or-nothing).

const std = @import("std");
const common = @import("common.zig");
const workspace = @import("../client/workspace.zig");
const sync = @import("../client/sync.zig");

pub fn run(ctx: *const common.Context) common.ExitCode {
    var ws = common.openWorkspace(ctx) catch
        return common.fail(ctx, .usage, common.not_a_dataset_msg, .{});
    const cache_dir = common.openCacheDir(ctx) catch
        return common.fail(ctx, .network, "cannot open the cache folder (~/.cache/cid). Check HOME, then run 'cid push' again.", .{});
    const name = workspace.datasetPathOf(ws.config.address) orelse
        return common.fail(ctx, .integrity, ".cid/config.zon holds a broken address. Clone again, or fix it to cid@host:org/path.", .{});
    const remote = common.remoteFor(ctx, name, .write, ws.config.address) catch
        return common.fail(ctx, .usage, common.no_server_msg, .{});

    const outcome = sync.push(ctx.arena, ctx.io, &ws, cache_dir, remote) catch |err| switch (err) {
        error.Stale => return common.fail(ctx, .conflict, "someone pushed since you pulled. Run 'cid pull', then 'cid push' again.", .{}),
        error.AccessDenied => return common.denied(ctx, "cid push"),
        error.ServerUnreachable => return common.fail(ctx, .network, "cannot reach the server. Check CID_SERVER, then run 'cid push' again.", .{}),
        error.MissingContent => return common.fail(ctx, .network, "the server lost track of an upload. Run 'cid push' again; it resumes.", .{}),
        error.CacheDamaged => return common.fail(ctx, .integrity, "a committed file changed after 'cid add', in the cache and in the folder. Put it back as committed, then run 'cid push' again.", .{}),
        error.TransferFailed => return common.fail(ctx, .network, "an upload failed. Check the connection, then run 'cid push' again; nothing is lost.", .{}),
        else => return common.fail(ctx, .integrity, ".cid/ state is unreadable. Run 'cid status' for details.", .{}),
    };

    if (outcome.pushed_commits == 0) {
        ctx.out.writeAll("Everything up to date.\n") catch return .network;
    } else {
        ctx.out.print("Pushed {d} commit{s} ({d} file{s} uploaded) to {s}.\n", .{
            outcome.pushed_commits, plural(outcome.pushed_commits),
            outcome.uploaded_files, plural(outcome.uploaded_files),
            ws.config.address,
        }) catch return .network;
    }
    return .ok;
}

fn plural(n: u32) []const u8 {
    return if (n == 1) "" else "s";
}
