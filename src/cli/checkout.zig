//! `cid checkout <commit>`: switch the folder to another commit; only
//! changed files transfer. Releases and branches join when `cid tag` and
//! `cid branch` land.

const std = @import("std");
const common = @import("common.zig");
const workspace = @import("../client/workspace.zig");
const local = @import("../client/local.zig");
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
    const remote = common.remoteFor(ctx, name, .read, ws.config.address) catch
        return common.fail(ctx, .usage, common.no_server_msg, .{});

    // Resolution order: release name, then branch name, then a commit id.
    var branch: []const u8 = "";
    var move_root = false;
    const commit_id: []const u8 = blk: {
        if (target.len == 36) break :blk target;
        const list = remote.releases(ctx.arena) catch
            return common.fail(ctx, .network, "cannot reach the server to resolve '{s}'. Check the connection, then run 'cid checkout' again.", .{target});
        for (list) |r| {
            if (std.mem.eql(u8, r.name, target)) break :blk r.commit;
        }
        const branch_list = remote.branches(ctx.arena) catch
            return common.fail(ctx, .network, "cannot reach the server to resolve '{s}'. Check the connection, then run 'cid checkout' again.", .{target});
        for (branch_list) |b| {
            if (std.mem.eql(u8, b.name, target)) {
                branch = b.name;
                move_root = true;
                break :blk b.commit;
            }
        }
        return common.fail(ctx, .usage, "'{s}' is neither a release, a branch nor a commit here. Run 'cid log', or 'cid branch {s}' to create the branch.", .{ target, target });
    };
    if (branch.len == 0) {
        const head = local.loadHead(ctx.arena, ctx.io, ws.cid_dir) catch
            return common.fail(ctx, .integrity, ".cid/ state is unreadable. Run 'cid status' for details.", .{});
        branch = head.branch;
    }

    const changed = sync.checkout(ctx.arena, ctx.io, &ws, cache_dir, remote, branch, commit_id, move_root) catch |err| switch (err) {
        error.UnpushedCommits => return common.fail(ctx, .conflict, "you have local commits not pushed; switching would hide them. Run 'cid push' first.", .{}),
        error.LocalChangesInTheWay => return common.fail(ctx, .conflict, "local edits would be overwritten. Commit them ('cid commit -a -m \"...\"') or move them aside, then run 'cid checkout' again.", .{}),
        error.NoSuchDataset => return common.fail(ctx, .usage, "no such commit here. Run 'cid log' to list commits.", .{}),
        error.AccessDenied => return common.denied(ctx, "cid checkout"),
        error.ServerUnreachable => return common.fail(ctx, .network, "cannot reach the server. Check CID_SERVER, then run 'cid checkout' again.", .{}),
        error.ExportFailed => return common.fail(ctx, .integrity, "the export sidecars could not be rebuilt (see the warning above). Fix the data in the platform, then run the command again.", .{}),
        error.Collected => return common.fail(ctx, .integrity, "this version needs files cleanup removed from the server: it is in no release and no branch head; the folder was not changed. Run 'cid log' and check out a release or a branch instead.", .{}),
        error.Corrupt => return common.fail(ctx, .integrity, "what the server sent failed its hash check; the folder was not changed. Run 'cid checkout' again.", .{}),
        error.ServerRefused => return common.fail(ctx, .network, "the server could not answer (see its message above, if any). Run 'cid checkout' again; if it persists, tell the dataset's owner.", .{}),
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
