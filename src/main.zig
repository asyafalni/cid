//! cid — version control for datasets.
//! Entry point: argument parsing, dispatch, exit codes. Thin by rule:
//! errors are mapped to exit codes and friendly messages here or in the
//! command files, nowhere deeper.

const std = @import("std");
const cid = @import("cid");
const nilo = @import("nilo_http");

// Nilo's two lines of root wiring (its listen() checks they are here).
pub const std_options = nilo.std_options;
pub const std_options_debug_io = nilo.debug_io;

pub fn main(init: std.process.Init) u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = init.minimal.args.toSlice(arena) catch
        return fail(io, .usage, "could not read arguments", "cid help");
    return run(arena, init.gpa, io, init.environ_map, args[1..]);
}

fn run(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    args: []const [:0]const u8,
) u8 {
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout_writer.interface;
    const is_tty = std.Io.File.stdout().isTty(io) catch false;

    const ctx: cid.common.Context = .{ .arena = arena, .gpa = gpa, .io = io, .out = out, .env = env };
    const code: cid.ExitCode = switch (cid.command.parse(args)) {
        .help => blk: {
            cid.help.print(out) catch break :blk .network;
            break :blk .ok;
        },
        .help_all => blk: {
            cid.help.printAll(out) catch break :blk .network;
            break :blk .ok;
        },
        .version => blk: {
            cid.version.print(out, is_tty) catch break :blk .network;
            break :blk .ok;
        },
        .init => |cmd_args| cid.cli_init.run(&ctx, cmd_args),
        .add => |cmd_args| cid.cli_add.run(&ctx, cmd_args),
        .commit => |cmd_args| cid.cli_commit.run(&ctx, cmd_args),
        .status => cid.cli_status.run(&ctx),
        .push => cid.cli_push.run(&ctx),
        .pull => cid.cli_pull.run(&ctx),
        .log => cid.cli_log.run(&ctx),
        .clone => |cmd_args| cid.cli_clone.run(&ctx, cmd_args),
        .checkout => |cmd_args| cid.cli_checkout.run(&ctx, cmd_args),
        .tag => |cmd_args| cid.cli_tag.run(&ctx, cmd_args),
        .restore => |cmd_args| cid.cli_restore.run(&ctx, cmd_args),
        .diff => |cmd_args| cid.cli_diff.run(&ctx, cmd_args),
        .branch => |cmd_args| cid.cli_branch.run(&ctx, cmd_args),
        .merge => |cmd_args| cid.cli_merge.run(&ctx, cmd_args),
        .login => |cmd_args| cid.cli_login.runLogin(&ctx, cmd_args),
        .logout => cid.cli_login.runLogout(&ctx),
        .admin => |admin_args| cid.admin.run(arena, io, out, env, admin_args),
        .ssh_keys => |ssh_args| cid.cli_ssh.runKeys(arena, io, out, env, ssh_args),
        .ssh_auth => |ssh_args| cid.cli_ssh.runAuth(arena, io, out, env, ssh_args),
        .not_yet => |name| {
            var ebuf: [256]u8 = undefined;
            var ew = std.Io.File.stderr().writer(io, &ebuf);
            ew.interface.print("cid: '{s}' is not built yet in this early version. Run 'cid help' for what works today.\n", .{name}) catch {};
            ew.interface.flush() catch {};
            return @intFromEnum(cid.ExitCode.usage);
        },
        .unknown => |name| return fail(io, .usage, name, "cid help"),
    };
    out.flush() catch return @intFromEnum(cid.ExitCode.network);
    return @intFromEnum(code);
}

/// Every error ends with the command to run next.
fn fail(io: std.Io, code: cid.ExitCode, what: []const u8, next: []const u8) u8 {
    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const err = &stderr_writer.interface;
    switch (code) {
        .usage => err.print("cid: '{s}' is not a cid command. Run '{s}'.\n", .{ what, next }) catch {},
        else => err.print("cid: {s}. Run '{s}'.\n", .{ what, next }) catch {},
    }
    err.flush() catch {};
    return @intFromEnum(code);
}
