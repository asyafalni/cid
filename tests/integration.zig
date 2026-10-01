//! Integration tests: run against the real services from
//! docker-compose.test.yml (`docker compose -f docker-compose.test.yml up -d`).
//!
//! For now this is the service smoke test the later store tests build on:
//! it proves the pinned TimescaleDB and SeaweedFS containers are reachable
//! on the ports the compose file publishes.

const std = @import("std");

const timescale_port = 5433; // host port for timescaledb (5432 in-container)
const seaweed_s3_port = 8333; // SeaweedFS S3 API

fn expectReachable(port: u16, what: []const u8) !void {
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    const io = std.testing.io;
    var stream = addr.connect(io, .{ .mode = .stream }) catch |err| {
        std.debug.print(
            "cid integration: {s} is not reachable on 127.0.0.1:{d} ({t}). " ++
                "Run 'docker compose -f docker-compose.test.yml up -d' first.\n",
            .{ what, port, err },
        );
        return error.ServiceUnreachable;
    };
    stream.close(io);
}

test "timescaledb is reachable" {
    try expectReachable(timescale_port, "TimescaleDB");
}

test "seaweedfs s3 is reachable" {
    try expectReachable(seaweed_s3_port, "SeaweedFS S3");
}
