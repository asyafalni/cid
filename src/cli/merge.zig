//! `cid merge <name>`: merge a branch into main, on the server. Stops
//! and lists conflicts; a person decides (invariant 9).

const std = @import("std");
const common = @import("common.zig");
const workspace = @import("../client/workspace.zig");

pub fn run(ctx: *const common.Context, args: []const [:0]const u8) common.ExitCode {
    if (args.len != 1)
        return common.fail(ctx, .usage, "run 'cid merge <branch>', e.g. cid merge cleanup", .{});
    const name = args[0];

    const ws = common.openWorkspace(ctx) catch
        return common.fail(ctx, .usage, common.not_a_dataset_msg, .{});
    const dataset = workspace.datasetPathOf(ws.config.address) orelse
        return common.fail(ctx, .integrity, ".cid/config.zon holds a broken address. Clone again, or fix it to cid@host:org/path.", .{});
    const remote = common.remoteFor(ctx, dataset, .write, ws.config.address) catch
        return common.fail(ctx, .usage, common.no_server_msg, .{});

    const author = common.author(ctx) catch return .network;
    const result = remote.merge(ctx.arena, name, author) catch |err| switch (err) {
        error.NoSuchBranch => return common.fail(ctx, .usage, "no branch named '{s}'. Run 'cid branch {s}' to create it.", .{ name, name }),
        error.AccessDenied => return common.denied(ctx, "cid merge"),
        error.ServerUnreachable => return common.fail(ctx, .network, "cannot reach the server. Check the connection, then run 'cid merge' again.", .{}),
        else => return common.fail(ctx, .network, "the server refused. Check the server logs, then run 'cid merge' again.", .{}),
    };
    switch (result) {
        .merged => |m| ctx.out.print("Merged '{s}' into main as {s} ({d} change{s}). Run 'cid checkout main' then 'cid pull' to see it.\n", .{
            name, m.commit[0..13], m.changes, plural(m.changes),
        }) catch return .network,
        .nothing_to_merge => ctx.out.writeAll("Main already has everything from that branch. Nothing to do.\n") catch return .network,
        .conflicts => |paths| {
            var buf: [4096]u8 = undefined;
            var w = std.Io.File.stderr().writer(ctx.io, &buf);
            const err_w = &w.interface;
            err_w.print("cid: both main and '{s}' changed these files; nothing was merged:\n", .{name}) catch {};
            for (paths) |p| err_w.print("  {s}\n", .{p}) catch {};
            err_w.print("Put the wanted versions on the branch ('cid checkout {s}', edit, commit, push), then run 'cid merge {s}' again.\n", .{ name, name }) catch {};
            err_w.flush() catch {};
            return .conflict;
        },
    }
    return .ok;
}

fn plural(n: anytype) []const u8 {
    return if (n == 1) "" else "s";
}
