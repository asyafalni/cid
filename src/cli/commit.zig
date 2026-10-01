//! `cid commit -m <msg> [-a]`: save staged changes as a local commit.
//! Instant, works offline (rule 1).

const std = @import("std");
const common = @import("common.zig");
const workspace = @import("../client/workspace.zig");

pub fn run(ctx: *const common.Context, args: []const [:0]const u8) common.ExitCode {
    var message: ?[]const u8 = null;
    var stage_all = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-m")) {
            i += 1;
            if (i >= args.len) return common.fail(ctx, .usage, "-m needs a message. Run 'cid commit -m \"what changed\"'.", .{});
            message = args[i];
        } else if (std.mem.eql(u8, args[i], "-a")) {
            stage_all = true;
        } else if (std.mem.eql(u8, args[i], "-am") or std.mem.eql(u8, args[i], "-ma")) {
            stage_all = true;
            i += 1;
            if (i >= args.len) return common.fail(ctx, .usage, "-m needs a message. Run 'cid commit -am \"what changed\"'.", .{});
            message = args[i];
        } else {
            return common.fail(ctx, .usage, "unexpected argument '{s}'. Run 'cid commit -m \"what changed\"'.", .{args[i]});
        }
    }
    const msg = message orelse
        return common.fail(ctx, .usage, "a message is needed. Run 'cid commit -m \"what changed\"'.", .{});
    if (msg.len == 0)
        return common.fail(ctx, .usage, "the message is empty. Run 'cid commit -m \"what changed\"'.", .{});

    var ws = common.openWorkspace(ctx) catch
        return common.fail(ctx, .usage, common.not_a_dataset_msg, .{});

    if (stage_all) {
        const cache_dir = common.openCacheDir(ctx) catch
            return common.fail(ctx, .network, "cannot open the cache folder (~/.cache/cid). Check HOME, then run 'cid commit -a' again.", .{});
        _ = workspace.add(ctx.arena, ctx.io, &ws, cache_dir, &.{"."}) catch
            return common.fail(ctx, .integrity, "could not stage changes. Run 'cid status' for details.", .{});
    }

    const author = common.author(ctx) catch return .network;
    const summary = workspace.commit(ctx.arena, ctx.io, &ws, msg, author) catch |err| switch (err) {
        error.NothingStaged => return common.fail(ctx, .usage, "nothing staged. Run 'cid add <path>' first, or 'cid commit -a -m \"...\"'.", .{}),
        else => return common.fail(ctx, .integrity, ".cid/ state is unreadable. Run 'cid status' for details.", .{}),
    };

    const id = summary.id.toString();
    const first_line = firstLine(msg);
    // 13 chars covers the whole UUIDv7 millisecond timestamp; a shorter,
    // git-style prefix would look identical for commits made close together.
    ctx.out.print("[{s} {s}] {s}\n {d} change{s}\n", .{
        "main", id[0..13], first_line, summary.changes, plural(summary.changes),
    }) catch return .network;
    return .ok;
}

fn firstLine(msg: []const u8) []const u8 {
    const nl = std.mem.indexOfScalar(u8, msg, '\n') orelse return msg;
    return msg[0..nl];
}

fn plural(n: u32) []const u8 {
    return if (n == 1) "" else "s";
}
