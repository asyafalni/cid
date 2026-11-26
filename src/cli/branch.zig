//! `cid branch <name>`: a draft line of work on the server, always
//! starting from main (invariant 8). `cid branch` alone (or `-a`, `-l`,
//! `--list`) lists the branches, the folder's marked, as git's does.

const std = @import("std");
const common = @import("common.zig");
const workspace = @import("../client/workspace.zig");
const local = @import("../client/local.zig");

const usage = "run 'cid branch <name>' to start one, e.g. cid branch cleanup, or 'cid branch' to list them";
const usage_sentence = "Run" ++ usage["run".len..];

pub fn run(ctx: *const common.Context, args: []const [:0]const u8) common.ExitCode {
    var list = args.len == 0;
    for (args) |a| {
        if (std.mem.eql(u8, a, "-a") or std.mem.eql(u8, a, "-l") or std.mem.eql(u8, a, "--list") or std.mem.eql(u8, a, "--all")) {
            list = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            return common.fail(ctx, .usage, "'{s}' is not an option of cid branch. {s}.", .{ a, usage_sentence });
        }
    }
    if (list and args.len > 1) return common.fail(ctx, .usage, "{s}.", .{usage_sentence});
    if (!list and args.len != 1) return common.fail(ctx, .usage, "{s}", .{usage});

    const ws = common.openWorkspace(ctx) catch
        return common.fail(ctx, .usage, common.not_a_dataset_msg, .{});
    if (list) return listBranches(ctx, ws);
    const name = args[0];
    const last_pushed = local.readLastPushed(ctx.arena, ctx.io, ws.cid_dir);
    const unpushed = local.listUnpushed(ctx.arena, ctx.io, ws.cid_dir, last_pushed) catch
        return common.fail(ctx, .integrity, ".cid/ state is unreadable. Run 'cid status' for details.", .{});
    if (unpushed.len > 0)
        return common.fail(ctx, .usage, "branches start from pushed history. Run 'cid push' first, then 'cid branch {s}' again.", .{name});

    const dataset = workspace.datasetPathOf(ws.config.address) orelse
        return common.fail(ctx, .integrity, ".cid/config.zon holds a broken address. Clone again, or fix it to cid@host:org/path.", .{});
    const remote = common.remoteFor(ctx, dataset, .maintain, ws.config.address) catch |err|
        return common.noRemote(ctx, err, "cid branch");

    _ = remote.branchCreate(ctx.arena, name) catch |err| switch (err) {
        error.BranchExists => return common.fail(ctx, .conflict, "'{s}' already exists. Run 'cid checkout {s}' to work on it.", .{ name, name }),
        error.BadReleaseName => return common.fail(ctx, .usage, "'{s}' is not a branch name (letters, digits, dot, dash, underscore). Run 'cid branch cleanup'.", .{name}),
        error.NothingToTag => return common.fail(ctx, .usage, "main has no commits yet. Run 'cid push' first.", .{}),
        error.AccessDenied => return common.denied(ctx, "cid branch"),
        error.ServerUnreachable => return common.fail(ctx, .network, "cannot reach the server. Check the connection, then run 'cid branch' again.", .{}),
        else => return common.fail(ctx, .network, "the server refused. Check the server logs, then run 'cid branch' again.", .{}),
    };
    if (common.emitJson(ctx, .{ .branch = name })) return .ok;
    ctx.out.print("Branch '{s}' created from main. Run 'cid checkout {s}' to work on it.\n", .{ name, name }) catch return .network;
    return .ok;
}

/// `cid branch` alone: every branch on the server, one a line, the one
/// this folder is on marked with `*`, as `git branch` marks it.
fn listBranches(ctx: *const common.Context, ws: workspace.Workspace) common.ExitCode {
    const dataset = workspace.datasetPathOf(ws.config.address) orelse
        return common.fail(ctx, .integrity, ".cid/config.zon holds a broken address. Clone again, or fix it to cid@host:org/path.", .{});
    const here = (local.loadHead(ctx.arena, ctx.io, ws.cid_dir) catch
        return common.fail(ctx, .integrity, ".cid/ state is unreadable. Run 'cid status' for details.", .{})).branch;
    const remote = common.remoteFor(ctx, dataset, .read, ws.config.address) catch |err|
        return common.noRemote(ctx, err, "cid branch");
    const branches = remote.branches(ctx.arena) catch |err| switch (err) {
        error.NoSuchDataset => return common.fail(ctx, .usage, "the dataset is not on the server yet. Run 'cid push' first.", .{}),
        error.AccessDenied => return common.denied(ctx, "cid branch"),
        else => return common.fail(ctx, .network, "cannot reach the server. Check CID_SERVER, then run 'cid branch' again.", .{}),
    };
    if (common.emitJson(ctx, .{ .branches = branches, .current = here })) return .ok;
    var listed_here = false;
    for (branches) |b| {
        const mine = std.mem.eql(u8, b.name, here);
        listed_here = listed_here or mine;
        ctx.out.print("{s} {s}\t{s}\n", .{ if (mine) "*" else " ", b.name, b.commit[0..@min(b.commit.len, 13)] }) catch return .network;
    }
    // A folder on main before its first push: main is still its branch.
    if (!listed_here) ctx.out.print("* {s}\t(no commits pushed yet)\n", .{here}) catch return .network;
    return .ok;
}
