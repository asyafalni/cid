//! `cid clone <address> [folder]`: download a dataset into a new folder.

const std = @import("std");
const common = @import("common.zig");
const workspace = @import("../client/workspace.zig");
const sync = @import("../client/sync.zig");

pub fn run(ctx: *const common.Context, args: []const [:0]const u8) common.ExitCode {
    if (args.len == 0 or args.len > 2)
        return common.fail(ctx, .usage, "run 'cid clone <address> [folder]', e.g. cid clone cid@cidhub.com:org/datasets/calls", .{});
    const address = args[0];
    const name = workspace.datasetPathOf(address) orelse
        return common.fail(ctx, .usage, "'{s}' is not a cid address (expected cid@host:org/path). Check it and run 'cid clone' again.", .{address});

    const dest = if (args.len == 2) args[1] else lastSegment(name);
    const cwd = std.Io.Dir.cwd();
    if (cwd.access(ctx.io, dest, .{})) |_| {
        return common.fail(ctx, .usage, "'{s}' already exists here. Remove it or pick another folder: cid clone <address> <folder>.", .{dest});
    } else |_| {}
    cwd.createDirPath(ctx.io, dest) catch
        return common.fail(ctx, .network, "cannot create '{s}'. Check permissions, then run 'cid clone' again.", .{dest});
    const dest_dir = cwd.openDir(ctx.io, dest, .{ .iterate = true }) catch
        return common.fail(ctx, .network, "cannot open '{s}'. Check permissions, then run 'cid clone' again.", .{dest});

    const cache_dir = common.openCacheDir(ctx) catch
        return common.fail(ctx, .network, "cannot open the cache folder (~/.cache/cid). Check HOME, then run 'cid clone' again.", .{});
    const remote = common.remoteFor(ctx, name, .read, address) catch
        return common.fail(ctx, .usage, common.no_server_msg, .{});

    const outcome = sync.clone(ctx.arena, ctx.io, dest_dir, cache_dir, remote, address) catch |err| switch (err) {
        error.NoSuchDataset => return common.fail(ctx, .usage, "no dataset '{s}' on the server. Check the address, or create it with 'cid init'.", .{name}),
        error.EmptyDataset => return common.fail(ctx, .usage, "'{s}' has nothing pushed yet. Push from the producing folder first.", .{name}),
        error.ServerUnreachable => return common.fail(ctx, .network, "cannot reach the server. Check CID_SERVER, then run 'cid clone' again.", .{}),
        error.TransferFailed => return common.fail(ctx, .integrity, "a download failed its hash check or the connection broke. Run 'cid clone' again.", .{}),
        else => return common.fail(ctx, .network, "clone failed. Fix the cause above, then run 'cid clone' again.", .{}),
    };

    ctx.out.print("Cloned {s} into {s}/: {d} file{s} ({d} downloaded, the rest from the local cache).\n", .{
        name, dest, outcome.files, plural(outcome.files), outcome.downloaded,
    }) catch return .network;
    return .ok;
}

fn lastSegment(name: []const u8) []const u8 {
    const sep = std.mem.lastIndexOfScalar(u8, name, '/') orelse return name;
    return name[sep + 1 ..];
}

fn plural(n: u32) []const u8 {
    return if (n == 1) "" else "s";
}
