//! `cid tag <name>`: make a release from the branch head, on the server.
//! Needs everything pushed first, and says so.

const std = @import("std");
const common = @import("common.zig");
const workspace = @import("../client/workspace.zig");
const local = @import("../client/local.zig");

pub fn run(ctx: *const common.Context, args: []const [:0]const u8) common.ExitCode {
    if (args.len != 1)
        return common.fail(ctx, .usage, "run 'cid tag <name>', e.g. cid tag v1.0.0", .{});
    const name = args[0];

    const ws = common.openWorkspace(ctx) catch
        return common.fail(ctx, .usage, common.not_a_dataset_msg, .{});

    // Releases are made on the server from pushed history (CLI reference).
    const last_pushed = local.readLastPushed(ctx.arena, ctx.io, ws.cid_dir);
    const unpushed = local.listUnpushed(ctx.arena, ctx.io, ws.cid_dir, last_pushed) catch
        return common.fail(ctx, .integrity, ".cid/ state is unreadable. Run 'cid status' for details.", .{});
    if (unpushed.len > 0)
        return common.fail(ctx, .usage, "you have {d} local commit{s} not pushed; a release tags the server's history. Run 'cid push', then 'cid tag {s}' again.", .{ unpushed.len, plural(unpushed.len), name });

    const dataset = workspace.datasetPathOf(ws.config.address) orelse
        return common.fail(ctx, .integrity, ".cid/config.zon holds a broken address. Clone again, or fix it to cid@host:org/path.", .{});
    const remote = common.remoteFor(ctx, dataset) catch
        return common.fail(ctx, .usage, common.no_server_msg, .{});

    const result = remote.tag(ctx.arena, name) catch |err| switch (err) {
        error.ReleaseExists => return common.fail(ctx, .conflict, "release '{s}' already exists and releases never move. Pick the next name, e.g. a higher version.", .{name}),
        error.BadReleaseName => return common.fail(ctx, .usage, "'{s}' is not a release name (letters, digits, dot, dash, underscore). Try something like v1.0.0.", .{name}),
        error.NothingToTag => return common.fail(ctx, .usage, "nothing to tag yet. Run 'cid push' first, then 'cid tag {s}' again.", .{name}),
        error.NoSuchDataset => return common.fail(ctx, .usage, "the dataset is not on the server yet. Run 'cid push' first.", .{}),
        error.ServerUnreachable => return common.fail(ctx, .network, "cannot reach the server. Check CID_SERVER, then run 'cid tag' again.", .{}),
        else => return common.fail(ctx, .network, "the server refused the tag. Check the server logs, then run 'cid tag' again.", .{}),
    };

    ctx.out.print("Release {s} created at {s}: {d} item{s}, manifest sha256 {s}…\n", .{
        result.release, result.commit[0..13], result.items, plural(result.items), result.manifest_sha256[0..12],
    }) catch return .network;
    return .ok;
}

fn plural(n: anytype) []const u8 {
    return if (n == 1) "" else "s";
}
