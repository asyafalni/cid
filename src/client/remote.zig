//! The client's view of a cid server: a typed API over a pluggable
//! transport. The real CLI speaks HTTP; integration tests plug the server's
//! handlers in directly, so sync logic is tested without sockets.
//! File bytes never ride the API: uploads and downloads go straight to
//! storage through presigned URLs (free functions at the bottom).

const std = @import("std");
const local = @import("local.zig");
const index_mod = @import("index.zig");

pub const TokenLevel = enum { read, write };

pub const Response = struct {
    status: std.http.Status,
    body: []const u8,
};

pub const Transport = struct {
    ctx: *anyopaque,
    call_fn: *const fn (
        ctx: *anyopaque,
        arena: std.mem.Allocator,
        method: []const u8,
        target: []const u8,
        body: []const u8,
    ) anyerror!Response,

    pub fn call(
        self: Transport,
        arena: std.mem.Allocator,
        method: []const u8,
        target: []const u8,
        body: []const u8,
    ) anyerror!Response {
        return self.call_fn(self.ctx, arena, method, target, body);
    }
};

/// HTTP transport: bearer token, one connection per request.
pub const HttpTransport = struct {
    http: std.http.Client,
    base_url: []const u8, // no trailing '/'
    token: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, base_url: []const u8, token: []const u8) HttpTransport {
        var base = base_url;
        while (base.len > 0 and base[base.len - 1] == '/') base = base[0 .. base.len - 1];
        return .{ .http = .{ .allocator = allocator, .io = io }, .base_url = base, .token = token };
    }

    pub fn deinit(self: *HttpTransport) void {
        self.http.deinit();
    }

    pub fn transport(self: *HttpTransport) Transport {
        return .{ .ctx = self, .call_fn = call };
    }

    fn call(
        ctx: *anyopaque,
        arena: std.mem.Allocator,
        method: []const u8,
        target: []const u8,
        body: []const u8,
    ) anyerror!Response {
        const self: *HttpTransport = @ptrCast(@alignCast(ctx));
        const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ self.base_url, target });
        const auth = try std.fmt.allocPrint(arena, "Bearer {s}", .{self.token});
        var aw: std.Io.Writer.Allocating = .init(arena);
        const result = try self.http.fetch(.{
            .location = .{ .url = url },
            .method = std.meta.stringToEnum(std.http.Method, method).?,
            .payload = if (body.len > 0) body else null,
            .raw_uri = true,
            .keep_alive = false,
            .response_writer = &aw.writer,
            .extra_headers = &.{.{ .name = "authorization", .value = auth }},
        });
        return .{ .status = result.status, .body = aw.writer.buffered() };
    }
};

pub const Error = error{
    ServerUnreachable,
    ServerRefused, // unexpected status; message in logs
    NoSuchDataset,
    Stale, // someone pushed since you pulled
    MissingContent, // a file was not in storage; re-run push
    ReleaseExists,
    BranchExists,
    NoSuchBranch,
    BadReleaseName,
    NothingToTag,
    OutOfMemory,
};

pub const Remote = struct {
    t: Transport,
    /// Dataset path, e.g. "org/datasets/calls".
    name: []const u8,

    fn target(self: *const Remote, arena: std.mem.Allocator, comptime action_fmt: []const u8, args: anytype) ![]u8 {
        return std.fmt.allocPrint(arena, "/v0/datasets/{s}/-/" ++ action_fmt, .{self.name} ++ args);
    }

    pub fn createDataset(self: *const Remote, arena: std.mem.Allocator, git_url: []const u8) Error!void {
        const body = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{
            .name = self.name,
            .kind = "files",
            .git_url = git_url,
        }, .{})});
        const res = self.t.call(arena, "POST", "/v0/datasets", body) catch return error.ServerUnreachable;
        if (res.status != .created and res.status != .conflict) return error.ServerRefused;
    }

    pub const Info = struct { name: []const u8, kind: []const u8, git_url: []const u8, default_format: []const u8 };

    pub fn info(self: *const Remote, arena: std.mem.Allocator) Error!Info {
        const res = self.t.call(arena, "GET", try self.target(arena, "info", .{}), "") catch
            return error.ServerUnreachable;
        if (res.status == .not_found) return error.NoSuchDataset;
        if (res.status != .ok) return error.ServerRefused;
        return parse(Info, arena, res.body) orelse error.ServerRefused;
    }

    pub fn head(self: *const Remote, arena: std.mem.Allocator, branch: []const u8) Error!?[]const u8 {
        const res = self.t.call(arena, "GET", try self.target(arena, "head?branch={s}", .{branch}), "") catch
            return error.ServerUnreachable;
        if (res.status == .not_found) return error.NoSuchDataset;
        if (res.status != .ok) return error.ServerRefused;
        const Head = struct { commit: ?[]const u8 };
        const parsed = parse(Head, arena, res.body) orelse return error.ServerRefused;
        return parsed.commit;
    }

    pub const LogEntry = struct {
        id: []const u8,
        parent: ?[]const u8,
        message: []const u8,
        author: []const u8,
        authored_at_ms: u64,
    };

    pub fn log(self: *const Remote, arena: std.mem.Allocator, branch: []const u8) Error![]const LogEntry {
        const res = self.t.call(arena, "GET", try self.target(arena, "log?branch={s}", .{branch}), "") catch
            return error.ServerUnreachable;
        if (res.status == .not_found) return error.NoSuchDataset;
        if (res.status != .ok) return error.ServerRefused;
        const Log = struct { commits: []const LogEntry };
        const parsed = parse(Log, arena, res.body) orelse return error.ServerRefused;
        return parsed.commits;
    }

    pub const Missing = struct { hash: []const u8, url: []const u8 };

    pub fn checkHashes(self: *const Remote, arena: std.mem.Allocator, hashes: []const []const u8) Error![]const Missing {
        const body = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{ .hashes = hashes }, .{})});
        const res = self.t.call(arena, "POST", try self.target(arena, "check-hashes", .{}), body) catch
            return error.ServerUnreachable;
        if (res.status != .ok) return error.ServerRefused;
        const Check = struct { missing: []const Missing };
        const parsed = parse(Check, arena, res.body) orelse return error.ServerRefused;
        return parsed.missing;
    }

    pub fn push(self: *const Remote, arena: std.mem.Allocator, branch: []const u8, commits: []const local.Commit) Error!void {
        // Wire shape: ops as strings, hashes hex, adds only carry hashes.
        const WireChange = struct { op: []const u8, path: []const u8, hash: []const u8 = "", size: u64 = 0 };
        const WireCommit = struct {
            id: []const u8,
            parent: ?[]const u8,
            message: []const u8,
            author: []const u8,
            authored_at_ms: u64,
            changes: []const WireChange,
        };
        const wire = try arena.alloc(WireCommit, commits.len);
        for (commits, 0..) |commit, i| {
            const changes = try arena.alloc(WireChange, commit.changes.len);
            for (commit.changes, 0..) |ch, j| {
                changes[j] = switch (ch.op) {
                    .add => .{ .op = "add", .path = ch.path, .hash = try arena.dupe(u8, &ch.hash_hex), .size = ch.size },
                    .delete => .{ .op = "delete", .path = ch.path },
                };
            }
            wire[i] = .{
                .id = try arena.dupe(u8, &commit.id.toString()),
                .parent = if (commit.parent) |p| try arena.dupe(u8, &p.toString()) else null,
                .message = commit.message,
                .author = commit.author,
                .authored_at_ms = commit.authored_at_ms,
                .changes = changes,
            };
        }
        const body = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{ .branch = branch, .commits = wire }, .{})});
        const res = self.t.call(arena, "POST", try self.target(arena, "push", .{}), body) catch
            return error.ServerUnreachable;
        if (res.status == .conflict) return error.Stale;
        if (res.status == .unprocessable_entity) return error.MissingContent;
        if (res.status != .ok) return error.ServerRefused;
    }

    pub const StateItem = struct { path: []const u8, hash: []const u8, size: u64, split: ?[]const u8 = null, item_id: ?[]const u8 = null, width: ?u32 = null, height: ?u32 = null };

    pub fn state(self: *const Remote, arena: std.mem.Allocator, commit_id: []const u8) Error![]const StateItem {
        const res = self.t.call(arena, "GET", try self.target(arena, "state/{s}", .{commit_id}), "") catch
            return error.ServerUnreachable;
        if (res.status == .not_found) return error.NoSuchDataset;
        if (res.status != .ok) return error.ServerRefused;
        const State = struct { commit: []const u8, items: []const StateItem };
        const parsed = parse(State, arena, res.body) orelse return error.ServerRefused;
        return parsed.items;
    }

    pub const TagResult = struct { release: []const u8, commit: []const u8, manifest_sha256: []const u8, items: u64 };

    pub fn tag(self: *const Remote, arena: std.mem.Allocator, name: []const u8) Error!TagResult {
        const body = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{ .name = name }, .{})});
        const res = self.t.call(arena, "POST", try self.target(arena, "tag", .{}), body) catch
            return error.ServerUnreachable;
        if (res.status == .conflict) return error.ReleaseExists;
        if (res.status == .bad_request) return error.BadReleaseName;
        if (res.status == .unprocessable_entity) return error.NothingToTag;
        if (res.status == .not_found) return error.NoSuchDataset;
        if (res.status != .created) return error.ServerRefused;
        return parse(TagResult, arena, res.body) orelse error.ServerRefused;
    }

    pub const Release = struct { name: []const u8, commit: []const u8, manifest_sha256: []const u8 };

    pub fn releases(self: *const Remote, arena: std.mem.Allocator) Error![]const Release {
        const res = self.t.call(arena, "GET", try self.target(arena, "releases", .{}), "") catch
            return error.ServerUnreachable;
        if (res.status == .not_found) return error.NoSuchDataset;
        if (res.status != .ok) return error.ServerRefused;
        const List = struct { releases: []const Release };
        const parsed = parse(List, arena, res.body) orelse return error.ServerRefused;
        return parsed.releases;
    }

    pub fn branchCreate(self: *const Remote, arena: std.mem.Allocator, name: []const u8) Error![]const u8 {
        const body = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{ .name = name }, .{})});
        const res = self.t.call(arena, "POST", try self.target(arena, "branch", .{}), body) catch
            return error.ServerUnreachable;
        if (res.status == .conflict) return error.BranchExists;
        if (res.status == .bad_request) return error.BadReleaseName;
        if (res.status == .unprocessable_entity) return error.NothingToTag;
        if (res.status == .not_found) return error.NoSuchDataset;
        if (res.status != .created) return error.ServerRefused;
        const Created = struct { branch: []const u8, start: []const u8 };
        const parsed = parse(Created, arena, res.body) orelse return error.ServerRefused;
        return parsed.start;
    }

    pub const Branch = struct { name: []const u8, commit: []const u8 };

    pub fn branches(self: *const Remote, arena: std.mem.Allocator) Error![]const Branch {
        const res = self.t.call(arena, "GET", try self.target(arena, "branches", .{}), "") catch
            return error.ServerUnreachable;
        if (res.status == .not_found) return error.NoSuchDataset;
        if (res.status != .ok) return error.ServerRefused;
        const List = struct { branches: []const Branch };
        const parsed = parse(List, arena, res.body) orelse return error.ServerRefused;
        return parsed.branches;
    }

    pub const MergeResult = union(enum) {
        merged: struct { commit: []const u8, changes: u64 },
        conflicts: []const []const u8,
        nothing_to_merge,
    };

    pub fn merge(self: *const Remote, arena: std.mem.Allocator, name: []const u8, author: []const u8) Error!MergeResult {
        const body = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{ .name = name, .author = author }, .{})});
        const res = self.t.call(arena, "POST", try self.target(arena, "merge", .{}), body) catch
            return error.ServerUnreachable;
        if (res.status == .conflict) {
            const C = struct { conflicts: []const []const u8 };
            const parsed = parse(C, arena, res.body) orelse return error.ServerRefused;
            return .{ .conflicts = parsed.conflicts };
        }
        if (res.status == .unprocessable_entity) return .nothing_to_merge;
        if (res.status == .not_found) return error.NoSuchBranch;
        if (res.status != .ok) return error.ServerRefused;
        const M = struct { merge_commit: []const u8, changes: u64 };
        const parsed = parse(M, arena, res.body) orelse return error.ServerRefused;
        return .{ .merged = .{ .commit = parsed.merge_commit, .changes = parsed.changes } };
    }

    /// The platform-style server commit over directly written revisions.
    pub fn commitServer(self: *const Remote, arena: std.mem.Allocator, branch: []const u8, message: []const u8, author: []const u8) Error![]const u8 {
        const body = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{ .branch = branch, .message = message, .author = author }, .{})});
        const res = self.t.call(arena, "POST", try self.target(arena, "commit", .{}), body) catch
            return error.ServerUnreachable;
        if (res.status == .unprocessable_entity) return error.NothingToTag;
        if (res.status == .not_found) return error.NoSuchDataset;
        if (res.status != .created) return error.ServerRefused;
        const C = struct { commit: []const u8 };
        const parsed = parse(C, arena, res.body) orelse return error.ServerRefused;
        return parsed.commit;
    }

    pub const RegisterItem = struct { hash: []const u8, size: u64, media_type: []const u8 = "application/octet-stream", width: ?u32 = null, height: ?u32 = null };

    pub fn registerItems(self: *const Remote, arena: std.mem.Allocator, items: []const RegisterItem) Error!void {
        const body = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{ .items = items }, .{})});
        const res = self.t.call(arena, "POST", try self.target(arena, "register-items", .{}), body) catch
            return error.ServerUnreachable;
        if (res.status == .unprocessable_entity) return error.MissingContent;
        if (res.status != .ok) return error.ServerRefused;
    }

    pub const Annotation = struct {
        id: []const u8,
        item_id: []const u8,
        kind: ?[]const u8 = null,
        class: ?[]const u8 = null,
        geometry: ?std.json.Value = null,
        attrs: ?std.json.Value = null,
        author: []const u8,
        policy_ver: []const u8,
    };

    pub const AnnotatedState = struct {
        items: []const StateItem,
        annotations: []const Annotation,
    };

    pub fn stateAnnotated(self: *const Remote, arena: std.mem.Allocator, commit_id: []const u8) Error!AnnotatedState {
        const res = self.t.call(arena, "GET", try self.target(arena, "state/{s}", .{commit_id}), "") catch
            return error.ServerUnreachable;
        if (res.status == .not_found) return error.NoSuchDataset;
        if (res.status != .ok) return error.ServerRefused;
        const State = struct {
            commit: []const u8,
            items: []const StateItem,
            annotations: []const Annotation = &.{},
        };
        const parsed = parse(State, arena, res.body) orelse return error.ServerRefused;
        return .{ .items = parsed.items, .annotations = parsed.annotations };
    }

    pub const Download = struct { hash: []const u8, url: []const u8 };

    pub fn downloads(self: *const Remote, arena: std.mem.Allocator, hashes: []const []const u8) Error![]const Download {
        const body = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{ .hashes = hashes }, .{})});
        const res = self.t.call(arena, "POST", try self.target(arena, "downloads", .{}), body) catch
            return error.ServerUnreachable;
        if (res.status != .ok) return error.ServerRefused;
        const Dl = struct { downloads: []const Download };
        const parsed = parse(Dl, arena, res.body) orelse return error.ServerRefused;
        return parsed.downloads;
    }

    pub const RowDiff = struct {
        /// done | unreadable | too_large | not_a_table | needs_server_build | busy
        status: []const u8,
        reason: ?[]const u8 = null,
        diff: ?struct {
            rows_a: u64,
            rows_b: u64,
            columns_a: []const []const u8 = &.{},
            columns_b: []const []const u8 = &.{},
            columns_changed: bool,
            added: u64 = 0,
            removed: u64 = 0,
        } = null,
        withheld: bool = false,
    };

    /// Row-level diff of two contents of a table file, by the server.
    pub fn rowDiff(self: *const Remote, arena: std.mem.Allocator, a: []const u8, path_a: []const u8, b: []const u8, path_b: []const u8) Error!RowDiff {
        const body = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{ .a = a, .b = b, .path_a = path_a, .path_b = path_b }, .{})});
        const res = self.t.call(arena, "POST", try self.target(arena, "rowdiff", .{}), body) catch
            return error.ServerUnreachable;
        if (res.status == .service_unavailable) return .{ .status = "busy" };
        if (res.status == .not_found) return error.NoSuchDataset;
        if (res.status != .ok) return error.ServerRefused;
        return parse(RowDiff, arena, res.body) orelse error.ServerRefused;
    }
};

fn parse(T: type, arena: std.mem.Allocator, body: []const u8) ?T {
    return std.json.parseFromSliceLeaky(T, arena, body, .{ .ignore_unknown_fields = true }) catch null;
}

// ---------------------------------------------------------------------------
// Presigned transfers: bytes move between the local cache and storage,
// streamed with bounded buffers, never through the API.
// ---------------------------------------------------------------------------

pub const TransferError = error{ TransferFailed, OutOfMemory };

/// Streams one cached item to a presigned PUT URL.
pub fn uploadFromCache(
    allocator: std.mem.Allocator,
    io: std.Io,
    cache_dir: std.Io.Dir,
    hash_hex: []const u8,
    size: u64,
    url: []const u8,
) TransferError!void {
    var path_buf: [96]u8 = undefined;
    const cache_path = std.fmt.bufPrint(&path_buf, "items/{s}/{s}", .{ hash_hex[0..2], hash_hex }) catch unreachable;
    var file = cache_dir.openFile(io, cache_path, .{}) catch return error.TransferFailed;
    defer file.close(io);

    var http: std.http.Client = .{ .allocator = allocator, .io = io };
    defer http.deinit();
    const uri = std.Uri.parse(url) catch return error.TransferFailed;
    var req = http.request(.PUT, uri, .{ .keep_alive = false }) catch return error.TransferFailed;
    defer req.deinit();
    req.transfer_encoding = .{ .content_length = size };

    var send_buf: [64 * 1024]u8 = undefined;
    var body = req.sendBody(&send_buf) catch return error.TransferFailed;
    var read_buf: [64 * 1024]u8 = undefined;
    var fr = file.reader(io, &read_buf);
    _ = fr.interface.streamRemaining(&body.writer) catch return error.TransferFailed;
    body.end() catch return error.TransferFailed;

    var redirect_buf: [1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch return error.TransferFailed;
    if (response.head.status != .ok) return error.TransferFailed;
    const reader = response.reader(&.{});
    _ = reader.discardRemaining() catch return error.TransferFailed;
}

/// Downloads a presigned GET URL into the cache, verifying the SHA-256
/// before the item becomes visible (invariant: downloads verify everything).
pub fn downloadToCache(
    allocator: std.mem.Allocator,
    io: std.Io,
    cache_dir: std.Io.Dir,
    expected_hash_hex: []const u8,
    url: []const u8,
) TransferError!void {
    var tmp_random: [8]u8 = undefined;
    io.random(&tmp_random);
    var tmp_buf: [64]u8 = undefined;
    const tmp_name = std.fmt.bufPrint(&tmp_buf, "tmp-dl-{x}", .{&tmp_random}) catch unreachable;
    var ok = false;
    defer if (!ok) cache_dir.deleteFile(io, tmp_name) catch {};

    {
        var tmp_file = cache_dir.createFile(io, tmp_name, .{ .truncate = true }) catch return error.TransferFailed;
        defer tmp_file.close(io);
        var wbuf: [64 * 1024]u8 = undefined;
        var fw = tmp_file.writer(io, &wbuf);
        var http: std.http.Client = .{ .allocator = allocator, .io = io };
        defer http.deinit();
        const res = http.fetch(.{
            .location = .{ .url = url },
            .raw_uri = true,
            .keep_alive = false,
            .response_writer = &fw.interface,
        }) catch return error.TransferFailed;
        fw.interface.flush() catch return error.TransferFailed;
        if (res.status != .ok) return error.TransferFailed;
    }

    // Verify, then move into place by hash. A mismatch never lands.
    const cache_mod = @import("cache.zig");
    const hashed = cache_mod.hashFile(io, cache_dir, tmp_name) catch return error.TransferFailed;
    if (!std.mem.eql(u8, &hashed.hash_hex, expected_hash_hex)) return error.TransferFailed;

    var dir_buf: [16]u8 = undefined;
    const sub = std.fmt.bufPrint(&dir_buf, "items/{s}", .{expected_hash_hex[0..2]}) catch unreachable;
    cache_dir.createDirPath(io, sub) catch return error.TransferFailed;
    var final_buf: [96]u8 = undefined;
    const final_path = std.fmt.bufPrint(&final_buf, "items/{s}/{s}", .{ expected_hash_hex[0..2], expected_hash_hex }) catch unreachable;
    std.Io.Dir.rename(cache_dir, tmp_name, cache_dir, final_path, io) catch return error.TransferFailed;
    ok = true;
}

/// True if the cache already holds this hash.
pub fn inCache(io: std.Io, cache_dir: std.Io.Dir, hash_hex: []const u8) bool {
    var buf: [96]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "items/{s}/{s}", .{ hash_hex[0..2], hash_hex }) catch unreachable;
    cache_dir.access(io, path, .{}) catch return false;
    return true;
}

/// Hard-links a cached item into the working folder, copying when linking
/// is impossible (different filesystem).
pub fn placeFromCache(
    io: std.Io,
    cache_dir: std.Io.Dir,
    hash_hex: []const u8,
    work_dir: std.Io.Dir,
    rel_path: []const u8,
) TransferError!void {
    var buf: [96]u8 = undefined;
    const cache_path = std.fmt.bufPrint(&buf, "items/{s}/{s}", .{ hash_hex[0..2], hash_hex }) catch unreachable;
    if (std.mem.lastIndexOfScalar(u8, rel_path, '/')) |sep| {
        work_dir.createDirPath(io, rel_path[0..sep]) catch return error.TransferFailed;
    }
    work_dir.deleteFile(io, rel_path) catch {};
    std.Io.Dir.hardLink(cache_dir, cache_path, work_dir, rel_path, io, .{}) catch {
        std.Io.Dir.copyFile(cache_dir, cache_path, work_dir, rel_path, io, .{}) catch
            return error.TransferFailed;
    };
}

test {
    _ = Transport;
    _ = index_mod;
}
