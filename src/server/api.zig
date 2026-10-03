//! The cid server API, v0: pure request handlers, HTTP-free so the
//! integration tests exercise them directly. serve.zig maps HTTP onto
//! `handle`. All responses are JSON (the same shapes `--json` prints).
//!
//! Routes (dataset names contain '/', so actions sit behind '/-/'):
//!   GET  /v0/ping
//!   POST /v0/datasets                         {name, kind, git_url}
//!   GET  /v0/datasets/<name>/-/head?branch=main
//!   GET  /v0/datasets/<name>/-/log?branch=main
//!   POST /v0/datasets/<name>/-/check-hashes   {hashes:[hex]}
//!   POST /v0/datasets/<name>/-/push           {branch, commits:[…]}
//!   GET  /v0/datasets/<name>/-/version/<commit>   presigned version file
//!   GET  /v0/datasets/<name>/-/compare/<a>/<b>    presigned diff file
//!   GET  /v0/datasets/<name>/-/browse[/size|/dir|/compare]?commit=…
//!   POST /v0/datasets/<name>/-/downloads      {hashes:[hex]}
//!
//! v0 auth is one bearer token for everything; the SSH front door and
//! per-dataset scoping replace it (docs/access.md). Not for production.
//!
//! Database access is nilo_sql: a pooled Db shared across nilo's threads,
//! each query under the caller's Scope (the request's Ctx in serve.zig, a
//! Run in tests and admin commands).

const std = @import("std");
const dbx = @import("../store/db.zig");
const blob = @import("../store/blob.zig");
const release_mod = @import("../core/release.zig");
const git_writer = @import("../gitrepo/writer.zig");
const protection = @import("../gitrepo/protection.zig");
const gitlab_sync = @import("../access/gitlab_sync.zig");
const keys_mod = @import("../access/keys.zig");
const preview_worker = @import("../preview/worker.zig");
const duck = @import("../store/duck.zig");
const table_stats = @import("../tabular/stats.zig");
const rowdiff_mod = @import("../tabular/rowdiff.zig");
const browse_mod = @import("browse/browse.zig");
const bundle_mod = @import("../export/bundle.zig");
const versions = @import("../core/version.zig");
const nilo = @import("nilo_http");
const token_mod = @import("../access/token.zig");
const Uuid = @import("../util/uuid7.zig").Uuid;
const content_hash = @import("../util/hash.zig");

pub const Deps = struct {
    db: *dbx.sql.Db,
    s3: *blob.Client,
    io: std.Io,
    /// The static full-access token (CI fallback; empty disables it).
    token: []const u8,
    /// Verifies SSH-issued scoped tokens when set (CID_TOKEN_SECRET).
    token_secret: ?[]const u8 = null,
    /// When set, releases are written to the dataset repository right
    /// after tagging; otherwise git_writes rows wait for
    /// 'cid admin git <dataset> --resync'.
    git: ?git_writer.Config = null,
    /// Whether "Sign in with GitLab" is configured (the sign-in page asks).
    gitlab_signin: bool = false,
    /// The GitLab the server syncs members from (CID_GITLAB_URL and
    /// CID_GITLAB_TOKEN): also asked, at creation, whether a dataset
    /// repository on it protects main.
    gitlab: ?gitlab_sync.Config = null,
    /// The server's one DuckDB database for browse queries,
    /// confined to browse_dir, opened by `cid admin serve`: every query
    /// takes a connection, so one memory ceiling covers them all at once.
    /// Index builds and row diffs, one at a time each, use a one-thread
    /// database of their own. Null in tests and admin commands.
    duck: ?*duck.Db = null,
    /// Files in flight: a release's manifest on its way to storage, the two
    /// tables a row diff compares (DuckDB is confined to it then).
    work_dir: []const u8 = "/tmp/cid-work",
    /// Files larger than this go up in pieces of this size, each its own
    /// presigned PUT, so no file is too large and a push that stops picks
    /// up at the first missing piece (tests lower it).
    piece_bytes: u64 = 64 * 1024 * 1024,
    /// One row diff at a time, server-wide: DuckDB work never scales with
    /// requests (each answer is cached, so this is rarely contended).
    rowdiff_busy: std.atomic.Value(bool) = .init(false),
    /// The server's browse indexes, two Parquet files per version
    /// (named by commit id), kept here and in storage for releases.
    browse_dir: []const u8 = "/tmp/cid-browse",
    /// How many indexes the folder keeps; the least recently built go.
    browse_cache_max: u32 = 32,
    /// One index build at a time, server-wide.
    browse_building: std.atomic.Value(bool) = .init(false),
    /// Which commit holds the slot (the random half of its id; 0 for
    /// none), so a request for the very version being built waits for it.
    browse_building_commit: std.atomic.Value(u64) = .init(0),
    /// For memory that outlives no single step but must not grow with a
    /// dataset: each batch of a streamed index build.
    gpa: std.mem.Allocator,
    /// Set by `cid admin serve`: DuckDB work goes to nilo's thread pool
    /// (nilo ADR 013) so the fiber's thread keeps serving meanwhile. Tests
    /// and admin commands, which have no engine, run it in place.
    offload: bool = false,
};

/// A DuckDB connection for one browse query: to the server's shared
/// database when there is one, else to a database of its own.
fn duckFor(arena: std.mem.Allocator, deps: *Deps, dir: []const u8) HandleError!duck.Db {
    if (deps.duck) |shared| return shared.connect() catch error.Storage;
    return duck.Db.open(arena, .{ .allowed_dir = dir, .threads = browse_mod.query_threads }) catch error.Storage;
}

/// Runs `func` on the server's blocking pool when serving, in place
/// otherwise.
fn offload(deps: *const Deps, comptime func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) @typeInfo(@TypeOf(func)).@"fn".return_type.? {
    if (deps.offload) return nilo.blocking(func, args);
    return @call(.auto, func, args);
}

pub const Response = struct {
    status: std.http.Status,
    /// JSON, arena-owned.
    body: []const u8,
};

const presign_secs = 15 * 60;

pub fn handle(
    arena: std.mem.Allocator,
    deps: *Deps,
    scope: anytype,
    method: []const u8,
    target: []const u8,
    auth_header: ?[]const u8,
    body: []const u8,
) Response {
    return handleAs(arena, deps, scope, method, target, .{ .header = auth_header }, body);
}

/// Who is asking: a bearer token (static, or SSH-issued and scoped), or a
/// dashboard session's account (`gitlab:<id>`). A session carries identity
/// only; what it may read or write comes from the `access` table on every
/// request, the same table an SSH token is minted from.
pub const Caller = struct {
    header: ?[]const u8 = null,
    account: ?[]const u8 = null,
    /// The account came from a personal token, not a dashboard session:
    /// it may do what the person may, except manage their tokens.
    personal: bool = false,
};

pub fn handleAs(
    arena: std.mem.Allocator,
    deps: *Deps,
    scope: anytype,
    method: []const u8,
    target: []const u8,
    caller: Caller,
    body: []const u8,
) Response {
    return handleInner(arena, deps, scope, method, target, caller, body) catch |err| switch (err) {
        error.OutOfMemory => errorResponse(arena, .internal_server_error, "out of memory", "Try again."),
        error.Db => errorResponse(arena, .internal_server_error, "database error", "Check the server logs, then try again."),
        error.Storage => errorResponse(arena, .internal_server_error, "storage error", "Check the server logs, then try again."),
        error.BadRequest => errorResponse(arena, .bad_request, "the request body is not what this route expects", "Update cid and try again."),
        error.Collected => errorResponse(arena, .unprocessable_entity, "a file was cleaned up from storage while this ran", "Run the same command again; it uploads the file again."),
    };
}

/// `Collected`: cleanup (`cid admin gc`) took a file this request was
/// recording; nothing was recorded, and a retry uploads it again.
const HandleError = error{ OutOfMemory, Db, Storage, BadRequest, Collected };

fn handleInner(
    arena: std.mem.Allocator,
    deps: *Deps,
    scope: anytype,
    method: []const u8,
    target: []const u8,
    given: Caller,
    body: []const u8,
) HandleError!Response {
    // A personal token (Bearer, or the password of git-style Basic
    // credentials) becomes its maker's account here, before anything else
    // looks: from then on it is that person, as a session would be.
    const caller = switch (try resolveCaller(arena, deps, scope, given)) {
        .caller => |c| c,
        .refused => |r| return r,
    };
    const auth_header = caller.header;
    if (eql(method, "GET") and eql(target, "/v0/ping"))
        return json(arena, .ok, .{ .ok = true });
    // Public: the sign-in page asks which ways in this server offers.
    if (eql(method, "GET") and eql(target, "/v0/auth/config"))
        return json(arena, .ok, .{ .gitlab = deps.gitlab_signin });
    if (eql(method, "GET") and eql(target, "/v0/me")) return me(arena, deps, scope, caller);
    if (std.mem.startsWith(u8, target, "/v0/me/keys")) return myKeys(arena, deps, scope, caller, method, target, body);
    if (std.mem.startsWith(u8, target, "/v0/me/tokens")) return myTokens(arena, deps, scope, caller, method, target, body);

    if (eql(method, "POST") and eql(target, "/v0/datasets")) {
        if (caller.personal)
            return errorResponse(arena, .forbidden, "a personal token cannot create a dataset", "Run 'cid init' with your SSH key (a GitLab Maintainer of the project at that path may), or ask the administrator.");
        // The dataset's name is in the body; createDataset checks scope.
        return createDataset(arena, deps, scope, auth_header, body);
    }
    if (eql(method, "GET") and eql(target, "/v0/datasets")) {
        // Listing crosses datasets, so a per-dataset token cannot do it:
        // the static token only, until OAuth brings account-level views.
        if (tokenOk(deps.token, auth_header)) return listDatasets(arena, deps, scope, null);
        if (caller.account) |account| return listDatasets(arena, deps, scope, account);
        return errorResponse(arena, .unauthorized, "listing needs you signed in", "Run the sign-in again: 'Sign in with GitLab' on the dashboard, or the server token.");
    }

    const route = parseDatasetRoute(target) orelse
        return errorResponse(arena, .not_found, "no such route", "Update cid and try again.");

    // Owners' actions need a maintain-scoped token (Maintainer), writes a
    // write one (Developer), reads a read one (Reporter).
    const needed: token_mod.Level = if (eql(route.action, "tag") or
        eql(route.action, "branch") or eql(route.action, "merge") or
        (eql(method, "PUT") and eql(route.action, "card")))
        .maintain
    else if (eql(route.action, "push") or eql(route.action, "check-hashes") or
        eql(route.action, "commit") or eql(route.action, "register-items") or
        eql(route.action, "policy"))
        .write
    else
        .read;
    if (!authorized(arena, deps, scope, caller, route.name, needed)) {
        if (needed == .maintain and authorized(arena, deps, scope, caller, route.name, .write))
            return errorResponse(arena, .forbidden, "only the dataset's owners (Maintainers of its project) tag, branch, merge and edit the card", "Ask a Maintainer of the dataset's project to do it, or for the Maintainer role.");
        return errorResponse(arena, .unauthorized, "missing, wrong or expired token for this dataset", "Run the command again; cid fetches a fresh token over SSH. CI: check CID_TOKEN.");
    }

    const ds = lookupDataset(arena, deps, scope, route.name) orelse
        return errorResponse(arena, .not_found, "no such dataset", "Run 'cid init' to create it, or check the address.");

    if (eql(method, "GET") and eql(route.action, "text"))
        return textHead(arena, deps, scope, ds, route.queryParam("hash") orelse "");
    if (eql(method, "GET") and eql(route.action, "table"))
        return tableStats(arena, deps, scope, ds, route.queryParam("hash") orelse "");
    if (eql(method, "GET") and eql(route.action, "browse"))
        return browse(arena, deps, scope, ds, route);
    if (eql(method, "GET") and eql(route.action, "browse/size"))
        return browseSize(arena, deps, scope, ds, route);
    if (eql(method, "GET") and eql(route.action, "browse/dir"))
        return browseDir(arena, deps, scope, ds, route);
    if (eql(method, "GET") and eql(route.action, "browse/compare"))
        return browseCompare(arena, deps, scope, ds, route);
    if (eql(method, "POST") and eql(route.action, "rowdiff"))
        return rowDiff(arena, deps, scope, ds, body);
    if (eql(method, "GET") and eql(route.action, "history"))
        return history(arena, deps, scope, ds, route.queryParam("path") orelse "");
    if (eql(method, "POST") and eql(route.action, "reveal"))
        return reveal(arena, deps, scope, caller, ds, body);
    if (eql(method, "GET") and eql(route.action, "activity"))
        return activity(arena, deps, scope, caller, ds);
    if (eql(route.action, "star") and (eql(method, "PUT") or eql(method, "DELETE")))
        return star(arena, deps, scope, caller, ds, eql(method, "PUT"));
    if (eql(method, "GET") and eql(route.action, "info"))
        return datasetInfo(arena, deps, scope, ds);
    if (eql(method, "GET") and eql(route.action, "overview"))
        return overview(arena, deps, scope, ds);
    if (eql(method, "GET") and eql(route.action, "head"))
        return head(arena, deps, scope, ds, route.queryParam("branch") orelse "main");
    if (eql(method, "GET") and eql(route.action, "log"))
        return log(arena, deps, scope, ds, route.queryParam("branch") orelse "main");
    if (eql(method, "POST") and eql(route.action, "check-hashes"))
        return checkHashes(arena, deps, scope, ds, body);
    if (eql(method, "POST") and eql(route.action, "push"))
        return push(arena, deps, scope, caller, ds, body);
    if (eql(method, "GET") and std.mem.startsWith(u8, route.action, "compare/"))
        return compare(arena, deps, scope, ds, route.action["compare/".len..]);
    if (eql(method, "GET") and std.mem.startsWith(u8, route.action, "version/"))
        return versionFile(arena, deps, scope, ds, route.action["version/".len..], route);
    if (eql(method, "POST") and eql(route.action, "downloads"))
        return downloads(arena, deps, scope, caller, ds, body);
    if (eql(method, "POST") and eql(route.action, "thumbs"))
        return thumbs(arena, deps, scope, ds, body);
    if (eql(method, "POST") and eql(route.action, "tag"))
        return tag(arena, deps, scope, caller, ds, body);
    if (eql(method, "GET") and eql(route.action, "releases"))
        return releases(arena, deps, scope, ds);
    if (eql(method, "POST") and eql(route.action, "branch"))
        return branchCreate(arena, deps, scope, caller, ds, body);
    if (eql(method, "GET") and eql(route.action, "branches"))
        return branches(arena, deps, scope, ds);
    if (eql(method, "POST") and eql(route.action, "merge"))
        return merge(arena, deps, scope, caller, ds, body);
    if (eql(method, "POST") and eql(route.action, "commit"))
        return serverCommit(arena, deps, scope, caller, ds, body);
    if (eql(method, "POST") and eql(route.action, "register-items"))
        return registerItems(arena, deps, scope, ds, body);
    if (eql(method, "POST") and eql(route.action, "policy"))
        return policyCreate(arena, deps, scope, ds, body);
    if (eql(method, "GET") and eql(route.action, "policies"))
        return policies(arena, deps, scope, ds);
    if (eql(method, "GET") and eql(route.action, "card"))
        return cardGet(arena, deps, scope, ds);
    if (eql(method, "PUT") and eql(route.action, "card"))
        return cardPut(arena, deps, scope, caller, ds, body);

    return errorResponse(arena, .not_found, "no such route", "Update cid and try again.");
}

// ---------------------------------------------------------------------------
// Routing helpers
// ---------------------------------------------------------------------------

const DatasetRoute = struct {
    name: []const u8,
    action: []const u8, // "push", "version/<id>", …
    query: []const u8, // raw query string, no '?'

    fn queryParam(self: *const DatasetRoute, key: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, self.query, '&');
        while (it.next()) |pair| {
            const q = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            if (std.mem.eql(u8, pair[0..q], key)) return pair[q + 1 ..];
        }
        return null;
    }
};

fn parseDatasetRoute(target: []const u8) ?DatasetRoute {
    const prefix = "/v0/datasets/";
    if (!std.mem.startsWith(u8, target, prefix)) return null;
    const rest = target[prefix.len..];
    const sep = std.mem.indexOf(u8, rest, "/-/") orelse return null;
    const after = rest[sep + 3 ..];
    const q = std.mem.indexOfScalar(u8, after, '?') orelse after.len;
    return .{
        .name = rest[0..sep],
        .action = after[0..q],
        .query = if (q < after.len) after[q + 1 ..] else "",
    };
}

fn tokenOk(expected: []const u8, auth_header: ?[]const u8) bool {
    if (expected.len == 0) return false;
    const h = auth_header orelse return false;
    if (!std.mem.startsWith(u8, h, "Bearer ")) return false;
    const got = h["Bearer ".len..];
    if (got.len != expected.len) return false;
    var diff: u8 = 0;
    for (got, expected) |a, b| diff |= a ^ b;
    return diff == 0;
}

/// The account a scoped token was minted for, if the header holds a valid
/// one (never for the static token, which names nobody).
fn tokenAccount(arena: std.mem.Allocator, deps: *Deps, auth_header: ?[]const u8) ?[]const u8 {
    const secret = deps.token_secret orelse return null;
    const h = auth_header orelse return null;
    if (!std.mem.startsWith(u8, h, "Bearer ") or tokenOk(deps.token, h)) return null;
    const now: u64 = @intCast(@max(0, std.Io.Timestamp.now(deps.io, .real).toSeconds()));
    const claims = token_mod.verify(arena, secret, h["Bearer ".len..], now) catch return null;
    return claims.account;
}

/// Static token: everything. Scoped token: this dataset, this level or
/// higher, not expired.
fn authorized(
    arena: std.mem.Allocator,
    deps: *Deps,
    scope: anytype,
    caller: Caller,
    dataset: []const u8,
    needed: token_mod.Level,
) bool {
    const auth_header = caller.header;
    if (tokenOk(deps.token, auth_header)) return true;
    if (caller.account) |account| {
        const level = deps.db.rawOne([]const u8, scope, "SELECT a.level FROM access a JOIN datasets d USING (dataset_id) WHERE d.name = $1 AND a.account_id = $2", .{ dataset, account }) catch return false;
        const have = level orelse return false;
        const as = std.meta.stringToEnum(token_mod.Level, have) orelse return false;
        return as.covers(needed);
    }
    const secret = deps.token_secret orelse return false;
    const h = auth_header orelse return false;
    if (!std.mem.startsWith(u8, h, "Bearer ")) return false;
    const now: u64 = @intCast(@max(0, std.Io.Timestamp.now(deps.io, .real).toSeconds()));
    const claims = token_mod.verify(arena, secret, h["Bearer ".len..], now) catch return false;
    return std.mem.eql(u8, claims.dataset, dataset) and claims.level.covers(needed);
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

const Dataset = struct {
    id: []const u8, // uuid text
    name: []const u8,
    kind: []const u8, // 'files' | 'annotated'
    /// Previews blurred until a logged reveal; every clear URL logged.
    restricted: bool = false,
};

const DatasetRow = struct {
    pub const nilo_table = .projection;
    dataset_id: []const u8,
    kind: []const u8,
    restricted: bool,
};

// ---------------------------------------------------------------------------
// Preparing versions ahead of their first visitor
// ---------------------------------------------------------------------------

/// Queues a new branch head or release for the background worker. Best
/// effort: a version nobody prepared is prepared by its first visit.
fn queueVersion(deps: *Deps, scope: anytype, ds: Dataset, commit_id: []const u8) void {
    _ = deps.db.exec(scope, "INSERT INTO version_jobs (commit_id, dataset_id) VALUES ($1::uuid, $2::uuid) ON CONFLICT DO NOTHING", .{ commit_id, ds.id }) catch {};
}

/// Prepares the next queued version: its statistics, its browse index,
/// its items file, for a release its diff with the release before, and
/// for an annotated dataset its default export —
/// the work its first visit would otherwise wait for (8–30 s at 1M
/// items). The same code paths a request takes, so a version is never
/// prepared two ways. A commit that is no longer a branch head or a
/// release by its turn is skipped. Answers whether there was a job.
pub fn prepareNext(arena: std.mem.Allocator, deps: *Deps, scope: anytype) HandleError!bool {
    const Job = struct {
        pub const nilo_table = .projection;
        commit_id: []const u8,
        dataset_id: []const u8,
    };
    const job = (deps.db.rawOne(Job, scope, "UPDATE version_jobs SET status = 'building', updated_at = now() WHERE commit_id = (" ++
        "  SELECT commit_id FROM version_jobs WHERE status = 'pending' OR (status = 'building' AND updated_at < now() - interval '10 minutes') " ++
        "  ORDER BY queued_at LIMIT 1 FOR UPDATE SKIP LOCKED) " ++
        "RETURNING commit_id::text AS commit_id, dataset_id::text AS dataset_id", .{}) catch return error.Db) orelse return false;
    const Row = struct {
        pub const nilo_table = .projection;
        name: []const u8,
        kind: []const u8,
        restricted: bool,
        default_format: []const u8,
    };
    const row = (deps.db.rawOne(Row, scope, "SELECT name, kind, restricted, default_format FROM datasets WHERE dataset_id = $1::uuid", .{job.dataset_id}) catch return error.Db) orelse return error.Db;
    const ds: Dataset = .{ .id = job.dataset_id, .name = row.name, .kind = row.kind, .restricted = row.restricted };

    const live = deps.db.rawOne(i64, scope, "SELECT 1::bigint FROM refs WHERE dataset_id = $1::uuid AND commit_id = $2::uuid LIMIT 1", .{ ds.id, job.commit_id }) catch return error.Db;
    if (live == null) {
        finishJob(deps, scope, job.commit_id, "skipped", "no longer a branch head or a release");
        return true;
    }
    prepare(arena, deps, scope, ds, job.commit_id, row.default_format) catch |err| {
        finishJob(deps, scope, job.commit_id, "failed", @errorName(err));
        return true;
    };
    finishJob(deps, scope, job.commit_id, "done", null);
    return true;
}

fn prepare(arena: std.mem.Allocator, deps: *Deps, scope: anytype, ds: Dataset, commit_id: []const u8, default_format: []const u8) HandleError!void {
    _ = versions.stats(arena, deps.db, scope, ds.id, commit_id) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Db,
    };
    // The browse index; another build holding the slot means it is busy
    // with some version's index, and this one is built by its first view.
    _ = try browseIndex(arena, deps, scope, ds, commit_id);
    _ = try ensureVersionFile(arena, deps, scope, ds, commit_id, .state, .{});
    // A release: its diff with the release before it, which Compare opens
    // on by default.
    const previous = deps.db.rawOne([]const u8, scope, "SELECT p.commit_id::text FROM refs r JOIN refs p ON p.dataset_id = r.dataset_id " ++
        "AND p.kind = 'release' AND p.commit_id < r.commit_id WHERE r.dataset_id = $1::uuid AND r.commit_id = $2::uuid AND r.kind = 'release' " ++
        "ORDER BY p.commit_id DESC LIMIT 1", .{ ds.id, commit_id }) catch return error.Db;
    if (previous) |prev| {
        if (try browseIndex(arena, deps, scope, ds, prev)) |ia| if (try browseIndex(arena, deps, scope, ds, commit_id)) |ib| {
            _ = try diffIndex(arena, deps, scope, ds, prev, commit_id, ia, ib);
        };
    }
    if (eql(ds.kind, "annotated")) {
        if (std.meta.stringToEnum(bundle_mod.Kind, default_format)) |kind| if (kind != .state) {
            // An impossible export is an answer too; the clone says why.
            _ = try ensureVersionFile(arena, deps, scope, ds, commit_id, kind, .{});
        };
    }
}

fn finishJob(deps: *Deps, scope: anytype, commit_id: []const u8, status: []const u8, reason: ?[]const u8) void {
    _ = deps.db.exec(scope, "UPDATE version_jobs SET status = $2, reason = $3, updated_at = now() WHERE commit_id = $1::uuid", .{ commit_id, status, reason }) catch {};
}

fn lookupDataset(arena: std.mem.Allocator, deps: *Deps, scope: anytype, name: []const u8) ?Dataset {
    _ = arena;
    const row = (deps.db.rawOne(DatasetRow, scope, "SELECT dataset_id::text AS dataset_id, kind, restricted FROM datasets WHERE name = $1", .{name}) catch return null) orelse return null;
    return .{ .id = row.dataset_id, .name = name, .kind = row.kind, .restricted = row.restricted };
}

fn listDatasets(arena: std.mem.Allocator, deps: *Deps, scope: anytype, account: ?[]const u8) HandleError!Response {
    const Row = struct {
        pub const nilo_table = .projection;
        dataset_id: []const u8,
        name: []const u8,
        kind: []const u8,
        restricted: bool,
        default_format: []const u8,
        starred: bool,
        owners: ?[]const u8,
        latest_release: ?[]const u8,
        last_push: ?[]const u8,
        head: ?[]const u8,
        stats: ?[]const u8,
    };
    const rows = deps.db.raw(Row, scope, "SELECT d.dataset_id::text AS dataset_id, d.name, d.kind, d.restricted, d.default_format, " ++
        "  EXISTS (SELECT 1 FROM stars s WHERE s.dataset_id = d.dataset_id AND s.account_id = $1) AS starred, " ++
        // Owners are Maintainers (CLAUDE.md, words), by display name.
        "  (SELECT string_agg(ac.display_name, '\n' ORDER BY ac.display_name) FROM access o " ++
        "   JOIN accounts ac ON ac.account_id = o.account_id " ++
        "   WHERE o.dataset_id = d.dataset_id AND o.level = 'maintain') AS owners, " ++
        "  (SELECT r.name FROM refs r WHERE r.dataset_id = d.dataset_id AND r.kind = 'release' " ++
        "   ORDER BY r.commit_id DESC LIMIT 1) AS latest_release, " ++
        "  (SELECT to_char(max(c.recorded_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') " ++
        "   FROM commits c WHERE c.dataset_id = d.dataset_id) AS last_push, " ++
        "  h.commit_id::text AS head, c.stats::text AS stats " ++
        "FROM datasets d " ++
        "LEFT JOIN refs h ON h.dataset_id = d.dataset_id AND h.name = 'main' AND h.kind = 'branch' " ++
        "LEFT JOIN commits c ON c.commit_id = h.commit_id " ++
        // A signed-in person sees the datasets they may read; the static
        // token (NULL here) sees every one.
        "WHERE $1::text IS NULL OR EXISTS (SELECT 1 FROM access a WHERE a.dataset_id = d.dataset_id AND a.account_id = $1) " ++
        "ORDER BY d.name", .{account}) catch return error.Db;

    const Thumb = struct { hash: []const u8, url: []const u8 };
    const Type = struct { ext: []const u8, count: u64 };
    const Entry = struct {
        name: []const u8,
        kind: []const u8,
        restricted: bool,
        default_format: []const u8,
        latest_release: ?[]const u8,
        last_push: ?[]const u8,
        items: u64,
        bytes: u64,
        types: []const Type,
        classes: []const []const u8,
        mosaic: []const Thumb,
        starred: bool,
        owners: []const []const u8,
    };
    const list = try arena.alloc(Entry, rows.len);
    for (list, rows) |*e, row| {
        // The head's statistics, as the listing query already read them;
        // aggregated (and kept) only the first time anyone asks.
        const st: versions.Stats = if (row.head) |head_commit|
            versions.kept(arena, row.stats) orelse versions.stats(arena, deps.db, scope, row.dataset_id, head_commit) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.Db,
            }
        else
            .{};
        const types = try arena.alloc(Type, @min(st.types.len, 8));
        for (types, st.types[0..types.len]) |*t, c| t.* = .{ .ext = c.name, .count = c.count };
        const class_names = try arena.alloc([]const u8, @min(st.classes.len, 50));
        for (class_names, st.classes[0..class_names.len]) |*n, c| n.* = c.name;
        // Only previews that already exist are handed out (the structural
        // ffmpeg guarantee); a restricted dataset's card shows the blurred
        // renditions, and none where a blur does not exist yet — never a
        // clear thumbnail (invariant 20).
        var mosaic: std.ArrayList(Thumb) = .empty;
        {
            for (st.visual) |hash| {
                const done = deps.db.rawOne(i64, scope, "SELECT 1::bigint FROM previews WHERE item_hash = decode($1, 'hex') AND status = 'done' AND (blurred OR NOT $2)", .{ hash, row.restricted }) catch return error.Db;
                if (done == null) continue;
                const key = (if (row.restricted) preview_worker.blurKey(arena, hash) else preview_worker.thumbKey(arena, hash)) catch return error.OutOfMemory;
                const url = deps.s3.presignGet(scope, key, presign_secs) catch return error.Storage;
                try mosaic.append(arena, .{ .hash = hash, .url = url });
            }
        }
        e.* = .{
            .name = row.name,
            .kind = row.kind,
            .restricted = row.restricted,
            .default_format = row.default_format,
            .latest_release = row.latest_release,
            .last_push = row.last_push,
            .items = st.items,
            .bytes = st.bytes,
            .types = types,
            .classes = if (row.restricted) &.{} else class_names,
            .mosaic = mosaic.items,
            .starred = row.starred,
            .owners = try splitLines(arena, row.owners orelse ""),
        };
    }
    return json(arena, .ok, .{ .datasets = list });
}

/// One item's history (docs/dashboard.md §4.3, the drawer): every change
/// to its path and every change to its annotations, newest first, each
/// with the commit that sealed it and that commit's release — or none,
/// when the platform wrote it and nobody has committed since. The client
/// pairs consecutive versions into before/after.
fn history(arena: std.mem.Allocator, deps: *Deps, scope: anytype, ds: Dataset, raw_path: []const u8) HandleError!Response {
    // The client sends encodeURIComponent's spelling: %XX, and `+` stays
    // a plus (a path may hold one), so std's decoder, not a form's.
    const path = std.Uri.percentDecodeInPlace(try arena.dupe(u8, raw_path));
    if (path.len == 0) return error.BadRequest;

    // The commit a revision landed in: the first one on its branch whose
    // cutoff reaches it (cutoffs only move forward, invariant 3).
    const sealed_by =
        "(SELECT c.commit_id FROM commits c WHERE c.dataset_id = r.dataset_id AND c.branch = r.branch " ++
        " AND c.cutoff_rev >= r.rev_id ORDER BY c.cutoff_rev LIMIT 1)";
    const Change = struct {
        pub const nilo_table = .projection;
        at: []const u8,
        branch: []const u8,
        op: []const u8,
        hash: ?[]const u8,
        author: []const u8,
        commit: ?[]const u8,
        message: ?[]const u8,
        release: ?[]const u8,
    };
    const changes = deps.db.raw(Change, scope, "SELECT to_char(r.ts AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"') AS at, " ++
        "r.branch, r.op, encode(r.item_hash, 'hex') AS hash, r.author, sc.commit_id::text AS commit, sc.message, " ++
        "(SELECT f.name FROM refs f WHERE f.commit_id = sc.commit_id AND f.kind = 'release' ORDER BY f.name LIMIT 1) AS release " ++
        "FROM item_revisions r LEFT JOIN commits sc ON sc.commit_id = " ++ sealed_by ++ " " ++
        "WHERE r.dataset_id = $1::uuid AND r.path = $2 ORDER BY r.rev_id DESC LIMIT 200", .{ ds.id, path }) catch return error.Db;

    const AnnChange = struct {
        pub const nilo_table = .projection;
        at: []const u8,
        branch: []const u8,
        annotation_id: []const u8,
        op: []const u8,
        kind: ?[]const u8,
        class: ?[]const u8,
        geometry: ?[]const u8,
        author: []const u8,
        policy_ver: []const u8,
        commit: ?[]const u8,
        release: ?[]const u8,
    };
    // Annotations attach to item identity (invariant 4): every item_id
    // this path has held.
    const ann_changes = deps.db.raw(AnnChange, scope, "SELECT to_char(r.ts AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"') AS at, " ++
        "r.branch, r.annotation_id::text AS annotation_id, r.op, r.kind, r.class, r.geometry::text AS geometry, r.author, r.policy_ver, " ++
        "sc.commit_id::text AS commit, " ++
        "(SELECT f.name FROM refs f WHERE f.commit_id = sc.commit_id AND f.kind = 'release' ORDER BY f.name LIMIT 1) AS release " ++
        "FROM annotation_revisions r LEFT JOIN commits sc ON sc.commit_id = " ++ sealed_by ++ " " ++
        "WHERE r.dataset_id = $1::uuid AND r.item_id IN (SELECT DISTINCT item_id FROM item_revisions " ++
        "  WHERE dataset_id = $1::uuid AND path = $2 AND item_id IS NOT NULL) " ++
        "ORDER BY r.rev_id DESC LIMIT 200", .{ ds.id, path }) catch return error.Db;

    const WireAnn = struct {
        at: []const u8,
        branch: []const u8,
        annotation_id: []const u8,
        op: []const u8,
        kind: ?[]const u8,
        class: ?[]const u8,
        geometry: ?std.json.Value,
        author: []const u8,
        policy_ver: []const u8,
        commit: ?[]const u8,
        release: ?[]const u8,
    };
    const wire = try arena.alloc(WireAnn, ann_changes.len);
    for (wire, ann_changes) |*w, a| w.* = .{
        .at = a.at,
        .branch = a.branch,
        .annotation_id = a.annotation_id,
        .op = a.op,
        .kind = a.kind,
        .class = a.class,
        .geometry = jsonValue(arena, a.geometry),
        .author = a.author,
        .policy_ver = a.policy_ver,
        .commit = a.commit,
        .release = a.release,
    };
    return json(arena, .ok, .{ .path = path, .changes = changes, .annotations = wire });
}

/// A table item's statistics (docs/dashboard.md, Phase 2), built once by
/// the preview worker; never computed here. When there are none, the
/// answer says why in words, so the drawer never shows a blank.
/// A restricted dataset is answered with its shape only — rows, column
/// names, types and nulls — because ranges and sample rows are content;
/// those come with a logged reveal (invariant 20).
fn tableStats(arena: std.mem.Allocator, deps: *Deps, scope: anytype, ds: Dataset, hash: []const u8) HandleError!Response {
    if (!validHashHex(hash)) return error.BadRequest;
    const here = deps.db.rawOne(i64, scope, "SELECT 1::bigint FROM dataset_hashes WHERE dataset_id = $1::uuid AND item_hash = decode($2, 'hex')", .{ ds.id, hash }) catch return error.Db;
    if (here == null) return errorResponse(arena, .not_found, "no such item in this dataset", "Pick the item from this dataset's Browse view.");

    const Row = struct {
        pub const nilo_table = .projection;
        status: []const u8,
        reason: ?[]const u8,
        stats: ?[]const u8,
    };
    const row = deps.db.rawOne(Row, scope, "SELECT status, reason, table_stats::text AS stats FROM previews WHERE item_hash = decode($1, 'hex')", .{hash}) catch return error.Db;
    const r = row orelse return json(arena, .ok, .{ .status = "pending", .reason = @as(?[]const u8, null) });
    const text = r.stats orelse return json(arena, .ok, .{ .status = r.status, .reason = r.reason });
    const stats = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch
        return json(arena, .ok, .{ .status = "skipped", .reason = @as(?[]const u8, "the stored statistics could not be read") });
    if (!ds.restricted) return json(arena, .ok, .{ .status = "done", .stats = stats, .withheld = false });
    return json(arena, .ok, .{ .status = "done", .stats = try shapeOnly(arena, stats), .withheld = true });
}

/// A version's browse index, ready to query, or the answer that says why
/// not: a bad or foreign commit, or another build holding the slot.
const Indexed = union(enum) { ready: BrowseIndex, refused: Response };

fn indexFor(arena: std.mem.Allocator, deps: *Deps, scope: anytype, ds: Dataset, commit: ?[]const u8) HandleError!Indexed {
    const c = commit orelse
        return .{ .refused = errorResponse(arena, .bad_request, "this needs a version", "Pick a version from the version picker.") };
    if (Uuid.parse(c) == error.InvalidUuid)
        return .{ .refused = errorResponse(arena, .bad_request, "that is not a commit id", "Pick a version from the version picker.") };
    // Indexes are cached by commit alone, so the commit is checked to be
    // this dataset's before any cache is consulted.
    const mine = deps.db.rawOne(i64, scope, "SELECT 1::bigint FROM commits WHERE commit_id = $1::uuid AND dataset_id = $2::uuid", .{ c, ds.id }) catch return error.Db;
    if (mine == null) return .{ .refused = errorResponse(arena, .not_found, "no such version in this dataset", "Pick a version from the version picker.") };
    const index = (try browseIndex(arena, deps, scope, ds, c)) orelse
        return .{ .refused = errorResponse(arena, .service_unavailable, "the server is indexing another version", "Reload in a moment.") };
    return .{ .ready = index };
}

fn limitOf(route: DatasetRoute, default: u32) HandleError!u32 {
    const raw = route.queryParam("limit") orelse return default;
    const n = std.fmt.parseInt(u32, raw, 10) catch return error.BadRequest;
    return std.math.clamp(n, 1, browse_mod.max_limit);
}

/// Maps a DuckDB failure to the API's errors.
fn duckErr(err: browse_mod.Error) HandleError {
    return if (err == error.OutOfMemory) error.OutOfMemory else error.Storage;
}

/// One page of a version, filtered, with facets and a cursor
/// (browse/browse.zig has the contract), from the version's index.
fn browse(arena: std.mem.Allocator, deps: *Deps, scope: anytype, ds: Dataset, route: DatasetRoute) HandleError!Response {
    const index = switch (try indexFor(arena, deps, scope, ds, route.queryParam("commit"))) {
        .ready => |ix| ix,
        .refused => |res| return res,
    };
    var q: browse_mod.Query = .{
        .q = try param(arena, route, "q"),
        .split = try param(arena, route, "split"),
        .class = try param(arena, route, "class"),
        .type = try param(arena, route, "type"),
        .after = try param(arena, route, "after"),
        .item = try param(arena, route, "item"),
        .limit = try limitOf(route, browse_mod.default_limit),
    };
    if (q.q) |text| if (text.len == 0) {
        q.q = null;
    };
    var db = try duckFor(arena, deps, index.dir);
    defer db.close();
    const answer = offload(deps, browse_mod.queryIndex, .{ arena, &db, index.files, q }) catch |err| return duckErr(err);
    return json(arena, .ok, try withMedia(arena, deps, scope, answer));
}

/// How much a subset would take (`split=` and `class=`, each repeatable):
/// the overview's "use this dataset" size line.
fn browseSize(arena: std.mem.Allocator, deps: *Deps, scope: anytype, ds: Dataset, route: DatasetRoute) HandleError!Response {
    const index = switch (try indexFor(arena, deps, scope, ds, route.queryParam("commit"))) {
        .ready => |ix| ix,
        .refused => |res| return res,
    };
    const splits = try paramAll(arena, route, "split");
    const classes = try paramAll(arena, route, "class");
    var db = try duckFor(arena, deps, index.dir);
    defer db.close();
    const size = offload(deps, browse_mod.subsetSize, .{ arena, &db, index.files, splits, classes }) catch |err| return duckErr(err);
    return json(arena, .ok, size);
}

/// One folder of a version (`prefix=`, "" for the top): subfolders with
/// their counts, and a page of the files in it.
fn browseDir(arena: std.mem.Allocator, deps: *Deps, scope: anytype, ds: Dataset, route: DatasetRoute) HandleError!Response {
    const index = switch (try indexFor(arena, deps, scope, ds, route.queryParam("commit"))) {
        .ready => |ix| ix,
        .refused => |res| return res,
    };
    const prefix = (try param(arena, route, "prefix")) orelse "";
    if (prefix.len > 0 and prefix[prefix.len - 1] != '/') return error.BadRequest;
    var db = try duckFor(arena, deps, index.dir);
    defer db.close();
    const listing = offload(deps, browse_mod.listDir, .{ arena, &db, index.files, prefix, try param(arena, route, "after"), try limitOf(route, browse_mod.max_limit) }) catch |err| return duckErr(err);
    return json(arena, .ok, listing);
}

/// The dashboard's compare of two versions (`a=`, `b=`): the summary, a
/// page of item changes, and on the first page the visual diff.
fn browseCompare(arena: std.mem.Allocator, deps: *Deps, scope: anytype, ds: Dataset, route: DatasetRoute) HandleError!Response {
    const a = switch (try indexFor(arena, deps, scope, ds, route.queryParam("a"))) {
        .ready => |ix| ix,
        .refused => |res| return res,
    };
    const b = switch (try indexFor(arena, deps, scope, ds, route.queryParam("b"))) {
        .ready => |ix| ix,
        .refused => |res| return res,
    };
    const pair = (try diffIndex(arena, deps, scope, ds, route.queryParam("a").?, route.queryParam("b").?, a, b)) orelse
        return errorResponse(arena, .service_unavailable, "the server is indexing another version", "Reload in a moment.");
    var db = try duckFor(arena, deps, a.dir);
    defer db.close();
    var page = offload(deps, browse_mod.comparePage, .{ arena, &db, a.files, b.files, pair, try param(arena, route, "after"), try limitOf(route, browse_mod.max_limit) }) catch |err| return duckErr(err);
    // Dimensions, as everywhere: read now, never frozen into an index.
    var hashes: std.ArrayList([]const u8) = .empty;
    for (page.visual) |v| {
        if (v.before) |x| try hashes.append(arena, x.hash);
        if (v.after) |x| try hashes.append(arena, x.hash);
    }
    const dims = try dimsOf(arena, deps, scope, hashes.items);
    const visual = try arena.dupe(@TypeOf(page.visual[0]), page.visual);
    for (visual) |*v| {
        inline for (.{ &v.before, &v.after }) |side| if (side.*) |*x| if (dims.get(x.hash)) |d| {
            x.width = d.width;
            x.height = d.height;
        };
    }
    page.visual = visual;
    return json(arena, .ok, page);
}

const Dims = struct { width: ?u32, height: ?u32 };

/// Image dimensions by content hash, from the items' media metadata.
fn dimsOf(arena: std.mem.Allocator, deps: *Deps, scope: anytype, hashes: []const []const u8) HandleError!std.StringHashMapUnmanaged(Dims) {
    var out: std.StringHashMapUnmanaged(Dims) = .empty;
    if (hashes.len == 0) return out;
    var joined: std.ArrayList(u8) = .empty;
    for (hashes, 0..) |h, i| {
        if (i > 0) try joined.append(arena, ',');
        try joined.appendSlice(arena, h);
    }
    const Meta = struct {
        pub const nilo_table = .projection;
        hash: []const u8,
        width: ?i32,
        height: ?i32,
    };
    const metas = deps.db.raw(Meta, scope, "SELECT encode(item_hash, 'hex') AS hash, (meta->>'width')::int AS width, (meta->>'height')::int AS height " ++
        "FROM items WHERE item_hash IN (SELECT decode(h, 'hex') FROM unnest(string_to_array($1, ',')) h)", .{joined.items}) catch return error.Db;
    for (metas) |m| try out.put(arena, try arena.dupe(u8, m.hash), .{
        .width = if (m.width) |w| (if (w > 0) @intCast(w) else null) else null,
        .height = if (m.height) |h| (if (h > 0) @intCast(h) else null) else null,
    });
    return out;
}

/// The page's media metadata (an image's dimensions), read now: the
/// worker fills it in after ingest, so it is never part of an index.
fn withMedia(arena: std.mem.Allocator, deps: *Deps, scope: anytype, answer: browse_mod.Answer) HandleError!browse_mod.Answer {
    var out = answer;
    var hashes: std.ArrayList([]const u8) = .empty;
    for (answer.items) |item| try hashes.append(arena, item.hash);
    if (answer.open) |item| try hashes.append(arena, item.hash);
    const dims = try dimsOf(arena, deps, scope, hashes.items);
    const items = try arena.dupe(browse_mod.Item, answer.items);
    for (items) |*item| if (dims.get(item.hash)) |d| {
        item.width = d.width;
        item.height = d.height;
    };
    out.items = items;
    if (out.open) |*item| if (dims.get(item.hash)) |d| {
        item.width = d.width;
        item.height = d.height;
    };
    return out;
}

/// A query parameter, percent-decoded; present-but-empty is "" (the
/// "no split" value), absent is null.
fn param(arena: std.mem.Allocator, route: DatasetRoute, key: []const u8) HandleError!?[]const u8 {
    const raw = route.queryParam(key) orelse return null;
    return std.Uri.percentDecodeInPlace(try arena.dupe(u8, raw));
}

/// Every value of a repeated query parameter, percent-decoded.
fn paramAll(arena: std.mem.Allocator, route: DatasetRoute, key: []const u8) HandleError![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, route.query, '&');
    while (it.next()) |pair| {
        const eq_at = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eq_at], key)) continue;
        try out.append(arena, std.Uri.percentDecodeInPlace(try arena.dupe(u8, pair[eq_at + 1 ..])));
    }
    return out.items;
}

const BrowseIndex = struct { dir: []const u8, files: browse_mod.Files };

fn releaseSlot(deps: *Deps) void {
    deps.browse_building_commit.store(0, .release);
    deps.browse_building.store(false, .release);
}

/// Whether the server is still running, asked without relying on a
/// cancellation. A stop cancels background work once, and that cancel can
/// be spent inside a job (a cancelled S3 call reads as a storage error and
/// the job carries on); a wait after it then runs its full length, and the
/// stop waits with it. A server winding down takes no new background work
/// (nilo ADR 028), so a refused spawn means it is going. Every wait that
/// background work can reach asks this too.
pub fn serving() bool {
    nilo.spawn(idle, .{}) catch return false;
    return true;
}

fn idle() void {}

/// How long a request waits for the build of the very version it asked
/// for (a 1M-item index takes about 25 s).
const browse_wait_ms = 90_000;

/// The version's browse index on local disk, fetched from storage (kept
/// there for every version once built) or built from history the first
/// time; null while another build holds the one build slot. Commits are sealed, so an index never
/// goes stale; the folder keeps the most recent `browse_cache_max`.
fn browseIndex(arena: std.mem.Allocator, deps: *Deps, scope: anytype, ds: Dataset, commit: []const u8) HandleError!?BrowseIndex {
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(deps.io, deps.browse_dir) catch return error.Storage;
    const dir = cwd.realPathFileAlloc(deps.io, deps.browse_dir, arena) catch return error.Storage;
    const index: BrowseIndex = .{ .dir = dir, .files = browse_mod.Files.of(arena, dir, commit) catch return error.OutOfMemory };
    if (cwd.statFile(deps.io, index.files.items, .{})) |_| return index else |_| {}

    const wanted = std.mem.readInt(u64, (Uuid.parse(commit) catch return error.BadRequest).bytes[8..16], .big);
    if (deps.browse_building.swap(true, .acquire)) {
        // The version asked for is the one being built (the background
        // worker started on it after the push): wait for it, in a server.
        if (deps.offload and deps.browse_building_commit.load(.acquire) == wanted) {
            var waited: u32 = 0;
            while (waited < browse_wait_ms and serving()) : (waited += 250) {
                nilo.sleep(250) catch break;
                if (cwd.statFile(deps.io, index.files.items, .{})) |_| return index else |_| {}
            }
        }
        return null;
    }
    deps.browse_building_commit.store(wanted, .release);
    defer releaseSlot(deps);
    if (cwd.statFile(deps.io, index.files.items, .{})) |_| return index else |_| {}

    // Built before, here or by another server: storage keeps every index.
    fetched: {
        const keys = try browseKeys(arena, ds.id, commit);
        // Annotations first: an index exists once its items file does.
        for ([_][2][]const u8{ .{ keys.anns, index.files.anns }, .{ keys.items, index.files.items } }) |pair| {
            const tmp = try uniqueTmp(arena, deps, pair[1]);
            if (!(try downloadTo(deps, scope, pair[0], tmp))) break :fetched;
            std.Io.Dir.rename(cwd, tmp, cwd, pair[1], deps.io) catch return error.Storage;
        }
        pruneBrowse(arena, deps, dir);
        return index;
    }

    // One pass over history (core/version.zig), then DuckDB's conversion,
    // in working files of this build's own.
    const build = index.files.forBuild(arena, deps.io) catch return error.OutOfMemory;
    const lines = try openLines(deps, build);
    defer deps.gpa.destroy(lines);
    _ = versions.pass(deps.gpa, deps.db, scope, ds.id, commit, .{ .items = lines.items(), .annotations = lines.anns() }) catch |err| {
        lines.discard(deps, build);
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.WriteFailed => error.Storage,
            else => error.Db,
        };
    };
    lines.close(deps);
    try convertLines(arena, deps, build);
    storeBrowseIndex(arena, deps, scope, ds, commit, index.files);
    pruneBrowse(arena, deps, dir);
    return index;
}

/// A temp name beside `path` that no other server sharing the folder will
/// write: downloads land there, then rename into place.
fn uniqueTmp(arena: std.mem.Allocator, deps: *Deps, path: []const u8) error{OutOfMemory}![]const u8 {
    var token: [8]u8 = undefined;
    deps.io.random(&token);
    return std.fmt.allocPrint(arena, "{s}.{x}.tmp", .{ path, &token });
}

/// The two line files a pass writes, open, with their writers.
const Lines = struct {
    items_file: std.Io.File,
    anns_file: std.Io.File,
    items_w: std.Io.File.Writer,
    anns_w: std.Io.File.Writer,
    items_buf: [64 * 1024]u8,
    anns_buf: [64 * 1024]u8,

    fn items(self: *Lines) *std.Io.Writer {
        return &self.items_w.interface;
    }
    fn anns(self: *Lines) *std.Io.Writer {
        return &self.anns_w.interface;
    }
    fn close(self: *Lines, deps: *Deps) void {
        self.items_file.close(deps.io);
        self.anns_file.close(deps.io);
    }
    fn discard(self: *Lines, deps: *Deps, files: browse_mod.Files) void {
        self.close(deps);
        std.Io.Dir.cwd().deleteFile(deps.io, files.items_lines) catch {};
        std.Io.Dir.cwd().deleteFile(deps.io, files.ann_lines) catch {};
    }
};

fn openLines(deps: *Deps, files: browse_mod.Files) HandleError!*Lines {
    const lines = deps.gpa.create(Lines) catch return error.OutOfMemory;
    errdefer deps.gpa.destroy(lines);
    const cwd = std.Io.Dir.cwd();
    lines.items_file = cwd.createFile(deps.io, files.items_lines, .{ .truncate = true }) catch return error.Storage;
    lines.anns_file = cwd.createFile(deps.io, files.ann_lines, .{ .truncate = true }) catch {
        lines.items_file.close(deps.io);
        return error.Storage;
    };
    lines.items_w = lines.items_file.writer(deps.io, &lines.items_buf);
    lines.anns_w = lines.anns_file.writer(deps.io, &lines.anns_buf);
    return lines;
}

/// The lines → Parquet, in a database of its own with one thread: index
/// builds run one at a time, and one thread keeps the conversion near
/// 250 MB at 1M items where two take near 600 MB.
fn convertLines(arena: std.mem.Allocator, deps: *Deps, files: browse_mod.Files) HandleError!void {
    const dir = std.fs.path.dirname(files.items) orelse return error.Storage;
    var db = duck.Db.open(arena, .{ .allowed_dir = dir, .threads = 1 }) catch return error.Storage;
    defer db.close();
    offload(deps, browse_mod.convertIndex, .{ arena, deps.io, &db, files }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Storage,
    };
}

/// Streams the object at `key` into the file at `path`, holding none of
/// it; false when storage does not have it (the partial file is removed).
fn downloadTo(deps: *Deps, scope: anytype, key: []const u8, path: []const u8) HandleError!bool {
    const cwd = std.Io.Dir.cwd();
    var file = cwd.createFile(deps.io, path, .{ .truncate = true }) catch return error.Storage;
    var buf: [64 * 1024]u8 = undefined;
    var fw = file.writer(deps.io, &buf);
    const ok = if (deps.s3.streamTo(scope, key, &fw.interface)) |_| (if (fw.interface.flush()) |_| true else |_| false) else |_| false;
    file.close(deps.io);
    if (!ok) cwd.deleteFile(deps.io, path) catch {};
    return ok;
}

/// manifests/<dataset_id>/<commit_id>.{items,anns}.parquet, beside the
/// release's canonical manifest (CLAUDE.md, storage layout). Derived and
/// rebuildable: the release's hash is over the canonical stream.
fn browseKeys(arena: std.mem.Allocator, dataset_id: []const u8, commit: []const u8) HandleError!struct { items: []const u8, anns: []const u8 } {
    return .{
        .items = try std.fmt.allocPrint(arena, "manifests/{s}/{s}.items.parquet", .{ dataset_id, commit }),
        .anns = try std.fmt.allocPrint(arena, "manifests/{s}/{s}.anns.parquet", .{ dataset_id, commit }),
    };
}

/// Keeps a version's index in storage, so another server (or this one,
/// after a restart) fetches it instead of rebuilding. Best-effort: the
/// index can always be built again from history.
fn storeBrowseIndex(arena: std.mem.Allocator, deps: *Deps, scope: anytype, ds: Dataset, commit: []const u8, files: browse_mod.Files) void {
    const keys = browseKeys(arena, ds.id, commit) catch return;
    for ([_][2][]const u8{ .{ keys.anns, files.anns }, .{ keys.items, files.items } }) |pair| {
        deps.s3.putFile(scope, deps.io, pair[0], pair[1]) catch {
            std.log.warn("browse: could not store the index of a release; it will be rebuilt when needed", .{});
            return;
        };
    }
}

/// A pair's diff (browse.DiffFiles) on local disk: kept, fetched from
/// storage, or built now under the one build slot, in a one-thread
/// database of its own (the whole-version joins spill past its ceiling
/// rather than fail); null while another build holds the slot. Both
/// versions are sealed, so a diff never goes stale.
fn diffIndex(arena: std.mem.Allocator, deps: *Deps, scope: anytype, ds: Dataset, a: []const u8, b: []const u8, ia: BrowseIndex, ib: BrowseIndex) HandleError!?browse_mod.DiffFiles {
    const cwd = std.Io.Dir.cwd();
    const d = browse_mod.DiffFiles.of(arena, ia.dir, a, b) catch return error.OutOfMemory;
    if (cwd.statFile(deps.io, d.items, .{})) |_| return d else |_| {}
    if (deps.browse_building.swap(true, .acquire)) return null;
    defer releaseSlot(deps);
    if (cwd.statFile(deps.io, d.items, .{})) |_| return d else |_| {}

    const keys = [_][]const u8{
        try std.fmt.allocPrint(arena, "diffs/{s}/{s}-{s}.anns.parquet", .{ ds.id, a, b }),
        try std.fmt.allocPrint(arena, "diffs/{s}/{s}-{s}.items.parquet", .{ ds.id, a, b }),
    };
    const local = [_][]const u8{ d.anns, d.items };
    fetched: {
        for (keys, local) |key, path| {
            const tmp = try uniqueTmp(arena, deps, path);
            if (!(try downloadTo(deps, scope, key, tmp))) break :fetched;
            std.Io.Dir.rename(cwd, tmp, cwd, path, deps.io) catch return error.Storage;
        }
        return d;
    }
    {
        var db = duck.Db.open(arena, .{ .allowed_dir = ia.dir }) catch return error.Storage;
        defer db.close();
        offload(deps, browse_mod.buildDiff, .{ arena, deps.io, &db, ia.files, ib.files, d }) catch |err| return duckErr(err);
    }
    for (keys, local) |key, path| deps.s3.putFile(scope, deps.io, key, path) catch {
        std.log.warn("browse: could not store a diff; it will be rebuilt when needed", .{});
        break;
    };
    pruneBrowse(arena, deps, ia.dir);
    return d;
}

fn pruneBrowse(arena: std.mem.Allocator, deps: *Deps, dir_path: []const u8) void {
    // Versions' indexes and pairs' diffs, each kept to the most recent few.
    pruneKind(arena, deps, dir_path, ".diff-items.parquet", ".diff-anns.parquet");
    pruneKind(arena, deps, dir_path, ".items.parquet", ".anns.parquet");
}

fn pruneKind(arena: std.mem.Allocator, deps: *Deps, dir_path: []const u8, comptime main: []const u8, comptime partner: []const u8) void {
    var dir = std.Io.Dir.cwd().openDir(deps.io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(deps.io);
    const Entry = struct { name: []const u8, mtime: i96 };
    var entries: std.ArrayList(Entry) = .empty;
    var it = dir.iterate();
    while (it.next(deps.io) catch return) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, main)) continue;
        // ".items.parquet" must not count a diff's ".diff-items.parquet".
        if (comptime std.mem.eql(u8, main, ".items.parquet")) if (std.mem.endsWith(u8, entry.name, ".diff-items.parquet")) continue;
        const stat = dir.statFile(deps.io, entry.name, .{}) catch continue;
        entries.append(arena, .{ .name = arena.dupe(u8, entry.name) catch return, .mtime = stat.mtime.nanoseconds }) catch return;
    }
    if (entries.items.len <= deps.browse_cache_max) return;
    std.mem.sort(Entry, entries.items, {}, struct {
        fn newer(_: void, a: Entry, b: Entry) bool {
            return a.mtime > b.mtime;
        }
    }.newer);
    for (entries.items[deps.browse_cache_max..]) |old| {
        dir.deleteFile(deps.io, old.name) catch {};
        const stem = old.name[0 .. old.name.len - main.len];
        const anns = std.fmt.allocPrint(arena, "{s}" ++ partner, .{stem}) catch continue;
        dir.deleteFile(deps.io, anns) catch {};
    }
}

const RowDiffBody = struct { a: []const u8, b: []const u8, path_a: []const u8, path_b: []const u8 };

/// The largest table file a row diff reads. Larger tables belong in
/// partitioned files (CLAUDE.md, non-goals), which diff one by one.
pub const rowdiff_max_bytes: u64 = 128 * 1024 * 1024;

/// Row-level diff of two contents of a table file (CLAUDE.md, Formats):
/// rows added and removed, or the column change. Computed in the server
/// build the first time anyone asks, then answered from `row_diffs`.
/// Both contents must belong to this dataset (invariant 12). A restricted
/// dataset is answered with counts and columns only: rows are content.
fn rowDiff(arena: std.mem.Allocator, deps: *Deps, scope: anytype, ds: Dataset, body: []const u8) HandleError!Response {
    const req = parseBody(RowDiffBody, arena, body) orelse return error.BadRequest;
    if (!validHashHex(req.a) or !validHashHex(req.b)) return error.BadRequest;
    const kind_a = table_stats.kindOf(req.path_a) orelse
        return json(arena, .ok, .{ .status = "not_a_table", .reason = @as(?[]const u8, "only CSV, Parquet and JSONL files are compared by rows") });
    const kind_b = table_stats.kindOf(req.path_b) orelse
        return json(arena, .ok, .{ .status = "not_a_table", .reason = @as(?[]const u8, "only CSV, Parquet and JSONL files are compared by rows") });
    for ([_][]const u8{ req.a, req.b }) |hash| {
        const here = deps.db.rawOne(i64, scope, "SELECT 1::bigint FROM dataset_hashes WHERE dataset_id = $1::uuid AND item_hash = decode($2, 'hex')", .{ ds.id, hash }) catch return error.Db;
        if (here == null) return errorResponse(arena, .not_found, "no such item in this dataset", "Run 'cid diff <a> <b>' with two versions of this dataset.");
    }
    const ka = @tagName(kind_a);
    const kb = @tagName(kind_b);

    const Cached = struct {
        pub const nilo_table = .projection;
        status: []const u8,
        result: ?[]const u8,
        reason: ?[]const u8,
    };
    const lookup = "SELECT status, result::text AS result, reason FROM row_diffs WHERE hash_a = decode($1, 'hex') AND hash_b = decode($2, 'hex') AND kind_a = $3 AND kind_b = $4";
    var cached = deps.db.rawOne(Cached, scope, lookup, .{ req.a, req.b, ka, kb }) catch return error.Db;

    if (cached == null) {
        const Size = struct {
            pub const nilo_table = .projection;
            size_bytes: i64,
        };
        for ([_][]const u8{ req.a, req.b }) |hash| {
            const size = deps.db.rawOne(Size, scope, "SELECT size_bytes FROM items WHERE item_hash = decode($1, 'hex')", .{hash}) catch return error.Db;
            if (size) |sz| if (sz.size_bytes > rowdiff_max_bytes)
                return json(arena, .ok, .{ .status = "too_large", .reason = @as(?[]const u8, "over 128 MB; split large tables into partitioned files to compare them by rows") });
        }
        if (deps.rowdiff_busy.swap(true, .acquire))
            return errorResponse(arena, .service_unavailable, "the server is comparing another table", "Run the command again in a moment.");
        defer deps.rowdiff_busy.store(false, .release);

        const outcome = try computeRowDiff(arena, deps, scope, req, kind_a, kind_b);
        _ = deps.db.exec(scope, "INSERT INTO row_diffs (hash_a, hash_b, kind_a, kind_b, status, result, reason) " ++
            "VALUES (decode($1, 'hex'), decode($2, 'hex'), $3, $4, $5, $6::jsonb, $7) ON CONFLICT DO NOTHING", .{ req.a, req.b, ka, kb, outcome.status, outcome.result, outcome.reason }) catch return error.Db;
        cached = .{ .status = outcome.status, .result = outcome.result, .reason = outcome.reason };
    }

    const c = cached.?;
    const diff: ?std.json.Value = jsonValue(arena, c.result);
    if (diff == null or !ds.restricted)
        return json(arena, .ok, .{ .status = c.status, .reason = c.reason, .diff = diff, .withheld = false });
    var kept = diff.?;
    if (kept == .object) {
        _ = kept.object.orderedRemove("added_sample");
        _ = kept.object.orderedRemove("removed_sample");
    }
    return json(arena, .ok, .{ .status = c.status, .reason = c.reason, .diff = kept, .withheld = true });
}

const RowDiffOutcome = struct { status: []const u8, result: ?[]const u8 = null, reason: ?[]const u8 = null };

/// Fetches both contents into the scratch folder and has DuckDB compare
/// them there. Storage trouble is an error (asked again, computed again);
/// a file DuckDB cannot read is an answer, kept like any other.
fn computeRowDiff(arena: std.mem.Allocator, deps: *Deps, scope: anytype, req: RowDiffBody, kind_a: table_stats.Kind, kind_b: table_stats.Kind) HandleError!RowDiffOutcome {
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(deps.io, deps.work_dir) catch return error.Storage;
    const dir = cwd.realPathFileAlloc(deps.io, deps.work_dir, arena) catch return error.Storage;
    const path_a = try std.fmt.allocPrint(arena, "{s}/{s}.a.{t}", .{ dir, req.a, kind_a });
    const path_b = try std.fmt.allocPrint(arena, "{s}/{s}.b.{t}", .{ dir, req.b, kind_b });
    defer cwd.deleteFile(deps.io, path_a) catch {};
    defer cwd.deleteFile(deps.io, path_b) catch {};
    for ([_][2][]const u8{ .{ req.a, path_a }, .{ req.b, path_b } }) |pair| {
        if (!(try downloadTo(deps, scope, itemKey(arena, pair[0]) catch return error.OutOfMemory, pair[1]))) return error.Storage;
    }

    var db = duck.Db.open(arena, .{ .allowed_dir = dir, .threads = 1 }) catch return error.Storage;
    defer db.close();
    const text = offload(deps, rowdiff_mod.compute, .{ arena, &db, path_a, kind_a, path_b, kind_b }) catch |err| switch (err) {
        error.QueryFailed => return .{ .status = "unreadable", .reason = "not a readable table: DuckDB could not read one of the two versions as its file name says" },
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Storage,
    };
    return .{ .status = "done", .result = text };
}

/// How much of a text item the drawer shows.
const text_head_bytes = 64 * 1024;

/// The opening of a text item, for the drawer (media-native: a text file
/// reads as text, never "no preview"): its first 64 KB, cut back to a
/// whole character, read with a ranged GET so a large file is never held.
/// Shown, never interpreted (invariant 15). A restricted dataset's text is
/// content: withheld, and handed out by a logged reveal (invariant 20).
fn textHead(arena: std.mem.Allocator, deps: *Deps, scope: anytype, ds: Dataset, hash: []const u8) HandleError!Response {
    if (!validHashHex(hash)) return error.BadRequest;
    const Here = struct {
        pub const nilo_table = .projection;
        size_bytes: i64,
    };
    const here = (deps.db.rawOne(Here, scope, "SELECT i.size_bytes FROM items i WHERE i.item_hash = decode($1, 'hex') AND EXISTS " ++
        "(SELECT 1 FROM item_revisions r WHERE r.dataset_id = $2::uuid AND r.item_hash = i.item_hash)", .{ hash, ds.id }) catch return error.Db) orelse
        return errorResponse(arena, .not_found, "no such item in this dataset", "Pick the item from this dataset's Browse view.");
    if (ds.restricted) return json(arena, .ok, .{ .withheld = true, .size = here.size_bytes });
    return json(arena, .ok, try readTextHead(arena, deps, scope, hash, @intCast(here.size_bytes)));
}

fn isPictureOrSound(media_type: []const u8) bool {
    inline for (.{ "image/", "video/", "audio/" }) |p| if (std.mem.startsWith(u8, media_type, p)) return true;
    return false;
}

const TextHead = struct { text: ?[]const u8, truncated: bool, binary: bool, size: u64, withheld: bool = false };

fn readTextHead(arena: std.mem.Allocator, deps: *Deps, scope: anytype, hash: []const u8, size: u64) HandleError!TextHead {
    if (size == 0) return .{ .text = "", .truncated = false, .binary = false, .size = 0 };
    const bytes = deps.s3.getHead(scope, itemKey(arena, hash) catch return error.OutOfMemory, @min(size, text_head_bytes)) catch return error.Storage;
    // Cut back to a whole character; a NUL or broken UTF-8 is not text.
    var end = bytes.len;
    if (size > bytes.len) {
        var back: usize = 0;
        while (back < 3 and end > 0 and (bytes[end - 1] & 0xc0) == 0x80) : (back += 1) end -= 1;
        if (end > 0 and bytes[end - 1] >= 0xc0) end -= 1;
    }
    const text = bytes[0..end];
    if (std.mem.indexOfScalar(u8, text, 0) != null or !std.unicode.utf8ValidateSlice(text))
        return .{ .text = null, .truncated = false, .binary = true, .size = size };
    return .{ .text = text, .truncated = size > bytes.len, .binary = false, .size = size };
}

/// A table's statistics without its content: rows, and per column only
/// name, type and the share of nulls.
fn shapeOnly(arena: std.mem.Allocator, stats: std.json.Value) HandleError!std.json.Value {
    if (stats != .object) return .null;
    var out: std.json.ObjectMap = .empty;
    if (stats.object.get("rows")) |rows| try out.put(arena, "rows", rows);
    var cols = std.json.Array.init(arena);
    if (stats.object.get("columns")) |columns| if (columns == .array) for (columns.array.items) |col| {
        if (col != .object) continue;
        var kept: std.json.ObjectMap = .empty;
        inline for (.{ "name", "type", "null_percent" }) |k| if (col.object.get(k)) |v| try kept.put(arena, k, v);
        try cols.append(.{ .object = kept });
    };
    try out.put(arena, "columns", .{ .array = cols });
    try out.put(arena, "sample", .{ .array = std.json.Array.init(arena) });
    return .{ .object = out };
}

const RevealBody = struct { hash: []const u8 };

/// The one way to a clear preview of a restricted item (invariant 20):
/// the reveal is written to the activity log first, then the clear
/// thumbnail and a download link are handed back. The item must belong to
/// this dataset — reading one dataset never reveals another's bytes
/// (invariant 12). An open dataset answers with the same shape, unlogged.
fn reveal(arena: std.mem.Allocator, deps: *Deps, scope: anytype, caller: Caller, ds: Dataset, body: []const u8) HandleError!Response {
    const req = parseBody(RevealBody, arena, body) orelse return error.BadRequest;
    if (!validHashHex(req.hash)) return error.BadRequest;
    const here = deps.db.rawOne(i64, scope, "SELECT 1::bigint FROM item_revisions WHERE dataset_id = $1::uuid AND item_hash = decode($2, 'hex') LIMIT 1", .{ ds.id, req.hash }) catch return error.Db;
    if (here == null) return errorResponse(arena, .not_found, "no such item in this dataset", "Pick the item from this dataset's Browse view, then reveal it again.");

    if (ds.restricted) try logActivity(arena, deps, scope, ds, try actorOf(arena, deps, caller), "reveal", req.hash, null);

    const built = deps.db.rawOne(i64, scope, "SELECT 1::bigint FROM previews WHERE item_hash = decode($1, 'hex') AND status = 'done'", .{req.hash}) catch return error.Db;
    const thumb: ?[]const u8 = if (built != null)
        deps.s3.presignGet(scope, preview_worker.thumbKey(arena, req.hash) catch return error.OutOfMemory, presign_secs) catch return error.Storage
    else
        null;
    const download = deps.s3.presignGet(scope, itemKey(arena, req.hash) catch return error.OutOfMemory, presign_secs) catch return error.Storage;
    // A revealed table shows its rows: the same record covers them.
    const table_text = deps.db.rawOne([]const u8, scope, "SELECT table_stats::text FROM previews WHERE item_hash = decode($1, 'hex') AND table_stats IS NOT NULL", .{req.hash}) catch return error.Db;
    const table: ?std.json.Value = if (table_text) |t| jsonValue(arena, t) else null;
    // …and a text item its opening, on the same record.
    const Media = struct {
        pub const nilo_table = .projection;
        size_bytes: i64,
        media_type: []const u8,
    };
    const media = deps.db.rawOne(Media, scope, "SELECT size_bytes, media_type FROM items WHERE item_hash = decode($1, 'hex')", .{req.hash}) catch return error.Db;
    const text: ?TextHead = if (media) |m| (if (isPictureOrSound(m.media_type)) null else readTextHead(arena, deps, scope, req.hash, @intCast(@max(m.size_bytes, 0))) catch null) else null;
    return json(arena, .ok, .{ .hash = req.hash, .thumb = thumb, .download = download, .table = table, .text = text, .logged = ds.restricted });
}

/// The dataset's activity log (docs/dashboard.md §4.7). It names who
/// revealed what, so it is the owners' to read: Maintainers, and the
/// server token, which administers everything.
fn activity(arena: std.mem.Allocator, deps: *Deps, scope: anytype, caller: Caller, ds: Dataset) HandleError!Response {
    if (!(try isOwner(deps, scope, caller, ds)))
        return errorResponse(arena, .forbidden, "the activity log is for the dataset's owners", "Ask an owner (a Maintainer of the dataset's GitLab project) if you need to see it.");
    const Event = struct {
        pub const nilo_table = .projection;
        at: []const u8,
        account_id: []const u8,
        display_name: ?[]const u8,
        action: []const u8,
        ref: ?[]const u8,
        detail: ?[]const u8,
    };
    const events = deps.db.raw(Event, scope, "SELECT to_char(e.ts AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') AS at, e.account_id, " ++
        "a.display_name, e.action, e.ref, e.detail::text AS detail " ++
        "FROM activity_events e LEFT JOIN accounts a ON a.account_id = e.account_id " ++
        "WHERE e.dataset_id = $1::uuid ORDER BY e.ts DESC LIMIT 200", .{ds.id}) catch return error.Db;
    return json(arena, .ok, .{ .events = events });
}

fn isOwner(deps: *Deps, scope: anytype, caller: Caller, ds: Dataset) HandleError!bool {
    if (tokenOk(deps.token, caller.header)) return true;
    const account = caller.account orelse return false;
    const level = deps.db.rawOne([]const u8, scope, "SELECT level FROM access WHERE dataset_id = $1::uuid AND account_id = $2", .{ ds.id, account }) catch return error.Db;
    return if (level) |l| eql(l, "maintain") else false;
}

/// Who did it, for the record: a dashboard session's account, an
/// SSH-issued token's account, or the server token, which is nobody's.
fn actorOf(arena: std.mem.Allocator, deps: *Deps, caller: Caller) HandleError![]const u8 {
    if (caller.account) |account| return account;
    if (deps.token_secret) |secret| if (caller.header) |h| if (std.mem.startsWith(u8, h, "Bearer ")) {
        const now: u64 = @intCast(@max(0, std.Io.Timestamp.now(deps.io, .real).toSeconds()));
        if (token_mod.verify(arena, secret, h["Bearer ".len..], now)) |claims| return claims.account else |_| {}
    };
    return "server-token";
}

/// The record of something that already happened (a push, a release):
/// best effort, after the fact. Failing to note a push must not turn a
/// recorded push into a 500 — the client would retry into "someone pushed
/// since you pulled". A reveal is the opposite case; it uses logActivity.
fn noteActivity(arena: std.mem.Allocator, deps: *Deps, scope: anytype, caller: Caller, ds: Dataset, action: []const u8, ref: ?[]const u8, detail: anytype) void {
    const actor = actorOf(arena, deps, caller) catch "server-token";
    logActivity(arena, deps, scope, ds, actor, action, ref, detail) catch
        std.log.warn("could not note a {s} in the activity log; the {s} itself stands", .{ action, action });
}

/// An audit record, written before the thing it records happens: if it
/// cannot be written, the clear URL is not handed out either.
fn logActivity(arena: std.mem.Allocator, deps: *Deps, scope: anytype, ds: Dataset, actor: []const u8, action: []const u8, ref: ?[]const u8, detail: anytype) HandleError!void {
    const detail_text: ?[]const u8 = if (@TypeOf(detail) == @TypeOf(null)) null else try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(detail, .{})});
    _ = deps.db.exec(scope, "INSERT INTO activity_events (ts, dataset_id, account_id, action, ref, detail) VALUES (now(), $1::uuid, $2, $3, $4, $5::jsonb)", .{ ds.id, actor, action, ref, detail_text }) catch return error.Db;
}

/// A star is one person's bookmark — their preference, not the dataset's
/// data (invariant 17 is about the latter) — so it needs a person: a
/// dashboard session. The shared server token has no account to star from.
fn star(arena: std.mem.Allocator, deps: *Deps, scope: anytype, caller: Caller, ds: Dataset, on: bool) HandleError!Response {
    const account = caller.account orelse
        return errorResponse(arena, .unprocessable_entity, "a star belongs to a person, and the server token is not one", "Run 'Sign in with GitLab' on the dashboard, then star it again.");
    if (on) {
        _ = deps.db.exec(scope, "INSERT INTO stars (account_id, dataset_id) VALUES ($1, $2::uuid) ON CONFLICT DO NOTHING", .{ account, ds.id }) catch return error.Db;
    } else {
        _ = deps.db.exec(scope, "DELETE FROM stars WHERE account_id = $1 AND dataset_id = $2::uuid", .{ account, ds.id }) catch return error.Db;
    }
    return json(arena, .ok, .{ .starred = on });
}

fn splitLines(arena: std.mem.Allocator, text: []const u8) HandleError![]const []const u8 {
    if (text.len == 0) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| try out.append(arena, line);
    return out.items;
}

/// Who the dashboard is talking to. A session answers with its account;
/// the shared server token answers as itself, with no account behind it.
fn me(arena: std.mem.Allocator, deps: *Deps, scope: anytype, caller: Caller) HandleError!Response {
    if (caller.account) |account| {
        const name = deps.db.rawOne([]const u8, scope, "SELECT display_name FROM accounts WHERE account_id = $1", .{account}) catch return error.Db;
        return json(arena, .ok, .{ .via = "gitlab", .account = account, .display_name = name orelse account });
    }
    if (tokenOk(deps.token, caller.header))
        return json(arena, .ok, .{ .via = "token", .account = @as(?[]const u8, null), .display_name = "server token" });
    return errorResponse(arena, .unauthorized, "not signed in", "Run the sign-in again from the dashboard.");
}

/// What `resolveCaller` makes of the authorization header.
const Resolved = union(enum) { caller: Caller, refused: Response };

/// Basic credentials (`https://user:token@host/…`, as git sends them)
/// carry their token as the password, so they become a Bearer header; the
/// name is not read. A personal token (`cidp_…`) is looked up by its hash
/// and, if live, becomes its maker's account; any other bearer token
/// (the server's, or one minted over SSH) passes on unchanged.
fn resolveCaller(arena: std.mem.Allocator, deps: *Deps, scope: anytype, given: Caller) HandleError!Resolved {
    var caller = given;
    const h = caller.header orelse return .{ .caller = caller };
    if (std.mem.startsWith(u8, h, "Basic ")) {
        const decoder = std.base64.standard.Decoder;
        const raw = std.mem.trim(u8, h["Basic ".len..], " ");
        const plain = try arena.alloc(u8, decoder.calcSizeForSlice(raw) catch return .{ .refused = badCredentials(arena) });
        decoder.decode(plain, raw) catch return .{ .refused = badCredentials(arena) };
        const colon = std.mem.indexOfScalar(u8, plain, ':') orelse return .{ .refused = badCredentials(arena) };
        caller.header = try std.fmt.allocPrint(arena, "Bearer {s}", .{plain[colon + 1 ..]});
    }
    const bearer = caller.header.?;
    if (!std.mem.startsWith(u8, bearer, "Bearer " ++ personal_prefix)) return .{ .caller = caller };
    const hash_hex = content_hash.hex(bearer["Bearer ".len..]);
    const account = deps.db.rawOne([]const u8, scope, "UPDATE personal_tokens SET last_used_at = now() " ++
        "WHERE token_hash = decode($1, 'hex') AND expires_at > now() RETURNING account_id", .{@as([]const u8, &hash_hex)}) catch return error.Db;
    const who = account orelse return .{ .refused = errorResponse(arena, .unauthorized, "that personal token is expired, revoked or unknown", "Make a new one on the dashboard's Tokens page, then run the command again with it.") };
    return .{ .caller = .{ .account = who, .personal = true } };
}

fn badCredentials(arena: std.mem.Allocator) Response {
    return errorResponse(arena, .unauthorized, "the credentials are not 'name:token'", "Put the token in the address as https://you:TOKEN@host/<dataset>, then run the command again.");
}

/// Personal tokens start with this, so a leaked one is easy to recognise
/// and the server knows which lookup it needs.
pub const personal_prefix = "cidp_";
const token_days_default = 90;
const token_days_max = 365;
const tokens_per_account_max = 50;

const NewTokenBody = struct { name: []const u8, days: u32 = token_days_default };

/// A signed-in person's personal tokens, for scripts and CI: each acts as
/// them until it expires or is revoked. Made and revoked from a dashboard
/// session only, never by a token. `GET` lists, `POST {name, days}` makes
/// one (shown this once), `DELETE ?id=` revokes.
fn myTokens(arena: std.mem.Allocator, deps: *Deps, scope: anytype, caller: Caller, method: []const u8, target: []const u8, body: []const u8) HandleError!Response {
    const account = caller.account orelse
        return errorResponse(arena, .unprocessable_entity, "tokens belong to a person, and the server token is not one", "Run 'Sign in with GitLab' on the dashboard, then open your tokens again.");
    if (caller.personal)
        return errorResponse(arena, .forbidden, "a token cannot manage tokens", "Open the dashboard's Tokens page, signed in with GitLab, to do this.");
    const Row = struct {
        pub const nilo_table = .projection;
        id: []const u8,
        name: []const u8,
        prefix: []const u8,
        created_at: []const u8,
        expires_at: []const u8,
        expired: bool,
        last_used_at: ?[]const u8,
    };
    const iso = "'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'";
    const list_sql = "SELECT token_id::text AS id, name, prefix, to_char(created_at AT TIME ZONE 'UTC', " ++ iso ++ ") AS created_at, " ++
        "to_char(expires_at AT TIME ZONE 'UTC', " ++ iso ++ ") AS expires_at, expires_at <= now() AS expired, to_char(last_used_at AT TIME ZONE 'UTC', " ++ iso ++ ") AS last_used_at " ++
        "FROM personal_tokens WHERE account_id = $1 ORDER BY created_at DESC";

    if (eql(method, "GET") and eql(target, "/v0/me/tokens")) {
        const rows = deps.db.raw(Row, scope, list_sql, .{account}) catch return error.Db;
        return json(arena, .ok, .{ .tokens = rows });
    }
    if (eql(method, "POST") and eql(target, "/v0/me/tokens")) {
        const req = parseBody(NewTokenBody, arena, body) orelse return error.BadRequest;
        const name = std.mem.trim(u8, req.name, " \t\r\n");
        if (name.len == 0 or name.len > 100 or std.mem.indexOfAny(u8, name, "\r\n\t") != null)
            return errorResponse(arena, .unprocessable_entity, "a token needs a name of up to 100 characters on one line", "Name it after what will use it, such as 'nightly CI', then make it again.");
        if (req.days < 1 or req.days > token_days_max)
            return errorResponse(arena, .unprocessable_entity, "a token lives between 1 and 365 days", "Choose a lifetime in that range, then make it again.");
        const count = (deps.db.rawOne(i64, scope, "SELECT count(*)::bigint FROM personal_tokens WHERE account_id = $1", .{account}) catch return error.Db) orelse 0;
        if (count >= tokens_per_account_max)
            return errorResponse(arena, .unprocessable_entity, "you have 50 tokens already", "Revoke the ones nothing uses any more, then make this one again.");

        var secret: [32]u8 = undefined;
        deps.io.random(&secret);
        const b64 = std.base64.url_safe_no_pad.Encoder;
        const token = try arena.alloc(u8, personal_prefix.len + b64.calcSize(secret.len));
        @memcpy(token[0..personal_prefix.len], personal_prefix);
        _ = b64.encode(token[personal_prefix.len..], &secret);
        const hash_hex = content_hash.hex(token);
        const id = Uuid.now(deps.io).toString();
        _ = deps.db.exec(scope, "INSERT INTO personal_tokens (token_id, account_id, name, token_hash, prefix, expires_at) " ++
            "VALUES ($1::uuid, $2, $3, decode($4, 'hex'), $5, now() + $6::bigint * interval '1 day')", .{
            @as([]const u8, &id), account, name, @as([]const u8, &hash_hex), token[0 .. personal_prefix.len + 6], @as(i64, req.days),
        }) catch return error.Db;
        const rows = deps.db.raw(Row, scope, list_sql, .{account}) catch return error.Db;
        return json(arena, .created, .{ .id = @as([]const u8, &id), .token = token, .tokens = rows });
    }
    if (eql(method, "DELETE") and std.mem.startsWith(u8, target, "/v0/me/tokens?id=")) {
        const id = target["/v0/me/tokens?id=".len..];
        if (Uuid.parse(id) == error.InvalidUuid) return errorResponse(arena, .not_found, "you have no token with that id", "Reload your tokens and try again.");
        const gone = deps.db.exec(scope, "DELETE FROM personal_tokens WHERE token_id = $1::uuid AND account_id = $2", .{ id, account }) catch return error.Db;
        if (gone == 0) return errorResponse(arena, .not_found, "you have no token with that id", "Reload your tokens and try again.");
        const rows = deps.db.raw(Row, scope, list_sql, .{account}) catch return error.Db;
        return json(arena, .ok, .{ .tokens = rows });
    }
    return errorResponse(arena, .not_found, "no such route", "Update cid and try again.");
}

const AddKeyBody = struct { title: []const u8 = "", key: []const u8 };

/// A signed-in person's own SSH keys, the identity `cid clone` and the rest
/// use (invariant 17 allows the dashboard to change these). Listed with
/// where each came from; a key added here is removed here, a GitLab key in
/// GitLab. `GET` lists, `POST {title, key}` adds, `DELETE ?fingerprint=`
/// removes.
fn myKeys(arena: std.mem.Allocator, deps: *Deps, scope: anytype, caller: Caller, method: []const u8, target: []const u8, body: []const u8) HandleError!Response {
    const account = caller.account orelse
        return errorResponse(arena, .unprocessable_entity, "SSH keys belong to a person, and the server token is not one", "Run 'Sign in with GitLab' on the dashboard, then open your keys again.");
    // A key outlives any token, so a token, which can leak, may not add one.
    if (caller.personal)
        return errorResponse(arena, .forbidden, "a token cannot manage SSH keys", "Open the dashboard's SSH keys page, signed in with GitLab, to do this.");
    const Row = struct {
        pub const nilo_table = .projection;
        fingerprint: []const u8,
        title: []const u8,
        key_type: []const u8,
        source: []const u8,
        added_at: []const u8,
    };
    const list_sql = "SELECT fingerprint, title, split_part(public_key, ' ', 1) AS key_type, source, " ++
        "to_char(added_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') AS added_at " ++
        "FROM ssh_keys WHERE account_id = $1 ORDER BY added_at, fingerprint";

    if (eql(method, "GET") and eql(target, "/v0/me/keys")) {
        const rows = deps.db.raw(Row, scope, list_sql, .{account}) catch return error.Db;
        return json(arena, .ok, .{ .keys = rows });
    }
    if (eql(method, "POST") and eql(target, "/v0/me/keys")) {
        const req = parseBody(AddKeyBody, arena, body) orelse return error.BadRequest;
        const key = keys_mod.parse(arena, req.key) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.UnsupportedType => errorResponse(arena, .unprocessable_entity, "cid does not accept that key type", "Paste an ed25519 key (make one with 'ssh-keygen -t ed25519'), or ECDSA, or RSA of 2048 bits or more."),
            error.WeakKey => errorResponse(arena, .unprocessable_entity, "that RSA key is shorter than 2048 bits", "Make a new key with 'ssh-keygen -t ed25519' and paste its .pub file."),
            error.NotAKey, error.TypeMismatch => errorResponse(arena, .unprocessable_entity, "that is not an OpenSSH public key", "Paste the one line of your .pub file (for example ~/.ssh/id_ed25519.pub), which starts with 'ssh-'."),
        };
        const title = std.mem.trim(u8, req.title, " \t\r\n");
        if (title.len > 100 or std.mem.indexOfAny(u8, title, "\r\n\t") != null)
            return errorResponse(arena, .unprocessable_entity, "the title is longer than 100 characters or has line breaks", "Use a short name, such as the machine the key is on, then add it again.");
        // One key, one account: a key someone already registered (here,
        // in GitLab, or by an administrator) is refused, so nobody can
        // claim another person's public key.
        const added = deps.db.rawOne([]const u8, scope, "INSERT INTO ssh_keys (fingerprint, account_id, public_key, title, source) " ++
            "VALUES ($1, $2, $3, $4, 'dashboard') ON CONFLICT (fingerprint) DO NOTHING RETURNING fingerprint", .{ key.fingerprint, account, key.line, if (title.len > 0) title else key.comment }) catch return error.Db;
        if (added == null) {
            const mine = deps.db.rawOne(i64, scope, "SELECT 1::bigint FROM ssh_keys WHERE fingerprint = $1 AND account_id = $2", .{ key.fingerprint, account }) catch return error.Db;
            return if (mine != null)
                errorResponse(arena, .conflict, "that key is already one of yours", "Use it as it is: run 'cid clone' with it.")
            else
                errorResponse(arena, .conflict, "that key is already registered to another account", "Make a new key with 'ssh-keygen -t ed25519' and add its .pub file.");
        }
        const rows = deps.db.raw(Row, scope, list_sql, .{account}) catch return error.Db;
        return json(arena, .created, .{ .fingerprint = key.fingerprint, .keys = rows });
    }
    if (eql(method, "DELETE") and std.mem.startsWith(u8, target, "/v0/me/keys?fingerprint=")) {
        const fp = std.Uri.percentDecodeInPlace(try arena.dupe(u8, target["/v0/me/keys?fingerprint=".len..]));
        const source = deps.db.rawOne([]const u8, scope, "SELECT source FROM ssh_keys WHERE fingerprint = $1 AND account_id = $2", .{ fp, account }) catch return error.Db;
        const from = source orelse return errorResponse(arena, .not_found, "you have no key with that fingerprint", "Reload your keys and try again.");
        if (!eql(from, "dashboard"))
            return errorResponse(arena, .conflict, if (eql(from, "gitlab")) "that key comes from your GitLab account" else "an administrator registered that key", if (eql(from, "gitlab")) "Remove it in GitLab (Preferences > SSH Keys); cid drops it at the next sync." else "Ask the administrator to remove it.");
        _ = deps.db.exec(scope, "DELETE FROM ssh_keys WHERE fingerprint = $1 AND account_id = $2 AND source = 'dashboard'", .{ fp, account }) catch return error.Db;
        const rows = deps.db.raw(Row, scope, list_sql, .{account}) catch return error.Db;
        return json(arena, .ok, .{ .keys = rows });
    }
    return errorResponse(arena, .not_found, "no such route", "Update cid and try again.");
}

/// What a dataset card needs about a commit, cached in `commits.stats`.
/// A commit never changes, so this is computed once — the first time a
/// page needs it — and stored with `WHERE stats IS NULL`: the work scales
/// with commits, never with visitors, the rule the preview queue follows.
/// It is a derived cache of an immutable row, not history; a version it
/// cannot read is recomputed and simply not stored.
const CreateDatasetBody = struct {
    name: []const u8,
    kind: []const u8 = "files",
    git_url: []const u8,
};

fn createDataset(arena: std.mem.Allocator, deps: *Deps, scope: anytype, auth_header: ?[]const u8, body: []const u8) HandleError!Response {
    const req = parseBody(CreateDatasetBody, arena, body) orelse return error.BadRequest;
    if (req.name.len == 0 or req.git_url.len == 0) return error.BadRequest;
    if (!authorized(arena, deps, scope, .{ .header = auth_header }, req.name, .write))
        return errorResponse(arena, .unauthorized, "missing, wrong or expired token for this dataset", "Run the command again; cid fetches a fresh token over SSH. CI: check CID_TOKEN.");
    if (!eql(req.kind, "files") and !eql(req.kind, "annotated")) return error.BadRequest;

    if (lookupDataset(arena, deps, scope, req.name) != null)
        return errorResponse(arena, .conflict, "the dataset already exists", "Run 'cid clone' to work with it.");

    // Every dataset has a git repository cid writes (invariant 21): with the
    // writer configured, find out now, not at the first release, whether
    // it can. A server without one queues the writes for --resync instead.
    if (deps.git) |git_config| {
        const checked = offload(deps, git_writer.probe, .{ arena, deps.io, git_config, req.git_url }) catch return error.Storage;
        switch (checked) {
            .ok => {},
            .unreachable_repo => |why| return errorResponse(arena, .unprocessable_entity, try std.fmt.allocPrint(arena, "the git repository {s} cannot be reached ({s})", .{ req.git_url, why }), "Check the URL (create the repository first if it does not exist), then run 'cid init' again."),
            .not_writable => |why| return errorResponse(arena, .unprocessable_entity, try std.fmt.allocPrint(arena, "the cid server cannot push to {s} ({s})", .{ req.git_url, why }), "Give the cid server's key write access to that repository (a deploy key with write access), then run 'cid init' again."),
        }
    }

    // Whether only cid can push to main: warned about, never refused.
    const warning = offload(deps, protection.check, .{ arena, deps.io, deps.gitlab, req.git_url }) catch return error.OutOfMemory;

    const id = Uuid.now(deps.io).toString();
    _ = deps.db.exec(
        scope,
        "INSERT INTO datasets (dataset_id, name, kind, git_url) VALUES ($1::uuid, $2, $3, $4)",
        .{ @as([]const u8, &id), req.name, req.kind, req.git_url },
    ) catch return error.Db;
    // Made with a token the SSH front door minted for a GitLab Maintainer
    // (cid-auth <dataset> create): its creator owns it from now, not from
    // the next GitLab sync, which will find the same role.
    if (tokenAccount(arena, deps, auth_header)) |account| {
        _ = deps.db.exec(scope, "INSERT INTO access (dataset_id, account_id, level, source) " ++
            "SELECT $1::uuid, $2, 'maintain', 'gitlab' WHERE EXISTS (SELECT 1 FROM accounts WHERE account_id = $2) " ++
            "ON CONFLICT (dataset_id, account_id) DO UPDATE SET level = 'maintain'", .{ @as([]const u8, &id), account }) catch return error.Db;
    }
    const warnings: []const []const u8 = if (warning) |w| try arena.dupe([]const u8, &.{w}) else &.{};
    return json(arena, .created, .{ .name = req.name, .dataset_id = &id, .git_checked = deps.git != null, .warnings = warnings });
}

const InfoRow = struct {
    pub const nilo_table = .projection;
    kind: []const u8,
    git_url: []const u8,
    default_format: []const u8,
};

fn datasetInfo(arena: std.mem.Allocator, deps: *Deps, scope: anytype, ds: Dataset) HandleError!Response {
    const info = (deps.db.rawOne(InfoRow, scope, "SELECT kind, git_url, default_format FROM datasets WHERE dataset_id = $1::uuid", .{ds.id}) catch return error.Db) orelse return error.Db;
    return json(arena, .ok, .{
        .name = ds.name,
        .kind = info.kind,
        .git_url = info.git_url,
        .default_format = info.default_format,
    });
}

/// Everything the dashboard's Overview needs in one call: identity, the
/// commit tape (newest first, releases attached), and the counts of the
/// current head state. Pinned to main; branch views arrive later.
fn overview(arena: std.mem.Allocator, deps: *Deps, scope: anytype, ds: Dataset) HandleError!Response {
    const info = (deps.db.rawOne(InfoRow, scope, "SELECT kind, git_url, default_format FROM datasets WHERE dataset_id = $1::uuid", .{ds.id}) catch return error.Db) orelse return error.Db;

    const TapeEntry = struct {
        pub const nilo_table = .projection;
        id: []const u8,
        message: []const u8,
        author: []const u8,
        at_ms: i64,
        release: ?[]const u8,
    };
    const tape = deps.db.raw(TapeEntry, scope, "SELECT c.commit_id::text AS id, c.message, c.author, " ++
        "(extract(epoch from c.recorded_at) * 1000)::bigint AS at_ms, rel.name AS release " ++
        "FROM commits c LEFT JOIN LATERAL (" ++
        "  SELECT name FROM refs r WHERE r.dataset_id = c.dataset_id " ++
        "  AND r.commit_id = c.commit_id AND r.kind = 'release' ORDER BY name LIMIT 1) rel ON true " ++
        "WHERE c.dataset_id = $1::uuid AND c.branch = 'main' " ++
        "ORDER BY c.commit_id DESC LIMIT 100", .{ds.id}) catch return error.Db;

    // Counts at head, kept on the commit (versions.stats).
    const head_stats: versions.Stats = if (tape.len > 0)
        versions.stats(arena, deps.db, scope, ds.id, tape[0].id) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Db,
        }
    else
        .{};

    return json(arena, .ok, .{
        .name = ds.name,
        .kind = ds.kind,
        .restricted = ds.restricted,
        .git_url = info.git_url,
        .default_format = info.default_format,
        .commits = tape,
        .items = head_stats.items,
        .bytes = head_stats.bytes,
        .classes = head_stats.classes,
        .splits = head_stats.splits,
    });
}

fn head(arena: std.mem.Allocator, deps: *Deps, scope: anytype, ds: Dataset, branch: []const u8) HandleError!Response {
    const commit = deps.db.rawOne([]const u8, scope, "SELECT commit_id::text FROM refs WHERE dataset_id = $1::uuid AND name = $2 AND kind = 'branch'", .{ ds.id, branch }) catch return error.Db;
    return json(arena, .ok, .{ .commit = commit });
}

fn log(arena: std.mem.Allocator, deps: *Deps, scope: anytype, ds: Dataset, branch: []const u8) HandleError!Response {
    const Entry = struct {
        pub const nilo_table = .projection;
        id: []const u8,
        parent: ?[]const u8,
        message: []const u8,
        author: []const u8,
        authored_at_ms: i64,
        /// The releases made at this commit, comma-separated (most have none).
        releases: ?[]const u8,
    };
    const list = deps.db.raw(Entry, scope, "SELECT c.commit_id::text AS id, c.parent_id::text AS parent, c.message, c.author, " ++
        "(extract(epoch from c.authored_at) * 1000)::bigint AS authored_at_ms, " ++
        "(SELECT string_agg(r.name, ', ' ORDER BY r.name) FROM refs r WHERE r.dataset_id = c.dataset_id AND r.commit_id = c.commit_id AND r.kind = 'release') AS releases " ++
        "FROM commits c WHERE c.dataset_id = $1::uuid AND c.branch = $2 " ++
        "ORDER BY c.commit_id DESC LIMIT 200", .{ ds.id, branch }) catch return error.Db;
    return json(arena, .ok, .{ .commits = list });
}

/// `sizes`, when sent, runs alongside `hashes`: a file larger than a piece
/// is asked for in pieces.
const HashesBody = struct { hashes: []const []const u8, sizes: []const u64 = &.{} };

/// Which of these hashes must be uploaded, with presigned PUT URLs for them
/// (into this dataset's staging area). Only bytes this dataset already
/// holds count as present (invariant 12: a hash learned elsewhere opens
/// nothing).
fn checkHashes(arena: std.mem.Allocator, deps: *Deps, scope: anytype, ds: Dataset, body: []const u8) HandleError!Response {
    const req = parseBody(HashesBody, arena, body) orelse return error.BadRequest;
    if (req.hashes.len > 1000) return error.BadRequest;

    if (req.sizes.len != 0 and req.sizes.len != req.hashes.len) return error.BadRequest;
    const Piece = struct { n: u32, url: []const u8 };
    const Upload = struct {
        hash: []const u8,
        /// The whole file, one PUT…
        url: ?[]const u8 = null,
        /// …or the pieces still missing, each `part_size` bytes (the last
        /// one shorter), numbered from 1.
        part_size: ?u64 = null,
        parts: ?[]const Piece = null,
    };
    var missing: std.ArrayList(Upload) = .empty;
    for (req.hashes, 0..) |hash, i| {
        if (!validHashHex(hash)) return error.BadRequest;
        if (try isPurged(deps.db, scope, hash))
            return errorResponse(arena, .unprocessable_entity, "that content was purged and cannot come back", "Remove or replace the file, then run 'cid push' again.");
        if (try heldHere(arena, deps, scope, ds, hash)) {
            // Told "the server has it": cleanup must not take it now.
            _ = deps.db.exec(scope, "UPDATE items SET touched_at = now() WHERE item_hash = decode($1, 'hex')", .{hash}) catch return error.Db;
            continue;
        }
        // Uploads land in this dataset's staging area, never on the
        // stored key: the server verifies them when they are recorded. One
        // already staged (a push that stopped before recording) is not
        // asked for again.
        const staged = try stagedKey(arena, ds.id, hash);
        if ((deps.s3.headObject(scope, staged) catch return error.Storage) != null) continue;
        const size = if (req.sizes.len > 0) req.sizes[i] else 0;
        if (size <= deps.piece_bytes) {
            const url = deps.s3.presignPut(scope, staged, presign_secs) catch return error.Storage;
            try missing.append(arena, .{ .hash = hash, .url = url });
            continue;
        }
        // In pieces: those already staged (an earlier push that stopped)
        // are not asked for again.
        const count: u32 = @intCast((size + deps.piece_bytes - 1) / deps.piece_bytes);
        const have = try stagedPieces(arena, deps, scope, ds.id, hash, count);
        var pieces: std.ArrayList(Piece) = .empty;
        for (have, 1..) |there, n| {
            if (there) continue;
            const url = deps.s3.presignPut(scope, try pieceKey(arena, ds.id, hash, @intCast(n)), presign_secs) catch return error.Storage;
            try pieces.append(arena, .{ .n = @intCast(n), .url = url });
        }
        if (pieces.items.len == 0) continue;
        try missing.append(arena, .{ .hash = hash, .part_size = deps.piece_bytes, .parts = pieces.items });
    }
    return json(arena, .ok, .{ .missing = missing.items });
}

const PushChange = struct {
    op: []const u8, // "add" | "delete"
    path: []const u8,
    hash: []const u8 = "",
    size: u64 = 0,
};
const PushCommit = struct {
    id: []const u8,
    parent: ?[]const u8 = null,
    message: []const u8,
    author: []const u8,
    authored_at_ms: u64,
    changes: []const PushChange,
};
const PushBody = struct {
    branch: []const u8 = "main",
    commits: []const PushCommit,
};

/// All-or-nothing (invariant 7 of the push rules): verify every file first,
/// then record revisions, commits and the branch head in one transaction,
/// under the per-(dataset, branch) advisory lock (invariant 3).
fn push(arena: std.mem.Allocator, deps: *Deps, scope: anytype, caller: Caller, ds: Dataset, body: []const u8) HandleError!Response {
    const req = parseBody(PushBody, arena, body) orelse return error.BadRequest;
    if (req.commits.len == 0) return error.BadRequest;

    // 1. Every new file is admitted: held here already, or uploaded and
    // its bytes hashed by the server now (invariant 2); once per content.
    var admitted: std.StringHashMapUnmanaged(void) = .empty;
    for (req.commits) |commit| {
        for (commit.changes) |ch| {
            if (eql(ch.op, "add")) {
                if (!validHashHex(ch.hash)) return error.BadRequest;
                if (admitted.contains(ch.hash)) continue;
                if (try isPurged(deps.db, scope, ch.hash))
                    return errorResponse(arena, .unprocessable_entity, "that content was purged and cannot come back", "Remove or replace the file, then run 'cid push' again.");
                switch (try admit(arena, deps, scope, ds, ch.hash, ch.size)) {
                    .admitted => try admitted.put(arena, ch.hash, {}),
                    .missing => return errorResponse(arena, .unprocessable_entity, "a file is missing from storage", "Run 'cid push' again; it re-uploads what is missing."),
                    .mismatch => return errorResponse(arena, .unprocessable_entity, "an uploaded file does not match its hash", "Run 'cid push' again; it re-uploads it. If it persists, check the file is not changing while you push."),
                }
            } else if (!eql(ch.op, "delete")) return error.BadRequest;
        }
    }

    var tx = deps.db.begin(scope, .{}) catch return error.Db;
    defer tx.deinit(); // rolls back unless committed

    // 2. The commit lock: writers shared, commits exclusive (docs/data-model.md).
    _ = tx.exec(
        scope,
        "SELECT pg_advisory_xact_lock(hashtextextended($1 || '/' || $2, 0))",
        .{ ds.id, req.branch },
    ) catch return error.Db;

    // 3. Forward-only: the first commit's parent must be the branch head.
    const server_head = tx.rawOne([]const u8, scope, "SELECT commit_id::text FROM refs WHERE dataset_id = $1::uuid AND name = $2 AND kind = 'branch'", .{ ds.id, req.branch }) catch return error.Db;
    const claimed_parent = req.commits[0].parent;
    const matches = (server_head == null and claimed_parent == null) or
        (server_head != null and claimed_parent != null and eql(server_head.?, claimed_parent.?));
    if (!matches) {
        return errorResponse(arena, .conflict, "someone pushed since you pulled", "Run 'cid pull', then 'cid push' again.");
    }

    // 4. Record: items, revisions, commits; branch head last. Revision ids
    // come from the database clock, each strictly above the one before and
    // above the current head's cutoff (invariant 3).
    if (try sealBroken(arena, &tx, scope, ds, server_head)) |res| return res;
    var rev_floor: ?[]const u8 = null;
    if (server_head) |h| {
        rev_floor = tx.rawOne([]const u8, scope, "SELECT cutoff_rev::text FROM commits WHERE commit_id = $1::uuid", .{h}) catch return error.Db;
    }

    var last_commit_id: []const u8 = undefined;
    for (req.commits) |commit| {
        if (Uuid.parse(commit.id) == error.InvalidUuid) return error.BadRequest;
        if (commit.changes.len == 0) return error.BadRequest;
        var last_rev: []const u8 = undefined;
        for (commit.changes) |ch| {
            last_rev = if (eql(ch.op, "add"))
                try insertAddRevision(&tx, scope, deps.io, ds, req.branch, rev_floor, ch.path, ch.hash, ch.size, commit.author)
            else
                try insertDeleteRevision(&tx, scope, ds, req.branch, rev_floor, ch.path, commit.author);
            rev_floor = last_rev;
        }

        _ = tx.exec(
            scope,
            "INSERT INTO commits (commit_id, dataset_id, branch, parent_id, cutoff_rev, message, author, authored_at) " ++
                "VALUES ($1::uuid, $2::uuid, $3, $4::uuid, $5::uuid, $6, $7, to_timestamp($8::bigint / 1000.0))",
            .{
                commit.id,
                ds.id,
                req.branch,
                commit.parent,
                last_rev,
                commit.message,
                commit.author,
                @as(i64, @intCast(commit.authored_at_ms)),
            },
        ) catch return error.Db;
        last_commit_id = commit.id;
    }

    _ = tx.exec(
        scope,
        "INSERT INTO refs (dataset_id, name, kind, commit_id) VALUES ($1::uuid, $2, 'branch', $3::uuid) " ++
            "ON CONFLICT (dataset_id, name) DO UPDATE SET commit_id = excluded.commit_id",
        .{ ds.id, req.branch, last_commit_id },
    ) catch return error.Db;
    tx.commit() catch return error.Db;

    queueVersion(deps, scope, ds, last_commit_id);
    noteActivity(arena, deps, scope, caller, ds, "push", last_commit_id, .{ .branch = req.branch, .commits = req.commits.len });
    return json(arena, .ok, .{ .head = last_commit_id, .commits_recorded = req.commits.len });
}

/// How long a provisional state file (some item still waiting for its
/// media metadata) is handed out before it is written again.
const state_provisional_secs = 10 * 60;

/// A version as the CLI downloads it: a gzip file of JSON lines in
/// storage, written by one streamed pass (core/version.zig) and handed
/// out as a presigned URL with its hash, which the client checks as it
/// reads (invariant 14). Written once per version and kept; a version
/// whose media metadata is still arriving gets a provisional file,
/// written again after a while, so dimensions are never frozen blank.
/// The server's memory stays one batch deep at any size.
fn versionFile(arena: std.mem.Allocator, deps: *Deps, scope: anytype, ds: Dataset, commit_id: []const u8, route: DatasetRoute) HandleError!Response {
    if (Uuid.parse(commit_id) == error.InvalidUuid)
        return errorResponse(arena, .bad_request, "that is not a commit id", "Run 'cid log' to list commits.");
    const kind = std.meta.stringToEnum(bundle_mod.Kind, (try param(arena, route, "kind")) orelse "state") orelse
        return errorResponse(arena, .bad_request, "no such export format", "Use one of: files, jsonl, yolo.");
    if (kind != .state and !eql(ds.kind, "annotated"))
        return errorResponse(arena, .bad_request, "only annotated datasets have exports", "Clone it as files.");
    // The subset, canonical: sorted lists, so the same subset is one file.
    const splits = try sortedCopy(arena, try paramAll(arena, route, "split"));
    const classes = try sortedCopy(arena, try paramAll(arena, route, "class"));
    const mine = deps.db.rawOne(i64, scope, "SELECT 1::bigint FROM commits WHERE commit_id = $1::uuid AND dataset_id = $2::uuid", .{ commit_id, ds.id }) catch return error.Db;
    if (mine == null) return errorResponse(arena, .not_found, "no such commit in this dataset", "Run 'cid log' to list commits.");

    // How many items the version holds before any subset (clone says "N of M").
    const total = (versions.stats(arena, deps.db, scope, ds.id, commit_id) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Db,
    }).items;
    const file = switch (try ensureVersionFile(arena, deps, scope, ds, commit_id, kind, .{ .splits = splits, .classes = classes })) {
        .ready => |f| f,
        .failed => |f| return json(arena, .unprocessable_entity, .{
            .@"error" = try std.fmt.allocPrint(arena, "the {t} export is impossible: {s}: {s}", .{ kind, f.path, f.why }),
            .next = "Fix that item in the annotation platform, commit, then run the command again; or clone with --format jsonl.",
            .path = f.path,
        }),
    };
    const url = deps.s3.presignGet(scope, file.key, presign_secs) catch return error.Storage;
    return json(arena, .ok, .{ .commit = commit_id, .url = url, .hash = file.file_hash, .final = file.final, .total = total });
}

const VersionFile = union(enum) {
    ready: struct { key: []const u8, file_hash: []const u8, final: bool },
    failed: bundle_mod.Failure,
};

/// A version file in storage, kept or written now: one streamed pass →
/// gzip → hashed → a file in the work folder → storage, named by its own
/// hash (the same content is the same object). What a request asks
/// for, and what the background worker prepares before anyone asks.
fn ensureVersionFile(arena: std.mem.Allocator, deps: *Deps, scope: anytype, ds: Dataset, commit_id: []const u8, kind: bundle_mod.Kind, subset: bundle_mod.Subset) HandleError!VersionFile {
    const subset_key = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{ .splits = subset.splits, .classes = subset.classes }, .{})});
    const Kept = struct {
        pub const nilo_table = .projection;
        file_hash: []const u8,
        final: bool,
        fresh: bool,
    };
    const kept = deps.db.rawOne(Kept, scope, "SELECT file_hash, final, " ++
        "built_at > now() - interval '" ++ std.fmt.comptimePrint("{d}", .{state_provisional_secs}) ++ " seconds' AS fresh " ++
        "FROM version_files WHERE commit_id = $1::uuid AND kind = $2 AND subset = $3", .{ commit_id, @tagName(kind), subset_key }) catch return error.Db;
    if (kept) |k| if (k.final or k.fresh)
        return .{ .ready = .{ .key = try fileKey(arena, ds.id, commit_id, kind, subset_key, k.file_hash), .file_hash = k.file_hash, .final = k.final } };

    const path = try std.fmt.allocPrint(arena, "{s}/{s}-{t}-{s}.gz", .{ deps.work_dir, commit_id, kind, (try subsetHash(arena, subset_key))[0..16] });
    const gz = try GzFile.open(deps, path);
    defer gz.close(deps);
    const outcome = bundle_mod.build(deps.gpa, deps.db, scope, ds.id, commit_id, kind, subset, gz.writer()) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.WriteFailed => error.Storage,
        else => error.Db,
    };
    const written = switch (outcome) {
        .written => |w| w,
        .failed => |f| {
            defer deps.gpa.free(f.path);
            return .{ .failed = .{ .path = try arena.dupe(u8, f.path), .why = f.why } };
        },
    };
    const file_hash = try arena.dupe(u8, &(try gz.finish()));
    const final = !written.media_pending;
    const key = try fileKey(arena, ds.id, commit_id, kind, subset_key, file_hash);
    if (!(kept != null and eql(kept.?.file_hash, file_hash)))
        deps.s3.putFile(scope, deps.io, key, path) catch return error.Storage;
    _ = deps.db.exec(scope, "INSERT INTO version_files (commit_id, kind, subset, file_hash, final) VALUES ($1::uuid, $2, $3, $4, $5) " ++
        "ON CONFLICT (commit_id, kind, subset) DO UPDATE SET file_hash = excluded.file_hash, final = excluded.final, built_at = now()", .{ commit_id, @tagName(kind), subset_key, file_hash, final }) catch return error.Db;
    return .{ .ready = .{ .key = key, .file_hash = file_hash, .final = final } };
}

fn sortedCopy(arena: std.mem.Allocator, list: []const []const u8) HandleError![]const []const u8 {
    const out = try arena.dupe([]const u8, list);
    std.mem.sort([]const u8, out, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    return out;
}

fn subsetHash(arena: std.mem.Allocator, subset_key: []const u8) HandleError![]const u8 {
    return arena.dupe(u8, &content_hash.hex(subset_key));
}

/// states/… for a version's items, exports/… for an export
/// (CLAUDE.md, storage layout); subset and content named by hash.
fn fileKey(arena: std.mem.Allocator, dataset_id: []const u8, commit_id: []const u8, kind: bundle_mod.Kind, subset_key: []const u8, file_hash: []const u8) HandleError![]const u8 {
    const sub = (try subsetHash(arena, subset_key))[0..16];
    return switch (kind) {
        .state => std.fmt.allocPrint(arena, "states/{s}/{s}-{s}-{s}.jsonl.gz", .{ dataset_id, commit_id, sub, file_hash[0..16] }),
        .jsonl, .yolo => std.fmt.allocPrint(arena, "exports/{s}/{s}/{t}-{s}-{s}.jsonl.gz", .{ dataset_id, commit_id, kind, sub, file_hash[0..16] }),
    };
}

/// A gzip file of JSON lines being written in the work folder, its hash
/// taken over the compressed bytes as they go out: the shape of every
/// large answer the CLI downloads (a version, a diff).
const GzFile = struct {
    path: []const u8,
    file: std.Io.File,
    fw: std.Io.File.Writer,
    hashed: std.Io.Writer.Hashed(content_hash.Hasher),
    gz: std.compress.flate.Compress,
    file_buf: [64 * 1024]u8,
    hash_buf: [64 * 1024]u8,
    window: [std.compress.flate.max_window_len]u8,

    fn open(deps: *Deps, path: []const u8) HandleError!*GzFile {
        const cwd = std.Io.Dir.cwd();
        cwd.createDirPath(deps.io, deps.work_dir) catch return error.Storage;
        const self = deps.gpa.create(GzFile) catch return error.OutOfMemory;
        errdefer deps.gpa.destroy(self);
        self.path = path;
        self.file = cwd.createFile(deps.io, path, .{ .truncate = true }) catch return error.Storage;
        self.fw = self.file.writer(deps.io, &self.file_buf);
        self.hashed = self.fw.interface.hashed(content_hash.init(), &self.hash_buf);
        self.gz = std.compress.flate.Compress.init(&self.hashed.writer, &self.window, .gzip, .level_1) catch {
            self.file.close(deps.io);
            return error.Storage;
        };
        return self;
    }

    fn writer(self: *GzFile) *std.Io.Writer {
        return &self.gz.writer;
    }

    fn finish(self: *GzFile) HandleError![64]u8 {
        self.gz.finish() catch return error.Storage;
        self.hashed.writer.flush() catch return error.Storage;
        self.fw.interface.flush() catch return error.Storage;
        return content_hash.hexOf(&self.hashed.hasher);
    }

    /// Closes and removes the file (it has gone to storage, or failed).
    fn close(self: *GzFile, deps: *Deps) void {
        self.file.close(deps.io);
        std.Io.Dir.cwd().deleteFile(deps.io, self.path) catch {};
        deps.gpa.destroy(self);
    }
};

/// What changed from one version to another, as the CLI reads it (`cid
/// diff`): DuckDB joins the two versions' browse indexes (0.5 s at 1M
/// items), the change lines are kept in storage as a gzip file with its
/// hash, and handed out presigned with the summary counts. Both
/// versions are sealed, so a diff is written once and kept.
fn compare(arena: std.mem.Allocator, deps: *Deps, scope: anytype, ds: Dataset, pair: []const u8) HandleError!Response {
    const slash = std.mem.indexOfScalar(u8, pair, '/') orelse return error.BadRequest;
    const a = pair[0..slash];
    const b = pair[slash + 1 ..];
    if (Uuid.parse(a) == error.InvalidUuid or Uuid.parse(b) == error.InvalidUuid)
        return errorResponse(arena, .bad_request, "those are not commit ids", "Run 'cid log' to list commits.");
    const Kept = struct {
        pub const nilo_table = .projection;
        file_hash: []const u8,
        summary: []const u8,
    };
    if (deps.db.rawOne(Kept, scope, "SELECT file_hash, summary::text AS summary FROM version_diffs WHERE commit_a = $1::uuid AND commit_b = $2::uuid AND dataset_id = $3::uuid", .{ a, b, ds.id }) catch return error.Db) |kept| {
        const url = deps.s3.presignGet(scope, try diffKey(arena, ds.id, a, b, kept.file_hash), presign_secs) catch return error.Storage;
        return json(arena, .ok, .{ .url = url, .hash = kept.file_hash, .summary = jsonValue(arena, kept.summary) });
    }

    // Both versions' indexes, joined by DuckDB into change lines (items by
    // path, annotations by item path), then gzipped into one file here.
    const ia = switch (try indexFor(arena, deps, scope, ds, a)) {
        .ready => |ix| ix,
        .refused => |res| return res,
    };
    const ib = switch (try indexFor(arena, deps, scope, ds, b)) {
        .ready => |ix| ix,
        .refused => |res| return res,
    };
    const lines: browse_mod.CompareFiles = .{
        .items = try std.fmt.allocPrint(arena, "{s}/{s}-{s}.changes.jsonl", .{ ia.dir, a, b }),
        .anns = try std.fmt.allocPrint(arena, "{s}/{s}-{s}.annchanges.jsonl", .{ ia.dir, a, b }),
    };
    const cwd = std.Io.Dir.cwd();
    defer cwd.deleteFile(deps.io, lines.items) catch {};
    defer cwd.deleteFile(deps.io, lines.anns) catch {};
    const d = (try diffIndex(arena, deps, scope, ds, a, b, ia, ib)) orelse
        return errorResponse(arena, .service_unavailable, "the server is indexing another version", "Run 'cid diff' again in a moment.");
    const summary = blk: {
        var db = try duckFor(arena, deps, ia.dir);
        defer db.close();
        break :blk offload(deps, browse_mod.compareLines, .{ arena, &db, d, lines }) catch |err| return duckErr(err);
    };
    const path = try std.fmt.allocPrint(arena, "{s}/{s}-{s}.diff.gz", .{ deps.work_dir, a, b });
    const gz = try GzFile.open(deps, path);
    defer gz.close(deps);
    gz.writer().print("{{\"cid\":\"diff\",\"v\":1,\"a\":\"{s}\",\"b\":\"{s}\"}}\n", .{ a, b }) catch return error.Storage;
    for ([_][]const u8{ lines.items, lines.anns }) |part| {
        var file = cwd.openFile(deps.io, part, .{}) catch return error.Storage;
        defer file.close(deps.io);
        var buf: [64 * 1024]u8 = undefined;
        var fr = file.reader(deps.io, &buf);
        _ = fr.interface.streamRemaining(gz.writer()) catch return error.Storage;
    }
    const file_hash = try gz.finish();
    deps.s3.putFile(scope, deps.io, try diffKey(arena, ds.id, a, b, &file_hash), path) catch return error.Storage;
    const summary_text = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(summary, .{})});
    _ = deps.db.exec(scope, "INSERT INTO version_diffs (dataset_id, commit_a, commit_b, file_hash, summary) VALUES ($1::uuid, $2::uuid, $3::uuid, $4, $5::jsonb) " ++
        "ON CONFLICT DO NOTHING", .{ ds.id, a, b, @as([]const u8, &file_hash), summary_text }) catch return error.Db;
    const url = deps.s3.presignGet(scope, try diffKey(arena, ds.id, a, b, &file_hash), presign_secs) catch return error.Storage;
    return json(arena, .ok, .{ .url = url, .hash = @as([]const u8, &file_hash), .summary = summary });
}

fn diffKey(arena: std.mem.Allocator, dataset_id: []const u8, a: []const u8, b: []const u8, file_hash: []const u8) HandleError![]const u8 {
    return std.fmt.allocPrint(arena, "diffs/{s}/{s}-{s}-{s}.jsonl.gz", .{ dataset_id, a, b, file_hash[0..16] });
}

/// Stored jsonb text → a JSON value for the response (never re-encoded as
/// a string). Unparseable content degrades to null rather than breaking
/// the whole view (one bad record never breaks a view).
fn jsonValue(arena: std.mem.Allocator, text: ?[]const u8) ?std.json.Value {
    const t = text orelse return null;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, t, .{}) catch null;
}

const TagBody = struct {
    name: []const u8,
    /// Defaults to the branch head.
    commit: ?[]const u8 = null,
    branch: []const u8 = "main",
};

/// `cid tag`: a release never moves once this returns (invariant 5).
fn tag(arena: std.mem.Allocator, deps: *Deps, scope: anytype, caller: Caller, ds: Dataset, body: []const u8) HandleError!Response {
    const req = parseBody(TagBody, arena, body) orelse return error.BadRequest;

    const commit_id: []const u8 = blk: {
        if (req.commit) |c| {
            if (Uuid.parse(c) == error.InvalidUuid) return error.BadRequest;
            break :blk c;
        }
        const head_commit = deps.db.rawOne([]const u8, scope, "SELECT commit_id::text FROM refs WHERE dataset_id = $1::uuid AND name = $2 AND kind = 'branch'", .{ ds.id, req.branch }) catch return error.Db;
        break :blk head_commit orelse
            return errorResponse(arena, .unprocessable_entity, "nothing to tag: the branch has no commits", "Run 'cid push' first, then 'cid tag' again.");
    };

    // The server writes the release's browse index lines in the same
    // pass as its manifest: the version is read from history once.
    var work: release_mod.Work = .{ .gpa = deps.gpa, .io = deps.io, .dir = deps.work_dir };
    var index_files: ?browse_mod.Files = null;
    var lines: ?*Lines = null;
    // Already built (someone browsed the commit before it was released):
    // only its copy in storage is missing.
    var cached: ?browse_mod.Files = null;
    defer if (lines) |l| deps.gpa.destroy(l);
    prepared: {
        const cwd = std.Io.Dir.cwd();
        cwd.createDirPath(deps.io, deps.browse_dir) catch break :prepared;
        const dir = cwd.realPathFileAlloc(deps.io, deps.browse_dir, arena) catch break :prepared;
        const files = browse_mod.Files.of(arena, dir, commit_id) catch return error.OutOfMemory;
        if (cwd.statFile(deps.io, files.items, .{})) |_| {
            cached = files;
            break :prepared;
        } else |_| {}
        // The one build slot, as every index build takes it: a build of
        // this very commit may be under way (the worker started on it
        // after the push), and then it finishes the index instead.
        if (deps.browse_building.swap(true, .acquire)) break :prepared;
        deps.browse_building_commit.store(std.mem.readInt(u64, (Uuid.parse(commit_id) catch return error.BadRequest).bytes[8..16], .big), .release);
        const build = files.forBuild(arena, deps.io) catch return error.OutOfMemory;
        lines = openLines(deps, build) catch {
            releaseSlot(deps);
            break :prepared;
        };
        index_files = build;
        work.items = lines.?.items();
        work.annotations = lines.?.anns();
    }
    const created = release_mod.create(arena, work, deps.db, scope, deps.s3, ds.id, req.name, commit_id) catch |err| {
        if (lines) |l| {
            l.discard(deps, index_files.?);
            releaseSlot(deps);
        }
        return switch (err) {
            error.BadName => errorResponse(arena, .bad_request, "that is not a release name (letters, digits, dot, dash, underscore)", "Pick a name like v1.0.0 and run 'cid tag' again."),
            error.ReleaseExists => errorResponse(arena, .conflict, "that release already exists and releases never move", "Pick a new name, e.g. the next version number."),
            error.NoSuchCommit => errorResponse(arena, .not_found, "no such commit in this dataset", "Run 'cid log' to list commits."),
            error.BadAnnotationText => errorResponse(arena, .unprocessable_entity, "an annotation carries text or JSON the manifest cannot hold", "Fix the offending annotation in the platform, commit, then tag again."),
            error.Storage => error.Storage,
            error.OutOfMemory => error.OutOfMemory,
            error.Db => error.Db,
        };
    };
    // The release stands; its git copy is queued and attempted right away
    // when configured. A git failure never blocks the release (invariant 21).
    _ = deps.db.exec(
        scope,
        "INSERT INTO git_writes (dataset_id, release, status) VALUES ($1::uuid, $2, 'pending') " ++
            "ON CONFLICT (dataset_id, release) DO NOTHING",
        .{ ds.id, created.name },
    ) catch return error.Db;
    var git_status: []const u8 = "pending";
    if (deps.git) |git_config| {
        const outcome = git_writer.processDataset(arena, deps.io, deps.db, scope, git_config, ds.name) catch
            git_writer.Outcome{ .failed = 1 };
        git_status = if (outcome.failed == 0) "done" else "failed";
    }

    // The release's browse index: its lines came with the manifest's pass;
    // converted now, so the first visitor does not wait, and kept in
    // storage beside the manifest. Derived data: a failure here never
    // fails the release, and browsing rebuilds it.
    if (lines) |l| {
        l.close(deps);
        defer releaseSlot(deps);
        if (convertLines(arena, deps, index_files.?)) |_| {
            storeBrowseIndex(arena, deps, scope, ds, created.commit_id, index_files.?);
            pruneBrowse(arena, deps, std.fs.path.dirname(index_files.?.items) orelse deps.browse_dir);
        } else |_| std.log.warn("browse: the new release's index was not built; browsing will build it", .{});
    }
    if (cached) |files| storeBrowseIndex(arena, deps, scope, ds, created.commit_id, files);
    queueVersion(deps, scope, ds, created.commit_id);
    noteActivity(arena, deps, scope, caller, ds, "tag", created.name, .{ .items = created.items });
    return json(arena, .created, .{
        .release = created.name,
        .commit = @as([]const u8, created.commit_id),
        .manifest_hash = &created.manifest_hash,
        .items = created.items,
        .git = git_status,
    });
}

fn releases(arena: std.mem.Allocator, deps: *Deps, scope: anytype, ds: Dataset) HandleError!Response {
    const Entry = struct {
        pub const nilo_table = .projection;
        name: []const u8,
        commit: []const u8,
        manifest_hash: []const u8,
    };
    const list = deps.db.raw(Entry, scope, "SELECT name, commit_id::text AS commit, encode(manifest_hash, 'hex') AS manifest_hash FROM refs " ++
        "WHERE dataset_id = $1::uuid AND kind = 'release' ORDER BY commit_id DESC", .{ds.id}) catch return error.Db;
    return json(arena, .ok, .{ .releases = list });
}

/// Presigned URLs for thumbnails that already exist. Never a trigger:
/// a hash with no finished preview is simply absent from the answer and
/// the page shows a placeholder (the structural ffmpeg guarantee).
fn thumbs(arena: std.mem.Allocator, deps: *Deps, scope: anytype, ds: Dataset, body: []const u8) HandleError!Response {
    const req = parseBody(HashesBody, arena, body) orelse return error.BadRequest;
    if (req.hashes.len > 1000) return error.BadRequest;
    const Thumb = struct { hash: []const u8, url: []const u8 };
    var list: std.ArrayList(Thumb) = .empty;
    for (req.hashes) |hash| {
        if (!validHashHex(hash)) return error.BadRequest;
        // A restricted dataset is answered with the blurred rendition and
        // nothing else (invariant 20): a missing blur is an absent preview,
        // never the clear one in its place. The clear one is /reveal's.
        const done = deps.db.rawOne(i64, scope, "SELECT 1::bigint FROM previews WHERE item_hash = decode($1, 'hex') AND status = 'done' AND (blurred OR NOT $2)", .{ hash, ds.restricted }) catch return error.Db;
        if (done == null) continue;
        const key = (if (ds.restricted) preview_worker.blurKey(arena, hash) else preview_worker.thumbKey(arena, hash)) catch return error.OutOfMemory;
        const url = deps.s3.presignGet(scope, key, presign_secs) catch return error.Storage;
        try list.append(arena, .{ .hash = hash, .url = url });
    }
    return json(arena, .ok, .{ .thumbs = list.items });
}

fn downloads(arena: std.mem.Allocator, deps: *Deps, scope: anytype, caller: Caller, ds: Dataset, body: []const u8) HandleError!Response {
    const req = parseBody(HashesBody, arena, body) orelse return error.BadRequest;
    if (req.hashes.len > 1000) return error.BadRequest;
    // Clear bytes of a restricted dataset are content too: every batch
    // handed out — a CLI clone, a reveal's download — is on the record
    // before the URLs exist (invariant 20).
    if (ds.restricted) try logActivity(arena, deps, scope, ds, try actorOf(arena, deps, caller), "download", null, .{ .items = req.hashes.len });
    var set: std.ArrayList(u8) = .empty;
    try set.append(arena, '{');
    for (req.hashes, 0..) |hash, i| {
        if (!validHashHex(hash)) return error.BadRequest;
        if (i > 0) try set.append(arena, ',');
        try set.appendSlice(arena, hash);
    }
    try set.append(arena, '}');
    // Bytes cleanup took (not in any release or branch head) are said so,
    // not handed out as links that answer 404.
    const collected = deps.db.rawOne(i64, scope, "SELECT count(*)::bigint FROM collected_items " ++
        "WHERE item_hash IN (SELECT decode(h, 'hex') FROM unnest($1::text[]) h)", .{set.items}) catch return error.Db;
    if (collected.? > 0) return errorResponse(arena, .gone, try std.fmt.allocPrint(arena, "{d} file{s} of this version {s} cleaned up from storage: it is in no release and no branch head", .{
        collected.?, if (collected.? == 1) "" else "s", if (collected.? == 1) "was" else "were",
    }), "Run 'cid log' and check out a release or a branch instead.");
    const Download = struct { hash: []const u8, url: []const u8 };
    const list = try arena.alloc(Download, req.hashes.len);
    for (req.hashes, 0..) |hash, i| {
        const key = itemKey(arena, hash) catch return error.OutOfMemory;
        const url = deps.s3.presignGet(scope, key, presign_secs) catch return error.Storage;
        list[i] = .{ .hash = hash, .url = url };
    }
    return json(arena, .ok, .{ .downloads = list });
}

fn insertAddRevision(
    tx: anytype,
    scope: anytype,
    io: std.Io,
    ds: Dataset,
    branch: []const u8,
    floor: ?[]const u8,
    path: []const u8,
    hash: []const u8,
    size: u64,
    author: []const u8,
) HandleError![]const u8 {
    _ = tx.exec(
        scope,
        "INSERT INTO items (item_hash, size_bytes, media_type) " ++
            "VALUES (decode($1, 'hex'), $2::bigint, 'application/octet-stream') " ++
            "ON CONFLICT (item_hash) DO UPDATE SET touched_at = now()",
        .{ hash, @as(i64, @intCast(size)) },
    ) catch return error.Db;
    // The upsert holds the row cleanup locks (core/gc.zig): collected now
    // means the bytes went after this push admitted them.
    if ((tx.rawOne(i64, scope, collected_sql, .{hash}) catch return error.Db) != null) return error.Collected;
    _ = tx.exec(scope, held_sql, .{ ds.id, hash }) catch return error.Db;
    try enqueuePreview(tx, scope, hash);
    // Item identity: new path → new item_id; existing path keeps its id.
    // On a branch, the path may live on main as of the branch start.
    const Landed = struct {
        pub const nilo_table = .projection;
        rev: []const u8,
        item_id: []const u8,
    };
    const landed = (tx.rawOne(
        Landed,
        scope,
        "INSERT INTO item_revisions (rev_id, dataset_id, branch, path, op, item_id, item_hash, split, author) " ++
            "SELECT cid_rev_after($1::uuid), $2::uuid, $3, $4, " ++
            "  CASE WHEN prev.item_id IS NULL THEN 'add' ELSE 'update' END, " ++
            "  COALESCE(prev.item_id, $5::uuid), decode($6, 'hex'), NULL, $7 " ++
            "FROM (SELECT 1) one LEFT JOIN LATERAL (" ++
            "  SELECT item_id FROM item_revisions " ++
            "  WHERE dataset_id = $2::uuid AND branch IN ('main', $3) AND path = $4 AND op <> 'delete' " ++
            "  ORDER BY rev_id DESC LIMIT 1) prev ON true " ++
            "RETURNING rev_id::text AS rev, item_id::text AS item_id",
        .{ floor, ds.id, branch, path, @as([]const u8, &Uuid.now(io).toString()), hash, author },
    ) catch return error.Db) orelse return error.Db;
    _ = tx.exec(scope, "INSERT INTO dataset_items (item_id, dataset_id) VALUES ($1::uuid, $2::uuid) ON CONFLICT (item_id) DO NOTHING", .{ landed.item_id, ds.id }) catch return error.Db;
    return landed.rev;
}

fn insertDeleteRevision(
    tx: anytype,
    scope: anytype,
    ds: Dataset,
    branch: []const u8,
    floor: ?[]const u8,
    path: []const u8,
    author: []const u8,
) HandleError![]const u8 {
    return (tx.rawOne(
        []const u8,
        scope,
        "INSERT INTO item_revisions (rev_id, dataset_id, branch, path, op, item_id, item_hash, split, author) " ++
            "VALUES (cid_rev_after($1::uuid), $2::uuid, $3, $4, 'delete', NULL, NULL, NULL, $5) RETURNING rev_id::text",
        .{ floor, ds.id, branch, path, author },
    ) catch return error.Db) orelse error.Db;
}

/// Invariant 3's backstop, checked as a commit is about to be recorded
/// (under the branch's exclusive lock): no revision landed at or under
/// the head commit's cutoff after that commit was sealed. Revision times
/// are set by the database (writers cannot), so this is exact for every
/// writer; it answers the refusal to send, or null.
fn sealBroken(arena: std.mem.Allocator, tx: anytype, scope: anytype, ds: Dataset, head_commit: ?[]const u8) HandleError!?Response {
    const sealed = head_commit orelse return null;
    const late = (tx.rawOne(i64, scope, "SELECT (SELECT count(*) FROM item_revisions r WHERE r.dataset_id = c.dataset_id AND r.branch = c.branch " ++
        "  AND r.ts > c.recorded_at AND r.rev_id <= c.cutoff_rev) + " ++
        "(SELECT count(*) FROM annotation_revisions a WHERE a.dataset_id = c.dataset_id AND a.branch = c.branch " ++
        "  AND a.ts > c.recorded_at AND a.rev_id <= c.cutoff_rev) FROM commits c WHERE c.commit_id = $1::uuid", .{sealed}) catch return error.Db) orelse 0;
    if (late == 0) return null;
    // Warn, not err: the refusal itself carries it to the caller, and the
    // test that provokes it must not read as a failure.
    std.log.warn("dataset {s}: {d} revision(s) landed under the sealed cutoff of commit {s} (invariant 3); nothing more is recorded on the branch", .{ ds.name, late, sealed });
    return errorResponse(arena, .internal_server_error, try std.fmt.allocPrint(arena, "{d} revision(s) landed under commit {s} after it was sealed; history would change, so nothing more is recorded on this branch", .{ late, sealed }), "Tell the administrator: run 'cid admin verify' on this dataset's releases and find the writer that set its own revision ids.");
}

const BranchBody = struct { name: []const u8 };

/// `cid branch <name>`: a draft line of work, always starting from main
/// (invariant 8), recording where it started.
fn branchCreate(arena: std.mem.Allocator, deps: *Deps, scope: anytype, caller: Caller, ds: Dataset, body: []const u8) HandleError!Response {
    const req = parseBody(BranchBody, arena, body) orelse return error.BadRequest;
    if (!release_mod.validName(req.name) or eql(req.name, "main"))
        return errorResponse(arena, .bad_request, "that is not a branch name (letters, digits, dot, dash, underscore; not 'main')", "Pick a name like cleanup and run 'cid branch' again.");

    const existing = deps.db.rawOne(i64, scope, "SELECT 1::bigint FROM refs WHERE dataset_id = $1::uuid AND name = $2", .{ ds.id, req.name }) catch return error.Db;
    if (existing != null)
        return errorResponse(arena, .conflict, "that name is taken", "Run 'cid checkout' to work on it, or pick another name.");

    const main_head = (deps.db.rawOne([]const u8, scope, "SELECT commit_id::text FROM refs WHERE dataset_id = $1::uuid AND name = 'main' AND kind = 'branch'", .{ds.id}) catch return error.Db) orelse
        return errorResponse(arena, .unprocessable_entity, "main has no commits yet", "Run 'cid push' first, then 'cid branch' again.");

    _ = deps.db.exec(
        scope,
        "INSERT INTO refs (dataset_id, name, kind, commit_id, start_commit_id) " ++
            "VALUES ($1::uuid, $2, 'branch', $3::uuid, $3::uuid)",
        .{ ds.id, req.name, main_head },
    ) catch return error.Db;
    noteActivity(arena, deps, scope, caller, ds, "branch", req.name, null);
    return json(arena, .created, .{ .branch = req.name, .start = main_head });
}

fn branches(arena: std.mem.Allocator, deps: *Deps, scope: anytype, ds: Dataset) HandleError!Response {
    const Entry = struct {
        pub const nilo_table = .projection;
        name: []const u8,
        commit: []const u8,
    };
    const list = deps.db.raw(Entry, scope, "SELECT name, commit_id::text AS commit FROM refs WHERE dataset_id = $1::uuid AND kind = 'branch' ORDER BY name", .{ds.id}) catch return error.Db;
    return json(arena, .ok, .{ .branches = list });
}

/// `resolve`: a person's decision for paths the merge listed as conflicts
/// — "main" keeps main's version, "branch" takes the branch's. A conflict
/// without one is still listed (invariant 9: nothing is decided silently).
const MergeBody = struct {
    name: []const u8,
    author: []const u8 = "user:unknown",
    resolve: []const struct { path: []const u8, take: []const u8 } = &.{},
};

/// `cid merge <name>` into main. Overlapping changes stop the merge and
/// are listed; nothing is resolved silently (invariant 9).
fn merge(arena: std.mem.Allocator, deps: *Deps, scope: anytype, caller: Caller, ds: Dataset, body: []const u8) HandleError!Response {
    const req = parseBody(MergeBody, arena, body) orelse return error.BadRequest;

    const BranchRef = struct {
        pub const nilo_table = .projection;
        commit_id: []const u8,
        start_commit_id: []const u8,
    };
    const branch_ref = deps.db.rawOne(BranchRef, scope, "SELECT commit_id::text AS commit_id, start_commit_id::text AS start_commit_id FROM refs " ++
        "WHERE dataset_id = $1::uuid AND name = $2 AND kind = 'branch'", .{ ds.id, req.name }) catch return error.Db;
    if (branch_ref == null or eql(req.name, "main"))
        return errorResponse(arena, .not_found, "no such branch", "Run 'cid branch <name>' to create one.");
    const branch_head = branch_ref.?.commit_id;
    const branch_start = branch_ref.?.start_commit_id;
    if (eql(branch_head, branch_start))
        return errorResponse(arena, .unprocessable_entity, "the branch has no commits of its own", "Push commits on the branch first, then merge.");

    const main_head = (deps.db.rawOne([]const u8, scope, "SELECT commit_id::text FROM refs WHERE dataset_id = $1::uuid AND name = 'main' AND kind = 'branch'", .{ds.id}) catch return error.Db) orelse return error.Db;

    // Only the paths the branch touched can differ from the base; the
    // three sides of each come from one query (core/version.zig).
    const Cutoff = struct {
        pub const nilo_table = .projection;
        branch: []const u8,
        start: []const u8,
        main: []const u8,
    };
    const cut = (deps.db.rawOne(Cutoff, scope, "SELECT (SELECT cutoff_rev::text FROM commits WHERE commit_id = $1::uuid) AS branch, " ++
        "(SELECT cutoff_rev::text FROM commits WHERE commit_id = $2::uuid) AS start, " ++
        "(SELECT cutoff_rev::text FROM commits WHERE commit_id = $3::uuid) AS main", .{ branch_head, branch_start, main_head }) catch return error.Db) orelse return error.Db;
    const touched = versions.branchPaths(deps.db, scope, ds.id, req.name, cut.branch, cut.start, cut.main) catch return error.Db;

    const BranchChange = union(enum) { add: struct { hash: []const u8, size: u64 }, delete };
    var branch_changes: std.StringArrayHashMapUnmanaged(BranchChange) = .empty;
    var conflicts: std.ArrayList([]const u8) = .empty;
    for (touched) |p| {
        if (optEql(p.theirs, p.base)) continue; // touched, but back where it started
        const main_changed = !optEql(p.ours, p.base);
        if (main_changed) {
            if (optEql(p.theirs, p.ours)) continue; // both sides made the same change
            const decided = for (req.resolve) |r| {
                if (eql(r.path, p.path)) break r.take;
            } else null;
            const take = decided orelse {
                try conflicts.append(arena, p.path);
                continue;
            };
            if (eql(take, "main")) continue; // main's version stays
            if (!eql(take, "branch")) return error.BadRequest;
        }
        try branch_changes.put(arena, p.path, if (p.theirs) |h|
            .{ .add = .{ .hash = h, .size = @intCast(p.theirs_size orelse 0) } }
        else
            .delete);
    }
    if (conflicts.items.len > 0)
        return json(arena, .conflict, .{ .conflicts = conflicts.items });
    if (branch_changes.count() == 0)
        return errorResponse(arena, .unprocessable_entity, "main already has everything from the branch", "Nothing to merge; run 'cid pull' to update your folder.");

    var tx = deps.db.begin(scope, .{}) catch return error.Db;
    defer tx.deinit();
    _ = tx.exec(
        scope,
        "SELECT pg_advisory_xact_lock(hashtextextended($1 || '/main', 0))",
        .{ds.id},
    ) catch return error.Db;

    if (try sealBroken(arena, &tx, scope, ds, main_head)) |res| return res;
    var rev_floor: ?[]const u8 = tx.rawOne([]const u8, scope, "SELECT cutoff_rev::text FROM commits WHERE commit_id = $1::uuid", .{main_head}) catch return error.Db;
    for (branch_changes.keys(), branch_changes.values()) |path, change| {
        rev_floor = switch (change) {
            .add => |a| try insertAddRevision(&tx, scope, deps.io, ds, "main", rev_floor, path, a.hash, a.size, req.author),
            .delete => try insertDeleteRevision(&tx, scope, ds, "main", rev_floor, path, req.author),
        };
    }
    const last_rev = rev_floor.?;

    const merge_id = Uuid.nextAfter(deps.io, Uuid.parse(main_head) catch null);
    const message = try std.fmt.allocPrint(arena, "Merge branch '{s}'", .{req.name});
    _ = tx.exec(
        scope,
        "INSERT INTO commits (commit_id, dataset_id, branch, parent_id, merge_parent_id, cutoff_rev, message, author, authored_at) " ++
            "VALUES ($1::uuid, $2::uuid, 'main', $3::uuid, $4::uuid, $5::uuid, $6, $7, now())",
        .{
            @as([]const u8, &merge_id.toString()),
            ds.id,
            main_head,
            branch_head,
            last_rev,
            message,
            req.author,
        },
    ) catch return error.Db;
    _ = tx.exec(
        scope,
        "UPDATE refs SET commit_id = $2::uuid WHERE dataset_id = $1::uuid AND name = 'main' AND kind = 'branch'",
        .{ ds.id, @as([]const u8, &merge_id.toString()) },
    ) catch return error.Db;
    tx.commit() catch return error.Db;

    queueVersion(deps, scope, ds, &merge_id.toString());
    noteActivity(arena, deps, scope, caller, ds, "merge", req.name, .{ .changes = branch_changes.count() });
    return json(arena, .ok, .{ .merge_commit = &merge_id.toString(), .changes = branch_changes.count() });
}

const RegisterItemsBody = struct {
    items: []const struct {
        hash: []const u8,
        size: u64,
        media_type: []const u8 = "application/octet-stream",
        width: ?u32 = null,
        height: ?u32 = null,
    },
};

/// The platform's item registration: after uploading through the
/// presigned URLs from check-hashes, this verifies each object is really
/// in storage with the right size, then records the items row (invariant
/// 2 keeps one enforcement point: bytes always enter through the server's
/// upload flow).
fn registerItems(arena: std.mem.Allocator, deps: *Deps, scope: anytype, ds: Dataset, body: []const u8) HandleError!Response {
    const req = parseBody(RegisterItemsBody, arena, body) orelse return error.BadRequest;
    if (req.items.len > 1000) return error.BadRequest;
    var admitted: std.StringHashMapUnmanaged(void) = .empty;
    for (req.items) |item| {
        if (!validHashHex(item.hash)) return error.BadRequest;
        if (try isPurged(deps.db, scope, item.hash))
            return errorResponse(arena, .unprocessable_entity, "that content was purged and cannot come back", "Remove or replace the file, then register again.");
        if (!admitted.contains(item.hash)) switch (try admit(arena, deps, scope, ds, item.hash, item.size)) {
            .admitted => try admitted.put(arena, item.hash, {}),
            .missing => return errorResponse(arena, .unprocessable_entity, "an item is missing from storage", "Upload it through the check-hashes URLs first, then register again."),
            .mismatch => return errorResponse(arena, .unprocessable_entity, "an uploaded item does not match its hash or size", "Re-upload the file, then register again."),
        };
        const meta = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{
            .width = item.width,
            .height = item.height,
        }, .{ .emit_null_optional_fields = false })});
        _ = deps.db.exec(
            scope,
            "INSERT INTO items (item_hash, size_bytes, media_type, meta) VALUES (decode($1, 'hex'), $2::bigint, $3, $4::jsonb) " ++
                "ON CONFLICT (item_hash) DO UPDATE SET meta = items.meta || excluded.meta, touched_at = now()",
            .{ item.hash, @as(i64, @intCast(item.size)), item.media_type, meta },
        ) catch return error.Db;
        if ((deps.db.rawOne(i64, scope, collected_sql, .{item.hash}) catch return error.Db) != null) return error.Collected;
        _ = deps.db.exec(scope, held_sql, .{ ds.id, item.hash }) catch return error.Db;
        try enqueuePreview(deps.db, scope, item.hash);
    }
    return json(arena, .ok, .{ .registered = req.items.len });
}

const PolicyBody = struct {
    version: []const u8,
    body: std.json.Value,
};

/// Annotated datasets: the platform records each labelling-policy version
/// here; annotation revisions reference it by name. Versions never change
/// once written (the policy a box was made under is history).
fn policyCreate(arena: std.mem.Allocator, deps: *Deps, scope: anytype, ds: Dataset, body: []const u8) HandleError!Response {
    const req = parseBody(PolicyBody, arena, body) orelse return error.BadRequest;
    if (req.version.len == 0 or req.version.len > 100) return error.BadRequest;
    const existing = deps.db.rawOne(i64, scope, "SELECT 1::bigint FROM policy_versions WHERE dataset_id = $1::uuid AND version = $2", .{ ds.id, req.version }) catch return error.Db;
    if (existing != null)
        return errorResponse(arena, .conflict, "that policy version already exists and never changes", "Record a new version instead.");
    const body_json = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(req.body, .{})});
    _ = deps.db.exec(
        scope,
        "INSERT INTO policy_versions (dataset_id, version, body) VALUES ($1::uuid, $2, $3::jsonb)",
        .{ ds.id, req.version, body_json },
    ) catch return error.Db;
    return json(arena, .created, .{ .version = req.version });
}

/// The dataset card: the human-written fields (an object of text). Each
/// release keeps a snapshot (`refs.card`), so editing never changes what
/// an earlier release renders.
fn cardGet(arena: std.mem.Allocator, deps: *Deps, scope: anytype, ds: Dataset) HandleError!Response {
    const body = deps.db.rawOne([]const u8, scope, "SELECT body::text FROM dataset_cards WHERE dataset_id = $1::uuid", .{ds.id}) catch return error.Db;
    return json(arena, .ok, .{ .card = if (body) |b| jsonValue(arena, b) else null });
}

const card_max_bytes = 64 * 1024;

/// Owners only (invariant 17): the route needs the maintain level.
fn cardPut(arena: std.mem.Allocator, deps: *Deps, scope: anytype, caller: Caller, ds: Dataset, body: []const u8) HandleError!Response {
    if (body.len > card_max_bytes)
        return errorResponse(arena, .payload_too_large, "a card is at most 64 KB", "Shorten the card, then save it again.");
    const Body = struct { card: std.json.Value };
    const req = parseBody(Body, arena, body) orelse return error.BadRequest;
    if (req.card != .object) return error.BadRequest;
    var it = req.card.object.iterator();
    while (it.next()) |e| {
        if (e.key_ptr.len == 0 or e.key_ptr.len > 64 or e.value_ptr.* != .string)
            return errorResponse(arena, .bad_request, "a card is fields of text: names up to 64 characters, text values", "Fix the card, then save it again.");
    }
    const text = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(req.card, .{})});
    const actor = actorOf(arena, deps, caller) catch "server-token";
    _ = deps.db.exec(scope, "INSERT INTO dataset_cards (dataset_id, body, updated_by) VALUES ($1::uuid, $2::jsonb, $3) " ++
        "ON CONFLICT (dataset_id) DO UPDATE SET body = excluded.body, updated_by = excluded.updated_by, updated_at = now()", .{ ds.id, text, actor }) catch return error.Db;
    noteActivity(arena, deps, scope, caller, ds, "card-edit", null, null);
    return json(arena, .ok, .{ .card = req.card });
}

fn policies(arena: std.mem.Allocator, deps: *Deps, scope: anytype, ds: Dataset) HandleError!Response {
    const Row = struct {
        pub const nilo_table = .projection;
        version: []const u8,
        body: []const u8,
    };
    const rows = deps.db.raw(Row, scope, "SELECT version, body::text AS body FROM policy_versions WHERE dataset_id = $1::uuid ORDER BY created_at", .{ds.id}) catch return error.Db;
    const Entry = struct { version: []const u8, body: ?std.json.Value };
    const list = try arena.alloc(Entry, rows.len);
    for (list, rows) |*e, row| {
        e.* = .{ .version = row.version, .body = jsonValue(arena, row.body) };
    }
    return json(arena, .ok, .{ .policies = list });
}

const ServerCommitBody = struct {
    branch: []const u8 = "main",
    message: []const u8,
    author: []const u8,
};

/// The annotation platform's commit: it has already INSERTed revisions
/// (items and annotations) with the cid_writer role under the shared
/// write lock; this seals them — "all changes up to here" — under the
/// exclusive lock, so no in-flight write can land beneath the cutoff
/// (invariant 3).
fn serverCommit(arena: std.mem.Allocator, deps: *Deps, scope: anytype, caller: Caller, ds: Dataset, body: []const u8) HandleError!Response {
    const req = parseBody(ServerCommitBody, arena, body) orelse return error.BadRequest;
    if (req.message.len == 0 or req.author.len == 0) return error.BadRequest;

    var tx = deps.db.begin(scope, .{}) catch return error.Db;
    defer tx.deinit();
    _ = tx.exec(
        scope,
        "SELECT pg_advisory_xact_lock(hashtextextended($1 || '/' || $2, 0))",
        .{ ds.id, req.branch },
    ) catch return error.Db;

    const parent = tx.rawOne([]const u8, scope, "SELECT commit_id::text FROM refs WHERE dataset_id = $1::uuid AND name = $2 AND kind = 'branch'", .{ ds.id, req.branch }) catch return error.Db;
    if (try sealBroken(arena, &tx, scope, ds, parent)) |res| return res;
    const parent_cutoff: ?[]const u8 = blk: {
        const p = parent orelse break :blk null;
        break :blk tx.rawOne([]const u8, scope, "SELECT cutoff_rev::text FROM commits WHERE commit_id = $1::uuid", .{p}) catch return error.Db;
    };

    // The cutoff: the newest revision on this branch, item or annotation.
    // The database mints each row's id and time from one clock, microseconds
    // apart, so the newest id is among the rows written in the last second
    // before the newest time: two index lookups, however much was written
    // since the parent (a pipeline stage can be millions of rows).
    const floor = parent_cutoff orelse "00000000-0000-0000-0000-000000000000";
    const newer = "rev_id > $3::uuid AND ts >= cid_rev_time($3::uuid) - interval '1 second'";
    // max() answers one row, NULL when nothing is new.
    const latest: ?[]const u8 = (tx.rawOne(?[]const u8, scope, "SELECT max(t)::text FROM (" ++
        "  (SELECT ts AS t FROM item_revisions WHERE dataset_id = $1::uuid AND branch = $2 AND " ++ newer ++ " ORDER BY ts DESC LIMIT 1) " ++
        "  UNION ALL " ++
        "  (SELECT ts FROM annotation_revisions WHERE dataset_id = $1::uuid AND branch = $2 AND " ++ newer ++ " ORDER BY ts DESC LIMIT 1)) x", .{ ds.id, req.branch, floor }) catch return error.Db) orelse null;
    // A separate statement, so the time bound is a constant the planner
    // can take the time index with (passed in one query, it walks the
    // dataset's whole path index instead: 730 ms against 8 at 10M rows).
    const cutoff: ?[]const u8 = if (latest) |t| tx.rawOne([]const u8, scope, "SELECT rev_id::text FROM (" ++
        "  SELECT rev_id FROM item_revisions WHERE dataset_id = $1::uuid AND branch = $2 AND rev_id > $3::uuid AND ts >= $4::timestamptz - interval '1 second' " ++
        "  UNION ALL " ++
        "  SELECT rev_id FROM annotation_revisions WHERE dataset_id = $1::uuid AND branch = $2 AND rev_id > $3::uuid AND ts >= $4::timestamptz - interval '1 second') u " ++
        "ORDER BY rev_id DESC LIMIT 1", .{ ds.id, req.branch, floor, t }) catch return error.Db else null;
    if (cutoff == null) {
        return errorResponse(arena, .unprocessable_entity, "nothing new to commit on this branch", "Write revisions first, then commit again.");
    }

    const commit_id = Uuid.nextAfter(deps.io, if (parent) |p| (Uuid.parse(p) catch null) else null);
    _ = tx.exec(
        scope,
        "INSERT INTO commits (commit_id, dataset_id, branch, parent_id, cutoff_rev, message, author, authored_at) " ++
            "VALUES ($1::uuid, $2::uuid, $3, $4::uuid, $5::uuid, $6, $7, now())",
        .{ @as([]const u8, &commit_id.toString()), ds.id, req.branch, parent, cutoff.?, req.message, req.author },
    ) catch return error.Db;
    _ = tx.exec(
        scope,
        "INSERT INTO refs (dataset_id, name, kind, commit_id) VALUES ($1::uuid, $2, 'branch', $3::uuid) " ++
            "ON CONFLICT (dataset_id, name) DO UPDATE SET commit_id = excluded.commit_id",
        .{ ds.id, req.branch, @as([]const u8, &commit_id.toString()) },
    ) catch return error.Db;
    tx.commit() catch return error.Db;

    queueVersion(deps, scope, ds, &commit_id.toString());
    noteActivity(arena, deps, scope, caller, ds, "commit", req.message, null);
    return json(arena, .created, .{ .commit = &commit_id.toString() });
}

/// One queue row per content hash, ever (ON CONFLICT DO NOTHING): the
/// structural guarantee that preview work scales with ingested content
/// and never with dashboard traffic. No request path builds previews.
/// `q` is the Db, or the enclosing transaction.
fn enqueuePreview(q: anytype, scope: anytype, hash: []const u8) HandleError!void {
    _ = q.exec(
        scope,
        "INSERT INTO previews (item_hash) VALUES (decode($1, 'hex')) ON CONFLICT (item_hash) DO NOTHING",
        .{hash},
    ) catch return error.Db;
}

/// One piece of a large upload, numbered from 1 (zero-padded, so a listing
/// of a file's pieces is in order).
pub fn pieceKey(arena: std.mem.Allocator, dataset_id: []const u8, hash: []const u8, n: u32) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(arena, "uploads/{s}/{s}.part-{d:0>6}", .{ dataset_id, hash, n });
}

/// Which of a file's `count` pieces are staged already: one listing (a page
/// per 1,000 pieces), not a request per piece.
fn stagedPieces(arena: std.mem.Allocator, deps: *Deps, scope: anytype, dataset_id: []const u8, hash: []const u8, count: u32) HandleError![]bool {
    const have = try arena.alloc(bool, count);
    @memset(have, false);
    const prefix = try std.fmt.allocPrint(arena, "uploads/{s}/{s}.part-", .{ dataset_id, hash });
    var cursor: ?[]const u8 = null;
    while (true) {
        const page = deps.s3.list(scope, prefix, cursor) catch return error.Storage;
        for (page.objects) |object| {
            const n = std.fmt.parseInt(u32, object.key.view()[prefix.len..], 10) catch continue;
            if (n >= 1 and n <= count) have[n - 1] = true;
        }
        cursor = if (page.next) |next| try arena.dupe(u8, next.view()) else return have;
    }
}

/// Where a dataset's uploads land before the server verifies them.
pub fn stagedKey(arena: std.mem.Allocator, dataset_id: []const u8, hash: []const u8) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(arena, "uploads/{s}/{s}", .{ dataset_id, hash });
}

/// The hash is this dataset's already and its bytes are stored. Only then
/// is "the server has it" said (invariant 12): content held only by other
/// datasets must be uploaded again — proof of possession — so a hash
/// learned elsewhere opens nothing.
/// Records that this dataset holds these (admitted) bytes.
const held_sql = "INSERT INTO dataset_hashes (dataset_id, item_hash) VALUES ($1::uuid, decode($2, 'hex')) ON CONFLICT DO NOTHING";

fn heldHere(arena: std.mem.Allocator, deps: *Deps, scope: anytype, ds: Dataset, hash: []const u8) HandleError!bool {
    const here = deps.db.rawOne(i64, scope, "SELECT 1::bigint FROM dataset_hashes WHERE dataset_id = $1::uuid AND item_hash = decode($2, 'hex')", .{ ds.id, hash }) catch return error.Db;
    if (here == null) return false;
    const collected = deps.db.rawOne(i64, scope, collected_sql, .{hash}) catch return error.Db;
    if (collected != null) return false;
    return (deps.s3.headObject(scope, itemKey(arena, hash) catch return error.OutOfMemory) catch return error.Storage) != null;
}

const Admit = enum { admitted, missing, mismatch };

/// Admits an item's bytes (invariant 2): held here already, or uploaded to
/// this dataset's staging area — then streamed through the content hash into a
/// work file, and only if they match (and the size, when one is claimed) stored
/// under the item's key, if absent. The staged copy goes either way.
fn admit(arena: std.mem.Allocator, deps: *Deps, scope: anytype, ds: Dataset, hash: []const u8, size: ?u64) HandleError!Admit {
    if (try heldHere(arena, deps, scope, ds, hash)) return .admitted;
    const staged = try stagedKey(arena, ds.id, hash);
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(deps.io, deps.work_dir) catch return error.Storage;
    const path = try std.fmt.allocPrint(arena, "{s}/{s}.upload", .{ deps.work_dir, hash });
    defer cwd.deleteFile(deps.io, path) catch {};
    // Whole, or in pieces when the file is larger than one (and was not
    // sent whole): the pieces stream through the hash in order, as one.
    const whole = (deps.s3.headObject(scope, staged) catch return error.Storage) != null;
    const count: u32 = if (whole or size == null or size.? <= deps.piece_bytes) 1 else @intCast((size.? + deps.piece_bytes - 1) / deps.piece_bytes);
    const got = blk: {
        var file = cwd.createFile(deps.io, path, .{ .truncate = true }) catch return error.Storage;
        defer file.close(deps.io);
        var buf: [64 * 1024]u8 = undefined;
        var fw = file.writer(deps.io, &buf);
        var hbuf: [64 * 1024]u8 = undefined;
        var hashed = fw.interface.hashed(content_hash.init(), &hbuf);
        var n: u64 = 0;
        if (count == 1) {
            n = deps.s3.streamTo(scope, staged, &hashed.writer) catch return .missing;
        } else for (1..count + 1) |piece| {
            n += deps.s3.streamTo(scope, try pieceKey(arena, ds.id, hash, @intCast(piece)), &hashed.writer) catch return .missing;
        }
        hashed.writer.flush() catch return error.Storage;
        fw.interface.flush() catch return error.Storage;
        break :blk .{ n, content_hash.hexOf(&hashed.hasher) };
    };
    defer if (count == 1) {
        deps.s3.deleteObject(scope, staged) catch {};
    } else for (1..count + 1) |piece| {
        deps.s3.deleteObject(scope, pieceKey(arena, ds.id, hash, @intCast(piece)) catch continue) catch {};
    };
    if (!eql(&got[1], hash) or (size != null and size.? != got[0])) return .mismatch;
    const key = itemKey(arena, hash) catch return error.OutOfMemory;
    // Stored only if absent, never overwritten (invariant 2), except bytes
    // that cannot be these: a stored object of another size is damage, and
    // the verified upload repairs it.
    const stored = deps.s3.headObject(scope, key) catch return error.Storage;
    if (stored == null or stored.? != got[0])
        deps.s3.putFile(scope, deps.io, key, path) catch return error.Storage;
    // Verified bytes are back in storage: whatever cleanup took returns.
    _ = deps.db.exec(scope, "DELETE FROM collected_items WHERE item_hash = decode($1, 'hex')", .{hash}) catch return error.Db;
    return .admitted;
}

const collected_sql = "SELECT 1::bigint FROM collected_items WHERE item_hash = decode($1, 'hex')";

fn isPurged(db: *dbx.sql.Db, scope: anytype, hash: []const u8) HandleError!bool {
    const row = db.rawOne(i64, scope, "SELECT 1::bigint FROM purged_items WHERE item_hash = decode($1, 'hex')", .{hash}) catch return error.Db;
    return row != null;
}

fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

/// Storage layout: items/blake3/<aa>/<bb>/<hex>.
pub fn itemKey(arena: std.mem.Allocator, hash_hex: []const u8) ![]const u8 {
    return content_hash.itemKey(arena, hash_hex);
}

pub fn validHashHex(hash: []const u8) bool {
    if (hash.len != 64) return false;
    for (hash) |ch| switch (ch) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

fn parseBody(T: type, arena: std.mem.Allocator, body: []const u8) ?T {
    return std.json.parseFromSliceLeaky(T, arena, body, .{ .ignore_unknown_fields = true }) catch null;
}

fn json(arena: std.mem.Allocator, status: std.http.Status, value: anytype) HandleError!Response {
    const body = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(value, .{})});
    return .{ .status = status, .body = body };
}

fn errorResponse(arena: std.mem.Allocator, status: std.http.Status, what: []const u8, next: []const u8) Response {
    const body = std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{ .@"error" = what, .next = next }, .{})}) catch
        "{\"error\":\"out of memory\"}";
    return .{ .status = status, .body = body };
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test "route parsing finds names with slashes and actions with arguments" {
    const r = parseDatasetRoute("/v0/datasets/org/datasets/calls/-/version/0192-abc?x=1").?;
    try std.testing.expectEqualStrings("org/datasets/calls", r.name);
    try std.testing.expectEqualStrings("version/0192-abc", r.action);
    try std.testing.expectEqualStrings("x=1", r.query);
    try std.testing.expectEqualStrings("1", r.queryParam("x").?);
    try std.testing.expect(parseDatasetRoute("/v0/other") == null);
    try std.testing.expect(parseDatasetRoute("/v0/datasets/no-action") == null);
}

test "token comparison is exact" {
    try std.testing.expect(tokenOk("secret", "Bearer secret"));
    try std.testing.expect(!tokenOk("secret", "Bearer secret2"));
    try std.testing.expect(!tokenOk("secret", "Bearer secre"));
    try std.testing.expect(!tokenOk("secret", "secret"));
    try std.testing.expect(!tokenOk("secret", null));
}

test "hash and key helpers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const h = "ab" ++ ("cd" ** 31);
    try std.testing.expect(validHashHex(h));
    try std.testing.expect(!validHashHex("xyz"));
    try std.testing.expectEqualStrings(
        "items/blake3/ab/cd/" ++ h,
        try itemKey(arena_state.allocator(), h),
    );
}
