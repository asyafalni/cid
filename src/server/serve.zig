//! HTTP front of the API, on Nilo (pinned commit; CLAUDE.md, Zig
//! conventions): two catch-all routes per method keep api.handle the one
//! dispatcher, so the framework owns connections and parsing while the
//! API surface stays HTTP-free and directly testable. TLS remains the
//! reverse proxy's job (docs/access.md).

const std = @import("std");
const nilo = @import("nilo_http");
const api = @import("api.zig");
const duck = @import("../store/duck.zig");
const fetch = @import("nilo_fetch");
const signin = @import("signin.zig");
const blob = @import("../store/blob.zig");
const assets = @import("web_assets");

pub const Options = struct {
    host: []const u8 = "127.0.0.1",
    port: u16,
    /// Seals dashboard sessions; exactly 32 bytes (nilo's rule).
    session_secret: []const u8,
    /// "Sign in with GitLab", when configured.
    signin: ?signin.Config = null,
};

const max_body = 64 * 1024 * 1024;

pub fn serve(gpa: std.mem.Allocator, deps: *api.Deps, options: Options) !void {
    var app = nilo.App.init(gpa);
    defer app.deinit();
    // Versions are prepared ahead of their first visitor, in the background.
    try app.spawn(prepareVersions, .{deps});

    // Served by nilo now: long DuckDB calls go to its blocking pool.
    deps.offload = true;
    deps.gpa = gpa;

    // The server's one DuckDB database for browse queries: each takes
    // a connection, under one memory ceiling and two threads.
    var duck_arena = std.heap.ArenaAllocator.init(gpa);
    defer duck_arena.deinit();
    var shared: duck.Db = undefined;
    {
        const io = deps.io;
        const cwd = std.Io.Dir.cwd();
        const da = duck_arena.allocator();
        cwd.createDirPath(io, deps.browse_dir) catch return error.BrowseDirUnusable;
        cwd.createDirPath(io, deps.work_dir) catch return error.WorkDirUnusable;
        deps.browse_dir = cwd.realPathFileAlloc(io, deps.browse_dir, da) catch return error.BrowseDirUnusable;
        deps.work_dir = cwd.realPathFileAlloc(io, deps.work_dir, da) catch return error.WorkDirUnusable;
        shared = try duck.Db.open(da, .{ .allowed_dir = deps.browse_dir, .threads = 2 });
        deps.duck = &shared;
    }
    defer {
        deps.duck = null;
        shared.close();
    }

    // The Db, the S3 Store and its Bucket are nilo Services: provided
    // here, started by listen() on the server's own loop, shared by
    // every worker thread.
    try app.provide(deps.db);
    try app.provide(&deps.s3.store);
    try app.provide(&deps.s3.items);
    try app.provide(deps);
    // One outbound client for the whole server (nilo_fetch): GitLab's
    // OAuth calls ride it, under a deadline, never blocking a thread.
    var client: fetch.Client = .init(gpa, .{});
    defer client.deinit();
    try app.provide(&client);
    if (options.signin) |*cfg| {
        try app.provide(cfg);
        try app.get("/auth/gitlab", signin.start);
        try app.get("/auth/gitlab/callback", signin.callback);
    }
    try app.post("/auth/signout", signin.signout);
    // Refuse to start without the 'cid' bucket, with the fix named,
    // instead of every upload failing later.
    try app.before(checkBucket, .{deps.s3});
    try app.get("/v0/ping", dispatch);
    try app.get("/v0/*", dispatch);
    try app.post("/v0/datasets", dispatch);
    try app.post("/v0/*", dispatch);
    try app.put("/v0/*", dispatch);
    try app.delete("/v0/*", dispatch);
    // The dashboard, embedded at build time: /v0/* wins over these by
    // specificity, and every non-API path falls back to the app shell so
    // deep links (/d/org/datasets/x) open where they point.
    try app.get("/", serveIndex);
    try app.get("/*", serveAsset);

    std.log.info("cid server listening on {s}:{d}", .{ options.host, options.port });
    try app.listen(.{
        .session_secret = options.session_secret,
        .address = options.host,
        .port = options.port,
        .max_body = max_body,
    });
    std.log.info("requests and background work finished; closing", .{});
}

fn checkBucket(run: *nilo.Run, blobs: *blob.Client) !void {
    if (!blobs.bucketReady(run)) {
        std.log.err(
            "the 'cid' bucket does not exist on the S3 store. Create it (docker-compose.test.yml shows how), then run 'cid admin serve' again.",
            .{},
        );
        return error.NoBucket;
    }
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
fn dispatch(deps: *api.Deps, s: signin.Session, c: *nilo.Ctx) !void {
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
    // A session names its account; the access table decides the rest.
    const account: ?[]const u8 = if (s.get()) |signed|
        (if (signed.gitlab_user != 0) try signin.accountOf(signed.gitlab_user, arena) else null)
    else
        null;
    const response = api.handleAs(arena, deps, c, @tagName(c.method), target, .{ .header = auth, .account = account }, body);
    try c.send(@intFromEnum(response.status), "application/json", response.body);
}

/// The background worker: every couple of seconds, prepares whatever
/// versions are queued (api.prepareNext), one at a time.
fn prepareVersions(deps: *api.Deps) void {
    // Said on the way out: a stop that never finishes is then plainly
    // waiting on a version being prepared, if this line is missing.
    defer std.log.info("version worker stopped", .{});
    while (true) {
        nilo.sleep(2_000) catch return; // the server is going
        if (!serving()) return;
        while (serving()) {
            var run = nilo.Run.initIo(deps.gpa, deps.io);
            defer run.deinit();
            const more = api.prepareNext(run.arena(), deps, &run) catch |err| {
                std.log.warn("preparing a version: {t}", .{err});
                break;
            };
            if (!more) break;
        }
    }
}

const serving = api.serving;
