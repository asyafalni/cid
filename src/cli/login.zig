//! `cid login <server-url>` / `cid logout`: for machines that cannot use
//! SSH at all (CLI reference). The token is read from stdin (pipe it in)
//! and stored in ~/.config/cid/credentials, mode 0600 — tokens only,
//! never keys (docs/access.md).

const std = @import("std");
const common = @import("common.zig");

pub const credentials_rel = ".config/cid/credentials";

pub fn runLogin(ctx: *const common.Context, args: []const [:0]const u8) common.ExitCode {
    if (args.len != 1 or !std.mem.startsWith(u8, args[0], "http"))
        return common.fail(ctx, .usage, "run 'cid login <server-url>' and pipe the token in, e.g. echo \"$TOKEN\" | cid login https://cid.example", .{});
    const server = args[0];

    var buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(ctx.io, &buf);
    const n = stdin_reader.interface.readSliceShort(&buf) catch 0;
    const token = std.mem.trim(u8, buf[0..n], " \n\r\t");
    if (token.len == 0)
        return common.fail(ctx, .usage, "no token arrived on stdin. Run 'echo \"$TOKEN\" | cid login {s}'.", .{server});

    const home = ctx.env.get("HOME") orelse
        return common.fail(ctx, .usage, "HOME is not set, so there is nowhere to store the token. Set it, then run 'cid login' again.", .{});
    const dir_path = std.fmt.allocPrint(ctx.arena, "{s}/.config/cid", .{home}) catch return .network;
    var dir = std.Io.Dir.cwd().createDirPathOpen(ctx.io, dir_path, .{}) catch
        return common.fail(ctx, .network, "cannot create ~/.config/cid. Check permissions, then run 'cid login' again.", .{});
    defer dir.close(ctx.io);

    const contents = std.fmt.allocPrint(ctx.arena, "cid-credentials 1\nserver {s}\ntoken {s}\n", .{ server, token }) catch return .network;
    var file = dir.createFile(ctx.io, "credentials", .{ .truncate = true, .permissions = .fromMode(0o600) }) catch
        return common.fail(ctx, .network, "cannot write the credentials file. Check permissions, then run 'cid login' again.", .{});
    defer file.close(ctx.io);
    var wbuf: [4096]u8 = undefined;
    var fw = file.writer(ctx.io, &wbuf);
    fw.interface.writeAll(contents) catch return .network;
    fw.interface.flush() catch return .network;

    ctx.out.print("Logged in to {s}. The token lives in ~/{s} (0600); 'cid logout' removes it.\n", .{ server, credentials_rel }) catch return .network;
    return .ok;
}

pub fn runLogout(ctx: *const common.Context) common.ExitCode {
    const home = ctx.env.get("HOME") orelse
        return common.fail(ctx, .usage, "HOME is not set. Nothing to do.", .{});
    const path = std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ home, credentials_rel }) catch return .network;
    std.Io.Dir.cwd().deleteFile(ctx.io, path) catch {
        ctx.out.writeAll("No stored login. Nothing to do.\n") catch return .network;
        return .ok;
    };
    ctx.out.writeAll("Logged out: the stored token is gone.\n") catch return .network;
    return .ok;
}

/// The stored login, if any: used by remoteFor when SSH is not an option.
pub const Stored = struct { server: []const u8, token: []const u8 };

pub fn load(ctx: *const common.Context) ?Stored {
    const home = ctx.env.get("HOME") orelse return null;
    const path = std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ home, credentials_rel }) catch return null;
    const text = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(16 * 1024)) catch return null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    if (!std.mem.eql(u8, lines.next() orelse "", "cid-credentials 1")) return null;
    var server: ?[]const u8 = null;
    var token: ?[]const u8 = null;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "server ")) server = line["server ".len..];
        if (std.mem.startsWith(u8, line, "token ")) token = line["token ".len..];
    }
    if (server == null or token == null) return null;
    return .{ .server = server.?, .token = token.? };
}
