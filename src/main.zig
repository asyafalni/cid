//! cid — version control for datasets.
//! Entry point: argument parsing, dispatch, exit codes. Thin by rule:
//! errors are mapped to exit codes and friendly messages here, nowhere else.

const std = @import("std");
const command = @import("cli/command.zig");
const help = @import("cli/help.zig");
const version = @import("cli/version.zig");

/// CLI exit codes (CLAUDE.md, "Rules for every command").
pub const ExitCode = enum(u8) {
    ok = 0,
    usage = 1,
    conflict = 2,
    integrity = 3,
    network = 4,
    access = 5,
};

pub fn main(init: std.process.Init) u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = init.minimal.args.toSlice(arena) catch
        return fail(io, .usage, "could not read arguments", "cid help");
    return run(io, args[1..]);
}

fn run(io: std.Io, args: []const [:0]const u8) u8 {
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout_writer.interface;
    const is_tty = std.Io.File.stdout().isTty(io) catch false;

    const code: ExitCode = switch (command.parse(args)) {
        .help => blk: {
            help.print(out) catch break :blk .network;
            break :blk .ok;
        },
        .version => blk: {
            version.print(out, is_tty) catch break :blk .network;
            break :blk .ok;
        },
        .unknown => |name| return fail(io, .usage, name, "cid help"),
    };
    out.flush() catch return @intFromEnum(ExitCode.network);
    return @intFromEnum(code);
}

/// Every error ends with the command to run next.
fn fail(io: std.Io, code: ExitCode, what: []const u8, next: []const u8) u8 {
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

test {
    // Pull in all referenced modules' tests.
    std.testing.refAllDecls(@This());
}
