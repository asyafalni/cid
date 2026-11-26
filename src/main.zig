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

    // `--json` anywhere: machine output, one JSON document on stdout.
    var json = false;
    var rest: std.ArrayList([:0]const u8) = .empty;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--json")) json = true else rest.append(arena, a) catch return @backingInt(cid.ExitCode.network);
    }
    const ctx: cid.common.Context = .{ .arena = arena, .gpa = gpa, .io = io, .out = out, .env = env, .json = json };
    const code: cid.ExitCode = switch (cid.command.parse(rest.items)) {
        .help => blk: {
            if (json) {
                cid.help.printJson(out, cid.version.text) catch break :blk .network;
                break :blk .ok;
            }
            cid.help.print(out) catch break :blk .network;
            break :blk .ok;
        },
        .help_for => |name| blk: {
            if (cid.help.printFor(out, name, json) catch break :blk .network) break :blk .ok;
            break :blk cid.common.fail(&ctx, .usage, "there is no cid command '{s}'. Run 'cid help' for the everyday ones, 'cid help --all' for the rest", .{name});
        },
        .help_all => blk: {
            if (json) {
                cid.help.printJson(out, cid.version.text) catch break :blk .network;
                break :blk .ok;
            }
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
        .pull => |cmd_args| cid.cli_pull.run(&ctx, cmd_args),
        .log => cid.cli_log.run(&ctx),
        .clone => |cmd_args| cid.cli_clone.run(&ctx, cmd_args),
        .checkout => |cmd_args| cid.cli_checkout.run(&ctx, cmd_args),
        .tag => |cmd_args| cid.cli_tag.run(&ctx, cmd_args),
        .deploy_key => |cmd_args| cid.cli_deploy_key.run(&ctx, cmd_args),
        .restore => |cmd_args| cid.cli_restore.run(&ctx, cmd_args),
        .hash_object => |cmd_args| cid.cli_hash_object.run(&ctx, cmd_args),
        .diff => |cmd_args| cid.cli_diff.run(&ctx, cmd_args),
        .branch => |cmd_args| cid.cli_branch.run(&ctx, cmd_args),
        .merge => |cmd_args| cid.cli_merge.run(&ctx, cmd_args),
        .remote => |cmd_args| cid.cli_remote.run(&ctx, cmd_args),
        .admin => |admin_args| cid.admin.run(arena, io, out, env, admin_args),
        .ssh_keys => |ssh_args| cid.cli_ssh.runKeys(arena, io, out, env, ssh_args),
        .ssh_auth => |ssh_args| cid.cli_ssh.runAuth(arena, io, out, env, ssh_args),
        .not_yet => |name| {
            if (json) return @backingInt(cid.common.fail(&ctx, .usage, "'{s}' is not built yet in this early version. Run 'cid help --json' for what works today.", .{name}));
            var ebuf: [256]u8 = undefined;
            var ew = std.Io.File.stderr().writer(io, &ebuf);
            ew.interface.print("cid: '{s}' is not built yet in this early version. Run 'cid help' for what works today.\n", .{name}) catch {};
            ew.interface.flush() catch {};
            return @backingInt(cid.ExitCode.usage);
        },
        .unknown => |name| {
            if (json) return @backingInt(cid.common.fail(&ctx, .usage, "'{s}' is not a cid command. Run 'cid help --json' for the commands there are.", .{name}));
            // git's rm and mv have no cid twin: a folder is staged as it
            // is, so say how, rather than only that they do not exist.
            if (std.mem.eql(u8, name, "rm") or std.mem.eql(u8, name, "mv"))
                return @backingInt(cid.common.fail(&ctx, .usage, "cid has no '{s}': change the folder itself ({s} the file as usual), then run 'cid add <path>' to stage it, as for any change", .{
                    name, if (std.mem.eql(u8, name, "rm")) "delete" else "move",
                }));
            return fail(io, .usage, name, "cid help");
        },
    };
    out.flush() catch return @backingInt(cid.ExitCode.network);
    return @backingInt(code);
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
    return @backingInt(code);
}
