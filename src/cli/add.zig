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

    // git's "everything" (-A, --all) is cid's 'cid add .'; any other
    // option is said, never taken for a path.
    const paths = ctx.arena.alloc([]const u8, args.len) catch return .network;
    for (args, 0..) |a, i| {
        if (std.mem.eql(u8, a, "-A") or std.mem.eql(u8, a, "--all")) {
            paths[i] = ".";
        } else if (std.mem.startsWith(u8, a, "-") and a.len > 1) {
            return common.fail(ctx, .usage, "'{s}' is not an option of cid add. Run 'cid add <path>...', or 'cid add .' for everything.", .{a});
        } else paths[i] = a;
    }

    const summary = workspace.add(ctx.arena, ctx.io, &ws, cache_dir, paths) catch |err| switch (err) {
        error.PathspecUnmatched => return common.fail(ctx, .usage, "a path matched no files and nothing tracked. Run 'cid status' to see what is here.", .{}),
        error.StoreFailed => return common.fail(ctx, .network, "could not copy a file into the cache. Check disk space, then run 'cid add' again.", .{}),
        else => return common.fail(ctx, .integrity, ".cid/ state is unreadable. Run 'cid status' for details.", .{}),
    };

    // Links are never dropped in silence: the add stops, naming them.
    if (summary.links.len > 0) {
        const shown = summary.links[0..@min(summary.links.len, 3)];
        const names = std.mem.join(ctx.arena, ", ", shown) catch return .network;
        const more = if (summary.links.len > shown.len)
            std.fmt.allocPrint(ctx.arena, " and {d} more", .{summary.links.len - shown.len}) catch return .network
        else
            "";
        return common.fail(ctx, .usage, "{d} of these paths {s} a symbolic link ({s}{s}), and cid stores files, not links: nothing was staged. " ++
            "Put the files themselves there (cp -L), or name the links in .cidignore, then run 'cid add' again.", .{
            summary.links.len, if (summary.links.len == 1) "is" else "are", names, more,
        });
    }

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
