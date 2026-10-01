//! `cid restore [--staged] <path>...`: unstage, or throw away local edits.

const std = @import("std");
const common = @import("common.zig");
const workspace = @import("../client/workspace.zig");

pub fn run(ctx: *const common.Context, args: []const [:0]const u8) common.ExitCode {
    var staged = false;
    var paths: std.ArrayList([]const u8) = .empty;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--staged")) {
            staged = true;
        } else {
            paths.append(ctx.arena, arg) catch return .network;
        }
    }
    if (paths.items.len == 0)
        return common.fail(ctx, .usage, "name what to restore: 'cid restore <path>' (throw away edits) or 'cid restore --staged <path>' (unstage).", .{});

    var ws = common.openWorkspace(ctx) catch
        return common.fail(ctx, .usage, common.not_a_dataset_msg, .{});

    if (staged) {
        const removed = workspace.restoreStaged(ctx.arena, ctx.io, &ws, paths.items) catch |err| switch (err) {
            error.PathspecUnmatched => return common.fail(ctx, .usage, "nothing staged matches. Run 'cid status' to see what is staged.", .{}),
            else => return common.fail(ctx, .integrity, ".cid/ state is unreadable. Run 'cid status' for details.", .{}),
        };
        ctx.out.print("Unstaged {d} change{s}. Run 'cid status' to review.\n", .{ removed, plural(removed) }) catch return .network;
        return .ok;
    }

    const cache_dir = common.openCacheDir(ctx) catch
        return common.fail(ctx, .network, "cannot open the cache folder (~/.cache/cid). Check HOME, then run 'cid restore' again.", .{});
    const summary = workspace.restoreWorktree(ctx.arena, ctx.io, &ws, cache_dir, paths.items) catch |err| switch (err) {
        error.PathspecUnmatched => return common.fail(ctx, .usage, "nothing tracked matches. Run 'cid status' to see local changes.", .{}),
        error.StoreFailed => return common.fail(ctx, .integrity, "a file's content is missing from the local cache. Run 'cid pull' to refetch, then 'cid restore' again.", .{}),
        else => return common.fail(ctx, .integrity, ".cid/ state is unreadable. Run 'cid status' for details.", .{}),
    };
    if (summary.restored == 0 and summary.skipped_untracked > 0) {
        ctx.out.print("Nothing restored: {d} file{s} here {s} never added to cid, so there is nothing to go back to. Delete them by hand if unwanted.\n", .{
            summary.skipped_untracked, plural(summary.skipped_untracked), wasWere(summary.skipped_untracked),
        }) catch return .network;
    } else {
        ctx.out.print("Restored {d} file{s}.", .{ summary.restored, plural(summary.restored) }) catch return .network;
        if (summary.skipped_untracked > 0) {
            ctx.out.print(" Left {d} untracked file{s} alone.", .{ summary.skipped_untracked, plural(summary.skipped_untracked) }) catch return .network;
        }
        ctx.out.writeAll("\n") catch return .network;
    }
    return .ok;
}

fn plural(n: u32) []const u8 {
    return if (n == 1) "" else "s";
}

fn wasWere(n: u32) []const u8 {
    return if (n == 1) "was" else "were";
}
