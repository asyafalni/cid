//! `cid pull`: fast-forward the folder to the server's newest commit.
//! Replaying unpushed local commits onto new history is a coming slice;
//! until then pull says so instead of guessing.

const std = @import("std");
const common = @import("common.zig");
const workspace = @import("../client/workspace.zig");
const sync = @import("../client/sync.zig");

/// `cid pull --continue` finishes a pull whose conflicts are decided, as in
/// git; plain `cid pull` does the same, so either works.
pub fn run(ctx: *const common.Context, args: []const [:0]const u8) common.ExitCode {
    for (args) |a| if (!std.mem.eql(u8, a, "--continue"))
        return common.fail(ctx, .usage, "'cid pull' takes no '{s}'. Run 'cid pull', or 'cid pull --continue' once conflicts are decided.", .{a});
    var ws = common.openWorkspace(ctx) catch
        return common.fail(ctx, .usage, common.not_a_dataset_msg, .{});
    const cache_dir = common.openCacheDir(ctx) catch
        return common.fail(ctx, .network, "cannot open the cache folder (~/.cache/cid). Check HOME, then run 'cid pull' again.", .{});
    const name = workspace.datasetPathOf(ws.config.address) orelse
        return common.fail(ctx, .integrity, ".cid/config.zon holds a broken address. Clone again, or fix it to cid@host:org/path.", .{});
    const remote = common.remoteFor(ctx, name, .read, ws.config.address) catch |err|
        return common.noRemote(ctx, err, "cid pull");

    const outcome = sync.pull(ctx.arena, ctx.io, &ws, cache_dir, remote) catch |err| switch (err) {
        error.StagedChanges => return common.fail(ctx, .conflict, "you have staged changes. Commit them ('cid commit -m \"...\"') or unstage ('cid restore --staged'), then run 'cid pull' again.", .{}),
        error.LocalChangesInTheWay => return common.fail(ctx, .conflict, "local edits would be overwritten. Commit them ('cid commit -a -m \"...\"') or move them aside, then run 'cid pull' again.", .{}),
        error.EmptyDataset => return common.fail(ctx, .usage, "the server has nothing for this dataset yet. Run 'cid push' first.", .{}),
        error.AccessDenied => return common.denied(ctx, "cid pull"),
        error.ServerUnreachable => return common.fail(ctx, .network, "cannot reach the server. Check CID_SERVER, then run 'cid pull' again.", .{}),
        error.ExportFailed => return common.fail(ctx, .integrity, "the export sidecars could not be rebuilt (see the warning above). Fix the data in the platform, then run the command again.", .{}),
        error.Collected => return common.fail(ctx, .integrity, "this version needs files cleanup removed from the server: it is in no release and no branch head; the folder was not changed. Run 'cid log' and check out a release or a branch instead.", .{}),
        error.Corrupt => return common.fail(ctx, .integrity, "what the server sent failed its hash check; the folder was not changed. Run 'cid pull' again.", .{}),
        error.ServerRefused => return common.fail(ctx, .network, "the server could not answer (see its message above, if any). Run 'cid pull' again; if it persists, tell the dataset's owner.", .{}),
        error.TransferFailed => return common.fail(ctx, .integrity, "a download failed its hash check or the connection broke. Run 'cid pull' again.", .{}),
        else => return common.fail(ctx, .integrity, ".cid/ state is unreadable. Run 'cid status' for details.", .{}),
    };

    switch (outcome) {
        .conflicts => {},
        inline else => |v, tag| if (common.emitJson(ctx, .{ .result = @tagName(tag), .details = v })) return .ok,
    }
    switch (outcome) {
        .already_up_to_date => ctx.out.writeAll("Already up to date.\n") catch return .network,
        .fast_forwarded => |ff| ctx.out.print("Updated to {s}: {d} file{s} changed.\n", .{
            ff.head_commit[0..13], ff.files_changed, plural(ff.files_changed),
        }) catch return .network,
        .replayed => |r| ctx.out.print("Updated to {s} and replayed {d} local commit{s} on top ({d} file{s} changed). Run 'cid push' when ready.\n", .{
            r.head_commit[0..13], r.commits, plural(r.commits), r.files_changed, plural(r.files_changed),
        }) catch return .network,
        .conflicts => |list| {
            var buf: [4096]u8 = undefined;
            var stderr_writer = std.Io.File.stderr().writer(ctx.io, &buf);
            const err_w = &stderr_writer.interface;
            err_w.writeAll("cid: you and the server changed the same files; nothing was merged.\n") catch {};
            for (list) |c| {
                switch (c.choice) {
                    .undecided => err_w.print("  both changed  {s}\n", .{c.path}) catch {},
                    .mine => err_w.print("  keeping yours {s}\n", .{c.path}) catch {},
                    .theirs => err_w.print("  taking theirs {s}\n", .{c.path}) catch {},
                }
            }
            err_w.writeAll(
                "Decide each file with 'cid checkout --mine <path>' (keep yours) or\n" ++
                    "'cid checkout --theirs <path>' (take the server's), then run 'cid pull --continue'.\n",
            ) catch {};
            err_w.flush() catch {};
            return .conflict;
        },
    }
    return .ok;
}

fn plural(n: u32) []const u8 {
    return if (n == 1) "" else "s";
}
