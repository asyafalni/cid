//! `cid clone <address> [folder]`: download a dataset into a new folder.

const std = @import("std");
const common = @import("common.zig");
const workspace = @import("../client/workspace.zig");
const sync = @import("../client/sync.zig");

pub fn run(ctx: *const common.Context, args: []const [:0]const u8) common.ExitCode {
    var positional: std.ArrayList([]const u8) = .empty;
    var release: ?[]const u8 = null;
    var format: ?[]const u8 = null;
    var splits: std.ArrayList([]const u8) = .empty;
    var classes: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--release")) {
            i += 1;
            if (i >= args.len) return common.fail(ctx, .usage, "--release needs a name, e.g. cid clone <address> --release v1.0.0", .{});
            release = args[i];
        } else if (std.mem.eql(u8, args[i], "--format")) {
            i += 1;
            const f: []const u8 = if (i < args.len) args[i] else "";
            if (!std.mem.eql(u8, f, "files") and !std.mem.eql(u8, f, "jsonl") and !std.mem.eql(u8, f, "yolo"))
                return common.fail(ctx, .usage, "this build knows the formats files, jsonl and yolo. Run 'cid clone <address> --format jsonl'.", .{});
            format = f;
        } else if (std.mem.eql(u8, args[i], "--split") or std.mem.eql(u8, args[i], "--class")) {
            const flag = args[i];
            i += 1;
            if (i >= args.len or args[i].len == 0)
                return common.fail(ctx, .usage, "{s} needs a name. Run 'cid clone <address> {s} {s}'.", .{
                    flag, flag, if (std.mem.eql(u8, flag, "--split")) "train" else "person",
                });
            const list = if (std.mem.eql(u8, flag, "--split")) &splits else &classes;
            list.append(ctx.arena, args[i]) catch return .network;
        } else {
            positional.append(ctx.arena, args[i]) catch return .network;
        }
    }
    if (positional.items.len == 0 or positional.items.len > 2)
        return common.fail(ctx, .usage, "run 'cid clone <address> [folder]', e.g. cid clone cid@cidhub.com:org/datasets/calls", .{});
    var address = positional.items[0];

    // The git URL copied from GitLab works too: the dataset repository's
    // .cid marker says which server and dataset it mirrors. This is the
    // CLI's one and only git invocation (CLAUDE.md, external programs).
    if (std.mem.endsWith(u8, address, ".git")) {
        address = resolveGitUrl(ctx, address) orelse
            return common.fail(ctx, .usage, "could not read the dataset marker from that git repository. Check the URL, or run 'cid clone' with the cid address instead.", .{});
    }
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

    const subset: workspace.Subset = .{ .split = splits.items, .class = classes.items };
    const outcome = sync.clone(ctx.arena, ctx.io, dest_dir, cache_dir, remote, address, release, format, subset) catch |err| {
        // The folder was made by this command and holds nothing worth
        // keeping; leaving it would make the retry say it already exists.
        cwd.deleteTree(ctx.io, dest) catch {};
        return cloneFailed(ctx, err, name, release, format, subset);
    };

    if (subset.active()) {
        const what = subset.describe(ctx.arena) catch return .network;
        ctx.out.print("Cloned {s}{s}{s} into {s}/: {d} of {d} item{s} ({s}), {d} downloaded, the rest from the local cache.\n", .{
            name,
            if (outcome.release != null) " at release " else "",
            outcome.release orelse "",
            dest,
            outcome.files,
            outcome.total,
            plural(outcome.total),
            what,
            outcome.downloaded,
        }) catch return .network;
        return .ok;
    }
    return reportClone(ctx, name, dest, outcome);
}

fn cloneFailed(
    ctx: *const common.Context,
    err: sync.Error,
    name: []const u8,
    release: ?[]const u8,
    format: ?[]const u8,
    subset: workspace.Subset,
) common.ExitCode {
    switch (err) {
        error.ClassOnFileDataset => return common.fail(ctx, .usage, "'{s}' is a file dataset: it has no classes to choose. Run 'cid clone' with --split instead, or without --class.", .{name}),
        error.EmptySubset => {
            const what = subset.describe(ctx.arena) catch "that subset";
            return common.fail(ctx, .usage, "no item matches {s} at this version. Check the names in the dashboard's Browse filters, or run 'cid clone' without --split/--class.", .{what});
        },
        else => {},
    }
    switch (err) {
        error.NoSuchRelease => return common.fail(ctx, .usage, "no release named '{s}'. Leave --release off for the newest, or ask the owner which releases exist.", .{release.?}),
        error.ExportFailed => return common.fail(ctx, .integrity, "the {s} export could not be built (see the warning above for the file). Fix it in the platform, or clone with --format files.", .{format orelse "requested"}),
        error.NoSuchDataset => return common.fail(ctx, .usage, "no dataset '{s}' on the server. Check the address, or run 'cid init' in the producing folder to create it.", .{name}),
        error.EmptyDataset => return common.fail(ctx, .usage, "'{s}' has nothing pushed yet. Push from the producing folder first.", .{name}),
        error.ServerUnreachable => return common.fail(ctx, .network, "cannot reach the server. Check CID_SERVER, then run 'cid clone' again.", .{}),
        error.TransferFailed => return common.fail(ctx, .integrity, "a download failed its hash check or the connection broke. Run 'cid clone' again.", .{}),
        error.Collected => return common.fail(ctx, .integrity, "this version needs files cleanup removed from the server: it is in no release and no branch head. Run 'cid log' and clone a release or a branch instead (--release).", .{}),
        error.Corrupt => return common.fail(ctx, .integrity, "what the server sent failed its hash check. Run 'cid clone' again.", .{}),
        else => return common.fail(ctx, .network, "clone failed. Fix the cause above, then run 'cid clone' again.", .{}),
    }
}

fn reportClone(ctx: *const common.Context, name: []const u8, dest: []const u8, outcome: sync.CloneOutcome) common.ExitCode {
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

/// Shallow-clones the repository to a scratch folder, reads `.cid`
/// (cid-marker 1 / server <url> / dataset <name>), and builds the cid
/// address cid@<server-host>:<dataset>.
fn resolveGitUrl(ctx: *const common.Context, git_url: []const u8) ?[]const u8 {
    const home = ctx.env.get("HOME") orelse return null;
    var rand: [6]u8 = undefined;
    ctx.io.random(&rand);
    const tmp = std.fmt.allocPrint(ctx.arena, "{s}/.cache/cid/marker-{x}", .{ home, &rand }) catch return null;
    defer std.Io.Dir.cwd().deleteTree(ctx.io, tmp) catch {};

    const result = std.process.run(ctx.arena, ctx.io, .{
        .argv = &.{ "git", "clone", "--depth", "1", "--quiet", git_url, tmp },
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .{ .nanoseconds = 60 * std.time.ns_per_s } } },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return null;
    if (result.term != .exited or result.term.exited != 0) {
        if (result.stderr.len > 0)
            std.log.warn("git said: {s}", .{std.mem.trim(u8, result.stderr, " \n")});
        return null;
    }

    const marker_path = std.fmt.allocPrint(ctx.arena, "{s}/.cid", .{tmp}) catch return null;
    const text = std.Io.Dir.cwd().readFileAlloc(ctx.io, marker_path, ctx.arena, .limited(4096)) catch return null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    if (!std.mem.eql(u8, lines.next() orelse "", "cid-marker 1")) return null;
    var server: ?[]const u8 = null;
    var dataset: ?[]const u8 = null;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "server ")) server = line["server ".len..];
        if (std.mem.startsWith(u8, line, "dataset ")) dataset = line["dataset ".len..];
    }
    const srv = server orelse return null;
    const ds = dataset orelse return null;

    // cid@<host>:<dataset> — the host from the server URL, port dropped
    // (SSH has its own).
    const scheme_end = std.mem.indexOf(u8, srv, "://") orelse return null;
    var host = srv[scheme_end + 3 ..];
    if (std.mem.indexOfScalar(u8, host, '/')) |slash| host = host[0..slash];
    if (std.mem.indexOfScalar(u8, host, ':')) |colon| host = host[0..colon];
    return std.fmt.allocPrint(ctx.arena, "cid@{s}:{s}", .{ host, ds }) catch null;
}

fn lastSegment(name: []const u8) []const u8 {
    const sep = std.mem.lastIndexOfScalar(u8, name, '/') orelse return name;
    return name[sep + 1 ..];
}

fn plural(n: u32) []const u8 {
    return if (n == 1) "" else "s";
}
