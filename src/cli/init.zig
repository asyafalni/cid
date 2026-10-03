//! `cid init <address> --git <git-url>`: create a dataset from the current
//! folder, paired with its git repository (both addresses required, rule 3).

const std = @import("std");
const common = @import("common.zig");
const workspace = @import("../client/workspace.zig");
const Remote = @import("../client/remote.zig").Remote;

const usage_hint =
    "run 'cid init <address> --git <git-url>', e.g.\n" ++
    "  cid init cid@cidhub.com:your-org/datasets/my-data \\\n" ++
    "    --git git@gitlab.com:your-org/datasets/my-data.git";

pub fn run(ctx: *const common.Context, args: []const [:0]const u8) common.ExitCode {
    var address: ?[]const u8 = null;
    var git_url: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--git")) {
            i += 1;
            if (i >= args.len) return common.fail(ctx, .usage, "--git needs a value; {s}", .{usage_hint});
            git_url = args[i];
        } else if (address == null) {
            address = args[i];
        } else {
            return common.fail(ctx, .usage, "unexpected argument '{s}'; {s}", .{ args[i], usage_hint });
        }
    }
    const addr = address orelse
        return common.fail(ctx, .usage, "an address is needed; {s}", .{usage_hint});
    const git = git_url orelse
        return common.fail(ctx, .usage, "every dataset is paired with a git repository; {s}", .{usage_hint});

    const path = workspace.datasetPathOf(addr) orelse
        return common.fail(ctx, .usage, "'{s}' is not a cid address (expected cid@host:org/path); {s}", .{ workspace.redacted(ctx.arena, addr) catch "that address", usage_hint });
    const work_dir = std.Io.Dir.cwd().openDir(ctx.io, ".", .{ .iterate = true }) catch
        return common.fail(ctx, .usage, "cannot open the current folder. Run 'cid init' from the dataset folder.", .{});
    if (work_dir.access(ctx.io, ".cid", .{})) |_| {
        return common.fail(ctx, .usage, "this folder is already a cid dataset. Run 'cid status'.", .{});
    } else |_| {}

    // The server creates the dataset now and checks it can write the git
    // repository, so a wrong URL fails here, not at the first release.
    // Nothing is written locally unless it agrees.
    var registered = false;
    var made: Remote.Made = .{};
    if (common.remoteFor(ctx, path, .create, addr)) |remote| {
        const created = remote.create(ctx.arena, git) catch |err| switch (err) {
            error.AccessDenied => return common.denied(ctx, "cid init"),
            error.ServerUnreachable => return common.fail(ctx, .network, "cannot reach the server to create the dataset. Check the connection, then run 'cid init' again.", .{}),
            else => return common.fail(ctx, .network, "the server could not create the dataset. Run 'cid init' again; if it persists, tell the administrator.", .{}),
        };
        switch (created) {
            .created => |m| {
                registered = true;
                made = m;
            },
            .exists => return common.fail(ctx, .usage, "{s} already exists. Run 'cid clone {s}' to work with it.", .{ path, workspace.withoutCredentials(ctx.arena, addr) catch "<address>" }),
            .refused => |r| return common.fail(ctx, .usage, "{s}. {s}", .{ r.what, r.next }),
        }
    } else |err| switch (err) {
        error.AccessDenied => return refusedCreate(ctx, path),
        error.NeedToken => return common.noRemote(ctx, err, "cid init"),
        else => {},
    }

    workspace.init(ctx.arena, ctx.io, work_dir, addr, git) catch |err| switch (err) {
        error.BadAddress => return common.fail(ctx, .usage, "'{s}' is not a cid address (expected cid@host:org/path); {s}", .{ workspace.redacted(ctx.arena, addr) catch "that address", usage_hint }),
        error.AlreadyADataset => return common.fail(ctx, .usage, "this folder is already a cid dataset. Run 'cid status'.", .{}),
        else => return common.fail(ctx, .network, "could not write .cid/ here. Check folder permissions, then run 'cid init' again.", .{}),
    };

    if (common.emitJson(ctx, .{ .dataset = path, .address = workspace.withoutCredentials(ctx.arena, addr) catch addr, .git = git, .on_server = registered, .warnings = made.warnings })) return .ok;
    for (made.warnings) |w| common.warn(ctx, "{s}", .{w});
    ctx.out.print(
        "Initialized {s} from this folder{s}.\nNext: 'cid add .' to stage files, then 'cid commit -m \"First import\"'.\n",
        .{ path, if (!registered) "" else if (made.git_checked) " (created on the server; its git repository is writable)" else " (created on the server)" },
    ) catch return .network;
    return .ok;
}

/// Creating is refused for its own reasons (the dataset exists, no
/// Maintainer role on the GitLab project at that path), which the server's
/// front door has just printed; the role advice of a plain refusal would
/// be wrong here.
fn refusedCreate(ctx: *const common.Context, path: []const u8) common.ExitCode {
    return common.fail(ctx, .access, "the server would not create {s} for your key; its reason is above. Fix that, then run 'cid init' again.", .{path});
}
