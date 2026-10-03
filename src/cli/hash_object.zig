//! `cid hash-object <file>...`: each file's content hash (BLAKE3, hex), one
//! per line, as `git hash-object` prints its ids. Plumbing for scripts and
//! for writers that register items themselves (the annotation platform):
//! the hash cid names and checks the bytes by. Not in `cid help`.

const std = @import("std");
const common = @import("common.zig");
const cache = @import("../client/cache.zig");

pub fn run(ctx: *const common.Context, args: []const [:0]const u8) common.ExitCode {
    if (args.len == 0)
        return common.fail(ctx, .usage, "name a file: 'cid hash-object <file>...'.", .{});
    const Hashed = struct { path: []const u8, hash: []const u8, size: u64 };
    const results = ctx.arena.alloc(Hashed, args.len) catch return .network;
    for (args, results) |path, *r| {
        const got = cache.hashFile(ctx.io, std.Io.Dir.cwd(), path) catch
            return common.fail(ctx, .usage, "cannot read '{s}'. Check the path, then run 'cid hash-object' again.", .{path});
        r.* = .{ .path = path, .hash = ctx.arena.dupe(u8, &got.hash_hex) catch return .network, .size = got.size };
    }
    if (common.emitJson(ctx, results)) return .ok;
    for (results) |r| ctx.out.print("{s}\n", .{r.hash}) catch return .network;
    return .ok;
}
