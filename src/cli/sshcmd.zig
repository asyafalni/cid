//! The two server-side entry points sshd calls (never people, so they are
//! not in any help text):
//!
//!   cid ssh-keys --fingerprint=SHA256:…   AuthorizedKeysCommand: prints the
//!                                         authorized_keys line for a known
//!                                         key, with the forced command.
//!   cid ssh-auth --account=<id>           the forced command: reads
//!                                         SSH_ORIGINAL_COMMAND, checks
//!                                         permission, prints a token grant
//!                                         as JSON.
//!
//! Both read CID_DB; ssh-auth also reads CID_TOKEN_SECRET and
//! CID_PUBLIC_URL. See deploy/sshd/.

const std = @import("std");
const root = @import("../cid.zig");
const dbx = @import("../store/db.zig");
const auth = @import("../access/auth.zig");

const ExitCode = root.ExitCode;

pub fn runKeys(
    arena: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    env: *const std.process.Environ.Map,
    args: []const [:0]const u8,
) ExitCode {
    var fingerprint: ?[]const u8 = null;
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--fingerprint=")) fingerprint = arg["--fingerprint=".len..];
    }
    const fp = fingerprint orelse return quietFail(io, "ssh-keys needs --fingerprint=");

    var standalone: dbx.Standalone = undefined;
    connectDb(&standalone, arena, io, env) orelse return .network;
    defer standalone.close();
    var scope = dbx.Run.init(arena);
    defer scope.deinit();

    const line = auth.authorizedKeysLine(arena, &standalone.db, &scope, fp) catch return .network;
    if (line) |l| out.writeAll(l) catch return .network;
    out.flush() catch return .network;
    return .ok; // no match prints nothing: sshd just refuses the key
}

pub fn runAuth(
    arena: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    env: *const std.process.Environ.Map,
    args: []const [:0]const u8,
) ExitCode {
    var account: ?[]const u8 = null;
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--account=")) account = arg["--account=".len..];
    }
    const acct = account orelse return quietFail(io, "ssh-auth needs --account=");
    const original = env.get("SSH_ORIGINAL_COMMAND") orelse
        return quietFail(io, "no command. This endpoint only answers: cid-auth <dataset> <read|write>");
    const secret = env.get("CID_TOKEN_SECRET") orelse
        return quietFail(io, "server misconfigured (CID_TOKEN_SECRET unset); tell the administrator");
    const server_url = env.get("CID_PUBLIC_URL") orelse
        return quietFail(io, "server misconfigured (CID_PUBLIC_URL unset); tell the administrator");

    var standalone: dbx.Standalone = undefined;
    connectDb(&standalone, arena, io, env) orelse return .network;
    defer standalone.close();
    var scope = dbx.Run.init(arena);
    defer scope.deinit();

    const req = auth.parseOriginalCommand(original, acct) catch
        return quietFail(io, "refused. This endpoint only answers: cid-auth <dataset> <read|write>");
    const now: u64 = @intCast(@max(0, std.Io.Timestamp.now(io, .real).toSeconds()));
    const grant = auth.authorize(arena, &standalone.db, &scope, secret, server_url, now, req) catch |err| switch (err) {
        error.AccessDenied => return quietFail(io, "access denied. Ask for access to the dataset's project, then try again."),
        else => return quietFail(io, "the server could not answer; try again or tell the administrator"),
    };

    out.print("{f}\n", .{std.json.fmt(.{
        .token = grant.token,
        .url = grant.url,
        .expires_in_secs = grant.expires_in_secs,
    }, .{})}) catch return .network;
    out.flush() catch return .network;
    return .ok;
}

fn connectDb(
    standalone: *dbx.Standalone,
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
) ?void {
    const spec = env.get("CID_DB") orelse {
        _ = quietFail(io, "server misconfigured (CID_DB unset); tell the administrator");
        return null;
    };
    standalone.open(arena, spec) catch {
        _ = quietFail(io, "the server database is unreachable; tell the administrator");
        return null;
    };
}

/// These run under sshd: terse, single-line, never a stack of hints.
fn quietFail(io: std.Io, msg: []const u8) ExitCode {
    var buf: [512]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    w.interface.print("cid: {s}\n", .{msg}) catch {};
    w.interface.flush() catch {};
    return .access;
}
