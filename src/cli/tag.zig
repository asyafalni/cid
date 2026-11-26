//! `cid tag <name> [-m <notes>] [--trained-on <dataset>@<release>]...`:
//! make a release from the branch head, on the server. `cid tag` alone
//! (or `-l`, `--list`) lists the releases, as git's does. Needs everything
//! pushed first, and says so. `-m` gives the release its own words, as
//! git's annotated tags carry a message: kept with it, never changed. A model's release may name the dataset releases it was trained
//! on (docs/roadmap.md, C3): recorded with it, and never changed.

const std = @import("std");
const common = @import("common.zig");
const workspace = @import("../client/workspace.zig");
const local = @import("../client/local.zig");
const Remote = @import("../client/remote.zig").Remote;

const usage = "run 'cid tag <name>', e.g. cid tag v1.0.0 (add -m \"what this release is\" for its notes; a model's release may add --trained-on <dataset>@<release>, once per dataset release)";

pub fn run(ctx: *const common.Context, args: []const [:0]const u8) common.ExitCode {
    var given: ?[]const u8 = null;
    var sources: std.ArrayList(Remote.Source) = .empty;
    var notes: ?[]const u8 = null;
    var list = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-m") or std.mem.eql(u8, args[i], "--message")) {
            i += 1;
            if (i >= args.len or notes != null)
                return common.fail(ctx, .usage, "-m needs the release's notes, once. Run 'cid tag <name> -m \"what this release is\"'.", .{});
            notes = args[i];
        } else if (std.mem.eql(u8, args[i], "--trained-on")) {
            i += 1;
            if (i >= args.len) return common.fail(ctx, .usage, "--trained-on needs a dataset release. Run 'cid tag <name> --trained-on <dataset>@<release>', e.g. --trained-on your-org/datasets/person-vehicle@v4.2.0", .{});
            const at = std.mem.lastIndexOfScalar(u8, args[i], '@') orelse
                return common.fail(ctx, .usage, "'{s}' names no release. Run 'cid tag <name> --trained-on <dataset>@<release>', e.g. your-org/datasets/person-vehicle@v4.2.0", .{args[i]});
            if (at == 0 or at + 1 == args[i].len)
                return common.fail(ctx, .usage, "'{s}' names no release. Run 'cid tag <name> --trained-on <dataset>@<release>', e.g. your-org/datasets/person-vehicle@v4.2.0", .{args[i]});
            sources.append(ctx.arena, .{ .dataset = args[i][0..at], .release = args[i][at + 1 ..] }) catch return .network;
        } else if (std.mem.eql(u8, args[i], "-l") or std.mem.eql(u8, args[i], "--list")) {
            list = true;
        } else if (std.mem.startsWith(u8, args[i], "-")) {
            // Never a release name: a release never moves, so an option
            // mistaken for one would stay in the history for good.
            return common.fail(ctx, .usage, "'{s}' is not an option of cid tag. Run 'cid tag' to list releases, or {s}", .{ args[i], usage });
        } else if (given == null) {
            given = args[i];
        } else return common.fail(ctx, .usage, "{s}", .{usage});
    }
    if (list and (given != null or notes != null or sources.items.len > 0))
        return common.fail(ctx, .usage, "-l lists releases and makes none. Run 'cid tag' to list them, or {s}", .{usage});

    const ws = common.openWorkspace(ctx) catch
        return common.fail(ctx, .usage, common.not_a_dataset_msg, .{});

    const name = given orelse {
        if (notes != null or sources.items.len > 0) return common.fail(ctx, .usage, "{s}", .{usage});
        return listReleases(ctx, ws);
    };

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

    const tagged = remote.tagWith(ctx.arena, name, sources.items, notes) catch |err| switch (err) {
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

/// `cid tag` alone: the dataset's releases, one a line, as `git tag`
/// lists tags; with the commit each sits on.
fn listReleases(ctx: *const common.Context, ws: workspace.Workspace) common.ExitCode {
    const dataset = workspace.datasetPathOf(ws.config.address) orelse
        return common.fail(ctx, .integrity, ".cid/config.zon holds a broken address. Clone again, or fix it to cid@host:org/path.", .{});
    const remote = common.remoteFor(ctx, dataset, .read, ws.config.address) catch |err|
        return common.noRemote(ctx, err, "cid tag");
    const releases = remote.releases(ctx.arena) catch |err| switch (err) {
        error.NoSuchDataset => return common.fail(ctx, .usage, "the dataset is not on the server yet. Run 'cid push' first.", .{}),
        error.AccessDenied => return common.denied(ctx, "cid tag"),
        else => return common.fail(ctx, .network, "cannot reach the server. Check CID_SERVER, then run 'cid tag' again.", .{}),
    };
    if (common.emitJson(ctx, .{ .releases = releases })) return .ok;
    if (releases.len == 0) {
        ctx.out.writeAll("No releases yet. Run 'cid tag v1.0.0' to make the first.\n") catch return .network;
        return .ok;
    }
    for (releases) |r| ctx.out.print("{s}\t{s}\n", .{ r.name, r.commit[0..@min(r.commit.len, 13)] }) catch return .network;
    return .ok;
}

fn plural(n: anytype) []const u8 {
    return if (n == 1) "" else "s";
}
