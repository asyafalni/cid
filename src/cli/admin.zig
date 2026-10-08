//! `cid admin …`: server administration. Hidden from plain `cid help` (rule 6).

const std = @import("std");
const nilo = @import("nilo_http");
const root = @import("../cid.zig");
const dbx = @import("../store/db.zig");
const blob = @import("../store/blob.zig");
const migrate = @import("../core/migrate.zig");
const api = @import("../server/api.zig");
const release = @import("../core/release.zig");
const git_writer = @import("../gitrepo/writer.zig");
const keys_mod = @import("../access/keys.zig");
const gitlab_sync = @import("../access/gitlab_sync.zig");
const purge_mod = @import("../core/purge.zig");
const gc_mod = @import("../core/gc.zig");
const preview_worker = @import("../preview/worker.zig");
const serve_mod = @import("../server/serve.zig");
const signin_mod = @import("../server/signin.zig");

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
    \\  git <dataset> [--resync]     dataset repository status, and whether it still
    \\             holds what cid wrote; --resync retries
    \\  gc [--days <n>] [--apply]    show unreferenced files (untouched for n days,
    \\             default 30); --apply deletes them
    \\  purge <dataset> <path|hash> --reason "why"   audited erasure of one item
    \\  previews   one pass of the preview worker (serve also runs it)
    \\  sync-gitlab  sync members and SSH keys now
    \\  add-key <account> <name> <public-key>   register an SSH key by hand
    \\  grant <dataset> <account> <read|write|maintain>   give access by hand
    \\  rename <dataset> <new-name> [--git <git-url>]   after its GitLab project
    \\             moved; the old address stops answering, as in git, and
    \\             its git repository's files are rewritten to name it.
    \\             The same name with --git: only the repository moved
    \\
    \\All of them read configuration from the environment:
    \\  CID_DB     the TimescaleDB connection (setup, migrate, serve)
    \\  CID_S3_ENDPOINT, CID_S3_ACCESS_KEY, CID_S3_SECRET_KEY,
    \\  CID_S3_REGION (optional), CID_TOKEN    (serve)
    \\  CID_S3_PUBLIC_ENDPOINT  where clients reach the store, when not at
    \\             CID_S3_ENDPOINT: the URLs they are given are signed
    \\             for it (optional; deploy/proxy/README.md) (serve)
    \\  CID_GITLAB_OAUTH_ID, CID_GITLAB_OAUTH_SECRET, CID_PUBLIC_URL,
    \\  CID_SESSION_SECRET  "Sign in with GitLab" on the dashboard (serve)
    \\  CID_BROWSE_DIR  where the server keeps browse indexes, one
    \\             Parquet file per version (default /tmp/cid-browse) (serve)
    \\  CID_WORK_DIR  files in flight: manifests going up, tables a row
    \\             diff compares (default /tmp/cid-work) (serve)
    \\  CID_TOKEN_SECRET  signs the tokens the SSH front door hands out
    \\             (serve, ssh-auth)
    \\  CID_GIT_WORKDIR  turns the git writer on: clones of dataset
    \\             repositories live here (serve)
    \\  CID_GITLAB_TOKEN, CID_GITLAB_URL  member and key sync (serve,
    \\             sync-gitlab); who may create a dataset (ssh-auth)
    \\  CID_SYNC_INTERVAL_SECS  the background loop's period: previews,
    \\             GitLab sync, git retries (default 600) (serve)
    \\  The bucket is always named 'cid'; create it on the store first
    \\  (docker-compose.test.yml shows how).
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
    if (eql(sub, "rename")) {
        return runRename(arena, io, out, env, args[1..]);
    }
    if (eql(sub, "sync-gitlab")) {
        return runSyncGitlab(arena, io, out, env);
    }
    if (eql(sub, "purge")) {
        return runPurge(arena, io, out, env, args[1..]);
    }
    if (eql(sub, "gc")) {
        return runGc(arena, io, out, env, args[1..]);
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
    const spec = env.get("CID_DB") orelse {
        return fail(io, .usage, "CID_DB is not set.\nSet it to the server database connection, e.g.\n  {s}\nThen run 'cid admin {s}' again.", .{ conninfo_example, sub });
    };

    var standalone: dbx.Standalone = undefined;
    standalone.open(arena, spec) catch {
        return fail(io, .network, "cannot connect to the database.\nCheck the database is running and CID_DB is right, then run 'cid admin {s}' again.", .{sub});
    };
    defer standalone.close();
    standalone.db.watching(stashDbProblem);

    var scope = nilo.Run.init(arena);
    defer scope.deinit();

    const summary = migrate.run(&standalone.db, &scope, out) catch {
        return fail(io, .network, "migration failed: {s}\nFix the cause, then run 'cid admin {s}' again; the failed migration was rolled back.", .{ lastDbProblem(), sub });
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
    const s3_region = env.get("CID_S3_REGION") orelse "us-east-1";
    const token = env.get("CID_TOKEN") orelse "";
    const token_secret = env.get("CID_TOKEN_SECRET");
    if (token.len == 0 and token_secret == null)
        return fail(io, .usage, "set CID_TOKEN_SECRET (SSH-issued tokens) or CID_TOKEN (one static token), then run 'cid admin serve' again.", .{});

    const conninfo = arena.dupeZ(u8, conninfo_raw) catch return .network;
    // The server's Db is a nilo Service: init records the URL, and
    // serve()'s listen() opens the pool on the server's own loop.
    const db_url = dbx.urlFrom(arena, conninfo) catch return .network;
    var db = dbx.sql.Db.init(arena, db_url, .{ .unchecked = true });
    defer db.deinit();

    // Opened here, started by listen() on the server's own loop, the
    // same way the Db is; serve() checks the 'cid' bucket exists before
    // the first request and refuses to start without it.
    var s3_client: blob.Client = undefined;
    s3_client.open(arena, .{
        .endpoint = s3_endpoint,
        .access_key = s3_access,
        .secret_key = s3_secret,
        .region = s3_region,
        .public_endpoint = env.get("CID_S3_PUBLIC_ENDPOINT"),
    }) catch return fail(io, .usage, "CID_S3_ENDPOINT and CID_S3_PUBLIC_ENDPOINT must look like http://host:port. Fix them, then run 'cid admin serve' again.", .{});
    defer s3_client.deinit();

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
                .region = s3_region,
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

    var deps: api.Deps = .{ .db = &db, .s3 = &s3_client, .io = io, .gpa = std.heap.smp_allocator, .token = token, .token_secret = token_secret };
    if (env.get("CID_BROWSE_DIR")) |dir| deps.browse_dir = dir;
    if (env.get("CID_WORK_DIR")) |dir| deps.work_dir = dir;
    if (env.get("CID_GITLAB_TOKEN")) |t| deps.gitlab = .{
        .base_url = env.get("CID_GITLAB_URL") orelse "https://gitlab.com",
        .token = t,
    };
    if (env.get("CID_GIT_WORKDIR")) |git_workdir| {
        deps.git = .{
            .workdir = git_workdir,
            .server_url = env.get("CID_PUBLIC_URL") orelse "http://127.0.0.1:7070",
        };
    } else {
        std.log.info("CID_GIT_WORKDIR not set: releases queue their git copy for 'cid admin git --resync'", .{});
    }
    // Dashboard sign-in. GitLab OAuth when its application is configured;
    // sessions are sealed with CID_SESSION_SECRET, which must then be set
    // (a per-start secret would sign everybody out on every deploy).
    const signin_cfg: ?signin_mod.Config = if (env.get("CID_GITLAB_OAUTH_ID")) |client_id| blk: {
        const client_secret = env.get("CID_GITLAB_OAUTH_SECRET") orelse
            return fail(io, .usage, "CID_GITLAB_OAUTH_ID is set but CID_GITLAB_OAUTH_SECRET is not. Export the GitLab application's secret, then run 'cid admin serve' again.", .{});
        const public_url = env.get("CID_PUBLIC_URL") orelse
            return fail(io, .usage, "GitLab sign-in needs CID_PUBLIC_URL (where browsers reach this server; the GitLab application's redirect URI is <it>/auth/gitlab/callback). Export it, then run 'cid admin serve' again.", .{});
        if (env.get("CID_SESSION_SECRET") == null)
            return fail(io, .usage, "GitLab sign-in needs CID_SESSION_SECRET (32 random bytes, base64; e.g. from 'head -c 32 /dev/urandom | base64'), the same on every instance and across restarts. Export it, then run 'cid admin serve' again.", .{});
        break :blk .{
            .gitlab_url = env.get("CID_GITLAB_URL") orelse "https://gitlab.com",
            .client_id = client_id,
            .client_secret = client_secret,
            .public_url = public_url,
        };
    } else null;
    deps.gitlab_signin = signin_cfg != null;

    var secret: [32]u8 = undefined;
    if (env.get("CID_SESSION_SECRET")) |text| {
        const trimmed = std.mem.trim(u8, text, " \n");
        const len = std.base64.standard.Decoder.calcSizeForSlice(trimmed) catch
            return fail(io, .usage, "CID_SESSION_SECRET is not base64. Make one with 'head -c 32 /dev/urandom | base64', then run 'cid admin serve' again.", .{});
        if (len != 32)
            return fail(io, .usage, "CID_SESSION_SECRET decodes to {d} bytes; it must be exactly 32. Make one with 'head -c 32 /dev/urandom | base64', then run 'cid admin serve' again.", .{len});
        std.base64.standard.Decoder.decode(&secret, trimmed) catch
            return fail(io, .usage, "CID_SESSION_SECRET is not base64. Make one with 'head -c 32 /dev/urandom | base64', then run 'cid admin serve' again.", .{});
    } else {
        // No GitLab sign-in, so no session outlives this process anyway.
        io.random(&secret);
    }

    // A long-running server needs an allocator that frees: the command's
    // arena never would, and every streamed batch would stay allocated.
    serve_mod.serve(std.heap.smp_allocator, &deps, .{ .port = port, .session_secret = &secret, .signin = signin_cfg }) catch |err| {
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
    const s3_region = env.get("CID_S3_REGION") orelse "us-east-1";

    _ = conninfo_raw;
    var standalone: dbx.Standalone = undefined;
    adminPool(&standalone, arena, io, env, "cid admin verify") orelse return .network;
    defer standalone.close();
    var scope = dbx.Run.init(arena);
    defer scope.deinit();
    var s3_client: blob.Client = undefined;
    s3_client.open(arena, .{
        .endpoint = s3_endpoint,
        .access_key = s3_access,
        .secret_key = s3_secret,
        .region = s3_region,
    }) catch return fail(io, .usage, "CID_S3_ENDPOINT must look like http://host:port.", .{});
    defer s3_client.deinit();
    s3_client.start(io) catch
        return fail(io, .network, "cannot reach storage at {s}. Check SeaweedFS, then run the command again.", .{s3_endpoint});

    // Dataset name → id.
    const dataset_id = (standalone.db.rawOne([]const u8, &scope, "SELECT dataset_id::text FROM datasets WHERE name = $1", .{@as([]const u8, dataset_name)}) catch
        return fail(io, .network, "database error: {s}", .{lastDbProblem()})) orelse
        return fail(io, .usage, "no dataset named '{s}'. Check the name.", .{dataset_name});

    const result = release.verify(arena, std.heap.page_allocator, &standalone.db, &scope, &s3_client, dataset_id, release_name) catch |err| switch (err) {
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
    err_w.print("Investigate before anything else touches this dataset: stop writes to it, restore storage or the\n" ++
        "database from backup, then run 'cid admin verify {s} {s}' again.\n", .{ dataset_name, release_name }) catch {};
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

    var standalone: dbx.Standalone = undefined;
    adminPool(&standalone, arena, io, env, "cid admin git") orelse return .network;
    defer standalone.close();
    var scope = dbx.Run.init(arena);
    defer scope.deinit();

    if (resync) {
        const workdir = env.get("CID_GIT_WORKDIR") orelse
            return fail(io, .usage, "CID_GIT_WORKDIR is not set (where repository clones live). Export it, then run 'cid admin git --resync' again.", .{});
        const config: git_writer.Config = .{
            .workdir = workdir,
            .server_url = env.get("CID_PUBLIC_URL") orelse "http://127.0.0.1:7070",
        };
        const outcome = git_writer.processDataset(arena, io, &standalone.db, &scope, config, dataset_name) catch
            return fail(io, .network, "resync could not run. Check the dataset name and the database.", .{});
        out.print("Resync: {d} release{s} written, {d} failed.\n", .{ outcome.processed, plural(outcome.processed), outcome.failed }) catch return .network;
        // And the newest one's files as the dataset is named now (after a
        // rename whose git update failed, this is the retry).
        if (outcome.failed == 0) {
            const r = git_writer.refresh(arena, io, &standalone.db, &scope, config, dataset_name, "dataset: files brought up to date") catch {
                out.flush() catch {};
                return fail(io, .network, "could not bring the repository's files up to date (see the git error above). Fix the cause, then run 'cid admin git {s} --resync' again.", .{dataset_name});
            };
            if (r == .committed) out.print("Brought its files up to date: commit {s} on main.\n", .{r.committed[0..@min(12, r.committed.len)]}) catch return .network;
        }
        out.flush() catch return .network;
        return if (outcome.failed == 0) .ok else .network;
    }

    const WriteRow = struct {
        pub const nilo_table = .projection;
        release: []const u8,
        status: []const u8,
        git_commit: []const u8,
        attempts: i32,
        last_error: []const u8,
    };
    const rows = standalone.db.raw(WriteRow, &scope, "SELECT release, status, coalesce(git_commit, '-') AS git_commit, attempts, " ++
        "coalesce(last_error, '') AS last_error " ++
        "FROM git_writes w JOIN datasets d USING (dataset_id) WHERE d.name = $1 ORDER BY release", .{@as([]const u8, dataset_name)}) catch
        return fail(io, .network, "database error: {s}", .{lastDbProblem()});
    if (rows.len == 0) {
        out.print("No releases queued for {s} yet.\n", .{dataset_name}) catch return .network;
        out.flush() catch return .network;
        return .ok;
    }
    var any_failed = false;
    for (rows) |row| {
        if (eql(row.status, "failed")) any_failed = true;
        out.print("{s: <16} {s: <8} {s: <14} attempts={d}", .{ row.release, row.status, row.git_commit[0..@min(12, row.git_commit.len)], row.attempts }) catch return .network;
        if (row.last_error.len > 0) out.print("  ({s})", .{row.last_error}) catch return .network;
        out.writeAll("\n") catch return .network;
    }
    if (any_failed)
        out.writeAll("Fix the cause, then run 'cid admin git <dataset> --resync'.\n") catch return .network;

    // Whether the repository still holds what cid wrote, by plain git, so
    // the same on every host. A rewrite is an integrity failure (exit 3).
    const workdir = env.get("CID_GIT_WORKDIR") orelse {
        out.writeAll("Repository: not checked here (CID_GIT_WORKDIR is not set; run this where the git writer runs).\n") catch return .network;
        out.flush() catch return .network;
        return .ok;
    };
    const config: git_writer.Config = .{ .workdir = workdir, .server_url = env.get("CID_PUBLIC_URL") orelse "http://127.0.0.1:7070" };
    const seen = git_writer.inspect(arena, io, &standalone.db, &scope, config, dataset_name) catch |err| {
        out.flush() catch {};
        return switch (err) {
            error.GitFailed => fail(io, .network, "could not read the git repository (see git's words above). Check it is reachable, then run 'cid admin git {s}' again.", .{dataset_name}),
            else => fail(io, .network, "database error: {s}", .{lastDbProblem()}),
        };
    };
    if (seen.problems.len == 0) {
        out.print("Repository: matches what cid wrote ({d} release{s}).\n", .{ seen.releases, plural(seen.releases) }) catch return .network;
        out.flush() catch return .network;
        return .ok;
    }
    out.writeAll("Repository: changed since cid wrote it:\n") catch return .network;
    for (seen.problems) |p| out.print("  {s}\n", .{p}) catch return .network;
    out.writeAll("Someone with push rights rewrote it; cid repairs nothing by itself. Protect main and release tags on its host\n" ++
        "so only cid's key may push, then put back what is missing from a clone that still has it\n" ++
        "(git push origin <tag>, or git push --force origin <commit>:main), and run 'cid admin git <dataset>' again.\n") catch return .network;
    out.flush() catch return .network;
    return .integrity;
}

/// Opens a Standalone pool for a one-shot admin command, with the usual
/// what-to-do-next error messages. The caller owns close().
fn adminPool(standalone: *dbx.Standalone, arena: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, next_cmd: []const u8) ?void {
    const spec = env.get("CID_DB") orelse {
        _ = fail(io, .usage, "CID_DB is not set.\n  {s}\nThen run '{s}' again.", .{ conninfo_example, next_cmd });
        return null;
    };
    standalone.open(arena, spec) catch {
        _ = fail(io, .network, "cannot connect to the database. Check CID_DB, then run '{s}' again.", .{next_cmd});
        return null;
    };
    standalone.db.watching(stashDbProblem);
    return {};
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

    var standalone: dbx.Standalone = undefined;
    adminPool(&standalone, arena, io, env, "cid admin add-key") orelse return .network;
    defer standalone.close();
    var scope = dbx.Run.init(arena);
    defer scope.deinit();
    _ = standalone.db.exec(
        &scope,
        "INSERT INTO accounts (account_id, display_name, source) VALUES ($1, $2, 'dashboard') " ++
            "ON CONFLICT (account_id) DO UPDATE SET display_name = excluded.display_name",
        .{ @as([]const u8, account), @as([]const u8, display) },
    ) catch return fail(io, .network, "database error: {s}", .{lastDbProblem()});
    _ = standalone.db.exec(
        &scope,
        "INSERT INTO ssh_keys (fingerprint, account_id, public_key, source) VALUES ($1, $2, $3, 'admin') " ++
            "ON CONFLICT (fingerprint) DO UPDATE SET account_id = excluded.account_id, public_key = excluded.public_key, source = 'admin'",
        .{ fp, @as([]const u8, account), @as([]const u8, key_line) },
    ) catch return fail(io, .network, "database error: {s}", .{lastDbProblem()});
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

    var standalone: dbx.Standalone = undefined;
    adminPool(&standalone, arena, io, env, "cid admin grant") orelse return .network;
    defer standalone.close();
    var scope = dbx.Run.init(arena);
    defer scope.deinit();
    _ = standalone.db.exec(
        &scope,
        "INSERT INTO access (dataset_id, account_id, level, source) " ++
            "SELECT d.dataset_id, $2, $3, 'dashboard' FROM datasets d WHERE d.name = $1 " ++
            "ON CONFLICT (dataset_id, account_id) DO UPDATE SET level = excluded.level",
        .{ @as([]const u8, dataset), @as([]const u8, account), @as([]const u8, level) },
    ) catch return fail(io, .network, "database error: {s}", .{lastDbProblem()});
    out.print("Granted {s} on {s} to {s}.\n", .{ level, dataset, account }) catch return .network;
    out.flush() catch return .network;
    return .ok;
}

/// A dataset's new path, and its repository's new URL when that moved
/// (access follows the repository the URL names, so on a server synced
/// with GitLab the new one must be there). As in git, nothing answers at the old path afterwards:
/// each folder runs `cid remote set-url`.
fn runRename(
    arena: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    env: *const std.process.Environ.Map,
    args: []const [:0]const u8,
) ExitCode {
    const usage = "run 'cid admin rename <dataset> <new-name> [--git <git-url>]'.";
    var names: [2][]const u8 = undefined;
    var n: usize = 0;
    var git_url: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (eql(args[i], "--git")) {
            i += 1;
            if (i == args.len) return fail(io, .usage, usage, .{});
            git_url = args[i];
        } else {
            if (n == 2) return fail(io, .usage, usage, .{});
            names[n] = args[i];
            n += 1;
        }
    }
    if (n != 2) return fail(io, .usage, usage, .{});
    const old = names[0];
    const new = names[1];
    // The same name: the repository moved, the dataset did not.
    const same = eql(old, new);
    if (same and git_url == null)
        return fail(io, .usage, "nothing to change: give a new name, or the new git URL. Run 'cid admin rename {s} {s} --git <git-url>'.", .{ old, old });
    if (!validDatasetPath(new))
        return fail(io, .usage, "'{s}' is not a dataset path: segments of letters, digits, '.', '_' and '-', joined by '/'. Run 'cid admin rename {s} <new-name>'.", .{ new, old });

    var standalone: dbx.Standalone = undefined;
    adminPool(&standalone, arena, io, env, "cid admin rename") orelse return .network;
    defer standalone.close();
    var scope = dbx.Run.init(arena);
    defer scope.deinit();
    const taken = standalone.db.rawOne(i64, &scope, "SELECT 1::bigint FROM datasets WHERE name = $1", .{new}) catch
        return fail(io, .network, "database error: {s}", .{lastDbProblem()});
    if (taken != null and !same) return fail(io, .usage, "a dataset named {s} already exists. Pick another name, then run 'cid admin rename {s} <new-name>'.", .{ new, old });
    const exists = standalone.db.rawOne(i64, &scope, "SELECT 1::bigint FROM datasets WHERE name = $1", .{old}) catch
        return fail(io, .network, "database error: {s}", .{lastDbProblem()});
    if (exists == null) return fail(io, .usage, "no dataset named {s}. Check the name, then run 'cid admin rename <dataset> <new-name>'.", .{old});

    // On a server that takes access from GitLab, the repository must be
    // there, as at init: access comes from the repository the URL names.
    if (git_url) |url| if (env.get("CID_GITLAB_TOKEN")) |_| {
        const base = env.get("CID_GITLAB_URL") orelse "https://gitlab.com";
        if (gitlab_sync.projectOf(url, base) == null)
            return fail(io, .usage, "this server takes access from {s}, and {s} is not a repository there; nothing was renamed. Move the repository to {s}, then run 'cid admin rename' again with its URL.", .{ gitlab_sync.hostOf(base), url, gitlab_sync.hostOf(base) });
    };

    // A new git URL must take a push before anything moves, as at init.
    const writer_config: ?git_writer.Config = if (env.get("CID_GIT_WORKDIR")) |workdir| .{
        .workdir = workdir,
        .server_url = env.get("CID_PUBLIC_URL") orelse "http://127.0.0.1:7070",
    } else null;
    if (git_url) |url| if (writer_config) |config| {
        const probed = git_writer.probe(arena, io, config, url) catch
            return fail(io, .network, "could not run git to check {s}. Check git is installed, then run 'cid admin rename' again.", .{url});
        switch (probed) {
            .ok => {},
            .unreachable_repo => |why| return fail(io, .network, "cid cannot reach {s} ({s}); nothing was renamed. Move the repository on its host first, then run 'cid admin rename' again.", .{ url, why }),
            .not_writable => |why| return fail(io, .access, "cid cannot push to {s} ({s}); nothing was renamed. Give the server's key write access there, then run 'cid admin rename' again.", .{ url, why }),
        }
    };

    _ = standalone.db.exec(&scope, "UPDATE datasets SET name = $2, git_url = coalesce($3, git_url) WHERE name = $1", .{ old, new, git_url }) catch
        return fail(io, .network, "database error: {s}", .{lastDbProblem()});
    if (same)
        out.print("Changed the git repository of {s} to {s}.\n", .{ old, git_url.? }) catch return .network
    else
        out.print("Renamed {s} to {s}. The old address no longer answers.\n", .{ old, new }) catch return .network;

    // The repository's own files name the dataset (the .cid marker that
    // `cid clone <git-url>` reads, the README): rewritten now, by git.
    var code: ExitCode = .ok;
    if (writer_config) |config| {
        const message = if (same)
            std.fmt.allocPrint(arena, "dataset: repository now {s}", .{git_url.?}) catch return .network
        else
            std.fmt.allocPrint(arena, "dataset: now {s}", .{new}) catch return .network;
        if (git_writer.refresh(arena, io, &standalone.db, &scope, config, new, message)) |r| switch (r) {
            .nothing_released => out.writeAll("Its git repository gets its files at the first release.\n") catch return .network,
            .up_to_date => out.writeAll("Its git repository already names it.\n") catch return .network,
            .committed => |sha| out.print("Its git repository now names it: commit {s} on main.\n", .{sha[0..@min(12, sha.len)]}) catch return .network,
        } else |_| {
            out.print("Its git repository could not be updated (see the git error above). Fix the cause, then run 'cid admin git {s} --resync'.\n", .{new}) catch return .network;
            code = .network;
        }
    } else {
        out.print("This machine has no git writer (CID_GIT_WORKDIR unset): run 'cid admin git {s} --resync' where it has one, to update its git repository.\n", .{new}) catch return .network;
    }
    if (same)
        out.writeAll("In each folder of it, run: cid remote set-url") catch return .network
    else
        out.print("In each folder of it, run: cid remote set-url cid@<host>:{s}", .{new}) catch return .network;
    if (git_url) |url| out.print(" --git {s}", .{url}) catch return .network;
    out.writeAll("\n") catch return .network;
    out.flush() catch return .network;
    return code;
}

/// A dataset path as GitLab spells project paths: `/`-joined segments of
/// letters, digits, `.`, `_` and `-`, none empty, none `-` alone (the
/// API's `/-/` separator), none ending in `.git` or `.cid`.
fn validDatasetPath(path: []const u8) bool {
    if (path.len == 0 or path.len > 255) return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or eql(seg, "-") or eql(seg, ".") or eql(seg, "..")) return false;
        for (seg) |c| if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-')) return false;
    }
    return !std.mem.endsWith(u8, path, ".git") and !std.mem.endsWith(u8, path, ".cid");
}

test "a new dataset path is checked the way GitLab spells project paths" {
    try std.testing.expect(validDatasetPath("org/datasets/speech-id"));
    try std.testing.expect(validDatasetPath("org/v1.2_data"));
    for ([_][]const u8{ "", "/org/x", "org/x/", "org//x", "org/-/x", "org/x y", "org/x.git", "org/x.cid", "org/../x" }) |bad|
        try std.testing.expect(!validDatasetPath(bad));
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

    var standalone: dbx.Standalone = undefined;
    standalone.open(arena, env.get("CID_DB") orelse "") catch
        return fail(io, .network, "cannot connect to the database. Check CID_DB, then run 'cid admin sync-gitlab' again.", .{});
    defer standalone.close();
    var scope = dbx.Run.init(arena);
    defer scope.deinit();

    const outcome = gitlab_sync.syncAll(arena, io, &standalone.db, &scope, .{ .base_url = base_url, .token = token }) catch |err| switch (err) {
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

    var s3_client: blob.Client = undefined;
    if (adminStorage(&s3_client, arena, io, env)) |code| return code;
    defer s3_client.deinit();
    var standalone: dbx.Standalone = undefined;
    adminPool(&standalone, arena, io, env, "cid admin purge") orelse return .network;
    defer standalone.close();
    var scope = dbx.Run.init(arena);
    defer scope.deinit();

    const by = env.get("USER") orelse "admin";
    const by_tag = std.fmt.allocPrint(arena, "user:{s}", .{by}) catch return .network;
    const result = purge_mod.purge(arena, &standalone.db, &scope, &s3_client, positional.items[0], positional.items[1], reason.?, by_tag) catch |err| switch (err) {
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

/// Opens storage from the environment for an admin command; an exit code
/// (with the message already written) when it cannot.
fn adminStorage(client: *blob.Client, arena: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) ?ExitCode {
    const s3_endpoint = env.get("CID_S3_ENDPOINT") orelse return missingEnv(io, "CID_S3_ENDPOINT", "http://127.0.0.1:8333");
    const s3_access = env.get("CID_S3_ACCESS_KEY") orelse return missingEnv(io, "CID_S3_ACCESS_KEY", "cid");
    const s3_secret = env.get("CID_S3_SECRET_KEY") orelse return missingEnv(io, "CID_S3_SECRET_KEY", "…");
    client.open(arena, .{
        .endpoint = s3_endpoint,
        .access_key = s3_access,
        .secret_key = s3_secret,
        .region = env.get("CID_S3_REGION") orelse "us-east-1",
    }) catch return fail(io, .usage, "CID_S3_ENDPOINT must look like http://host:port.", .{});
    client.start(io) catch {
        client.deinit();
        return fail(io, .network, "cannot reach storage at {s}. Check SeaweedFS, then run the command again.", .{s3_endpoint});
    };
    return null;
}

fn runGc(
    arena: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    env: *const std.process.Environ.Map,
    args: []const [:0]const u8,
) ExitCode {
    var options: gc_mod.Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (eql(args[i], "--apply")) {
            options.apply = true;
        } else if (eql(args[i], "--days")) {
            i += 1;
            const text = if (i < args.len) args[i] else "";
            options.days = std.fmt.parseInt(u32, text, 10) catch
                return fail(io, .usage, "--days needs a whole number of days. Run 'cid admin gc --days 30'.", .{});
        } else {
            return fail(io, .usage, "'{s}' is not an option of gc. Run 'cid admin gc' to see what would go, then 'cid admin gc --apply'.", .{args[i]});
        }
    }

    var s3_client: blob.Client = undefined;
    if (adminStorage(&s3_client, arena, io, env)) |code| return code;
    defer s3_client.deinit();
    var standalone: dbx.Standalone = undefined;
    adminPool(&standalone, arena, io, env, "cid admin gc") orelse return .network;
    defer standalone.close();
    var scope = dbx.Run.init(arena);
    defer scope.deinit();

    const report = gc_mod.run(std.heap.smp_allocator, &standalone.db, &scope, &s3_client, options) catch |err|
        return fail(io, .network, "cleanup could not finish: {t}. Run the same command again; it picks up where it stopped.", .{err});
    const verb = if (options.apply) "Deleted" else "Would delete";
    out.print("{s} {d} unreferenced file{s} ({Bi:.1}) untouched for {d} day{s}, and {d} abandoned upload{s}.\n", .{
        verb,          report.items,          plural(report.items), report.bytes, options.days, plural(options.days),
        report.staged, plural(report.staged),
    }) catch return .network;
    out.writeAll("Kept: everything in a release or a branch head, and anything used within that period.\n") catch return .network;
    if (!options.apply and (report.items > 0 or report.staged > 0))
        out.writeAll("Run 'cid admin gc --apply' to delete them.\n") catch return .network;
    out.flush() catch return .network;
    return .ok;
}

const BackgroundConfig = struct {
    io: std.Io,
    conninfo: [:0]const u8,
    interval_secs: u64,
    gitlab: ?gitlab_sync.Config,
    git: ?git_writer.Config,
    s3: blob.Config,
};

fn backgroundLoop(bg: BackgroundConfig) void {
    while (true) {
        std.Io.sleep(bg.io, .fromNanoseconds(@intCast(bg.interval_secs * std.time.ns_per_s)), .awake) catch return;
        var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        // One pool per tick, so a hiccup never poisons the next tick.
        var standalone: dbx.Standalone = undefined;
        standalone.open(arena, bg.conninfo) catch {
            std.log.warn("background: database unreachable; will retry", .{});
            continue;
        };
        defer standalone.close();
        const db = &standalone.db;
        var scope = dbx.Run.init(arena);
        defer scope.deinit();

        {
            var s3_bg: blob.Client = undefined;
            s3_bg.open(arena, bg.s3) catch {
                std.log.warn("background: bad S3 config for previews", .{});
                continue;
            };
            defer s3_bg.deinit();
            s3_bg.start(bg.io) catch {
                std.log.warn("background: storage unreachable for previews; will retry", .{});
                continue;
            };
            if (preview_worker.processPending(arena, bg.io, db, &scope, &s3_bg, .{})) |outcome| {
                if (outcome.built > 0 or outcome.skipped > 0)
                    std.log.info("background: previews {d} built, {d} skipped", .{ outcome.built, outcome.skipped });
            } else |err| {
                std.log.warn("background: preview pass failed: {t}", .{err});
            }
        }
        if (bg.gitlab) |config| {
            if (gitlab_sync.syncAll(arena, bg.io, db, &scope, config)) |outcome| {
                if (outcome.members > 0 or outcome.keys > 0 or outcome.access_removed > 0)
                    std.log.info("background: gitlab sync {d} members, {d} keys", .{ outcome.members, outcome.keys });
            } else |err| {
                std.log.warn("background: gitlab sync failed: {t}", .{err});
            }
        }
        if (bg.git) |config| {
            const names = db.raw([]const u8, &scope, "SELECT DISTINCT d.name FROM git_writes w JOIN datasets d USING (dataset_id) WHERE w.status <> 'done'", .{}) catch continue;
            for (names) |name| {
                _ = git_writer.processDataset(arena, bg.io, db, &scope, config, name) catch |err| {
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
    const s3_region = env.get("CID_S3_REGION") orelse "us-east-1";
    var standalone: dbx.Standalone = undefined;
    adminPool(&standalone, arena, io, env, "cid admin previews") orelse return .network;
    defer standalone.close();
    var scope = dbx.Run.init(arena);
    defer scope.deinit();
    var s3_client: blob.Client = undefined;
    s3_client.open(arena, .{
        .endpoint = s3_endpoint,
        .access_key = s3_access,
        .secret_key = s3_secret,
        .region = s3_region,
    }) catch return fail(io, .usage, "CID_S3_ENDPOINT must look like http://host:port.", .{});
    defer s3_client.deinit();
    s3_client.start(io) catch
        return fail(io, .network, "cannot reach storage at {s}. Check SeaweedFS, then run the command again.", .{s3_endpoint});

    const outcome = preview_worker.processPending(arena, io, &standalone.db, &scope, &s3_client, .{}) catch |err|
        return fail(io, .network, "the preview pass could not run: {t}. Fix the cause, then run 'cid admin previews' again.", .{err});
    out.print("Previews: {d} built, {d} skipped, {d} will retry.\n", .{
        outcome.built, outcome.skipped, outcome.failed,
    }) catch return .network;
    out.flush() catch return .network;
    return .ok;
}

fn missingEnv(io: std.Io, name: []const u8, example: []const u8) ExitCode {
    return fail(io, .usage, "{s} is not set. Export it (e.g. {s}={s}), then run the command again.", .{ name, name, example });
}

/// Every error ends with the command to run next (already in the formats above).
/// nilo's statement watcher is a plain function pointer (its ADR 108), so
/// the database's words about a failure land in this file-scope buffer.
/// Admin commands are one-shot and single-threaded; this is the one
/// sanctioned exception to "no globals", and it never leaves this file.
var db_problem_buf: [512]u8 = undefined;
var db_problem_len: usize = 0;

fn stashDbProblem(sent: dbx.sql.Sent) void {
    const p = sent.problem orelse return;
    const n = @min(p.message.len, db_problem_buf.len);
    @memcpy(db_problem_buf[0..n], p.message[0..n]);
    db_problem_len = n;
}

fn lastDbProblem() []const u8 {
    return if (db_problem_len == 0) "no details from the database" else db_problem_buf[0..db_problem_len];
}

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
