//! `cid add <path>...`: stage added, changed and deleted files.

const std = @import("std");
const common = @import("common.zig");
const workspace = @import("../client/workspace.zig");

pub fn run(ctx: *const common.Context, args: []const [:0]const u8) common.ExitCode {
    if (args.len == 0)
        return common.fail(ctx, .usage, "nothing specified. Run 'cid add .' to stage everything.", .{});

    var ws = common.openWorkspace(ctx) catch
        return common.fail(ctx, .usage, common.not_a_dataset_msg, .{});
    if (workspace.readOnlyReason(ctx.arena, ws.config)) |why|
        return common.fail(ctx, .usage, "{s}", .{why});
    const cache_dir = common.openCacheDir(ctx) catch
        return common.fail(ctx, .network, "cannot open the cache folder (~/.cache/cid). Check HOME, then run 'cid add' again.", .{});

    const paths = ctx.arena.alloc([]const u8, args.len) catch return .network;
    for (args, 0..) |a, i| paths[i] = a;

    const summary = workspace.add(ctx.arena, ctx.io, &ws, cache_dir, paths) catch |err| switch (err) {
        error.PathspecUnmatched => return common.fail(ctx, .usage, "a path matched no files and nothing tracked. Run 'cid status' to see what is here.", .{}),
        error.StoreFailed => return common.fail(ctx, .network, "could not copy a file into the cache. Check disk space, then run 'cid add' again.", .{}),
        else => return common.fail(ctx, .integrity, ".cid/ state is unreadable. Run 'cid status' for details.", .{}),
    };

    const total = summary.staged_adds + summary.staged_deletes;
    if (common.emitJson(ctx, summary)) return .ok;
    if (total == 0) {
        ctx.out.writeAll("Nothing new to stage.\n") catch return .network;
    } else {
        ctx.out.print("Staged {d} change{s} ({d} added or changed, {d} deleted). Next: 'cid commit -m \"...\"'.\n", .{
            total, plural(total), summary.staged_adds, summary.staged_deletes,
        }) catch return .network;
    }
    return .ok;
}

fn plural(n: u32) []const u8 {
    return if (n == 1) "" else "s";
}
