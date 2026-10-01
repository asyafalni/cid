//! `cid init <address> --git <git-url>`: create a dataset from the current
//! folder, paired with its git repository (both addresses required, rule 3).

const std = @import("std");
const common = @import("common.zig");
const workspace = @import("../client/workspace.zig");

const usage_hint =
    "run 'cid init <address> --git <git-url>', e.g.\n" ++
    "  cid init cid@cidhub.com:your-org/datasets/my-data \\\n" ++
    "    --git git@gitlab.com:your-org/datasets/my-data.git";

pub fn run(ctx: *const common.Context, args: []const [:0]const u8) common.ExitCode {
    var address: ?[]const u8 = null;
    var git_url: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--git")) {
            i += 1;
            if (i >= args.len) return common.fail(ctx, .usage, "--git needs a value; {s}", .{usage_hint});
            git_url = args[i];
        } else if (address == null) {
            address = args[i];
        } else {
            return common.fail(ctx, .usage, "unexpected argument '{s}'; {s}", .{ args[i], usage_hint });
        }
    }
    const addr = address orelse
        return common.fail(ctx, .usage, "an address is needed; {s}", .{usage_hint});
    const git = git_url orelse
        return common.fail(ctx, .usage, "every dataset is paired with a git repository; {s}", .{usage_hint});

    const work_dir = std.Io.Dir.cwd().openDir(ctx.io, ".", .{ .iterate = true }) catch
        return common.fail(ctx, .usage, "cannot open the current folder. Run 'cid init' from the dataset folder.", .{});
    workspace.init(ctx.arena, ctx.io, work_dir, addr, git) catch |err| switch (err) {
        error.BadAddress => return common.fail(ctx, .usage, "'{s}' is not a cid address (expected cid@host:org/path); {s}", .{ addr, usage_hint }),
        error.AlreadyADataset => return common.fail(ctx, .usage, "this folder is already a cid dataset. Run 'cid status'.", .{}),
        else => return common.fail(ctx, .network, "could not write .cid/ here. Check folder permissions, then run 'cid init' again.", .{}),
    };

    const path = workspace.datasetPathOf(addr).?;
    ctx.out.print(
        "Initialized {s} from this folder.\nNext: 'cid add .' to stage files, then 'cid commit -m \"First import\"'.\n",
        .{path},
    ) catch return .network;
    return .ok;
}
