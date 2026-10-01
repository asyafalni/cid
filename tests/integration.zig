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

test "s3: put, head, get, presign round trip against SeaweedFS" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var s3 = try cid.s3.Client.init(std.testing.allocator, io, .{
        .endpoint = "http://127.0.0.1:8333",
        .access_key = "cid-test-key",
        .secret_key = "cid-test-secret",
        .bucket = "cid-test",
    });
    defer s3.deinit();

    try s3.createBucket(arena);
    try s3.createBucket(arena); // idempotent

    const key = "items/sha256/ab/abcd-test-object";
    const body = "cid stores any bytes \x00\x01\x02 exactly";

    try std.testing.expectEqual(@as(?u64, null), try s3.headObject(arena, "items/missing"));
    try std.testing.expectError(error.NotFound, s3.getObjectAlloc(arena, "items/missing", 1024));

    try s3.putObject(arena, key, body);
    const got = try s3.getObjectAlloc(arena, key, 1024);
    try std.testing.expectEqualSlices(u8, body, got);

    // Presigned GET works with a plain HTTP client and no credentials.
    const now: u64 = @intCast(@max(0, std.Io.Timestamp.now(io, .real).toSeconds()));
    const url = try s3.presignGet(arena, key, now, 300);
    var plain: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    defer plain.deinit();
    var aw: std.Io.Writer.Allocating = .init(arena);
    const res = try plain.fetch(.{ .location = .{ .url = url }, .raw_uri = true, .keep_alive = false, .response_writer = &aw.writer });
    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualSlices(u8, body, aw.writer.buffered());

    try s3.deleteObject(arena, key);
    try std.testing.expectEqual(@as(?u64, null), try s3.headObject(arena, key));
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

test "api: create, check-hashes, push (forward-only), state, downloads, log" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var diag: cid.pg.Diag = .{};
    var db = try connect(&diag);
    defer db.close();
    var discard: std.Io.Writer.Discarding = .init(&.{});
    _ = try cid.migrate.run(arena, &db, &discard.writer, &diag);

    var s3c = try cid.s3.Client.init(std.testing.allocator, io, .{
        .endpoint = "http://127.0.0.1:8333",
        .access_key = "cid-test-key",
        .secret_key = "cid-test-secret",
        .bucket = "cid-test",
    });
    defer s3c.deinit();
    try s3c.createBucket(arena);

    var deps: cid.api.Deps = .{ .db = &db, .s3 = &s3c, .io = io, .token = "test-token" };
    const name = "test/datasets/api";

    // Leftovers from earlier runs go through the maintenance escape.
    try db.exec("SET cid.maintenance = 'on'", &diag);
    try db.exec("DELETE FROM refs WHERE dataset_id IN (SELECT dataset_id FROM datasets WHERE name = 'test/datasets/api')", &diag);
    try db.exec("DELETE FROM commits WHERE dataset_id IN (SELECT dataset_id FROM datasets WHERE name = 'test/datasets/api')", &diag);
    try db.exec("DELETE FROM item_revisions WHERE dataset_id IN (SELECT dataset_id FROM datasets WHERE name = 'test/datasets/api')", &diag);
    try db.exec("DELETE FROM dataset_items WHERE dataset_id IN (SELECT dataset_id FROM datasets WHERE name = 'test/datasets/api')", &diag);
    try db.exec("DELETE FROM datasets WHERE name = 'test/datasets/api'", &diag);
    try db.exec("RESET cid.maintenance", &diag);

    // Auth is checked before anything else.
    const unauth = cid.api.handle(arena, &deps, "GET", "/v0/datasets/x/-/head", "Bearer wrong", "");
    try std.testing.expectEqual(std.http.Status.unauthorized, unauth.status);

    // Create the dataset.
    const created = cid.api.handle(arena, &deps, "POST", "/v0/datasets", "Bearer test-token", "{\"name\":\"test/datasets/api\",\"git_url\":\"git@example.invalid:d.git\"}");
    try std.testing.expectEqual(std.http.Status.created, created.status);
    const again = cid.api.handle(arena, &deps, "POST", "/v0/datasets", "Bearer test-token", "{\"name\":\"test/datasets/api\",\"git_url\":\"git@example.invalid:d.git\"}");
    try std.testing.expectEqual(std.http.Status.conflict, again.status);

    // Two contents; their hex hashes.
    const content_a = "api test content A";
    const content_b = "api test content B, longer";
    var dg: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content_a, &dg, .{});
    const hash_a = std.fmt.bytesToHex(dg, .lower);
    std.crypto.hash.sha2.Sha256.hash(content_b, &dg, .{});
    const hash_b = std.fmt.bytesToHex(dg, .lower);

    // Earlier runs may have uploaded these; start from a clean slate.
    try s3c.deleteObject(arena, try cid.api.itemKey(arena, &hash_a));
    try s3c.deleteObject(arena, try cid.api.itemKey(arena, &hash_b));

    // check-hashes says both are missing and hands out presigned PUTs.
    const check_body = try std.fmt.allocPrint(arena, "{{\"hashes\":[\"{s}\",\"{s}\"]}}", .{ &hash_a, &hash_b });
    const check1 = cid.api.handle(arena, &deps, "POST", "/v0/datasets/" ++ name ++ "/-/check-hashes", "Bearer test-token", check_body);
    try std.testing.expectEqual(std.http.Status.ok, check1.status);
    const Check = struct { missing: []const struct { hash: []const u8, url: []const u8 } };
    const check1_parsed = try std.json.parseFromSliceLeaky(Check, arena, check1.body, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 2), check1_parsed.missing.len);

    // Upload A through its presigned URL with a plain client — no credentials.
    var plain: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    defer plain.deinit();
    for (check1_parsed.missing) |m| {
        if (std.mem.eql(u8, m.hash, &hash_a)) {
            const put = try plain.fetch(.{ .location = .{ .url = m.url }, .method = .PUT, .payload = content_a, .raw_uri = true, .keep_alive = false });
            try std.testing.expectEqual(std.http.Status.ok, put.status);
        }
    }
    const check2 = cid.api.handle(arena, &deps, "POST", "/v0/datasets/" ++ name ++ "/-/check-hashes", "Bearer test-token", check_body);
    const check2_parsed = try std.json.parseFromSliceLeaky(Check, arena, check2.body, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 1), check2_parsed.missing.len);
    try std.testing.expectEqualStrings(&hash_b, check2_parsed.missing[0].hash);

    // First push: one commit adding a.txt (content A, already uploaded).
    const id1 = cid.uuid7.Uuid.now(io).toString();
    const push1_body = try std.fmt.allocPrint(arena,
        \\{{"branch":"main","commits":[{{"id":"{s}","parent":null,"message":"first","author":"user:test","authored_at_ms":1760000000000,"changes":[{{"op":"add","path":"a.txt","hash":"{s}","size":18}}]}}]}}
    , .{ &id1, &hash_a });
    const push1 = cid.api.handle(arena, &deps, "POST", "/v0/datasets/" ++ name ++ "/-/push", "Bearer test-token", push1_body);
    try std.testing.expectEqual(std.http.Status.ok, push1.status);

    // A second root push is stale: forward-only refuses it with the pull hint.
    const id_stale = cid.uuid7.Uuid.now(io).toString();
    const stale_body = try std.fmt.allocPrint(arena,
        \\{{"branch":"main","commits":[{{"id":"{s}","parent":null,"message":"stale","author":"user:test","authored_at_ms":1760000000000,"changes":[{{"op":"add","path":"a.txt","hash":"{s}","size":18}}]}}]}}
    , .{ &id_stale, &hash_a });
    const stale = cid.api.handle(arena, &deps, "POST", "/v0/datasets/" ++ name ++ "/-/push", "Bearer test-token", stale_body);
    try std.testing.expectEqual(std.http.Status.conflict, stale.status);
    try std.testing.expect(std.mem.indexOf(u8, stale.body, "cid pull") != null);

    // Pushing content that is not in storage is refused before anything lands.
    const id2 = cid.uuid7.Uuid.now(io).toString();
    const push2_body = try std.fmt.allocPrint(arena,
        \\{{"branch":"main","commits":[{{"id":"{s}","parent":"{s}","message":"second","author":"user:test","authored_at_ms":1760000001000,"changes":[{{"op":"add","path":"b.txt","hash":"{s}","size":26}},{{"op":"delete","path":"a.txt"}}]}}]}}
    , .{ &id2, &id1, &hash_b });
    const missing = cid.api.handle(arena, &deps, "POST", "/v0/datasets/" ++ name ++ "/-/push", "Bearer test-token", push2_body);
    try std.testing.expectEqual(std.http.Status.unprocessable_entity, missing.status);

    // Upload B, retry: same body now lands.
    const key_b = try cid.api.itemKey(arena, &hash_b);
    try s3c.putObject(arena, key_b, content_b);
    const push2 = cid.api.handle(arena, &deps, "POST", "/v0/datasets/" ++ name ++ "/-/push", "Bearer test-token", push2_body);
    try std.testing.expectEqual(std.http.Status.ok, push2.status);

    // head and state: only b.txt remains after the delete.
    const head_res = cid.api.handle(arena, &deps, "GET", "/v0/datasets/" ++ name ++ "/-/head?branch=main", "Bearer test-token", "");
    const Head = struct { commit: ?[]const u8 };
    const head_parsed = try std.json.parseFromSliceLeaky(Head, arena, head_res.body, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqualStrings(&id2, head_parsed.commit.?);

    const state_target = try std.fmt.allocPrint(arena, "/v0/datasets/{s}/-/state/{s}", .{ name, &id2 });
    const state_res = cid.api.handle(arena, &deps, "GET", state_target, "Bearer test-token", "");
    try std.testing.expectEqual(std.http.Status.ok, state_res.status);
    const State = struct { commit: []const u8, items: []const struct { path: []const u8, hash: []const u8, size: u64 } };
    const state_parsed = try std.json.parseFromSliceLeaky(State, arena, state_res.body, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 1), state_parsed.items.len);
    try std.testing.expectEqualStrings("b.txt", state_parsed.items[0].path);
    try std.testing.expectEqualStrings(&hash_b, state_parsed.items[0].hash);
    try std.testing.expectEqual(@as(u64, 26), state_parsed.items[0].size);

    // State at the first commit still shows a.txt: history is intact.
    const state1_target = try std.fmt.allocPrint(arena, "/v0/datasets/{s}/-/state/{s}", .{ name, &id1 });
    const state1_parsed = try std.json.parseFromSliceLeaky(State, arena, cid.api.handle(arena, &deps, "GET", state1_target, "Bearer test-token", "").body, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 1), state1_parsed.items.len);
    try std.testing.expectEqualStrings("a.txt", state1_parsed.items[0].path);

    // downloads: a presigned GET for B round-trips the bytes.
    const dl_body = try std.fmt.allocPrint(arena, "{{\"hashes\":[\"{s}\"]}}", .{&hash_b});
    const dl = cid.api.handle(arena, &deps, "POST", "/v0/datasets/" ++ name ++ "/-/downloads", "Bearer test-token", dl_body);
    const Dl = struct { downloads: []const struct { hash: []const u8, url: []const u8 } };
    const dl_parsed = try std.json.parseFromSliceLeaky(Dl, arena, dl.body, .{ .ignore_unknown_fields = true });
    var aw: std.Io.Writer.Allocating = .init(arena);
    const got = try plain.fetch(.{ .location = .{ .url = dl_parsed.downloads[0].url }, .raw_uri = true, .keep_alive = false, .response_writer = &aw.writer });
    try std.testing.expectEqual(std.http.Status.ok, got.status);
    try std.testing.expectEqualSlices(u8, content_b, aw.writer.buffered());

    // log: both commits, newest first.
    const log_res = cid.api.handle(arena, &deps, "GET", "/v0/datasets/" ++ name ++ "/-/log?branch=main", "Bearer test-token", "");
    const Log = struct { commits: []const struct { id: []const u8, parent: ?[]const u8, message: []const u8, author: []const u8, authored_at_ms: u64 } };
    const log_parsed = try std.json.parseFromSliceLeaky(Log, arena, log_res.body, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 2), log_parsed.commits.len);
    try std.testing.expectEqualStrings("second", log_parsed.commits[0].message);
    try std.testing.expectEqualStrings(&id1, log_parsed.commits[0].parent.?);
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

// ---------------------------------------------------------------------------
// The milestone test: the whole file-dataset round trip through sync,
// with the server's handlers plugged in as the transport (no sockets;
// content still rides real presigned URLs against live SeaweedFS).
// ---------------------------------------------------------------------------

const DirectTransport = struct {
    deps: *cid.api.Deps,
    auth: []const u8,

    fn transport(self: *DirectTransport) cid.client.remote.Transport {
        return .{ .ctx = self, .call_fn = call };
    }

    fn call(
        ctx: *anyopaque,
        arena: std.mem.Allocator,
        method: []const u8,
        target: []const u8,
        body: []const u8,
    ) anyerror!cid.client.remote.Response {
        const self: *DirectTransport = @ptrCast(@alignCast(ctx));
        const r = cid.api.handle(arena, self.deps, method, target, self.auth, body);
        return .{ .status = r.status, .body = r.body };
    }
};

fn readWholeFile(io: std.Io, dir: std.Io.Dir, path: []const u8, arena: std.mem.Allocator) ![]u8 {
    return dir.readFileAlloc(io, path, arena, .limited(1024 * 1024));
}

test "sync: the file-dataset round trip (push, clone, pull, checkout, stale)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var diag: cid.pg.Diag = .{};
    var db = try connect(&diag);
    defer db.close();
    var discard: std.Io.Writer.Discarding = .init(&.{});
    _ = try cid.migrate.run(arena, &db, &discard.writer, &diag);

    var s3c = try cid.s3.Client.init(std.testing.allocator, io, .{
        .endpoint = "http://127.0.0.1:8333",
        .access_key = "cid-test-key",
        .secret_key = "cid-test-secret",
        .bucket = "cid-test",
    });
    defer s3c.deinit();
    try s3c.createBucket(arena);

    var deps: cid.api.Deps = .{ .db = &db, .s3 = &s3c, .io = io, .token = "test-token" };
    var direct: DirectTransport = .{ .deps = &deps, .auth = "Bearer test-token" };
    const remote: cid.client.remote.Remote = .{ .t = direct.transport(), .name = "test/datasets/sync" };

    // Earlier runs may have uploaded this test's contents; purge them so
    // upload counts are exact.
    inline for (.{ "version one of a\n", "\x00\x01\x02\xff binary", "version TWO of a\n", "the new file c\n", "my local edit", "d" }) |content| {
        var content_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(content, &content_digest, .{});
        const content_hex = std.fmt.bytesToHex(content_digest, .lower);
        try s3c.deleteObject(arena, try cid.api.itemKey(arena, &content_hex));
    }

    // Clean slate for this dataset.
    try db.exec("SET cid.maintenance = 'on'", &diag);
    inline for (.{ "refs", "commits", "item_revisions", "dataset_items" }) |table| {
        try db.exec("DELETE FROM " ++ table ++ " WHERE dataset_id IN (SELECT dataset_id FROM datasets WHERE name = 'test/datasets/sync')", &diag);
    }
    try db.exec("DELETE FROM datasets WHERE name = 'test/datasets/sync'", &diag);
    try db.exec("RESET cid.maintenance", &diag);

    // Producer folder: two files (one binary), committed offline.
    var producer = std.testing.tmpDir(.{ .iterate = true });
    defer producer.cleanup();
    var producer_cache = std.testing.tmpDir(.{});
    defer producer_cache.cleanup();
    try producer.dir.createDirPath(io, "sub");
    try producer.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "version one of a\n" });
    try producer.dir.writeFile(io, .{ .sub_path = "sub/b.bin", .data = "\x00\x01\x02\xff binary" });

    try cid.client.workspace.init(arena, io, producer.dir, "cid@test:test/datasets/sync", "git@example.invalid:sync.git");
    var pws = try cid.client.workspace.open(arena, io, producer.dir);
    _ = try cid.client.workspace.add(arena, io, &pws, producer_cache.dir, &.{"."});
    const first = try cid.client.workspace.commit(arena, io, &pws, "first", "user:producer");

    // Push: creates the dataset server-side, uploads both files, records the commit.
    const push1 = try cid.client.sync.push(arena, io, &pws, producer_cache.dir, &remote);
    try std.testing.expectEqual(@as(u32, 1), push1.pushed_commits);
    try std.testing.expectEqual(@as(u32, 2), push1.uploaded_files);
    const push_again = try cid.client.sync.push(arena, io, &pws, producer_cache.dir, &remote);
    try std.testing.expectEqual(@as(u32, 0), push_again.pushed_commits);

    // Clone into a fresh folder with its own cache: every byte verified.
    var reader_dir = std.testing.tmpDir(.{ .iterate = true });
    defer reader_dir.cleanup();
    var reader_cache = std.testing.tmpDir(.{});
    defer reader_cache.cleanup();
    const cloned = try cid.client.sync.clone(arena, io, reader_dir.dir, reader_cache.dir, &remote, "cid@test:test/datasets/sync", null, null);
    try std.testing.expectEqual(@as(u32, 2), cloned.files);
    try std.testing.expectEqual(@as(u32, 2), cloned.downloaded);
    try std.testing.expectEqualSlices(u8, "version one of a\n", try readWholeFile(io, reader_dir.dir, "a.txt", arena));
    try std.testing.expectEqualSlices(u8, "\x00\x01\x02\xff binary", try readWholeFile(io, reader_dir.dir, "sub/b.bin", arena));

    var rws = try cid.client.workspace.open(arena, io, reader_dir.dir);
    const rstatus = try cid.client.workspace.status(arena, io, &rws);
    try std.testing.expectEqual(@as(usize, 0), rstatus.staged.len);
    try std.testing.expectEqual(@as(usize, 0), rstatus.unstaged_new.len);
    try std.testing.expectEqual(@as(usize, 0), rstatus.unstaged_modified.len);

    // Producer iterates: edit, delete, add — then pushes.
    try producer.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "version TWO of a\n" });
    try producer.dir.deleteFile(io, "sub/b.bin");
    try producer.dir.writeFile(io, .{ .sub_path = "c.txt", .data = "the new file c\n" });
    _ = try cid.client.workspace.add(arena, io, &pws, producer_cache.dir, &.{"."});
    _ = try cid.client.workspace.commit(arena, io, &pws, "second", "user:producer");
    const push2 = try cid.client.sync.push(arena, io, &pws, producer_cache.dir, &remote);
    try std.testing.expectEqual(@as(u32, 1), push2.pushed_commits);

    // Reader pulls the fast-forward.
    const pulled = try cid.client.sync.pull(arena, io, &rws, reader_cache.dir, &remote);
    try std.testing.expect(pulled == .fast_forwarded);
    try std.testing.expectEqualSlices(u8, "version TWO of a\n", try readWholeFile(io, reader_dir.dir, "a.txt", arena));
    try std.testing.expectEqualSlices(u8, "the new file c\n", try readWholeFile(io, reader_dir.dir, "c.txt", arena));
    try std.testing.expectError(error.FileNotFound, reader_dir.dir.openFile(io, "sub/b.bin", .{}));
    const pulled2 = try cid.client.sync.pull(arena, io, &rws, reader_cache.dir, &remote);
    try std.testing.expect(pulled2 == .already_up_to_date);

    // Checkout the first commit: the old tree returns, byte for byte.
    const changed_back = try cid.client.sync.checkout(arena, io, &rws, reader_cache.dir, &remote, "main", &first.id.toString(), false);
    try std.testing.expect(changed_back >= 2);
    try std.testing.expectEqualSlices(u8, "version one of a\n", try readWholeFile(io, reader_dir.dir, "a.txt", arena));
    try std.testing.expectEqualSlices(u8, "\x00\x01\x02\xff binary", try readWholeFile(io, reader_dir.dir, "sub/b.bin", arena));
    try std.testing.expectError(error.FileNotFound, reader_dir.dir.openFile(io, "c.txt", .{}));
    _ = try cid.client.sync.pull(arena, io, &rws, reader_cache.dir, &remote); // back to latest

    // Local edits are never overwritten silently.
    try reader_dir.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "my local edit" });
    try std.testing.expectError(
        error.LocalChangesInTheWay,
        cid.client.sync.checkout(arena, io, &rws, reader_cache.dir, &remote, "main", &first.id.toString(), false),
    );
    // Put it back to the tracked content for the rest of the test.
    _ = try cid.client.workspace.add(arena, io, &rws, reader_cache.dir, &.{"a.txt"});
    _ = try cid.client.workspace.commit(arena, io, &rws, "reader edit", "user:reader");

    // Reader pushes (it sits at the server head, so this lands)…
    const push3 = try cid.client.sync.push(arena, io, &rws, reader_cache.dir, &remote);
    try std.testing.expectEqual(@as(u32, 1), push3.pushed_commits);

    // …which makes the producer stale: its next push must be refused.
    try producer.dir.writeFile(io, .{ .sub_path = "d.txt", .data = "d" });
    _ = try cid.client.workspace.add(arena, io, &pws, producer_cache.dir, &.{"."});
    _ = try cid.client.workspace.commit(arena, io, &pws, "add d", "user:producer");
    try std.testing.expectError(error.Stale, cid.client.sync.push(arena, io, &pws, producer_cache.dir, &remote));

    // Different files on each side: pull replays automatically.
    const replayed = try cid.client.sync.pull(arena, io, &pws, producer_cache.dir, &remote);
    try std.testing.expect(replayed == .replayed);
    try std.testing.expectEqual(@as(u32, 1), replayed.replayed.commits);
    try std.testing.expectEqualSlices(u8, "my local edit", try readWholeFile(io, producer.dir, "a.txt", arena));
    try std.testing.expectEqualSlices(u8, "d", try readWholeFile(io, producer.dir, "d.txt", arena));
    const after_replay = try cid.client.sync.push(arena, io, &pws, producer_cache.dir, &remote);
    try std.testing.expectEqual(@as(u32, 1), after_replay.pushed_commits);
    // The reader follows; both sit on the same head now.
    _ = try cid.client.sync.pull(arena, io, &rws, reader_cache.dir, &remote);

    // The same file on both sides: pull lists the conflict and merges nothing.
    try reader_dir.dir.writeFile(io, .{ .sub_path = "d.txt", .data = "reader version of d" });
    _ = try cid.client.workspace.add(arena, io, &rws, reader_cache.dir, &.{"."});
    _ = try cid.client.workspace.commit(arena, io, &rws, "reader d", "user:reader");
    _ = try cid.client.sync.push(arena, io, &rws, reader_cache.dir, &remote);
    try producer.dir.writeFile(io, .{ .sub_path = "d.txt", .data = "producer version of d" });
    try producer.dir.writeFile(io, .{ .sub_path = "e.txt", .data = "e is peaceful" });
    _ = try cid.client.workspace.add(arena, io, &pws, producer_cache.dir, &.{"."});
    _ = try cid.client.workspace.commit(arena, io, &pws, "producer d and e", "user:producer");

    const conflicted = try cid.client.sync.pull(arena, io, &pws, producer_cache.dir, &remote);
    try std.testing.expect(conflicted == .conflicts);
    try std.testing.expectEqual(@as(usize, 1), conflicted.conflicts.len);
    try std.testing.expectEqualStrings("d.txt", conflicted.conflicts[0].path);
    // Nothing merged: the working file still holds the producer's version.
    try std.testing.expectEqualSlices(u8, "producer version of d", try readWholeFile(io, producer.dir, "d.txt", arena));

    // Take theirs: the local change to d.txt is dropped, e.txt survives.
    const decided = try cid.client.sync.decide(arena, io, &pws, "d.txt", .theirs);
    try std.testing.expectEqual(@as(usize, 0), decided.remaining);
    const resolved = try cid.client.sync.pull(arena, io, &pws, producer_cache.dir, &remote);
    try std.testing.expect(resolved == .replayed);
    try std.testing.expectEqualSlices(u8, "reader version of d", try readWholeFile(io, producer.dir, "d.txt", arena));
    try std.testing.expectEqualSlices(u8, "e is peaceful", try readWholeFile(io, producer.dir, "e.txt", arena));
    _ = try cid.client.sync.push(arena, io, &pws, producer_cache.dir, &remote);

    // And the mirror case, keeping mine.
    _ = try cid.client.sync.pull(arena, io, &rws, reader_cache.dir, &remote);
    try reader_dir.dir.writeFile(io, .{ .sub_path = "e.txt", .data = "reader e" });
    _ = try cid.client.workspace.add(arena, io, &rws, reader_cache.dir, &.{"."});
    _ = try cid.client.workspace.commit(arena, io, &rws, "reader e", "user:reader");
    _ = try cid.client.sync.push(arena, io, &rws, reader_cache.dir, &remote);
    try producer.dir.writeFile(io, .{ .sub_path = "e.txt", .data = "producer e wins" });
    _ = try cid.client.workspace.add(arena, io, &pws, producer_cache.dir, &.{"."});
    _ = try cid.client.workspace.commit(arena, io, &pws, "producer e", "user:producer");
    const conflicted2 = try cid.client.sync.pull(arena, io, &pws, producer_cache.dir, &remote);
    try std.testing.expect(conflicted2 == .conflicts);
    _ = try cid.client.sync.decide(arena, io, &pws, "e.txt", .mine);
    const resolved2 = try cid.client.sync.pull(arena, io, &pws, producer_cache.dir, &remote);
    try std.testing.expect(resolved2 == .replayed);
    try std.testing.expectEqual(@as(u32, 1), resolved2.replayed.commits);
    try std.testing.expectEqualSlices(u8, "producer e wins", try readWholeFile(io, producer.dir, "e.txt", arena));
    const final_push = try cid.client.sync.push(arena, io, &pws, producer_cache.dir, &remote);
    try std.testing.expectEqual(@as(u32, 1), final_push.pushed_commits);
    const reader_final = try cid.client.sync.pull(arena, io, &rws, reader_cache.dir, &remote);
    try std.testing.expect(reader_final == .fast_forwarded);
    try std.testing.expectEqualSlices(u8, "producer e wins", try readWholeFile(io, reader_dir.dir, "e.txt", arena));
}

test "releases: tag, immutability, verify green, verify catches corruption" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var diag: cid.pg.Diag = .{};
    var db = try connect(&diag);
    defer db.close();
    var discard: std.Io.Writer.Discarding = .init(&.{});
    _ = try cid.migrate.run(arena, &db, &discard.writer, &diag);

    var s3c = try cid.s3.Client.init(std.testing.allocator, io, .{
        .endpoint = "http://127.0.0.1:8333",
        .access_key = "cid-test-key",
        .secret_key = "cid-test-secret",
        .bucket = "cid-test",
    });
    defer s3c.deinit();
    try s3c.createBucket(arena);

    var deps: cid.api.Deps = .{ .db = &db, .s3 = &s3c, .io = io, .token = "test-token" };
    var direct: DirectTransport = .{ .deps = &deps, .auth = "Bearer test-token" };
    const remote: cid.client.remote.Remote = .{ .t = direct.transport(), .name = "test/datasets/rel" };

    // Clean slate.
    try db.exec("SET cid.maintenance = 'on'", &diag);
    inline for (.{ "refs", "commits", "item_revisions", "dataset_items" }) |table| {
        try db.exec("DELETE FROM " ++ table ++ " WHERE dataset_id IN (SELECT dataset_id FROM datasets WHERE name = 'test/datasets/rel')", &diag);
    }
    try db.exec("DELETE FROM datasets WHERE name = 'test/datasets/rel'", &diag);
    try db.exec("RESET cid.maintenance", &diag);

    // A producer pushes two commits.
    var producer = std.testing.tmpDir(.{ .iterate = true });
    defer producer.cleanup();
    var cache = std.testing.tmpDir(.{});
    defer cache.cleanup();
    try producer.dir.writeFile(io, .{ .sub_path = "x.txt", .data = "release content x" });
    try cid.client.workspace.init(arena, io, producer.dir, "cid@test:test/datasets/rel", "git@example.invalid:rel.git");
    var pws = try cid.client.workspace.open(arena, io, producer.dir);
    _ = try cid.client.workspace.add(arena, io, &pws, cache.dir, &.{"."});
    const c1 = try cid.client.workspace.commit(arena, io, &pws, "first", "user:test");
    _ = try cid.client.sync.push(arena, io, &pws, cache.dir, &remote);
    try producer.dir.writeFile(io, .{ .sub_path = "y.txt", .data = "release content y" });
    _ = try cid.client.workspace.add(arena, io, &pws, cache.dir, &.{"."});
    _ = try cid.client.workspace.commit(arena, io, &pws, "second", "user:test");
    _ = try cid.client.sync.push(arena, io, &pws, cache.dir, &remote);

    // Tag the head; the same name again must be refused (releases never move).
    const t1 = try remote.tag(arena, "v1.0.0");
    try std.testing.expectEqual(@as(u64, 2), t1.items);
    try std.testing.expectError(error.ReleaseExists, remote.tag(arena, "v1.0.0"));
    try std.testing.expectError(error.BadReleaseName, remote.tag(arena, "bad name"));

    // Checkout by release name resolves through /-/releases.
    const list = try remote.releases(arena);
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqualStrings("v1.0.0", list[0].name);

    // Verify: green, and repeatable.
    const ds_id: [:0]const u8 = blk: {
        var rows = try db.query("SELECT dataset_id::text FROM datasets WHERE name = 'test/datasets/rel'", &.{}, &diag);
        defer rows.deinit();
        break :blk try arena.dupeZ(u8, rows.get(0, 0));
    };
    const v1 = try cid.release.verify(arena, &db, &s3c, ds_id, "v1.0.0");
    try std.testing.expect(v1.ok);
    try std.testing.expectEqual(@as(usize, 2), v1.items);

    // Corruption A: a revision smuggled UNDER the sealed cutoff (an id older
    // than c1's, adding a path the release never had) changes recomputed
    // history → verify must turn red.
    const old_uuid = cid.uuid7.Uuid.init(c1.id.unixMs() - 10_000, @splat(7));
    const smuggle = try std.fmt.allocPrintSentinel(arena, "INSERT INTO item_revisions (rev_id, ts, dataset_id, branch, path, op, item_id, item_hash, author) " ++
        "VALUES ('{s}', to_timestamp({d}), '{s}', 'main', 'smuggled.txt', 'add', gen_random_uuid(), " ++
        "decode(repeat('ef', 32), 'hex'), 'user:evil')", .{ &old_uuid.toString(), (old_uuid.unixMs() / 1000), ds_id }, 0);
    try db.exec("INSERT INTO items (item_hash, size_bytes, media_type) VALUES (decode(repeat('ef', 32), 'hex'), 1, 'application/octet-stream') ON CONFLICT DO NOTHING", &diag);
    try db.exec(smuggle, &diag);
    const v2 = try cid.release.verify(arena, &db, &s3c, ds_id, "v1.0.0");
    try std.testing.expect(!v2.ok);
    try std.testing.expectEqual(cid.release.VerifyProblem.recomputed_hash_differs, v2.problems[0]);

    // Remove the smuggled row (maintenance), verify is green again.
    try db.exec("SET cid.maintenance = 'on'", &diag);
    try db.exec("DELETE FROM item_revisions WHERE author = 'user:evil'", &diag);
    try db.exec("RESET cid.maintenance", &diag);
    const v3 = try cid.release.verify(arena, &db, &s3c, ds_id, "v1.0.0");
    try std.testing.expect(v3.ok);

    // Corruption B: tamper with the stored manifest object.
    const commit_for_release = try arena.dupe(u8, list[0].commit);
    const mkey = try cid.release.manifestKey(arena, ds_id, commit_for_release);
    try s3c.putObject(arena, mkey, "tampered bytes");
    const v4 = try cid.release.verify(arena, &db, &s3c, ds_id, "v1.0.0");
    try std.testing.expect(!v4.ok);
    try std.testing.expectEqual(cid.release.VerifyProblem.stored_manifest_differs, v4.problems[0]);
}

test "git writer: one commit and tag per release, idempotent, resumable" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var diag: cid.pg.Diag = .{};
    var db = try connect(&diag);
    defer db.close();
    var discard: std.Io.Writer.Discarding = .init(&.{});
    _ = try cid.migrate.run(arena, &db, &discard.writer, &diag);

    var s3c = try cid.s3.Client.init(std.testing.allocator, io, .{
        .endpoint = "http://127.0.0.1:8333",
        .access_key = "cid-test-key",
        .secret_key = "cid-test-secret",
        .bucket = "cid-test",
    });
    defer s3c.deinit();
    try s3c.createBucket(arena);

    // A local bare repository stands in for GitLab.
    var git_root = std.testing.tmpDir(.{ .iterate = true });
    defer git_root.cleanup();
    var root_path_buf: [512]u8 = undefined;
    const root_len = try git_root.dir.realPath(io, &root_path_buf);
    const root_path = root_path_buf[0..root_len];
    const bare_url = try std.fmt.allocPrint(arena, "{s}/dataset.git", .{root_path});
    const work_root = try std.fmt.allocPrint(arena, "{s}/work", .{root_path});
    const clone_dir = try std.fmt.allocPrint(arena, "{s}/check", .{root_path});
    _ = try std.process.run(arena, io, .{ .argv = &.{ "git", "init", "--bare", "-b", "main", bare_url } });

    var deps: cid.api.Deps = .{
        .db = &db,
        .s3 = &s3c,
        .io = io,
        .token = "test-token",
        .git = .{ .workdir = work_root, .server_url = "https://cid.example" },
    };
    var direct: DirectTransport = .{ .deps = &deps, .auth = "Bearer test-token" };
    const remote: cid.client.remote.Remote = .{ .t = direct.transport(), .name = "test/datasets/gitw" };

    // Clean slate, then a dataset whose git_url is the bare repo.
    try db.exec("SET cid.maintenance = 'on'", &diag);
    inline for (.{ "git_writes", "refs", "commits", "item_revisions", "dataset_items" }) |table| {
        try db.exec("DELETE FROM " ++ table ++ " WHERE dataset_id IN (SELECT dataset_id FROM datasets WHERE name = 'test/datasets/gitw')", &diag);
    }
    try db.exec("DELETE FROM datasets WHERE name = 'test/datasets/gitw'", &diag);
    try db.exec("RESET cid.maintenance", &diag);

    var producer = std.testing.tmpDir(.{ .iterate = true });
    defer producer.cleanup();
    var cache = std.testing.tmpDir(.{});
    defer cache.cleanup();
    try producer.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "git writer content" });
    try cid.client.workspace.init(arena, io, producer.dir, "cid@test:test/datasets/gitw", bare_url);
    var pws = try cid.client.workspace.open(arena, io, producer.dir);
    _ = try cid.client.workspace.add(arena, io, &pws, cache.dir, &.{"."});
    _ = try cid.client.workspace.commit(arena, io, &pws, "first release content", "user:test");
    _ = try cid.client.sync.push(arena, io, &pws, cache.dir, &remote);

    // Tag: with deps.git set, the repository is written immediately.
    _ = try remote.tag(arena, "v1.0.0");

    var rows1 = try db.query(
        "SELECT status FROM git_writes w JOIN datasets d USING (dataset_id) WHERE d.name = 'test/datasets/gitw'",
        &.{},
        &diag,
    );
    defer rows1.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows1.count());
    try std.testing.expectEqualStrings("done", rows1.get(0, 0));

    // Clone the bare repo and look at what landed.
    _ = try std.process.run(arena, io, .{ .argv = &.{ "git", "clone", bare_url, clone_dir } });
    var check = try std.Io.Dir.cwd().openDir(io, clone_dir, .{ .iterate = true });
    defer check.close(io);
    const readme = try check.readFileAlloc(io, "README.md", arena, .limited(64 * 1024));
    try std.testing.expect(std.mem.indexOf(u8, readme, "v1.0.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, readme, "cid clone") != null);
    const marker = try check.readFileAlloc(io, ".cid", arena, .limited(1024));
    try std.testing.expect(std.mem.indexOf(u8, marker, "test/datasets/gitw") != null);
    _ = try check.readFileAlloc(io, "stats.yaml", arena, .limited(64 * 1024));
    _ = try check.readFileAlloc(io, "files.txt", arena, .limited(64 * 1024));
    const tags1 = try std.process.run(arena, io, .{ .argv = &.{ "git", "-C", clone_dir, "tag" } });
    try std.testing.expectEqualStrings("v1.0.0\n", tags1.stdout);

    // Second release: exactly one more commit, one more tag.
    try producer.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "second file" });
    _ = try cid.client.workspace.add(arena, io, &pws, cache.dir, &.{"."});
    _ = try cid.client.workspace.commit(arena, io, &pws, "second release content", "user:test");
    _ = try cid.client.sync.push(arena, io, &pws, cache.dir, &remote);
    _ = try remote.tag(arena, "v2.0.0");

    // Re-processing changes nothing: rendering is deterministic.
    const again = try cid.gitrepo.writer.processDataset(arena, io, &db, deps.git.?, "test/datasets/gitw");
    try std.testing.expectEqual(@as(u32, 0), again.failed);

    const count = try std.process.run(arena, io, .{ .argv = &.{ "git", "-C", bare_url, "rev-list", "--count", "main" } });
    try std.testing.expectEqualStrings("2\n", count.stdout);
    const tags2 = try std.process.run(arena, io, .{ .argv = &.{ "git", "-C", bare_url, "tag" } });
    try std.testing.expectEqualStrings("v1.0.0\nv2.0.0\n", tags2.stdout);

    // The CHANGELOG now lists both releases, newest first.
    _ = try std.process.run(arena, io, .{ .argv = &.{ "git", "-C", clone_dir, "pull" } });
    const changelog = try check.readFileAlloc(io, "CHANGELOG.md", arena, .limited(64 * 1024));
    const v2_at = std.mem.indexOf(u8, changelog, "v2.0.0").?;
    const v1_at = std.mem.indexOf(u8, changelog, "v1.0.0").?;
    try std.testing.expect(v2_at < v1_at);
}

test "access: key lookup, forced command, scoped tokens enforced by routes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var diag: cid.pg.Diag = .{};
    var db = try connect(&diag);
    defer db.close();
    var discard: std.Io.Writer.Discarding = .init(&.{});
    _ = try cid.migrate.run(arena, &db, &discard.writer, &diag);

    var s3c = try cid.s3.Client.init(std.testing.allocator, io, .{
        .endpoint = "http://127.0.0.1:8333",
        .access_key = "cid-test-key",
        .secret_key = "cid-test-secret",
        .bucket = "cid-test",
    });
    defer s3c.deinit();
    try s3c.createBucket(arena);

    const secret = "integration-test-secret-0123456789abcdef";
    var deps: cid.api.Deps = .{ .db = &db, .s3 = &s3c, .io = io, .token = "", .token_secret = secret };

    // Clean slate: account, key, dataset, access.
    try db.exec("DELETE FROM access WHERE account_id IN ('gitlab:7001', 'gitlab:7002')", &diag);
    try db.exec("DELETE FROM ssh_keys WHERE account_id IN ('gitlab:7001', 'gitlab:7002')", &diag);
    try db.exec("DELETE FROM accounts WHERE account_id IN ('gitlab:7001', 'gitlab:7002')", &diag);
    try db.exec("INSERT INTO datasets (dataset_id, name, kind, git_url) VALUES " ++
        "('018f0000-0000-7000-8000-00000000ac01', 'test/datasets/access', 'files', 'g@h:a.git') " ++
        "ON CONFLICT (name) DO NOTHING", &diag);
    try db.exec("INSERT INTO accounts (account_id, display_name, source) VALUES " ++
        "('gitlab:7001', 'Reader Rhea', 'dashboard'), ('gitlab:7002', 'Writer Wade', 'dashboard')", &diag);
    try db.exec("INSERT INTO ssh_keys (fingerprint, account_id, public_key) VALUES " ++
        "('SHA256:testfp7001', 'gitlab:7001', 'ssh-ed25519 AAAAC3NzaTEST7001 rhea@laptop')", &diag);
    try db.exec("INSERT INTO access (dataset_id, account_id, level, source) VALUES " ++
        "('018f0000-0000-7000-8000-00000000ac01', 'gitlab:7001', 'read', 'dashboard'), " ++
        "('018f0000-0000-7000-8000-00000000ac01', 'gitlab:7002', 'write', 'dashboard')", &diag);

    // AuthorizedKeysCommand: a known key gets the pinned forced command.
    const line = (try cid.access.auth.authorizedKeysLine(arena, &db, "SHA256:testfp7001")).?;
    try std.testing.expect(std.mem.startsWith(u8, line, "restrict,command=\"cid ssh-auth --account=gitlab:7001\" ssh-ed25519"));
    try std.testing.expectEqual(@as(?[]const u8, null), try cid.access.auth.authorizedKeysLine(arena, &db, "SHA256:unknown"));

    // The forced command: read is granted to the reader, write is not.
    const now: u64 = @intCast(@max(0, std.Io.Timestamp.now(io, .real).toSeconds()));
    const read_req = try cid.access.auth.parseOriginalCommand("cid-auth test/datasets/access read", "gitlab:7001");
    const read_grant = try cid.access.auth.authorize(arena, &db, secret, "http://127.0.0.1:7070", now, read_req);
    try std.testing.expect(std.mem.startsWith(u8, read_grant.token, "cid1."));

    const write_req = try cid.access.auth.parseOriginalCommand("cid-auth test/datasets/access write", "gitlab:7001");
    try std.testing.expectError(error.AccessDenied, cid.access.auth.authorize(arena, &db, secret, "x", now, write_req));
    const wade_write = try cid.access.auth.parseOriginalCommand("cid-auth test/datasets/access write", "gitlab:7002");
    const write_grant = try cid.access.auth.authorize(arena, &db, secret, "x", now, wade_write);

    // Both decisions landed in the audit log.
    var events = try db.query(
        "SELECT count(*) FILTER (WHERE granted), count(*) FILTER (WHERE NOT granted) FROM auth_events " ++
            "WHERE account_id IN ('gitlab:7001', 'gitlab:7002') AND ts > now() - interval '1 minute'",
        &.{},
        &diag,
    );
    defer events.deinit();
    try std.testing.expect((std.fmt.parseInt(u32, events.get(0, 0), 10) catch 0) >= 2);
    try std.testing.expect((std.fmt.parseInt(u32, events.get(0, 1), 10) catch 0) >= 1);

    // Routes enforce the scope: read token reads but cannot push; a token
    // for another dataset is useless here; garbage is refused.
    const read_auth = try std.fmt.allocPrint(arena, "Bearer {s}", .{read_grant.token});
    const write_auth = try std.fmt.allocPrint(arena, "Bearer {s}", .{write_grant.token});

    const head_ok = cid.api.handle(arena, &deps, "GET", "/v0/datasets/test/datasets/access/-/head", read_auth, "");
    try std.testing.expectEqual(std.http.Status.ok, head_ok.status);
    const push_denied = cid.api.handle(arena, &deps, "POST", "/v0/datasets/test/datasets/access/-/push", read_auth, "{}");
    try std.testing.expectEqual(std.http.Status.unauthorized, push_denied.status);
    const check_denied = cid.api.handle(arena, &deps, "POST", "/v0/datasets/test/datasets/access/-/check-hashes", read_auth, "{\"hashes\":[]}");
    try std.testing.expectEqual(std.http.Status.unauthorized, check_denied.status);
    const check_ok = cid.api.handle(arena, &deps, "POST", "/v0/datasets/test/datasets/access/-/check-hashes", write_auth, "{\"hashes\":[]}");
    try std.testing.expectEqual(std.http.Status.ok, check_ok.status);

    const other_ds = cid.api.handle(arena, &deps, "GET", "/v0/datasets/test/datasets/sync/-/head", read_auth, "");
    try std.testing.expectEqual(std.http.Status.unauthorized, other_ds.status);
    const garbage = cid.api.handle(arena, &deps, "GET", "/v0/datasets/test/datasets/access/-/head", "Bearer cid1.not.real", "");
    try std.testing.expectEqual(std.http.Status.unauthorized, garbage.status);

    // An expired token is dead, whatever it once allowed.
    const expired = try cid.access.token.mint(arena, secret, .{
        .expiry_unix = now - 1,
        .level = .write,
        .account = "gitlab:7002",
        .dataset = "test/datasets/access",
    });
    const expired_auth = try std.fmt.allocPrint(arena, "Bearer {s}", .{expired});
    const expired_res = cid.api.handle(arena, &deps, "GET", "/v0/datasets/test/datasets/access/-/head", expired_auth, "");
    try std.testing.expectEqual(std.http.Status.unauthorized, expired_res.status);

    // With no static token configured, the old shared-token style fails.
    const static_res = cid.api.handle(arena, &deps, "GET", "/v0/datasets/test/datasets/access/-/head", "Bearer test-token", "");
    try std.testing.expectEqual(std.http.Status.unauthorized, static_res.status);
}

test "gitlab sync: members and keys applied, removals revoke access" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    _ = io;

    var diag: cid.pg.Diag = .{};
    var db = try connect(&diag);
    defer db.close();
    var discard: std.Io.Writer.Discarding = .init(&.{});
    _ = try cid.migrate.run(arena, &db, &discard.writer, &diag);

    try db.exec("DELETE FROM access WHERE account_id LIKE 'gitlab:91%'", &diag);
    try db.exec("DELETE FROM ssh_keys WHERE account_id LIKE 'gitlab:91%'", &diag);
    try db.exec("DELETE FROM accounts WHERE account_id LIKE 'gitlab:91%'", &diag);
    try db.exec("INSERT INTO datasets (dataset_id, name, kind, git_url) VALUES " ++
        "('018f0000-0000-7000-8000-000000009d01'::uuid, 'test/datasets/gl', 'files', 'g@h:gl.git') " ++
        "ON CONFLICT (name) DO NOTHING", &diag);

    // First sync: a reporter, a developer, a guest (ignored).
    const members1 = try cid.access.gitlab.parseMembers(arena,
        \\[{"id":9101,"username":"rhea","name":"Rhea R","access_level":20,"state":"active"},
        \\ {"id":9102,"username":"wade","name":"Wade W","access_level":30,"state":"active"},
        \\ {"id":9103,"username":"guest","access_level":10,"state":"active"}]
    );
    const first = try cid.access.gitlab.applyMembers(arena, &db, "test/datasets/gl", members1);
    try std.testing.expectEqual(@as(u32, 2), first.upserted);

    var levels = try db.query(
        "SELECT account_id, level FROM access a JOIN datasets d USING (dataset_id) " ++
            "WHERE d.name = 'test/datasets/gl' ORDER BY account_id",
        &.{},
        &diag,
    );
    defer levels.deinit();
    try std.testing.expectEqual(@as(usize, 2), levels.count());
    try std.testing.expectEqualStrings("read", levels.get(0, 1)); // 9101
    try std.testing.expectEqualStrings("write", levels.get(1, 1)); // 9102

    // Keys for the developer: the fixture key gets its real fingerprint.
    const keys1 = try cid.access.gitlab.parseKeys(arena,
        \\[{"id":1,"key":"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFdJMTzwHtTuz5TEIEMRoQ8hWQ8EuaJotFSs/0FCfvS4 fixture@cid"},
        \\ {"id":2,"key":"garbage not a key"}]
    );
    const key_first = try cid.access.gitlab.applyKeys(arena, &db, 9102, keys1);
    try std.testing.expectEqual(@as(u32, 1), key_first.upserted);
    try std.testing.expectEqual(@as(u32, 1), key_first.skipped_invalid);
    const line = (try cid.access.auth.authorizedKeysLine(arena, &db, "SHA256:dFtRBBCbqwbXXQkKRXzbOpi9eJQNbn/SAiaVrdWiLo0")).?;
    try std.testing.expect(std.mem.indexOf(u8, line, "--account=gitlab:9102") != null);

    // Second sync: Rhea is gone, Wade is demoted to reporter, keys rotated.
    const members2 = try cid.access.gitlab.parseMembers(arena,
        \\[{"id":9102,"username":"wade","name":"Wade W","access_level":20,"state":"active"}]
    );
    const second = try cid.access.gitlab.applyMembers(arena, &db, "test/datasets/gl", members2);
    try std.testing.expectEqual(@as(u32, 1), second.removed);

    var levels2 = try db.query(
        "SELECT account_id, level FROM access a JOIN datasets d USING (dataset_id) " ++
            "WHERE d.name = 'test/datasets/gl' ORDER BY account_id",
        &.{},
        &diag,
    );
    defer levels2.deinit();
    try std.testing.expectEqual(@as(usize, 1), levels2.count());
    try std.testing.expectEqualStrings("gitlab:9102", levels2.get(0, 0));
    try std.testing.expectEqualStrings("read", levels2.get(0, 1));

    const key_second = try cid.access.gitlab.applyKeys(arena, &db, 9102, &.{});
    try std.testing.expectEqual(@as(u32, 1), key_second.removed);
    try std.testing.expectEqual(@as(?[]const u8, null), try cid.access.auth.authorizedKeysLine(arena, &db, "SHA256:dFtRBBCbqwbXXQkKRXzbOpi9eJQNbn/SAiaVrdWiLo0"));
}

test "branches: compose from main, push on branch, merge with conflicts listed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var diag: cid.pg.Diag = .{};
    var db = try connect(&diag);
    defer db.close();
    var discard: std.Io.Writer.Discarding = .init(&.{});
    _ = try cid.migrate.run(arena, &db, &discard.writer, &diag);
    var s3c = try cid.s3.Client.init(std.testing.allocator, io, .{
        .endpoint = "http://127.0.0.1:8333",
        .access_key = "cid-test-key",
        .secret_key = "cid-test-secret",
        .bucket = "cid-test",
    });
    defer s3c.deinit();
    try s3c.createBucket(arena);

    var deps: cid.api.Deps = .{ .db = &db, .s3 = &s3c, .io = io, .token = "test-token" };
    var direct: DirectTransport = .{ .deps = &deps, .auth = "Bearer test-token" };
    const remote: cid.client.remote.Remote = .{ .t = direct.transport(), .name = "test/datasets/br" };

    try db.exec("SET cid.maintenance = 'on'", &diag);
    inline for (.{ "git_writes", "refs", "commits", "item_revisions", "dataset_items" }) |table| {
        try db.exec("DELETE FROM " ++ table ++ " WHERE dataset_id IN (SELECT dataset_id FROM datasets WHERE name = 'test/datasets/br')", &diag);
    }
    try db.exec("DELETE FROM datasets WHERE name = 'test/datasets/br'", &diag);
    try db.exec("RESET cid.maintenance", &diag);

    // Main gets its base: shared.txt and tweak.txt.
    var producer = std.testing.tmpDir(.{ .iterate = true });
    defer producer.cleanup();
    var cache = std.testing.tmpDir(.{});
    defer cache.cleanup();
    try producer.dir.writeFile(io, .{ .sub_path = "shared.txt", .data = "base shared" });
    try producer.dir.writeFile(io, .{ .sub_path = "tweak.txt", .data = "base tweak" });
    try cid.client.workspace.init(arena, io, producer.dir, "cid@test:test/datasets/br", "g@h:br.git");
    var pws = try cid.client.workspace.open(arena, io, producer.dir);
    _ = try cid.client.workspace.add(arena, io, &pws, cache.dir, &.{"."});
    _ = try cid.client.workspace.commit(arena, io, &pws, "base", "user:test");
    _ = try cid.client.sync.push(arena, io, &pws, cache.dir, &remote);

    // A branch, worked on from a clone.
    _ = try remote.branchCreate(arena, "cleanup");
    try std.testing.expectError(error.BranchExists, remote.branchCreate(arena, "cleanup"));

    var worker = std.testing.tmpDir(.{ .iterate = true });
    defer worker.cleanup();
    var wcache = std.testing.tmpDir(.{});
    defer wcache.cleanup();
    _ = try cid.client.sync.clone(arena, io, worker.dir, wcache.dir, &remote, "cid@test:test/datasets/br", null, null);
    var wws = try cid.client.workspace.open(arena, io, worker.dir);

    // Switch to the branch: the base files are all there (composed state).
    const head_of_branch = (try remote.head(arena, "cleanup")).?;
    _ = try cid.client.sync.checkout(arena, io, &wws, wcache.dir, &remote, "cleanup", head_of_branch, true);
    try std.testing.expectEqualSlices(u8, "base shared", try readWholeFile(io, worker.dir, "shared.txt", arena));

    // Branch work: change tweak.txt, add branch-only.txt; push lands on the branch.
    try worker.dir.writeFile(io, .{ .sub_path = "tweak.txt", .data = "branch tweak" });
    try worker.dir.writeFile(io, .{ .sub_path = "branch-only.txt", .data = "from the branch" });
    _ = try cid.client.workspace.add(arena, io, &wws, wcache.dir, &.{"."});
    _ = try cid.client.workspace.commit(arena, io, &wws, "branch work", "user:worker");
    const bpush = try cid.client.sync.push(arena, io, &wws, wcache.dir, &remote);
    try std.testing.expectEqual(@as(u32, 1), bpush.pushed_commits);

    // Branch state composes; main is untouched.
    const bstate = try remote.state(arena, (try remote.head(arena, "cleanup")).?);
    try std.testing.expectEqual(@as(usize, 3), bstate.len);
    const mstate = try remote.state(arena, (try remote.head(arena, "main")).?);
    try std.testing.expectEqual(@as(usize, 2), mstate.len);

    // Main moves independently on a different file: merge is automatic.
    try producer.dir.writeFile(io, .{ .sub_path = "main-only.txt", .data = "from main" });
    _ = try cid.client.workspace.add(arena, io, &pws, cache.dir, &.{"."});
    _ = try cid.client.workspace.commit(arena, io, &pws, "main work", "user:test");
    _ = try cid.client.sync.push(arena, io, &pws, cache.dir, &remote);

    const merged = try remote.merge(arena, "cleanup", "user:test");
    try std.testing.expect(merged == .merged);
    try std.testing.expectEqual(@as(u64, 2), merged.merged.changes); // tweak + branch-only

    const after = try remote.state(arena, (try remote.head(arena, "main")).?);
    try std.testing.expectEqual(@as(usize, 4), after.len);
    var mrows = try db.query(
        "SELECT merge_parent_id::text FROM commits c JOIN datasets d USING (dataset_id) " ++
            "WHERE d.name = 'test/datasets/br' AND merge_parent_id IS NOT NULL",
        &.{},
        &diag,
    );
    defer mrows.deinit();
    try std.testing.expectEqual(@as(usize, 1), mrows.count());

    // The producer pulls the merge; the folder holds all four files.
    const after_pull = try cid.client.sync.pull(arena, io, &pws, cache.dir, &remote);
    try std.testing.expect(after_pull == .fast_forwarded);
    try std.testing.expectEqualSlices(u8, "branch tweak", try readWholeFile(io, producer.dir, "tweak.txt", arena));
    try std.testing.expectEqualSlices(u8, "from the branch", try readWholeFile(io, producer.dir, "branch-only.txt", arena));

    // A conflicting branch: both sides now change shared.txt differently.
    _ = try remote.branchCreate(arena, "risky");
    _ = try cid.client.sync.checkout(arena, io, &wws, wcache.dir, &remote, "risky", (try remote.head(arena, "risky")).?, true);
    try worker.dir.writeFile(io, .{ .sub_path = "shared.txt", .data = "risky version" });
    _ = try cid.client.workspace.add(arena, io, &wws, wcache.dir, &.{"shared.txt"});
    _ = try cid.client.workspace.commit(arena, io, &wws, "risky shared", "user:worker");
    _ = try cid.client.sync.push(arena, io, &wws, wcache.dir, &remote);
    try producer.dir.writeFile(io, .{ .sub_path = "shared.txt", .data = "main version" });
    _ = try cid.client.workspace.add(arena, io, &pws, cache.dir, &.{"shared.txt"});
    _ = try cid.client.workspace.commit(arena, io, &pws, "main shared", "user:test");
    _ = try cid.client.sync.push(arena, io, &pws, cache.dir, &remote);

    const conflicted = try remote.merge(arena, "risky", "user:test");
    try std.testing.expect(conflicted == .conflicts);
    try std.testing.expectEqual(@as(usize, 1), conflicted.conflicts.len);
    try std.testing.expectEqualStrings("shared.txt", conflicted.conflicts[0]);
    // Nothing merged: main still holds its own version.
    const untouched = try remote.state(arena, (try remote.head(arena, "main")).?);
    for (untouched) |item| {
        if (std.mem.eql(u8, item.path, "shared.txt")) {
            var dgst: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash("main version", &dgst, .{});
            try std.testing.expectEqualStrings(&std.fmt.bytesToHex(dgst, .lower), item.hash);
        }
    }

    try std.testing.expectError(error.NoSuchBranch, remote.merge(arena, "ghost", "user:test"));
}

test "s3 multipart: a large object goes up in parts and comes back identical" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var s3c = try cid.s3.Client.init(std.testing.allocator, io, .{
        .endpoint = "http://127.0.0.1:8333",
        .access_key = "cid-test-key",
        .secret_key = "cid-test-secret",
        .bucket = "cid-test",
        .multipart_threshold = 5 * 1024 * 1024, // S3's minimum part size
    });
    defer s3c.deinit();
    try s3c.createBucket(arena);

    // 12 MB of varied bytes → 3 parts (5 + 5 + 2).
    const big = try arena.alloc(u8, 12 * 1024 * 1024);
    for (big, 0..) |*b, i| b.* = @truncate(i *% 31 +% (i >> 8));

    const key = "items/sha256/mp/multipart-test-object";
    try s3c.deleteObject(arena, key);
    try s3c.putObject(arena, key, big);

    const got = try s3c.getObjectAlloc(arena, key, 16 * 1024 * 1024);
    try std.testing.expectEqual(big.len, got.len);
    try std.testing.expect(std.mem.eql(u8, big, got));
    try s3c.deleteObject(arena, key);
}

test "purge: bytes gone, history intact, verify says so, content cannot return" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var diag: cid.pg.Diag = .{};
    var db = try connect(&diag);
    defer db.close();
    var discard: std.Io.Writer.Discarding = .init(&.{});
    _ = try cid.migrate.run(arena, &db, &discard.writer, &diag);
    var s3c = try cid.s3.Client.init(std.testing.allocator, io, .{
        .endpoint = "http://127.0.0.1:8333",
        .access_key = "cid-test-key",
        .secret_key = "cid-test-secret",
        .bucket = "cid-test",
    });
    defer s3c.deinit();
    try s3c.createBucket(arena);

    var deps: cid.api.Deps = .{ .db = &db, .s3 = &s3c, .io = io, .token = "test-token" };
    var direct: DirectTransport = .{ .deps = &deps, .auth = "Bearer test-token" };
    const remote: cid.client.remote.Remote = .{ .t = direct.transport(), .name = "test/datasets/purge" };

    try db.exec("SET cid.maintenance = 'on'", &diag);
    inline for (.{ "git_writes", "refs", "commits", "item_revisions", "dataset_items" }) |table| {
        try db.exec("DELETE FROM " ++ table ++ " WHERE dataset_id IN (SELECT dataset_id FROM datasets WHERE name = 'test/datasets/purge')", &diag);
    }
    try db.exec("DELETE FROM purged_items WHERE dataset_id IN (SELECT dataset_id FROM datasets WHERE name = 'test/datasets/purge')", &diag);
    try db.exec("DELETE FROM datasets WHERE name = 'test/datasets/purge'", &diag);
    try db.exec("RESET cid.maintenance", &diag);

    const sensitive = "a face image that must be erasable";
    var dg: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(sensitive, &dg, .{});
    const sensitive_hash = std.fmt.bytesToHex(dg, .lower);
    {
        const hz = try arena.dupeZ(u8, &sensitive_hash);
        db.execParams("DELETE FROM purged_items WHERE item_hash = decode($1, 'hex')", &.{hz}, &diag) catch {};
    }

    var producer = std.testing.tmpDir(.{ .iterate = true });
    defer producer.cleanup();
    var cache = std.testing.tmpDir(.{});
    defer cache.cleanup();
    try producer.dir.writeFile(io, .{ .sub_path = "face.jpg", .data = sensitive });
    try producer.dir.writeFile(io, .{ .sub_path = "ok.txt", .data = "harmless" });
    try cid.client.workspace.init(arena, io, producer.dir, "cid@test:test/datasets/purge", "g@h:p.git");
    var pws = try cid.client.workspace.open(arena, io, producer.dir);
    _ = try cid.client.workspace.add(arena, io, &pws, cache.dir, &.{"."});
    _ = try cid.client.workspace.commit(arena, io, &pws, "with face", "user:test");
    _ = try cid.client.sync.push(arena, io, &pws, cache.dir, &remote);
    _ = try remote.tag(arena, "v1.0.0");

    const ds_id: [:0]const u8 = blk: {
        var rows = try db.query("SELECT dataset_id::text FROM datasets WHERE name = 'test/datasets/purge'", &.{}, &diag);
        defer rows.deinit();
        break :blk try arena.dupeZ(u8, rows.get(0, 0));
    };

    // Purge by path; the bytes vanish, the tombstone and audit land.
    const purged = try cid.purge.purge(arena, &db, &s3c, "test/datasets/purge", "face.jpg", "erasure request #42", "user:admin");
    try std.testing.expectEqualStrings(&sensitive_hash, purged.hash_hex);
    try std.testing.expectEqual(@as(usize, 1), purged.releases_affected);
    const key = try cid.api.itemKey(arena, &sensitive_hash);
    try std.testing.expectEqual(@as(?u64, null), try s3c.headObject(arena, key));
    try std.testing.expectError(error.AlreadyPurged, cid.purge.purge(arena, &db, &s3c, "test/datasets/purge", "face.jpg", "again", "user:admin"));

    var audit = try db.query(
        "SELECT count(*) FROM activity_events WHERE dataset_id = $1::uuid AND action = 'purge'",
        &.{ds_id},
        &diag,
    );
    defer audit.deinit();
    try std.testing.expectEqualStrings("1", audit.get(0, 0));

    // History rows untouched; verify is green with the purged item named.
    const v = try cid.release.verify(arena, &db, &s3c, ds_id, "v1.0.0");
    try std.testing.expect(v.ok);
    try std.testing.expectEqual(@as(usize, 1), v.purged);
    try std.testing.expectEqual(@as(usize, 2), v.items);

    // The purged content can never come back through push.
    const check_body = try std.fmt.allocPrint(arena, "{{\"hashes\":[\"{s}\"]}}", .{&sensitive_hash});
    const refused = cid.api.handle(arena, &deps, "POST", "/v0/datasets/test/datasets/purge/-/check-hashes", "Bearer test-token", check_body);
    try std.testing.expectEqual(std.http.Status.unprocessable_entity, refused.status);
}

test "annotated: the platform writes revisions, the server commits, state composes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var diag: cid.pg.Diag = .{};
    var db = try connect(&diag);
    defer db.close();
    var discard: std.Io.Writer.Discarding = .init(&.{});
    _ = try cid.migrate.run(arena, &db, &discard.writer, &diag);
    var s3c = try cid.s3.Client.init(std.testing.allocator, io, .{
        .endpoint = "http://127.0.0.1:8333",
        .access_key = "cid-test-key",
        .secret_key = "cid-test-secret",
        .bucket = "cid-test",
    });
    defer s3c.deinit();
    try s3c.createBucket(arena);

    var deps: cid.api.Deps = .{ .db = &db, .s3 = &s3c, .io = io, .token = "test-token" };
    var direct: DirectTransport = .{ .deps = &deps, .auth = "Bearer test-token" };
    const remote: cid.client.remote.Remote = .{ .t = direct.transport(), .name = "test/datasets/ann" };

    try db.exec("SET cid.maintenance = 'on'", &diag);
    inline for (.{ "git_writes", "refs", "commits", "item_revisions", "annotation_revisions", "dataset_items" }) |table| {
        try db.exec("DELETE FROM " ++ table ++ " WHERE dataset_id IN (SELECT dataset_id FROM datasets WHERE name = 'test/datasets/ann')", &diag);
    }
    try db.exec("DELETE FROM datasets WHERE name = 'test/datasets/ann'", &diag);
    try db.exec("RESET cid.maintenance", &diag);

    // The platform creates an annotated dataset.
    const created = cid.api.handle(arena, &deps, "POST", "/v0/datasets", "Bearer test-token", "{\"name\":\"test/datasets/ann\",\"kind\":\"annotated\",\"git_url\":\"g@h:ann.git\"}");
    try std.testing.expectEqual(std.http.Status.created, created.status);
    const ds_id: [:0]const u8 = blk: {
        var rows = try db.query("SELECT dataset_id::text FROM datasets WHERE name = 'test/datasets/ann'", &.{}, &diag);
        defer rows.deinit();
        break :blk try arena.dupeZ(u8, rows.get(0, 0));
    };

    // Bytes go up through check-hashes presigns, then register-items
    // records them (hash-verified against storage).
    const frame1 = "frame one pixels";
    const frame2 = "frame two pixels, longer";
    var dg: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(frame1, &dg, .{});
    const h1 = std.fmt.bytesToHex(dg, .lower);
    std.crypto.hash.sha2.Sha256.hash(frame2, &dg, .{});
    const h2 = std.fmt.bytesToHex(dg, .lower);
    try s3c.deleteObject(arena, try cid.api.itemKey(arena, &h1));
    try s3c.deleteObject(arena, try cid.api.itemKey(arena, &h2));
    {
        const hz = try arena.dupeZ(u8, &h1);
        db.execParams("DELETE FROM purged_items WHERE item_hash = decode($1, 'hex')", &.{hz}, &diag) catch {};
    }

    const missing = try remote.checkHashes(arena, &.{ &h1, &h2 });
    try std.testing.expectEqual(@as(usize, 2), missing.len);
    var plain: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    defer plain.deinit();
    for (missing) |m| {
        const content: []const u8 = if (std.mem.eql(u8, m.hash, &h1)) frame1 else frame2;
        const put = try plain.fetch(.{ .location = .{ .url = m.url }, .method = .PUT, .payload = content, .raw_uri = true, .keep_alive = false });
        try std.testing.expectEqual(std.http.Status.ok, put.status);
    }
    // Registration before upload is refused; after upload it lands.
    try remote.registerItems(arena, &.{
        .{ .hash = &h1, .size = frame1.len, .media_type = "image/jpeg" },
        .{ .hash = &h2, .size = frame2.len, .media_type = "image/jpeg" },
    });

    // The platform writes revisions directly: cid_writer role, shared
    // write lock, strictly increasing UUIDv7 ids (the documented contract).
    var last = cid.uuid7.Uuid.now(io);
    const aitem1 = cid.uuid7.Uuid.now(io).toString();
    const aitem2 = cid.uuid7.Uuid.now(io).toString();
    const ann1_id = cid.uuid7.Uuid.now(io);
    const ann1 = ann1_id.toString();
    const ann2 = cid.uuid7.Uuid.nextAfter(io, ann1_id).toString();

    try db.exec("BEGIN", &diag);
    {
        const lock = try std.fmt.allocPrintSentinel(arena, "SELECT pg_advisory_xact_lock_shared(hashtextextended('{s}/main', 0))", .{ds_id}, 0);
        try db.exec(lock, &diag);
    }
    try db.exec("SET LOCAL ROLE cid_writer", &diag);
    inline for (.{
        .{ "frames/0001.jpg", &h1, "train" },
        .{ "frames/0002.jpg", &h2, "val" },
    }, 0..) |row, idx| {
        last = cid.uuid7.Uuid.nextAfter(io, last);
        const item_id = if (idx == 0) &aitem1 else &aitem2;
        const sql = try std.fmt.allocPrintSentinel(arena, "INSERT INTO item_revisions (rev_id, ts, dataset_id, branch, path, op, item_id, item_hash, split, author) " ++
            "VALUES ('{s}', to_timestamp({d}), '{s}', 'main', '{s}', 'add', '{s}', decode('{s}', 'hex'), '{s}', 'agent:annotator')", .{ &last.toString(), last.unixMs() / 1000, ds_id, row[0], item_id, row[1], row[2] }, 0);
        try db.exec(sql, &diag);
    }
    inline for (.{
        .{ &ann1, &aitem1, "{\"x\":10,\"y\":20,\"w\":30,\"h\":40}", "person" },
        .{ &ann2, &aitem1, "{\"x\":50,\"y\":60,\"w\":70,\"h\":80}", "vehicle" },
    }) |row| {
        last = cid.uuid7.Uuid.nextAfter(io, last);
        const sql = try std.fmt.allocPrintSentinel(arena, "INSERT INTO annotation_revisions (rev_id, ts, dataset_id, branch, annotation_id, item_id, op, kind, class, geometry, author, policy_ver) " ++
            "VALUES ('{s}', to_timestamp({d}), '{s}', 'main', '{s}', '{s}', 'create', 'box', '{s}', '{s}'::jsonb, 'agent:annotator', 'policy-v1')", .{ &last.toString(), last.unixMs() / 1000, ds_id, row[0], row[1], row[3], row[2] }, 0);
        try db.exec(sql, &diag);
    }
    try db.exec("COMMIT", &diag);

    // The server seals the batch.
    const c1 = try remote.commitServer(arena, "main", "batch one annotated", "agent:annotator");
    const s1 = try remote.stateAnnotated(arena, c1);
    try std.testing.expectEqual(@as(usize, 2), s1.items.len);
    try std.testing.expectEqual(@as(usize, 2), s1.annotations.len);
    try std.testing.expectEqualStrings("box", s1.annotations[0].kind.?);
    try std.testing.expectEqualStrings("person", s1.annotations[0].class.?);
    try std.testing.expectEqual(@as(i64, 10), s1.annotations[0].geometry.?.object.get("x").?.integer);
    try std.testing.expectEqualStrings("policy-v1", s1.annotations[0].policy_ver);

    // Nothing new → the commit is refused with a reason.
    try std.testing.expectError(error.NothingToTag, remote.commitServer(arena, "main", "empty", "agent:annotator"));

    // Batch two: move box one, delete box two.
    try db.exec("BEGIN", &diag);
    {
        const lock = try std.fmt.allocPrintSentinel(arena, "SELECT pg_advisory_xact_lock_shared(hashtextextended('{s}/main', 0))", .{ds_id}, 0);
        try db.exec(lock, &diag);
    }
    try db.exec("SET LOCAL ROLE cid_writer", &diag);
    last = cid.uuid7.Uuid.nextAfter(io, last);
    {
        const sql = try std.fmt.allocPrintSentinel(arena, "INSERT INTO annotation_revisions (rev_id, ts, dataset_id, branch, annotation_id, item_id, op, kind, class, geometry, author, policy_ver) " ++
            "VALUES ('{s}', to_timestamp({d}), '{s}', 'main', '{s}', '{s}', 'update', 'box', 'person', '{{\"x\":11,\"y\":21,\"w\":30,\"h\":40}}'::jsonb, 'user:reviewer', 'policy-v1')", .{ &last.toString(), last.unixMs() / 1000, ds_id, &ann1, &aitem1 }, 0);
        try db.exec(sql, &diag);
    }
    last = cid.uuid7.Uuid.nextAfter(io, last);
    {
        const sql = try std.fmt.allocPrintSentinel(arena, "INSERT INTO annotation_revisions (rev_id, ts, dataset_id, branch, annotation_id, item_id, op, author, policy_ver) " ++
            "VALUES ('{s}', to_timestamp({d}), '{s}', 'main', '{s}', '{s}', 'delete', 'user:reviewer', 'policy-v1')", .{ &last.toString(), last.unixMs() / 1000, ds_id, &ann2, &aitem1 }, 0);
        try db.exec(sql, &diag);
    }
    try db.exec("COMMIT", &diag);

    const c2 = try remote.commitServer(arena, "main", "review pass", "user:reviewer");
    const s2 = try remote.stateAnnotated(arena, c2);
    try std.testing.expectEqual(@as(usize, 2), s2.items.len);
    try std.testing.expectEqual(@as(usize, 1), s2.annotations.len);
    try std.testing.expectEqual(@as(i64, 11), s2.annotations[0].geometry.?.object.get("x").?.integer);
    try std.testing.expectEqualStrings("user:reviewer", s2.annotations[0].author);

    // History is history: the first commit still answers with both boxes.
    const s1_again = try remote.stateAnnotated(arena, c1);
    try std.testing.expectEqual(@as(usize, 2), s1_again.annotations.len);
    try std.testing.expectEqual(@as(i64, 10), s1_again.annotations[0].geometry.?.object.get("x").?.integer);
}

test "annotated releases: v2 manifest with JCS rows, verify catches smuggled boxes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var diag: cid.pg.Diag = .{};
    var db = try connect(&diag);
    defer db.close();
    var discard: std.Io.Writer.Discarding = .init(&.{});
    _ = try cid.migrate.run(arena, &db, &discard.writer, &diag);
    var s3c = try cid.s3.Client.init(std.testing.allocator, io, .{
        .endpoint = "http://127.0.0.1:8333",
        .access_key = "cid-test-key",
        .secret_key = "cid-test-secret",
        .bucket = "cid-test",
    });
    defer s3c.deinit();
    try s3c.createBucket(arena);

    var deps: cid.api.Deps = .{ .db = &db, .s3 = &s3c, .io = io, .token = "test-token" };
    var direct: DirectTransport = .{ .deps = &deps, .auth = "Bearer test-token" };
    const remote: cid.client.remote.Remote = .{ .t = direct.transport(), .name = "test/datasets/annrel" };

    try db.exec("SET cid.maintenance = 'on'", &diag);
    inline for (.{ "git_writes", "refs", "commits", "item_revisions", "annotation_revisions", "dataset_items" }) |table| {
        try db.exec("DELETE FROM " ++ table ++ " WHERE dataset_id IN (SELECT dataset_id FROM datasets WHERE name = 'test/datasets/annrel')", &diag);
    }
    try db.exec("DELETE FROM datasets WHERE name = 'test/datasets/annrel'", &diag);
    try db.exec("RESET cid.maintenance", &diag);

    _ = cid.api.handle(arena, &deps, "POST", "/v0/datasets", "Bearer test-token", "{\"name\":\"test/datasets/annrel\",\"kind\":\"annotated\",\"git_url\":\"g@h:ar.git\"}");
    const ds_id: [:0]const u8 = blk: {
        var rows = try db.query("SELECT dataset_id::text FROM datasets WHERE name = 'test/datasets/annrel'", &.{}, &diag);
        defer rows.deinit();
        break :blk try arena.dupeZ(u8, rows.get(0, 0));
    };

    // One image with one box, platform-style (bytes + register + revisions).
    const pix = "annrel pixels";
    var dg: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(pix, &dg, .{});
    const hh = std.fmt.bytesToHex(dg, .lower);
    try s3c.putObject(arena, try cid.api.itemKey(arena, &hh), pix);
    try remote.registerItems(arena, &.{.{ .hash = &hh, .size = pix.len }});

    var last = cid.uuid7.Uuid.now(io);
    const item_id = cid.uuid7.Uuid.now(io).toString();
    const box_id = cid.uuid7.Uuid.now(io).toString();
    try db.exec("BEGIN", &diag);
    {
        const lock = try std.fmt.allocPrintSentinel(arena, "SELECT pg_advisory_xact_lock_shared(hashtextextended('{s}/main', 0))", .{ds_id}, 0);
        try db.exec(lock, &diag);
    }
    try db.exec("SET LOCAL ROLE cid_writer", &diag);
    {
        const sql = try std.fmt.allocPrintSentinel(arena, "INSERT INTO item_revisions (rev_id, ts, dataset_id, branch, path, op, item_id, item_hash, split, author) " ++
            "VALUES ('{s}', to_timestamp({d}), '{s}', 'main', 'img/a.jpg', 'add', '{s}', decode('{s}', 'hex'), 'train', 'agent:annotator')", .{ &last.toString(), last.unixMs() / 1000, ds_id, &item_id, &hh }, 0);
        try db.exec(sql, &diag);
    }
    last = cid.uuid7.Uuid.nextAfter(io, last);
    {
        // Written messy on purpose: unsorted keys, 10.0 instead of 10.
        const sql = try std.fmt.allocPrintSentinel(arena, "INSERT INTO annotation_revisions (rev_id, ts, dataset_id, branch, annotation_id, item_id, op, kind, class, geometry, author, policy_ver) " ++
            "VALUES ('{s}', to_timestamp({d}), '{s}', 'main', '{s}', '{s}', 'create', 'box', 'person', " ++
            "'{{\"y\": 20, \"x\": 10.0, \"w\": 30.5, \"h\": 40}}'::jsonb, 'agent:annotator', 'policy-v1')", .{ &last.toString(), last.unixMs() / 1000, ds_id, &box_id, &item_id }, 0);
        try db.exec(sql, &diag);
    }
    try db.exec("COMMIT", &diag);
    _ = try remote.commitServer(arena, "main", "one box", "agent:annotator");

    // Tag: the stored manifest is version 2 with a JCS annotation row.
    const t = try remote.tag(arena, "v1.0.0");
    try std.testing.expectEqual(@as(u64, 1), t.items);
    const mkey = try cid.release.manifestKey(arena, ds_id, t.commit);
    const stored = try s3c.getObjectAlloc(arena, mkey, 1024 * 1024);
    try std.testing.expect(std.mem.startsWith(u8, stored, "cid-manifest 2\n"));
    try std.testing.expect(std.mem.indexOf(u8, stored, "item\timg/a.jpg\t") != null);
    const ann_line = try std.fmt.allocPrint(arena, "ann\t{s}\t{s}\tbox\tperson\t{{\"h\":40,\"w\":30.5,\"x\":10,\"y\":20}}\t-\tagent:annotator\tpolicy-v1\n", .{ &item_id, &box_id });
    try std.testing.expect(std.mem.indexOf(u8, stored, ann_line) != null);

    // Verify: green, repeatably.
    const v1 = try cid.release.verify(arena, &db, &s3c, ds_id, "v1.0.0");
    try std.testing.expect(v1.ok);

    // A box smuggled under the sealed cutoff turns verify red.
    const old_uuid = cid.uuid7.Uuid.init(last.unixMs() - 10_000, @splat(3));
    {
        const sql = try std.fmt.allocPrintSentinel(arena, "INSERT INTO annotation_revisions (rev_id, ts, dataset_id, branch, annotation_id, item_id, op, kind, class, geometry, author, policy_ver) " ++
            "VALUES ('{s}', to_timestamp({d}), '{s}', 'main', gen_random_uuid(), '{s}', 'create', 'box', 'smuggled', '{{\"x\":1}}'::jsonb, 'user:evil', 'policy-v1')", .{ &old_uuid.toString(), old_uuid.unixMs() / 1000, ds_id, &item_id }, 0);
        try db.exec(sql, &diag);
    }
    const v2 = try cid.release.verify(arena, &db, &s3c, ds_id, "v1.0.0");
    try std.testing.expect(!v2.ok);
    try std.testing.expectEqual(cid.release.VerifyProblem.recomputed_hash_differs, v2.problems[0]);
    try db.exec("SET cid.maintenance = 'on'", &diag);
    try db.exec("DELETE FROM annotation_revisions WHERE author = 'user:evil'", &diag);
    try db.exec("RESET cid.maintenance", &diag);
    const v3 = try cid.release.verify(arena, &db, &s3c, ds_id, "v1.0.0");
    try std.testing.expect(v3.ok);
}

test "annotated clone --format: jsonl and yolo sidecars, clean status, pull regenerates" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var diag: cid.pg.Diag = .{};
    var db = try connect(&diag);
    defer db.close();
    var discard: std.Io.Writer.Discarding = .init(&.{});
    _ = try cid.migrate.run(arena, &db, &discard.writer, &diag);
    var s3c = try cid.s3.Client.init(std.testing.allocator, io, .{
        .endpoint = "http://127.0.0.1:8333",
        .access_key = "cid-test-key",
        .secret_key = "cid-test-secret",
        .bucket = "cid-test",
    });
    defer s3c.deinit();
    try s3c.createBucket(arena);

    var deps: cid.api.Deps = .{ .db = &db, .s3 = &s3c, .io = io, .token = "test-token" };
    var direct: DirectTransport = .{ .deps = &deps, .auth = "Bearer test-token" };
    const remote: cid.client.remote.Remote = .{ .t = direct.transport(), .name = "test/datasets/fmt" };

    try db.exec("SET cid.maintenance = 'on'", &diag);
    inline for (.{ "git_writes", "refs", "commits", "item_revisions", "annotation_revisions", "dataset_items" }) |table| {
        try db.exec("DELETE FROM " ++ table ++ " WHERE dataset_id IN (SELECT dataset_id FROM datasets WHERE name = 'test/datasets/fmt')", &diag);
    }
    try db.exec("DELETE FROM datasets WHERE name = 'test/datasets/fmt'", &diag);
    try db.exec("RESET cid.maintenance", &diag);

    _ = cid.api.handle(arena, &deps, "POST", "/v0/datasets", "Bearer test-token", "{\"name\":\"test/datasets/fmt\",\"kind\":\"annotated\",\"git_url\":\"g@h:f.git\"}");
    const ds_id: [:0]const u8 = blk: {
        var rows = try db.query("SELECT dataset_id::text FROM datasets WHERE name = 'test/datasets/fmt'", &.{}, &diag);
        defer rows.deinit();
        break :blk try arena.dupeZ(u8, rows.get(0, 0));
    };

    // One 640x480 image with one person box, platform-style.
    const pix = "fmt pixels pretending to be a jpeg";
    var dg: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(pix, &dg, .{});
    const hh = std.fmt.bytesToHex(dg, .lower);
    try s3c.putObject(arena, try cid.api.itemKey(arena, &hh), pix);
    try remote.registerItems(arena, &.{.{ .hash = &hh, .size = pix.len, .media_type = "image/jpeg", .width = 640, .height = 480 }});

    var last = cid.uuid7.Uuid.now(io);
    const fitem = cid.uuid7.Uuid.now(io).toString();
    const fbox = cid.uuid7.Uuid.now(io).toString();
    try db.exec("BEGIN", &diag);
    {
        const lock = try std.fmt.allocPrintSentinel(arena, "SELECT pg_advisory_xact_lock_shared(hashtextextended('{s}/main', 0))", .{ds_id}, 0);
        try db.exec(lock, &diag);
    }
    try db.exec("SET LOCAL ROLE cid_writer", &diag);
    {
        const sql = try std.fmt.allocPrintSentinel(arena, "INSERT INTO item_revisions (rev_id, ts, dataset_id, branch, path, op, item_id, item_hash, split, author) " ++
            "VALUES ('{s}', to_timestamp({d}), '{s}', 'main', 'img/a.jpg', 'add', '{s}', decode('{s}', 'hex'), 'train', 'agent:annotator')", .{ &last.toString(), last.unixMs() / 1000, ds_id, &fitem, &hh }, 0);
        try db.exec(sql, &diag);
    }
    last = cid.uuid7.Uuid.nextAfter(io, last);
    {
        const sql = try std.fmt.allocPrintSentinel(arena, "INSERT INTO annotation_revisions (rev_id, ts, dataset_id, branch, annotation_id, item_id, op, kind, class, geometry, author, policy_ver) " ++
            "VALUES ('{s}', to_timestamp({d}), '{s}', 'main', '{s}', '{s}', 'create', 'box', 'person', '{{\"x\":32,\"y\":48,\"w\":64,\"h\":96}}'::jsonb, 'agent:annotator', 'p1')", .{ &last.toString(), last.unixMs() / 1000, ds_id, &fbox, &fitem }, 0);
        try db.exec(sql, &diag);
    }
    try db.exec("COMMIT", &diag);
    _ = try remote.commitServer(arena, "main", "one box", "agent:annotator");

    // Clone as jsonl: item file plus the sidecar, and a clean status.
    var jl_dir = std.testing.tmpDir(.{ .iterate = true });
    defer jl_dir.cleanup();
    var cache = std.testing.tmpDir(.{});
    defer cache.cleanup();
    const jl = try cid.client.sync.clone(arena, io, jl_dir.dir, cache.dir, &remote, "cid@test:test/datasets/fmt", null, "jsonl");
    try std.testing.expectEqual(@as(u32, 1), jl.files);
    try std.testing.expectEqualSlices(u8, pix, try readWholeFile(io, jl_dir.dir, "img/a.jpg", arena));
    const jl_text = try readWholeFile(io, jl_dir.dir, "annotations.jsonl", arena);
    try std.testing.expect(std.mem.indexOf(u8, jl_text, "\"path\":\"img/a.jpg\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jl_text, "\"class\":\"person\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jl_text, "\"width\":640") != null);
    var jl_ws = try cid.client.workspace.open(arena, io, jl_dir.dir);
    try std.testing.expectEqualStrings("jsonl", jl_ws.config.format);
    const jl_st = try cid.client.workspace.status(arena, io, &jl_ws);
    try std.testing.expectEqual(@as(usize, 0), jl_st.unstaged_new.len); // sidecars ignored

    // Clone as yolo: labels, classes, split list, dataset.yaml.
    var yo_dir = std.testing.tmpDir(.{ .iterate = true });
    defer yo_dir.cleanup();
    _ = try cid.client.sync.clone(arena, io, yo_dir.dir, cache.dir, &remote, "cid@test:test/datasets/fmt", null, "yolo");
    try std.testing.expectEqualStrings("person\n", try readWholeFile(io, yo_dir.dir, "classes.txt", arena));
    try std.testing.expectEqualStrings(
        "0 0.100000 0.200000 0.100000 0.200000\n",
        try readWholeFile(io, yo_dir.dir, "labels/img/a.txt", arena),
    );
    try std.testing.expectEqualStrings("img/a.jpg\n", try readWholeFile(io, yo_dir.dir, "train.txt", arena));
    const yaml = try readWholeFile(io, yo_dir.dir, "dataset.yaml", arena);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "0: person") != null);

    // The platform adds a vehicle box; a pull regenerates the sidecars.
    try db.exec("BEGIN", &diag);
    {
        const lock = try std.fmt.allocPrintSentinel(arena, "SELECT pg_advisory_xact_lock_shared(hashtextextended('{s}/main', 0))", .{ds_id}, 0);
        try db.exec(lock, &diag);
    }
    try db.exec("SET LOCAL ROLE cid_writer", &diag);
    last = cid.uuid7.Uuid.nextAfter(io, last);
    {
        const sql = try std.fmt.allocPrintSentinel(arena, "INSERT INTO annotation_revisions (rev_id, ts, dataset_id, branch, annotation_id, item_id, op, kind, class, geometry, author, policy_ver) " ++
            "VALUES ('{s}', to_timestamp({d}), '{s}', 'main', gen_random_uuid(), '{s}', 'create', 'box', 'vehicle', '{{\"x\":0,\"y\":0,\"w\":320,\"h\":240}}'::jsonb, 'agent:annotator', 'p1')", .{ &last.toString(), last.unixMs() / 1000, ds_id, &fitem }, 0);
        try db.exec(sql, &diag);
    }
    try db.exec("COMMIT", &diag);
    _ = try remote.commitServer(arena, "main", "vehicle too", "agent:annotator");

    var yo_ws = try cid.client.workspace.open(arena, io, yo_dir.dir);
    const pulled = try cid.client.sync.pull(arena, io, &yo_ws, cache.dir, &remote);
    try std.testing.expect(pulled == .fast_forwarded);
    try std.testing.expectEqualStrings("person\nvehicle\n", try readWholeFile(io, yo_dir.dir, "classes.txt", arena));
    const label2 = try readWholeFile(io, yo_dir.dir, "labels/img/a.txt", arena);
    try std.testing.expect(std.mem.indexOf(u8, label2, "1 0.250000 0.250000 0.500000 0.500000") != null);
}
