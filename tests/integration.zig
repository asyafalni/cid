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

/// The fixture pool each test drives its raw setup SQL through.
fn openFixture(standalone: *cid.db.Standalone) !void {
    standalone.open(std.testing.allocator, conninfo) catch |err| {
        std.debug.print(
            "cid integration: TimescaleDB is not reachable ({t}). " ++
                "Run 'docker compose -f docker-compose.test.yml up -d' first.\n",
            .{err},
        );
        return err;
    };
    standalone.db.watching(stashProblem);
}

// nilo's statement watcher is a plain function pointer, and the suite is
// serial, so the last failure's words land here for expectRefused.
var problem_buf: [1024]u8 = undefined;
var problem_len: usize = 0;

fn stashProblem(sent: cid.db.sql.Sent) void {
    const p = sent.problem orelse return;
    const n = @min(p.message.len, problem_buf.len);
    @memcpy(problem_buf[0..n], p.message[0..n]);
    problem_len = n;
}

/// Migrations now run through nilo_sql (its own pool, opened and closed
/// here), while the rest of a test still talks libpq until its module is
/// ported. Two drivers, one database, no interference.
fn runMigrations() !cid.migrate.Summary {
    var standalone: cid.db.Standalone = undefined;
    try standalone.open(std.testing.allocator, conninfo);
    defer standalone.close();
    var scope = cid.db.Run.init(std.testing.allocator);
    defer scope.deinit();
    var discard: std.Io.Writer.Discarding = .init(&.{});
    return cid.migrate.run(&standalone.db, &scope, &discard.writer);
}

/// The blob store, opened on the test's io and started at once: cid's
/// S3 goes through nilo_s3, and the 'cid' bucket is created by
/// docker-compose.test.yml (bucket creation is the deployment's job).
fn openBlobs(client: *cid.blob.Client, io: std.Io) !void {
    try client.open(std.testing.allocator, .{
        .endpoint = "http://127.0.0.1:8333",
        .access_key = "cid-test-key",
        .secret_key = "cid-test-secret",
    });
    try client.start(io);
}

fn expectRefused(db: anytype, scope: anytype, sql: []const u8, needle: []const u8) !void {
    problem_len = 0;
    if (db.exec(scope, sql, .{})) |_| {
        std.debug.print("expected '{s}' to be refused\n", .{sql});
        return error.NotRefused;
    } else |_| {}
    if (std.mem.indexOf(u8, problem_buf[0..problem_len], needle) == null) {
        std.debug.print("expected error about '{s}', got: {s}\n", .{ needle, problem_buf[0..problem_len] });
        return error.WrongError;
    }
}

/// A stand-in GitLab: answers each request with the next canned reply and
/// keeps the request lines it was asked, on a port of its own.
const FakeGitLab = struct {
    const Reply = struct { status: []const u8, body: []const u8 };
    server: std.Io.net.Server,
    replies: []const Reply,
    asked: [4][256]u8 = undefined,
    asked_len: [4]usize = @splat(0),
    thread: std.Thread = undefined,

    fn start(self: *FakeGitLab, io: std.Io) !u16 {
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        self.server = try addr.listen(io, .{ .reuse_address = true });
        self.thread = try std.Thread.spawn(.{}, serve, .{ self, io });
        return self.server.socket.address.getPort();
    }

    fn serve(self: *FakeGitLab, io: std.Io) void {
        for (self.replies, 0..) |reply, i| {
            var stream = self.server.accept(io) catch return;
            defer stream.close(io);
            var rbuf: [4096]u8 = undefined;
            var r = stream.reader(io, &rbuf);
            const line = r.interface.takeDelimiterExclusive('\n') catch return;
            const n = @min(line.len, self.asked[i].len);
            @memcpy(self.asked[i][0..n], line[0..n]);
            self.asked_len[i] = n;
            while (true) {
                const h = r.interface.takeDelimiterExclusive('\n') catch return;
                if (std.mem.trim(u8, h, "\r").len == 0) break;
            }
            var wbuf: [4096]u8 = undefined;
            var w = stream.writer(io, &wbuf);
            w.interface.print("HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ reply.status, reply.body.len, reply.body }) catch return;
            w.interface.flush() catch return;
        }
    }

    fn stop(self: *FakeGitLab, io: std.Io) void {
        self.thread.join();
        self.server.deinit(io);
    }

    fn request(self: *const FakeGitLab, i: usize) []const u8 {
        return self.asked[i][0..self.asked_len[i]];
    }
};

test "init's branch-protection warning: GitLab asked about main, other hosts noted" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var fixture: cid.db.Standalone = undefined;
    try openFixture(&fixture);
    defer fixture.close();
    var fscope = cid.db.Run.init(std.testing.allocator);
    defer fscope.deinit();
    const db = &fixture.db;
    _ = try runMigrations();

    var s3c: cid.blob.Client = undefined;
    try openBlobs(&s3c, io);
    defer s3c.deinit();
    var standalone: cid.db.Standalone = undefined;
    try standalone.open(std.testing.allocator, conninfo);
    defer standalone.close();
    var scope = cid.db.Run.init(std.testing.allocator);
    defer scope.deinit();

    var fake: FakeGitLab = .{ .server = undefined, .replies = &.{
        .{ .status = "404 Not Found", .body = "{\"message\":\"404 Not found\"}" },
        .{ .status = "200 OK", .body = "{\"name\":\"main\",\"push_access_levels\":[{\"access_level\":40}],\"allow_force_push\":false}" },
    } };
    const port = try fake.start(io);
    var deps: cid.api.Deps = .{
        .db = &standalone.db,
        .s3 = &s3c,
        .io = io,
        .gpa = std.testing.allocator,
        .token = "test-token",
        .gitlab = .{ .base_url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{port}), .token = "t" },
    };

    _ = try db.exec(&fscope, "DELETE FROM datasets WHERE name LIKE 'test/datasets/protect-%'", .{});
    const Made = struct { warnings: []const []const u8 };
    const cases = .{
        .{ "test/datasets/protect-open", "git@127.0.0.1:org/datasets/open.git", "main is not protected" },
        .{ "test/datasets/protect-shut", "ssh://git@127.0.0.1/org/datasets/shut.git", "" },
        .{ "test/datasets/protect-elsewhere", "git@github.com:org/x.git", "cannot check branch protection on github.com" },
    };
    inline for (cases) |c| {
        const body = try std.fmt.allocPrint(arena, "{{\"name\":\"{s}\",\"git_url\":\"{s}\"}}", .{ c[0], c[1] });
        const res = cid.api.handle(arena, &deps, &scope, "POST", "/v0/datasets", "Bearer test-token", body);
        try std.testing.expectEqual(std.http.Status.created, res.status);
        const made = try std.json.parseFromSliceLeaky(Made, arena, res.body, .{ .ignore_unknown_fields = true });
        if (c[2].len == 0) {
            try std.testing.expectEqual(@as(usize, 0), made.warnings.len);
        } else {
            try std.testing.expectEqual(@as(usize, 1), made.warnings.len);
            try std.testing.expect(std.mem.indexOf(u8, made.warnings[0], c[2]) != null);
        }
    }
    fake.stop(io);
    // GitLab was asked exactly about each project's main, by its path.
    try std.testing.expect(std.mem.startsWith(u8, fake.request(0), "GET /api/v4/projects/org%2Fdatasets%2Fopen/protected_branches/main "));
    try std.testing.expect(std.mem.startsWith(u8, fake.request(1), "GET /api/v4/projects/org%2Fdatasets%2Fshut/protected_branches/main "));
    _ = try db.exec(&fscope, "DELETE FROM datasets WHERE name LIKE 'test/datasets/protect-%'", .{});
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

    var s3: cid.blob.Client = undefined;
    try openBlobs(&s3, io);
    defer s3.deinit();
    var scope = cid.db.Run.init(std.testing.allocator);
    defer scope.deinit();

    const key = "items/blake3/ab/abcd-test-object";
    const body = "cid stores any bytes \x00\x01\x02 exactly";

    try std.testing.expectEqual(@as(?u64, null), try s3.headObject(&scope, "items/missing"));
    try std.testing.expectError(error.NotFound, s3.getObjectAlloc(&scope, "items/missing"));

    try s3.putObject(&scope, key, body);
    const got = try s3.getObjectAlloc(&scope, key);
    try std.testing.expectEqualSlices(u8, body, got);

    // Presigned GET works with a plain HTTP client and no credentials.
    const url = try s3.presignGet(&scope, key, 300);
    var plain: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    defer plain.deinit();
    var aw: std.Io.Writer.Allocating = .init(arena);
    const res = try plain.fetch(.{ .location = .{ .url = url }, .raw_uri = true, .keep_alive = false, .response_writer = &aw.writer });
    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualSlices(u8, body, aw.writer.buffered());

    try s3.deleteObject(&scope, key);
    try std.testing.expectEqual(@as(?u64, null), try s3.headObject(&scope, key));
}

test "migrations apply from scratch and are idempotent" {
    var fixture: cid.db.Standalone = undefined;
    try openFixture(&fixture);
    defer fixture.close();
    var fscope = cid.db.Run.init(std.testing.allocator);
    defer fscope.deinit();
    const db = &fixture.db;

    _ = try db.exec(&fscope, "DROP SCHEMA public CASCADE; CREATE SCHEMA public", .{});

    const first = try runMigrations();
    try std.testing.expect(first.total >= 1);
    try std.testing.expectEqual(first.total, first.applied);

    const second = try runMigrations();
    try std.testing.expectEqual(@as(u32, 0), second.applied);

    const versions = try db.rawExactlyOne(i64, &fscope, "SELECT count(*) FROM schema_migrations", .{});
    try std.testing.expectEqual(@as(i64, @intCast(first.total)), versions);
}

test "api: create, check-hashes, push (forward-only), state, downloads, log" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var fixture: cid.db.Standalone = undefined;
    try openFixture(&fixture);
    defer fixture.close();
    var fscope = cid.db.Run.init(std.testing.allocator);
    defer fscope.deinit();
    const db = &fixture.db;
    _ = try runMigrations();

    var s3c: cid.blob.Client = undefined;
    try openBlobs(&s3c, io);
    defer s3c.deinit();

    var standalone: cid.db.Standalone = undefined;
    try standalone.open(std.testing.allocator, conninfo);
    defer standalone.close();
    var scope = cid.db.Run.init(std.testing.allocator);
    defer scope.deinit();
    var deps: cid.api.Deps = .{ .db = &standalone.db, .s3 = &s3c, .io = io, .gpa = std.testing.allocator, .token = "test-token" };
    const name = "test/datasets/api";

    // Leftovers from earlier runs go through the maintenance escape.
    _ = try db.exec(&fscope, "SET cid.maintenance = 'on'", .{});
    _ = try db.exec(&fscope, "DELETE FROM refs WHERE dataset_id IN (SELECT dataset_id FROM datasets WHERE name = 'test/datasets/api')", .{});
    _ = try db.exec(&fscope, "DELETE FROM commits WHERE dataset_id IN (SELECT dataset_id FROM datasets WHERE name = 'test/datasets/api')", .{});
    _ = try db.exec(&fscope, "DELETE FROM item_revisions WHERE dataset_id IN (SELECT dataset_id FROM datasets WHERE name = 'test/datasets/api')", .{});
    _ = try db.exec(&fscope, "DELETE FROM dataset_items WHERE dataset_id IN (SELECT dataset_id FROM datasets WHERE name = 'test/datasets/api')", .{});
    _ = try db.exec(&fscope, "DELETE FROM datasets WHERE name = 'test/datasets/api'", .{});
    _ = try db.exec(&fscope, "RESET cid.maintenance", .{});

    // Auth is checked before anything else.
    const unauth = cid.api.handle(arena, &deps, &scope, "GET", "/v0/datasets/x/-/head", "Bearer wrong", "");
    try std.testing.expectEqual(std.http.Status.unauthorized, unauth.status);

    // Create the dataset.
    const created = cid.api.handle(arena, &deps, &scope, "POST", "/v0/datasets", "Bearer test-token", "{\"name\":\"test/datasets/api\",\"git_url\":\"git@example.invalid:d.git\"}");
    try std.testing.expectEqual(std.http.Status.created, created.status);
    const again = cid.api.handle(arena, &deps, &scope, "POST", "/v0/datasets", "Bearer test-token", "{\"name\":\"test/datasets/api\",\"git_url\":\"git@example.invalid:d.git\"}");
    try std.testing.expectEqual(std.http.Status.conflict, again.status);

    // Two contents; their hex hashes.
    const content_a = "api test content A";
    const content_b = "api test content B, longer";
    var dg: [32]u8 = undefined;
    cid.hash.Hasher.hash(content_a, &dg, .{});
    const hash_a = std.fmt.bytesToHex(dg, .lower);
    cid.hash.Hasher.hash(content_b, &dg, .{});
    const hash_b = std.fmt.bytesToHex(dg, .lower);

    // Earlier runs may have uploaded these; start from a clean slate.
    try s3c.deleteObject(&scope, try cid.api.itemKey(arena, &hash_a));
    try s3c.deleteObject(&scope, try cid.api.itemKey(arena, &hash_b));

    // check-hashes says both are missing and hands out presigned PUTs.
    const check_body = try std.fmt.allocPrint(arena, "{{\"hashes\":[\"{s}\",\"{s}\"]}}", .{ &hash_a, &hash_b });
    const check1 = cid.api.handle(arena, &deps, &scope, "POST", "/v0/datasets/" ++ name ++ "/-/check-hashes", "Bearer test-token", check_body);
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
    const check2 = cid.api.handle(arena, &deps, &scope, "POST", "/v0/datasets/" ++ name ++ "/-/check-hashes", "Bearer test-token", check_body);
    const check2_parsed = try std.json.parseFromSliceLeaky(Check, arena, check2.body, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 1), check2_parsed.missing.len);
    try std.testing.expectEqualStrings(&hash_b, check2_parsed.missing[0].hash);

    // First push: one commit adding a.txt (content A, already uploaded).
    const id1 = cid.uuid7.Uuid.now(io).toString();
    const push1_body = try std.fmt.allocPrint(arena,
        \\{{"branch":"main","commits":[{{"id":"{s}","parent":null,"message":"first","author":"user:test","authored_at_ms":1760000000000,"changes":[{{"op":"add","path":"a.txt","hash":"{s}","size":18}}]}}]}}
    , .{ &id1, &hash_a });
    const push1 = cid.api.handle(arena, &deps, &scope, "POST", "/v0/datasets/" ++ name ++ "/-/push", "Bearer test-token", push1_body);
    try std.testing.expectEqual(std.http.Status.ok, push1.status);

    // A second root push is stale: forward-only refuses it with the pull hint.
    const id_stale = cid.uuid7.Uuid.now(io).toString();
    const stale_body = try std.fmt.allocPrint(arena,
        \\{{"branch":"main","commits":[{{"id":"{s}","parent":null,"message":"stale","author":"user:test","authored_at_ms":1760000000000,"changes":[{{"op":"add","path":"a.txt","hash":"{s}","size":18}}]}}]}}
    , .{ &id_stale, &hash_a });
    const stale = cid.api.handle(arena, &deps, &scope, "POST", "/v0/datasets/" ++ name ++ "/-/push", "Bearer test-token", stale_body);
    try std.testing.expectEqual(std.http.Status.conflict, stale.status);
    try std.testing.expect(std.mem.indexOf(u8, stale.body, "cid pull") != null);

    // Pushing content that is not in storage is refused before anything lands.
    const id2 = cid.uuid7.Uuid.now(io).toString();
    const push2_body = try std.fmt.allocPrint(arena,
        \\{{"branch":"main","commits":[{{"id":"{s}","parent":"{s}","message":"second","author":"user:test","authored_at_ms":1760000001000,"changes":[{{"op":"add","path":"b.txt","hash":"{s}","size":26}},{{"op":"delete","path":"a.txt"}}]}}]}}
    , .{ &id2, &id1, &hash_b });
    const missing = cid.api.handle(arena, &deps, &scope, "POST", "/v0/datasets/" ++ name ++ "/-/push", "Bearer test-token", push2_body);
    try std.testing.expectEqual(std.http.Status.unprocessable_entity, missing.status);

    // Upload B, retry: same body now lands.
    const api_id = (try db.rawOne([]const u8, &fscope, "SELECT dataset_id::text FROM datasets WHERE name = 'test/datasets/api'", .{})).?;
    const key_b = try cid.api.stagedKey(arena, api_id, &hash_b);
    try s3c.putObject(&scope, key_b, content_b);
    const push2 = cid.api.handle(arena, &deps, &scope, "POST", "/v0/datasets/" ++ name ++ "/-/push", "Bearer test-token", push2_body);
    try std.testing.expectEqual(std.http.Status.ok, push2.status);

    // Another dataset is never told the server holds B (invariant 12), and
    // bytes staged under B's hash that are not B are refused at push, the
    // stored B untouched (invariant 2).
    {
        _ = try db.exec(&fscope, "SET cid.maintenance = 'on'", .{});
        inline for (.{ "refs", "commits", "item_revisions", "dataset_items" }) |table| {
            _ = try db.exec(&fscope, "DELETE FROM " ++ table ++ " WHERE dataset_id IN (SELECT dataset_id FROM datasets WHERE name = 'test/datasets/api-other')", .{});
        }
        _ = try db.exec(&fscope, "DELETE FROM datasets WHERE name = 'test/datasets/api-other'", .{});
        _ = try db.exec(&fscope, "RESET cid.maintenance", .{});
        const other = cid.api.handle(arena, &deps, &scope, "POST", "/v0/datasets", "Bearer test-token", "{\"name\":\"test/datasets/api-other\",\"git_url\":\"git@example.invalid:o.git\"}");
        try std.testing.expectEqual(std.http.Status.created, other.status);
        const other_id = (try db.rawOne([]const u8, &fscope, "SELECT dataset_id::text FROM datasets WHERE name = 'test/datasets/api-other'", .{})).?;

        const ask_b = try std.fmt.allocPrint(arena, "{{\"hashes\":[\"{s}\"]}}", .{&hash_b});
        const check_other = cid.api.handle(arena, &deps, &scope, "POST", "/v0/datasets/test/datasets/api-other/-/check-hashes", "Bearer test-token", ask_b);
        try std.testing.expectEqual(std.http.Status.ok, check_other.status);
        const other_parsed = try std.json.parseFromSliceLeaky(Check, arena, check_other.body, .{ .ignore_unknown_fields = true });
        try std.testing.expectEqual(@as(usize, 1), other_parsed.missing.len);

        const forged = "not content B at all......";
        try s3c.putObject(&scope, try cid.api.stagedKey(arena, other_id, &hash_b), forged);
        const id_f = cid.uuid7.Uuid.now(io).toString();
        const forged_body = try std.fmt.allocPrint(arena,
            \\{{"branch":"main","commits":[{{"id":"{s}","parent":null,"message":"forged","author":"user:test","authored_at_ms":1760000002000,"changes":[{{"op":"add","path":"b.txt","hash":"{s}","size":26}}]}}]}}
        , .{ &id_f, &hash_b });
        const refused = cid.api.handle(arena, &deps, &scope, "POST", "/v0/datasets/test/datasets/api-other/-/push", "Bearer test-token", forged_body);
        try std.testing.expectEqual(std.http.Status.unprocessable_entity, refused.status);
        try std.testing.expect(std.mem.indexOf(u8, refused.body, "does not match") != null);
        const kept = try s3c.getObjectAlloc(&scope, try cid.api.itemKey(arena, &hash_b));
        try std.testing.expectEqualStrings(content_b, kept);
        const heads = try db.rawOne(i64, &fscope, "SELECT count(*)::bigint FROM commits WHERE dataset_id = $1::uuid", .{other_id});
        try std.testing.expectEqual(@as(?i64, 0), heads);
    }

    // head and state: only b.txt remains after the delete.
    const head_res = cid.api.handle(arena, &deps, &scope, "GET", "/v0/datasets/" ++ name ++ "/-/head?branch=main", "Bearer test-token", "");
    const Head = struct { commit: ?[]const u8 };
    const head_parsed = try std.json.parseFromSliceLeaky(Head, arena, head_res.body, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqualStrings(&id2, head_parsed.commit.?);

    // Both pushes queued their head for the background worker. By its turn
    // the first is no longer a head: skipped. The second is prepared — its
    // statistics, browse index and items file, before anyone asks.
    {
        var prep_tmp = std.testing.tmpDir(.{});
        defer prep_tmp.cleanup();
        deps.browse_dir = try prep_tmp.dir.realPathFileAlloc(io, ".", arena);
        while (try cid.api.prepareNext(arena, &deps, &scope)) {}
        const Job = struct {
            pub const nilo_table = .projection;
            status: []const u8,
        };
        const first_job = (try db.rawOne(Job, &fscope, "SELECT status FROM version_jobs WHERE commit_id = $1::uuid", .{@as([]const u8, &id1)})).?;
        try std.testing.expectEqualStrings("skipped", first_job.status);
        const head_job = (try db.rawOne(Job, &fscope, "SELECT status FROM version_jobs WHERE commit_id = $1::uuid", .{@as([]const u8, &id2)})).?;
        try std.testing.expectEqualStrings("done", head_job.status);
        try std.testing.expect((try db.rawOne([]const u8, &fscope, "SELECT stats::text FROM commits WHERE commit_id = $1::uuid AND stats IS NOT NULL", .{@as([]const u8, &id2)})) != null);
        try std.testing.expect((try db.rawOne(i64, &fscope, "SELECT 1::bigint FROM version_files WHERE commit_id = $1::uuid AND kind = 'state'", .{@as([]const u8, &id2)})) != null);
        const index = try std.fmt.allocPrint(arena, "{s}.items.parquet", .{&id2});
        _ = try prep_tmp.dir.statFile(io, index, .{});
        deps.browse_dir = "/tmp/cid-browse";
    }

    // The version as the CLI reads it: a file in storage, hash-checked.
    var direct: DirectTransport = .{ .deps = &deps, .scope = &scope, .auth = "Bearer test-token" };
    const remote: cid.client.remote.Remote = .{ .t = direct.transport(), .name = name, .gpa = std.testing.allocator };
    const items2 = try remote.state(arena, &id2);
    try std.testing.expectEqual(@as(usize, 1), items2.len);
    try std.testing.expectEqualStrings("b.txt", items2[0].path);
    try std.testing.expectEqualStrings(&hash_b, items2[0].hash);
    try std.testing.expectEqual(@as(u64, 26), items2[0].size);

    // State at the first commit still shows a.txt: history is intact.
    const items1 = try remote.state(arena, &id1);
    try std.testing.expectEqual(@as(usize, 1), items1.len);
    try std.testing.expectEqualStrings("a.txt", items1[0].path);

    // downloads: a presigned GET for B round-trips the bytes.
    const dl_body = try std.fmt.allocPrint(arena, "{{\"hashes\":[\"{s}\"]}}", .{&hash_b});
    const dl = cid.api.handle(arena, &deps, &scope, "POST", "/v0/datasets/" ++ name ++ "/-/downloads", "Bearer test-token", dl_body);
    const Dl = struct { downloads: []const struct { hash: []const u8, url: []const u8 } };
    const dl_parsed = try std.json.parseFromSliceLeaky(Dl, arena, dl.body, .{ .ignore_unknown_fields = true });
    var aw: std.Io.Writer.Allocating = .init(arena);
    const got = try plain.fetch(.{ .location = .{ .url = dl_parsed.downloads[0].url }, .raw_uri = true, .keep_alive = false, .response_writer = &aw.writer });
    try std.testing.expectEqual(std.http.Status.ok, got.status);
    try std.testing.expectEqualSlices(u8, content_b, aw.writer.buffered());

    // log: both commits, newest first.
    const log_res = cid.api.handle(arena, &deps, &scope, "GET", "/v0/datasets/" ++ name ++ "/-/log?branch=main", "Bearer test-token", "");
    const Log = struct { commits: []const struct { id: []const u8, parent: ?[]const u8, message: []const u8, author: []const u8, authored_at_ms: u64 } };
    const log_parsed = try std.json.parseFromSliceLeaky(Log, arena, log_res.body, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 2), log_parsed.commits.len);
    try std.testing.expectEqualStrings("second", log_parsed.commits[0].message);
    try std.testing.expectEqualStrings(&id1, log_parsed.commits[0].parent.?);
}

test "append-only history and immovable releases, enforced by the database" {
    var fixture: cid.db.Standalone = undefined;
    try openFixture(&fixture);
    defer fixture.close();
    var fscope = cid.db.Run.init(std.testing.allocator);
    defer fscope.deinit();
    const db = &fixture.db;

    // Make sure the schema exists (idempotent), then remove this test's
    // leftovers through the maintenance escape hatch.
    _ = try runMigrations();
    _ = try db.exec(&fscope, "SET cid.maintenance = 'on'", .{});
    _ = try db.exec(&fscope, "DELETE FROM refs WHERE dataset_id = '" ++ ds ++ "'", .{});
    _ = try db.exec(&fscope, "DELETE FROM commits WHERE dataset_id = '" ++ ds ++ "'", .{});
    _ = try db.exec(&fscope, "DELETE FROM item_revisions WHERE dataset_id = '" ++ ds ++ "'", .{});
    _ = try db.exec(&fscope, "DELETE FROM datasets WHERE dataset_id = '" ++ ds ++ "'", .{});
    _ = try db.exec(&fscope, "RESET cid.maintenance", .{});

    _ = try db.exec(&fscope, "INSERT INTO datasets (dataset_id, name, kind, git_url) VALUES ('" ++ ds ++
        "', 'test/datasets/invariants', 'files', 'git@example.invalid:d.git')", .{});
    _ = try db.exec(&fscope, "INSERT INTO item_revisions (rev_id, ts, dataset_id, path, op, item_id, item_hash, author) " ++
        "VALUES ('" ++ rev1 ++ "', now(), '" ++ ds ++ "', 'a.txt', 'add', '" ++ item1 ++
        "', decode(repeat('ab', 32), 'hex'), 'user:test')", .{});

    // Invariant 1: revision history is append-only.
    try expectRefused(db, &fscope, "UPDATE item_revisions SET author = 'evil' WHERE dataset_id = '" ++ ds ++ "'", "append-only");
    try expectRefused(db, &fscope, "DELETE FROM item_revisions WHERE dataset_id = '" ++ ds ++ "'", "append-only");

    // Invariant 5: releases never move; branches may.
    _ = try db.exec(&fscope, "INSERT INTO commits (commit_id, dataset_id, branch, cutoff_rev, message, author, authored_at) " ++
        "VALUES ('" ++ commit1 ++ "', '" ++ ds ++ "', 'main', '" ++ rev1 ++ "', 'first', 'user:test', now())", .{});
    _ = try db.exec(&fscope, "INSERT INTO refs (dataset_id, name, kind, commit_id) VALUES ('" ++ ds ++
        "', 'v1.0.0', 'release', '" ++ commit1 ++ "')", .{});
    try expectRefused(db, &fscope, "UPDATE refs SET commit_id = '" ++ commit1 ++ "' WHERE dataset_id = '" ++ ds ++
        "' AND name = 'v1.0.0'", "never moves");
    try expectRefused(db, &fscope, "DELETE FROM refs WHERE dataset_id = '" ++ ds ++ "' AND name = 'v1.0.0'", "never moves");
    _ = try db.exec(&fscope, "INSERT INTO refs (dataset_id, name, kind, commit_id) VALUES ('" ++ ds ++
        "', 'main', 'branch', '" ++ commit1 ++ "')", .{});
    _ = try db.exec(&fscope, "UPDATE refs SET commit_id = '" ++ commit1 ++ "' WHERE dataset_id = '" ++ ds ++
        "' AND name = 'main'", .{});

    // The platform's role can INSERT revisions and nothing else.
    {
        var ptx = try db.begin(&fscope, .{});
        defer ptx.deinit();
        try platformWrite(&ptx, &fscope, ds);
        _ = try ptx.exec(&fscope, "INSERT INTO item_revisions (dataset_id, path, op, item_id, item_hash, author) " ++
            "VALUES ('" ++ ds ++ "', 'b.txt', 'add', '018e0000-0000-7000-8000-00000000b002', decode(repeat('cd', 32), 'hex'), 'agent:annotator')", .{});
        try ptx.commit();
    }
    // A batch carries its key: retrying one that already committed (its
    // acknowledgement lost) fails on the key, and nothing lands twice.
    inline for (0..2) |attempt| {
        var ptx = try db.begin(&fscope, .{});
        defer ptx.deinit();
        try platformWrite(&ptx, &fscope, ds);
        if (attempt == 0) {
            _ = try ptx.exec(&fscope, "INSERT INTO revision_batches (dataset_id, batch_key) VALUES ('" ++ ds ++ "', 'import-0001')", .{});
            _ = try ptx.exec(&fscope, "INSERT INTO item_revisions (dataset_id, path, op, item_id, item_hash, author) " ++
                "VALUES ('" ++ ds ++ "', 'batch.txt', 'add', gen_random_uuid(), decode(repeat('cd', 32), 'hex'), 'agent:import')", .{});
            try ptx.commit();
        } else {
            try expectRefused(&ptx, &fscope, "INSERT INTO revision_batches (dataset_id, batch_key) VALUES ('" ++ ds ++ "', 'import-0001')", "duplicate key");
        }
    }
    const batch_rows = try db.rawOne(i64, &fscope, "SELECT count(*)::bigint FROM item_revisions WHERE dataset_id = '" ++ ds ++ "' AND path = 'batch.txt'", .{});
    try std.testing.expectEqual(@as(?i64, 1), batch_rows);

    // …and nothing else: not its own revision id (the database's clock
    // decides, invariant 3), not history, not datasets. Each refusal in a
    // transaction of its own, as the role.
    inline for (.{
        "INSERT INTO item_revisions (rev_id, dataset_id, path, op, item_id, item_hash, author) VALUES " ++
            "('018e0000-0000-7000-8000-00000000a003', '" ++ ds ++ "', 'c.txt', 'add', '018e0000-0000-7000-8000-00000000b003', decode(repeat('cd', 32), 'hex'), 'agent:annotator')",
        "INSERT INTO item_revisions (ts, dataset_id, path, op, item_id, item_hash, author) VALUES " ++
            "(now() - interval '1 day', '" ++ ds ++ "', 'c.txt', 'add', '018e0000-0000-7000-8000-00000000b003', decode(repeat('cd', 32), 'hex'), 'agent:annotator')",
        "UPDATE item_revisions SET author = 'evil' WHERE dataset_id = '" ++ ds ++ "'",
        "INSERT INTO datasets (dataset_id, name, kind, git_url) VALUES (gen_random_uuid(), 'x/y', 'files', 'g')",
    }) |sql| {
        var ptx = try db.begin(&fscope, .{});
        defer ptx.deinit();
        try platformWrite(&ptx, &fscope, ds);
        try expectRefused(&ptx, &fscope, sql, "permission denied");
    }
}

// ---------------------------------------------------------------------------
// The milestone test: the whole file-dataset round trip through sync,
// with the server's handlers plugged in as the transport (no sockets;
// content still rides real presigned URLs against live SeaweedFS).
// ---------------------------------------------------------------------------

/// A platform-style write, exactly the documented contract: one
/// transaction, the branch's shared write lock, the cid_writer role (which
/// cannot set rev_id or ts: the database mints them).
fn platformWrite(tx: anytype, scope: anytype, dataset_id: []const u8) !void {
    _ = try tx.exec(scope, "SELECT pg_advisory_xact_lock_shared(hashtextextended($1 || '/main', 0))", .{dataset_id});
    _ = try tx.exec(scope, "SET LOCAL ROLE cid_writer", .{});
}

const DirectTransport = struct {
    deps: *cid.api.Deps,
    scope: *cid.db.Run,
    auth: []const u8,
    /// The connection drops as the push is being recorded: a push killed
    /// after its uploads, before the server took its commits.
    cut_push: bool = false,

    fn transport(self: *DirectTransport) cid.client.remote.Transport {
        return .{ .ctx = self, .call_fn = call, .get_url_fn = getUrl };
    }

    fn getUrl(ctx: *anyopaque, url: []const u8, reader: cid.client.remote.BodyReader) anyerror!void {
        const self: *DirectTransport = @ptrCast(@alignCast(ctx));
        var http: std.http.Client = .{ .allocator = std.testing.allocator, .io = self.deps.io };
        defer http.deinit();
        return cid.client.remote.readUrl(&http, url, reader);
    }

    fn call(
        ctx: *anyopaque,
        arena: std.mem.Allocator,
        method: []const u8,
        target: []const u8,
        body: []const u8,
    ) anyerror!cid.client.remote.Response {
        const self: *DirectTransport = @ptrCast(@alignCast(ctx));
        if (self.cut_push and std.mem.endsWith(u8, target, "/-/push")) return error.ConnectionResetByPeer;
        const r = cid.api.handle(arena, self.deps, self.scope, method, target, self.auth, body);
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

    var fixture: cid.db.Standalone = undefined;
    try openFixture(&fixture);
    defer fixture.close();
    var fscope = cid.db.Run.init(std.testing.allocator);
    defer fscope.deinit();
    const db = &fixture.db;
    _ = try runMigrations();

    var s3c: cid.blob.Client = undefined;
    try openBlobs(&s3c, io);
    defer s3c.deinit();

    var standalone: cid.db.Standalone = undefined;
    try standalone.open(std.testing.allocator, conninfo);
    defer standalone.close();
    var scope = cid.db.Run.init(std.testing.allocator);
    defer scope.deinit();
    var deps: cid.api.Deps = .{ .db = &standalone.db, .s3 = &s3c, .io = io, .gpa = std.testing.allocator, .token = "test-token" };
    var direct: DirectTransport = .{ .deps = &deps, .scope = &scope, .auth = "Bearer test-token" };
    const remote: cid.client.remote.Remote = .{ .t = direct.transport(), .name = "test/datasets/sync", .gpa = std.testing.allocator };

    // Earlier runs may have uploaded this test's contents; purge them so
    // upload counts are exact.
    inline for (.{ "version one of a\n", "\x00\x01\x02\xff binary", "version TWO of a\n", "the new file c\n", "my local edit", "d" }) |content| {
        var content_digest: [32]u8 = undefined;
        cid.hash.Hasher.hash(content, &content_digest, .{});
        const content_hex = std.fmt.bytesToHex(content_digest, .lower);
        try s3c.deleteObject(&scope, try cid.api.itemKey(arena, &content_hex));
    }

    // Clean slate for this dataset.
    _ = try db.exec(&fscope, "SET cid.maintenance = 'on'", .{});
    inline for (.{ "refs", "commits", "item_revisions", "dataset_items" }) |table| {
        _ = try db.exec(&fscope, "DELETE FROM " ++ table ++ " WHERE dataset_id IN (SELECT dataset_id FROM datasets WHERE name = 'test/datasets/sync')", .{});
    }
    _ = try db.exec(&fscope, "DELETE FROM datasets WHERE name = 'test/datasets/sync'", .{});
    _ = try db.exec(&fscope, "RESET cid.maintenance", .{});

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
    const cloned = try cid.client.sync.clone(arena, io, reader_dir.dir, reader_cache.dir, &remote, "cid@test:test/datasets/sync", null, null, .{});
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

/// The folder holds exactly these files (ignoring .cid/), byte for byte.
fn expectTree(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, want: []const [2][]const u8) !void {
    var walker = try dir.walk(arena);
    defer walker.deinit();
    var seen: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or std.mem.startsWith(u8, entry.path, ".cid")) continue;
        const expected = for (want) |w| {
            if (std.mem.eql(u8, w[0], entry.path)) break w[1];
        } else {
            std.debug.print("unexpected file in the folder: {s}\n", .{entry.path});
            return error.TreeDiffers;
        };
        try std.testing.expectEqualSlices(u8, expected, try readWholeFile(io, dir, entry.path, arena));
        seen += 1;
    }
    if (seen != want.len) {
        std.debug.print("the folder has {d} files, expected {d}\n", .{ seen, want.len });
        return error.TreeDiffers;
    }
}

test "clone round trip: clone, checkout and pull give exactly the release's files, for every fixture type" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var fixture: cid.db.Standalone = undefined;
    try openFixture(&fixture);
    defer fixture.close();
    _ = try runMigrations();
    var s3c: cid.blob.Client = undefined;
    try openBlobs(&s3c, io);
    defer s3c.deinit();

    var standalone: cid.db.Standalone = undefined;
    try standalone.open(std.testing.allocator, conninfo);
    defer standalone.close();
    var scope = cid.db.Run.init(std.testing.allocator);
    defer scope.deinit();
    var deps: cid.api.Deps = .{ .db = &standalone.db, .s3 = &s3c, .io = io, .gpa = std.testing.allocator, .token = "test-token" };
    var direct: DirectTransport = .{ .deps = &deps, .scope = &scope, .auth = "Bearer test-token" };
    const remote: cid.client.remote.Remote = .{ .t = direct.transport(), .name = "test/datasets/fixtures", .gpa = std.testing.allocator };

    // Every fixture, in folders: image, audio, PDF, text, CSV, Parquet,
    // JSONL and a binary no sniffer knows.
    const fixtures = try std.Io.Dir.cwd().openDir(io, "tests/fixtures", .{});
    const placed = [_][2][]const u8{
        .{ "media/pixels.png", "pixels.png" },      .{ "media/tone.wav", "tone.wav" },
        .{ "docs/page.pdf", "page.pdf" },           .{ "docs/notes.txt", "notes.txt" },
        .{ "tables/people.csv", "people.csv" },     .{ "tables/people.parquet", "people.parquet" },
        .{ "tables/events.jsonl", "events.jsonl" }, .{ "misc/unknown.bin", "unknown.bin" },
    };
    var v1: [placed.len][2][]const u8 = undefined;
    var producer = std.testing.tmpDir(.{ .iterate = true });
    defer producer.cleanup();
    var cache = std.testing.tmpDir(.{});
    defer cache.cleanup();
    for (placed, &v1) |p, *f| {
        const bytes = try fixtures.readFileAlloc(io, p[1], arena, .limited(1 << 20));
        try producer.dir.createDirPath(io, std.fs.path.dirname(p[0]).?);
        try producer.dir.writeFile(io, .{ .sub_path = p[0], .data = bytes });
        f.* = .{ p[0], bytes };
    }
    try cid.client.workspace.init(arena, io, producer.dir, "cid@test:test/datasets/fixtures", "git@example.invalid:fixtures.git");
    var ws = try cid.client.workspace.open(arena, io, producer.dir);
    _ = try cid.client.workspace.add(arena, io, &ws, cache.dir, &.{"."});
    _ = try cid.client.workspace.commit(arena, io, &ws, "every fixture", "user:test");
    _ = try cid.client.sync.push(arena, io, &ws, cache.dir, &remote);
    const r1 = try remote.tag(arena, "v1");

    // v2: an edit, a delete, and the image again under another name.
    const notes2 = try std.fmt.allocPrint(arena, "{s}one more line\n", .{v1[3][1]});
    try producer.dir.writeFile(io, .{ .sub_path = "docs/notes.txt", .data = notes2 });
    try producer.dir.deleteFile(io, "misc/unknown.bin");
    try producer.dir.writeFile(io, .{ .sub_path = "media/copy.png", .data = v1[0][1] });
    _ = try cid.client.workspace.add(arena, io, &ws, cache.dir, &.{"."});
    _ = try cid.client.workspace.commit(arena, io, &ws, "edit, delete, copy", "user:test");
    _ = try cid.client.sync.push(arena, io, &ws, cache.dir, &remote);
    _ = try remote.tag(arena, "v2");
    var v2: [placed.len][2][]const u8 = v1;
    v2[3][1] = notes2;
    v2[7] = .{ "media/copy.png", v1[0][1] };

    // Clone (the newest release) into an empty folder and cache.
    var reader = std.testing.tmpDir(.{ .iterate = true });
    defer reader.cleanup();
    var rcache = std.testing.tmpDir(.{});
    defer rcache.cleanup();
    const cloned = try cid.client.sync.clone(arena, io, reader.dir, rcache.dir, &remote, "cid@test:test/datasets/fixtures", null, null, .{});
    try std.testing.expectEqual(@as(u32, placed.len), cloned.files);
    try expectTree(arena, io, reader.dir, &v2);

    // Checkout the older release, then pull back to the newest.
    var rws = try cid.client.workspace.open(arena, io, reader.dir);
    _ = try cid.client.sync.checkout(arena, io, &rws, rcache.dir, &remote, "main", r1.commit, false);
    try expectTree(arena, io, reader.dir, &v1);
    _ = try cid.client.sync.pull(arena, io, &rws, rcache.dir, &remote);
    try expectTree(arena, io, reader.dir, &v2);
    const st = try cid.client.workspace.status(arena, io, &rws);
    try std.testing.expectEqual(@as(usize, 0), st.unstaged_modified.len + st.unstaged_new.len + st.unstaged_deleted.len);
}

test "releases: tag, immutability, verify green, verify catches corruption" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var fixture: cid.db.Standalone = undefined;
    try openFixture(&fixture);
    defer fixture.close();
    var fscope = cid.db.Run.init(std.testing.allocator);
    defer fscope.deinit();
    const db = &fixture.db;
    _ = try runMigrations();

    var s3c: cid.blob.Client = undefined;
    try openBlobs(&s3c, io);
    defer s3c.deinit();

    var standalone: cid.db.Standalone = undefined;
    try standalone.open(std.testing.allocator, conninfo);
    defer standalone.close();
    var scope = cid.db.Run.init(std.testing.allocator);
    defer scope.deinit();
    var deps: cid.api.Deps = .{ .db = &standalone.db, .s3 = &s3c, .io = io, .gpa = std.testing.allocator, .token = "test-token" };
    var direct: DirectTransport = .{ .deps = &deps, .scope = &scope, .auth = "Bearer test-token" };
    const remote: cid.client.remote.Remote = .{ .t = direct.transport(), .name = "test/datasets/rel", .gpa = std.testing.allocator };

    // Clean slate.
    _ = try db.exec(&fscope, "SET cid.maintenance = 'on'", .{});
    inline for (.{ "refs", "commits", "item_revisions", "dataset_items" }) |table| {
        _ = try db.exec(&fscope, "DELETE FROM " ++ table ++ " WHERE dataset_id IN (SELECT dataset_id FROM datasets WHERE name = 'test/datasets/rel')", .{});
    }
    _ = try db.exec(&fscope, "DELETE FROM datasets WHERE name = 'test/datasets/rel'", .{});
    _ = try db.exec(&fscope, "RESET cid.maintenance", .{});

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
        break :blk try arena.dupeZ(u8, (try db.rawOne([]const u8, &fscope, "SELECT dataset_id::text FROM datasets WHERE name = 'test/datasets/rel'", .{})).?);
    };
    const v1 = try cid.release.verify(arena, std.testing.allocator, &standalone.db, &scope, &s3c, ds_id, "v1.0.0");
    try std.testing.expect(v1.ok);
    try std.testing.expectEqual(@as(usize, 2), v1.items);

    // Corruption A: a revision smuggled UNDER the sealed cutoff (an id older
    // than c1's, adding a path the release never had) changes recomputed
    // history → verify must turn red.
    const old_uuid = cid.uuid7.Uuid.init(c1.id.unixMs() - 10_000, @splat(7));
    const smuggle = try std.fmt.allocPrintSentinel(arena, "INSERT INTO item_revisions (rev_id, ts, dataset_id, branch, path, op, item_id, item_hash, author) " ++
        "VALUES ('{s}', to_timestamp({d}), '{s}', 'main', 'smuggled.txt', 'add', gen_random_uuid(), " ++
        "decode(repeat('ef', 32), 'hex'), 'user:evil')", .{ &old_uuid.toString(), (old_uuid.unixMs() / 1000), ds_id }, 0);
    _ = try db.exec(&fscope, "INSERT INTO items (item_hash, size_bytes, media_type) VALUES (decode(repeat('ef', 32), 'hex'), 1, 'application/octet-stream') ON CONFLICT DO NOTHING", .{});
    _ = try db.exec(&fscope, smuggle, .{});
    const v2 = try cid.release.verify(arena, std.testing.allocator, &standalone.db, &scope, &s3c, ds_id, "v1.0.0");
    try std.testing.expect(!v2.ok);
    try std.testing.expectEqual(cid.release.VerifyProblem.recomputed_hash_differs, v2.problems[0]);

    // Remove the smuggled row (maintenance), verify is green again.
    _ = try db.exec(&fscope, "SET cid.maintenance = 'on'", .{});
    _ = try db.exec(&fscope, "DELETE FROM item_revisions WHERE author = 'user:evil'", .{});
    _ = try db.exec(&fscope, "RESET cid.maintenance", .{});
    const v3 = try cid.release.verify(arena, std.testing.allocator, &standalone.db, &scope, &s3c, ds_id, "v1.0.0");
    try std.testing.expect(v3.ok);

    // Corruption B: tamper with the stored manifest object.
    const commit_for_release = try arena.dupe(u8, list[0].commit);
    const mkey = try cid.release.manifestKey(arena, ds_id, commit_for_release);
    try s3c.putObject(&scope, mkey, "tampered bytes");
    const v4 = try cid.release.verify(arena, std.testing.allocator, &standalone.db, &scope, &s3c, ds_id, "v1.0.0");
    try std.testing.expect(!v4.ok);
    try std.testing.expectEqual(cid.release.VerifyProblem.stored_manifest_differs, v4.problems[0]);

    // The activity log has the push and the release, by who did them.
    const pushes = (try db.rawOne(i64, &fscope, "SELECT count(*) FROM activity_events e JOIN datasets d USING (dataset_id) WHERE d.name = 'test/datasets/rel' AND e.action = 'push' AND e.account_id = 'server-token'", .{})).?;
    try std.testing.expect(pushes >= 1);
    const tags = (try db.rawOne(i64, &fscope, "SELECT count(*) FROM activity_events e JOIN datasets d USING (dataset_id) WHERE d.name = 'test/datasets/rel' AND e.action = 'tag' AND e.ref = 'v1.0.0'", .{})).?;
    try std.testing.expect(tags >= 1);
}

test "git writer: one commit and tag per release, idempotent, resumable" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var fixture: cid.db.Standalone = undefined;
    try openFixture(&fixture);
    defer fixture.close();
    var fscope = cid.db.Run.init(std.testing.allocator);
    defer fscope.deinit();
    const db = &fixture.db;
    _ = try runMigrations();

    var s3c: cid.blob.Client = undefined;
    try openBlobs(&s3c, io);
    defer s3c.deinit();

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

    var standalone: cid.db.Standalone = undefined;
    try standalone.open(std.testing.allocator, conninfo);
    defer standalone.close();
    var scope = cid.db.Run.init(std.testing.allocator);
    defer scope.deinit();
    var deps: cid.api.Deps = .{
        .db = &standalone.db,
        .s3 = &s3c,
        .io = io,
        .gpa = std.testing.allocator,
        .token = "test-token",
        .git = .{ .workdir = work_root, .server_url = "https://cid.example" },
    };
    var direct: DirectTransport = .{ .deps = &deps, .scope = &scope, .auth = "Bearer test-token" };
    const remote: cid.client.remote.Remote = .{ .t = direct.transport(), .name = "test/datasets/gitw", .gpa = std.testing.allocator };

    // Clean slate, then a dataset whose git_url is the bare repo.
    _ = try db.exec(&fscope, "SET cid.maintenance = 'on'", .{});
    inline for (.{ "git_writes", "refs", "commits", "item_revisions", "dataset_items" }) |table| {
        _ = try db.exec(&fscope, "DELETE FROM " ++ table ++ " WHERE dataset_id IN (SELECT dataset_id FROM datasets WHERE name = 'test/datasets/gitw')", .{});
    }
    _ = try db.exec(&fscope, "DELETE FROM datasets WHERE name = 'test/datasets/gitw'", .{});
    _ = try db.exec(&fscope, "RESET cid.maintenance", .{});

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

    const statuses = try db.raw([]const u8, &fscope, "SELECT status FROM git_writes w JOIN datasets d USING (dataset_id) WHERE d.name = 'test/datasets/gitw'", .{});
    try std.testing.expectEqual(@as(usize, 1), statuses.len);
    try std.testing.expectEqualStrings("done", statuses[0]);

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
    const again = try cid.gitrepo.writer.processDataset(arena, io, &standalone.db, &scope, deps.git.?, "test/datasets/gitw");
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

    const commitsOnMain = struct {
        fn on(al: std.mem.Allocator, i: std.Io, url: []const u8) ![]const u8 {
            return (try std.process.run(al, i, .{ .argv = &.{ "git", "-C", url, "rev-list", "--count", "main" } })).stdout;
        }
    }.on;
    const rerender = "UPDATE git_writes SET status = 'pending' WHERE dataset_id = (SELECT dataset_id FROM datasets WHERE name = 'test/datasets/gitw')";

    // The card is edited after v2: rendering every release again (for
    // real: each row back to pending) makes no new commit, because each
    // release renders its own card snapshot.
    const card_put = cid.api.handle(arena, &deps, &scope, "PUT", "/v0/datasets/test/datasets/gitw/-/card", "Bearer test-token", "{\"card\":{\"purpose\":\"exercise the git writer\",\"license\":\"CC0-1.0\"}}");
    try std.testing.expectEqual(std.http.Status.ok, card_put.status);
    _ = try db.exec(&fscope, rerender, .{});
    const rerendered = try cid.gitrepo.writer.processDataset(arena, io, &standalone.db, &scope, deps.git.?, "test/datasets/gitw");
    try std.testing.expectEqual(@as(u32, 2), rerendered.processed);
    try std.testing.expectEqualStrings("2\n", try commitsOnMain(arena, io, bare_url));

    // The next release carries the edited card.
    const steps = struct {
        fn release(al: std.mem.Allocator, i: std.Io, dir: std.Io.Dir, ws: *cid.client.workspace.Workspace, c: std.Io.Dir, r: *const cid.client.remote.Remote, file: []const u8, name: []const u8) !void {
            try dir.writeFile(i, .{ .sub_path = file, .data = name });
            _ = try cid.client.workspace.add(al, i, ws, c, &.{"."});
            _ = try cid.client.workspace.commit(al, i, ws, name, "user:test");
            _ = try cid.client.sync.push(al, i, ws, c, r);
            _ = try r.tag(al, name);
        }
    }.release;
    try steps(arena, io, producer.dir, &pws, cache.dir, &remote, "c.txt", "v3.0.0");
    _ = try std.process.run(arena, io, .{ .argv = &.{ "git", "-C", clone_dir, "pull", "-q" } });
    const readme3 = try check.readFileAlloc(io, "README.md", arena, .limited(64 * 1024));
    try std.testing.expect(std.mem.indexOf(u8, readme3, "**Purpose:** exercise the git writer") != null);
    try std.testing.expectEqualStrings("3\n", try commitsOnMain(arena, io, bare_url));

    // A git outage: the repository is gone. The release still happens,
    // intact; its git copy waits, and a resync fills the gap.
    const away = try std.fmt.allocPrint(arena, "{s}/away.git", .{root_path});
    try std.Io.Dir.rename(std.Io.Dir.cwd(), bare_url, std.Io.Dir.cwd(), away, io);
    try steps(arena, io, producer.dir, &pws, cache.dir, &remote, "d.txt", "v4.0.0");
    const v4_ref = try db.rawOne(i64, &fscope, "SELECT 1::bigint FROM refs r JOIN datasets d USING (dataset_id) WHERE d.name = 'test/datasets/gitw' AND r.name = 'v4.0.0'", .{});
    try std.testing.expect(v4_ref != null);
    const v4_git = (try db.rawOne([]const u8, &fscope, "SELECT status FROM git_writes w JOIN datasets d USING (dataset_id) WHERE d.name = 'test/datasets/gitw' AND w.release = 'v4.0.0'", .{})).?;
    try std.testing.expectEqualStrings("failed", v4_git);
    try std.Io.Dir.rename(std.Io.Dir.cwd(), away, std.Io.Dir.cwd(), bare_url, io);
    const resynced = try cid.gitrepo.writer.processDataset(arena, io, &standalone.db, &scope, deps.git.?, "test/datasets/gitw");
    try std.testing.expectEqual(@as(u32, 1), resynced.processed);
    try std.testing.expectEqual(@as(u32, 0), resynced.failed);
    try std.testing.expectEqualStrings("4\n", try commitsOnMain(arena, io, bare_url));
    const tags4 = try std.process.run(arena, io, .{ .argv = &.{ "git", "-C", bare_url, "tag" } });
    try std.testing.expectEqualStrings("v1.0.0\nv2.0.0\nv3.0.0\nv4.0.0\n", tags4.stdout);

    // Restricted: the release's files hold counts and nothing more — no
    // file names, no card, no release notes — in the repository itself.
    _ = try db.exec(&fscope, "UPDATE datasets SET restricted = true WHERE name = 'test/datasets/gitw'", .{});
    defer _ = db.exec(&fscope, "UPDATE datasets SET restricted = false WHERE name = 'test/datasets/gitw'", .{}) catch {};
    try steps(arena, io, producer.dir, &pws, cache.dir, &remote, "secret-name.txt", "v5.0.0");
    const tree = try std.process.run(arena, io, .{ .argv = &.{ "git", "-C", bare_url, "ls-tree", "-r", "--name-only", "v5.0.0" } });
    try std.testing.expect(std.mem.indexOf(u8, tree.stdout, "files.txt") == null);
    const files_list = try std.process.run(arena, io, .{ .argv = &.{ "git", "-C", bare_url, "ls-tree", "-r", "--name-only", "v5.0.0" } });
    var names = std.mem.splitScalar(u8, std.mem.trimEnd(u8, files_list.stdout, "\n"), '\n');
    while (names.next()) |name| {
        const shown = try std.process.run(arena, io, .{ .argv = &.{ "git", "-C", bare_url, "show", try std.fmt.allocPrint(arena, "v5.0.0:{s}", .{name}) } });
        for ([_][]const u8{ "secret-name", "a.txt", "exercise the git writer", "first release content" }) |leak| {
            if (std.mem.indexOf(u8, shown.stdout, leak) != null) {
                std.debug.print("restricted release wrote '{s}' into {s}\n", .{ leak, name });
                return error.RestrictedContentInGit;
            }
        }
    }
}

test "access: key lookup, forced command, scoped tokens enforced by routes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var fixture: cid.db.Standalone = undefined;
    try openFixture(&fixture);
    defer fixture.close();
    var fscope = cid.db.Run.init(std.testing.allocator);
    defer fscope.deinit();
    const db = &fixture.db;
    _ = try runMigrations();

    var s3c: cid.blob.Client = undefined;
    try openBlobs(&s3c, io);
    defer s3c.deinit();

    const secret = "integration-test-secret-0123456789abcdef";
    var standalone: cid.db.Standalone = undefined;
    try standalone.open(std.testing.allocator, conninfo);
    defer standalone.close();
    var scope = cid.db.Run.init(std.testing.allocator);
    defer scope.deinit();
    var deps: cid.api.Deps = .{ .db = &standalone.db, .s3 = &s3c, .io = io, .gpa = std.testing.allocator, .token = "", .token_secret = secret };
    const ndb = &standalone.db;

    // Clean slate: account, key, dataset, access.
    _ = try db.exec(&fscope, "DELETE FROM access WHERE account_id IN ('gitlab:7001', 'gitlab:7002')", .{});
    _ = try db.exec(&fscope, "DELETE FROM ssh_keys WHERE account_id IN ('gitlab:7001', 'gitlab:7002')", .{});
    _ = try db.exec(&fscope, "DELETE FROM accounts WHERE account_id IN ('gitlab:7001', 'gitlab:7002')", .{});
    _ = try db.exec(&fscope, "INSERT INTO datasets (dataset_id, name, kind, git_url) VALUES " ++
        "('018f0000-0000-7000-8000-00000000ac01', 'test/datasets/access', 'files', 'g@h:a.git') " ++
        "ON CONFLICT (name) DO NOTHING", .{});
    _ = try db.exec(&fscope, "INSERT INTO accounts (account_id, display_name, source) VALUES " ++
        "('gitlab:7001', 'Reader Rhea', 'dashboard'), ('gitlab:7002', 'Writer Wade', 'dashboard')", .{});
    _ = try db.exec(&fscope, "INSERT INTO ssh_keys (fingerprint, account_id, public_key) VALUES " ++
        "('SHA256:testfp7001', 'gitlab:7001', 'ssh-ed25519 AAAAC3NzaTEST7001 rhea@laptop')", .{});
    _ = try db.exec(&fscope, "INSERT INTO access (dataset_id, account_id, level, source) VALUES " ++
        "('018f0000-0000-7000-8000-00000000ac01', 'gitlab:7001', 'read', 'dashboard'), " ++
        "('018f0000-0000-7000-8000-00000000ac01', 'gitlab:7002', 'write', 'dashboard')", .{});

    // AuthorizedKeysCommand: a known key gets the pinned forced command.
    const line = (try cid.access.auth.authorizedKeysLine(arena, ndb, &scope, "SHA256:testfp7001")).?;
    try std.testing.expect(std.mem.startsWith(u8, line, "restrict,command=\"cid ssh-auth --account=gitlab:7001\" ssh-ed25519"));
    try std.testing.expectEqual(@as(?[]const u8, null), try cid.access.auth.authorizedKeysLine(arena, ndb, &scope, "SHA256:unknown"));

    // The forced command: read is granted to the reader, write is not.
    const now: u64 = @intCast(@max(0, std.Io.Timestamp.now(io, .real).toSeconds()));
    const read_req = try cid.access.auth.parseOriginalCommand("cid-auth test/datasets/access read", "gitlab:7001");
    const read_grant = try cid.access.auth.authorize(arena, ndb, &scope, secret, "http://127.0.0.1:7070", now, read_req);
    try std.testing.expect(std.mem.startsWith(u8, read_grant.token, "cid1."));

    const write_req = try cid.access.auth.parseOriginalCommand("cid-auth test/datasets/access write", "gitlab:7001");
    try std.testing.expectError(error.AccessDenied, cid.access.auth.authorize(arena, ndb, &scope, secret, "x", now, write_req));
    const wade_write = try cid.access.auth.parseOriginalCommand("cid-auth test/datasets/access write", "gitlab:7002");
    const write_grant = try cid.access.auth.authorize(arena, ndb, &scope, secret, "x", now, wade_write);

    // Both decisions landed in the audit log.
    const AuditCounts = struct {
        pub const nilo_table = .projection;
        granted_n: i64,
        denied_n: i64,
    };
    const events = try db.rawExactlyOne(AuditCounts, &fscope, "SELECT count(*) FILTER (WHERE granted) AS granted_n, " ++
        "count(*) FILTER (WHERE NOT granted) AS denied_n FROM auth_events " ++
        "WHERE account_id IN ('gitlab:7001', 'gitlab:7002') AND ts > now() - interval '1 minute'", .{});
    try std.testing.expect(events.granted_n >= 2);
    try std.testing.expect(events.denied_n >= 1);

    // Routes enforce the scope: read token reads but cannot push; a token
    // for another dataset is useless here; garbage is refused.
    const read_auth = try std.fmt.allocPrint(arena, "Bearer {s}", .{read_grant.token});
    const write_auth = try std.fmt.allocPrint(arena, "Bearer {s}", .{write_grant.token});

    const head_ok = cid.api.handle(arena, &deps, &scope, "GET", "/v0/datasets/test/datasets/access/-/head", read_auth, "");
    try std.testing.expectEqual(std.http.Status.ok, head_ok.status);
    const push_denied = cid.api.handle(arena, &deps, &scope, "POST", "/v0/datasets/test/datasets/access/-/push", read_auth, "{}");
    try std.testing.expectEqual(std.http.Status.unauthorized, push_denied.status);
    const check_denied = cid.api.handle(arena, &deps, &scope, "POST", "/v0/datasets/test/datasets/access/-/check-hashes", read_auth, "{\"hashes\":[]}");
    try std.testing.expectEqual(std.http.Status.unauthorized, check_denied.status);
    const check_ok = cid.api.handle(arena, &deps, &scope, "POST", "/v0/datasets/test/datasets/access/-/check-hashes", write_auth, "{\"hashes\":[]}");
    try std.testing.expectEqual(std.http.Status.ok, check_ok.status);

    // Owners' actions need the maintain level: a Developer's token is
    // told who can (403), and the forced command will not mint maintain
    // for a Developer.
    for ([_][]const u8{ "tag", "branch", "merge" }) |action| {
        const res = cid.api.handle(arena, &deps, &scope, "POST", try std.fmt.allocPrint(arena, "/v0/datasets/test/datasets/access/-/{s}", .{action}), write_auth, "{}");
        try std.testing.expectEqual(std.http.Status.forbidden, res.status);
        try std.testing.expect(std.mem.indexOf(u8, res.body, "Maintainer") != null);
    }
    const wade_maintain = try cid.access.auth.parseOriginalCommand("cid-auth test/datasets/access maintain", "gitlab:7002");
    try std.testing.expectError(error.AccessDenied, cid.access.auth.authorize(arena, ndb, &scope, secret, "x", now, wade_maintain));
    const owner_token = try cid.access.token.mint(arena, secret, .{ .expiry_unix = now + 60, .level = .maintain, .account = "gitlab:7002", .dataset = "test/datasets/access" });
    const owner_tag = cid.api.handle(arena, &deps, &scope, "POST", "/v0/datasets/test/datasets/access/-/tag", try std.fmt.allocPrint(arena, "Bearer {s}", .{owner_token}), "{}");
    try std.testing.expect(owner_tag.status != .forbidden and owner_tag.status != .unauthorized);

    const other_ds = cid.api.handle(arena, &deps, &scope, "GET", "/v0/datasets/test/datasets/sync/-/head", read_auth, "");
    try std.testing.expectEqual(std.http.Status.unauthorized, other_ds.status);
    const garbage = cid.api.handle(arena, &deps, &scope, "GET", "/v0/datasets/test/datasets/access/-/head", "Bearer cid1.not.real", "");
    try std.testing.expectEqual(std.http.Status.unauthorized, garbage.status);

    // An expired token is dead, whatever it once allowed.
    const expired = try cid.access.token.mint(arena, secret, .{
        .expiry_unix = now - 1,
        .level = .write,
        .account = "gitlab:7002",
        .dataset = "test/datasets/access",
    });
    const expired_auth = try std.fmt.allocPrint(arena, "Bearer {s}", .{expired});
    const expired_res = cid.api.handle(arena, &deps, &scope, "GET", "/v0/datasets/test/datasets/access/-/head", expired_auth, "");
    try std.testing.expectEqual(std.http.Status.unauthorized, expired_res.status);

    // With no static token configured, the old shared-token style fails.
    const static_res = cid.api.handle(arena, &deps, &scope, "GET", "/v0/datasets/test/datasets/access/-/head", "Bearer test-token", "");
    try std.testing.expectEqual(std.http.Status.unauthorized, static_res.status);

    // A dashboard session: identity from the cookie, permission from the
    // same access table. gitlab:7001 reads test/datasets/access only.
    const rhea: cid.api.Caller = .{ .account = "gitlab:7001" };
    const listing = cid.api.handleAs(arena, &deps, &scope, "GET", "/v0/datasets", rhea, "");
    try std.testing.expectEqual(std.http.Status.ok, listing.status);
    try std.testing.expect(std.mem.indexOf(u8, listing.body, "\"test/datasets/access\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, listing.body, "\"test/datasets/sync\"") == null);
    const read_ok = cid.api.handleAs(arena, &deps, &scope, "GET", "/v0/datasets/test/datasets/access/-/head", rhea, "");
    try std.testing.expectEqual(std.http.Status.ok, read_ok.status);
    const push_no = cid.api.handleAs(arena, &deps, &scope, "POST", "/v0/datasets/test/datasets/access/-/push", rhea, "{}");
    try std.testing.expectEqual(std.http.Status.unauthorized, push_no.status);
    const other_no = cid.api.handleAs(arena, &deps, &scope, "GET", "/v0/datasets/test/datasets/sync/-/head", rhea, "");
    try std.testing.expectEqual(std.http.Status.unauthorized, other_no.status);
    // Stars: hers to set, shown in her listing, refused for the token.
    const starred = cid.api.handleAs(arena, &deps, &scope, "PUT", "/v0/datasets/test/datasets/access/-/star", rhea, "");
    try std.testing.expectEqual(std.http.Status.ok, starred.status);
    const with_star = cid.api.handleAs(arena, &deps, &scope, "GET", "/v0/datasets", rhea, "");
    try std.testing.expect(std.mem.indexOf(u8, with_star.body, "\"starred\":true") != null);
    const unstarred = cid.api.handleAs(arena, &deps, &scope, "DELETE", "/v0/datasets/test/datasets/access/-/star", rhea, "");
    try std.testing.expectEqual(std.http.Status.ok, unstarred.status);
    const no_star = cid.api.handleAs(arena, &deps, &scope, "GET", "/v0/datasets", rhea, "");
    try std.testing.expect(std.mem.indexOf(u8, no_star.body, "\"starred\":true") == null);
    const other_star = cid.api.handleAs(arena, &deps, &scope, "PUT", "/v0/datasets/test/datasets/sync/-/star", rhea, "");
    try std.testing.expectEqual(std.http.Status.unauthorized, other_star.status); // only what she can read
    // Owners: the Maintainers, by name. Wade writes, so he is not one yet.
    try std.testing.expect(std.mem.indexOf(u8, with_star.body, "\"owners\":[]") != null);
    _ = try db.exec(&fscope, "UPDATE access SET level = 'maintain' WHERE account_id = 'gitlab:7002'", .{});
    const owned = cid.api.handleAs(arena, &deps, &scope, "GET", "/v0/datasets", rhea, "");
    try std.testing.expect(std.mem.indexOf(u8, owned.body, "\"owners\":[\"Writer Wade\"]") != null);
    const who = cid.api.handleAs(arena, &deps, &scope, "GET", "/v0/me", rhea, "");
    try std.testing.expect(std.mem.indexOf(u8, who.body, "Reader Rhea") != null);
    // Nobody signed in: no listing, and /v0/me says so.
    const anon = cid.api.handleAs(arena, &deps, &scope, "GET", "/v0/datasets", .{}, "");
    try std.testing.expectEqual(std.http.Status.unauthorized, anon.status);
    const anon_me = cid.api.handleAs(arena, &deps, &scope, "GET", "/v0/me", .{}, "");
    try std.testing.expectEqual(std.http.Status.unauthorized, anon_me.status);
}

test "gitlab sync: members and keys applied, removals revoke access" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    _ = io;

    var fixture: cid.db.Standalone = undefined;
    try openFixture(&fixture);
    defer fixture.close();
    var fscope = cid.db.Run.init(std.testing.allocator);
    defer fscope.deinit();
    const db = &fixture.db;
    _ = try runMigrations();

    _ = try db.exec(&fscope, "DELETE FROM access WHERE account_id LIKE 'gitlab:91%'", .{});
    _ = try db.exec(&fscope, "DELETE FROM ssh_keys WHERE account_id LIKE 'gitlab:91%'", .{});
    _ = try db.exec(&fscope, "DELETE FROM accounts WHERE account_id LIKE 'gitlab:91%'", .{});
    _ = try db.exec(&fscope, "INSERT INTO datasets (dataset_id, name, kind, git_url) VALUES " ++
        "('018f0000-0000-7000-8000-000000009d01'::uuid, 'test/datasets/gl', 'files', 'g@h:gl.git') " ++
        "ON CONFLICT (name) DO NOTHING", .{});

    // First sync: a reporter, a developer, a guest (ignored).
    const members1 = try cid.access.gitlab.parseMembers(arena,
        \\[{"id":9101,"username":"rhea","name":"Rhea R","access_level":20,"state":"active"},
        \\ {"id":9102,"username":"wade","name":"Wade W","access_level":30,"state":"active"},
        \\ {"id":9103,"username":"guest","access_level":10,"state":"active"}]
    );
    var standalone: cid.db.Standalone = undefined;
    try standalone.open(std.testing.allocator, conninfo);
    defer standalone.close();
    var scope = cid.db.Run.init(std.testing.allocator);
    defer scope.deinit();
    const ndb = &standalone.db;
    const first = try cid.access.gitlab.applyMembers(arena, ndb, &scope, "test/datasets/gl", members1);
    try std.testing.expectEqual(@as(u32, 2), first.upserted);

    const Lvl = struct {
        pub const nilo_table = .projection;
        account_id: []const u8,
        level: []const u8,
    };
    const levels = try db.raw(Lvl, &fscope, "SELECT account_id, level FROM access a JOIN datasets d USING (dataset_id) " ++
        "WHERE d.name = 'test/datasets/gl' ORDER BY account_id", .{});
    try std.testing.expectEqual(@as(usize, 2), levels.len);
    try std.testing.expectEqualStrings("read", levels[0].level); // 9101
    try std.testing.expectEqualStrings("write", levels[1].level); // 9102

    // Keys for the developer: the fixture key gets its real fingerprint.
    const keys1 = try cid.access.gitlab.parseKeys(arena,
        \\[{"id":1,"key":"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFdJMTzwHtTuz5TEIEMRoQ8hWQ8EuaJotFSs/0FCfvS4 fixture@cid"},
        \\ {"id":2,"key":"garbage not a key"}]
    );
    const key_first = try cid.access.gitlab.applyKeys(arena, ndb, &scope, 9102, keys1);
    try std.testing.expectEqual(@as(u32, 1), key_first.upserted);
    try std.testing.expectEqual(@as(u32, 1), key_first.skipped_invalid);
    const line = (try cid.access.auth.authorizedKeysLine(arena, ndb, &scope, "SHA256:dFtRBBCbqwbXXQkKRXzbOpi9eJQNbn/SAiaVrdWiLo0")).?;
    try std.testing.expect(std.mem.indexOf(u8, line, "--account=gitlab:9102") != null);

    // Second sync: Rhea is gone, Wade is demoted to reporter, keys rotated.
    const members2 = try cid.access.gitlab.parseMembers(arena,
        \\[{"id":9102,"username":"wade","name":"Wade W","access_level":20,"state":"active"}]
    );
    const second = try cid.access.gitlab.applyMembers(arena, ndb, &scope, "test/datasets/gl", members2);
    try std.testing.expectEqual(@as(u32, 1), second.removed);

    const levels2 = try db.raw(Lvl, &fscope, "SELECT account_id, level FROM access a JOIN datasets d USING (dataset_id) " ++
        "WHERE d.name = 'test/datasets/gl' ORDER BY account_id", .{});
    try std.testing.expectEqual(@as(usize, 1), levels2.len);
    try std.testing.expectEqualStrings("gitlab:9102", levels2[0].account_id);
    try std.testing.expectEqualStrings("read", levels2[0].level);

    const key_second = try cid.access.gitlab.applyKeys(arena, ndb, &scope, 9102, &.{});
    try std.testing.expectEqual(@as(u32, 1), key_second.removed);
    try std.testing.expectEqual(@as(?[]const u8, null), try cid.access.auth.authorizedKeysLine(arena, ndb, &scope, "SHA256:dFtRBBCbqwbXXQkKRXzbOpi9eJQNbn/SAiaVrdWiLo0"));
}

test "branches: compose from main, push on branch, merge with conflicts listed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var fixture: cid.db.Standalone = undefined;
    try openFixture(&fixture);
    defer fixture.close();
    var fscope = cid.db.Run.init(std.testing.allocator);
    defer fscope.deinit();
    const db = &fixture.db;
    _ = try runMigrations();
    var s3c: cid.blob.Client = undefined;
    try openBlobs(&s3c, io);
    defer s3c.deinit();

    var standalone: cid.db.Standalone = undefined;
    try standalone.open(std.testing.allocator, conninfo);
    defer standalone.close();
    var scope = cid.db.Run.init(std.testing.allocator);
    defer scope.deinit();
    var deps: cid.api.Deps = .{ .db = &standalone.db, .s3 = &s3c, .io = io, .gpa = std.testing.allocator, .token = "test-token" };
    var direct: DirectTransport = .{ .deps = &deps, .scope = &scope, .auth = "Bearer test-token" };
    const remote: cid.client.remote.Remote = .{ .t = direct.transport(), .name = "test/datasets/br", .gpa = std.testing.allocator };

    _ = try db.exec(&fscope, "SET cid.maintenance = 'on'", .{});
    inline for (.{ "git_writes", "refs", "commits", "item_revisions", "dataset_items" }) |table| {
        _ = try db.exec(&fscope, "DELETE FROM " ++ table ++ " WHERE dataset_id IN (SELECT dataset_id FROM datasets WHERE name = 'test/datasets/br')", .{});
    }
    _ = try db.exec(&fscope, "DELETE FROM datasets WHERE name = 'test/datasets/br'", .{});
    _ = try db.exec(&fscope, "RESET cid.maintenance", .{});

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
    _ = try cid.client.sync.clone(arena, io, worker.dir, wcache.dir, &remote, "cid@test:test/datasets/br", null, null, .{});
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

    const merged = try remote.merge(arena, "cleanup", "user:test", &.{});
    try std.testing.expect(merged == .merged);
    try std.testing.expectEqual(@as(u64, 2), merged.merged.changes); // tweak + branch-only

    const after = try remote.state(arena, (try remote.head(arena, "main")).?);
    try std.testing.expectEqual(@as(usize, 4), after.len);
    const merge_parents = try db.raw([]const u8, &fscope, "SELECT merge_parent_id::text FROM commits c JOIN datasets d USING (dataset_id) " ++
        "WHERE d.name = 'test/datasets/br' AND merge_parent_id IS NOT NULL", .{});
    try std.testing.expectEqual(@as(usize, 1), merge_parents.len);

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

    const conflicted = try remote.merge(arena, "risky", "user:test", &.{});
    try std.testing.expect(conflicted == .conflicts);
    try std.testing.expectEqual(@as(usize, 1), conflicted.conflicts.len);
    try std.testing.expectEqualStrings("shared.txt", conflicted.conflicts[0]);
    // Nothing merged: main still holds its own version.
    const untouched = try remote.state(arena, (try remote.head(arena, "main")).?);
    for (untouched) |item| {
        if (std.mem.eql(u8, item.path, "shared.txt")) {
            var dgst: [32]u8 = undefined;
            cid.hash.Hasher.hash("main version", &dgst, .{});
            try std.testing.expectEqualStrings(&std.fmt.bytesToHex(dgst, .lower), item.hash);
        }
    }

    try std.testing.expectError(error.NoSuchBranch, remote.merge(arena, "ghost", "user:test", &.{}));

    // A person decides: take the branch's shared.txt. The merge lands, and
    // main now holds the branch's version.
    const shaOf = struct {
        fn hex(bytes: []const u8) [64]u8 {
            var d: [32]u8 = undefined;
            cid.hash.Hasher.hash(bytes, &d, .{});
            return std.fmt.bytesToHex(d, .lower);
        }
    }.hex;
    const decided = try remote.merge(arena, "risky", "user:test", &.{.{ .path = "shared.txt", .take = "branch" }});
    try std.testing.expect(decided == .merged);
    for (try remote.state(arena, (try remote.head(arena, "main")).?)) |item| {
        if (std.mem.eql(u8, item.path, "shared.txt")) try std.testing.expectEqualStrings(&shaOf("risky version"), item.hash);
    }
}

test "s3 multipart: a large object goes up in parts and comes back identical" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var s3c: cid.blob.Client = undefined;
    try s3c.open(std.testing.allocator, .{
        .endpoint = "http://127.0.0.1:8333",
        .access_key = "cid-test-key",
        .secret_key = "cid-test-secret",
        .multipart_threshold = 6 * 1024 * 1024, // low, so the test is 12 MB not 65
    });
    try s3c.start(io);
    defer s3c.deinit();
    var scope = cid.db.Run.init(std.testing.allocator);
    defer scope.deinit();

    // 12 MB of varied bytes, over the lowered threshold → multipart
    // (nilo parts of 8 + 4 MB).
    const big = try arena.alloc(u8, 12 * 1024 * 1024);
    for (big, 0..) |*b, i| b.* = @truncate(i *% 31 +% (i >> 8));

    const key = "items/blake3/mp/multipart-test-object";
    try s3c.deleteObject(&scope, key);
    try s3c.putObject(&scope, key, big);

    const got = try s3c.getObjectAlloc(&scope, key);
    try std.testing.expectEqual(big.len, got.len);
    try std.testing.expect(std.mem.eql(u8, big, got));
    try s3c.deleteObject(&scope, key);
}

test "purge: bytes gone, history intact, verify says so, content cannot return" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var fixture: cid.db.Standalone = undefined;
    try openFixture(&fixture);
    defer fixture.close();
    var fscope = cid.db.Run.init(std.testing.allocator);
    defer fscope.deinit();
    const db = &fixture.db;
    _ = try runMigrations();
    var s3c: cid.blob.Client = undefined;
    try openBlobs(&s3c, io);
    defer s3c.deinit();

    var standalone: cid.db.Standalone = undefined;
    try standalone.open(std.testing.allocator, conninfo);
    defer standalone.close();
    var scope = cid.db.Run.init(std.testing.allocator);
    defer scope.deinit();
    var deps: cid.api.Deps = .{ .db = &standalone.db, .s3 = &s3c, .io = io, .gpa = std.testing.allocator, .token = "test-token" };
    var direct: DirectTransport = .{ .deps = &deps, .scope = &scope, .auth = "Bearer test-token" };
    const remote: cid.client.remote.Remote = .{ .t = direct.transport(), .name = "test/datasets/purge", .gpa = std.testing.allocator };

    _ = try db.exec(&fscope, "SET cid.maintenance = 'on'", .{});
    inline for (.{ "git_writes", "refs", "commits", "item_revisions", "dataset_items" }) |table| {
        _ = try db.exec(&fscope, "DELETE FROM " ++ table ++ " WHERE dataset_id IN (SELECT dataset_id FROM datasets WHERE name = 'test/datasets/purge')", .{});
    }
    _ = try db.exec(&fscope, "DELETE FROM purged_items WHERE dataset_id IN (SELECT dataset_id FROM datasets WHERE name = 'test/datasets/purge')", .{});
    _ = try db.exec(&fscope, "DELETE FROM datasets WHERE name = 'test/datasets/purge'", .{});
    _ = try db.exec(&fscope, "RESET cid.maintenance", .{});

    const sensitive = "a face image that must be erasable";
    var dg: [32]u8 = undefined;
    cid.hash.Hasher.hash(sensitive, &dg, .{});
    const sensitive_hash = std.fmt.bytesToHex(dg, .lower);
    {
        const hz = try arena.dupeZ(u8, &sensitive_hash);
        _ = db.exec(&fscope, "DELETE FROM purged_items WHERE item_hash = decode($1, 'hex')", .{hz}) catch {};
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
        break :blk try arena.dupeZ(u8, (try db.rawOne([]const u8, &fscope, "SELECT dataset_id::text FROM datasets WHERE name = 'test/datasets/purge'", .{})).?);
    };

    // Its previews exist (as the worker would have made them).
    const thumb = try cid.preview.thumbKey(arena, &sensitive_hash);
    const blur = try cid.preview.blurKey(arena, &sensitive_hash);
    try s3c.putObject(&scope, thumb, "a thumbnail of the face");
    try s3c.putObject(&scope, blur, "a blurred face");

    // Purge by path; the bytes and their previews vanish, the tombstone
    // and audit land (invariant 19).
    const purged = try cid.purge.purge(arena, &standalone.db, &scope, &s3c, "test/datasets/purge", "face.jpg", "erasure request #42", "user:admin");
    try std.testing.expectEqualStrings(&sensitive_hash, purged.hash_hex);
    try std.testing.expectEqual(@as(usize, 1), purged.releases_affected);
    const key = try cid.api.itemKey(arena, &sensitive_hash);
    try std.testing.expectEqual(@as(?u64, null), try s3c.headObject(&scope, key));
    try std.testing.expectEqual(@as(?u64, null), try s3c.headObject(&scope, thumb));
    try std.testing.expectEqual(@as(?u64, null), try s3c.headObject(&scope, blur));
    try std.testing.expectEqual(@as(?i64, null), try db.rawOne(i64, &fscope, "SELECT 1::bigint FROM previews WHERE item_hash = decode($1, 'hex')", .{&sensitive_hash}));
    try std.testing.expectError(error.AlreadyPurged, cid.purge.purge(arena, &standalone.db, &scope, &s3c, "test/datasets/purge", "face.jpg", "again", "user:admin"));

    const audit = try db.rawExactlyOne(i64, &fscope, "SELECT count(*) FROM activity_events WHERE dataset_id = $1::uuid AND action = 'purge'", .{ds_id});
    try std.testing.expectEqual(@as(i64, 1), audit);

    // History rows untouched; verify is green with the purged item named.
    const v = try cid.release.verify(arena, std.testing.allocator, &standalone.db, &scope, &s3c, ds_id, "v1.0.0");
    try std.testing.expect(v.ok);
    try std.testing.expectEqual(@as(usize, 1), v.purged);
    try std.testing.expectEqual(@as(usize, 2), v.items);

    // The purged content can never come back through push.
    const check_body = try std.fmt.allocPrint(arena, "{{\"hashes\":[\"{s}\"]}}", .{&sensitive_hash});
    const refused = cid.api.handle(arena, &deps, &scope, "POST", "/v0/datasets/test/datasets/purge/-/check-hashes", "Bearer test-token", check_body);
    try std.testing.expectEqual(std.http.Status.unprocessable_entity, refused.status);
}

test "annotated: the platform writes revisions, the server commits, state composes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var fixture: cid.db.Standalone = undefined;
    try openFixture(&fixture);
    defer fixture.close();
    var fscope = cid.db.Run.init(std.testing.allocator);
    defer fscope.deinit();
    const db = &fixture.db;
    _ = try runMigrations();
    var s3c: cid.blob.Client = undefined;
    try openBlobs(&s3c, io);
    defer s3c.deinit();

    var standalone: cid.db.Standalone = undefined;
    try standalone.open(std.testing.allocator, conninfo);
    defer standalone.close();
    var scope = cid.db.Run.init(std.testing.allocator);
    defer scope.deinit();
    var deps: cid.api.Deps = .{ .db = &standalone.db, .s3 = &s3c, .io = io, .gpa = std.testing.allocator, .token = "test-token" };
    var direct: DirectTransport = .{ .deps = &deps, .scope = &scope, .auth = "Bearer test-token" };
    const remote: cid.client.remote.Remote = .{ .t = direct.transport(), .name = "test/datasets/ann", .gpa = std.testing.allocator };

    _ = try db.exec(&fscope, "SET cid.maintenance = 'on'", .{});
    inline for (.{ "git_writes", "refs", "commits", "item_revisions", "annotation_revisions", "dataset_items" }) |table| {
        _ = try db.exec(&fscope, "DELETE FROM " ++ table ++ " WHERE dataset_id IN (SELECT dataset_id FROM datasets WHERE name = 'test/datasets/ann')", .{});
    }
    _ = try db.exec(&fscope, "DELETE FROM datasets WHERE name = 'test/datasets/ann'", .{});
    _ = try db.exec(&fscope, "RESET cid.maintenance", .{});

    // The platform creates an annotated dataset.
    const created = cid.api.handle(arena, &deps, &scope, "POST", "/v0/datasets", "Bearer test-token", "{\"name\":\"test/datasets/ann\",\"kind\":\"annotated\",\"git_url\":\"g@h:ann.git\"}");
    try std.testing.expectEqual(std.http.Status.created, created.status);
    const ds_id: [:0]const u8 = blk: {
        break :blk try arena.dupeZ(u8, (try db.rawOne([]const u8, &fscope, "SELECT dataset_id::text FROM datasets WHERE name = 'test/datasets/ann'", .{})).?);
    };

    // Bytes go up through check-hashes presigns, then register-items
    // records them (hash-verified against storage).
    const frame1 = "frame one pixels";
    const frame2 = "frame two pixels, longer";
    var dg: [32]u8 = undefined;
    cid.hash.Hasher.hash(frame1, &dg, .{});
    const h1 = std.fmt.bytesToHex(dg, .lower);
    cid.hash.Hasher.hash(frame2, &dg, .{});
    const h2 = std.fmt.bytesToHex(dg, .lower);
    try s3c.deleteObject(&scope, try cid.api.itemKey(arena, &h1));
    try s3c.deleteObject(&scope, try cid.api.itemKey(arena, &h2));
    {
        const hz = try arena.dupeZ(u8, &h1);
        _ = db.exec(&fscope, "DELETE FROM purged_items WHERE item_hash = decode($1, 'hex')", .{hz}) catch {};
    }

    const missing = try remote.checkHashes(arena, &.{ &h1, &h2 }, &.{});
    try std.testing.expectEqual(@as(usize, 2), missing.len);
    var plain: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    defer plain.deinit();
    for (missing) |m| {
        const content: []const u8 = if (std.mem.eql(u8, m.hash, &h1)) frame1 else frame2;
        const put = try plain.fetch(.{ .location = .{ .url = m.url.? }, .method = .PUT, .payload = content, .raw_uri = true, .keep_alive = false });
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

    {
        var ptx = try db.begin(&fscope, .{});
        defer ptx.deinit();
        try platformWrite(&ptx, &fscope, ds_id);
        inline for (.{
            .{ "frames/0001.jpg", &h1, "train" },
            .{ "frames/0002.jpg", &h2, "val" },
        }, 0..) |row, idx| {
            last = cid.uuid7.Uuid.nextAfter(io, last);
            const item_id = if (idx == 0) &aitem1 else &aitem2;
            const sql = try std.fmt.allocPrintSentinel(arena, "INSERT INTO item_revisions (dataset_id, branch, path, op, item_id, item_hash, split, author) " ++
                "VALUES ('{s}', 'main', '{s}', 'add', '{s}', decode('{s}', 'hex'), '{s}', 'agent:annotator')", .{ ds_id, row[0], item_id, row[1], row[2] }, 0);
            _ = try ptx.exec(&fscope, sql, .{});
        }
        inline for (.{
            .{ &ann1, &aitem1, "{\"x\":10,\"y\":20,\"w\":30,\"h\":40}", "person" },
            .{ &ann2, &aitem1, "{\"x\":50,\"y\":60,\"w\":70,\"h\":80}", "vehicle" },
        }) |row| {
            last = cid.uuid7.Uuid.nextAfter(io, last);
            const sql = try std.fmt.allocPrintSentinel(arena, "INSERT INTO annotation_revisions (dataset_id, branch, annotation_id, item_id, op, kind, class, geometry, author, policy_ver) " ++
                "VALUES ('{s}', 'main', '{s}', '{s}', 'create', 'box', '{s}', '{s}'::jsonb, 'agent:annotator', 'policy-v1')", .{ ds_id, row[0], row[1], row[3], row[2] }, 0);
            _ = try ptx.exec(&fscope, sql, .{});
        }
        try ptx.commit();
    }

    // The server seals the batch.
    const c1 = try remote.commitServer(arena, "main", "batch one annotated", "agent:annotator");
    // A version's items and annotations, as the browse API answers them.
    const At = struct {
        items: []const struct { path: []const u8 },
        annotations: []const struct { kind: ?[]const u8, class: ?[]const u8, geometry: ?std.json.Value, author: []const u8, policy_ver: []const u8 },
    };
    const stateAt = struct {
        fn get(al: std.mem.Allocator, d: *cid.api.Deps, sc: anytype, commit: []const u8) !At {
            const res = cid.api.handle(al, d, sc, "GET", try std.fmt.allocPrint(al, "/v0/datasets/test/datasets/ann/-/browse?commit={s}&limit=200", .{commit}), "Bearer test-token", "");
            const Page = struct { items: []const struct { path: []const u8, annotations: []const @typeInfo(@FieldType(At, "annotations")).pointer.child } };
            const page = try std.json.parseFromSliceLeaky(Page, al, res.body, .{ .ignore_unknown_fields = true });
            var items: std.ArrayList(@typeInfo(@FieldType(At, "items")).pointer.child) = .empty;
            var anns: std.ArrayList(@typeInfo(@FieldType(At, "annotations")).pointer.child) = .empty;
            for (page.items) |i| {
                try items.append(al, .{ .path = i.path });
                try anns.appendSlice(al, i.annotations);
            }
            return .{ .items = items.items, .annotations = anns.items };
        }
    }.get;
    const s1 = try stateAt(arena, &deps, &scope, c1);
    try std.testing.expectEqual(@as(usize, 2), s1.items.len);
    try std.testing.expectEqual(@as(usize, 2), s1.annotations.len);
    try std.testing.expectEqualStrings("box", s1.annotations[0].kind.?);
    try std.testing.expectEqualStrings("person", s1.annotations[0].class.?);
    try std.testing.expectEqual(@as(i64, 10), s1.annotations[0].geometry.?.object.get("x").?.integer);
    try std.testing.expectEqualStrings("policy-v1", s1.annotations[0].policy_ver);

    // Nothing new → the commit is refused with a reason.
    try std.testing.expectError(error.NothingToTag, remote.commitServer(arena, "main", "empty", "agent:annotator"));

    // Batch two: move box one, delete box two.
    {
        var ptx = try db.begin(&fscope, .{});
        defer ptx.deinit();
        try platformWrite(&ptx, &fscope, ds_id);
        last = cid.uuid7.Uuid.nextAfter(io, last);
        {
            const sql = try std.fmt.allocPrintSentinel(arena, "INSERT INTO annotation_revisions (dataset_id, branch, annotation_id, item_id, op, kind, class, geometry, author, policy_ver) " ++
                "VALUES ('{s}', 'main', '{s}', '{s}', 'update', 'box', 'person', '{{\"x\":11,\"y\":21,\"w\":30,\"h\":40}}'::jsonb, 'user:reviewer', 'policy-v1')", .{ ds_id, &ann1, &aitem1 }, 0);
            _ = try ptx.exec(&fscope, sql, .{});
        }
        last = cid.uuid7.Uuid.nextAfter(io, last);
        {
            const sql = try std.fmt.allocPrintSentinel(arena, "INSERT INTO annotation_revisions (dataset_id, branch, annotation_id, item_id, op, author, policy_ver) " ++
                "VALUES ('{s}', 'main', '{s}', '{s}', 'delete', 'user:reviewer', 'policy-v1')", .{ ds_id, &ann2, &aitem1 }, 0);
            _ = try ptx.exec(&fscope, sql, .{});
        }
        try ptx.commit();
    }

    const c2 = try remote.commitServer(arena, "main", "review pass", "user:reviewer");
    const s2 = try stateAt(arena, &deps, &scope, c2);
    try std.testing.expectEqual(@as(usize, 2), s2.items.len);
    try std.testing.expectEqual(@as(usize, 1), s2.annotations.len);
    try std.testing.expectEqual(@as(i64, 11), s2.annotations[0].geometry.?.object.get("x").?.integer);
    try std.testing.expectEqualStrings("user:reviewer", s2.annotations[0].author);

    // History is history: the first commit still answers with both boxes.
    const s1_again = try stateAt(arena, &deps, &scope, c1);
    try std.testing.expectEqual(@as(usize, 2), s1_again.annotations.len);
    try std.testing.expectEqual(@as(i64, 10), s1_again.annotations[0].geometry.?.object.get("x").?.integer);

    // The drawer's history: the item's one change, sealed by the first
    // commit, and its annotations' changes newest first — the box's move
    // by the reviewer in the second commit, both versions on record.
    const hist = cid.api.handle(arena, &deps, &scope, "GET", "/v0/datasets/test/datasets/ann/-/history?path=frames%2F0001.jpg", "Bearer test-token", "");
    try std.testing.expectEqual(std.http.Status.ok, hist.status);
    const History = struct {
        path: []const u8,
        changes: []const struct { op: []const u8, commit: ?[]const u8 },
        annotations: []const struct {
            annotation_id: []const u8,
            op: []const u8,
            author: []const u8,
            geometry: ?std.json.Value,
            commit: ?[]const u8,
        },
    };
    const h = try std.json.parseFromSliceLeaky(History, arena, hist.body, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqualStrings("frames/0001.jpg", h.path);
    try std.testing.expectEqual(@as(usize, 1), h.changes.len);
    try std.testing.expectEqualStrings("add", h.changes[0].op);
    try std.testing.expectEqualStrings(c1, h.changes[0].commit.?);
    try std.testing.expect(h.annotations.len >= 3);
    const moved = for (h.annotations) |a| {
        if (std.mem.eql(u8, a.op, "update")) break a;
    } else return error.NoUpdateInHistory;
    try std.testing.expectEqualStrings("user:reviewer", moved.author);
    try std.testing.expectEqualStrings(c2, moved.commit.?);
    try std.testing.expectEqual(@as(i64, 11), moved.geometry.?.object.get("x").?.integer);
    const original = for (h.annotations) |a| {
        if (std.mem.eql(u8, a.annotation_id, moved.annotation_id) and std.mem.eql(u8, a.op, "create")) break a;
    } else return error.NoCreateInHistory;
    try std.testing.expectEqual(@as(i64, 10), original.geometry.?.object.get("x").?.integer);
    try std.testing.expectEqualStrings(c1, original.commit.?);

    // cid diff: the server compares, the changes stream in. One box moved,
    // one removed; no item changed.
    const Collected = struct {
        arena: std.mem.Allocator,
        lines: std.ArrayList([]const u8) = .empty,
        fn visit(ctx: *anyopaque, line: cid.client.remote.Remote.DiffLine) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const text = if (line.ann) |change|
                try std.fmt.allocPrint(self.arena, "ann {s} {s} {s} on {s}", .{ change, line.kind.?, line.class.?, line.item_path.? })
            else
                try std.fmt.allocPrint(self.arena, "{s} {s}", .{ line.change.?, line.path.? });
            try self.lines.append(self.arena, text);
        }
    };
    var seen: Collected = .{ .arena = arena };
    const sum = try remote.compare(arena, c1, c2, .{ .ctx = &seen, .visit = Collected.visit });
    try std.testing.expectEqual(@as(u64, 0), sum.added + sum.modified + sum.deleted);
    try std.testing.expectEqual(@as(u64, 1), sum.ann_changed);
    try std.testing.expectEqual(@as(u64, 1), sum.ann_removed);
    try std.testing.expectEqual(@as(usize, 2), seen.lines.items.len);
    try std.testing.expect(std.mem.indexOf(u8, seen.lines.items[0], "frames/0001.jpg") != null);
    var changed_seen = false;
    for (seen.lines.items) |l| {
        if (std.mem.eql(u8, l, "ann changed box person on frames/0001.jpg")) changed_seen = true;
    }
    try std.testing.expect(changed_seen);
    // Kept: asked again, served from version_diffs, the same.
    const kept_diffs = (try db.rawOne(i64, &fscope, "SELECT count(*)::bigint FROM version_diffs WHERE commit_a = $1::uuid AND commit_b = $2::uuid", .{ @as([]const u8, c1), @as([]const u8, c2) })).?;
    try std.testing.expectEqual(@as(i64, 1), kept_diffs);
    var again: Collected = .{ .arena = arena };
    const sum2 = try remote.compare(arena, c1, c2, .{ .ctx = &again, .visit = Collected.visit });
    try std.testing.expectEqual(sum.ann_changed, sum2.ann_changed);
    try std.testing.expectEqual(seen.lines.items.len, again.lines.items.len);
    // And the other way round: the box comes back.
    var back: Collected = .{ .arena = arena };
    const sum3 = try remote.compare(arena, c2, c1, .{ .ctx = &back, .visit = Collected.visit });
    try std.testing.expectEqual(@as(u64, 1), sum3.ann_added);

    // The dashboard's views of a version: a subset's size, a folder, and the
    // compare page with its visual diff (dimensions joined per page).
    {
        const size_res = cid.api.handle(arena, &deps, &scope, "GET", try std.fmt.allocPrint(arena, "/v0/datasets/test/datasets/ann/-/browse/size?commit={s}&split=train&class=vehicle", .{c1}), "Bearer test-token", "");
        try std.testing.expectEqual(std.http.Status.ok, size_res.status);
        const size = try std.json.parseFromSliceLeaky(struct { items: u64, bytes: u64, total: u64 }, arena, size_res.body, .{});
        try std.testing.expectEqual(@as(u64, 1), size.items);
        try std.testing.expectEqual(@as(u64, frame1.len), size.bytes);
        try std.testing.expectEqual(@as(u64, 2), size.total);
        const dir_res = cid.api.handle(arena, &deps, &scope, "GET", try std.fmt.allocPrint(arena, "/v0/datasets/test/datasets/ann/-/browse/dir?commit={s}&prefix=", .{c1}), "Bearer test-token", "");
        const listing = try std.json.parseFromSliceLeaky(struct { folders: []const struct { name: []const u8, items: u64 } }, arena, dir_res.body, .{ .ignore_unknown_fields = true });
        try std.testing.expectEqualStrings("frames", listing.folders[0].name);
        try std.testing.expectEqual(@as(u64, 2), listing.folders[0].items);
        const cmp_res = cid.api.handle(arena, &deps, &scope, "GET", try std.fmt.allocPrint(arena, "/v0/datasets/test/datasets/ann/-/browse/compare?a={s}&b={s}", .{ c1, c2 }), "Bearer test-token", "");
        try std.testing.expectEqual(std.http.Status.ok, cmp_res.status);
        const Side = struct { path: []const u8, hash: []const u8 };
        const cmp = try std.json.parseFromSliceLeaky(struct {
            summary: struct { ann_changed: u64, ann_removed: u64 },
            visual: []const struct { path: []const u8, before: ?Side, after: ?Side, shapes_before: []const std.json.Value, shapes_after: []const std.json.Value },
        }, arena, cmp_res.body, .{ .ignore_unknown_fields = true });
        try std.testing.expectEqual(@as(u64, 1), cmp.summary.ann_changed);
        try std.testing.expectEqual(@as(usize, 1), cmp.visual.len);
        try std.testing.expectEqualStrings("frames/0001.jpg", cmp.visual[0].path);
        try std.testing.expectEqual(@as(usize, 2), cmp.visual[0].shapes_before.len); // the moved box and the removed one
        try std.testing.expectEqual(@as(usize, 1), cmp.visual[0].shapes_after.len);
    }

    // Browse: each version as it was, a page at a time (DuckDB over the
    // version's browse index).
    var browse_tmp = std.testing.tmpDir(.{ .iterate = true });
    defer browse_tmp.cleanup();
    deps.browse_dir = try browse_tmp.dir.realPathFileAlloc(io, ".", arena);
    deps.browse_cache_max = 1;
    const Browsed = struct {
        total: u64,
        matched: u64,
        items: []const struct { path: []const u8, split: ?[]const u8, annotations: []const struct { class: ?[]const u8, geometry: ?std.json.Value } },
        next: ?[]const u8,
        open: ?struct { path: []const u8 } = null,
        facets: struct { class: []const struct { value: []const u8, count: u64 } },
        classes: []const struct { value: []const u8, count: u64 },
    };
    const browseAt = struct {
        fn get(al: std.mem.Allocator, d: *cid.api.Deps, sc: anytype, commit: []const u8, query: []const u8) !Browsed {
            const target = try std.fmt.allocPrint(al, "/v0/datasets/test/datasets/ann/-/browse?commit={s}{s}", .{ commit, query });
            const res = cid.api.handle(al, d, sc, "GET", target, "Bearer test-token", "");
            if (res.status != .ok) {
                std.debug.print("browse answered {d}: {s}\n", .{ @intFromEnum(res.status), res.body });
                return error.BrowseRefused;
            }
            return std.json.parseFromSliceLeaky(Browsed, al, res.body, .{ .ignore_unknown_fields = true });
        }
    }.get;
    const b1 = try browseAt(arena, &deps, &scope, c1, "");
    try std.testing.expectEqual(@as(u64, 2), b1.total);
    try std.testing.expectEqualStrings("frames/0001.jpg", b1.items[0].path);
    try std.testing.expectEqual(@as(usize, 2), b1.items[0].annotations.len);
    try std.testing.expectEqual(@as(usize, 2), b1.facets.class.len);
    try std.testing.expectEqualStrings("person", b1.classes[0].value);
    const vehicles = try browseAt(arena, &deps, &scope, c1, "&class=vehicle&item=frames%2F0002.jpg");
    try std.testing.expectEqual(@as(u64, 1), vehicles.matched);
    try std.testing.expectEqualStrings("frames/0002.jpg", vehicles.open.?.path);
    // The second version: one box, moved; the vehicle is gone.
    const b2 = try browseAt(arena, &deps, &scope, c2, "&q=FRAMES%2F0001");
    try std.testing.expectEqual(@as(u64, 1), b2.matched);
    try std.testing.expectEqual(@as(usize, 1), b2.items[0].annotations.len);
    try std.testing.expectEqual(@as(i64, 11), b2.items[0].annotations[0].geometry.?.object.get("x").?.integer);
    const val = try browseAt(arena, &deps, &scope, c2, "&split=val&limit=1");
    try std.testing.expectEqual(@as(u64, 1), val.matched);
    try std.testing.expectEqualStrings("val", val.items[0].split.?);
    try std.testing.expect(val.next == null);
    const paged = try browseAt(arena, &deps, &scope, c2, "&limit=1");
    try std.testing.expectEqualStrings("frames/0001.jpg", paged.next.?);
    const page2 = try browseAt(arena, &deps, &scope, c2, "&limit=1&after=frames%2F0001.jpg");
    try std.testing.expectEqualStrings("frames/0002.jpg", page2.items[0].path);
    // File types: one rule, in SQL, as every view spells them.
    for ([_][2][]const u8{
        .{ "a/b/C.JPG", ".jpg" }, .{ "README", "file" },      .{ ".cidignore", "file" },
        .{ "x.tar.gz", ".gz" },   .{ ".hidden.txt", ".txt" }, .{ "dir.d/noext", "file" },
        .{ "trailing.", "." },
    }) |case| {
        const sql_ext = (try db.rawOne([]const u8, &fscope, "SELECT " ++ comptime cid.state.extOf("$1::text"), .{case[0]})).?;
        try std.testing.expectEqualStrings(case[1], sql_ext);
    }

    // Another dataset's version, or none at all, is not browsable here.
    const stranger = cid.api.handle(arena, &deps, &scope, "GET", "/v0/datasets/test/datasets/ann/-/browse?commit=01890000-0000-7000-8000-000000000000", "Bearer test-token", "");
    try std.testing.expectEqual(std.http.Status.not_found, stranger.status);

    {
        // The cache kept one index (the limit), the most recent: both of
        // its files, and neither of the evicted one's.
        var kept: usize = 0;
        var files: usize = 0;
        var it = browse_tmp.dir.iterate();
        while (try it.next(io)) |entry| {
            if (std.mem.endsWith(u8, entry.name, ".parquet")) files += 1;
            if (std.mem.endsWith(u8, entry.name, ".items.parquet")) kept += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), kept);
        try std.testing.expectEqual(@as(usize, 2), files);
        // A release's index is kept in storage beside its manifest, even
        // when this server had built it already, so a server with an empty
        // cache fetches it rather than rebuilding.
        const tagged = try remote.tag(arena, "v-browse");
        const keys = [_][]const u8{
            try std.fmt.allocPrint(arena, "manifests/{s}/{s}.items.parquet", .{ ds_id, tagged.commit }),
            try std.fmt.allocPrint(arena, "manifests/{s}/{s}.anns.parquet", .{ ds_id, tagged.commit }),
        };
        for (keys) |key| try std.testing.expect((try s3c.headObject(&scope, key)) != null);
        var empty_cache = std.testing.tmpDir(.{});
        defer empty_cache.cleanup();
        deps.browse_dir = try empty_cache.dir.realPathFileAlloc(io, ".", arena);
        const fetched = try browseAt(arena, &deps, &scope, tagged.commit, "&q=0001");
        try std.testing.expectEqual(@as(u64, 2), fetched.total);
        try std.testing.expectEqual(@as(usize, 1), fetched.items[0].annotations.len);
        for (keys) |key| try s3c.deleteObject(&scope, key);
    }
}

/// One platform-style revision writer for the cutoff race: each
/// transaction takes the shared write lock, inserts as cid_writer (the
/// database mints the id), waits a little with the row in (a slow writer),
/// and — still holding the lock — checks no sealed commit covers it.
const RaceWriter = struct {
    ds_id: []const u8,
    rounds: u32,
    seed: u64,
    written: u32 = 0,
    violations: u32 = 0,
    failed: ?anyerror = null,

    fn run(self: *RaceWriter) void {
        self.loop() catch |err| {
            self.failed = err;
        };
    }

    fn loop(self: *RaceWriter) !void {
        const io = std.testing.io;
        var conn: cid.db.Standalone = undefined;
        try conn.open(std.testing.allocator, conninfo);
        defer conn.close();
        var prng: std.Random.DefaultPrng = .init(self.seed);
        for (0..self.rounds) |n| {
            var scope = cid.db.Run.init(std.testing.allocator);
            defer scope.deinit();
            const a = scope.arena();
            var tx = try conn.db.begin(&scope, .{});
            defer tx.deinit();
            _ = try tx.exec(&scope, "SELECT pg_advisory_xact_lock_shared(hashtextextended($1 || '/main', 0))", .{self.ds_id});
            _ = try tx.exec(&scope, "SET LOCAL ROLE cid_writer", .{});
            const path = try std.fmt.allocPrint(a, "w{d}/{d}", .{ self.seed, n });
            _ = try tx.exec(&scope, "INSERT INTO item_revisions (dataset_id, branch, path, op, item_id, item_hash, author) " ++
                "VALUES ($1::uuid, 'main', $2, 'add', $3::uuid, decode(repeat('ab', 32), 'hex'), 'agent:race')", .{
                self.ds_id, path, @as([]const u8, &cid.uuid7.Uuid.now(io).toString()),
            });
            // A slow writer: the row is in, the transaction still open.
            try std.Io.sleep(io, .fromMilliseconds(2 + prng.random().uintLessThan(u32, 9)), .awake);
            _ = try tx.exec(&scope, "RESET ROLE", .{});
            const rev = (try tx.rawOne([]const u8, &scope, "SELECT rev_id::text FROM item_revisions WHERE dataset_id = $1::uuid AND path = $2", .{ self.ds_id, path })).?;
            const covered = try tx.rawOne(i64, &scope, "SELECT count(*)::bigint FROM commits WHERE dataset_id = $1::uuid AND branch = 'main' AND cutoff_rev >= $2::uuid", .{ self.ds_id, rev });
            if (covered.? > 0) self.violations += 1;
            try tx.commit();
            self.written += 1;
        }
    }
};

test "cutoff lock: revision writers racing commits never land under a sealed cutoff" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var fixture: cid.db.Standalone = undefined;
    try openFixture(&fixture);
    defer fixture.close();
    var fscope = cid.db.Run.init(std.testing.allocator);
    defer fscope.deinit();
    const db = &fixture.db;
    _ = try runMigrations();
    var s3c: cid.blob.Client = undefined;
    try openBlobs(&s3c, io);
    defer s3c.deinit();

    var standalone: cid.db.Standalone = undefined;
    try standalone.open(std.testing.allocator, conninfo);
    defer standalone.close();
    var scope = cid.db.Run.init(std.testing.allocator);
    defer scope.deinit();
    var deps: cid.api.Deps = .{ .db = &standalone.db, .s3 = &s3c, .io = io, .gpa = std.testing.allocator, .token = "test-token" };
    var direct: DirectTransport = .{ .deps = &deps, .scope = &scope, .auth = "Bearer test-token" };
    const remote: cid.client.remote.Remote = .{ .t = direct.transport(), .name = "test/datasets/race", .gpa = std.testing.allocator };

    const created = cid.api.handle(arena, &deps, &scope, "POST", "/v0/datasets", "Bearer test-token", "{\"name\":\"test/datasets/race\",\"kind\":\"annotated\",\"git_url\":\"g@h:race.git\"}");
    try std.testing.expectEqual(std.http.Status.created, created.status);
    const ds_id = (try db.rawOne([]const u8, &fscope, "SELECT dataset_id::text FROM datasets WHERE name = 'test/datasets/race'", .{})).?;
    _ = try db.exec(&fscope, "INSERT INTO items (item_hash, size_bytes, media_type) VALUES (decode(repeat('ab', 32), 'hex'), 1, 'application/octet-stream') ON CONFLICT DO NOTHING", .{});

    // Four writers, while the server commits as fast as it can.
    var writers: [4]RaceWriter = undefined;
    var threads: [4]std.Thread = undefined;
    for (&writers, &threads, 0..) |*w, *t, i| {
        w.* = .{ .ds_id = ds_id, .rounds = 100, .seed = i + 1 };
        t.* = try std.Thread.spawn(.{}, RaceWriter.run, .{w});
    }
    var commits: u32 = 0;
    var cutoffs_seen: u32 = 0;
    while (true) {
        const done = for (writers) |w| {
            if (w.written + @intFromBool(w.failed != null) * w.rounds < w.rounds) break false;
        } else true;
        if (remote.commitServer(arena, "main", "race", "agent:race")) |_| {
            commits += 1;
        } else |err| switch (err) {
            error.NothingToTag => {},
            else => return err,
        }
        cutoffs_seen += 1;
        if (done) break;
    }
    for (threads) |t| t.join();
    for (writers) |w| {
        if (w.failed) |err| return err;
        try std.testing.expectEqual(@as(u32, 0), w.violations);
    }
    try std.testing.expect(commits >= 5);

    // Every row is under the last commit, and each commit's own rows are
    // exactly those up to its cutoff: nothing joined a sealed commit late.
    _ = remote.commitServer(arena, "main", "the rest", "agent:race") catch |err| switch (err) {
        error.NothingToTag => "",
        else => return err,
    };
    const outside = try db.rawOne(i64, &fscope, "SELECT count(*)::bigint FROM item_revisions r WHERE r.dataset_id = $1::uuid " ++
        "AND r.rev_id > (SELECT cutoff_rev FROM commits WHERE dataset_id = $1::uuid ORDER BY cutoff_rev DESC LIMIT 1)", .{ds_id});
    try std.testing.expectEqual(@as(?i64, 0), outside);

    // The backstop: a row that does land under a sealed cutoff (only the
    // owner role can still set its own id) stops the next commit, loudly,
    // until it is dealt with.
    const sealed_cutoff = (try db.rawOne([]const u8, &fscope, "SELECT cutoff_rev::text FROM commits WHERE dataset_id = $1::uuid ORDER BY cutoff_rev DESC LIMIT 1", .{ds_id})).?;
    _ = try db.exec(&fscope, "INSERT INTO item_revisions (rev_id, dataset_id, branch, path, op, item_id, item_hash, author) " ++
        "VALUES ($1::uuid, $2::uuid, 'main', 'late.txt', 'add', gen_random_uuid(), decode(repeat('ab', 32), 'hex'), 'user:late')", .{ sealed_cutoff, ds_id });
    {
        var wscope = cid.db.Run.init(std.testing.allocator);
        defer wscope.deinit();
        var ptx = try db.begin(&wscope, .{});
        defer ptx.deinit();
        try platformWrite(&ptx, &wscope, ds_id);
        _ = try ptx.exec(&wscope, "INSERT INTO item_revisions (dataset_id, branch, path, op, item_id, item_hash, author) VALUES ($1::uuid, 'main', 'next.txt', 'add', gen_random_uuid(), decode(repeat('ab', 32), 'hex'), 'agent:race')", .{ds_id});
        try ptx.commit();
    }
    const refused = cid.api.handle(arena, &deps, &scope, "POST", "/v0/datasets/test/datasets/race/-/commit", "Bearer test-token", "{\"branch\":\"main\",\"message\":\"after\",\"author\":\"agent:race\"}");
    try std.testing.expectEqual(std.http.Status.internal_server_error, refused.status);
    try std.testing.expect(std.mem.indexOf(u8, refused.body, "after it was sealed") != null);
    _ = try db.exec(&fscope, "SET cid.maintenance = 'on'", .{});
    _ = try db.exec(&fscope, "DELETE FROM item_revisions WHERE author = 'user:late'", .{});
    _ = try db.exec(&fscope, "RESET cid.maintenance", .{});
    _ = try remote.commitServer(arena, "main", "after", "agent:race");
}

test "item identity: re-encoding keeps annotations; identical files at two paths share none" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var fixture: cid.db.Standalone = undefined;
    try openFixture(&fixture);
    defer fixture.close();
    var fscope = cid.db.Run.init(std.testing.allocator);
    defer fscope.deinit();
    const db = &fixture.db;
    _ = try runMigrations();
    var s3c: cid.blob.Client = undefined;
    try openBlobs(&s3c, io);
    defer s3c.deinit();

    var standalone: cid.db.Standalone = undefined;
    try standalone.open(std.testing.allocator, conninfo);
    defer standalone.close();
    var scope = cid.db.Run.init(std.testing.allocator);
    defer scope.deinit();
    var deps: cid.api.Deps = .{ .db = &standalone.db, .s3 = &s3c, .io = io, .gpa = std.testing.allocator, .token = "test-token" };
    var direct: DirectTransport = .{ .deps = &deps, .scope = &scope, .auth = "Bearer test-token" };
    const remote: cid.client.remote.Remote = .{ .t = direct.transport(), .name = "test/datasets/ident", .gpa = std.testing.allocator };

    const created = cid.api.handle(arena, &deps, &scope, "POST", "/v0/datasets", "Bearer test-token", "{\"name\":\"test/datasets/ident\",\"kind\":\"annotated\",\"git_url\":\"g@h:ident.git\"}");
    try std.testing.expectEqual(std.http.Status.created, created.status);
    const ds_id = (try db.rawOne([]const u8, &fscope, "SELECT dataset_id::text FROM datasets WHERE name = 'test/datasets/ident'", .{})).?;

    // Three contents: a clip, the same clip re-encoded, and a photo.
    const bytes = [_][]const u8{ "ident: clip, original encoding", "ident: clip, re-encoded smaller", "ident: a photo" };
    var hashes: [bytes.len][64]u8 = undefined;
    for (bytes, &hashes) |b, *h| {
        var dg: [32]u8 = undefined;
        cid.hash.Hasher.hash(b, &dg, .{});
        h.* = std.fmt.bytesToHex(dg, .lower);
        try s3c.putObject(&scope, try cid.api.stagedKey(arena, ds_id, h), b);
    }
    try remote.registerItems(arena, &.{
        .{ .hash = &hashes[0], .size = bytes[0].len },
        .{ .hash = &hashes[1], .size = bytes[1].len },
        .{ .hash = &hashes[2], .size = bytes[2].len },
    });

    // Platform-style writes, under the shared write lock as cid_writer.
    // Platform-style batches: each its own transaction (platformWrite).
    const W = struct {
        fn item(tx: anytype, sc: anytype, al: std.mem.Allocator, dsid: []const u8, path: []const u8, op: []const u8, item_id: []const u8, hash: []const u8) !void {
            const sql = try std.fmt.allocPrintSentinel(al, "INSERT INTO item_revisions (dataset_id, branch, path, op, item_id, item_hash, author) " ++
                "VALUES ('{s}', 'main', '{s}', '{s}', '{s}', decode('{s}', 'hex'), 'agent:t')", .{ dsid, path, op, item_id, hash }, 0);
            _ = try tx.exec(sc, sql, .{});
        }
        fn box(tx: anytype, sc: anytype, al: std.mem.Allocator, i: std.Io, dsid: []const u8, item_id: []const u8, class: []const u8) !void {
            const ann = cid.uuid7.Uuid.now(i);
            const sql = try std.fmt.allocPrintSentinel(al, "INSERT INTO annotation_revisions (dataset_id, branch, annotation_id, item_id, op, kind, class, geometry, author, policy_ver) " ++
                "VALUES ('{s}', 'main', '{s}', '{s}', 'create', 'box', '{s}', '{{\"x\":1,\"y\":2,\"w\":3,\"h\":4}}'::jsonb, 'agent:t', 'p1')", .{ dsid, &ann.toString(), item_id, class }, 0);
            _ = try tx.exec(sc, sql, .{});
        }
    };
    const clip_id = cid.uuid7.Uuid.now(io).toString();
    const photo_id = cid.uuid7.Uuid.nextAfter(io, cid.uuid7.Uuid.now(io)).toString();
    const copy_id = cid.uuid7.Uuid.nextAfter(io, cid.uuid7.Uuid.parse(&photo_id) catch unreachable).toString();

    // The clip and the photo, each annotated; the same photo bytes again
    // at a second path — a separate item, with no annotation of its own.
    {
        var ptx = try db.begin(&fscope, .{});
        defer ptx.deinit();
        try platformWrite(&ptx, &fscope, ds_id);
        try W.item(&ptx, &fscope, arena, ds_id, "clips/a.mp4", "add", &clip_id, &hashes[0]);
        try W.item(&ptx, &fscope, arena, ds_id, "photos/p.jpg", "add", &photo_id, &hashes[2]);
        try W.item(&ptx, &fscope, arena, ds_id, "photos/copy-of-p.jpg", "add", &copy_id, &hashes[2]);
        try W.box(&ptx, &fscope, arena, io, ds_id, &clip_id, "person");
        try W.box(&ptx, &fscope, arena, io, ds_id, &photo_id, "car");
        try ptx.commit();
    }
    const c1 = try remote.commitServer(arena, "main", "first batch", "agent:t");

    // Re-encoding: new bytes at the same path, the same item_id.
    {
        var ptx = try db.begin(&fscope, .{});
        defer ptx.deinit();
        try platformWrite(&ptx, &fscope, ds_id);
        try W.item(&ptx, &fscope, arena, ds_id, "clips/a.mp4", "update", &clip_id, &hashes[1]);
        try ptx.commit();
    }
    const c2 = try remote.commitServer(arena, "main", "re-encode", "agent:t");

    const Page = struct { items: []const struct { path: []const u8, hash: []const u8, annotations: []const struct { class: ?[]const u8 } } };
    const classesAt = struct {
        fn get(al: std.mem.Allocator, d: *cid.api.Deps, sc: anytype, commit: []const u8) !Page {
            const res = cid.api.handle(al, d, sc, "GET", try std.fmt.allocPrint(al, "/v0/datasets/test/datasets/ident/-/browse?commit={s}&limit=200", .{commit}), "Bearer test-token", "");
            if (res.status != .ok) return error.BrowseRefused;
            return std.json.parseFromSliceLeaky(Page, al, res.body, .{ .ignore_unknown_fields = true });
        }
    }.get;
    for ([_][]const u8{ c1, c2 }, 0..) |commit, n| {
        const page = try classesAt(arena, &deps, &scope, commit);
        try std.testing.expectEqual(@as(usize, 3), page.items.len);
        for (page.items) |it| {
            if (std.mem.eql(u8, it.path, "clips/a.mp4")) {
                // Its box survives the new bytes.
                try std.testing.expectEqualStrings(&hashes[if (n == 0) 0 else 1], it.hash);
                try std.testing.expectEqual(@as(usize, 1), it.annotations.len);
                try std.testing.expectEqualStrings("person", it.annotations[0].class.?);
            } else if (std.mem.eql(u8, it.path, "photos/p.jpg")) {
                try std.testing.expectEqual(@as(usize, 1), it.annotations.len);
            } else {
                // Same bytes as the photo; none of its annotations.
                try std.testing.expectEqualStrings(&hashes[2], it.hash);
                try std.testing.expectEqual(@as(usize, 0), it.annotations.len);
            }
        }
    }
}

test "annotated releases: v2 manifest with JCS rows, verify catches smuggled boxes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var fixture: cid.db.Standalone = undefined;
    try openFixture(&fixture);
    defer fixture.close();
    var fscope = cid.db.Run.init(std.testing.allocator);
    defer fscope.deinit();
    const db = &fixture.db;
    _ = try runMigrations();
    var s3c: cid.blob.Client = undefined;
    try openBlobs(&s3c, io);
    defer s3c.deinit();

    var standalone: cid.db.Standalone = undefined;
    try standalone.open(std.testing.allocator, conninfo);
    defer standalone.close();
    var scope = cid.db.Run.init(std.testing.allocator);
    defer scope.deinit();
    var deps: cid.api.Deps = .{ .db = &standalone.db, .s3 = &s3c, .io = io, .gpa = std.testing.allocator, .token = "test-token" };
    var direct: DirectTransport = .{ .deps = &deps, .scope = &scope, .auth = "Bearer test-token" };
    const remote: cid.client.remote.Remote = .{ .t = direct.transport(), .name = "test/datasets/annrel", .gpa = std.testing.allocator };

    _ = try db.exec(&fscope, "SET cid.maintenance = 'on'", .{});
    inline for (.{ "git_writes", "refs", "commits", "item_revisions", "annotation_revisions", "dataset_items" }) |table| {
        _ = try db.exec(&fscope, "DELETE FROM " ++ table ++ " WHERE dataset_id IN (SELECT dataset_id FROM datasets WHERE name = 'test/datasets/annrel')", .{});
    }
    _ = try db.exec(&fscope, "DELETE FROM datasets WHERE name = 'test/datasets/annrel'", .{});
    _ = try db.exec(&fscope, "RESET cid.maintenance", .{});

    _ = cid.api.handle(arena, &deps, &scope, "POST", "/v0/datasets", "Bearer test-token", "{\"name\":\"test/datasets/annrel\",\"kind\":\"annotated\",\"git_url\":\"g@h:ar.git\"}");
    const ds_id: [:0]const u8 = blk: {
        break :blk try arena.dupeZ(u8, (try db.rawOne([]const u8, &fscope, "SELECT dataset_id::text FROM datasets WHERE name = 'test/datasets/annrel'", .{})).?);
    };

    // One image with one box, platform-style (bytes + register + revisions).
    const pix = "annrel pixels";
    var dg: [32]u8 = undefined;
    cid.hash.Hasher.hash(pix, &dg, .{});
    const hh = std.fmt.bytesToHex(dg, .lower);
    try s3c.putObject(&scope, try cid.api.stagedKey(arena, ds_id, &hh), pix);
    try remote.registerItems(arena, &.{.{ .hash = &hh, .size = pix.len }});

    var last = cid.uuid7.Uuid.now(io);
    const item_id = cid.uuid7.Uuid.now(io).toString();
    const box_id = cid.uuid7.Uuid.now(io).toString();
    {
        var ptx = try db.begin(&fscope, .{});
        defer ptx.deinit();
        try platformWrite(&ptx, &fscope, ds_id);
        {
            const sql = try std.fmt.allocPrintSentinel(arena, "INSERT INTO item_revisions (dataset_id, branch, path, op, item_id, item_hash, split, author) " ++
                "VALUES ('{s}', 'main', 'img/a.jpg', 'add', '{s}', decode('{s}', 'hex'), 'train', 'agent:annotator')", .{ ds_id, &item_id, &hh }, 0);
            _ = try ptx.exec(&fscope, sql, .{});
        }
        last = cid.uuid7.Uuid.nextAfter(io, last);
        {
            // Written messy on purpose: unsorted keys, 10.0 instead of 10.
            const sql = try std.fmt.allocPrintSentinel(arena, "INSERT INTO annotation_revisions (dataset_id, branch, annotation_id, item_id, op, kind, class, geometry, author, policy_ver) " ++
                "VALUES ('{s}', 'main', '{s}', '{s}', 'create', 'box', 'person', " ++
                "'{{\"y\": 20, \"x\": 10.0, \"w\": 30.5, \"h\": 40}}'::jsonb, 'agent:annotator', 'policy-v1')", .{ ds_id, &box_id, &item_id }, 0);
            _ = try ptx.exec(&fscope, sql, .{});
        }
        try ptx.commit();
    }
    _ = try remote.commitServer(arena, "main", "one box", "agent:annotator");

    // Tag: the stored manifest names the item's identity on its item row,
    // and the annotation row (in JCS form) points at it.
    const t = try remote.tag(arena, "v1.0.0");
    try std.testing.expectEqual(@as(u64, 1), t.items);
    const mkey = try cid.release.manifestKey(arena, ds_id, t.commit);
    const stored = try s3c.getObjectAlloc(&scope, mkey);
    try std.testing.expect(std.mem.startsWith(u8, stored, cid.canonical.header));
    const item_row = try std.fmt.allocPrint(arena, "item\timg/a.jpg\t{s}\t", .{&item_id});
    try std.testing.expect(std.mem.indexOf(u8, stored, item_row) != null);
    const ann_line = try std.fmt.allocPrint(arena, "ann\t{s}\t{s}\tbox\tperson\t{{\"h\":40,\"w\":30.5,\"x\":10,\"y\":20}}\t-\tagent:annotator\tpolicy-v1\n", .{ &item_id, &box_id });
    try std.testing.expect(std.mem.indexOf(u8, stored, ann_line) != null);

    // Verify: green, repeatably.
    const v1 = try cid.release.verify(arena, std.testing.allocator, &standalone.db, &scope, &s3c, ds_id, "v1.0.0");
    try std.testing.expect(v1.ok);

    // A box smuggled under the sealed cutoff turns verify red.
    const old_uuid = cid.uuid7.Uuid.init(last.unixMs() - 10_000, @splat(3));
    {
        const sql = try std.fmt.allocPrintSentinel(arena, "INSERT INTO annotation_revisions (rev_id, ts, dataset_id, branch, annotation_id, item_id, op, kind, class, geometry, author, policy_ver) " ++
            "VALUES ('{s}', to_timestamp({d}), '{s}', 'main', gen_random_uuid(), '{s}', 'create', 'box', 'smuggled', '{{\"x\":1}}'::jsonb, 'user:evil', 'policy-v1')", .{ &old_uuid.toString(), old_uuid.unixMs() / 1000, ds_id, &item_id }, 0);
        _ = try db.exec(&fscope, sql, .{});
    }
    const v2 = try cid.release.verify(arena, std.testing.allocator, &standalone.db, &scope, &s3c, ds_id, "v1.0.0");
    try std.testing.expect(!v2.ok);
    try std.testing.expectEqual(cid.release.VerifyProblem.recomputed_hash_differs, v2.problems[0]);
    _ = try db.exec(&fscope, "SET cid.maintenance = 'on'", .{});
    _ = try db.exec(&fscope, "DELETE FROM annotation_revisions WHERE author = 'user:evil'", .{});
    _ = try db.exec(&fscope, "RESET cid.maintenance", .{});
    const v3 = try cid.release.verify(arena, std.testing.allocator, &standalone.db, &scope, &s3c, ds_id, "v1.0.0");
    try std.testing.expect(v3.ok);
}

test "annotated clone --format: jsonl and yolo sidecars, clean status, pull regenerates" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var fixture: cid.db.Standalone = undefined;
    try openFixture(&fixture);
    defer fixture.close();
    var fscope = cid.db.Run.init(std.testing.allocator);
    defer fscope.deinit();
    const db = &fixture.db;
    _ = try runMigrations();
    var s3c: cid.blob.Client = undefined;
    try openBlobs(&s3c, io);
    defer s3c.deinit();

    var standalone: cid.db.Standalone = undefined;
    try standalone.open(std.testing.allocator, conninfo);
    defer standalone.close();
    var scope = cid.db.Run.init(std.testing.allocator);
    defer scope.deinit();
    var deps: cid.api.Deps = .{ .db = &standalone.db, .s3 = &s3c, .io = io, .gpa = std.testing.allocator, .token = "test-token" };
    var direct: DirectTransport = .{ .deps = &deps, .scope = &scope, .auth = "Bearer test-token" };
    const remote: cid.client.remote.Remote = .{ .t = direct.transport(), .name = "test/datasets/fmt", .gpa = std.testing.allocator };

    _ = try db.exec(&fscope, "SET cid.maintenance = 'on'", .{});
    inline for (.{ "git_writes", "refs", "commits", "item_revisions", "annotation_revisions", "dataset_items" }) |table| {
        _ = try db.exec(&fscope, "DELETE FROM " ++ table ++ " WHERE dataset_id IN (SELECT dataset_id FROM datasets WHERE name = 'test/datasets/fmt')", .{});
    }
    _ = try db.exec(&fscope, "DELETE FROM datasets WHERE name = 'test/datasets/fmt'", .{});
    _ = try db.exec(&fscope, "RESET cid.maintenance", .{});

    _ = cid.api.handle(arena, &deps, &scope, "POST", "/v0/datasets", "Bearer test-token", "{\"name\":\"test/datasets/fmt\",\"kind\":\"annotated\",\"git_url\":\"g@h:f.git\"}");
    const ds_id: [:0]const u8 = blk: {
        break :blk try arena.dupeZ(u8, (try db.rawOne([]const u8, &fscope, "SELECT dataset_id::text FROM datasets WHERE name = 'test/datasets/fmt'", .{})).?);
    };

    // One 640x480 image with one person box, platform-style.
    const pix = "fmt pixels pretending to be a jpeg";
    var dg: [32]u8 = undefined;
    cid.hash.Hasher.hash(pix, &dg, .{});
    const hh = std.fmt.bytesToHex(dg, .lower);
    try s3c.putObject(&scope, try cid.api.stagedKey(arena, ds_id, &hh), pix);
    try remote.registerItems(arena, &.{.{ .hash = &hh, .size = pix.len, .media_type = "image/jpeg", .width = 640, .height = 480 }});

    // Registering enqueues exactly one preview per content hash, ever —
    // re-registering (or any number of viewers later) adds nothing.
    try remote.registerItems(arena, &.{.{ .hash = &hh, .size = pix.len, .media_type = "image/jpeg", .width = 640, .height = 480 }});
    {
        const hz = try arena.dupeZ(u8, &hh);
        const Queue = struct {
            pub const nilo_table = .projection;
            n: i64,
            status: ?[]const u8,
        };
        const prow = try db.rawExactlyOne(Queue, &fscope, "SELECT count(*) AS n, min(status) AS status FROM previews WHERE item_hash = decode($1, 'hex')", .{hz});
        try std.testing.expectEqual(@as(i64, 1), prow.n);
        try std.testing.expectEqualStrings("pending", prow.status.?);
    }

    var last = cid.uuid7.Uuid.now(io);
    const fitem = cid.uuid7.Uuid.now(io).toString();
    const fbox = cid.uuid7.Uuid.now(io).toString();
    {
        var ptx = try db.begin(&fscope, .{});
        defer ptx.deinit();
        try platformWrite(&ptx, &fscope, ds_id);
        {
            const sql = try std.fmt.allocPrintSentinel(arena, "INSERT INTO item_revisions (dataset_id, branch, path, op, item_id, item_hash, split, author) " ++
                "VALUES ('{s}', 'main', 'img/a.jpg', 'add', '{s}', decode('{s}', 'hex'), 'train', 'agent:annotator')", .{ ds_id, &fitem, &hh }, 0);
            _ = try ptx.exec(&fscope, sql, .{});
        }
        last = cid.uuid7.Uuid.nextAfter(io, last);
        {
            const sql = try std.fmt.allocPrintSentinel(arena, "INSERT INTO annotation_revisions (dataset_id, branch, annotation_id, item_id, op, kind, class, geometry, author, policy_ver) " ++
                "VALUES ('{s}', 'main', '{s}', '{s}', 'create', 'box', 'person', '{{\"x\":32,\"y\":48,\"w\":64,\"h\":96}}'::jsonb, 'agent:annotator', 'p1')", .{ ds_id, &fbox, &fitem }, 0);
            _ = try ptx.exec(&fscope, sql, .{});
        }
        try ptx.commit();
    }
    _ = try remote.commitServer(arena, "main", "one box", "agent:annotator");

    // Clone as jsonl: item file plus the sidecar, and a clean status.
    var jl_dir = std.testing.tmpDir(.{ .iterate = true });
    defer jl_dir.cleanup();
    var cache = std.testing.tmpDir(.{});
    defer cache.cleanup();
    const jl = try cid.client.sync.clone(arena, io, jl_dir.dir, cache.dir, &remote, "cid@test:test/datasets/fmt", null, "jsonl", .{});
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
    _ = try cid.client.sync.clone(arena, io, yo_dir.dir, cache.dir, &remote, "cid@test:test/datasets/fmt", null, "yolo", .{});
    try std.testing.expectEqualStrings("person\n", try readWholeFile(io, yo_dir.dir, "classes.txt", arena));
    try std.testing.expectEqualStrings(
        "0 0.100000 0.200000 0.100000 0.200000\n",
        try readWholeFile(io, yo_dir.dir, "labels/img/a.txt", arena),
    );
    try std.testing.expectEqualStrings("img/a.jpg\n", try readWholeFile(io, yo_dir.dir, "train.txt", arena));
    const yaml = try readWholeFile(io, yo_dir.dir, "dataset.yaml", arena);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "0: person") != null);

    // The platform adds a vehicle box; a pull regenerates the sidecars.
    {
        var ptx = try db.begin(&fscope, .{});
        defer ptx.deinit();
        try platformWrite(&ptx, &fscope, ds_id);
        last = cid.uuid7.Uuid.nextAfter(io, last);
        {
            const sql = try std.fmt.allocPrintSentinel(arena, "INSERT INTO annotation_revisions (dataset_id, branch, annotation_id, item_id, op, kind, class, geometry, author, policy_ver) " ++
                "VALUES ('{s}', 'main', gen_random_uuid(), '{s}', 'create', 'box', 'vehicle', '{{\"x\":0,\"y\":0,\"w\":320,\"h\":240}}'::jsonb, 'agent:annotator', 'p1')", .{ ds_id, &fitem }, 0);
            _ = try ptx.exec(&fscope, sql, .{});
        }
        try ptx.commit();
    }
    _ = try remote.commitServer(arena, "main", "vehicle too", "agent:annotator");

    var yo_ws = try cid.client.workspace.open(arena, io, yo_dir.dir);
    const pulled = try cid.client.sync.pull(arena, io, &yo_ws, cache.dir, &remote);
    try std.testing.expect(pulled == .fast_forwarded);
    try std.testing.expectEqualStrings("person\nvehicle\n", try readWholeFile(io, yo_dir.dir, "classes.txt", arena));
    const label2 = try readWholeFile(io, yo_dir.dir, "labels/img/a.txt", arena);
    try std.testing.expect(std.mem.indexOf(u8, label2, "1 0.250000 0.250000 0.500000 0.500000") != null);

    // A subset clone: --class vehicle keeps the frame (it carries one) and
    // narrows its labels to vehicle, which becomes class 0 of its own map.
    var sub_dir = std.testing.tmpDir(.{ .iterate = true });
    defer sub_dir.cleanup();
    const sub = try cid.client.sync.clone(arena, io, sub_dir.dir, cache.dir, &remote, "cid@test:test/datasets/fmt", null, "yolo", .{
        .split = &.{"train"},
        .class = &.{"vehicle"},
    });
    try std.testing.expectEqual(@as(u32, 1), sub.files);
    try std.testing.expectEqual(@as(u32, 1), sub.total);
    try std.testing.expectEqualStrings("vehicle\n", try readWholeFile(io, sub_dir.dir, "classes.txt", arena));
    const sub_label = try readWholeFile(io, sub_dir.dir, "labels/img/a.txt", arena);
    try std.testing.expectEqualStrings("0 0.250000 0.250000 0.500000 0.500000\n", sub_label);

    // The folder remembers the subset, refuses to record changes, and a
    // pull keeps the same shape.
    var sub_ws = try cid.client.workspace.open(arena, io, sub_dir.dir);
    try std.testing.expectEqualStrings("vehicle", sub_ws.config.class[0]);
    try std.testing.expect(cid.client.workspace.readOnlyReason(arena, sub_ws.config) != null);
    const sub_pulled = try cid.client.sync.pull(arena, io, &sub_ws, cache.dir, &remote);
    try std.testing.expect(sub_pulled == .already_up_to_date);
    try std.testing.expectEqualStrings("vehicle\n", try readWholeFile(io, sub_dir.dir, "classes.txt", arena));

    // A subset nothing matches is refused before a folder is written.
    var none_dir = std.testing.tmpDir(.{ .iterate = true });
    defer none_dir.cleanup();
    try std.testing.expectError(error.EmptySubset, cid.client.sync.clone(arena, io, none_dir.dir, cache.dir, &remote, "cid@test:test/datasets/fmt", null, "yolo", .{
        .split = &.{"val"},
    }));
    try std.testing.expectError(error.NotADataset, cid.client.workspace.open(arena, io, none_dir.dir));
}

test "annotated git writer: classes.yaml, policy.md and per-class stats land" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var fixture: cid.db.Standalone = undefined;
    try openFixture(&fixture);
    defer fixture.close();
    var fscope = cid.db.Run.init(std.testing.allocator);
    defer fscope.deinit();
    const db = &fixture.db;
    _ = try runMigrations();
    var s3c: cid.blob.Client = undefined;
    try openBlobs(&s3c, io);
    defer s3c.deinit();

    var git_root = std.testing.tmpDir(.{ .iterate = true });
    defer git_root.cleanup();
    var root_path_buf: [512]u8 = undefined;
    const root_len = try git_root.dir.realPath(io, &root_path_buf);
    const root_path = root_path_buf[0..root_len];
    const bare_url = try std.fmt.allocPrint(arena, "{s}/ann.git", .{root_path});
    const work_root = try std.fmt.allocPrint(arena, "{s}/work", .{root_path});
    const clone_dir = try std.fmt.allocPrint(arena, "{s}/check", .{root_path});
    _ = try std.process.run(arena, io, .{ .argv = &.{ "git", "init", "--bare", "-b", "main", bare_url } });

    var standalone: cid.db.Standalone = undefined;
    try standalone.open(std.testing.allocator, conninfo);
    defer standalone.close();
    var scope = cid.db.Run.init(std.testing.allocator);
    defer scope.deinit();
    var deps: cid.api.Deps = .{
        .db = &standalone.db,
        .s3 = &s3c,
        .io = io,
        .gpa = std.testing.allocator,
        .token = "test-token",
        .git = .{ .workdir = work_root, .server_url = "https://cid.example" },
    };
    var direct: DirectTransport = .{ .deps = &deps, .scope = &scope, .auth = "Bearer test-token" };
    const remote: cid.client.remote.Remote = .{ .t = direct.transport(), .name = "test/datasets/anngit", .gpa = std.testing.allocator };

    _ = try db.exec(&fscope, "SET cid.maintenance = 'on'", .{});
    inline for (.{ "git_writes", "refs", "commits", "item_revisions", "annotation_revisions", "dataset_items", "policy_versions" }) |table| {
        _ = try db.exec(&fscope, "DELETE FROM " ++ table ++ " WHERE dataset_id IN (SELECT dataset_id FROM datasets WHERE name = 'test/datasets/anngit')", .{});
    }
    _ = try db.exec(&fscope, "DELETE FROM datasets WHERE name = 'test/datasets/anngit'", .{});
    _ = try db.exec(&fscope, "RESET cid.maintenance", .{});

    const create_body = try std.fmt.allocPrint(arena, "{{\"name\":\"test/datasets/anngit\",\"kind\":\"annotated\",\"git_url\":\"{s}\"}}", .{bare_url});
    _ = cid.api.handle(arena, &deps, &scope, "POST", "/v0/datasets", "Bearer test-token", create_body);
    const ds_id: [:0]const u8 = blk: {
        break :blk try arena.dupeZ(u8, (try db.rawOne([]const u8, &fscope, "SELECT dataset_id::text FROM datasets WHERE name = 'test/datasets/anngit'", .{})).?);
    };

    // The policy, then one image with a person and a vehicle box.
    const pol = cid.api.handle(arena, &deps, &scope, "POST", "/v0/datasets/test/datasets/anngit/-/policy", "Bearer test-token", "{\"version\":\"policy-v3\",\"body\":{\"rule\":\"label every visible person\"}}");
    try std.testing.expectEqual(std.http.Status.created, pol.status);
    const pol_again = cid.api.handle(arena, &deps, &scope, "POST", "/v0/datasets/test/datasets/anngit/-/policy", "Bearer test-token", "{\"version\":\"policy-v3\",\"body\":{}}");
    try std.testing.expectEqual(std.http.Status.conflict, pol_again.status);

    const pix = "anngit pixels";
    var dg: [32]u8 = undefined;
    cid.hash.Hasher.hash(pix, &dg, .{});
    const hh = std.fmt.bytesToHex(dg, .lower);
    try s3c.putObject(&scope, try cid.api.stagedKey(arena, ds_id, &hh), pix);
    try remote.registerItems(arena, &.{.{ .hash = &hh, .size = pix.len, .width = 100, .height = 100 }});

    var last = cid.uuid7.Uuid.now(io);
    const gitem = cid.uuid7.Uuid.now(io).toString();
    {
        var ptx = try db.begin(&fscope, .{});
        defer ptx.deinit();
        try platformWrite(&ptx, &fscope, ds_id);
        {
            const sql = try std.fmt.allocPrintSentinel(arena, "INSERT INTO item_revisions (dataset_id, branch, path, op, item_id, item_hash, split, author) " ++
                "VALUES ('{s}', 'main', 'f.jpg', 'add', '{s}', decode('{s}', 'hex'), 'train', 'agent:a')", .{ ds_id, &gitem, &hh }, 0);
            _ = try ptx.exec(&fscope, sql, .{});
        }
        inline for (.{ "person", "person", "vehicle" }) |class| {
            last = cid.uuid7.Uuid.nextAfter(io, last);
            const sql = try std.fmt.allocPrintSentinel(arena, "INSERT INTO annotation_revisions (dataset_id, branch, annotation_id, item_id, op, kind, class, geometry, author, policy_ver) " ++
                "VALUES ('{s}', 'main', gen_random_uuid(), '{s}', 'create', 'box', '" ++ class ++ "', '{{\"x\":1,\"y\":1,\"w\":2,\"h\":2}}'::jsonb, 'agent:a', 'policy-v3')", .{ ds_id, &gitem }, 0);
            _ = try ptx.exec(&fscope, sql, .{});
        }
        try ptx.commit();
    }
    _ = try remote.commitServer(arena, "main", "labelled", "agent:a");
    _ = try remote.tag(arena, "v1.0.0");

    // The git write happened inline (deps.git set); inspect the repo.
    _ = try std.process.run(arena, io, .{ .argv = &.{ "git", "clone", bare_url, clone_dir } });
    var check = try std.Io.Dir.cwd().openDir(io, clone_dir, .{ .iterate = true });
    defer check.close(io);
    const classes = try check.readFileAlloc(io, "classes.yaml", arena, .limited(4096));
    try std.testing.expectEqualStrings("0: person\n1: vehicle\n", classes);
    const policy_md = try check.readFileAlloc(io, "policy.md", arena, .limited(16 * 1024));
    try std.testing.expect(std.mem.indexOf(u8, policy_md, "policy-v3") != null);
    try std.testing.expect(std.mem.indexOf(u8, policy_md, "label every visible person") != null);
    const stats = try check.readFileAlloc(io, "stats.yaml", arena, .limited(16 * 1024));
    try std.testing.expect(std.mem.indexOf(u8, stats, "annotations: 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, stats, "\"person\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, stats, "\"vehicle\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, stats, "\"train\": 1") != null);
}

test "preview worker: builds image thumbs under discipline, skips the rest" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var fixture: cid.db.Standalone = undefined;
    try openFixture(&fixture);
    defer fixture.close();
    var fscope = cid.db.Run.init(std.testing.allocator);
    defer fscope.deinit();
    const db = &fixture.db;
    _ = try runMigrations();
    var s3c: cid.blob.Client = undefined;
    try openBlobs(&s3c, io);
    defer s3c.deinit();

    // A real PNG, made by ffmpeg itself.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var png_path_buf: [512]u8 = undefined;
    const tmp_len = try tmp.dir.realPath(io, &png_path_buf);
    const png_path = try std.fmt.allocPrint(arena, "{s}/t.png", .{png_path_buf[0..tmp_len]});
    _ = try std.process.run(arena, io, .{ .argv = &.{
        "ffmpeg", "-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=size=64x64:rate=1", "-frames:v", "1", png_path,
    } });
    const png = try std.Io.Dir.cwd().readFileAlloc(io, png_path, arena, .limited(1024 * 1024));

    var dg: [32]u8 = undefined;
    cid.hash.Hasher.hash(png, &dg, .{});
    const png_hash = std.fmt.bytesToHex(dg, .lower);
    const text = "just text, never a thumbnail";
    cid.hash.Hasher.hash(text, &dg, .{});
    const text_hash = std.fmt.bytesToHex(dg, .lower);

    // Earlier tests enqueued their pushes too; park that backlog so this
    // pass is about our two rows.
    _ = try db.exec(&fscope, "UPDATE previews SET status = 'skipped', reason = 'test reset' WHERE status = 'pending'", .{});

    // Reset queue rows and objects from earlier runs.
    inline for (.{ &png_hash, &text_hash }) |h| {
        const hz = try arena.dupeZ(u8, h);
        _ = db.exec(&fscope, "DELETE FROM previews WHERE item_hash = decode($1, 'hex')", .{hz}) catch {};
        _ = db.exec(&fscope, "DELETE FROM purged_items WHERE item_hash = decode($1, 'hex')", .{hz}) catch {};
    }
    try s3c.deleteObject(&fscope, try cid.preview.thumbKey(arena, &png_hash));

    // Ingest both platform-style on an existing dataset.
    var standalone: cid.db.Standalone = undefined;
    try standalone.open(std.testing.allocator, conninfo);
    defer standalone.close();
    var scope = cid.db.Run.init(std.testing.allocator);
    defer scope.deinit();
    var deps: cid.api.Deps = .{ .db = &standalone.db, .s3 = &s3c, .io = io, .gpa = std.testing.allocator, .token = "test-token" };
    var direct: DirectTransport = .{ .deps = &deps, .scope = &scope, .auth = "Bearer test-token" };
    const remote: cid.client.remote.Remote = .{ .t = direct.transport(), .name = "test/datasets/fmt", .gpa = std.testing.allocator };
    const fmt_id = (try db.rawOne([]const u8, &scope, "SELECT dataset_id::text FROM datasets WHERE name = 'test/datasets/fmt'", .{})).?;
    try s3c.putObject(&scope, try cid.api.stagedKey(arena, fmt_id, &png_hash), png);
    try s3c.putObject(&scope, try cid.api.stagedKey(arena, fmt_id, &text_hash), text);
    try remote.registerItems(arena, &.{
        .{ .hash = &png_hash, .size = png.len, .media_type = "image/png" },
        .{ .hash = &text_hash, .size = text.len, .media_type = "text/plain" },
    });

    // One pass: the image builds, the text is skipped with its reason.
    const pass = try cid.preview.processPending(arena, io, &standalone.db, &scope, &s3c, .{});
    try std.testing.expect(pass.built >= 1);
    try std.testing.expect(pass.skipped >= 1);

    const thumb = try s3c.getObjectAlloc(&scope, try cid.preview.thumbKey(arena, &png_hash));
    try std.testing.expect(thumb.len > 100); // a real webp came out

    {
        const hz = try arena.dupeZ(u8, &text_hash);
        const Prev = struct {
            pub const nilo_table = .projection;
            status: []const u8,
            reason: ?[]const u8,
        };
        const prev = try db.rawExactlyOne(Prev, &fscope, "SELECT status, reason FROM previews WHERE item_hash = decode($1, 'hex')", .{hz});
        try std.testing.expectEqualStrings("skipped", prev.status);
        try std.testing.expect(std.mem.indexOf(u8, prev.reason orelse "", "no thumbnail") != null);
    }

    // A second pass does nothing: one build per content hash, ever.
    const again = try cid.preview.processPending(arena, io, &standalone.db, &scope, &s3c, .{});
    try std.testing.expectEqual(@as(u32, 0), again.built);

    // The thumbs endpoint answers only for finished previews.
    const body = try std.fmt.allocPrint(arena, "{{\"hashes\":[\"{s}\",\"{s}\"]}}", .{ &png_hash, &text_hash });
    const res = cid.api.handle(arena, &deps, &scope, "POST", "/v0/datasets/test/datasets/fmt/-/thumbs", "Bearer test-token", body);
    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expect(std.mem.indexOf(u8, res.body, &png_hash) != null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, &text_hash) == null);
}

test "sniffing: a CLI-pushed PNG earns its type, dimensions and preview" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var fixture: cid.db.Standalone = undefined;
    try openFixture(&fixture);
    defer fixture.close();
    var fscope = cid.db.Run.init(std.testing.allocator);
    defer fscope.deinit();
    const db = &fixture.db;
    _ = try runMigrations();
    var s3c: cid.blob.Client = undefined;
    try openBlobs(&s3c, io);
    defer s3c.deinit();

    // A real PNG, pushed the CLI way: the server records octet-stream.
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buf: [512]u8 = undefined;
    const tlen = try tmp.dir.realPath(io, &buf);
    const png_path = try std.fmt.allocPrint(arena, "{s}/cli.png", .{buf[0..tlen]});
    _ = try std.process.run(arena, io, .{ .argv = &.{
        "ffmpeg", "-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=size=96x64:rate=1", "-frames:v", "1", "-y", png_path,
    } });
    const png = try std.Io.Dir.cwd().readFileAlloc(io, png_path, arena, .limited(1024 * 1024));
    var dg: [32]u8 = undefined;
    cid.hash.Hasher.hash(png, &dg, .{});
    const hh = std.fmt.bytesToHex(dg, .lower);

    _ = try db.exec(&fscope, "UPDATE previews SET status = 'skipped', reason = 'test reset' WHERE status = 'pending'", .{});
    {
        const hz = try arena.dupeZ(u8, &hh);
        _ = db.exec(&fscope, "DELETE FROM previews WHERE item_hash = decode($1, 'hex')", .{hz}) catch {};
        _ = db.exec(&fscope, "DELETE FROM items WHERE item_hash = decode($1, 'hex') AND NOT EXISTS (SELECT 1 FROM item_revisions ir WHERE ir.item_hash = decode($1, 'hex'))", .{hz}) catch {};
    }
    try s3c.deleteObject(&fscope, try cid.preview.thumbKey(arena, &hh));

    var standalone: cid.db.Standalone = undefined;
    try standalone.open(std.testing.allocator, conninfo);
    defer standalone.close();
    var scope = cid.db.Run.init(std.testing.allocator);
    defer scope.deinit();
    var deps: cid.api.Deps = .{ .db = &standalone.db, .s3 = &s3c, .io = io, .gpa = std.testing.allocator, .token = "test-token" };
    var producer = std.testing.tmpDir(.{ .iterate = true });
    defer producer.cleanup();
    var cache = std.testing.tmpDir(.{});
    defer cache.cleanup();
    var direct: DirectTransport = .{ .deps = &deps, .scope = &scope, .auth = "Bearer test-token" };
    const remote: cid.client.remote.Remote = .{ .t = direct.transport(), .name = "test/datasets/sniff", .gpa = std.testing.allocator };
    _ = try db.exec(&fscope, "SET cid.maintenance = 'on'", .{});
    inline for (.{ "git_writes", "refs", "commits", "item_revisions", "dataset_items" }) |table| {
        _ = try db.exec(&fscope, "DELETE FROM " ++ table ++ " WHERE dataset_id IN (SELECT dataset_id FROM datasets WHERE name = 'test/datasets/sniff')", .{});
    }
    _ = try db.exec(&fscope, "DELETE FROM datasets WHERE name = 'test/datasets/sniff'", .{});
    _ = try db.exec(&fscope, "RESET cid.maintenance", .{});
    try producer.dir.writeFile(io, .{ .sub_path = "cli.png", .data = png });
    try cid.client.workspace.init(arena, io, producer.dir, "cid@test:test/datasets/sniff", "g@h:sn.git");
    var pws = try cid.client.workspace.open(arena, io, producer.dir);
    _ = try cid.client.workspace.add(arena, io, &pws, cache.dir, &.{"."});
    _ = try cid.client.workspace.commit(arena, io, &pws, "a png, pushed blind", "user:test");
    _ = try cid.client.sync.push(arena, io, &pws, cache.dir, &remote);
    // Released before the worker has looked at it: whatever a release
    // indexes then, the dimensions sniffed later must still show.
    var browse_tmp = std.testing.tmpDir(.{});
    defer browse_tmp.cleanup();
    deps.browse_dir = try browse_tmp.dir.realPathFileAlloc(io, ".", arena);
    const released = try remote.tag(arena, "v1.0.0");
    // The version as the CLI downloads it: provisional while the worker
    // has yet to look (no dimensions, so none are frozen blank).
    const VersionWhere = struct { url: []const u8, hash: []const u8, final: bool };
    const early_res = cid.api.handle(arena, &deps, &scope, "GET", try std.fmt.allocPrint(arena, "/v0/datasets/test/datasets/sniff/-/version/{s}", .{released.commit}), "Bearer test-token", "");
    const early = try std.json.parseFromSliceLeaky(VersionWhere, arena, early_res.body, .{ .ignore_unknown_fields = true });
    try std.testing.expect(!early.final);
    try std.testing.expect((try remote.state(arena, released.commit))[0].width == null);

    // Before the worker: an honest octet-stream.
    {
        const hz = try arena.dupeZ(u8, &hh);
        const mt = (try db.rawOne([]const u8, &fscope, "SELECT media_type FROM items WHERE item_hash = decode($1, 'hex')", .{hz})).?;
        try std.testing.expectEqualStrings("application/octet-stream", mt);
    }

    // One worker pass: sniffed, measured, thumbnailed.
    const pass = try cid.preview.processPending(arena, io, &standalone.db, &scope, &s3c, .{});
    try std.testing.expect(pass.built >= 1);
    {
        const hz = try arena.dupeZ(u8, &hh);
        const Sniffed = struct {
            pub const nilo_table = .projection;
            media_type: []const u8,
            width: ?[]const u8,
            height: ?[]const u8,
        };
        const sniffed = try db.rawExactlyOne(Sniffed, &fscope, "SELECT media_type, meta->>'width' AS width, meta->>'height' AS height " ++
            "FROM items WHERE item_hash = decode($1, 'hex')", .{hz});
        try std.testing.expectEqualStrings("image/png", sniffed.media_type);
        try std.testing.expectEqualStrings("96", sniffed.width.?);
        try std.testing.expectEqualStrings("64", sniffed.height.?);
    }
    const thumb = try s3c.getObjectAlloc(&scope, try cid.preview.thumbKey(arena, &hh));
    try std.testing.expect(thumb.len > 100);
    {
        // Once the provisional file has had its time, the next is written
        // with the dimensions, and is final: kept, never written again.
        _ = try db.exec(&fscope, "UPDATE version_files SET built_at = now() - interval '1 day' WHERE commit_id = $1::uuid", .{@as([]const u8, released.commit)});
        const items = try remote.state(arena, released.commit);
        try std.testing.expectEqual(@as(?u32, 96), items[0].width);
        try std.testing.expectEqual(@as(?u32, 64), items[0].height);
        const where_res = cid.api.handle(arena, &deps, &scope, "GET", try std.fmt.allocPrint(arena, "/v0/datasets/test/datasets/sniff/-/version/{s}", .{released.commit}), "Bearer test-token", "");
        const where = try std.json.parseFromSliceLeaky(VersionWhere, arena, where_res.body, .{ .ignore_unknown_fields = true });
        try std.testing.expect(where.final);
        try std.testing.expect(!std.mem.eql(u8, where.hash, early.hash));
        // A state file changed in storage is refused, never half-trusted.
        const ds_id = (try db.rawOne([]const u8, &fscope, "SELECT dataset_id::text FROM datasets WHERE name = 'test/datasets/sniff'", .{})).?;
        var whole: [32]u8 = undefined; // the subset key of "no subset"
        cid.hash.Hasher.hash("{\"splits\":[],\"classes\":[]}", &whole, .{});
        const key = try std.fmt.allocPrint(arena, "states/{s}/{s}-{s}-{s}.jsonl.gz", .{ ds_id, released.commit, (&std.fmt.bytesToHex(whole, .lower))[0..16], where.hash[0..16] });
        const genuine = try s3c.getObjectAlloc(&scope, key);
        try s3c.putObject(&scope, key, "not the state you are looking for");
        try std.testing.expectError(error.Corrupt, remote.state(arena, released.commit));
        try s3c.putObject(&scope, key, genuine);
        try std.testing.expectEqual(@as(usize, 1), (try remote.state(arena, released.commit)).len);
    }
    {
        const target = try std.fmt.allocPrint(arena, "/v0/datasets/test/datasets/sniff/-/browse?commit={s}&item=cli.png", .{released.commit});
        const res = cid.api.handle(arena, &deps, &scope, "GET", target, "Bearer test-token", "");
        try std.testing.expectEqual(std.http.Status.ok, res.status);
        const Dims = struct { width: ?u32, height: ?u32 };
        const page = try std.json.parseFromSliceLeaky(struct { items: []const Dims, open: ?Dims }, arena, res.body, .{ .ignore_unknown_fields = true });
        try std.testing.expectEqual(@as(?u32, 96), page.items[0].width);
        try std.testing.expectEqual(@as(?u32, 64), page.open.?.height);
    }

    // The home listing: the card's counts come from the head commit's
    // stats, computed once and cached on the commit, and its mosaic is
    // the finished preview, presigned.
    const Card = struct {
        name: []const u8,
        items: u64,
        types: []const struct { ext: []const u8, count: u64 },
        mosaic: []const struct { hash: []const u8, url: []const u8 },
    };
    const Listing = struct { datasets: []const Card };
    const first = cid.api.handle(arena, &deps, &scope, "GET", "/v0/datasets", "Bearer test-token", "");
    try std.testing.expectEqual(std.http.Status.ok, first.status);
    const listed = try std.json.parseFromSliceLeaky(Listing, arena, first.body, .{ .ignore_unknown_fields = true });
    const card = for (listed.datasets) |d| {
        if (std.mem.eql(u8, d.name, "test/datasets/sniff")) break d;
    } else return error.CardMissing;
    try std.testing.expectEqual(@as(u64, 1), card.items);
    try std.testing.expectEqualStrings(".png", card.types[0].ext);
    try std.testing.expectEqual(@as(usize, 1), card.mosaic.len);
    try std.testing.expectEqualStrings(&hh, card.mosaic[0].hash);

    const cached = try db.rawOne([]const u8, &fscope, "SELECT c.stats::text FROM refs r JOIN commits c ON c.commit_id = r.commit_id " ++
        "JOIN datasets d ON d.dataset_id = r.dataset_id WHERE d.name = 'test/datasets/sniff' AND r.name = 'main'", .{});
    const Stored = struct { v: u32, items: u64 };
    const stored = try std.json.parseFromSliceLeaky(Stored, arena, cached.?, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(u64, 1), stored.items);

    // A restricted dataset's card shows no clear thumbnail (invariant 20).
    _ = try db.exec(&fscope, "UPDATE datasets SET restricted = true WHERE name = 'test/datasets/sniff'", .{});
    defer _ = db.exec(&fscope, "UPDATE datasets SET restricted = false WHERE name = 'test/datasets/sniff'", .{}) catch {};
    const second = cid.api.handle(arena, &deps, &scope, "GET", "/v0/datasets", "Bearer test-token", "");
    const relisted = try std.json.parseFromSliceLeaky(Listing, arena, second.body, .{ .ignore_unknown_fields = true });
    for (relisted.datasets) |d| {
        if (!std.mem.eql(u8, d.name, "test/datasets/sniff")) continue;
        // The worker built a blur beside the thumbnail; the card shows it.
        try std.testing.expectEqual(@as(usize, 1), d.mosaic.len);
        try std.testing.expect(std.mem.indexOf(u8, d.mosaic[0].url, "blur.webp") != null);
        try std.testing.expect(std.mem.indexOf(u8, d.mosaic[0].url, "thumb.webp") == null);
    }

    // Browse's thumbs answer with the blur and nothing else.
    const thumbs_body = try std.fmt.allocPrint(arena, "{{\"hashes\":[\"{s}\"]}}", .{&hh});
    const blurred = cid.api.handle(arena, &deps, &scope, "POST", "/v0/datasets/test/datasets/sniff/-/thumbs", "Bearer test-token", thumbs_body);
    try std.testing.expect(std.mem.indexOf(u8, blurred.body, "blur.webp") != null);
    try std.testing.expect(std.mem.indexOf(u8, blurred.body, "thumb.webp") == null);
    // The blur is a real, different image.
    const blur_bytes = try s3c.getObjectAlloc(&scope, try cid.preview.blurKey(arena, &hh));
    try std.testing.expect(!std.mem.eql(u8, blur_bytes, thumb));

    // A reveal is logged first, then hands back the clear thumbnail.
    const before = (try db.rawOne(i64, &fscope, "SELECT count(*) FROM activity_events e JOIN datasets d USING (dataset_id) WHERE d.name = 'test/datasets/sniff' AND e.action = 'reveal'", .{})).?;
    const reveal_body = try std.fmt.allocPrint(arena, "{{\"hash\":\"{s}\"}}", .{&hh});
    const revealed = cid.api.handle(arena, &deps, &scope, "POST", "/v0/datasets/test/datasets/sniff/-/reveal", "Bearer test-token", reveal_body);
    try std.testing.expectEqual(std.http.Status.ok, revealed.status);
    try std.testing.expect(std.mem.indexOf(u8, revealed.body, "thumb.webp") != null);
    try std.testing.expect(std.mem.indexOf(u8, revealed.body, "\"logged\":true") != null);
    const after = (try db.rawOne(i64, &fscope, "SELECT count(*) FROM activity_events e JOIN datasets d USING (dataset_id) WHERE d.name = 'test/datasets/sniff' AND e.action = 'reveal'", .{})).?;
    try std.testing.expectEqual(before + 1, after);

    // A hash from elsewhere is not revealed through this dataset.
    const stranger = cid.api.handle(arena, &deps, &scope, "POST", "/v0/datasets/test/datasets/sniff/-/reveal", "Bearer test-token", "{\"hash\":\"" ++ ("ab" ** 32) ++ "\"}");
    try std.testing.expectEqual(std.http.Status.not_found, stranger.status);

    // Raw downloads are logged too: no clear URL leaves unrecorded.
    const dl = cid.api.handle(arena, &deps, &scope, "POST", "/v0/datasets/test/datasets/sniff/-/downloads", "Bearer test-token", thumbs_body);
    try std.testing.expectEqual(std.http.Status.ok, dl.status);
    const dl_logged = (try db.rawOne(i64, &fscope, "SELECT count(*) FROM activity_events e JOIN datasets d USING (dataset_id) WHERE d.name = 'test/datasets/sniff' AND e.action = 'download'", .{})).?;
    try std.testing.expect(dl_logged >= 1);

    // The log is the owners': the server token reads it, a reader does not.
    const log = cid.api.handle(arena, &deps, &scope, "GET", "/v0/datasets/test/datasets/sniff/-/activity", "Bearer test-token", "");
    try std.testing.expectEqual(std.http.Status.ok, log.status);
    try std.testing.expect(std.mem.indexOf(u8, log.body, "\"action\":\"reveal\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, log.body, "server-token") != null);
}

test "table statistics: CSV, Parquet and JSONL, withheld when restricted" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var fixture: cid.db.Standalone = undefined;
    try openFixture(&fixture);
    defer fixture.close();
    var fscope = cid.db.Run.init(std.testing.allocator);
    defer fscope.deinit();
    const db = &fixture.db;
    _ = try runMigrations();
    var s3c: cid.blob.Client = undefined;
    try openBlobs(&s3c, io);
    defer s3c.deinit();

    const files = [_][]const u8{ "people.csv", "people.parquet", "events.jsonl" };
    var hashes: [files.len][64]u8 = undefined;
    var producer = std.testing.tmpDir(.{ .iterate = true });
    defer producer.cleanup();
    const fixtures = try std.Io.Dir.cwd().openDir(io, "tests/fixtures", .{});
    for (files, 0..) |name, i| {
        const bytes = try fixtures.readFileAlloc(io, name, arena, .limited(1 << 20));
        var dg: [32]u8 = undefined;
        cid.hash.Hasher.hash(bytes, &dg, .{});
        hashes[i] = std.fmt.bytesToHex(dg, .lower);
        try producer.dir.writeFile(io, .{ .sub_path = name, .data = bytes });
        // A fresh queue row each run, so the worker really builds it.
        _ = db.exec(&fscope, "DELETE FROM previews WHERE item_hash = decode($1, 'hex')", .{@as([]const u8, &hashes[i])}) catch {};
    }
    _ = try db.exec(&fscope, "UPDATE previews SET status = 'skipped', reason = 'test reset' WHERE status = 'pending'", .{});

    var standalone: cid.db.Standalone = undefined;
    try standalone.open(std.testing.allocator, conninfo);
    defer standalone.close();
    var scope = cid.db.Run.init(std.testing.allocator);
    defer scope.deinit();
    var deps: cid.api.Deps = .{ .db = &standalone.db, .s3 = &s3c, .io = io, .gpa = std.testing.allocator, .token = "test-token" };
    var cache = std.testing.tmpDir(.{});
    defer cache.cleanup();
    var direct: DirectTransport = .{ .deps = &deps, .scope = &scope, .auth = "Bearer test-token" };
    const remote: cid.client.remote.Remote = .{ .t = direct.transport(), .name = "test/datasets/tables", .gpa = std.testing.allocator };
    _ = try db.exec(&fscope, "SET cid.maintenance = 'on'", .{});
    inline for (.{ "git_writes", "refs", "commits", "item_revisions", "dataset_items" }) |table| {
        _ = try db.exec(&fscope, "DELETE FROM " ++ table ++ " WHERE dataset_id IN (SELECT dataset_id FROM datasets WHERE name = 'test/datasets/tables')", .{});
    }
    _ = try db.exec(&fscope, "DELETE FROM datasets WHERE name = 'test/datasets/tables'", .{});
    _ = try db.exec(&fscope, "RESET cid.maintenance", .{});
    try cid.client.workspace.init(arena, io, producer.dir, "cid@test:test/datasets/tables", "g@h:tb.git");
    var pws = try cid.client.workspace.open(arena, io, producer.dir);
    _ = try cid.client.workspace.add(arena, io, &pws, cache.dir, &.{"."});
    _ = try cid.client.workspace.commit(arena, io, &pws, "three tables", "user:test");
    _ = try cid.client.sync.push(arena, io, &pws, cache.dir, &remote);

    _ = try cid.preview.processPending(arena, io, &standalone.db, &scope, &s3c, .{});

    const Answer = struct {
        status: []const u8,
        reason: ?[]const u8 = null,
        withheld: bool = false,
        stats: ?struct {
            rows: u64,
            columns: []const struct { name: []const u8, min: ?[]const u8 = null },
            sample: []const std.json.Value,
        } = null,
    };
    const expected_rows = [_]u64{ 5, 5, 3 };
    for (hashes, 0..) |h, i| {
        const target = try std.fmt.allocPrint(arena, "/v0/datasets/test/datasets/tables/-/table?hash={s}", .{&h});
        const res = cid.api.handle(arena, &deps, &scope, "GET", target, "Bearer test-token", "");
        try std.testing.expectEqual(std.http.Status.ok, res.status);
        const a = try std.json.parseFromSliceLeaky(Answer, arena, res.body, .{ .ignore_unknown_fields = true });
        try std.testing.expectEqualStrings("done", a.status);
        try std.testing.expectEqual(expected_rows[i], a.stats.?.rows);
        try std.testing.expectEqual(expected_rows[i], a.stats.?.sample.len);
    }

    {
        // Restricted: the shape, never the values, until a logged reveal.
        _ = try db.exec(&fscope, "UPDATE datasets SET restricted = true WHERE name = 'test/datasets/tables'", .{});
        defer _ = db.exec(&fscope, "UPDATE datasets SET restricted = false WHERE name = 'test/datasets/tables'", .{}) catch {};
        const target = try std.fmt.allocPrint(arena, "/v0/datasets/test/datasets/tables/-/table?hash={s}", .{&hashes[0]});
        const res = cid.api.handle(arena, &deps, &scope, "GET", target, "Bearer test-token", "");
        const a = try std.json.parseFromSliceLeaky(Answer, arena, res.body, .{ .ignore_unknown_fields = true });
        try std.testing.expect(a.withheld);
        try std.testing.expectEqual(@as(u64, 5), a.stats.?.rows);
        try std.testing.expectEqualStrings("name", a.stats.?.columns[1].name);
        try std.testing.expect(a.stats.?.columns[1].min == null);
        try std.testing.expectEqual(@as(usize, 0), a.stats.?.sample.len);
        try std.testing.expect(std.mem.indexOf(u8, res.body, "Ana Wijaya") == null);
        // The reveal brings the rows, on the record.
        const body = try std.fmt.allocPrint(arena, "{{\"hash\":\"{s}\"}}", .{&hashes[0]});
        const revealed = cid.api.handle(arena, &deps, &scope, "POST", "/v0/datasets/test/datasets/tables/-/reveal", "Bearer test-token", body);
        try std.testing.expect(std.mem.indexOf(u8, revealed.body, "Ana Wijaya") != null);
        try std.testing.expect(std.mem.indexOf(u8, revealed.body, "\"logged\":true") != null);
    }
}

test "row diffs: rows added and removed between versions, cached, withheld when restricted" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var fixture: cid.db.Standalone = undefined;
    try openFixture(&fixture);
    defer fixture.close();
    var fscope = cid.db.Run.init(std.testing.allocator);
    defer fscope.deinit();
    const db = &fixture.db;
    _ = try runMigrations();
    var s3c: cid.blob.Client = undefined;
    try openBlobs(&s3c, io);
    defer s3c.deinit();

    var standalone: cid.db.Standalone = undefined;
    try standalone.open(std.testing.allocator, conninfo);
    defer standalone.close();
    var scope = cid.db.Run.init(std.testing.allocator);
    defer scope.deinit();
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    var deps: cid.api.Deps = .{ .db = &standalone.db, .s3 = &s3c, .io = io, .gpa = std.testing.allocator, .token = "test-token", .work_dir = try scratch.dir.realPathFileAlloc(io, ".", arena) };
    var cache = std.testing.tmpDir(.{});
    defer cache.cleanup();
    var direct: DirectTransport = .{ .deps = &deps, .scope = &scope, .auth = "Bearer test-token" };
    const remote: cid.client.remote.Remote = .{ .t = direct.transport(), .name = "test/datasets/rowdiff", .gpa = std.testing.allocator };

    _ = try db.exec(&fscope, "SET cid.maintenance = 'on'", .{});
    inline for (.{ "git_writes", "refs", "commits", "item_revisions", "dataset_items" }) |table| {
        _ = try db.exec(&fscope, "DELETE FROM " ++ table ++ " WHERE dataset_id IN (SELECT dataset_id FROM datasets WHERE name = 'test/datasets/rowdiff')", .{});
    }
    _ = try db.exec(&fscope, "DELETE FROM datasets WHERE name = 'test/datasets/rowdiff'", .{});
    _ = try db.exec(&fscope, "RESET cid.maintenance", .{});

    // v1: the people fixture. v2: Budi gone, Citra's score edited, Fajar in.
    var producer = std.testing.tmpDir(.{ .iterate = true });
    defer producer.cleanup();
    const v1 = try std.Io.Dir.cwd().readFileAlloc(io, "tests/fixtures/people.csv", arena, .limited(1 << 20));
    const v2 =
        \\id,name,city,score
        \\1,Ana Wijaya,Bandung,91.5
        \\3,Citra,Bandung,79
        \\4,Dewi,Surabaya,88.25
        \\5,Eko,Jakarta,64
        \\6,Fajar,Medan,70
        \\
    ;
    var hashes: [2][64]u8 = undefined;
    for ([_][]const u8{ v1, v2 }, 0..) |bytes, i| {
        var dg: [32]u8 = undefined;
        cid.hash.Hasher.hash(bytes, &dg, .{});
        hashes[i] = std.fmt.bytesToHex(dg, .lower);
    }
    // Computed afresh each run.
    _ = try db.exec(&fscope, "DELETE FROM row_diffs WHERE hash_a = decode($1, 'hex')", .{@as([]const u8, &hashes[0])});

    try cid.client.workspace.init(arena, io, producer.dir, "cid@test:test/datasets/rowdiff", "g@h:rd.git");
    for ([_][]const u8{ v1, v2 }, 0..) |bytes, i| {
        try producer.dir.writeFile(io, .{ .sub_path = "people.csv", .data = bytes });
        try producer.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = if (i == 0) "one" else "two" });
        var pws = try cid.client.workspace.open(arena, io, producer.dir);
        _ = try cid.client.workspace.add(arena, io, &pws, cache.dir, &.{"."});
        _ = try cid.client.workspace.commit(arena, io, &pws, "people", "user:test");
        _ = try cid.client.sync.push(arena, io, &pws, cache.dir, &remote);
    }

    // The two versions, compared on the server: both files modified, the
    // hashes on each line so a client can ask for the table's rows.
    {
        const commits = try db.raw([]const u8, &fscope, "SELECT c.commit_id::text FROM commits c JOIN datasets d USING (dataset_id) " ++
            "WHERE d.name = 'test/datasets/rowdiff' ORDER BY c.commit_id", .{});
        try std.testing.expectEqual(@as(usize, 2), commits.len);
        const Seen = struct {
            arena: std.mem.Allocator,
            paths: std.ArrayList([]const u8) = .empty,
            table_hash_b: ?[]const u8 = null,
            fn visit(ctx: *anyopaque, line: cid.client.remote.Remote.DiffLine) anyerror!void {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                try std.testing.expectEqualStrings("modified", line.change.?);
                try self.paths.append(self.arena, try self.arena.dupe(u8, line.path.?));
                if (std.mem.eql(u8, line.path.?, "people.csv")) self.table_hash_b = try self.arena.dupe(u8, line.hash_b.?);
            }
        };
        var seen: Seen = .{ .arena = arena };
        const sum = try remote.compare(arena, commits[0], commits[1], .{ .ctx = &seen, .visit = Seen.visit });
        try std.testing.expectEqual(@as(u64, 2), sum.modified);
        try std.testing.expectEqualStrings("notes.txt", seen.paths.items[0]); // bytewise: 'n' < 'p'
        try std.testing.expectEqualStrings(&hashes[1], seen.table_hash_b.?);
    }

    const rd = try remote.rowDiff(arena, &hashes[0], "people.csv", &hashes[1], "people.csv");
    try std.testing.expectEqualStrings("done", rd.status);
    const d = rd.diff.?;
    try std.testing.expect(!d.columns_changed);
    try std.testing.expectEqual(@as(u64, 5), d.rows_a);
    try std.testing.expectEqual(@as(u64, 5), d.rows_b);
    try std.testing.expectEqual(@as(u64, 2), d.added); // Citra (new score), Fajar
    try std.testing.expectEqual(@as(u64, 2), d.removed); // Budi, Citra (old score)

    // Kept: asked again, answered from row_diffs, the same.
    const kept = try db.rawOne(i64, &fscope, "SELECT count(*)::bigint FROM row_diffs WHERE hash_a = decode($1, 'hex') AND status = 'done'", .{@as([]const u8, &hashes[0])});
    try std.testing.expectEqual(@as(i64, 1), kept.?);
    const again = try remote.rowDiff(arena, &hashes[0], "people.csv", &hashes[1], "people.csv");
    try std.testing.expectEqual(@as(u64, 2), again.diff.?.added);

    // The samples carry the rows; a restricted dataset gets counts only.
    const body = try std.fmt.allocPrint(arena, "{{\"a\":\"{s}\",\"b\":\"{s}\",\"path_a\":\"people.csv\",\"path_b\":\"people.csv\"}}", .{ &hashes[0], &hashes[1] });
    const open = cid.api.handle(arena, &deps, &scope, "POST", "/v0/datasets/test/datasets/rowdiff/-/rowdiff", "Bearer test-token", body);
    try std.testing.expect(std.mem.indexOf(u8, open.body, "Fajar") != null);
    _ = try db.exec(&fscope, "UPDATE datasets SET restricted = true WHERE name = 'test/datasets/rowdiff'", .{});
    defer _ = db.exec(&fscope, "UPDATE datasets SET restricted = false WHERE name = 'test/datasets/rowdiff'", .{}) catch {};
    const closed = cid.api.handle(arena, &deps, &scope, "POST", "/v0/datasets/test/datasets/rowdiff/-/rowdiff", "Bearer test-token", body);
    try std.testing.expectEqual(std.http.Status.ok, closed.status);
    try std.testing.expect(std.mem.indexOf(u8, closed.body, "Fajar") == null);
    try std.testing.expect(std.mem.indexOf(u8, closed.body, "\"withheld\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, closed.body, "\"added\":2") != null);

    // Another dataset's content is not an oracle (invariant 12), and a
    // file that is not a table is said so in words.
    const foreign = try std.fmt.allocPrint(arena, "{{\"a\":\"{s}\",\"b\":\"{s}\",\"path_a\":\"people.csv\",\"path_b\":\"people.csv\"}}", .{ "ab" ** 32, &hashes[1] });
    const refused = cid.api.handle(arena, &deps, &scope, "POST", "/v0/datasets/test/datasets/rowdiff/-/rowdiff", "Bearer test-token", foreign);
    try std.testing.expectEqual(std.http.Status.not_found, refused.status);
    const text = try remote.rowDiff(arena, &hashes[0], "notes.txt", &hashes[1], "notes.txt");
    try std.testing.expectEqualStrings("not_a_table", text.status);
}

test "media: audio gets its waveform, text reads as text, restricted text withheld" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var fixture: cid.db.Standalone = undefined;
    try openFixture(&fixture);
    defer fixture.close();
    var fscope = cid.db.Run.init(std.testing.allocator);
    defer fscope.deinit();
    const db = &fixture.db;
    _ = try runMigrations();
    var s3c: cid.blob.Client = undefined;
    try openBlobs(&s3c, io);
    defer s3c.deinit();

    var standalone: cid.db.Standalone = undefined;
    try standalone.open(std.testing.allocator, conninfo);
    defer standalone.close();
    var scope = cid.db.Run.init(std.testing.allocator);
    defer scope.deinit();
    var deps: cid.api.Deps = .{ .db = &standalone.db, .s3 = &s3c, .io = io, .gpa = std.testing.allocator, .token = "test-token" };
    var cache = std.testing.tmpDir(.{});
    defer cache.cleanup();
    var direct: DirectTransport = .{ .deps = &deps, .scope = &scope, .auth = "Bearer test-token" };
    const remote: cid.client.remote.Remote = .{ .t = direct.transport(), .name = "test/datasets/media", .gpa = std.testing.allocator };

    // The fixtures, pushed the CLI way (the server records octet-stream),
    // plus a binary file and a long text that the drawer shows the start of.
    var producer = std.testing.tmpDir(.{ .iterate = true });
    defer producer.cleanup();
    const fixtures = try std.Io.Dir.cwd().openDir(io, "tests/fixtures", .{});
    const wav = try fixtures.readFileAlloc(io, "tone.wav", arena, .limited(1 << 20));
    const notes = try fixtures.readFileAlloc(io, "notes.txt", arena, .limited(1 << 20));
    try producer.dir.createDirPath(io, "audio");
    try producer.dir.writeFile(io, .{ .sub_path = "audio/tone.wav", .data = wav });
    try producer.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = notes });
    try producer.dir.writeFile(io, .{ .sub_path = "blob.bin", .data = "\x00\x01\x02binary\x00" });
    const long = try arena.alloc(u8, 70 * 1024);
    for (long, 0..) |*ch, i| ch.* = if (i % 64 == 63) '\n' else 'a' + @as(u8, @intCast(i % 26));
    try producer.dir.writeFile(io, .{ .sub_path = "long.txt", .data = long });
    var hashes: [4][64]u8 = undefined;
    for ([_][]const u8{ wav, notes, "\x00\x01\x02binary\x00", long }, 0..) |bytes, i| {
        var dg: [32]u8 = undefined;
        cid.hash.Hasher.hash(bytes, &dg, .{});
        hashes[i] = std.fmt.bytesToHex(dg, .lower);
        _ = db.exec(&fscope, "DELETE FROM previews WHERE item_hash = decode($1, 'hex')", .{@as([]const u8, &hashes[i])}) catch {};
    }
    _ = try db.exec(&fscope, "UPDATE previews SET status = 'skipped', reason = 'test reset' WHERE status = 'pending'", .{});
    try cid.client.workspace.init(arena, io, producer.dir, "cid@test:test/datasets/media", "g@h:media.git");
    var pws = try cid.client.workspace.open(arena, io, producer.dir);
    _ = try cid.client.workspace.add(arena, io, &pws, cache.dir, &.{"."});
    _ = try cid.client.workspace.commit(arena, io, &pws, "sound and words", "user:test");
    _ = try cid.client.sync.push(arena, io, &pws, cache.dir, &remote);

    // One worker pass: the WAV is sniffed as audio and gets its waveform
    // as its thumbnail (and the blurred copy restricted views use); the
    // text is sniffed as text and gets no thumbnail, in words.
    _ = try cid.preview.processPending(arena, io, &standalone.db, &scope, &s3c, .{});
    const Prev = struct {
        pub const nilo_table = .projection;
        media_type: []const u8,
        status: []const u8,
        reason: ?[]const u8,
    };
    const sound = (try db.rawOne(Prev, &fscope, "SELECT i.media_type, p.status, p.reason FROM items i JOIN previews p USING (item_hash) WHERE i.item_hash = decode($1, 'hex')", .{@as([]const u8, &hashes[0])})).?;
    try std.testing.expectEqualStrings("audio/wav", sound.media_type);
    try std.testing.expectEqualStrings("done", sound.status);
    const waveform = try s3c.getObjectAlloc(&scope, try cid.preview.thumbKey(arena, &hashes[0]));
    try std.testing.expect(std.mem.startsWith(u8, waveform, "RIFF")); // a WebP picture
    try std.testing.expect((try s3c.headObject(&scope, try cid.preview.blurKey(arena, &hashes[0]))) != null);
    const words = (try db.rawOne(Prev, &fscope, "SELECT i.media_type, p.status, p.reason FROM items i JOIN previews p USING (item_hash) WHERE i.item_hash = decode($1, 'hex')", .{@as([]const u8, &hashes[1])})).?;
    try std.testing.expectEqualStrings("text/plain", words.media_type);
    try std.testing.expectEqualStrings("skipped", words.status);

    // The drawer's text: the note whole; the binary file said so; the long
    // file's first 64 KB, marked as such.
    const Text = struct { text: ?[]const u8 = null, truncated: bool = false, binary: bool = false, size: u64 = 0, withheld: bool = false };
    const textOf = struct {
        fn get(al: std.mem.Allocator, d: *cid.api.Deps, sc: anytype, hash: []const u8) !Text {
            const res = cid.api.handle(al, d, sc, "GET", try std.fmt.allocPrint(al, "/v0/datasets/test/datasets/media/-/text?hash={s}", .{hash}), "Bearer test-token", "");
            if (res.status != .ok) return error.TextRefused;
            return std.json.parseFromSliceLeaky(Text, al, res.body, .{ .ignore_unknown_fields = true });
        }
    }.get;
    const note = try textOf(arena, &deps, &scope, &hashes[1]);
    try std.testing.expectEqualStrings(notes, note.text.?);
    try std.testing.expect(!note.truncated);
    try std.testing.expect((try textOf(arena, &deps, &scope, &hashes[2])).binary);
    const head = try textOf(arena, &deps, &scope, &hashes[3]);
    try std.testing.expect(head.truncated);
    try std.testing.expectEqual(@as(usize, 64 * 1024), head.text.?.len);
    try std.testing.expectEqual(@as(u64, 70 * 1024), head.size);

    // Restricted: withheld, and given by the logged reveal.
    _ = try db.exec(&fscope, "UPDATE datasets SET restricted = true WHERE name = 'test/datasets/media'", .{});
    defer _ = db.exec(&fscope, "UPDATE datasets SET restricted = false WHERE name = 'test/datasets/media'", .{}) catch {};
    const hidden = try textOf(arena, &deps, &scope, &hashes[1]);
    try std.testing.expect(hidden.withheld);
    try std.testing.expect(hidden.text == null);
    const body = try std.fmt.allocPrint(arena, "{{\"hash\":\"{s}\"}}", .{&hashes[1]});
    const revealed = cid.api.handle(arena, &deps, &scope, "POST", "/v0/datasets/test/datasets/media/-/reveal", "Bearer test-token", body);
    try std.testing.expect(std.mem.indexOf(u8, revealed.body, "UTF-8 is fine") != null);
    try std.testing.expect(std.mem.indexOf(u8, revealed.body, "\"logged\":true") != null);
}

test "state at commit: random changes on main and a branch match an in-memory model at every commit" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var fixture: cid.db.Standalone = undefined;
    try openFixture(&fixture);
    defer fixture.close();
    var fscope = cid.db.Run.init(std.testing.allocator);
    defer fscope.deinit();
    const db = &fixture.db;
    _ = try runMigrations();
    var s3c: cid.blob.Client = undefined;
    try openBlobs(&s3c, io);
    defer s3c.deinit();

    var standalone: cid.db.Standalone = undefined;
    try standalone.open(std.testing.allocator, conninfo);
    defer standalone.close();
    var scope = cid.db.Run.init(std.testing.allocator);
    defer scope.deinit();
    var deps: cid.api.Deps = .{ .db = &standalone.db, .s3 = &s3c, .io = io, .gpa = std.testing.allocator, .token = "test-token" };
    var direct: DirectTransport = .{ .deps = &deps, .scope = &scope, .auth = "Bearer test-token" };
    const remote: cid.client.remote.Remote = .{ .t = direct.transport(), .name = "test/datasets/model", .gpa = std.testing.allocator };
    try remote.createDataset(arena, "g@h:model.git");
    const ds_id = (try db.rawOne([]const u8, &fscope, "SELECT dataset_id::text FROM datasets WHERE name = 'test/datasets/model'", .{})).?;

    // A pool of contents (staged once; afterwards this dataset holds them)
    // and of paths, some nested, some sharing prefixes.
    const contents = [_][]const u8{ "m0", "m1 one", "m2 two two", "m3 three!", "m4 ...." };
    var hashes: [contents.len][64]u8 = undefined;
    for (contents, &hashes) |c, *h| {
        var dg: [32]u8 = undefined;
        cid.hash.Hasher.hash(c, &dg, .{});
        h.* = std.fmt.bytesToHex(dg, .lower);
        try s3c.putObject(&scope, try cid.api.stagedKey(arena, ds_id, h), c);
    }
    const paths = [_][]const u8{ "a.txt", "a/b.txt", "a/b/c.txt", "a.b/x", "z", "dir/one", "dir/two", "dir/sub/three" };

    const State = [paths.len]?u8; // content index per path
    const Line = enum { main, branch };
    const Snapshot = struct { commit: []const u8, state: State };
    var snapshots: std.ArrayList(Snapshot) = .empty;
    var states: [2]State = .{ @splat(null), @splat(null) };
    var heads: [2]?cid.uuid7.Uuid = .{ null, null };
    var branched = false;
    var prng: std.Random.DefaultPrng = .init(0x5eed_c1d);
    const rand = prng.random();

    const commitOn = struct {
        fn run(al: std.mem.Allocator, r: *const cid.client.remote.Remote, i: std.Io, line: Line, head: *?cid.uuid7.Uuid, st: *State, h: *const [contents.len][64]u8, rnd: std.Random, first: bool) ![]const u8 {
            var changes: std.ArrayList(cid.client.local.Change) = .empty;
            var touched: [paths.len]bool = @splat(false);
            const n = if (first) contents.len else 1 + rnd.uintLessThan(usize, 4);
            for (0..n) |k| {
                const p = if (first) k else rnd.uintLessThan(usize, paths.len);
                if (touched[p]) continue;
                touched[p] = true;
                if (st[p] != null and rnd.uintLessThan(u8, 10) < 3) {
                    st[p] = null;
                    try changes.append(al, .{ .op = .delete, .path = paths[p], .hash_hex = undefined, .size = 0 });
                } else {
                    const c: u8 = if (first) @intCast(k) else rnd.uintLessThan(u8, contents.len);
                    st[p] = c;
                    try changes.append(al, .{ .op = .add, .path = paths[p], .hash_hex = h[c], .size = contents[c].len });
                }
            }
            const id = cid.uuid7.Uuid.now(i);
            const branch = if (line == .main) "main" else "exp";
            try r.push(al, branch, &.{.{ .id = id, .parent = head.*, .branch = branch, .author = "user:model", .authored_at_ms = 1760000000000, .message = "random", .changes = changes.items }});
            head.* = id;
            return al.dupe(u8, &id.toString());
        }
    }.run;

    for (0..55) |step| {
        if (step == 30) {
            // Cut the branch from main's head: it starts as main's state.
            _ = try remote.branchCreate(arena, "exp");
            heads[1] = try cid.uuid7.Uuid.parse((try remote.head(arena, "exp")).?);
            states[1] = states[0];
            branched = true;
        }
        const line: Line = if (branched and rand.boolean()) .branch else .main;
        const l = @intFromEnum(line);
        const commit = try commitOn(arena, &remote, io, line, &heads[l], &states[l], &hashes, rand, step == 0);
        try snapshots.append(arena, .{ .commit = commit, .state = states[l] });
    }

    // Every commit's state, as the server composes it, is the model's.
    for (snapshots.items, 0..) |snap, n| {
        const got = try remote.state(arena, snap.commit);
        var expected: usize = 0;
        for (snap.state, 0..) |c, p| {
            const content = c orelse continue;
            expected += 1;
            const item = for (got) |it| {
                if (std.mem.eql(u8, it.path, paths[p])) break it;
            } else {
                std.debug.print("commit #{d}: {s} missing\n", .{ n, paths[p] });
                return error.StateDiffers;
            };
            try std.testing.expectEqualStrings(&hashes[content], item.hash);
            try std.testing.expectEqual(@as(u64, contents[content].len), item.size);
        }
        if (got.len != expected) {
            std.debug.print("commit #{d}: {d} items, the model has {d}\n", .{ n, got.len, expected });
            return error.StateDiffers;
        }
        // In path order, bytewise (what clone and diff rely on).
        for (got[1..], got[0 .. got.len - 1]) |b, a| try std.testing.expect(std.mem.order(u8, a.path, b.path) == .lt);
    }
}

test "resume: a push killed halfway finishes on the next run, no file uploaded twice, nothing half-recorded" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var fixture: cid.db.Standalone = undefined;
    try openFixture(&fixture);
    defer fixture.close();
    var fscope = cid.db.Run.init(std.testing.allocator);
    defer fscope.deinit();
    const db = &fixture.db;
    _ = try runMigrations();

    var s3c: cid.blob.Client = undefined;
    try openBlobs(&s3c, io);
    defer s3c.deinit();

    var standalone: cid.db.Standalone = undefined;
    try standalone.open(std.testing.allocator, conninfo);
    defer standalone.close();
    var scope = cid.db.Run.init(std.testing.allocator);
    defer scope.deinit();
    var deps: cid.api.Deps = .{ .db = &standalone.db, .s3 = &s3c, .io = io, .gpa = std.testing.allocator, .token = "test-token" };
    var direct: DirectTransport = .{ .deps = &deps, .scope = &scope, .auth = "Bearer test-token" };
    const remote: cid.client.remote.Remote = .{ .t = direct.transport(), .name = "test/datasets/resume", .gpa = std.testing.allocator };

    // Three new files (fresh bytes each run: nothing in storage yet), in
    // two local commits.
    var nonce: [8]u8 = undefined;
    io.random(&nonce);
    var producer = std.testing.tmpDir(.{ .iterate = true });
    defer producer.cleanup();
    var cache = std.testing.tmpDir(.{});
    defer cache.cleanup();
    try cid.client.workspace.init(arena, io, producer.dir, "cid@test:test/datasets/resume", "git@example.invalid:resume.git");
    var ws = try cid.client.workspace.open(arena, io, producer.dir);
    for ([_][]const u8{ "one.txt", "two.bin" }) |name| {
        try producer.dir.writeFile(io, .{ .sub_path = name, .data = try std.fmt.allocPrint(arena, "{s} {x}", .{ name, &nonce }) });
    }
    _ = try cid.client.workspace.add(arena, io, &ws, cache.dir, &.{"."});
    _ = try cid.client.workspace.commit(arena, io, &ws, "first", "user:test");
    try producer.dir.writeFile(io, .{ .sub_path = "three.csv", .data = try std.fmt.allocPrint(arena, "a,b\n{x},1\n", .{&nonce}) });
    _ = try cid.client.workspace.add(arena, io, &ws, cache.dir, &.{"."});
    _ = try cid.client.workspace.commit(arena, io, &ws, "second", "user:test");

    // Killed after one upload: the dataset exists, one file is up.
    _ = remote.head(arena, "main") catch try remote.createDataset(arena, "git@example.invalid:resume.git");
    const ds_id = (try db.rawOne([]const u8, &fscope, "SELECT dataset_id::text FROM datasets WHERE name = 'test/datasets/resume'", .{})).?;
    _ = try db.exec(&fscope, "SET cid.maintenance = 'on'", .{});
    inline for (.{ "refs", "commits", "item_revisions", "dataset_items" }) |table| {
        _ = try db.exec(&fscope, "DELETE FROM " ++ table ++ " WHERE dataset_id = $1::uuid", .{ds_id});
    }
    _ = try db.exec(&fscope, "RESET cid.maintenance", .{});
    var hashes: [3][]const u8 = undefined;
    var sizes: [3]u64 = undefined;
    for ([_][]const u8{ "one.txt", "two.bin", "three.csv" }, 0..) |name, i| {
        const stored = try cid.client.cache.hashFile(io, producer.dir, name);
        hashes[i] = try arena.dupe(u8, &stored.hash_hex);
        sizes[i] = stored.size;
    }
    const first = try remote.checkHashes(arena, &hashes, &sizes);
    try std.testing.expectEqual(@as(usize, 3), first.len);
    try cid.client.remote.uploadFromCache(arena, io, cache.dir, sizes[0], first[0], null);

    // Run again, and the connection drops while recording: the other two
    // go up, nothing is recorded.
    direct.cut_push = true;
    try std.testing.expectError(error.ServerUnreachable, cid.client.sync.push(arena, io, &ws, cache.dir, &remote));
    const recorded = try db.rawOne(i64, &fscope, "SELECT count(*)::bigint FROM commits WHERE dataset_id = $1::uuid", .{ds_id});
    try std.testing.expectEqual(@as(?i64, 0), recorded);

    // And again: everything is up already, so nothing is uploaded twice;
    // both commits land together.
    direct.cut_push = false;
    const done = try cid.client.sync.push(arena, io, &ws, cache.dir, &remote);
    try std.testing.expectEqual(@as(u32, 0), done.uploaded_files);
    try std.testing.expectEqual(@as(u32, 2), done.pushed_commits);
    for (hashes) |h| try std.testing.expect((try s3c.headObject(&scope, try cid.api.itemKey(arena, h))) != null);
    const recorded_now = try db.rawOne(i64, &fscope, "SELECT count(*)::bigint FROM commits WHERE dataset_id = $1::uuid", .{ds_id});
    try std.testing.expectEqual(@as(?i64, 2), recorded_now);
    const again = try cid.client.sync.push(arena, io, &ws, cache.dir, &remote);
    try std.testing.expectEqual(@as(u32, 0), again.pushed_commits);
}

test "large files go up in pieces, and a push stopped mid-file carries on from the next piece" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var fixture: cid.db.Standalone = undefined;
    try openFixture(&fixture);
    defer fixture.close();
    var fscope = cid.db.Run.init(std.testing.allocator);
    defer fscope.deinit();
    const db = &fixture.db;
    _ = try runMigrations();
    var s3c: cid.blob.Client = undefined;
    try openBlobs(&s3c, io);
    defer s3c.deinit();

    var standalone: cid.db.Standalone = undefined;
    try standalone.open(std.testing.allocator, conninfo);
    defer standalone.close();
    var scope = cid.db.Run.init(std.testing.allocator);
    defer scope.deinit();
    // 5 MiB pieces (S3's smallest part), so a 17.5 MiB file is four of them.
    var deps: cid.api.Deps = .{ .db = &standalone.db, .s3 = &s3c, .io = io, .gpa = std.testing.allocator, .token = "test-token", .piece_bytes = 1 << 20 };
    var direct: DirectTransport = .{ .deps = &deps, .scope = &scope, .auth = "Bearer test-token" };
    const remote: cid.client.remote.Remote = .{ .t = direct.transport(), .name = "test/datasets/pieces", .gpa = std.testing.allocator };

    // Fresh bytes each run, so storage has never seen them.
    const big = try arena.alloc(u8, (7 << 20) / 2);
    io.random(big);
    var dg: [32]u8 = undefined;
    cid.hash.Hasher.hash(big, &dg, .{});
    const hash = std.fmt.bytesToHex(dg, .lower);

    var producer = std.testing.tmpDir(.{ .iterate = true });
    defer producer.cleanup();
    var cache = std.testing.tmpDir(.{});
    defer cache.cleanup();
    try producer.dir.writeFile(io, .{ .sub_path = "big.bin", .data = big });
    try producer.dir.writeFile(io, .{ .sub_path = "small.txt", .data = "beside it" });
    try cid.client.workspace.init(arena, io, producer.dir, "cid@test:test/datasets/pieces", "git@example.invalid:pieces.git");
    var ws = try cid.client.workspace.open(arena, io, producer.dir);
    _ = try cid.client.workspace.add(arena, io, &ws, cache.dir, &.{"."});
    _ = try cid.client.workspace.commit(arena, io, &ws, "a large file", "user:test");
    try remote.createDataset(arena, "git@example.invalid:pieces.git");

    // Asked for in four pieces; two go up, and the push stops there.
    const asked = try remote.checkHashes(arena, &.{&hash}, &.{big.len});
    try std.testing.expectEqual(@as(usize, 1), asked.len);
    try std.testing.expect(asked[0].url == null);
    try std.testing.expectEqual(@as(usize, 4), asked[0].parts.?.len);
    var partial = asked[0];
    partial.parts = asked[0].parts.?[0..2];
    try cid.client.remote.uploadFromCache(arena, io, cache.dir, big.len, partial, null);

    // Asked again, only the two still missing.
    const again = try remote.checkHashes(arena, &.{&hash}, &.{big.len});
    try std.testing.expectEqual(@as(usize, 2), again[0].parts.?.len);
    try std.testing.expectEqual(@as(u32, 3), again[0].parts.?[0].n);
    try std.testing.expectEqual(@as(u32, 4), again[0].parts.?[1].n);

    // `cid push` carries on: the rest goes up, the server hashes the pieces
    // in order as one file, stores it, and drops the pieces.
    const pushed = try cid.client.sync.push(arena, io, &ws, cache.dir, &remote);
    try std.testing.expectEqual(@as(u32, 1), pushed.pushed_commits);
    const stored = try s3c.getObjectAlloc(&scope, try cid.api.itemKey(arena, &hash));
    try std.testing.expectEqualSlices(u8, big, stored);
    const ds_id = (try db.rawOne([]const u8, &fscope, "SELECT dataset_id::text FROM datasets WHERE name = 'test/datasets/pieces'", .{})).?;
    for (1..5) |n| try std.testing.expect((try s3c.headObject(&scope, try cid.api.pieceKey(arena, ds_id, &hash, @intCast(n)))) == null);

    // Pieces that do not add up to the file are refused, and nothing lands.
    const forged = try arena.alloc(u8, (5 << 20) / 2);
    io.random(forged);
    cid.hash.Hasher.hash(forged, &dg, .{});
    const forged_hash = std.fmt.bytesToHex(dg, .lower);
    for (1..4) |n| try s3c.putObject(&scope, try cid.api.pieceKey(arena, ds_id, &forged_hash, @intCast(n)), forged[0 .. 1 << 20]);
    const body = try std.fmt.allocPrint(arena,
        \\{{"branch":"main","commits":[{{"id":"{s}","parent":"{s}","message":"forged","author":"user:test","authored_at_ms":1760000000000,"changes":[{{"op":"add","path":"forged.bin","hash":"{s}","size":{d}}}]}}]}}
    , .{ &cid.uuid7.Uuid.now(io).toString(), (try remote.head(arena, "main")).?, &forged_hash, forged.len });
    const refused = cid.api.handle(arena, &deps, &scope, "POST", "/v0/datasets/test/datasets/pieces/-/push", "Bearer test-token", body);
    try std.testing.expectEqual(std.http.Status.unprocessable_entity, refused.status);
    try std.testing.expect((try s3c.headObject(&scope, try cid.api.itemKey(arena, &forged_hash))) == null);
}

test "gc: never deletes what a release or branch head holds; collected bytes can come back" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var fixture: cid.db.Standalone = undefined;
    try openFixture(&fixture);
    defer fixture.close();
    var fscope = cid.db.Run.init(std.testing.allocator);
    defer fscope.deinit();
    const db = &fixture.db;
    _ = try runMigrations();

    var s3c: cid.blob.Client = undefined;
    try openBlobs(&s3c, io);
    defer s3c.deinit();

    var standalone: cid.db.Standalone = undefined;
    try standalone.open(std.testing.allocator, conninfo);
    defer standalone.close();
    var scope = cid.db.Run.init(std.testing.allocator);
    defer scope.deinit();
    var deps: cid.api.Deps = .{ .db = &standalone.db, .s3 = &s3c, .io = io, .gpa = std.testing.allocator, .token = "test-token" };
    var direct: DirectTransport = .{ .deps = &deps, .scope = &scope, .auth = "Bearer test-token" };
    const remote: cid.client.remote.Remote = .{ .t = direct.transport(), .name = "test/datasets/gc", .gpa = std.testing.allocator };

    _ = try db.exec(&fscope, "SET cid.maintenance = 'on'", .{});
    inline for (.{ "refs", "commits", "item_revisions", "dataset_items" }) |table| {
        _ = try db.exec(&fscope, "DELETE FROM " ++ table ++ " WHERE dataset_id IN (SELECT dataset_id FROM datasets WHERE name = 'test/datasets/gc')", .{});
    }
    _ = try db.exec(&fscope, "DELETE FROM datasets WHERE name = 'test/datasets/gc'", .{});
    _ = try db.exec(&fscope, "RESET cid.maintenance", .{});

    const contents = [_][]const u8{ "gc: in the release and the head", "gc: in the release only", "gc: in a middle commit only", "gc: in the head only" };
    var hashes: [contents.len][64]u8 = undefined;
    for (contents, &hashes) |c, *h| {
        var dg: [32]u8 = undefined;
        cid.hash.Hasher.hash(c, &dg, .{});
        h.* = std.fmt.bytesToHex(dg, .lower);
    }

    // a + b, released; then b goes and c comes; then c goes and d comes.
    var producer = std.testing.tmpDir(.{ .iterate = true });
    defer producer.cleanup();
    var cache = std.testing.tmpDir(.{});
    defer cache.cleanup();
    try cid.client.workspace.init(arena, io, producer.dir, "cid@test:test/datasets/gc", "git@example.invalid:gc.git");
    var ws = try cid.client.workspace.open(arena, io, producer.dir);
    const steps = [_]struct { write: []const usize, remove: []const []const u8 }{
        .{ .write = &.{ 0, 1 }, .remove = &.{} },
        .{ .write = &.{2}, .remove = &.{"b.txt"} },
        .{ .write = &.{3}, .remove = &.{"c.txt"} },
    };
    const names = [_][]const u8{ "a.txt", "b.txt", "c.txt", "d.txt" };
    for (steps, 0..) |step, n| {
        for (step.write) |w| try producer.dir.writeFile(io, .{ .sub_path = names[w], .data = contents[w] });
        for (step.remove) |r| try producer.dir.deleteFile(io, r);
        _ = try cid.client.workspace.add(arena, io, &ws, cache.dir, &.{"."});
        _ = try cid.client.workspace.commit(arena, io, &ws, "step", "user:test");
        _ = try cid.client.sync.push(arena, io, &ws, cache.dir, &remote);
        if (n == 0) _ = try remote.tag(arena, "v1");
    }
    const ds_id = (try db.rawOne([]const u8, &fscope, "SELECT dataset_id::text FROM datasets WHERE name = 'test/datasets/gc'", .{})).?;

    // An upload staged and never pushed.
    const junk_key = try cid.api.stagedKey(arena, ds_id, "00" ** 32);
    try s3c.putObject(&scope, junk_key, "abandoned");
    try std.Io.sleep(io, .fromSeconds(1), .awake); // storage stamps whole seconds

    // Showing deletes nothing, and only the middle commit's file is a
    // candidate (retention 0 days: every byte is old enough).
    const shown = try cid.gc.run(std.testing.allocator, &standalone.db, &scope, &s3c, .{ .days = 0 });
    try std.testing.expect(shown.items >= 1);
    try std.testing.expect(shown.staged >= 1);
    for (hashes, 0..) |h, i| {
        const listed = try db.rawOne(i64, &fscope, "SELECT 1::bigint FROM gc_candidates WHERE item_hash = decode($1, 'hex')", .{&h});
        try std.testing.expectEqual(i == 2, listed != null);
        try std.testing.expect((try s3c.headObject(&scope, try cid.api.itemKey(arena, &h))) != null);
    }
    try std.testing.expect((try s3c.headObject(&scope, junk_key)) != null);

    // --apply: c's bytes go, recorded; the release's and the head's stay.
    const applied = try cid.gc.run(std.testing.allocator, &standalone.db, &scope, &s3c, .{ .days = 0, .apply = true });
    try std.testing.expect(applied.items >= 1);
    for (hashes, 0..) |h, i| {
        const there = (try s3c.headObject(&scope, try cid.api.itemKey(arena, &h))) != null;
        try std.testing.expectEqual(i != 2, there);
    }
    try std.testing.expect((try db.rawOne(i64, &fscope, "SELECT 1::bigint FROM collected_items WHERE item_hash = decode($1, 'hex')", .{&hashes[2]})) != null);
    try std.testing.expect((try s3c.headObject(&scope, junk_key)) == null);
    // Asking for collected bytes is answered in words, not with dead links.
    try std.testing.expectError(error.Collected, remote.downloads(arena, &.{&hashes[2]}));
    _ = try remote.downloads(arena, &.{&hashes[0]});

    // A push of the same content uploads it again (the server never
    // claims to hold collected bytes) and the collection is undone.
    try producer.dir.writeFile(io, .{ .sub_path = "c-again.txt", .data = contents[2] });
    _ = try cid.client.workspace.add(arena, io, &ws, cache.dir, &.{"."});
    _ = try cid.client.workspace.commit(arena, io, &ws, "c is back", "user:test");
    const back = try cid.client.sync.push(arena, io, &ws, cache.dir, &remote);
    try std.testing.expectEqual(@as(u32, 1), back.uploaded_files);
    try std.testing.expect((try s3c.headObject(&scope, try cid.api.itemKey(arena, &hashes[2]))) != null);
    try std.testing.expect((try db.rawOne(i64, &fscope, "SELECT 1::bigint FROM collected_items WHERE item_hash = decode($1, 'hex')", .{&hashes[2]})) == null);

    // A second run finds nothing more of this dataset's to take.
    _ = try cid.gc.run(std.testing.allocator, &standalone.db, &scope, &s3c, .{ .days = 0, .apply = true });
    for (hashes) |h| try std.testing.expect((try s3c.headObject(&scope, try cid.api.itemKey(arena, &h))) != null);
}
