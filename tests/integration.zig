//! Integration tests: run against the real services from
//! docker-compose.test.yml (`docker compose -f docker-compose.test.yml up -d`).

const std = @import("std");
const cid = @import("cid");

const conninfo: [:0]const u8 =
    "host=127.0.0.1 port=5433 user=cid password=cid-test dbname=cid_test";
const seaweed_s3_port = 8333;

// Fixed ids so the test can clean up after itself on every run.
const ds = "018e0000-0000-7000-8000-00000000d001";
const rev1 = "018e0000-0000-7000-8000-00000000a001";
const item1 = "018e0000-0000-7000-8000-00000000b001";
const commit1 = "018e0000-0000-7000-8000-00000000c001";

fn connect(diag: *cid.pg.Diag) !cid.pg.Db {
    return cid.pg.Db.connect(conninfo, diag) catch |err| {
        std.debug.print(
            "cid integration: TimescaleDB is not reachable ({s}). " ++
                "Run 'docker compose -f docker-compose.test.yml up -d' first.\n",
            .{diag.message()},
        );
        return err;
    };
}

fn expectRefused(db: *cid.pg.Db, sql: [:0]const u8, needle: []const u8) !void {
    var diag: cid.pg.Diag = .{};
    try std.testing.expectError(error.QueryFailed, db.exec(sql, &diag));
    if (std.mem.indexOf(u8, diag.message(), needle) == null) {
        std.debug.print("expected error about '{s}', got: {s}\n", .{ needle, diag.message() });
        return error.WrongError;
    }
}

test "seaweedfs s3 is reachable" {
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", seaweed_s3_port);
    const io = std.testing.io;
    var stream = addr.connect(io, .{ .mode = .stream }) catch |err| {
        std.debug.print(
            "cid integration: SeaweedFS S3 is not reachable on 127.0.0.1:{d} ({t}). " ++
                "Run 'docker compose -f docker-compose.test.yml up -d' first.\n",
            .{ seaweed_s3_port, err },
        );
        return error.ServiceUnreachable;
    };
    stream.close(io);
}

test "migrations apply from scratch and are idempotent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var diag: cid.pg.Diag = .{};
    var db = try connect(&diag);
    defer db.close();

    try db.exec("DROP SCHEMA public CASCADE; CREATE SCHEMA public", &diag);

    var discard: std.Io.Writer.Discarding = .init(&.{});
    const first = cid.migrate.run(arena, &db, &discard.writer, &diag) catch |err| {
        std.debug.print("migrate failed: {s}\n", .{diag.message()});
        return err;
    };
    try std.testing.expect(first.total >= 1);
    try std.testing.expectEqual(first.total, first.applied);

    const second = try cid.migrate.run(arena, &db, &discard.writer, &diag);
    try std.testing.expectEqual(@as(u32, 0), second.applied);

    const versions = try db.queryInts(arena, "SELECT count(*) FROM schema_migrations", &diag);
    try std.testing.expectEqual(@as(i64, @intCast(first.total)), versions[0]);
}

test "append-only history and immovable releases, enforced by the database" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var diag: cid.pg.Diag = .{};
    var db = try connect(&diag);
    defer db.close();

    // Make sure the schema exists (idempotent), then remove this test's
    // leftovers through the maintenance escape hatch.
    var discard: std.Io.Writer.Discarding = .init(&.{});
    _ = cid.migrate.run(arena, &db, &discard.writer, &diag) catch |err| {
        std.debug.print("migrate failed: {s}\n", .{diag.message()});
        return err;
    };
    try db.exec("SET cid.maintenance = 'on'", &diag);
    try db.exec("DELETE FROM refs WHERE dataset_id = '" ++ ds ++ "'", &diag);
    try db.exec("DELETE FROM commits WHERE dataset_id = '" ++ ds ++ "'", &diag);
    try db.exec("DELETE FROM item_revisions WHERE dataset_id = '" ++ ds ++ "'", &diag);
    try db.exec("DELETE FROM datasets WHERE dataset_id = '" ++ ds ++ "'", &diag);
    try db.exec("RESET cid.maintenance", &diag);

    try db.exec("INSERT INTO datasets (dataset_id, name, kind, git_url) VALUES ('" ++ ds ++
        "', 'test/datasets/invariants', 'files', 'git@example.invalid:d.git')", &diag);
    try db.exec("INSERT INTO item_revisions (rev_id, ts, dataset_id, path, op, item_id, item_hash, author) " ++
        "VALUES ('" ++ rev1 ++ "', now(), '" ++ ds ++ "', 'a.txt', 'add', '" ++ item1 ++
        "', decode(repeat('ab', 32), 'hex'), 'user:test')", &diag);

    // Invariant 1: revision history is append-only.
    try expectRefused(&db, "UPDATE item_revisions SET author = 'evil' WHERE dataset_id = '" ++ ds ++ "'", "append-only");
    try expectRefused(&db, "DELETE FROM item_revisions WHERE dataset_id = '" ++ ds ++ "'", "append-only");

    // Invariant 5: releases never move; branches may.
    try db.exec("INSERT INTO commits (commit_id, dataset_id, branch, cutoff_rev, message, author, authored_at) " ++
        "VALUES ('" ++ commit1 ++ "', '" ++ ds ++ "', 'main', '" ++ rev1 ++ "', 'first', 'user:test', now())", &diag);
    try db.exec("INSERT INTO refs (dataset_id, name, kind, commit_id) VALUES ('" ++ ds ++
        "', 'v1.0.0', 'release', '" ++ commit1 ++ "')", &diag);
    try expectRefused(&db, "UPDATE refs SET commit_id = '" ++ commit1 ++ "' WHERE dataset_id = '" ++ ds ++
        "' AND name = 'v1.0.0'", "never moves");
    try expectRefused(&db, "DELETE FROM refs WHERE dataset_id = '" ++ ds ++ "' AND name = 'v1.0.0'", "never moves");
    try db.exec("INSERT INTO refs (dataset_id, name, kind, commit_id) VALUES ('" ++ ds ++
        "', 'main', 'branch', '" ++ commit1 ++ "')", &diag);
    try db.exec("UPDATE refs SET commit_id = '" ++ commit1 ++ "' WHERE dataset_id = '" ++ ds ++
        "' AND name = 'main'", &diag);

    // The platform's role can INSERT revisions and nothing else.
    try db.exec("SET ROLE cid_writer", &diag);
    try db.exec("INSERT INTO item_revisions (rev_id, ts, dataset_id, path, op, item_id, item_hash, author) " ++
        "VALUES ('018e0000-0000-7000-8000-00000000a002', now(), '" ++ ds ++ "', 'b.txt', 'add', " ++
        "'018e0000-0000-7000-8000-00000000b002', decode(repeat('cd', 32), 'hex'), 'agent:annotator')", &diag);
    try expectRefused(&db, "UPDATE item_revisions SET author = 'evil' WHERE dataset_id = '" ++ ds ++ "'", "permission denied");
    try expectRefused(&db, "INSERT INTO datasets (dataset_id, name, kind, git_url) VALUES (gen_random_uuid(), 'x/y', 'files', 'g')", "permission denied");
    try db.exec("RESET ROLE", &diag);
}
