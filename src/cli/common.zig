//! Shared plumbing for working-folder commands: the Context every command
//! receives, error printing (always ending with the next command to run),
//! cache-directory and author resolution.

const std = @import("std");
const root = @import("../cid.zig");
const workspace = @import("../client/workspace.zig");
const remote_mod = @import("../client/remote.zig");

pub const ExitCode = root.ExitCode;

pub const Context = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    env: *const std.process.Environ.Map,
};

/// Every error ends with the command to run next.
pub fn fail(ctx: *const Context, code: ExitCode, comptime fmt: []const u8, args: anytype) ExitCode {
    var buf: [2048]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(ctx.io, &buf);
    const err = &stderr_writer.interface;
    err.print("cid: " ++ fmt ++ "\n", args) catch {};
    err.flush() catch {};
    return code;
}

pub fn openWorkspace(ctx: *const Context) workspace.OpenError!workspace.Workspace {
    const work_dir = std.Io.Dir.cwd().openDir(ctx.io, ".", .{ .iterate = true }) catch
        return error.NotADataset;
    return workspace.open(ctx.arena, ctx.io, work_dir);
}

pub const not_a_dataset_msg =
    "this folder is not a cid dataset (no .cid/ here).\n" ++
    "Run 'cid init <address> --git <git-url>' to create one from this folder.";

/// ~/.cache/cid (or $XDG_CACHE_HOME/cid), created if missing.
pub fn openCacheDir(ctx: *const Context) !std.Io.Dir {
    const path = if (ctx.env.get("XDG_CACHE_HOME")) |xdg|
        try std.fmt.allocPrint(ctx.arena, "{s}/cid", .{xdg})
    else if (ctx.env.get("HOME")) |home|
        try std.fmt.allocPrint(ctx.arena, "{s}/.cache/cid", .{home})
    else
        return error.NoCacheDir;
    return std.Io.Dir.cwd().createDirPathOpen(ctx.io, path, .{});
}

/// Where the server is, until the SSH front door lands: CID_SERVER and
/// CID_TOKEN from the environment. The error text says exactly that.
pub const no_server_msg =
    "the server address is not set (the SSH flow is not built yet).\n" ++
    "Export CID_SERVER (e.g. http://127.0.0.1:7070) and CID_TOKEN, then run the command again.";

pub fn remoteFor(ctx: *const Context, dataset_name: []const u8) !*const remote_mod.Remote {
    const server = ctx.env.get("CID_SERVER") orelse return error.NoServer;
    const token = ctx.env.get("CID_TOKEN") orelse return error.NoServer;
    const transport = try ctx.arena.create(remote_mod.HttpTransport);
    transport.* = remote_mod.HttpTransport.init(ctx.arena, ctx.io, server, token);
    const r = try ctx.arena.create(remote_mod.Remote);
    r.* = .{ .t = transport.transport(), .name = dataset_name };
    return r;
}

/// 'user:<name>' from the environment; CID_AUTHOR overrides verbatim.
pub fn author(ctx: *const Context) ![]const u8 {
    if (ctx.env.get("CID_AUTHOR")) |a| return a;
    if (ctx.env.get("USER")) |u| return std.fmt.allocPrint(ctx.arena, "user:{s}", .{u});
    return "user:unknown";
}
