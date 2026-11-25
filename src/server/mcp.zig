//! The MCP door: cid's datasets read by an AI agent's own client
//! (docs/roadmap.md, E3; docs/access.md, "The MCP door").
//!
//! One more door out of cid, as git and the Hugging Face door are, and
//! read-only like them. It speaks the Model Context Protocol's Streamable
//! HTTP transport at `POST /mcp`: JSON-RPC in, one JSON answer out, no
//! session and no stream, so it is stateless like every other route.
//!
//! It is an adapter and nothing more. Each tool call becomes one of the
//! read routes the dashboard already uses, through `api.handleAs` with the
//! caller's own token: access, the limits on a restricted dataset and the
//! logging of its reads are whatever those routes do, decided in one
//! place. cid calls no model here; a model's client calls cid.

const std = @import("std");
const api = @import("api.zig");

/// The protocol revisions this door answers as. A client asking for one
/// of them gets it back; any other gets the newest.
const protocols = [_][]const u8{ "2025-06-18", "2025-03-26" };

pub const Answer = struct {
    status: std.http.Status,
    /// JSON, arena-owned; empty for a notification's 202.
    body: []const u8,
};

const instructions =
    "cid is version control for datasets. These tools read datasets this token may read; they change nothing. " ++
    "Start with list_datasets. A version is a release name (v1.2.0), a branch (main) or a commit id; " ++
    "leave it out for the latest release. Results are the server's JSON. An error says what to do next. " ++
    "To download or change a dataset, use the cid command: 'cid help --json' describes it.";

/// Every tool, as `tools/list` answers it. Each takes plain strings and
/// numbers; `dataset` is the dataset's path, as list_datasets names it.
const tools_json =
    \\[
    \\{"name":"list_datasets","description":"Every dataset and model this token may read: its path, kind, latest release and size.",
    \\ "inputSchema":{"type":"object","properties":{}},"annotations":{"readOnlyHint":true}},
    \\{"name":"get_dataset","description":"One dataset at a version: its card, counts of items and annotations, splits, classes, file types, releases and the command that clones it.",
    \\ "inputSchema":{"type":"object","properties":{"dataset":{"type":"string","description":"The dataset's path, e.g. your-org/datasets/speech-id"},"version":{"type":"string","description":"A release, branch or commit id. Default: the latest release."}},"required":["dataset"]},"annotations":{"readOnlyHint":true}},
    \\{"name":"list_releases","description":"A dataset's releases, newest first, each with its commit and manifest hash.",
    \\ "inputSchema":{"type":"object","properties":{"dataset":{"type":"string"}},"required":["dataset"]},"annotations":{"readOnlyHint":true}},
    \\{"name":"list_commits","description":"A branch's commits, newest first, with their messages, authors and the releases on them.",
    \\ "inputSchema":{"type":"object","properties":{"dataset":{"type":"string"},"branch":{"type":"string","description":"Default: main"}},"required":["dataset"]},"annotations":{"readOnlyHint":true}},
    \\{"name":"browse_items","description":"A page of a version's items in path order, each with its size, hash, split and annotations, plus how many match and the counts per split, class and file type. Filters combine.",
    \\ "inputSchema":{"type":"object","properties":{"dataset":{"type":"string"},"version":{"type":"string"},"search":{"type":"string","description":"Text the item's path contains"},"split":{"type":"string"},"class":{"type":"string","description":"Items carrying an annotation of this class"},"type":{"type":"string","description":"A file extension, e.g. .jpg"},"changed_since":{"type":"string","description":"A release name: only items added or changed since it"},"limit":{"type":"integer","description":"Items per page, 1 to 200. Default 20."},"cursor":{"type":"string","description":"The 'next' value of the page before"}},"required":["dataset"]},"annotations":{"readOnlyHint":true}},
    \\{"name":"list_folder","description":"One folder of a version: its subfolders and files with their sizes, like ls.",
    \\ "inputSchema":{"type":"object","properties":{"dataset":{"type":"string"},"version":{"type":"string"},"path":{"type":"string","description":"The folder, e.g. audio/2026-03/. Default: the top."}},"required":["dataset"]},"annotations":{"readOnlyHint":true}},
    \\{"name":"compare_versions","description":"What changed between two versions: counts of items and annotations added, changed and removed, per class, and a page of the changes themselves.",
    \\ "inputSchema":{"type":"object","properties":{"dataset":{"type":"string"},"from":{"type":"string","description":"The earlier version"},"to":{"type":"string","description":"The later version"},"path":{"type":"string","description":"Only changes under this folder"},"cursor":{"type":"string"}},"required":["dataset","from","to"]},"annotations":{"readOnlyHint":true}},
    \\{"name":"query_sql","description":"One read-only SQL SELECT (DuckDB) over a version's index: the tables 'items' (path, hash, size, split, type, item_id, annotations, classes, attributes, identities, authors, policies) and 'annotations' (id, item_id, kind, class, geometry, attributes, author, policy_ver). At most 1000 rows come back. Not offered for a restricted dataset.",
    \\ "inputSchema":{"type":"object","properties":{"dataset":{"type":"string"},"version":{"type":"string"},"sql":{"type":"string"}},"required":["dataset","sql"]},"annotations":{"readOnlyHint":true}},
    \\{"name":"get_health","description":"A version's health: cid's own checks (content in two splits, duplicate files, empty files, tables that cannot be read, and others), each passed, warned or failed, in words.",
    \\ "inputSchema":{"type":"object","properties":{"dataset":{"type":"string"},"version":{"type":"string"}},"required":["dataset"]},"annotations":{"readOnlyHint":true}}
    \\]
;

/// One JSON-RPC message in, its answer out. `auth` is the request's
/// Authorization header, passed on to every route as it came.
pub fn handle(
    arena: std.mem.Allocator,
    deps: *api.Deps,
    scope: anytype,
    auth: ?[]const u8,
    body: []const u8,
    version: []const u8,
) api.HandleError!Answer {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch
        return rpcError(arena, .bad_request, null, -32700, "the body is not JSON");
    const msg = switch (parsed) {
        .object => |o| o,
        // Batches left the protocol in 2025-06-18; one message a request.
        else => return rpcError(arena, .bad_request, null, -32600, "send one JSON-RPC message per request, not a batch"),
    };
    const id = msg.get("id");
    const method = switch (msg.get("method") orelse .null) {
        .string => |m| m,
        // A response to something this door never asks: taken, ignored.
        else => return .{ .status = .accepted, .body = "" },
    };
    // A notification wants no answer.
    if (id == null) return .{ .status = .accepted, .body = "" };

    if (eql(method, "initialize")) {
        var protocol: []const u8 = protocols[0];
        if (objectOf(msg.get("params"))) |params| if (stringOf(params.get("protocolVersion"))) |asked| {
            for (protocols) |p| if (eql(p, asked)) {
                protocol = p;
            };
        };
        return result(arena, id, .{
            .protocolVersion = protocol,
            .capabilities = .{ .tools = .{ .listChanged = false } },
            .serverInfo = .{ .name = "cid", .version = version },
            .instructions = instructions,
        });
    }
    // An empty object, written out: an empty tuple would print as a list.
    if (eql(method, "ping")) return rawResult(arena, id, "{}");
    if (eql(method, "tools/list"))
        return rawResult(arena, id, "{\"tools\":" ++ tools_json ++ "}");
    if (eql(method, "tools/call")) {
        const params = objectOf(msg.get("params")) orelse
            return rpcError(arena, .ok, id, -32602, "tools/call needs params");
        const name = stringOf(params.get("name")) orelse
            return rpcError(arena, .ok, id, -32602, "tools/call needs the tool's name");
        const args: std.json.ObjectMap = objectOf(params.get("arguments")) orelse .empty;
        const out = call(arena, deps, scope, auth, name, args) catch |err| switch (err) {
            error.UnknownTool => return rpcError(arena, .ok, id, -32602, try std.fmt.allocPrint(arena, "there is no tool '{s}'; tools/list names them", .{name})),
            error.OutOfMemory => return error.OutOfMemory,
        };
        return result(arena, id, .{
            .content = [_]Content{.{ .text = out.text }},
            .isError = out.failed,
        });
    }
    return rpcError(arena, .ok, id, -32601, try std.fmt.allocPrint(arena, "this door has no method '{s}': it offers tools only", .{method}));
}

const Content = struct { type: []const u8 = "text", text: []const u8 };

/// A tool's answer: the route's JSON as text, or its error (which says
/// what to do next), marked so the model sees it failed.
const Called = struct { text: []const u8, failed: bool };

fn call(
    arena: std.mem.Allocator,
    deps: *api.Deps,
    scope: anytype,
    auth: ?[]const u8,
    name: []const u8,
    args: std.json.ObjectMap,
) error{ UnknownTool, OutOfMemory }!Called {
    if (eql(name, "list_datasets")) return get(arena, deps, scope, auth, "/v0/datasets");

    const known = [_][]const u8{ "get_dataset", "list_releases", "list_commits", "browse_items", "list_folder", "compare_versions", "query_sql", "get_health" };
    for (known) |k| {
        if (eql(k, name)) break;
    } else return error.UnknownTool;

    const dataset = stringOf(args.get("dataset")) orelse return missing(arena, "dataset", "list_datasets names them");
    // A path only: nothing here may steer the route somewhere else.
    if (!api.validDatasetPath(dataset)) return refused(arena, "that is not a dataset's path", "Call list_datasets and pass a path it names.");
    const base = try std.fmt.allocPrint(arena, "/v0/datasets/{s}/-/", .{dataset});

    if (eql(name, "list_releases")) return get(arena, deps, scope, auth, try cat(arena, base, "releases"));
    if (eql(name, "list_commits")) {
        var q: Query = .init(arena, base, "log");
        try q.add("branch", stringOf(args.get("branch")));
        return get(arena, deps, scope, auth, q.target());
    }
    if (eql(name, "compare_versions")) {
        const from = stringOf(args.get("from")) orelse return missing(arena, "from", "list_releases names the versions");
        const to = stringOf(args.get("to")) orelse return missing(arena, "to", "list_releases names the versions");
        const a = switch (try commitOf(arena, deps, scope, auth, base, from)) {
            .commit => |c| c,
            .failed => |f| return f,
        };
        const b = switch (try commitOf(arena, deps, scope, auth, base, to)) {
            .commit => |c| c,
            .failed => |f| return f,
        };
        var q: Query = .init(arena, base, "browse/compare");
        try q.add("a", a);
        try q.add("b", b);
        try q.add("prefix", stringOf(args.get("path")));
        try q.add("after", stringOf(args.get("cursor")));
        return get(arena, deps, scope, auth, q.target());
    }

    // The rest read one version.
    const commit = switch (try commitOf(arena, deps, scope, auth, base, stringOf(args.get("version")))) {
        .commit => |c| c,
        .failed => |f| return f,
    };
    if (eql(name, "get_dataset")) {
        var q: Query = .init(arena, base, "overview");
        try q.add("commit", commit);
        return get(arena, deps, scope, auth, q.target());
    }
    if (eql(name, "get_health")) {
        var q: Query = .init(arena, base, "health");
        try q.add("commit", commit);
        return get(arena, deps, scope, auth, q.target());
    }
    if (eql(name, "list_folder")) {
        var q: Query = .init(arena, base, "browse/dir");
        try q.add("commit", commit);
        try q.add("prefix", stringOf(args.get("path")));
        return get(arena, deps, scope, auth, q.target());
    }
    if (eql(name, "browse_items")) {
        var q: Query = .init(arena, base, "browse");
        try q.add("commit", commit);
        try q.add("q", stringOf(args.get("search")));
        try q.add("split", stringOf(args.get("split")));
        try q.add("class", stringOf(args.get("class")));
        try q.add("type", stringOf(args.get("type")));
        try q.add("since", stringOf(args.get("changed_since")));
        try q.add("after", stringOf(args.get("cursor")));
        // Small pages by default: a page lands in a model's context.
        const limit: i64 = switch (args.get("limit") orelse .null) {
            .integer => |n| std.math.clamp(n, 1, 200),
            else => 20,
        };
        try q.add("limit", try std.fmt.allocPrint(arena, "{d}", .{limit}));
        return get(arena, deps, scope, auth, q.target());
    }
    // query_sql
    const sql = stringOf(args.get("sql")) orelse return missing(arena, "sql", "one SELECT over items and annotations");
    const body = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{ .commit = commit, .sql = sql }, .{})});
    return answer(api.handleAs(arena, deps, scope, "POST", try cat(arena, base, "sql"), .{ .header = auth }, body));
}

const Commit = union(enum) { commit: []const u8, failed: Called };

/// A version's name as its commit, asked of the server as the caller.
fn commitOf(arena: std.mem.Allocator, deps: *api.Deps, scope: anytype, auth: ?[]const u8, base: []const u8, rev: ?[]const u8) error{OutOfMemory}!Commit {
    var q: Query = .init(arena, base, "resolve");
    try q.add("rev", rev);
    const res = api.handleAs(arena, deps, scope, "GET", q.target(), .{ .header = auth }, "");
    if (res.status != .ok) return .{ .failed = answer(res) };
    const found = std.json.parseFromSliceLeaky(struct { commit: []const u8 }, arena, res.body, .{ .ignore_unknown_fields = true }) catch
        return .{ .failed = try refused(arena, "the server's answer could not be read", "Call the tool again.") };
    return .{ .commit = found.commit };
}

fn get(arena: std.mem.Allocator, deps: *api.Deps, scope: anytype, auth: ?[]const u8, target: []const u8) Called {
    return answer(api.handleAs(arena, deps, scope, "GET", target, .{ .header = auth }, ""));
}

fn answer(res: api.Response) Called {
    return .{ .text = res.body, .failed = @backingInt(res.status) >= 400 };
}

fn missing(arena: std.mem.Allocator, comptime arg: []const u8, comptime hint: []const u8) error{OutOfMemory}!Called {
    return refused(arena, "this tool needs '" ++ arg ++ "'", "Pass it (" ++ hint ++ "), then call the tool again.");
}

fn refused(arena: std.mem.Allocator, what: []const u8, next: []const u8) error{OutOfMemory}!Called {
    return .{ .text = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{ .@"error" = what, .next = next }, .{})}), .failed = true };
}

/// A route's target, its query values percent-encoded.
const Query = struct {
    arena: std.mem.Allocator,
    text: std.ArrayList(u8) = .empty,
    any: bool = false,

    fn init(arena: std.mem.Allocator, base: []const u8, action: []const u8) Query {
        var q: Query = .{ .arena = arena };
        q.text.appendSlice(arena, base) catch {};
        q.text.appendSlice(arena, action) catch {};
        return q;
    }

    fn add(self: *Query, key: []const u8, value: ?[]const u8) error{OutOfMemory}!void {
        const v = value orelse return;
        try self.text.append(self.arena, if (self.any) '&' else '?');
        self.any = true;
        try self.text.appendSlice(self.arena, key);
        try self.text.append(self.arena, '=');
        for (v) |ch| {
            if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
                try self.text.append(self.arena, ch);
            } else {
                try self.text.print(self.arena, "%{X:0>2}", .{ch});
            }
        }
    }

    fn target(self: *const Query) []const u8 {
        return self.text.items;
    }
};

fn result(arena: std.mem.Allocator, id: ?std.json.Value, value: anytype) error{OutOfMemory}!Answer {
    return rawResult(arena, id, try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(value, .{})}));
}

fn rawResult(arena: std.mem.Allocator, id: ?std.json.Value, json_text: []const u8) error{OutOfMemory}!Answer {
    return .{ .status = .ok, .body = try std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{f},\"result\":{s}}}", .{
        std.json.fmt(id orelse std.json.Value.null, .{}), json_text,
    }) };
}

fn rpcError(arena: std.mem.Allocator, status: std.http.Status, id: ?std.json.Value, code: i32, message: []const u8) error{OutOfMemory}!Answer {
    return .{ .status = status, .body = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{
        .jsonrpc = "2.0",
        .id = id orelse std.json.Value.null,
        .@"error" = .{ .code = code, .message = message },
    }, .{})}) };
}

fn objectOf(v: ?std.json.Value) ?std.json.ObjectMap {
    return switch (v orelse return null) {
        .object => |o| o,
        else => null,
    };
}

fn stringOf(v: ?std.json.Value) ?[]const u8 {
    return switch (v orelse return null) {
        .string => |s| if (s.len == 0) null else s,
        else => null,
    };
}

fn cat(arena: std.mem.Allocator, a: []const u8, b: []const u8) error{OutOfMemory}![]const u8 {
    return std.mem.concat(arena, u8, &.{ a, b });
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test "the tool list is JSON, every tool read-only and named once" {
    const Tool = struct {
        name: []const u8,
        description: []const u8,
        inputSchema: struct { type: []const u8 },
        annotations: struct { readOnlyHint: bool },
    };
    const parsed = try std.json.parseFromSlice([]const Tool, std.testing.allocator, tools_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 9), parsed.value.len);
    for (parsed.value, 0..) |t, i| {
        try std.testing.expect(t.annotations.readOnlyHint);
        try std.testing.expectEqualStrings("object", t.inputSchema.type);
        try std.testing.expect(t.description.len > 20);
        for (parsed.value[0..i]) |earlier| try std.testing.expect(!eql(earlier.name, t.name));
    }
}

test "a query's values are percent-encoded" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var q: Query = .init(arena_state.allocator(), "/v0/datasets/o/d/-/", "browse");
    try q.add("q", "a b&c=d/é");
    try q.add("split", null);
    try q.add("limit", "20");
    try std.testing.expectEqualStrings("/v0/datasets/o/d/-/browse?q=a%20b%26c%3Dd%2F%C3%A9&limit=20", q.target());
}
