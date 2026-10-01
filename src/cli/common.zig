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

/// How commands reach the server: the SSH flow (a short-lived token from
/// 'ssh cid@host cid-auth <dataset> <level>', like git), or the
/// CID_SERVER/CID_TOKEN environment override for CI and machines without
/// SSH. The override wins when both are set.
pub const no_server_msg =
    "cannot reach a cid server: the SSH call failed and no override is set.\n" ++
    "Check that 'ssh <user@host from the address>' works, or export\n" ++
    "CID_SERVER and CID_TOKEN, then run the command again.";

pub fn remoteFor(
    ctx: *const Context,
    dataset_name: []const u8,
    level: remote_mod.TokenLevel,
    address: ?[]const u8,
) !*const remote_mod.Remote {
    var server: []const u8 = undefined;
    var tok: []const u8 = undefined;
    if (ctx.env.get("CID_SERVER")) |s| {
        server = s;
        tok = ctx.env.get("CID_TOKEN") orelse return error.NoServer;
    } else {
        const addr = address orelse return error.NoServer;
        const grant = sshToken(ctx, addr, dataset_name, level) orelse return error.NoServer;
        server = grant.url;
        tok = grant.token;
    }
    const transport = try ctx.arena.create(remote_mod.HttpTransport);
    transport.* = remote_mod.HttpTransport.init(ctx.arena, ctx.io, server, tok);
    const r = try ctx.arena.create(remote_mod.Remote);
    r.* = .{ .t = transport.transport(), .name = dataset_name };
    return r;
}

const Grant = struct { token: []const u8, url: []const u8 };

/// `ssh cid@host cid-auth <dataset> <read|write>` — the system ssh, exactly
/// as git uses it, so ~/.ssh/config, agents and hardware keys all work.
fn sshToken(
    ctx: *const Context,
    address: []const u8,
    dataset_name: []const u8,
    level: remote_mod.TokenLevel,
) ?Grant {
    const colon = std.mem.indexOfScalar(u8, address, ':') orelse return null;
    const ssh_target = address[0..colon];
    const result = std.process.run(ctx.arena, ctx.io, .{
        .argv = &.{ "ssh", ssh_target, "cid-auth", dataset_name, @tagName(level) },
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .{ .nanoseconds = 30 * std.time.ns_per_s } } },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return null;
    if (result.term != .exited or result.term.exited != 0) {
        if (result.stderr.len > 0)
            std.log.warn("ssh said: {s}", .{std.mem.trim(u8, result.stderr, " \n")});
        return null;
    }
    const Parsed = struct { token: []const u8, url: []const u8, expires_in_secs: u64 = 0 };
    const parsed = std.json.parseFromSliceLeaky(Parsed, ctx.arena, result.stdout, .{ .ignore_unknown_fields = true }) catch
        return null;
    return .{ .token = parsed.token, .url = parsed.url };
}

/// 'user:<name>' from the environment; CID_AUTHOR overrides verbatim.
pub fn author(ctx: *const Context) ![]const u8 {
    if (ctx.env.get("CID_AUTHOR")) |a| return a;
    if (ctx.env.get("USER")) |u| return std.fmt.allocPrint(ctx.arena, "user:{s}", .{u});
    return "user:unknown";
}
