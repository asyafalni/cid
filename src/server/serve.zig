//! HTTP front of the API, on Nilo (pinned commit; CLAUDE.md, Zig
//! conventions): two catch-all routes per method keep api.handle the one
//! dispatcher, so the framework owns connections and parsing while the
//! API surface stays HTTP-free and directly testable. TLS remains the
//! reverse proxy's job (docs/access.md).

const std = @import("std");
const nilo = @import("nilo_http");
const api = @import("api.zig");
const assets = @import("web_assets");

pub const Options = struct {
    host: []const u8 = "127.0.0.1",
    port: u16,
};

const max_body = 64 * 1024 * 1024;

pub fn serve(gpa: std.mem.Allocator, deps: *api.Deps, options: Options) !void {
    var app = nilo.App.init(gpa);
    defer app.deinit();

    // The Db is a nilo Service: provided here, its pool is opened by
    // listen() on the server's own loop, shared by every worker thread.
    try app.provide(deps.db);
    try app.provide(deps);
    try app.get("/v0/ping", dispatch);
    try app.get("/v0/*", dispatch);
    try app.post("/v0/datasets", dispatch);
    try app.post("/v0/*", dispatch);
    // The dashboard, embedded at build time: /v0/* wins over these by
    // specificity, and every non-API path falls back to the app shell so
    // deep links (/d/org/datasets/x) open where they point.
    try app.get("/", serveIndex);
    try app.get("/*", serveAsset);

    std.log.info("cid server listening on {s}:{d}", .{ options.host, options.port });
    try app.listen(.{
        .address = options.host,
        .port = options.port,
        .max_body = max_body,
    });
}

fn serveIndex(c: *nilo.Ctx) !void {
    try sendAsset(c, "index.html");
}

fn serveAsset(c: *nilo.Ctx) !void {
    const path = c.path().view();
    const rel = if (path.len > 0 and path[0] == '/') path[1..] else path;
    inline for (assets.files) |f| {
        if (std.mem.eql(u8, f.path, rel)) {
            // Hashed asset names never change content: cache hard.
            if (std.mem.startsWith(u8, rel, "assets/") or std.mem.startsWith(u8, rel, "fonts/"))
                c.setStaticHeader("Cache-Control", "public, max-age=31536000, immutable") catch {};
            try c.send(200, f.mime, f.bytes);
            return;
        }
    }
    // Not a file: it is a route of the app shell.
    try sendAsset(c, "index.html");
}

fn sendAsset(c: *nilo.Ctx, name: []const u8) !void {
    inline for (assets.files) |f| {
        if (std.mem.eql(u8, f.path, name)) {
            try c.send(200, f.mime, f.bytes);
            return;
        }
    }
    try c.send(200, "text/plain; charset=utf-8", "The dashboard is not built into this binary. Run 'pnpm --dir web build', then 'zig build', and serve again.\n");
}

/// One door for every /v0 route: rebuild the target exactly as
/// api.handle has always read it (path plus query), hand over the raw
/// body and the authorization header, send back status and JSON.
fn dispatch(deps: *api.Deps, c: *nilo.Ctx) !void {
    const arena = c.arena();
    const qs = c.queryString();
    const target = if (qs.len() == 0)
        c.path().view()
    else
        try std.fmt.allocPrint(arena, "{s}?{s}", .{ c.path().view(), qs.view() });

    const auth: ?[]const u8 = if (c.header("authorization")) |h| h.view() else null;
    const body: []const u8 = if (c.method == .POST) (try c.body()).view() else "";

    // The Ctx is the Scope every query runs under; the pool underneath
    // makes requests genuinely concurrent (the old single-connection
    // mutex is gone).
    const response = api.handle(arena, deps, c, @tagName(c.method), target, auth, body);
    try c.send(@intFromEnum(response.status), "application/json", response.body);
}
