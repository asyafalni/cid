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

const std = @import("std");
const pg = @import("../store/pg.zig");
const s3 = @import("../store/s3.zig");
const release_mod = @import("../core/release.zig");
const git_writer = @import("../gitrepo/writer.zig");
const Uuid = @import("../util/uuid7.zig").Uuid;

pub const Deps = struct {
    db: *pg.Db,
    s3: *s3.Client,
    io: std.Io,
    token: []const u8,
    /// When set, releases are written to the dataset repository right
    /// after tagging; otherwise git_writes rows wait for
    /// 'cid admin git <dataset> --resync'.
    git: ?git_writer.Config = null,
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
    method: []const u8,
    target: []const u8,
    auth_header: ?[]const u8,
    body: []const u8,
) Response {
    return handleInner(arena, deps, method, target, auth_header, body) catch |err| switch (err) {
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
    method: []const u8,
    target: []const u8,
    auth_header: ?[]const u8,
    body: []const u8,
) HandleError!Response {
    if (eql(method, "GET") and eql(target, "/v0/ping"))
        return json(arena, .ok, .{ .ok = true });

    // Everything else needs the token.
    if (!tokenOk(deps.token, auth_header))
        return errorResponse(arena, .unauthorized, "missing or wrong token", "Check CID_TOKEN on both sides.");

    if (eql(method, "POST") and eql(target, "/v0/datasets"))
        return createDataset(arena, deps, body);

    const route = parseDatasetRoute(target) orelse
        return errorResponse(arena, .not_found, "no such route", "Update cid and try again.");

    const ds = lookupDataset(arena, deps, route.name) orelse
        return errorResponse(arena, .not_found, "no such dataset", "Run 'cid init' to create it, or check the address.");

    if (eql(method, "GET") and eql(route.action, "info"))
        return datasetInfo(arena, deps, ds);
    if (eql(method, "GET") and eql(route.action, "head"))
        return head(arena, deps, ds, route.queryParam("branch") orelse "main");
    if (eql(method, "GET") and eql(route.action, "log"))
        return log(arena, deps, ds, route.queryParam("branch") orelse "main");
    if (eql(method, "POST") and eql(route.action, "check-hashes"))
        return checkHashes(arena, deps, ds, body);
    if (eql(method, "POST") and eql(route.action, "push"))
        return push(arena, deps, ds, body);
    if (eql(method, "GET") and std.mem.startsWith(u8, route.action, "state/"))
        return state(arena, deps, ds, route.action["state/".len..]);
    if (eql(method, "POST") and eql(route.action, "downloads"))
        return downloads(arena, deps, ds, body);
    if (eql(method, "POST") and eql(route.action, "tag"))
        return tag(arena, deps, ds, body);
    if (eql(method, "GET") and eql(route.action, "releases"))
        return releases(arena, deps, ds);

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
    const h = auth_header orelse return false;
    if (!std.mem.startsWith(u8, h, "Bearer ")) return false;
    const got = h["Bearer ".len..];
    if (got.len != expected.len) return false;
    var diff: u8 = 0;
    for (got, expected) |a, b| diff |= a ^ b;
    return diff == 0;
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

const Dataset = struct {
    id: [:0]const u8, // uuid text
    name: []const u8,
};

fn lookupDataset(arena: std.mem.Allocator, deps: *Deps, name: []const u8) ?Dataset {
    const name_z = arena.dupeZ(u8, name) catch return null;
    var rows = deps.db.query(
        "SELECT dataset_id::text FROM datasets WHERE name = $1",
        &.{name_z},
        null,
    ) catch return null;
    defer rows.deinit();
    if (rows.count() == 0) return null;
    return .{
        .id = arena.dupeZ(u8, rows.get(0, 0)) catch return null,
        .name = name,
    };
}

const CreateDatasetBody = struct {
    name: []const u8,
    kind: []const u8 = "files",
    git_url: []const u8,
};

fn createDataset(arena: std.mem.Allocator, deps: *Deps, body: []const u8) HandleError!Response {
    const req = parseBody(CreateDatasetBody, arena, body) orelse return error.BadRequest;
    if (req.name.len == 0 or req.git_url.len == 0) return error.BadRequest;
    if (!eql(req.kind, "files") and !eql(req.kind, "annotated")) return error.BadRequest;

    if (lookupDataset(arena, deps, req.name) != null)
        return errorResponse(arena, .conflict, "the dataset already exists", "Run 'cid clone' to work with it.");

    const id = Uuid.now(deps.io).toString();
    var diag: pg.Diag = .{};
    deps.db.execParams(
        "INSERT INTO datasets (dataset_id, name, kind, git_url) VALUES ($1, $2, $3, $4)",
        &.{
            try arena.dupeZ(u8, &id),
            try arena.dupeZ(u8, req.name),
            try arena.dupeZ(u8, req.kind),
            try arena.dupeZ(u8, req.git_url),
        },
        &diag,
    ) catch return error.Db;
    return json(arena, .created, .{ .name = req.name, .dataset_id = &id });
}

fn datasetInfo(arena: std.mem.Allocator, deps: *Deps, ds: Dataset) HandleError!Response {
    var rows = deps.db.query(
        "SELECT kind, git_url, default_format FROM datasets WHERE dataset_id = $1::uuid",
        &.{ds.id},
        null,
    ) catch return error.Db;
    defer rows.deinit();
    if (rows.count() == 0) return error.Db;
    return json(arena, .ok, .{
        .name = ds.name,
        .kind = try arena.dupe(u8, rows.get(0, 0)),
        .git_url = try arena.dupe(u8, rows.get(0, 1)),
        .default_format = try arena.dupe(u8, rows.get(0, 2)),
    });
}

fn head(arena: std.mem.Allocator, deps: *Deps, ds: Dataset, branch: []const u8) HandleError!Response {
    var rows = deps.db.query(
        "SELECT commit_id::text FROM refs WHERE dataset_id = $1::uuid AND name = $2 AND kind = 'branch'",
        &.{ ds.id, try arena.dupeZ(u8, branch) },
        null,
    ) catch return error.Db;
    defer rows.deinit();
    if (rows.count() == 0) return json(arena, .ok, .{ .commit = null });
    return json(arena, .ok, .{ .commit = @as(?[]const u8, try arena.dupe(u8, rows.get(0, 0))) });
}

fn log(arena: std.mem.Allocator, deps: *Deps, ds: Dataset, branch: []const u8) HandleError!Response {
    var rows = deps.db.query(
        "SELECT commit_id::text, parent_id::text, message, author, " ++
            "(extract(epoch from authored_at) * 1000)::bigint::text " ++
            "FROM commits WHERE dataset_id = $1::uuid AND branch = $2 " ++
            "ORDER BY commit_id DESC LIMIT 200",
        &.{ ds.id, try arena.dupeZ(u8, branch) },
        null,
    ) catch return error.Db;
    defer rows.deinit();

    const Entry = struct {
        id: []const u8,
        parent: ?[]const u8,
        message: []const u8,
        author: []const u8,
        authored_at_ms: u64,
    };
    const list = try arena.alloc(Entry, rows.count());
    for (list, 0..) |*e, i| {
        e.* = .{
            .id = try arena.dupe(u8, rows.get(i, 0)),
            .parent = if (rows.isNull(i, 1)) null else try arena.dupe(u8, rows.get(i, 1)),
            .message = try arena.dupe(u8, rows.get(i, 2)),
            .author = try arena.dupe(u8, rows.get(i, 3)),
            .authored_at_ms = std.fmt.parseInt(u64, rows.get(i, 4), 10) catch 0,
        };
    }
    return json(arena, .ok, .{ .commits = list });
}

const HashesBody = struct { hashes: []const []const u8 };

/// Which of these hashes must be uploaded, with presigned PUT URLs for them.
/// v0 answers for everything the single token can see; the per-dataset
/// dedup-privacy rule (invariant 12) binds when real auth lands.
fn checkHashes(arena: std.mem.Allocator, deps: *Deps, ds: Dataset, body: []const u8) HandleError!Response {
    _ = ds;
    const req = parseBody(HashesBody, arena, body) orelse return error.BadRequest;
    if (req.hashes.len > 1000) return error.BadRequest;

    const Upload = struct { hash: []const u8, url: []const u8 };
    var missing: std.ArrayList(Upload) = .empty;
    const now = nowEpoch(deps.io);
    for (req.hashes) |hash| {
        if (!validHashHex(hash)) return error.BadRequest;
        const key = itemKey(arena, hash) catch return error.OutOfMemory;
        const exists = deps.s3.headObject(arena, key) catch return error.Storage;
        if (exists == null) {
            const url = deps.s3.presignPut(arena, key, now, presign_secs) catch return error.Storage;
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
fn push(arena: std.mem.Allocator, deps: *Deps, ds: Dataset, body: []const u8) HandleError!Response {
    const req = parseBody(PushBody, arena, body) orelse return error.BadRequest;
    if (req.commits.len == 0) return error.BadRequest;

    // 1. Every new file must already be in storage, hash-verified by name.
    for (req.commits) |commit| {
        for (commit.changes) |ch| {
            if (eql(ch.op, "add")) {
                if (!validHashHex(ch.hash)) return error.BadRequest;
                const key = itemKey(arena, ch.hash) catch return error.OutOfMemory;
                const exists = deps.s3.headObject(arena, key) catch return error.Storage;
                if (exists == null)
                    return errorResponse(arena, .unprocessable_entity, "a file is missing from storage", "Run 'cid push' again; it re-uploads what is missing.");
            } else if (!eql(ch.op, "delete")) return error.BadRequest;
        }
    }

    var diag: pg.Diag = .{};
    deps.db.exec("BEGIN", &diag) catch return error.Db;
    errdefer deps.db.exec("ROLLBACK", null) catch {};

    // 2. The commit lock: writers shared, commits exclusive (docs/data-model.md).
    deps.db.execParams(
        "SELECT pg_advisory_xact_lock(hashtextextended($1 || '/' || $2, 0))",
        &.{ ds.id, try arena.dupeZ(u8, req.branch) },
        &diag,
    ) catch return error.Db;

    // 3. Forward-only: the first commit's parent must be the branch head.
    const server_head: ?[]const u8 = blk: {
        var rows = deps.db.query(
            "SELECT commit_id::text FROM refs WHERE dataset_id = $1::uuid AND name = $2 AND kind = 'branch'",
            &.{ ds.id, try arena.dupeZ(u8, req.branch) },
            &diag,
        ) catch return error.Db;
        defer rows.deinit();
        break :blk if (rows.count() == 0) null else try arena.dupe(u8, rows.get(0, 0));
    };
    const claimed_parent = req.commits[0].parent;
    const matches = (server_head == null and claimed_parent == null) or
        (server_head != null and claimed_parent != null and eql(server_head.?, claimed_parent.?));
    if (!matches) {
        deps.db.exec("ROLLBACK", null) catch {};
        return errorResponse(arena, .conflict, "someone pushed since you pulled", "Run 'cid pull', then 'cid push' again.");
    }

    // 4. Record: items, revisions, commits; branch head last. Revision ids
    // are strictly increasing, floored at the current head's cutoff —
    // plain UUIDv7 is not ordered within a millisecond and a cutoff must
    // never be undercut (invariant 3).
    var rev_floor: ?Uuid = null;
    if (server_head) |h| {
        var cutoff_rows = deps.db.query(
            "SELECT cutoff_rev::text FROM commits WHERE commit_id = $1::uuid",
            &.{try arena.dupeZ(u8, h)},
            &diag,
        ) catch return error.Db;
        defer cutoff_rows.deinit();
        if (cutoff_rows.count() > 0)
            rev_floor = Uuid.parse(cutoff_rows.get(0, 0)) catch null;
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
                deps.db.execParams(
                    "INSERT INTO items (item_hash, size_bytes, media_type) " ++
                        "VALUES (decode($1, 'hex'), $2::bigint, 'application/octet-stream') " ++
                        "ON CONFLICT (item_hash) DO NOTHING",
                    &.{ try arena.dupeZ(u8, ch.hash), try intZ(arena, ch.size) },
                    &diag,
                ) catch return error.Db;
                // Item identity: new path → new item_id; existing path keeps its id.
                deps.db.execParams(
                    "INSERT INTO item_revisions (rev_id, ts, dataset_id, branch, path, op, item_id, item_hash, split, author) " ++
                        "SELECT $1::uuid, to_timestamp($2::bigint / 1000.0), $3::uuid, $4, $5, " ++
                        "  CASE WHEN prev.item_id IS NULL THEN 'add' ELSE 'update' END, " ++
                        "  COALESCE(prev.item_id, $6::uuid), decode($7, 'hex'), NULL, $8 " ++
                        "FROM (SELECT 1) one LEFT JOIN LATERAL (" ++
                        "  SELECT item_id FROM item_revisions " ++
                        "  WHERE dataset_id = $3::uuid AND branch = $4 AND path = $5 AND op <> 'delete' " ++
                        "  ORDER BY rev_id DESC LIMIT 1) prev ON true",
                    &.{
                        try arena.dupeZ(u8, &rev.toString()),
                        try intZ(arena, rev.unixMs()),
                        ds.id,
                        try arena.dupeZ(u8, req.branch),
                        try arena.dupeZ(u8, ch.path),
                        try arena.dupeZ(u8, &Uuid.now(deps.io).toString()),
                        try arena.dupeZ(u8, ch.hash),
                        try arena.dupeZ(u8, commit.author),
                    },
                    &diag,
                ) catch return error.Db;
                // New identities also get their dataset_items row.
                deps.db.execParams(
                    "INSERT INTO dataset_items (item_id, dataset_id) " ++
                        "SELECT r.item_id, $1::uuid FROM item_revisions r WHERE r.rev_id = $2::uuid " ++
                        "ON CONFLICT (item_id) DO NOTHING",
                    &.{ ds.id, try arena.dupeZ(u8, &rev.toString()) },
                    &diag,
                ) catch return error.Db;
            } else {
                deps.db.execParams(
                    "INSERT INTO item_revisions (rev_id, ts, dataset_id, branch, path, op, item_id, item_hash, split, author) " ++
                        "VALUES ($1::uuid, to_timestamp($2::bigint / 1000.0), $3::uuid, $4, $5, 'delete', NULL, NULL, NULL, $6)",
                    &.{
                        try arena.dupeZ(u8, &rev.toString()),
                        try intZ(arena, rev.unixMs()),
                        ds.id,
                        try arena.dupeZ(u8, req.branch),
                        try arena.dupeZ(u8, ch.path),
                        try arena.dupeZ(u8, commit.author),
                    },
                    &diag,
                ) catch return error.Db;
            }
        }
        if (!has_rev) return error.BadRequest;

        if (commit.parent) |parent| {
            deps.db.execParams(
                "INSERT INTO commits (commit_id, dataset_id, branch, parent_id, cutoff_rev, message, author, authored_at) " ++
                    "VALUES ($1::uuid, $2::uuid, $3, $4::uuid, $5::uuid, $6, $7, to_timestamp($8::bigint / 1000.0))",
                &.{
                    try arena.dupeZ(u8, commit.id),
                    ds.id,
                    try arena.dupeZ(u8, req.branch),
                    try arena.dupeZ(u8, parent),
                    try arena.dupeZ(u8, &last_rev.toString()),
                    try arena.dupeZ(u8, commit.message),
                    try arena.dupeZ(u8, commit.author),
                    try intZ(arena, commit.authored_at_ms),
                },
                &diag,
            ) catch return error.Db;
        } else {
            deps.db.execParams(
                "INSERT INTO commits (commit_id, dataset_id, branch, parent_id, cutoff_rev, message, author, authored_at) " ++
                    "VALUES ($1::uuid, $2::uuid, $3, NULL, $4::uuid, $5, $6, to_timestamp($7::bigint / 1000.0))",
                &.{
                    try arena.dupeZ(u8, commit.id),
                    ds.id,
                    try arena.dupeZ(u8, req.branch),
                    try arena.dupeZ(u8, &last_rev.toString()),
                    try arena.dupeZ(u8, commit.message),
                    try arena.dupeZ(u8, commit.author),
                    try intZ(arena, commit.authored_at_ms),
                },
                &diag,
            ) catch return error.Db;
        }
        last_commit_id = commit.id;
    }

    deps.db.execParams(
        "INSERT INTO refs (dataset_id, name, kind, commit_id) VALUES ($1::uuid, $2, 'branch', $3::uuid) " ++
            "ON CONFLICT (dataset_id, name) DO UPDATE SET commit_id = excluded.commit_id",
        &.{ ds.id, try arena.dupeZ(u8, req.branch), try arena.dupeZ(u8, last_commit_id) },
        &diag,
    ) catch return error.Db;
    deps.db.exec("COMMIT", &diag) catch return error.Db;

    return json(arena, .ok, .{ .head = last_commit_id, .commits_recorded = req.commits.len });
}

fn state(arena: std.mem.Allocator, deps: *Deps, ds: Dataset, commit_id: []const u8) HandleError!Response {
    if (Uuid.parse(commit_id) == error.InvalidUuid)
        return errorResponse(arena, .bad_request, "that is not a commit id", "Run 'cid log' to list commits.");
    const commit_z = try arena.dupeZ(u8, commit_id);

    const rows = release_mod.stateRows(arena, deps.db, ds.id, commit_z) catch |err| switch (err) {
        error.NoSuchCommit => return errorResponse(arena, .not_found, "no such commit in this dataset", "Run 'cid log' to list commits."),
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Db,
    };

    const Item = struct { path: []const u8, hash: []const u8, size: u64 };
    const items = try arena.alloc(Item, rows.len);
    for (items, 0..) |*item, i| {
        item.* = .{ .path = rows[i].path, .hash = rows[i].hash_hex, .size = rows[i].size };
    }
    return json(arena, .ok, .{ .commit = commit_id, .items = items });
}

const TagBody = struct {
    name: []const u8,
    /// Defaults to the branch head.
    commit: ?[]const u8 = null,
    branch: []const u8 = "main",
};

/// `cid tag`: a release never moves once this returns (invariant 5).
fn tag(arena: std.mem.Allocator, deps: *Deps, ds: Dataset, body: []const u8) HandleError!Response {
    const req = parseBody(TagBody, arena, body) orelse return error.BadRequest;

    const commit_id: [:0]const u8 = blk: {
        if (req.commit) |c| {
            if (Uuid.parse(c) == error.InvalidUuid) return error.BadRequest;
            break :blk try arena.dupeZ(u8, c);
        }
        var rows = deps.db.query(
            "SELECT commit_id::text FROM refs WHERE dataset_id = $1::uuid AND name = $2 AND kind = 'branch'",
            &.{ ds.id, try arena.dupeZ(u8, req.branch) },
            null,
        ) catch return error.Db;
        defer rows.deinit();
        if (rows.count() == 0)
            return errorResponse(arena, .unprocessable_entity, "nothing to tag: the branch has no commits", "Run 'cid push' first, then 'cid tag' again.");
        break :blk try arena.dupeZ(u8, rows.get(0, 0));
    };

    const created = release_mod.create(arena, deps.db, deps.s3, ds.id, req.name, commit_id) catch |err| switch (err) {
        error.BadName => return errorResponse(arena, .bad_request, "that is not a release name (letters, digits, dot, dash, underscore)", "Pick a name like v1.0.0 and run 'cid tag' again."),
        error.ReleaseExists => return errorResponse(arena, .conflict, "that release already exists and releases never move", "Pick a new name, e.g. the next version number."),
        error.NoSuchCommit => return errorResponse(arena, .not_found, "no such commit in this dataset", "Run 'cid log' to list commits."),
        error.Storage => return error.Storage,
        error.OutOfMemory => return error.OutOfMemory,
        error.Db => return error.Db,
    };
    // The release stands; its git copy is queued and attempted right away
    // when configured. A git failure never blocks the release (invariant 21).
    deps.db.execParams(
        "INSERT INTO git_writes (dataset_id, release, status) VALUES ($1::uuid, $2, 'pending') " ++
            "ON CONFLICT (dataset_id, release) DO NOTHING",
        &.{ ds.id, try arena.dupeZ(u8, created.name) },
        null,
    ) catch return error.Db;
    var git_status: []const u8 = "pending";
    if (deps.git) |git_config| {
        const outcome = git_writer.processDataset(arena, deps.io, deps.db, git_config, ds.name) catch
            git_writer.Outcome{ .failed = 1 };
        git_status = if (outcome.failed == 0) "done" else "failed";
    }

    return json(arena, .created, .{
        .release = created.name,
        .commit = @as([]const u8, created.commit_id),
        .manifest_sha256 = &created.manifest_sha256,
        .items = created.items,
        .git = git_status,
    });
}

fn releases(arena: std.mem.Allocator, deps: *Deps, ds: Dataset) HandleError!Response {
    var rows = deps.db.query(
        "SELECT name, commit_id::text, encode(manifest_sha256, 'hex') FROM refs " ++
            "WHERE dataset_id = $1::uuid AND kind = 'release' ORDER BY commit_id DESC",
        &.{ds.id},
        null,
    ) catch return error.Db;
    defer rows.deinit();
    const Entry = struct { name: []const u8, commit: []const u8, manifest_sha256: []const u8 };
    const list = try arena.alloc(Entry, rows.count());
    for (list, 0..) |*e, i| {
        e.* = .{
            .name = try arena.dupe(u8, rows.get(i, 0)),
            .commit = try arena.dupe(u8, rows.get(i, 1)),
            .manifest_sha256 = try arena.dupe(u8, rows.get(i, 2)),
        };
    }
    return json(arena, .ok, .{ .releases = list });
}

fn downloads(arena: std.mem.Allocator, deps: *Deps, ds: Dataset, body: []const u8) HandleError!Response {
    _ = ds;
    const req = parseBody(HashesBody, arena, body) orelse return error.BadRequest;
    if (req.hashes.len > 1000) return error.BadRequest;
    const Download = struct { hash: []const u8, url: []const u8 };
    const list = try arena.alloc(Download, req.hashes.len);
    const now = nowEpoch(deps.io);
    for (req.hashes, 0..) |hash, i| {
        if (!validHashHex(hash)) return error.BadRequest;
        const key = itemKey(arena, hash) catch return error.OutOfMemory;
        const url = deps.s3.presignGet(arena, key, now, presign_secs) catch return error.Storage;
        list[i] = .{ .hash = hash, .url = url };
    }
    return json(arena, .ok, .{ .downloads = list });
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

fn intZ(arena: std.mem.Allocator, n: u64) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(arena, "{d}", .{n}, 0);
}

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

fn nowEpoch(io: std.Io) u64 {
    return @intCast(@max(0, std.Io.Timestamp.now(io, .real).toSeconds()));
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
