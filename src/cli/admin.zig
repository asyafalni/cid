//! `cid admin …`: server administration. Hidden from plain `cid help` (rule 6).

const std = @import("std");
const root = @import("../cid.zig");
const pg = @import("../store/pg.zig");
const s3 = @import("../store/s3.zig");
const migrate = @import("../core/migrate.zig");
const api = @import("../server/api.zig");
const release = @import("../core/release.zig");
const git_writer = @import("../gitrepo/writer.zig");
const serve_mod = @import("../server/serve.zig");

const ExitCode = root.ExitCode;

const admin_help =
    \\usage: cid admin <command>
    \\
    \\Server administration:
    \\
    \\  setup      create the database schema (applies all migrations)
    \\  migrate    apply new SQL migrations
    \\  serve      run the cid server (--port <n>, default 7070)
    \\  verify <dataset> <release>   rebuild a release and check its hash
    \\  git <dataset> [--resync]     dataset repository status; --resync retries
    \\
    \\All of them read configuration from the environment:
    \\  CID_DB     the TimescaleDB connection (setup, migrate, serve)
    \\  CID_S3_ENDPOINT, CID_S3_ACCESS_KEY, CID_S3_SECRET_KEY,
    \\  CID_S3_BUCKET, CID_TOKEN            (serve)
    \\
;

const conninfo_example =
    "export CID_DB='host=127.0.0.1 port=5433 user=cid password=cid-test dbname=cid_test'";

pub fn run(
    arena: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    env: *const std.process.Environ.Map,
    args: []const [:0]const u8,
) ExitCode {
    if (args.len == 0) {
        out.writeAll(admin_help) catch return .network;
        return .ok;
    }
    const sub = args[0];
    if (eql(sub, "setup") or eql(sub, "migrate")) {
        return runMigrate(arena, io, out, env, sub);
    }
    if (eql(sub, "serve")) {
        return runServe(arena, io, env, args[1..]);
    }
    if (eql(sub, "verify")) {
        return runVerify(arena, io, out, env, args[1..]);
    }
    if (eql(sub, "git")) {
        return runGitAdmin(arena, io, out, env, args[1..]);
    }
    return fail(io, .usage, "'cid admin {s}' is not an admin command. Run 'cid admin'.", .{sub});
}

fn runMigrate(
    arena: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    env: *const std.process.Environ.Map,
    sub: []const u8,
) ExitCode {
    const conninfo_raw = env.get("CID_DB") orelse {
        return fail(io, .usage, "CID_DB is not set.\nSet it to the server database connection, e.g.\n  {s}\nThen run 'cid admin {s}' again.", .{ conninfo_example, sub });
    };
    const conninfo = arena.dupeZ(u8, conninfo_raw) catch return .network;

    var diag: pg.Diag = .{};
    var db = pg.Db.connect(conninfo, &diag) catch {
        return fail(io, .network, "cannot connect to the database: {s}\nCheck the database is running and CID_DB is right, then run 'cid admin {s}' again.", .{ diag.message(), sub });
    };
    defer db.close();

    const summary = migrate.run(arena, &db, out, &diag) catch {
        return fail(io, .network, "migration failed: {s}\nFix the cause, then run 'cid admin {s}' again; the failed migration was rolled back.", .{ diag.message(), sub });
    };
    if (summary.applied == 0) {
        out.print("Nothing to apply. Database is up to date ({d} migration{s}).\n", .{ summary.total, plural(summary.total) }) catch return .network;
    } else {
        out.print("Database is up to date ({d} applied, {d} total).\n", .{ summary.applied, summary.total }) catch return .network;
    }
    out.flush() catch return .network;
    return .ok;
}

fn runServe(
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    args: []const [:0]const u8,
) ExitCode {
    var port: u16 = 7070;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (eql(args[i], "--port")) {
            i += 1;
            if (i >= args.len) return fail(io, .usage, "--port needs a number. Run 'cid admin serve --port 7070'.", .{});
            port = std.fmt.parseInt(u16, args[i], 10) catch
                return fail(io, .usage, "'{s}' is not a port number. Run 'cid admin serve --port 7070'.", .{args[i]});
        } else {
            return fail(io, .usage, "unexpected argument '{s}'. Run 'cid admin' for usage.", .{args[i]});
        }
    }

    const conninfo_raw = env.get("CID_DB") orelse
        return fail(io, .usage, "CID_DB is not set.\n  {s}\nThen run 'cid admin serve' again.", .{conninfo_example});
    const s3_endpoint = env.get("CID_S3_ENDPOINT") orelse return missingEnv(io, "CID_S3_ENDPOINT", "http://127.0.0.1:8333");
    const s3_access = env.get("CID_S3_ACCESS_KEY") orelse return missingEnv(io, "CID_S3_ACCESS_KEY", "cid");
    const s3_secret = env.get("CID_S3_SECRET_KEY") orelse return missingEnv(io, "CID_S3_SECRET_KEY", "…");
    const s3_bucket = env.get("CID_S3_BUCKET") orelse return missingEnv(io, "CID_S3_BUCKET", "cid");
    const token = env.get("CID_TOKEN") orelse return missingEnv(io, "CID_TOKEN", "a long random string");

    const conninfo = arena.dupeZ(u8, conninfo_raw) catch return .network;
    var diag: pg.Diag = .{};
    var db = pg.Db.connect(conninfo, &diag) catch {
        return fail(io, .network, "cannot connect to the database: {s}\nCheck CID_DB, then run 'cid admin serve' again.", .{diag.message()});
    };
    defer db.close();

    var s3_client = s3.Client.init(arena, io, .{
        .endpoint = s3_endpoint,
        .access_key = s3_access,
        .secret_key = s3_secret,
        .bucket = s3_bucket,
    }) catch return fail(io, .usage, "CID_S3_ENDPOINT must look like http://host:port. Fix it, then run 'cid admin serve' again.", .{});
    defer s3_client.deinit();
    s3_client.createBucket(arena) catch
        return fail(io, .network, "cannot reach storage at {s}. Check SeaweedFS, then run 'cid admin serve' again.", .{s3_endpoint});

    var deps: api.Deps = .{ .db = &db, .s3 = &s3_client, .io = io, .token = token };
    if (env.get("CID_GIT_WORKDIR")) |git_workdir| {
        deps.git = .{
            .workdir = git_workdir,
            .server_url = env.get("CID_PUBLIC_URL") orelse "http://127.0.0.1:7070",
        };
    } else {
        std.log.info("CID_GIT_WORKDIR not set: releases queue their git copy for 'cid admin git --resync'", .{});
    }
    serve_mod.serve(arena, &deps, .{ .port = port }) catch |err| {
        return fail(io, .network, "the server stopped: {t}. Fix the cause, then run 'cid admin serve' again.", .{err});
    };
    return .ok;
}

fn runVerify(
    arena: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    env: *const std.process.Environ.Map,
    args: []const [:0]const u8,
) ExitCode {
    if (args.len != 2)
        return fail(io, .usage, "run 'cid admin verify <dataset> <release>'.", .{});
    const dataset_name = args[0];
    const release_name = args[1];

    const conninfo_raw = env.get("CID_DB") orelse
        return fail(io, .usage, "CID_DB is not set.\n  {s}\nThen run 'cid admin verify' again.", .{conninfo_example});
    const s3_endpoint = env.get("CID_S3_ENDPOINT") orelse return missingEnv(io, "CID_S3_ENDPOINT", "http://127.0.0.1:8333");
    const s3_access = env.get("CID_S3_ACCESS_KEY") orelse return missingEnv(io, "CID_S3_ACCESS_KEY", "cid");
    const s3_secret = env.get("CID_S3_SECRET_KEY") orelse return missingEnv(io, "CID_S3_SECRET_KEY", "…");
    const s3_bucket = env.get("CID_S3_BUCKET") orelse return missingEnv(io, "CID_S3_BUCKET", "cid");

    var diag: pg.Diag = .{};
    const conninfo = arena.dupeZ(u8, conninfo_raw) catch return .network;
    var db = pg.Db.connect(conninfo, &diag) catch
        return fail(io, .network, "cannot connect to the database: {s}\nCheck CID_DB, then run 'cid admin verify' again.", .{diag.message()});
    defer db.close();
    var s3_client = s3.Client.init(arena, io, .{
        .endpoint = s3_endpoint,
        .access_key = s3_access,
        .secret_key = s3_secret,
        .bucket = s3_bucket,
    }) catch return fail(io, .usage, "CID_S3_ENDPOINT must look like http://host:port.", .{});
    defer s3_client.deinit();

    // Dataset name → id.
    const name_z = arena.dupeZ(u8, dataset_name) catch return .network;
    const dataset_id: [:0]const u8 = blk: {
        var rows = db.query("SELECT dataset_id::text FROM datasets WHERE name = $1", &.{name_z}, &diag) catch
            return fail(io, .network, "database error: {s}", .{diag.message()});
        defer rows.deinit();
        if (rows.count() == 0)
            return fail(io, .usage, "no dataset named '{s}'. Check the name.", .{dataset_name});
        break :blk arena.dupeZ(u8, rows.get(0, 0)) catch return .network;
    };

    const result = release.verify(arena, &db, &s3_client, dataset_id, release_name) catch |err| switch (err) {
        error.NoSuchCommit => return fail(io, .usage, "no release '{s}' in '{s}'.", .{ release_name, dataset_name }),
        else => return fail(io, .network, "verify could not run: {t}. Fix the cause, then run it again.", .{err}),
    };

    if (result.ok) {
        out.print("Release {s} of {s} verifies: {d} items, manifest hash reproduced exactly.\n", .{
            release_name, dataset_name, result.items,
        }) catch return .network;
        out.flush() catch return .network;
        return .ok;
    }
    var buf: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &buf);
    const err_w = &stderr_writer.interface;
    err_w.print("cid: release {s} of {s} FAILS verification:\n", .{ release_name, dataset_name }) catch {};
    for (result.problems) |p| {
        const text = switch (p) {
            .recomputed_hash_differs => "history under the release's cutoff no longer reproduces the manifest (append-only was violated)",
            .stored_manifest_differs => "the stored manifest object does not match the recorded hash",
            .stored_manifest_missing => "the stored manifest object is missing",
            .item_missing_from_storage => "a released item is missing from storage",
        };
        err_w.print("  - {s}\n", .{text}) catch {};
    }
    err_w.writeAll("Investigate before anything else touches this dataset.\n") catch {};
    err_w.flush() catch {};
    return .integrity;
}

fn runGitAdmin(
    arena: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    env: *const std.process.Environ.Map,
    args: []const [:0]const u8,
) ExitCode {
    if (args.len < 1 or args.len > 2)
        return fail(io, .usage, "run 'cid admin git <dataset> [--resync]'.", .{});
    const dataset_name = args[0];
    const resync = args.len == 2 and eql(args[1], "--resync");
    if (args.len == 2 and !resync)
        return fail(io, .usage, "unknown flag '{s}'. Run 'cid admin git <dataset> [--resync]'.", .{args[1]});

    const conninfo_raw = env.get("CID_DB") orelse
        return fail(io, .usage, "CID_DB is not set.\n  {s}\nThen run 'cid admin git' again.", .{conninfo_example});
    var diag: pg.Diag = .{};
    const conninfo = arena.dupeZ(u8, conninfo_raw) catch return .network;
    var db = pg.Db.connect(conninfo, &diag) catch
        return fail(io, .network, "cannot connect to the database: {s}", .{diag.message()});
    defer db.close();

    if (resync) {
        const workdir = env.get("CID_GIT_WORKDIR") orelse
            return fail(io, .usage, "CID_GIT_WORKDIR is not set (where repository clones live). Export it, then run 'cid admin git --resync' again.", .{});
        const config: git_writer.Config = .{
            .workdir = workdir,
            .server_url = env.get("CID_PUBLIC_URL") orelse "http://127.0.0.1:7070",
        };
        const outcome = git_writer.processDataset(arena, io, &db, config, dataset_name) catch
            return fail(io, .network, "resync could not run. Check the dataset name and the database.", .{});
        out.print("Resync: {d} release{s} written, {d} failed.\n", .{ outcome.processed, plural(outcome.processed), outcome.failed }) catch return .network;
        out.flush() catch return .network;
        return if (outcome.failed == 0) .ok else .network;
    }

    const name_z = arena.dupeZ(u8, dataset_name) catch return .network;
    var rows = db.query(
        "SELECT release, status, coalesce(git_commit, '-'), attempts, coalesce(last_error, '') " ++
            "FROM git_writes w JOIN datasets d USING (dataset_id) WHERE d.name = $1 ORDER BY release",
        &.{name_z},
        &diag,
    ) catch return fail(io, .network, "database error: {s}", .{diag.message()});
    defer rows.deinit();
    if (rows.count() == 0) {
        out.print("No releases queued for {s} yet.\n", .{dataset_name}) catch return .network;
        out.flush() catch return .network;
        return .ok;
    }
    var any_failed = false;
    var i: usize = 0;
    while (i < rows.count()) : (i += 1) {
        const status = rows.get(i, 1);
        if (eql(status, "failed")) any_failed = true;
        out.print("{s: <16} {s: <8} {s: <14} attempts={s}", .{ rows.get(i, 0), status, rows.get(i, 2)[0..@min(12, rows.get(i, 2).len)], rows.get(i, 3) }) catch return .network;
        if (rows.get(i, 4).len > 0) out.print("  ({s})", .{rows.get(i, 4)}) catch return .network;
        out.writeAll("\n") catch return .network;
    }
    if (any_failed)
        out.writeAll("Fix the cause, then run 'cid admin git <dataset> --resync'.\n") catch return .network;
    out.flush() catch return .network;
    return .ok;
}

fn missingEnv(io: std.Io, name: []const u8, example: []const u8) ExitCode {
    return fail(io, .usage, "{s} is not set. Export it (e.g. {s}={s}), then run 'cid admin serve' again.", .{ name, name, example });
}

/// Every error ends with the command to run next (already in the formats above).
fn fail(io: std.Io, code: ExitCode, comptime fmt: []const u8, fmt_args: anytype) ExitCode {
    var buf: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &buf);
    const err = &stderr_writer.interface;
    err.print("cid: " ++ fmt ++ "\n", fmt_args) catch {};
    err.flush() catch {};
    return code;
}

fn plural(n: anytype) []const u8 {
    return if (n == 1) "" else "s";
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test "admin help names its commands and the env variable" {
    try std.testing.expect(std.mem.indexOf(u8, admin_help, "setup") != null);
    try std.testing.expect(std.mem.indexOf(u8, admin_help, "migrate") != null);
    try std.testing.expect(std.mem.indexOf(u8, admin_help, "CID_DB") != null);
}
