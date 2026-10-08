//! `cid remote`: the folder's address and git URL, as `git remote -v`
//! shows a remote's; `cid remote set-url <address> [--git <url>]` points
//! the folder elsewhere after a dataset is renamed, as `git remote
//! set-url` does; `cid remote set-url --git <url>` alone changes only the
//! git URL. A folder has one remote, always.

const std = @import("std");
const common = @import("common.zig");
const workspace = @import("../client/workspace.zig");

pub fn run(ctx: *const common.Context, args: []const [:0]const u8) common.ExitCode {
    var ws = common.openWorkspace(ctx) catch
        return common.fail(ctx, .usage, common.not_a_dataset_msg, .{});
    if (args.len > 0) {
        if (!std.mem.eql(u8, args[0], "set-url"))
            return common.fail(ctx, .usage, "'cid remote {s}' is not a remote command. Run 'cid remote' or 'cid remote set-url <address>'.", .{args[0]});
        var address: ?[]const u8 = null;
        var git_url: ?[]const u8 = null;
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--git")) {
                i += 1;
                if (i == args.len) return common.fail(ctx, .usage, "--git needs the git URL. Run 'cid remote set-url <address> --git <git-url>'.", .{});
                git_url = args[i];
            } else if (address == null) {
                address = args[i];
            } else return common.fail(ctx, .usage, "one address only. Run 'cid remote set-url <address> [--git <git-url>]'.", .{});
        }
        // `--git` alone keeps the address: the repository moved, the
        // dataset did not.
        const new = address orelse if (git_url != null) ws.config.address else return common.fail(ctx, .usage, "name the new address. Run 'cid remote set-url <address> [--git <git-url>]'.", .{});
        if (std.mem.endsWith(u8, new, ".git"))
            return common.fail(ctx, .usage, "that is a git URL; give the cid address (cid@host:<dataset>) and put the git URL after --git. Run 'cid remote set-url <address> --git {s}'.", .{new});
        workspace.setRemote(ctx.arena, ctx.io, &ws, new, git_url) catch |err| return switch (err) {
            error.BadAddress => common.fail(ctx, .usage, "'{s}' is not a cid address (cid@host:<dataset>, or https://host/<dataset>). Run 'cid remote set-url <address>'.", .{new}),
            else => common.fail(ctx, .integrity, "could not write .cid/config.zon. Check the folder is writable, then run 'cid remote set-url' again.", .{}),
        };
    }
    if (common.emitJson(ctx, .{ .address = ws.config.address, .git_url = ws.config.git_url })) return .ok;
    ctx.out.print("address  {s}\ngit      {s}\n", .{ ws.config.address, ws.config.git_url }) catch return .network;
    return .ok;
}
