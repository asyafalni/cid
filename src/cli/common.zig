//! Shared plumbing for working-folder commands: the Context every command
//! receives, error printing (always ending with the next command to run),
//! cache-directory and author resolution.

const std = @import("std");
const progress_mod = @import("../util/progress.zig");
const root = @import("../cid.zig");
const workspace = @import("../client/workspace.zig");
const remote_mod = @import("../client/remote.zig");

pub const ExitCode = root.ExitCode;

pub const Context = struct {
    arena: std.mem.Allocator,
    /// For memory reused and freed while a command streams (a line
    /// buffer, per-file scratch): never the arena, which cannot free.
    gpa: std.mem.Allocator,
    /// `--json`: results as one JSON document on stdout; errors as
    /// {"error", "exit"} on stderr. Text is unchanged without it.
    json: bool = false,
    io: std.Io,
    out: *std.Io.Writer,
    env: *const std.process.Environ.Map,
    /// Why the last SSH call failed, filled by it, so the command's error
    /// names the host and the reason (owned by main; null in tests).
    ssh_problem: ?*SshProblem = null,
};

pub const SshProblem = struct { target: []const u8 = "", reason: []const u8 = "" };

/// The one line of an external program's error output that says what went
/// wrong: not a host's banner, not git's "make sure you have the correct
/// access rights" boilerplate. Prefixes (`remote: `, `ssh: `, `ERROR: `)
/// dropped; at most 200 bytes. Empty when nothing is left.
pub fn tellingLine(stderr: []const u8) []const u8 {
    var best: []const u8 = "";
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \r\t");
        if (std.mem.startsWith(u8, line, "remote:")) line = std.mem.trim(u8, line["remote:".len..], " ");
        if (line.len == 0 or std.mem.startsWith(u8, line, "===")) continue;
        // git's asides are never why it failed.
        if (std.mem.startsWith(u8, line, "warning:") or std.mem.startsWith(u8, line, "hint:")) continue;
        if (std.mem.startsWith(u8, line, "Please make sure") or std.mem.startsWith(u8, line, "and the repository exists") or
            std.mem.startsWith(u8, line, "fatal: Could not read from remote repository")) continue;
        // A host's own error wins over the lines git adds after it.
        if (std.mem.startsWith(u8, line, "ERROR:")) return clip(std.mem.trim(u8, line["ERROR:".len..], " "));
        if (std.mem.startsWith(u8, line, "ssh: ")) return clip(line["ssh: ".len..]);
        if (best.len == 0) best = line;
    }
    if (std.mem.startsWith(u8, best, "fatal: ")) best = best["fatal: ".len..];
    return clip(best);
}

fn clip(line: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, line, ". ");
    return trimmed[0..@min(trimmed.len, 200)];
}

/// Whether a program's reason is the network's (exit 4), not the address's.
pub fn networkReason(reason: []const u8) bool {
    inline for (.{ "Could not resolve", "Connection refused", "timed out", "No route to host", "Network is unreachable", "no answer" }) |s|
        if (std.mem.indexOf(u8, reason, s) != null) return true;
    return false;
}

test "the telling line of ssh's and git's complaints" {
    try std.testing.expectEqualStrings("Could not resolve hostname nohost.invalid: Name or service not known", tellingLine("ssh: Could not resolve hostname nohost.invalid: Name or service not known\r\n"));
    try std.testing.expectEqualStrings("The project you were looking for could not be found or you don't have permission to view it", tellingLine(
        \\remote: 
        \\remote: ========================================================================
        \\remote: 
        \\remote: ERROR: The project you were looking for could not be found or you don't have permission to view it.
        \\
        \\remote: 
        \\fatal: Could not read from remote repository.
        \\
        \\Please make sure you have the correct access rights
        \\and the repository exists.
    ));
    try std.testing.expectEqualStrings("Remote branch main not found in upstream origin", tellingLine("warning: --depth is ignored in local clones; use file:// instead.\nfatal: Remote branch main not found in upstream origin\n"));
    try std.testing.expectEqualStrings("", tellingLine("\n\n"));
    try std.testing.expect(networkReason("Could not resolve hostname x"));
    try std.testing.expect(!networkReason("Permission denied (publickey)"));
}

/// Something the user should know that did not stop the command, on
/// stderr (so it never mixes into a result on stdout).
pub fn warn(ctx: *const Context, comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(ctx.io, &buf);
    stderr_writer.interface.print("cid: warning: " ++ fmt ++ "\n", args) catch {};
    stderr_writer.interface.flush() catch {};
}

/// The dataset's git repository is the server's to know: when a folder
/// records another (the dataset moved, `cid admin rename --git`, and this
/// folder never followed), say so and how to follow. Only a warning, and
/// silent when the server cannot be asked: nothing a folder does goes to
/// git, so the command itself is never at stake.
pub fn warnGitDrift(ctx: *const Context, remote: *const remote_mod.Remote, folder_git_url: []const u8) void {
    if (ctx.json) return;
    const info = remote.info(ctx.arena) catch return;
    if (gitUrlsMatch(info.git_url, folder_git_url)) return;
    warn(ctx, "this folder records the dataset's git repository as {s}, but the server's is {s}. Run 'cid remote set-url --git {s}'.", .{ folder_git_url, info.git_url, info.git_url });
}

/// The same repository however it is spelled at the end: a trailing
/// slash or `.git` makes no difference to git.
fn gitUrlsMatch(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, trimGit(a), trimGit(b));
}

fn trimGit(url: []const u8) []const u8 {
    var u = std.mem.trimEnd(u8, url, "/");
    if (std.mem.endsWith(u8, u, ".git")) u = u[0 .. u.len - 4];
    return u;
}

test "git URLs match whatever their ending" {
    try std.testing.expect(gitUrlsMatch("git@h:org/x.git", "git@h:org/x"));
    try std.testing.expect(gitUrlsMatch("https://h/org/x/", "https://h/org/x.git"));
    try std.testing.expect(!gitUrlsMatch("git@h:org/x.git", "git@h:org/y.git"));
}

/// Every error ends with the command to run next.
/// The server refused this identity or this action (exit 5). Roles come
/// from the dataset's repository on the server's git host (docs/access.md):
/// read clones and pulls, write pushes, maintain tags, branches and merges.
/// The client does not know which host, so both hosts' role names are said.
pub fn denied(ctx: *const Context, comptime command: []const u8) ExitCode {
    return fail(ctx, .access, "access denied: the server refused this for your key or token. Ask an owner of the dataset's repository for the access you need (read to clone or pull, write to push, maintain to tag, branch or merge; GitLab's Reporter, Developer, Maintainer; GitHub's Read, Write, Maintain), then run '" ++ command ++ "' again.", .{});
}

pub fn fail(ctx: *const Context, code: ExitCode, comptime fmt: []const u8, args: anytype) ExitCode {
    var buf: [2048]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(ctx.io, &buf);
    const err = &stderr_writer.interface;
    if (ctx.json) {
        const text = std.fmt.allocPrint(ctx.arena, fmt, args) catch "out of memory";
        err.print("{f}\n", .{std.json.fmt(.{ .@"error" = text, .exit = @backingInt(code) }, .{})}) catch {};
    } else {
        err.print("cid: " ++ fmt ++ "\n", args) catch {};
    }
    err.flush() catch {};
    return code;
}

/// With `--json`, a stop on conflicts as data and true: the error every
/// failure carries, plus each path and its decision so far, so a program
/// need not read them out of the sentence. `conflicts` is any list of
/// `{path, choice}`; `next` the sentence saying how to decide and go on.
pub fn conflictsJson(ctx: *const Context, comptime what: []const u8, comptime next: []const u8, conflicts: anytype) bool {
    if (!ctx.json) return false;
    var buf: [2048]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(ctx.io, &buf);
    const err = &stderr_writer.interface;
    err.print("{f}\n", .{std.json.fmt(.{
        .@"error" = what ++ " " ++ next,
        .exit = @backingInt(ExitCode.conflict),
        .conflicts = conflicts,
    }, .{})}) catch {};
    err.flush() catch {};
    return true;
}

/// With `--json`, prints `value` as the command's result and answers true;
/// the caller then skips its text.
pub fn emitJson(ctx: *const Context, value: anytype) bool {
    if (!ctx.json) return false;
    ctx.out.print("{f}\n", .{std.json.fmt(value, .{})}) catch {};
    return true;
}

pub fn openWorkspace(ctx: *const Context) workspace.OpenError!workspace.Workspace {
    const work_dir = std.Io.Dir.cwd().openDir(ctx.io, ".", .{ .iterate = true }) catch
        return error.NotADataset;
    var ws = try workspace.open(ctx.arena, ctx.io, work_dir);
    ws.progress = stderrProgress(ctx);
    return ws;
}

/// A progress line on stderr for this command (drawn only on a terminal,
/// only for work over a second); null if it cannot be made.
pub fn stderrProgress(ctx: *const Context) ?*progress_mod.Progress {
    const buf = ctx.arena.alloc(u8, 512) catch return null;
    const w = ctx.arena.create(std.Io.File.Writer) catch return null;
    w.* = std.Io.File.stderr().writer(ctx.io, buf);
    const p = ctx.arena.create(progress_mod.Progress) catch return null;
    p.* = progress_mod.forStderr(ctx.io, &w.interface);
    return p;
}

pub const not_a_dataset_msg =
    "this folder is not a cid dataset (no .cid/ here).\n" ++
    "Run 'cid init <address> --git <git-url>' to create one from this folder.";

/// ~/.cache/cid (or $XDG_CACHE_HOME/cid), created if missing.
pub fn openCacheDir(ctx: *const Context) !std.Io.Dir {
    const path = if (ctx.env.get("XDG_CACHE_HOME")) |xdg|
        try std.fmt.allocPrint(ctx.arena, "{s}/cid", .{xdg})
    else if (ctx.env.get("HOME")) |home|
        try std.fmt.allocPrint(ctx.arena, "{s}/.cache/cid", .{home})
    else
        return error.NoCacheDir;
    return std.Io.Dir.cwd().createDirPathOpen(ctx.io, path, .{});
}

/// How commands reach the server: the SSH flow (a short-lived token from
/// 'ssh cid@host cid-auth <dataset> <level>', like git), or the
/// CID_SERVER/CID_TOKEN environment override for CI and machines without
/// SSH. The override wins when both are set.
/// What a command says when it got no server: refused (exit 5), or none
/// reachable or configured (exit 1).
pub fn noRemote(ctx: *const Context, err: anyerror, comptime command: []const u8) ExitCode {
    if (err == error.AccessDenied) return denied(ctx, command);
    // A key the server has never seen is not a role an owner can grant:
    // the key needs adding, by its holder.
    if (err == error.KeyUnknown) {
        const target = if (ctx.ssh_problem) |p| p.target else "the server";
        return fail(ctx, .access, "the cid server {s} does not know your SSH key.\nAdd your public key (the one 'ssh -v {s}' offers) on the dashboard's SSH keys page,\nor to your account on the server's git host, then run '" ++ command ++ "' again.", .{ target, target });
    }
    if (err == error.NeedToken) return fail(ctx, .usage, need_token_msg ++ "'" ++ command ++ "' again.", .{});
    // The SSH call ran and failed: the server or the network (exit 4),
    // named with ssh's own reason; otherwise nothing says where the server
    // is (exit 1).
    if (err == error.ServerUnreachable) {
        if (ctx.ssh_problem) |p| if (p.target.len > 0) return fail(
            ctx,
            .network,
            "cannot reach the cid server {s} over SSH: {s}.\nCheck that 'ssh {s}' answers (cid replies and closes), or export CID_SERVER\nand CID_TOKEN, then run '" ++ command ++ "' again.",
            .{ p.target, if (p.reason.len > 0) p.reason else "ssh gave no reason", p.target },
        );
        return fail(ctx, .network, no_server_msg, .{});
    }
    return fail(ctx, .usage, no_server_msg, .{});
}

pub const need_token_msg =
    "this https address carries no token, and CID_TOKEN is not set.\n" ++
    "Make a token on the dashboard's Tokens page, then put it in the address\n" ++
    "(https://you:TOKEN@host/<dataset>) or export CID_TOKEN, then run ";

pub const no_server_msg =
    "cannot reach a cid server: the SSH call failed and no override is set.\n" ++
    "Check that 'ssh <user@host from the address>' works, or export\n" ++
    "CID_SERVER and CID_TOKEN, then run the command again.";

pub fn remoteFor(
    ctx: *const Context,
    dataset_name: []const u8,
    level: remote_mod.TokenLevel,
    address: ?[]const u8,
) !*const remote_mod.Remote {
    var server: []const u8 = undefined;
    var tok: []const u8 = undefined;
    var renew: ?*SshRenew = null;
    const https = if (address) |a| workspace.httpsOf(a) else null;
    if (ctx.env.get("CID_SERVER")) |s| {
        server = s;
        tok = ctx.env.get("CID_TOKEN") orelse return error.NoServer;
    } else if (https) |h| {
        // An https address is a server and, maybe, a token, as git takes
        // one; a folder keeps its address without the token, so there it
        // comes from CID_TOKEN.
        server = try h.server(ctx.arena);
        tok = h.token orelse ctx.env.get("CID_TOKEN") orelse return error.NeedToken;
    } else {
        const addr = address orelse return error.NoServer;
        const grant = try sshToken(ctx, addr, dataset_name, level);
        server = grant.url;
        tok = grant.token;
        renew = try ctx.arena.create(SshRenew);
        renew.?.* = .{ .ctx = ctx, .address = addr, .dataset = dataset_name, .level = level };
    }
    const transport = try ctx.arena.create(remote_mod.HttpTransport);
    transport.* = remote_mod.HttpTransport.init(ctx.arena, ctx.io, server, tok);
    if (renew) |r| transport.renew = .{ .ctx = r, .token = SshRenew.token };
    const r = try ctx.arena.create(remote_mod.Remote);
    r.* = .{ .t = transport.transport(), .name = dataset_name, .gpa = ctx.gpa, .progress = stderrProgress(ctx) };
    return r;
}

const Grant = struct { token: []const u8, url: []const u8 };

/// A token from the SSH front door, asked for again when it expires.
const SshRenew = struct {
    ctx: *const Context,
    address: []const u8,
    dataset: []const u8,
    level: remote_mod.TokenLevel,

    fn token(raw: *anyopaque) ?[]const u8 {
        const self: *SshRenew = @ptrCast(@alignCast(raw));
        const grant = sshToken(self.ctx, self.address, self.dataset, self.level) catch return null;
        return grant.token;
    }
};

/// `ssh cid@host cid-auth <dataset> <read|write>` — the system ssh, exactly
/// as git uses it, so ~/.ssh/config, agents and hardware keys all work.
fn sshToken(
    ctx: *const Context,
    address: []const u8,
    dataset_name: []const u8,
    level: remote_mod.TokenLevel,
) error{ NoServer, ServerUnreachable, AccessDenied, KeyUnknown }!Grant {
    const colon = std.mem.indexOfScalar(u8, address, ':') orelse return error.NoServer;
    const ssh_target = address[0..colon];
    const problem = ctx.ssh_problem;
    if (problem) |p| p.* = .{ .target = ssh_target };
    const result = std.process.run(ctx.arena, ctx.io, .{
        .argv = &.{ "ssh", ssh_target, "cid-auth", dataset_name, @tagName(level) },
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .{ .nanoseconds = 30 * std.time.ns_per_s } } },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| {
        if (problem) |p| p.reason = switch (err) {
            error.FileNotFound => "the ssh program is not installed (OpenSSH's client)",
            error.Timeout => "no answer within 30 seconds",
            else => "ssh could not run",
        };
        return error.ServerUnreachable;
    };
    if (result.term != .exited or result.term.exited != 0) {
        if (problem) |p| p.reason = tellingLine(result.stderr);
        // The forced command exits 5 when it refuses this key the dataset
        // or the level; sshd's own "Permission denied" is a key it does
        // not know. Both are access, not a missing server.
        if (result.term == .exited and result.term.exited == @backingInt(ExitCode.access)) return error.AccessDenied;
        // sshd's own refusal: the server knows no account with this key.
        if (std.mem.indexOf(u8, result.stderr, "Permission denied") != null) return error.KeyUnknown;
        return error.ServerUnreachable;
    }
    const Parsed = struct { token: []const u8, url: []const u8, expires_in_secs: u64 = 0 };
    const parsed = std.json.parseFromSliceLeaky(Parsed, ctx.arena, result.stdout, .{ .ignore_unknown_fields = true }) catch
        return error.ServerUnreachable;
    return .{ .token = parsed.token, .url = parsed.url };
}

/// 'user:<name>' from the environment; CID_AUTHOR overrides verbatim.
pub fn author(ctx: *const Context) ![]const u8 {
    if (ctx.env.get("CID_AUTHOR")) |a| return a;
    if (ctx.env.get("USER")) |u| return std.fmt.allocPrint(ctx.arena, "user:{s}", .{u});
    return "user:unknown";
}
