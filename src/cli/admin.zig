//! `cid admin …`: server administration. Hidden from plain `cid help` (rule 6).

const std = @import("std");
const root = @import("../cid.zig");
const pg = @import("../store/pg.zig");
const s3 = @import("../store/s3.zig");
const migrate = @import("../core/migrate.zig");
const api = @import("../server/api.zig");
const release = @import("../core/release.zig");
const git_writer = @import("../gitrepo/writer.zig");
const keys_mod = @import("../access/keys.zig");
const gitlab_sync = @import("../access/gitlab_sync.zig");
const purge_mod = @import("../core/purge.zig");
const preview_worker = @import("../preview/worker.zig");
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
    if (eql(sub, "previews")) {
        return runPreviews(arena, io, out, env);
    }
    if (eql(sub, "verify")) {
        return runVerify(arena, io, out, env, args[1..]);
    }
    if (eql(sub, "git")) {
        return runGitAdmin(arena, io, out, env, args[1..]);
    }
    if (eql(sub, "add-key")) {
        return runAddKey(arena, io, out, env, args[1..]);
    }
    if (eql(sub, "grant")) {
        return runGrant(arena, io, out, env, args[1..]);
    }
    if (eql(sub, "sync-gitlab")) {
        return runSyncGitlab(arena, io, out, env);
    }
    if (eql(sub, "purge")) {
        return runPurge(arena, io, out, env, args[1..]);
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
    const token = env.get("CID_TOKEN") orelse "";
    const token_secret = env.get("CID_TOKEN_SECRET");
    if (token.len == 0 and token_secret == null)
        return fail(io, .usage, "set CID_TOKEN_SECRET (SSH-issued tokens) or CID_TOKEN (one static token), then run 'cid admin serve' again.", .{});

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

    // The background loop: GitLab sync and git-write retries, every 10
    // minutes (CID_SYNC_INTERVAL_SECS overrides). Each tick opens its own
    // database connection, so a hiccup never poisons the server's.
    {
        const interval: u64 = blk: {
            const text = env.get("CID_SYNC_INTERVAL_SECS") orelse break :blk 600;
            break :blk std.fmt.parseInt(u64, text, 10) catch 600;
        };
        const bg: BackgroundConfig = .{
            .io = io,
            .conninfo = conninfo,
            .interval_secs = interval,
            .s3 = .{
                .endpoint = s3_endpoint,
                .access_key = s3_access,
                .secret_key = s3_secret,
                .bucket = s3_bucket,
            },
            .gitlab = if (env.get("CID_GITLAB_TOKEN")) |t| .{
                .base_url = env.get("CID_GITLAB_URL") orelse "https://gitlab.com",
                .token = t,
            } else null,
            .git = if (env.get("CID_GIT_WORKDIR")) |w| .{
                .workdir = w,
                .server_url = env.get("CID_PUBLIC_URL") orelse "http://127.0.0.1:7070",
            } else null,
        };
        // Previews always drain in the background; gitlab/git only when configured.
        {
            const thread = std.Thread.spawn(.{}, backgroundLoop, .{bg}) catch |err| {
                std.log.warn("background loop not started: {t}; use 'cid admin sync-gitlab' and 'cid admin git --resync' by hand", .{err});
                return fail(io, .network, "could not start the background loop: {t}", .{err});
            };
            thread.detach();
            std.log.info("background loop every {d}s (gitlab: {s}, git: {s})", .{
                interval,
                if (bg.gitlab != null) "on" else "off",
                if (bg.git != null) "on" else "off",
            });
        }
    }

    var deps: api.Deps = .{ .db = &db, .s3 = &s3_client, .io = io, .token = token, .token_secret = token_secret };
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
        if (result.purged > 0) {
            out.print("Release {s} of {s} verifies: {d} items, manifest hash reproduced exactly — intact except {d} purged item{s}.\n", .{
                release_name, dataset_name, result.items, result.purged, plural(result.purged),
            }) catch return .network;
        } else {
            out.print("Release {s} of {s} verifies: {d} items, manifest hash reproduced exactly.\n", .{
                release_name, dataset_name, result.items,
            }) catch return .network;
        }
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

fn adminDb(arena: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, next_cmd: []const u8) ?pg.Db {
    const conninfo_raw = env.get("CID_DB") orelse {
        _ = fail(io, .usage, "CID_DB is not set.\n  {s}\nThen run '{s}' again.", .{ conninfo_example, next_cmd });
        return null;
    };
    var diag: pg.Diag = .{};
    const conninfo = arena.dupeZ(u8, conninfo_raw) catch return null;
    return pg.Db.connect(conninfo, &diag) catch {
        _ = fail(io, .network, "cannot connect to the database: {s}", .{diag.message()});
        return null;
    };
}

fn runAddKey(
    arena: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    env: *const std.process.Environ.Map,
    args: []const [:0]const u8,
) ExitCode {
    if (args.len != 3)
        return fail(io, .usage, "run 'cid admin add-key <account> <display-name> <public-key-line>' (quote the key).", .{});
    const account = args[0];
    const display = args[1];
    const key_line = args[2];
    const fp = keys_mod.fingerprint(arena, key_line) orelse
        return fail(io, .usage, "that does not look like an OpenSSH public key line ('ssh-ed25519 AAAA… comment').", .{});

    var db = adminDb(arena, io, env, "cid admin add-key") orelse return .network;
    defer db.close();
    var diag: pg.Diag = .{};
    const account_z = arena.dupeZ(u8, account) catch return .network;
    const display_z = arena.dupeZ(u8, display) catch return .network;
    const fp_z = arena.dupeZ(u8, fp) catch return .network;
    const key_z = arena.dupeZ(u8, key_line) catch return .network;
    db.execParams(
        "INSERT INTO accounts (account_id, display_name, source) VALUES ($1, $2, 'dashboard') " ++
            "ON CONFLICT (account_id) DO UPDATE SET display_name = excluded.display_name",
        &.{ account_z, display_z },
        &diag,
    ) catch return fail(io, .network, "database error: {s}", .{diag.message()});
    db.execParams(
        "INSERT INTO ssh_keys (fingerprint, account_id, public_key) VALUES ($1, $2, $3) " ++
            "ON CONFLICT (fingerprint) DO UPDATE SET account_id = excluded.account_id, public_key = excluded.public_key",
        &.{ fp_z, account_z, key_z },
        &diag,
    ) catch return fail(io, .network, "database error: {s}", .{diag.message()});
    out.print("Registered key {s} for {s}.\n", .{ fp, account }) catch return .network;
    out.flush() catch return .network;
    return .ok;
}

fn runGrant(
    arena: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    env: *const std.process.Environ.Map,
    args: []const [:0]const u8,
) ExitCode {
    if (args.len != 3)
        return fail(io, .usage, "run 'cid admin grant <dataset> <account> <read|write|maintain>'.", .{});
    const dataset = args[0];
    const account = args[1];
    const level = args[2];
    if (!eql(level, "read") and !eql(level, "write") and !eql(level, "maintain"))
        return fail(io, .usage, "the level is read, write or maintain. Run 'cid admin grant {s} {s} read'.", .{ dataset, account });

    var db = adminDb(arena, io, env, "cid admin grant") orelse return .network;
    defer db.close();
    var diag: pg.Diag = .{};
    const dataset_z = arena.dupeZ(u8, dataset) catch return .network;
    const account_z = arena.dupeZ(u8, account) catch return .network;
    const level_z = arena.dupeZ(u8, level) catch return .network;
    db.execParams(
        "INSERT INTO access (dataset_id, account_id, level, source) " ++
            "SELECT d.dataset_id, $2, $3, 'dashboard' FROM datasets d WHERE d.name = $1 " ++
            "ON CONFLICT (dataset_id, account_id) DO UPDATE SET level = excluded.level",
        &.{ dataset_z, account_z, level_z },
        &diag,
    ) catch return fail(io, .network, "database error: {s}", .{diag.message()});
    out.print("Granted {s} on {s} to {s}.\n", .{ level, dataset, account }) catch return .network;
    out.flush() catch return .network;
    return .ok;
}

fn runSyncGitlab(
    arena: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    env: *const std.process.Environ.Map,
) ExitCode {
    const token = env.get("CID_GITLAB_TOKEN") orelse
        return fail(io, .usage, "CID_GITLAB_TOKEN is not set (a token with read_api scope). Export it, then run 'cid admin sync-gitlab' again.", .{});
    const base_url = env.get("CID_GITLAB_URL") orelse "https://gitlab.com";

    var db = adminDb(arena, io, env, "cid admin sync-gitlab") orelse return .network;
    defer db.close();

    const outcome = gitlab_sync.syncAll(arena, io, &db, .{ .base_url = base_url, .token = token }) catch |err| switch (err) {
        error.GitLabUnreachable => return fail(io, .network, "cannot reach {s}. Check the network, then run 'cid admin sync-gitlab' again.", .{base_url}),
        else => return fail(io, .network, "sync failed: {t}. Check CID_GITLAB_TOKEN has read_api on the datasets group, then run it again.", .{err}),
    };
    out.print("Synced {d} dataset{s} from {s}: {d} members ({d} removed), {d} keys ({d} removed).", .{
        outcome.datasets,     plural(outcome.datasets), base_url,
        outcome.members,      outcome.access_removed,   outcome.keys,
        outcome.keys_removed,
    }) catch return .network;
    if (outcome.datasets_failed > 0)
        out.print(" {d} project{s} could not be read (see the log).", .{ outcome.datasets_failed, plural(outcome.datasets_failed) }) catch return .network;
    out.writeAll("\n") catch return .network;
    out.flush() catch return .network;
    return .ok;
}

fn runPurge(
    arena: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    env: *const std.process.Environ.Map,
    args: []const [:0]const u8,
) ExitCode {
    var positional: std.ArrayList([]const u8) = .empty;
    var reason: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (eql(args[i], "--reason")) {
            i += 1;
            if (i >= args.len) return fail(io, .usage, "--reason needs text. Run 'cid admin purge <dataset> <path|hash> --reason \"erasure request #123\"'.", .{});
            reason = args[i];
        } else {
            positional.append(arena, args[i]) catch return .network;
        }
    }
    if (positional.items.len != 2 or reason == null)
        return fail(io, .usage, "run 'cid admin purge <dataset> <path|hash> --reason \"why\"'. The reason is recorded forever.", .{});

    const s3_endpoint = env.get("CID_S3_ENDPOINT") orelse return missingEnv(io, "CID_S3_ENDPOINT", "http://127.0.0.1:8333");
    const s3_access = env.get("CID_S3_ACCESS_KEY") orelse return missingEnv(io, "CID_S3_ACCESS_KEY", "cid");
    const s3_secret = env.get("CID_S3_SECRET_KEY") orelse return missingEnv(io, "CID_S3_SECRET_KEY", "…");
    const s3_bucket = env.get("CID_S3_BUCKET") orelse return missingEnv(io, "CID_S3_BUCKET", "cid");
    var db = adminDb(arena, io, env, "cid admin purge") orelse return .network;
    defer db.close();
    var s3_client = s3.Client.init(arena, io, .{
        .endpoint = s3_endpoint,
        .access_key = s3_access,
        .secret_key = s3_secret,
        .bucket = s3_bucket,
    }) catch return fail(io, .usage, "CID_S3_ENDPOINT must look like http://host:port.", .{});
    defer s3_client.deinit();

    const by = env.get("USER") orelse "admin";
    const by_tag = std.fmt.allocPrint(arena, "user:{s}", .{by}) catch return .network;
    const result = purge_mod.purge(arena, &db, &s3_client, positional.items[0], positional.items[1], reason.?, by_tag) catch |err| switch (err) {
        error.NoSuchDataset => return fail(io, .usage, "no dataset named '{s}'.", .{positional.items[0]}),
        error.NoSuchItem => return fail(io, .usage, "'{s}' matches no item in {s}. Give a path from the dataset or a 64-hex hash.", .{ positional.items[1], positional.items[0] }),
        error.AlreadyPurged => return fail(io, .usage, "that content is already purged. Nothing to do.", .{}),
        else => return fail(io, .network, "purge could not finish: {t}. Run the same command again; it resumes.", .{err}),
    };
    out.print("Purged {s} ({s}…) from storage. {d} release{s} now read{s} \"intact except purged\"; the reason is on record.\n", .{
        positional.items[1],              result.hash_hex[0..12],                         result.releases_affected,
        plural(result.releases_affected), if (result.releases_affected == 1) "s" else "",
    }) catch return .network;
    out.flush() catch return .network;
    return .ok;
}

const BackgroundConfig = struct {
    io: std.Io,
    conninfo: [:0]const u8,
    interval_secs: u64,
    gitlab: ?gitlab_sync.Config,
    git: ?git_writer.Config,
    s3: s3.Config,
};

fn backgroundLoop(bg: BackgroundConfig) void {
    while (true) {
        std.Io.sleep(bg.io, .fromNanoseconds(@intCast(bg.interval_secs * std.time.ns_per_s)), .awake) catch return;
        var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var db = pg.Db.connect(bg.conninfo, null) catch {
            std.log.warn("background: database unreachable; will retry", .{});
            continue;
        };
        defer db.close();

        {
            var s3_bg = s3.Client.init(arena, bg.io, bg.s3) catch {
                std.log.warn("background: bad S3 config for previews", .{});
                continue;
            };
            defer s3_bg.deinit();
            if (preview_worker.processPending(arena, bg.io, &db, &s3_bg, .{})) |outcome| {
                if (outcome.built > 0 or outcome.skipped > 0)
                    std.log.info("background: previews {d} built, {d} skipped", .{ outcome.built, outcome.skipped });
            } else |err| {
                std.log.warn("background: preview pass failed: {t}", .{err});
            }
        }
        if (bg.gitlab) |config| {
            if (gitlab_sync.syncAll(arena, bg.io, &db, config)) |outcome| {
                if (outcome.members > 0 or outcome.keys > 0 or outcome.access_removed > 0)
                    std.log.info("background: gitlab sync {d} members, {d} keys", .{ outcome.members, outcome.keys });
            } else |err| {
                std.log.warn("background: gitlab sync failed: {t}", .{err});
            }
        }
        if (bg.git) |config| {
            var names = db.query(
                "SELECT DISTINCT d.name FROM git_writes w JOIN datasets d USING (dataset_id) WHERE w.status <> 'done'",
                &.{},
                null,
            ) catch continue;
            defer names.deinit();
            var i: usize = 0;
            while (i < names.count()) : (i += 1) {
                const name = arena.dupe(u8, names.get(i, 0)) catch continue;
                _ = git_writer.processDataset(arena, bg.io, &db, config, name) catch |err| {
                    std.log.warn("background: git write for {s} failed: {t}", .{ name, err });
                };
            }
        }
    }
}

fn runPreviews(
    arena: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    env: *const std.process.Environ.Map,
) ExitCode {
    const s3_endpoint = env.get("CID_S3_ENDPOINT") orelse return missingEnv(io, "CID_S3_ENDPOINT", "http://127.0.0.1:8333");
    const s3_access = env.get("CID_S3_ACCESS_KEY") orelse return missingEnv(io, "CID_S3_ACCESS_KEY", "cid");
    const s3_secret = env.get("CID_S3_SECRET_KEY") orelse return missingEnv(io, "CID_S3_SECRET_KEY", "…");
    const s3_bucket = env.get("CID_S3_BUCKET") orelse return missingEnv(io, "CID_S3_BUCKET", "cid");
    var db = adminDb(arena, io, env, "cid admin previews") orelse return .network;
    defer db.close();
    var s3_client = s3.Client.init(arena, io, .{
        .endpoint = s3_endpoint,
        .access_key = s3_access,
        .secret_key = s3_secret,
        .bucket = s3_bucket,
    }) catch return fail(io, .usage, "CID_S3_ENDPOINT must look like http://host:port.", .{});
    defer s3_client.deinit();

    const outcome = preview_worker.processPending(arena, io, &db, &s3_client, .{}) catch |err|
        return fail(io, .network, "the preview pass could not run: {t}. Fix the cause, then run 'cid admin previews' again.", .{err});
    out.print("Previews: {d} built, {d} skipped, {d} will retry.\n", .{
        outcome.built, outcome.skipped, outcome.failed,
    }) catch return .network;
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
