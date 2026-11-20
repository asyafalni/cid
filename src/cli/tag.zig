//! `cid tag <name> [--trained-on <dataset>@<release>]...`: make a release
//! from the branch head, on the server. Needs everything pushed first, and
//! says so. A model's release may name the dataset releases it was trained
//! on (docs/roadmap.md, C3): recorded with it, and never changed.

const std = @import("std");
const common = @import("common.zig");
const workspace = @import("../client/workspace.zig");
const local = @import("../client/local.zig");
const Remote = @import("../client/remote.zig").Remote;

const usage = "run 'cid tag <name>', e.g. cid tag v1.0.0 (a model's release may add --trained-on <dataset>@<release>, once per dataset release)";

pub fn run(ctx: *const common.Context, args: []const [:0]const u8) common.ExitCode {
    var given: ?[]const u8 = null;
    var sources: std.ArrayList(Remote.Source) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--trained-on")) {
            i += 1;
            if (i >= args.len) return common.fail(ctx, .usage, "--trained-on needs a dataset release, e.g. --trained-on your-org/datasets/person-vehicle@v4.2.0", .{});
            const at = std.mem.lastIndexOfScalar(u8, args[i], '@') orelse
                return common.fail(ctx, .usage, "'{s}' names no release: write <dataset>@<release>, e.g. your-org/datasets/person-vehicle@v4.2.0", .{args[i]});
            if (at == 0 or at + 1 == args[i].len)
                return common.fail(ctx, .usage, "'{s}' names no release: write <dataset>@<release>, e.g. your-org/datasets/person-vehicle@v4.2.0", .{args[i]});
            sources.append(ctx.arena, .{ .dataset = args[i][0..at], .release = args[i][at + 1 ..] }) catch return .network;
        } else if (given == null) {
            given = args[i];
        } else return common.fail(ctx, .usage, "{s}", .{usage});
    }
    const name = given orelse return common.fail(ctx, .usage, "{s}", .{usage});

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
    const remote = common.remoteFor(ctx, dataset, .maintain, ws.config.address) catch |err|
        return common.noRemote(ctx, err, "cid tag");

    const tagged = remote.tagWith(ctx.arena, name, sources.items) catch |err| switch (err) {
        error.ReleaseExists => return common.fail(ctx, .conflict, "release '{s}' already exists and releases never move. Run 'cid tag' with the next name, e.g. the next version number.", .{name}),
        error.BadReleaseName => return common.fail(ctx, .usage, "'{s}' is not a release name (letters, digits, dot, dash, underscore). Try something like v1.0.0.", .{name}),
        error.NothingToTag => return common.fail(ctx, .usage, "nothing to tag yet. Run 'cid push' first, then 'cid tag {s}' again.", .{name}),
        error.NoSuchDataset => return common.fail(ctx, .usage, "the dataset is not on the server yet. Run 'cid push' first.", .{}),
        error.AccessDenied => return common.denied(ctx, "cid tag"),
        error.ServerUnreachable => return common.fail(ctx, .network, "cannot reach the server. Check CID_SERVER, then run 'cid tag' again.", .{}),
        else => return common.fail(ctx, .network, "the server refused the tag. Check the server logs, then run 'cid tag' again.", .{}),
    };
    const result = switch (tagged) {
        .made => |r| r,
        .refused => |r| return common.fail(ctx, .usage, "{s}. {s}", .{ r.what, r.next }),
    };

    if (common.emitJson(ctx, result)) return .ok;
    ctx.out.print("Release {s} created at {s}: {d} item{s}, manifest {s}…\n", .{
        result.release, result.commit[0..13], result.items, plural(result.items), result.manifest_hash[0..12],
    }) catch return .network;
    for (result.trained_on, 0..) |src, n| {
        ctx.out.print("{s}{s} {s}", .{ if (n == 0) "Trained on " else ", ", src.dataset, src.release }) catch return .network;
        if (n + 1 == result.trained_on.len) ctx.out.writeAll(".\n") catch return .network;
    }
    return .ok;
}

fn plural(n: anytype) []const u8 {
    return if (n == 1) "" else "s";
}
