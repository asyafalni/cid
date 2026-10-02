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
//!   GET  /v0/datasets/<name>/-/state/<commit>
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
const preview_worker = @import("../preview/worker.zig");
const duck = @import("../store/duck.zig");
const table_stats = @import("../tabular/stats.zig");
const rowdiff_mod = @import("../tabular/rowdiff.zig");
const token_mod = @import("../access/token.zig");
const Uuid = @import("../util/uuid7.zig").Uuid;

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
    /// Where row diffs put the two table files while DuckDB reads them;
    /// DuckDB is confined to it.
    scratch_dir: []const u8 = "/tmp/cid-rowdiff",
    /// One row diff at a time, server-wide: DuckDB work never scales with
    /// requests (each answer is cached, so this is rarely contended).
    rowdiff_busy: std.atomic.Value(bool) = .init(false),
};

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
    };
}

const HandleError = error{ OutOfMemory, Db, Storage, BadRequest };

fn handleInner(
    arena: std.mem.Allocator,
    deps: *Deps,
    scope: anytype,
    method: []const u8,
    target: []const u8,
    caller: Caller,
    body: []const u8,
) HandleError!Response {
    const auth_header = caller.header;
    if (eql(method, "GET") and eql(target, "/v0/ping"))
        return json(arena, .ok, .{ .ok = true });
    // Public: the sign-in page asks which ways in this server offers.
    if (eql(method, "GET") and eql(target, "/v0/auth/config"))
        return json(arena, .ok, .{ .gitlab = deps.gitlab_signin });
    if (eql(method, "GET") and eql(target, "/v0/me")) return me(arena, deps, scope, caller);

    if (eql(method, "POST") and eql(target, "/v0/datasets")) {
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

    // Writes need a write-scoped token for this dataset; reads a read one.
    const needed: token_mod.Level = if (eql(route.action, "push") or
        eql(route.action, "check-hashes") or eql(route.action, "tag") or
        eql(route.action, "branch") or eql(route.action, "merge") or
        eql(route.action, "commit") or eql(route.action, "register-items") or
        eql(route.action, "policy"))
        .write
    else
        .read;
    if (!authorized(arena, deps, scope, caller, route.name, needed))
        return errorResponse(arena, .unauthorized, "missing, wrong or expired token for this dataset", "Run the command again; cid fetches a fresh token over SSH. CI: check CID_TOKEN.");

    const ds = lookupDataset(arena, deps, scope, route.name) orelse
        return errorResponse(arena, .not_found, "no such dataset", "Run 'cid init' to create it, or check the address.");

    if (eql(method, "GET") and eql(route.action, "table"))
        return tableStats(arena, deps, scope, ds, route.queryParam("hash") orelse "");
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
    if (eql(method, "GET") and std.mem.startsWith(u8, route.action, "state/"))
        return state(arena, deps, scope, ds, route.action["state/".len..]);
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

    return errorResponse(arena, .not_found, "no such route", "Update cid and try again.");
}

// ---------------------------------------------------------------------------
// Routing helpers
// ---------------------------------------------------------------------------

const DatasetRoute = struct {
    name: []const u8,
    action: []const u8, // "push", "state/<id>", …
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
        // read < write < maintain; maintain covers write.
        const as: token_mod.Level = if (eql(have, "read")) .read else .write;
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
    const Entry = struct {
        name: []const u8,
        kind: []const u8,
        restricted: bool,
        default_format: []const u8,
        latest_release: ?[]const u8,
        last_push: ?[]const u8,
        items: u64,
        bytes: u64,
        types: []const CommitStats.Type,
        classes: []const []const u8,
        mosaic: []const Thumb,
        starred: bool,
        owners: []const []const u8,
    };
    const list = try arena.alloc(Entry, rows.len);
    for (list, rows) |*e, row| {
        const st: CommitStats = if (row.head) |head_commit|
            try commitStats(arena, deps, scope, row.dataset_id, row.kind, head_commit, row.stats)
        else
            .{};
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
            .types = st.types,
            .classes = if (row.restricted) &.{} else st.classes,
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
    const here = deps.db.rawOne(i64, scope, "SELECT 1::bigint FROM item_revisions WHERE dataset_id = $1::uuid AND item_hash = decode($2, 'hex') LIMIT 1", .{ ds.id, hash }) catch return error.Db;
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
        const here = deps.db.rawOne(i64, scope, "SELECT 1::bigint FROM item_revisions WHERE dataset_id = $1::uuid AND item_hash = decode($2, 'hex') LIMIT 1", .{ ds.id, hash }) catch return error.Db;
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
        if (comptime !duck.enabled)
            return json(arena, .ok, .{ .status = "needs_server_build", .reason = @as(?[]const u8, "this server is built without row-level diffs") });
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
    cwd.createDirPath(deps.io, deps.scratch_dir) catch return error.Storage;
    const dir = cwd.realPathFileAlloc(deps.io, deps.scratch_dir, arena) catch return error.Storage;
    const path_a = try std.fmt.allocPrint(arena, "{s}/{s}.a.{t}", .{ dir, req.a, kind_a });
    const path_b = try std.fmt.allocPrint(arena, "{s}/{s}.b.{t}", .{ dir, req.b, kind_b });
    defer cwd.deleteFile(deps.io, path_a) catch {};
    defer cwd.deleteFile(deps.io, path_b) catch {};
    for ([_][2][]const u8{ .{ req.a, path_a }, .{ req.b, path_b } }) |pair| {
        const bytes = deps.s3.getObjectAlloc(scope, itemKey(arena, pair[0]) catch return error.OutOfMemory) catch return error.Storage;
        cwd.writeFile(deps.io, .{ .sub_path = pair[1], .data = bytes }) catch return error.Storage;
    }

    var db = duck.Db.open(arena, .{ .allowed_dir = dir }) catch return error.Storage;
    defer db.close();
    const text = rowdiff_mod.compute(arena, &db, path_a, kind_a, path_b, kind_b) catch |err| switch (err) {
        error.QueryFailed => return .{ .status = "unreadable", .reason = "not a readable table: DuckDB could not read one of the two versions as its file name says" },
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Storage,
    };
    return .{ .status = "done", .result = text };
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
    return json(arena, .ok, .{ .hash = req.hash, .thumb = thumb, .download = download, .table = table, .logged = ds.restricted });
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

/// What a dataset card needs about a commit, cached in `commits.stats`.
/// A commit never changes, so this is computed once — the first time a
/// page needs it — and stored with `WHERE stats IS NULL`: the work scales
/// with commits, never with visitors, the rule the preview queue follows.
/// It is a derived cache of an immutable row, not history; a version it
/// cannot read is recomputed and simply not stored.
const CommitStats = struct {
    v: u32 = stats_version,
    items: u64 = 0,
    bytes: u64 = 0,
    /// File types by count, the eight most common; the extension with its
    /// dot, or "file" for none — the same spelling Browse's type filter uses.
    types: []const Type = &.{},
    /// Up to four visual items, the first by path: a stable sample.
    visual: []const []const u8 = &.{},
    /// Every class name at the commit (annotated datasets), sorted, at
    /// most fifty — what the home page searches.
    classes: []const []const u8 = &.{},

    const Type = struct { ext: []const u8, count: u64 };
};

const stats_version: u32 = 1;

fn commitStats(
    arena: std.mem.Allocator,
    deps: *Deps,
    scope: anytype,
    dataset_id: []const u8,
    kind: []const u8,
    commit_id: []const u8,
    stored: ?[]const u8,
) HandleError!CommitStats {
    if (stored) |text| {
        if (std.json.parseFromSliceLeaky(CommitStats, arena, text, .{ .ignore_unknown_fields = true })) |cached| {
            if (cached.v == stats_version) return cached;
        } else |_| {}
    }

    const rows = release_mod.stateRows(arena, deps.db, scope, dataset_id, commit_id) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Db,
    };
    var st: CommitStats = .{ .items = rows.len };
    var by_type: std.StringArrayHashMapUnmanaged(u64) = .empty;
    var visual: std.ArrayList([]const u8) = .empty;
    for (rows) |row| {
        st.bytes += row.size;
        const ext = extOf(row.path);
        const gop = try by_type.getOrPut(arena, ext);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
        if (visual.items.len < 4 and looksVisual(ext)) try visual.append(arena, row.hash_hex);
    }
    const types = try arena.alloc(CommitStats.Type, by_type.count());
    for (types, by_type.keys(), by_type.values()) |*t, ext, count| t.* = .{ .ext = ext, .count = count };
    std.mem.sort(CommitStats.Type, types, {}, struct {
        fn lessThan(_: void, a: CommitStats.Type, b: CommitStats.Type) bool {
            if (a.count != b.count) return a.count > b.count;
            return std.mem.lessThan(u8, a.ext, b.ext);
        }
    }.lessThan);
    st.types = types[0..@min(types.len, 8)];
    st.visual = visual.items;

    if (eql(kind, "annotated")) {
        const anns = release_mod.annotationRows(arena, deps.db, scope, dataset_id, commit_id) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Db,
        };
        var names: std.StringArrayHashMapUnmanaged(void) = .empty;
        for (anns) |ann| if (ann.class) |c| try names.put(arena, c, {});
        const list = try arena.dupe([]const u8, names.keys());
        std.mem.sort([]const u8, list, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);
        st.classes = list[0..@min(list.len, 50)];
    }

    const text = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(st, .{})});
    _ = deps.db.exec(
        scope,
        "UPDATE commits SET stats = $2::jsonb WHERE commit_id = $1::uuid AND stats IS NULL",
        .{ commit_id, text },
    ) catch {}; // a cache that failed to store is recomputed next time
    return st;
}

fn extOf(path: []const u8) []const u8 {
    const base = path[(if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| i + 1 else 0)..];
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return "file";
    if (dot == 0) return "file";
    return base[dot..];
}

fn looksVisual(ext: []const u8) bool {
    const kinds = [_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".mp4", ".mov", ".webm", ".mkv" };
    for (kinds) |k| if (std.ascii.eqlIgnoreCase(ext, k)) return true;
    return false;
}

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

    const id = Uuid.now(deps.io).toString();
    _ = deps.db.exec(
        scope,
        "INSERT INTO datasets (dataset_id, name, kind, git_url) VALUES ($1::uuid, $2, $3, $4)",
        .{ @as([]const u8, &id), req.name, req.kind, req.git_url },
    ) catch return error.Db;
    return json(arena, .created, .{ .name = req.name, .dataset_id = &id });
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

    // Counts at head, when there is one.
    var items_count: usize = 0;
    var total_bytes: u64 = 0;
    const Count = struct { name: []const u8, count: usize };
    var classes: []const Count = &.{};
    var splits: []const Count = &.{};
    if (tape.len > 0) {
        const rows = release_mod.stateRows(arena, deps.db, scope, ds.id, tape[0].id) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Db,
        };
        items_count = rows.len;
        var split_counts: std.StringArrayHashMapUnmanaged(usize) = .empty;
        for (rows) |row| {
            total_bytes += row.size;
            if (row.split) |name| {
                const gop = try split_counts.getOrPut(arena, name);
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
            }
        }
        const split_list = try arena.alloc(Count, split_counts.count());
        for (split_list, split_counts.keys(), split_counts.values()) |*slot, name, count| {
            slot.* = .{ .name = name, .count = count };
        }
        splits = split_list;

        if (eql(ds.kind, "annotated")) {
            const anns = release_mod.annotationRows(arena, deps.db, scope, ds.id, tape[0].id) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.Db,
            };
            var class_counts: std.StringArrayHashMapUnmanaged(usize) = .empty;
            for (anns) |ann| {
                const name = ann.class orelse continue;
                const gop = try class_counts.getOrPut(arena, name);
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
            }
            class_counts.sortUnstable(struct {
                keys: []const []const u8,
                pub fn lessThan(self: @This(), a: usize, b: usize) bool {
                    return std.mem.lessThan(u8, self.keys[a], self.keys[b]);
                }
            }{ .keys = class_counts.keys() });
            const class_list = try arena.alloc(Count, class_counts.count());
            for (class_list, class_counts.keys(), class_counts.values()) |*slot, name, count| {
                slot.* = .{ .name = name, .count = count };
            }
            classes = class_list;
        }
    }

    return json(arena, .ok, .{
        .name = ds.name,
        .kind = ds.kind,
        .restricted = ds.restricted,
        .git_url = info.git_url,
        .default_format = info.default_format,
        .commits = tape,
        .items = items_count,
        .bytes = total_bytes,
        .classes = classes,
        .splits = splits,
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
    };
    const list = deps.db.raw(Entry, scope, "SELECT commit_id::text AS id, parent_id::text AS parent, message, author, " ++
        "(extract(epoch from authored_at) * 1000)::bigint AS authored_at_ms " ++
        "FROM commits WHERE dataset_id = $1::uuid AND branch = $2 " ++
        "ORDER BY commit_id DESC LIMIT 200", .{ ds.id, branch }) catch return error.Db;
    return json(arena, .ok, .{ .commits = list });
}

const HashesBody = struct { hashes: []const []const u8 };

/// Which of these hashes must be uploaded, with presigned PUT URLs for them.
/// v0 answers for everything the single token can see; the per-dataset
/// dedup-privacy rule (invariant 12) binds when real auth lands.
fn checkHashes(arena: std.mem.Allocator, deps: *Deps, scope: anytype, ds: Dataset, body: []const u8) HandleError!Response {
    _ = ds;
    const req = parseBody(HashesBody, arena, body) orelse return error.BadRequest;
    if (req.hashes.len > 1000) return error.BadRequest;

    const Upload = struct { hash: []const u8, url: []const u8 };
    var missing: std.ArrayList(Upload) = .empty;
    for (req.hashes) |hash| {
        if (!validHashHex(hash)) return error.BadRequest;
        if (try isPurged(deps.db, scope, hash))
            return errorResponse(arena, .unprocessable_entity, "that content was purged and cannot come back", "Remove or replace the file, then run 'cid push' again.");
        const key = itemKey(arena, hash) catch return error.OutOfMemory;
        const exists = deps.s3.headObject(scope, key) catch return error.Storage;
        if (exists == null) {
            const url = deps.s3.presignPut(scope, key, presign_secs) catch return error.Storage;
            try missing.append(arena, .{ .hash = hash, .url = url });
        }
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

    // 1. Every new file must already be in storage, hash-verified by name.
    for (req.commits) |commit| {
        for (commit.changes) |ch| {
            if (eql(ch.op, "add")) {
                if (!validHashHex(ch.hash)) return error.BadRequest;
                if (try isPurged(deps.db, scope, ch.hash))
                    return errorResponse(arena, .unprocessable_entity, "that content was purged and cannot come back", "Remove or replace the file, then run 'cid push' again.");
                const key = itemKey(arena, ch.hash) catch return error.OutOfMemory;
                const exists = deps.s3.headObject(scope, key) catch return error.Storage;
                if (exists == null)
                    return errorResponse(arena, .unprocessable_entity, "a file is missing from storage", "Run 'cid push' again; it re-uploads what is missing.");
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
    // are strictly increasing, floored at the current head's cutoff —
    // plain UUIDv7 is not ordered within a millisecond and a cutoff must
    // never be undercut (invariant 3).
    var rev_floor: ?Uuid = null;
    if (server_head) |h| {
        const cutoff = tx.rawOne([]const u8, scope, "SELECT cutoff_rev::text FROM commits WHERE commit_id = $1::uuid", .{h}) catch return error.Db;
        if (cutoff) |c| rev_floor = Uuid.parse(c) catch null;
    }

    var last_commit_id: []const u8 = undefined;
    for (req.commits) |commit| {
        if (Uuid.parse(commit.id) == error.InvalidUuid) return error.BadRequest;
        var last_rev: Uuid = undefined;
        var has_rev = false;
        for (commit.changes) |ch| {
            const rev = Uuid.nextAfter(deps.io, rev_floor);
            rev_floor = rev;
            last_rev = rev;
            has_rev = true;
            if (eql(ch.op, "add")) {
                try insertAddRevision(&tx, scope, deps.io, ds, req.branch, rev, ch.path, ch.hash, ch.size, commit.author);
            } else {
                try insertDeleteRevision(&tx, scope, ds, req.branch, rev, ch.path, commit.author);
            }
        }
        if (!has_rev) return error.BadRequest;

        _ = tx.exec(
            scope,
            "INSERT INTO commits (commit_id, dataset_id, branch, parent_id, cutoff_rev, message, author, authored_at) " ++
                "VALUES ($1::uuid, $2::uuid, $3, $4::uuid, $5::uuid, $6, $7, to_timestamp($8::bigint / 1000.0))",
            .{
                commit.id,
                ds.id,
                req.branch,
                commit.parent,
                @as([]const u8, &last_rev.toString()),
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

    noteActivity(arena, deps, scope, caller, ds, "push", last_commit_id, .{ .branch = req.branch, .commits = req.commits.len });
    return json(arena, .ok, .{ .head = last_commit_id, .commits_recorded = req.commits.len });
}

fn state(arena: std.mem.Allocator, deps: *Deps, scope: anytype, ds: Dataset, commit_id: []const u8) HandleError!Response {
    if (Uuid.parse(commit_id) == error.InvalidUuid)
        return errorResponse(arena, .bad_request, "that is not a commit id", "Run 'cid log' to list commits.");

    const rows = release_mod.stateRows(arena, deps.db, scope, ds.id, commit_id) catch |err| switch (err) {
        error.NoSuchCommit => return errorResponse(arena, .not_found, "no such commit in this dataset", "Run 'cid log' to list commits."),
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Db,
    };

    const Item = struct { path: []const u8, hash: []const u8, size: u64, split: ?[]const u8, item_id: ?[]const u8, width: ?u32, height: ?u32 };
    const items = try arena.alloc(Item, rows.len);
    for (items, 0..) |*item, i| {
        item.* = .{ .path = rows[i].path, .hash = rows[i].hash_hex, .size = rows[i].size, .split = rows[i].split, .item_id = rows[i].item_id, .width = rows[i].width, .height = rows[i].height };
    }

    if (eql(ds.kind, "annotated")) {
        const anns = release_mod.annotationRows(arena, deps.db, scope, ds.id, commit_id) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Db,
        };
        const WireAnn = struct {
            id: []const u8,
            item_id: []const u8,
            kind: ?[]const u8,
            class: ?[]const u8,
            geometry: ?std.json.Value,
            attrs: ?std.json.Value,
            author: []const u8,
            policy_ver: []const u8,
        };
        const wire = try arena.alloc(WireAnn, anns.len);
        for (wire, 0..) |*w, i| {
            w.* = .{
                .id = anns[i].annotation_id,
                .item_id = anns[i].item_id,
                .kind = anns[i].kind,
                .class = anns[i].class,
                .geometry = jsonValue(arena, anns[i].geometry),
                .attrs = jsonValue(arena, anns[i].attrs),
                .author = anns[i].author,
                .policy_ver = anns[i].policy_ver,
            };
        }
        return json(arena, .ok, .{ .commit = commit_id, .items = items, .annotations = wire });
    }
    return json(arena, .ok, .{ .commit = commit_id, .items = items });
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

    const created = release_mod.create(arena, deps.db, scope, deps.s3, ds.id, req.name, commit_id) catch |err| switch (err) {
        error.BadName => return errorResponse(arena, .bad_request, "that is not a release name (letters, digits, dot, dash, underscore)", "Pick a name like v1.0.0 and run 'cid tag' again."),
        error.ReleaseExists => return errorResponse(arena, .conflict, "that release already exists and releases never move", "Pick a new name, e.g. the next version number."),
        error.NoSuchCommit => return errorResponse(arena, .not_found, "no such commit in this dataset", "Run 'cid log' to list commits."),
        error.BadAnnotationText => return errorResponse(arena, .unprocessable_entity, "an annotation carries text or JSON the manifest cannot hold", "Fix the offending annotation in the platform, commit, then tag again."),
        error.Storage => return error.Storage,
        error.OutOfMemory => return error.OutOfMemory,
        error.Db => return error.Db,
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

    noteActivity(arena, deps, scope, caller, ds, "tag", created.name, .{ .items = created.items });
    return json(arena, .created, .{
        .release = created.name,
        .commit = @as([]const u8, created.commit_id),
        .manifest_sha256 = &created.manifest_sha256,
        .items = created.items,
        .git = git_status,
    });
}

fn releases(arena: std.mem.Allocator, deps: *Deps, scope: anytype, ds: Dataset) HandleError!Response {
    const Entry = struct {
        pub const nilo_table = .projection;
        name: []const u8,
        commit: []const u8,
        manifest_sha256: []const u8,
    };
    const list = deps.db.raw(Entry, scope, "SELECT name, commit_id::text AS commit, encode(manifest_sha256, 'hex') AS manifest_sha256 FROM refs " ++
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
    const Download = struct { hash: []const u8, url: []const u8 };
    const list = try arena.alloc(Download, req.hashes.len);
    for (req.hashes, 0..) |hash, i| {
        if (!validHashHex(hash)) return error.BadRequest;
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
    rev: Uuid,
    path: []const u8,
    hash: []const u8,
    size: u64,
    author: []const u8,
) HandleError!void {
    _ = tx.exec(
        scope,
        "INSERT INTO items (item_hash, size_bytes, media_type) " ++
            "VALUES (decode($1, 'hex'), $2::bigint, 'application/octet-stream') " ++
            "ON CONFLICT (item_hash) DO NOTHING",
        .{ hash, @as(i64, @intCast(size)) },
    ) catch return error.Db;
    try enqueuePreview(tx, scope, hash);
    // Item identity: new path → new item_id; existing path keeps its id.
    // On a branch, the path may live on main as of the branch start.
    _ = tx.exec(
        scope,
        "INSERT INTO item_revisions (rev_id, ts, dataset_id, branch, path, op, item_id, item_hash, split, author) " ++
            "SELECT $1::uuid, to_timestamp($2::bigint / 1000.0), $3::uuid, $4, $5, " ++
            "  CASE WHEN prev.item_id IS NULL THEN 'add' ELSE 'update' END, " ++
            "  COALESCE(prev.item_id, $6::uuid), decode($7, 'hex'), NULL, $8 " ++
            "FROM (SELECT 1) one LEFT JOIN LATERAL (" ++
            "  SELECT item_id FROM item_revisions " ++
            "  WHERE dataset_id = $3::uuid AND branch IN ('main', $4) AND path = $5 AND op <> 'delete' " ++
            "  ORDER BY rev_id DESC LIMIT 1) prev ON true",
        .{
            @as([]const u8, &rev.toString()),
            @as(i64, @intCast(rev.unixMs())),
            ds.id,
            branch,
            path,
            @as([]const u8, &Uuid.now(io).toString()),
            hash,
            author,
        },
    ) catch return error.Db;
    _ = tx.exec(
        scope,
        "INSERT INTO dataset_items (item_id, dataset_id) " ++
            "SELECT r.item_id, $1::uuid FROM item_revisions r WHERE r.rev_id = $2::uuid " ++
            "ON CONFLICT (item_id) DO NOTHING",
        .{ ds.id, @as([]const u8, &rev.toString()) },
    ) catch return error.Db;
}

fn insertDeleteRevision(
    tx: anytype,
    scope: anytype,
    ds: Dataset,
    branch: []const u8,
    rev: Uuid,
    path: []const u8,
    author: []const u8,
) HandleError!void {
    _ = tx.exec(
        scope,
        "INSERT INTO item_revisions (rev_id, ts, dataset_id, branch, path, op, item_id, item_hash, split, author) " ++
            "VALUES ($1::uuid, to_timestamp($2::bigint / 1000.0), $3::uuid, $4, $5, 'delete', NULL, NULL, NULL, $6)",
        .{
            @as([]const u8, &rev.toString()),
            @as(i64, @intCast(rev.unixMs())),
            ds.id,
            branch,
            path,
            author,
        },
    ) catch return error.Db;
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

const MergeBody = struct { name: []const u8, author: []const u8 = "user:unknown" };

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

    const base = release_mod.stateRows(arena, deps.db, scope, ds.id, branch_start) catch return error.Db;
    const ours = release_mod.stateRows(arena, deps.db, scope, ds.id, main_head) catch return error.Db;
    const theirs = release_mod.stateRows(arena, deps.db, scope, ds.id, branch_head) catch return error.Db;

    // The branch's net changes, and main's changed paths, both vs the base.
    const BranchChange = union(enum) { add: struct { hash: []const u8, size: u64 }, delete };
    var branch_changes: std.StringArrayHashMapUnmanaged(BranchChange) = .empty;
    for (theirs) |item| {
        const in_base = findRow(base, item.path);
        if (in_base == null or !std.mem.eql(u8, in_base.?.hash_hex, item.hash_hex))
            try branch_changes.put(arena, item.path, .{ .add = .{ .hash = item.hash_hex, .size = item.size } });
    }
    for (base) |item| {
        if (findRow(theirs, item.path) == null)
            try branch_changes.put(arena, item.path, .delete);
    }

    var conflicts: std.ArrayList([]const u8) = .empty;
    for (branch_changes.keys(), branch_changes.values()) |path, change| {
        const in_base = findRow(base, path);
        const in_main = findRow(ours, path);
        const main_changed = blk: {
            if (in_base == null) break :blk in_main != null;
            if (in_main == null) break :blk true;
            break :blk !std.mem.eql(u8, in_base.?.hash_hex, in_main.?.hash_hex);
        };
        if (!main_changed) continue;
        const same = switch (change) {
            .add => |a| in_main != null and std.mem.eql(u8, in_main.?.hash_hex, a.hash),
            .delete => in_main == null,
        };
        if (same) {
            _ = branch_changes.swapRemove(path);
        } else {
            try conflicts.append(arena, path);
        }
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

    var rev_floor: ?Uuid = null;
    {
        const cutoff = tx.rawOne([]const u8, scope, "SELECT cutoff_rev::text FROM commits WHERE commit_id = $1::uuid", .{main_head}) catch return error.Db;
        if (cutoff) |c| rev_floor = Uuid.parse(c) catch null;
    }

    var last_rev: Uuid = undefined;
    for (branch_changes.keys(), branch_changes.values()) |path, change| {
        const rev = Uuid.nextAfter(deps.io, rev_floor);
        rev_floor = rev;
        last_rev = rev;
        switch (change) {
            .add => |a| try insertAddRevision(&tx, scope, deps.io, ds, "main", rev, path, a.hash, a.size, req.author),
            .delete => try insertDeleteRevision(&tx, scope, ds, "main", rev, path, req.author),
        }
    }

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
            @as([]const u8, &last_rev.toString()),
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
    _ = ds;
    const req = parseBody(RegisterItemsBody, arena, body) orelse return error.BadRequest;
    if (req.items.len > 1000) return error.BadRequest;
    for (req.items) |item| {
        if (!validHashHex(item.hash)) return error.BadRequest;
        if (try isPurged(deps.db, scope, item.hash))
            return errorResponse(arena, .unprocessable_entity, "that content was purged and cannot come back", "Remove or replace the file, then register again.");
        const key = itemKey(arena, item.hash) catch return error.OutOfMemory;
        const stored = deps.s3.headObject(scope, key) catch return error.Storage;
        const size = stored orelse
            return errorResponse(arena, .unprocessable_entity, "an item is missing from storage", "Upload it through the check-hashes URLs first, then register again.");
        if (size != item.size)
            return errorResponse(arena, .unprocessable_entity, "an item's size does not match what storage holds", "Re-upload the file, then register again.");
        const meta = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{
            .width = item.width,
            .height = item.height,
        }, .{ .emit_null_optional_fields = false })});
        _ = deps.db.exec(
            scope,
            "INSERT INTO items (item_hash, size_bytes, media_type, meta) VALUES (decode($1, 'hex'), $2::bigint, $3, $4::jsonb) " ++
                "ON CONFLICT (item_hash) DO UPDATE SET meta = items.meta || excluded.meta",
            .{ item.hash, @as(i64, @intCast(item.size)), item.media_type, meta },
        ) catch return error.Db;
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
    const parent_cutoff: ?[]const u8 = blk: {
        const p = parent orelse break :blk null;
        break :blk tx.rawOne([]const u8, scope, "SELECT cutoff_rev::text FROM commits WHERE commit_id = $1::uuid", .{p}) catch return error.Db;
    };

    // The cutoff: the newest revision on this branch, item or annotation.
    const floor = parent_cutoff orelse "00000000-0000-0000-0000-000000000000";
    const cutoff = tx.rawOne([]const u8, scope, "SELECT rev_id::text FROM (" ++
        "  SELECT rev_id FROM item_revisions WHERE dataset_id = $1::uuid AND branch = $2 AND rev_id > $3::uuid " ++
        "  UNION ALL " ++
        "  SELECT rev_id FROM annotation_revisions WHERE dataset_id = $1::uuid AND branch = $2 AND rev_id > $3::uuid) u " ++
        "ORDER BY rev_id DESC LIMIT 1", .{ ds.id, req.branch, floor }) catch return error.Db;
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

fn isPurged(db: *dbx.sql.Db, scope: anytype, hash: []const u8) HandleError!bool {
    const row = db.rawOne(i64, scope, "SELECT 1::bigint FROM purged_items WHERE item_hash = decode($1, 'hex')", .{hash}) catch return error.Db;
    return row != null;
}

fn findRow(rows: []const release_mod.StateRow, path: []const u8) ?release_mod.StateRow {
    for (rows) |row| {
        if (std.mem.eql(u8, row.path, path)) return row;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

/// Storage layout: items/sha256/<aa>/<bb>/<hex>.
pub fn itemKey(arena: std.mem.Allocator, hash_hex: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "items/sha256/{s}/{s}/{s}", .{
        hash_hex[0..2], hash_hex[2..4], hash_hex,
    });
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
    const r = parseDatasetRoute("/v0/datasets/org/datasets/calls/-/state/0192-abc?x=1").?;
    try std.testing.expectEqualStrings("org/datasets/calls", r.name);
    try std.testing.expectEqualStrings("state/0192-abc", r.action);
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

test "file types are spelled as Browse spells them" {
    try std.testing.expectEqualStrings(".png", extOf("frames/a.png"));
    try std.testing.expectEqualStrings("file", extOf("README"));
    try std.testing.expectEqualStrings("file", extOf("dir.v2/.hidden"));
    try std.testing.expect(looksVisual(".JPG"));
    try std.testing.expect(!looksVisual(".csv"));
}

test "hash and key helpers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const h = "ab" ++ ("cd" ** 31);
    try std.testing.expect(validHashHex(h));
    try std.testing.expect(!validHashHex("xyz"));
    try std.testing.expectEqualStrings(
        "items/sha256/ab/cd/" ++ h,
        try itemKey(arena_state.allocator(), h),
    );
}
