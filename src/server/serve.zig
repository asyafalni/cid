//! HTTP front of the API, on Nilo (pinned commit; CLAUDE.md, Zig
//! conventions): two catch-all routes per method keep api.handle the one
//! dispatcher, so the framework owns connections and parsing while the
//! API surface stays HTTP-free and directly testable. TLS remains the
//! reverse proxy's job (docs/access.md).

const std = @import("std");
const nilo = @import("nilo_http");
const api = @import("api.zig");

pub const Options = struct {
    host: []const u8 = "127.0.0.1",
    port: u16,
};

const max_body = 64 * 1024 * 1024;

pub fn serve(gpa: std.mem.Allocator, deps: *api.Deps, options: Options) !void {
    var app = nilo.App.init(gpa);
    defer app.deinit();

    try app.provide(deps);
    try app.get("/v0/ping", dispatch);
    try app.get("/v0/*", dispatch);
    try app.post("/v0/datasets", dispatch);
    try app.post("/v0/*", dispatch);

    std.log.info("cid server listening on {s}:{d}", .{ options.host, options.port });
    try app.listen(.{
        .address = options.host,
        .port = options.port,
        .max_body = max_body,
    });
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

    const response = api.handle(arena, deps, @tagName(c.method), target, auth, body);
    try c.send(@intFromEnum(response.status), "application/json", response.body);
}
