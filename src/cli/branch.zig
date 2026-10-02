//! `cid branch <name>`: a draft line of work on the server, always
//! starting from main (invariant 8).

const std = @import("std");
const common = @import("common.zig");
const workspace = @import("../client/workspace.zig");
const local = @import("../client/local.zig");

pub fn run(ctx: *const common.Context, args: []const [:0]const u8) common.ExitCode {
    if (args.len != 1)
        return common.fail(ctx, .usage, "run 'cid branch <name>', e.g. cid branch cleanup", .{});
    const name = args[0];

    const ws = common.openWorkspace(ctx) catch
        return common.fail(ctx, .usage, common.not_a_dataset_msg, .{});
    const last_pushed = local.readLastPushed(ctx.arena, ctx.io, ws.cid_dir);
    const unpushed = local.listUnpushed(ctx.arena, ctx.io, ws.cid_dir, last_pushed) catch
        return common.fail(ctx, .integrity, ".cid/ state is unreadable. Run 'cid status' for details.", .{});
    if (unpushed.len > 0)
        return common.fail(ctx, .usage, "branches start from pushed history. Run 'cid push' first, then 'cid branch {s}' again.", .{name});

    const dataset = workspace.datasetPathOf(ws.config.address) orelse
        return common.fail(ctx, .integrity, ".cid/config.zon holds a broken address. Clone again, or fix it to cid@host:org/path.", .{});
    const remote = common.remoteFor(ctx, dataset, .write, ws.config.address) catch |err|
        return common.noRemote(ctx, err, "cid branch");

    _ = remote.branchCreate(ctx.arena, name) catch |err| switch (err) {
        error.BranchExists => return common.fail(ctx, .conflict, "'{s}' already exists. Run 'cid checkout {s}' to work on it.", .{ name, name }),
        error.BadReleaseName => return common.fail(ctx, .usage, "'{s}' is not a branch name (letters, digits, dot, dash, underscore). Run 'cid branch cleanup'.", .{name}),
        error.NothingToTag => return common.fail(ctx, .usage, "main has no commits yet. Run 'cid push' first.", .{}),
        error.AccessDenied => return common.denied(ctx, "cid branch"),
        error.ServerUnreachable => return common.fail(ctx, .network, "cannot reach the server. Check the connection, then run 'cid branch' again.", .{}),
        else => return common.fail(ctx, .network, "the server refused. Check the server logs, then run 'cid branch' again.", .{}),
    };
    ctx.out.print("Branch '{s}' created from main. Run 'cid checkout {s}' to work on it.\n", .{ name, name }) catch return .network;
    return .ok;
}
