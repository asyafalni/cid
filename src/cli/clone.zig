//! `cid clone <address> [folder]`: download a dataset into a new folder.

const std = @import("std");
const common = @import("common.zig");
const workspace = @import("../client/workspace.zig");
const sync = @import("../client/sync.zig");

pub fn run(ctx: *const common.Context, args: []const [:0]const u8) common.ExitCode {
    var positional: std.ArrayList([]const u8) = .empty;
    var release: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--release")) {
            i += 1;
            if (i >= args.len) return common.fail(ctx, .usage, "--release needs a name, e.g. cid clone <address> --release v1.0.0", .{});
            release = args[i];
        } else if (std.mem.eql(u8, args[i], "--format")) {
            i += 1;
            const f: []const u8 = if (i < args.len) args[i] else "";
            if (!std.mem.eql(u8, f, "files"))
                return common.fail(ctx, .usage, "formats other than 'files' arrive with annotated datasets; this build clones the folder tree. Run 'cid clone <address>'.", .{});
        } else {
            positional.append(ctx.arena, args[i]) catch return .network;
        }
    }
    if (positional.items.len == 0 or positional.items.len > 2)
        return common.fail(ctx, .usage, "run 'cid clone <address> [folder]', e.g. cid clone cid@cidhub.com:org/datasets/calls", .{});
    const address = positional.items[0];
    const name = workspace.datasetPathOf(address) orelse
        return common.fail(ctx, .usage, "'{s}' is not a cid address (expected cid@host:org/path). Check it and run 'cid clone' again.", .{address});

    const dest = if (positional.items.len == 2) positional.items[1] else lastSegment(name);
    const cwd = std.Io.Dir.cwd();
    if (cwd.access(ctx.io, dest, .{})) |_| {
        return common.fail(ctx, .usage, "'{s}' already exists here. Remove it, or run 'cid clone <address> <another-folder>'.", .{dest});
    } else |_| {}
    cwd.createDirPath(ctx.io, dest) catch
        return common.fail(ctx, .network, "cannot create '{s}'. Check permissions, then run 'cid clone' again.", .{dest});
    const dest_dir = cwd.openDir(ctx.io, dest, .{ .iterate = true }) catch
        return common.fail(ctx, .network, "cannot open '{s}'. Check permissions, then run 'cid clone' again.", .{dest});

    const cache_dir = common.openCacheDir(ctx) catch
        return common.fail(ctx, .network, "cannot open the cache folder (~/.cache/cid). Check HOME, then run 'cid clone' again.", .{});
    const remote = common.remoteFor(ctx, name, .read, address) catch
        return common.fail(ctx, .usage, common.no_server_msg, .{});

    const outcome = sync.clone(ctx.arena, ctx.io, dest_dir, cache_dir, remote, address, release) catch |err| switch (err) {
        error.NoSuchRelease => return common.fail(ctx, .usage, "no release named '{s}'. Leave --release off for the newest, or ask the owner which releases exist.", .{release.?}),
        error.NoSuchDataset => return common.fail(ctx, .usage, "no dataset '{s}' on the server. Check the address, or run 'cid init' in the producing folder to create it.", .{name}),
        error.EmptyDataset => return common.fail(ctx, .usage, "'{s}' has nothing pushed yet. Push from the producing folder first.", .{name}),
        error.ServerUnreachable => return common.fail(ctx, .network, "cannot reach the server. Check CID_SERVER, then run 'cid clone' again.", .{}),
        error.TransferFailed => return common.fail(ctx, .integrity, "a download failed its hash check or the connection broke. Run 'cid clone' again.", .{}),
        else => return common.fail(ctx, .network, "clone failed. Fix the cause above, then run 'cid clone' again.", .{}),
    };

    if (outcome.release) |rel| {
        ctx.out.print("Cloned {s} at release {s} into {s}/: {d} file{s} ({d} downloaded, the rest from the local cache).\n", .{
            name, rel, dest, outcome.files, plural(outcome.files), outcome.downloaded,
        }) catch return .network;
    } else {
        ctx.out.print("Cloned {s} into {s}/: {d} file{s} ({d} downloaded, the rest from the local cache). No releases yet: this is the newest commit.\n", .{
            name, dest, outcome.files, plural(outcome.files), outcome.downloaded,
        }) catch return .network;
    }
    return .ok;
}

fn lastSegment(name: []const u8) []const u8 {
    const sep = std.mem.lastIndexOfScalar(u8, name, '/') orelse return name;
    return name[sep + 1 ..];
}

fn plural(n: u32) []const u8 {
    return if (n == 1) "" else "s";
}
