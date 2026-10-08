//! `cid log`: commits, newest first; unpushed commits marked. Works
//! offline (local commits only, with a note) when the server is away.

const std = @import("std");
const common = @import("common.zig");
const workspace = @import("../client/workspace.zig");
const local = @import("../client/local.zig");

pub fn run(ctx: *const common.Context) common.ExitCode {
    const ws = common.openWorkspace(ctx) catch
        return common.fail(ctx, .usage, common.not_a_dataset_msg, .{});

    // The folder's branch: its history, not always main's.
    const branch = if (local.loadHead(ctx.arena, ctx.io, ws.cid_dir)) |h| h.branch else |_| "main";

    // Local, always available: the unpushed commits, marked.
    const last_pushed = local.readLastPushed(ctx.arena, ctx.io, ws.cid_dir);
    const locals = local.listUnpushed(ctx.arena, ctx.io, ws.cid_dir, last_pushed) catch
        return common.fail(ctx, .integrity, ".cid/ state is unreadable. Run 'cid status' for details.", .{});

    if (ctx.json) {
        // Local commits, then the server's (null when it cannot be reached).
        const name_j = workspace.datasetPathOf(ws.config.address) orelse "";
        const server: ?[]const remote_mod.Remote.LogEntry = if (common.remoteFor(ctx, name_j, .read, ws.config.address)) |remote|
            remote.log(ctx.arena, branch) catch null
        else |_|
            null;
        const Local = struct { id: []const u8, message: []const u8, author: []const u8, authored_at_ms: u64 };
        const list = ctx.arena.alloc(Local, locals.len) catch return .network;
        for (list, locals) |*l, c| l.* = .{ .id = ctx.arena.dupe(u8, &c.id.toString()) catch return .network, .message = c.message, .author = c.author, .authored_at_ms = c.authored_at_ms };
        _ = common.emitJson(ctx, .{ .unpushed = list, .server = server });
        return .ok;
    }
    var printed: usize = 0;
    for (locals) |commit| {
        printLocal(ctx.out, commit, " (not pushed)") catch return .network;
        printed += 1;
    }

    // The server's view, when reachable.
    const name = workspace.datasetPathOf(ws.config.address) orelse "";
    if (common.remoteFor(ctx, name, .read, ws.config.address)) |remote| {
        common.warnGitDrift(ctx, remote, ws.config.git_url);
        if (remote.log(ctx.arena, branch)) |entries| {
            for (entries) |e| {
                printRemote(ctx.out, e) catch return .network;
                printed += 1;
            }
        } else |err| {
            ctx.out.writeAll(if (err == error.AccessDenied)
                "(access denied by the server: showing local commits only)\n"
            else
                "(server unreachable: showing local commits only)\n") catch return .network;
        }
    } else |_| {
        ctx.out.writeAll("(no server configured: showing local commits only)\n") catch return .network;
    }

    if (printed == 0)
        ctx.out.writeAll("No commits yet. Run 'cid add .' then 'cid commit -m \"...\"'.\n") catch return .network;
    return .ok;
}

fn printLocal(out: *std.Io.Writer, commit: local.Commit, mark: []const u8) !void {
    try out.print("commit {s}{s}\nAuthor: {s}\nDate:   {s}\n\n    {s}\n\n", .{
        &commit.id.toString(), mark, commit.author, &fmtDate(commit.authored_at_ms), firstLine(commit.message),
    });
}

const remote_mod = @import("../client/remote.zig");

fn printRemote(out: *std.Io.Writer, e: remote_mod.Remote.LogEntry) !void {
    // A commit that is a release says so, as `git log --decorate` does.
    try out.print("commit {s}", .{e.id});
    if (e.releases) |names| {
        try out.print(" (release: {s}", .{names});
        // The server writes git after the release; until it has, say so.
        if (e.git_pending) |pending| {
            if (std.mem.eql(u8, pending, names)) try out.writeAll("; not in git yet") else try out.print("; not in git yet: {s}", .{pending});
        }
        try out.writeAll(")");
    }
    try out.print("\nAuthor: {s}\nDate:   {s}\n\n    {s}\n\n", .{
        e.author, &fmtDate(e.authored_at_ms), firstLine(e.message),
    });
}

/// "2026-10-01 05:12" from Unix milliseconds.
fn fmtDate(ms: u64) [16]u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = ms / 1000 };
    const day = es.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = es.getDaySeconds();
    var out: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
    }) catch unreachable;
    return out;
}

fn firstLine(msg: []const u8) []const u8 {
    const nl = std.mem.indexOfScalar(u8, msg, '\n') orelse return msg;
    return msg[0..nl];
}

test "date formatting" {
    try std.testing.expectEqualStrings("2013-05-24 00:00", &fmtDate(1369353600000));
}

test "a release not in git yet says so, naming it when others at the commit are" {
    var buf: [512]u8 = undefined;
    inline for (.{
        .{ @as(?[]const u8, "v1.0.0"), @as(?[]const u8, null), "commit c1 (release: v1.0.0)\n" },
        .{ @as(?[]const u8, "v1.0.0"), @as(?[]const u8, "v1.0.0"), "commit c1 (release: v1.0.0; not in git yet)\n" },
        .{ @as(?[]const u8, "v1.0.0, v1.0.1"), @as(?[]const u8, "v1.0.1"), "commit c1 (release: v1.0.0, v1.0.1; not in git yet: v1.0.1)\n" },
    }) |case| {
        var w: std.Io.Writer = .fixed(&buf);
        try printRemote(&w, .{ .id = "c1", .parent = null, .message = "m", .author = "a", .authored_at_ms = 0, .releases = case[0], .git_pending = case[1] });
        const out = w.buffered();
        try std.testing.expectEqualStrings(case[2], out[0 .. std.mem.indexOfScalar(u8, out, '\n').? + 1]);
    }
}
