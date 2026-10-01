//! HTTP front of the v0 API: std.http.Server on a TCP listener, one
//! connection at a time. Enough for the first milestone's round trip;
//! Nilo takes this seat when the route surface grows (CLAUDE.md).
//! TLS is the reverse proxy's job (docs/access.md).

const std = @import("std");
const api = @import("api.zig");

const max_body = 64 * 1024 * 1024;

pub const Options = struct {
    host: []const u8 = "127.0.0.1",
    port: u16,
};

/// Blocks forever, serving requests. Errors on individual connections are
/// logged and survived (one bad request never stops the server).
pub fn serve(gpa: std.mem.Allocator, deps: *api.Deps, options: Options) !void {
    const addr = try std.Io.net.IpAddress.parse(options.host, options.port);
    var listener = try addr.listen(deps.io, .{ .reuse_address = true });
    defer listener.deinit(deps.io);
    std.log.info("cid server listening on {s}:{d}", .{ options.host, options.port });

    while (true) {
        const stream = listener.accept(deps.io) catch |err| {
            std.log.warn("accept failed: {t}", .{err});
            continue;
        };
        handleConnection(gpa, deps, stream) catch |err| {
            std.log.warn("connection failed: {t}", .{err});
        };
    }
}

fn handleConnection(gpa: std.mem.Allocator, deps: *api.Deps, stream: std.Io.net.Stream) !void {
    defer stream.close(deps.io);
    var read_buf: [64 * 1024]u8 = undefined;
    var write_buf: [64 * 1024]u8 = undefined;
    var conn_reader = stream.reader(deps.io, &read_buf);
    var conn_writer = stream.writer(deps.io, &write_buf);
    var server = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);

    while (true) {
        var request = server.receiveHead() catch return; // closed or malformed: drop
        try handleRequest(gpa, deps, &request);
        if (!request.head.keep_alive) return;
    }
}

fn handleRequest(gpa: std.mem.Allocator, deps: *api.Deps, request: *std.http.Server.Request) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const method = @tagName(request.head.method);
    const target = try arena.dupe(u8, request.head.target);

    var auth: ?[]const u8 = null;
    var it = request.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "authorization"))
            auth = try arena.dupe(u8, h.value);
    }

    // Read the body (invalidates head strings, hence the copies above).
    var body_buf: [16 * 1024]u8 = undefined;
    const body_reader = try request.readerExpectContinue(&body_buf);
    var aw: std.Io.Writer.Allocating = .init(arena);
    _ = body_reader.streamRemaining(&aw.writer) catch return error.BadBody;
    const body = aw.writer.buffered();
    if (body.len > max_body) return error.BadBody;

    const response = api.handle(arena, deps, method, target, auth, body);
    try request.respond(response.body, .{
        .status = response.status,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}
