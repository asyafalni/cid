//! `cid deploy-key add <name> <public-key> [--write]`, `cid deploy-key list`,
//! `cid deploy-key remove <name>`: a dataset's deploy keys (docs/access.md),
//! for its owners. A deploy key is an SSH key a machine (CI) uses to reach
//! this one dataset as itself, never as a person: read (clone, pull) by
//! default, write (push) with --write, never more. The key is given as its
//! .pub file or the line itself.

const std = @import("std");
const common = @import("common.zig");
const workspace = @import("../client/workspace.zig");
const remote_mod = @import("../client/remote.zig");
const Remote = remote_mod.Remote;

const usage = "run 'cid deploy-key add <name> <public-key-or-.pub-file> [--write]', 'cid deploy-key list' or 'cid deploy-key remove <name>'";

pub fn run(ctx: *const common.Context, args: []const [:0]const u8) common.ExitCode {
    if (args.len == 0) return common.fail(ctx, .usage, "{s}", .{usage});
    const sub = args[0];
    const rest = args[1..];

    const ws = common.openWorkspace(ctx) catch
        return common.fail(ctx, .usage, common.not_a_dataset_msg, .{});
    const dataset = workspace.datasetPathOf(ws.config.address) orelse
        return common.fail(ctx, .integrity, ".cid/config.zon holds a broken address. Clone again, or fix it to cid@host:org/path.", .{});

    if (std.mem.eql(u8, sub, "list")) {
        if (rest.len != 0) return common.fail(ctx, .usage, "{s}", .{usage});
        const remote = common.remoteFor(ctx, dataset, .maintain, ws.config.address) catch |err| return common.noRemote(ctx, err, "cid deploy-key list");
        const got = remote.deployKeys(ctx.arena, "GET", null, null) catch |err| return failure(ctx, err, "list");
        return switch (got) {
            .refused => |r| common.fail(ctx, .usage, "{s}. {s}", .{ r.what, r.next }),
            .keys => |k| list(ctx, dataset, k.keys),
        };
    }
    if (std.mem.eql(u8, sub, "add")) {
        var write = false;
        var positional: [2]?[]const u8 = .{ null, null };
        var n: usize = 0;
        for (rest) |a| {
            if (std.mem.eql(u8, a, "--write")) {
                write = true;
            } else if (n < 2) {
                positional[n] = a;
                n += 1;
            } else return common.fail(ctx, .usage, "{s}", .{usage});
        }
        const name = positional[0] orelse return common.fail(ctx, .usage, "{s}", .{usage});
        const given = positional[1] orelse return common.fail(ctx, .usage, "give the key: its .pub file or its one line. Run 'cid deploy-key add {s} ci_key.pub' (make one with 'ssh-keygen -t ed25519 -f ci_key').", .{name});
        const key = keyText(ctx, given) orelse return common.fail(ctx, .usage, "'{s}' is neither a readable .pub file nor a public key line. Run 'cid deploy-key add {s} ci_key.pub'.", .{ given, name });
        const remote = common.remoteFor(ctx, dataset, .maintain, ws.config.address) catch |err| return common.noRemote(ctx, err, "cid deploy-key add");
        const got = remote.deployKeys(ctx.arena, "POST", name, .{ .key = key, .write = write }) catch |err| return failure(ctx, err, "add");
        switch (got) {
            .refused => |r| return common.fail(ctx, .usage, "{s}. {s}", .{ r.what, r.next }),
            .keys => |k| {
                if (common.emitJson(ctx, .{ .added = name, .level = k.level, .fingerprint = k.fingerprint, .keys = k.keys })) return .ok;
                ctx.out.print("Added deploy key '{s}' ({s}) to {s}: {s}\n", .{ name, k.level orelse "read", dataset, k.fingerprint orelse "" }) catch return .network;
                ctx.out.writeAll(if (write)
                    "Its SSH key can now clone, pull and push this dataset.\n"
                else
                    "Its SSH key can now clone and pull this dataset. Add --write to let it push.\n") catch return .network;
                return .ok;
            },
        }
    }
    if (std.mem.eql(u8, sub, "remove")) {
        if (rest.len != 1) return common.fail(ctx, .usage, "{s}", .{usage});
        const name = rest[0];
        const remote = common.remoteFor(ctx, dataset, .maintain, ws.config.address) catch |err| return common.noRemote(ctx, err, "cid deploy-key remove");
        const got = remote.deployKeys(ctx.arena, "DELETE", name, null) catch |err| return failure(ctx, err, "remove");
        switch (got) {
            .refused => |r| return common.fail(ctx, .usage, "{s}. {s}", .{ r.what, r.next }),
            .keys => |k| {
                if (common.emitJson(ctx, .{ .removed = name, .keys = k.keys })) return .ok;
                ctx.out.print("Removed deploy key '{s}' from {s}; that key no longer reaches it.\n", .{ name, dataset }) catch return .network;
                return .ok;
            },
        }
    }
    return common.fail(ctx, .usage, "'{s}' is not a deploy-key command; {s}", .{ sub, usage });
}

fn failure(ctx: *const common.Context, err: remote_mod.Error, what: []const u8) common.ExitCode {
    return switch (err) {
        error.AccessDenied => common.denied(ctx, "cid deploy-key"),
        error.NoSuchDataset => common.fail(ctx, .usage, "the dataset is not on the server yet. Run 'cid push' first.", .{}),
        error.ServerUnreachable => common.fail(ctx, .network, "cannot reach the server. Check CID_SERVER, then run 'cid deploy-key {s}' again.", .{what}),
        else => common.fail(ctx, .network, "the server could not {s} the deploy key. Run 'cid deploy-key {s}' again; if it persists, tell the administrator.", .{ what, what }),
    };
}

/// The key as given: a .pub file's first line, or the line itself.
fn keyText(ctx: *const common.Context, given: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, given, "ssh-") or std.mem.startsWith(u8, given, "ecdsa-") or std.mem.startsWith(u8, given, "sk-"))
        return given;
    const bytes = std.Io.Dir.cwd().readFileAlloc(ctx.io, given, ctx.arena, .limited(16 * 1024)) catch return null;
    const line = std.mem.trim(u8, bytes[0 .. std.mem.indexOfScalar(u8, bytes, '\n') orelse bytes.len], " \t\r");
    return if (line.len > 0) line else null;
}

fn list(ctx: *const common.Context, dataset: []const u8, keys: []const Remote.DeployKey) common.ExitCode {
    if (common.emitJson(ctx, .{ .keys = keys })) return .ok;
    if (keys.len == 0) {
        ctx.out.print("{s} has no deploy keys. Run 'cid deploy-key add <name> <key.pub>' to give a machine read access.\n", .{dataset}) catch return .network;
        return .ok;
    }
    var width: usize = 0;
    for (keys) |k| width = @max(width, k.name.len);
    for (keys) |k| {
        ctx.out.print("{s}", .{k.name}) catch return .network;
        ctx.out.splatByteAll(' ', width - k.name.len + 2) catch return .network;
        ctx.out.print("{s: <5}  {s}  added {s}  last used {s}\n", .{
            k.level, k.fingerprint, k.added_at[0..@min(k.added_at.len, 10)], if (k.last_used_at) |t| t[0..@min(t.len, 10)] else "never",
        }) catch return .network;
    }
    return .ok;
}
