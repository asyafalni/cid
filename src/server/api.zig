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
const token_mod = @import("../access/token.zig");
const Uuid = @import("../util/uuid7.zig").Uuid;

pub const Deps = struct {
    db: *pg.Db,
    s3: *s3.Client,
    io: std.Io,
    /// The static full-access token (CI fallback; empty disables it).
    token: []const u8,
    /// Verifies SSH-issued scoped tokens when set (CID_TOKEN_SECRET).
    token_secret: ?[]const u8 = null,
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

    if (eql(method, "POST") and eql(target, "/v0/datasets")) {
        // The dataset's name is in the body; createDataset checks scope.
        return createDataset(arena, deps, auth_header, body);
    }

    const route = parseDatasetRoute(target) orelse
        return errorResponse(arena, .not_found, "no such route", "Update cid and try again.");

    // Writes need a write-scoped token for this dataset; reads a read one.
    const needed: token_mod.Level = if (eql(route.action, "push") or
        eql(route.action, "check-hashes") or eql(route.action, "tag") or
        eql(route.action, "branch") or eql(route.action, "merge") or
        eql(route.action, "commit") or eql(route.action, "register-items"))
        .write
    else
        .read;
    if (!authorized(arena, deps, auth_header, route.name, needed))
        return errorResponse(arena, .unauthorized, "missing, wrong or expired token for this dataset", "Run the command again; cid fetches a fresh token over SSH. CI: check CID_TOKEN.");

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
    if (eql(method, "POST") and eql(route.action, "branch"))
        return branchCreate(arena, deps, ds, body);
    if (eql(method, "GET") and eql(route.action, "branches"))
        return branches(arena, deps, ds);
    if (eql(method, "POST") and eql(route.action, "merge"))
        return merge(arena, deps, ds, body);
    if (eql(method, "POST") and eql(route.action, "commit"))
        return serverCommit(arena, deps, ds, body);
    if (eql(method, "POST") and eql(route.action, "register-items"))
        return registerItems(arena, deps, ds, body);

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
    auth_header: ?[]const u8,
    dataset: []const u8,
    needed: token_mod.Level,
) bool {
    if (tokenOk(deps.token, auth_header)) return true;
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
    id: [:0]const u8, // uuid text
    name: []const u8,
    kind: []const u8, // 'files' | 'annotated'
};

fn lookupDataset(arena: std.mem.Allocator, deps: *Deps, name: []const u8) ?Dataset {
    const name_z = arena.dupeZ(u8, name) catch return null;
    var rows = deps.db.query(
        "SELECT dataset_id::text, kind FROM datasets WHERE name = $1",
        &.{name_z},
        null,
    ) catch return null;
    defer rows.deinit();
    if (rows.count() == 0) return null;
    return .{
        .id = arena.dupeZ(u8, rows.get(0, 0)) catch return null,
        .name = name,
        .kind = arena.dupe(u8, rows.get(0, 1)) catch return null,
    };
}

const CreateDatasetBody = struct {
    name: []const u8,
    kind: []const u8 = "files",
    git_url: []const u8,
};

fn createDataset(arena: std.mem.Allocator, deps: *Deps, auth_header: ?[]const u8, body: []const u8) HandleError!Response {
    const req = parseBody(CreateDatasetBody, arena, body) orelse return error.BadRequest;
    if (req.name.len == 0 or req.git_url.len == 0) return error.BadRequest;
    if (!authorized(arena, deps, auth_header, req.name, .write))
        return errorResponse(arena, .unauthorized, "missing, wrong or expired token for this dataset", "Run the command again; cid fetches a fresh token over SSH. CI: check CID_TOKEN.");
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
        if (try isPurged(arena, deps, hash))
            return errorResponse(arena, .unprocessable_entity, "that content was purged and cannot come back", "Remove or replace the file, then run 'cid push' again.");
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
                if (try isPurged(arena, deps, ch.hash))
                    return errorResponse(arena, .unprocessable_entity, "that content was purged and cannot come back", "Remove or replace the file, then run 'cid push' again.");
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
                try insertAddRevision(arena, deps, &diag, ds, req.branch, rev, ch.path, ch.hash, ch.size, commit.author);
            } else {
                try insertDeleteRevision(arena, deps, &diag, ds, req.branch, rev, ch.path, commit.author);
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

    const Item = struct { path: []const u8, hash: []const u8, size: u64, split: ?[]const u8, item_id: ?[]const u8, width: ?u32, height: ?u32 };
    const items = try arena.alloc(Item, rows.len);
    for (items, 0..) |*item, i| {
        item.* = .{ .path = rows[i].path, .hash = rows[i].hash_hex, .size = rows[i].size, .split = rows[i].split, .item_id = rows[i].item_id, .width = rows[i].width, .height = rows[i].height };
    }

    if (eql(ds.kind, "annotated")) {
        const anns = release_mod.annotationRows(arena, deps.db, ds.id, commit_z) catch |err| switch (err) {
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
        error.BadAnnotationText => return errorResponse(arena, .unprocessable_entity, "an annotation carries text or JSON the manifest cannot hold", "Fix the offending annotation in the platform, commit, then tag again."),
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

fn insertAddRevision(
    arena: std.mem.Allocator,
    deps: *Deps,
    diag: *pg.Diag,
    ds: Dataset,
    branch: []const u8,
    rev: Uuid,
    path: []const u8,
    hash: []const u8,
    size: u64,
    author: []const u8,
) HandleError!void {
    deps.db.execParams(
        "INSERT INTO items (item_hash, size_bytes, media_type) " ++
            "VALUES (decode($1, 'hex'), $2::bigint, 'application/octet-stream') " ++
            "ON CONFLICT (item_hash) DO NOTHING",
        &.{ try arena.dupeZ(u8, hash), try intZ(arena, size) },
        diag,
    ) catch return error.Db;
    // Item identity: new path → new item_id; existing path keeps its id.
    // On a branch, the path may live on main as of the branch start.
    deps.db.execParams(
        "INSERT INTO item_revisions (rev_id, ts, dataset_id, branch, path, op, item_id, item_hash, split, author) " ++
            "SELECT $1::uuid, to_timestamp($2::bigint / 1000.0), $3::uuid, $4, $5, " ++
            "  CASE WHEN prev.item_id IS NULL THEN 'add' ELSE 'update' END, " ++
            "  COALESCE(prev.item_id, $6::uuid), decode($7, 'hex'), NULL, $8 " ++
            "FROM (SELECT 1) one LEFT JOIN LATERAL (" ++
            "  SELECT item_id FROM item_revisions " ++
            "  WHERE dataset_id = $3::uuid AND branch IN ('main', $4) AND path = $5 AND op <> 'delete' " ++
            "  ORDER BY rev_id DESC LIMIT 1) prev ON true",
        &.{
            try arena.dupeZ(u8, &rev.toString()),
            try intZ(arena, rev.unixMs()),
            ds.id,
            try arena.dupeZ(u8, branch),
            try arena.dupeZ(u8, path),
            try arena.dupeZ(u8, &Uuid.now(deps.io).toString()),
            try arena.dupeZ(u8, hash),
            try arena.dupeZ(u8, author),
        },
        diag,
    ) catch return error.Db;
    deps.db.execParams(
        "INSERT INTO dataset_items (item_id, dataset_id) " ++
            "SELECT r.item_id, $1::uuid FROM item_revisions r WHERE r.rev_id = $2::uuid " ++
            "ON CONFLICT (item_id) DO NOTHING",
        &.{ ds.id, try arena.dupeZ(u8, &rev.toString()) },
        diag,
    ) catch return error.Db;
}

fn insertDeleteRevision(
    arena: std.mem.Allocator,
    deps: *Deps,
    diag: *pg.Diag,
    ds: Dataset,
    branch: []const u8,
    rev: Uuid,
    path: []const u8,
    author: []const u8,
) HandleError!void {
    deps.db.execParams(
        "INSERT INTO item_revisions (rev_id, ts, dataset_id, branch, path, op, item_id, item_hash, split, author) " ++
            "VALUES ($1::uuid, to_timestamp($2::bigint / 1000.0), $3::uuid, $4, $5, 'delete', NULL, NULL, NULL, $6)",
        &.{
            try arena.dupeZ(u8, &rev.toString()),
            try intZ(arena, rev.unixMs()),
            ds.id,
            try arena.dupeZ(u8, branch),
            try arena.dupeZ(u8, path),
            try arena.dupeZ(u8, author),
        },
        diag,
    ) catch return error.Db;
}

const BranchBody = struct { name: []const u8 };

/// `cid branch <name>`: a draft line of work, always starting from main
/// (invariant 8), recording where it started.
fn branchCreate(arena: std.mem.Allocator, deps: *Deps, ds: Dataset, body: []const u8) HandleError!Response {
    const req = parseBody(BranchBody, arena, body) orelse return error.BadRequest;
    if (!release_mod.validName(req.name) or eql(req.name, "main"))
        return errorResponse(arena, .bad_request, "that is not a branch name (letters, digits, dot, dash, underscore; not 'main')", "Pick a name like cleanup and run 'cid branch' again.");

    var existing = deps.db.query(
        "SELECT 1 FROM refs WHERE dataset_id = $1::uuid AND name = $2",
        &.{ ds.id, try arena.dupeZ(u8, req.name) },
        null,
    ) catch return error.Db;
    defer existing.deinit();
    if (existing.count() > 0)
        return errorResponse(arena, .conflict, "that name is taken", "Run 'cid checkout' to work on it, or pick another name.");

    var head_rows = deps.db.query(
        "SELECT commit_id::text FROM refs WHERE dataset_id = $1::uuid AND name = 'main' AND kind = 'branch'",
        &.{ds.id},
        null,
    ) catch return error.Db;
    defer head_rows.deinit();
    if (head_rows.count() == 0)
        return errorResponse(arena, .unprocessable_entity, "main has no commits yet", "Run 'cid push' first, then 'cid branch' again.");
    const main_head = try arena.dupeZ(u8, head_rows.get(0, 0));

    deps.db.execParams(
        "INSERT INTO refs (dataset_id, name, kind, commit_id, start_commit_id) " ++
            "VALUES ($1::uuid, $2, 'branch', $3::uuid, $3::uuid)",
        &.{ ds.id, try arena.dupeZ(u8, req.name), main_head },
        null,
    ) catch return error.Db;
    return json(arena, .created, .{ .branch = req.name, .start = @as([]const u8, main_head) });
}

fn branches(arena: std.mem.Allocator, deps: *Deps, ds: Dataset) HandleError!Response {
    var rows = deps.db.query(
        "SELECT name, commit_id::text FROM refs WHERE dataset_id = $1::uuid AND kind = 'branch' ORDER BY name",
        &.{ds.id},
        null,
    ) catch return error.Db;
    defer rows.deinit();
    const Entry = struct { name: []const u8, commit: []const u8 };
    const list = try arena.alloc(Entry, rows.count());
    for (list, 0..) |*e, i| {
        e.* = .{
            .name = try arena.dupe(u8, rows.get(i, 0)),
            .commit = try arena.dupe(u8, rows.get(i, 1)),
        };
    }
    return json(arena, .ok, .{ .branches = list });
}

const MergeBody = struct { name: []const u8, author: []const u8 = "user:unknown" };

/// `cid merge <name>` into main. Overlapping changes stop the merge and
/// are listed; nothing is resolved silently (invariant 9).
fn merge(arena: std.mem.Allocator, deps: *Deps, ds: Dataset, body: []const u8) HandleError!Response {
    const req = parseBody(MergeBody, arena, body) orelse return error.BadRequest;

    var branch_rows = deps.db.query(
        "SELECT commit_id::text, start_commit_id::text FROM refs " ++
            "WHERE dataset_id = $1::uuid AND name = $2 AND kind = 'branch'",
        &.{ ds.id, try arena.dupeZ(u8, req.name) },
        null,
    ) catch return error.Db;
    defer branch_rows.deinit();
    if (branch_rows.count() == 0 or eql(req.name, "main"))
        return errorResponse(arena, .not_found, "no such branch", "Run 'cid branch <name>' to create one.");
    const branch_head = try arena.dupeZ(u8, branch_rows.get(0, 0));
    const branch_start = try arena.dupeZ(u8, branch_rows.get(0, 1));
    if (eql(branch_head, branch_start))
        return errorResponse(arena, .unprocessable_entity, "the branch has no commits of its own", "Push commits on the branch first, then merge.");

    var main_rows = deps.db.query(
        "SELECT commit_id::text FROM refs WHERE dataset_id = $1::uuid AND name = 'main' AND kind = 'branch'",
        &.{ds.id},
        null,
    ) catch return error.Db;
    defer main_rows.deinit();
    const main_head = try arena.dupeZ(u8, main_rows.get(0, 0));

    const base = release_mod.stateRows(arena, deps.db, ds.id, branch_start) catch return error.Db;
    const ours = release_mod.stateRows(arena, deps.db, ds.id, main_head) catch return error.Db;
    const theirs = release_mod.stateRows(arena, deps.db, ds.id, branch_head) catch return error.Db;

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

    var diag: pg.Diag = .{};
    deps.db.exec("BEGIN", &diag) catch return error.Db;
    errdefer deps.db.exec("ROLLBACK", null) catch {};
    deps.db.execParams(
        "SELECT pg_advisory_xact_lock(hashtextextended($1 || '/main', 0))",
        &.{ds.id},
        &diag,
    ) catch return error.Db;

    var rev_floor: ?Uuid = null;
    {
        var cutoff_rows = deps.db.query(
            "SELECT cutoff_rev::text FROM commits WHERE commit_id = $1::uuid",
            &.{main_head},
            &diag,
        ) catch return error.Db;
        defer cutoff_rows.deinit();
        if (cutoff_rows.count() > 0) rev_floor = Uuid.parse(cutoff_rows.get(0, 0)) catch null;
    }

    var last_rev: Uuid = undefined;
    for (branch_changes.keys(), branch_changes.values()) |path, change| {
        const rev = Uuid.nextAfter(deps.io, rev_floor);
        rev_floor = rev;
        last_rev = rev;
        switch (change) {
            .add => |a| try insertAddRevision(arena, deps, &diag, ds, "main", rev, path, a.hash, a.size, req.author),
            .delete => try insertDeleteRevision(arena, deps, &diag, ds, "main", rev, path, req.author),
        }
    }

    const merge_id = Uuid.nextAfter(deps.io, Uuid.parse(main_head) catch null);
    const message = try std.fmt.allocPrint(arena, "Merge branch '{s}'", .{req.name});
    deps.db.execParams(
        "INSERT INTO commits (commit_id, dataset_id, branch, parent_id, merge_parent_id, cutoff_rev, message, author, authored_at) " ++
            "VALUES ($1::uuid, $2::uuid, 'main', $3::uuid, $4::uuid, $5::uuid, $6, $7, now())",
        &.{
            try arena.dupeZ(u8, &merge_id.toString()),
            ds.id,
            main_head,
            branch_head,
            try arena.dupeZ(u8, &last_rev.toString()),
            try arena.dupeZ(u8, message),
            try arena.dupeZ(u8, req.author),
        },
        &diag,
    ) catch return error.Db;
    deps.db.execParams(
        "UPDATE refs SET commit_id = $2::uuid WHERE dataset_id = $1::uuid AND name = 'main' AND kind = 'branch'",
        &.{ ds.id, try arena.dupeZ(u8, &merge_id.toString()) },
        &diag,
    ) catch return error.Db;
    deps.db.exec("COMMIT", &diag) catch return error.Db;

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
fn registerItems(arena: std.mem.Allocator, deps: *Deps, ds: Dataset, body: []const u8) HandleError!Response {
    _ = ds;
    const req = parseBody(RegisterItemsBody, arena, body) orelse return error.BadRequest;
    if (req.items.len > 1000) return error.BadRequest;
    var diag: pg.Diag = .{};
    for (req.items) |item| {
        if (!validHashHex(item.hash)) return error.BadRequest;
        if (try isPurged(arena, deps, item.hash))
            return errorResponse(arena, .unprocessable_entity, "that content was purged and cannot come back", "Remove or replace the file, then register again.");
        const key = itemKey(arena, item.hash) catch return error.OutOfMemory;
        const stored = deps.s3.headObject(arena, key) catch return error.Storage;
        const size = stored orelse
            return errorResponse(arena, .unprocessable_entity, "an item is missing from storage", "Upload it through the check-hashes URLs first, then register again.");
        if (size != item.size)
            return errorResponse(arena, .unprocessable_entity, "an item's size does not match what storage holds", "Re-upload the file, then register again.");
        const meta = try std.fmt.allocPrintSentinel(arena, "{f}", .{std.json.fmt(.{
            .width = item.width,
            .height = item.height,
        }, .{ .emit_null_optional_fields = false })}, 0);
        deps.db.execParams(
            "INSERT INTO items (item_hash, size_bytes, media_type, meta) VALUES (decode($1, 'hex'), $2::bigint, $3, $4::jsonb) " ++
                "ON CONFLICT (item_hash) DO UPDATE SET meta = items.meta || excluded.meta",
            &.{ try arena.dupeZ(u8, item.hash), try intZ(arena, item.size), try arena.dupeZ(u8, item.media_type), meta },
            &diag,
        ) catch return error.Db;
    }
    return json(arena, .ok, .{ .registered = req.items.len });
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
fn serverCommit(arena: std.mem.Allocator, deps: *Deps, ds: Dataset, body: []const u8) HandleError!Response {
    const req = parseBody(ServerCommitBody, arena, body) orelse return error.BadRequest;
    if (req.message.len == 0 or req.author.len == 0) return error.BadRequest;
    const branch_z = try arena.dupeZ(u8, req.branch);

    var diag: pg.Diag = .{};
    deps.db.exec("BEGIN", &diag) catch return error.Db;
    errdefer deps.db.exec("ROLLBACK", null) catch {};
    deps.db.execParams(
        "SELECT pg_advisory_xact_lock(hashtextextended($1 || '/' || $2, 0))",
        &.{ ds.id, branch_z },
        &diag,
    ) catch return error.Db;

    const parent: ?[]const u8 = blk: {
        var rows = deps.db.query(
            "SELECT commit_id::text FROM refs WHERE dataset_id = $1::uuid AND name = $2 AND kind = 'branch'",
            &.{ ds.id, branch_z },
            &diag,
        ) catch return error.Db;
        defer rows.deinit();
        break :blk if (rows.count() == 0) null else try arena.dupe(u8, rows.get(0, 0));
    };
    const parent_cutoff: ?[]const u8 = blk: {
        const p = parent orelse break :blk null;
        var rows = deps.db.query(
            "SELECT cutoff_rev::text FROM commits WHERE commit_id = $1::uuid",
            &.{try arena.dupeZ(u8, p)},
            &diag,
        ) catch return error.Db;
        defer rows.deinit();
        break :blk if (rows.count() == 0) null else try arena.dupe(u8, rows.get(0, 0));
    };

    // The cutoff: the newest revision on this branch, item or annotation.
    const floor_z = try arena.dupeZ(u8, parent_cutoff orelse "00000000-0000-0000-0000-000000000000");
    var max_rows = deps.db.query(
        "SELECT rev_id::text FROM (" ++
            "  SELECT rev_id FROM item_revisions WHERE dataset_id = $1::uuid AND branch = $2 AND rev_id > $3::uuid " ++
            "  UNION ALL " ++
            "  SELECT rev_id FROM annotation_revisions WHERE dataset_id = $1::uuid AND branch = $2 AND rev_id > $3::uuid) u " ++
            "ORDER BY rev_id DESC LIMIT 1",
        &.{ ds.id, branch_z, floor_z },
        &diag,
    ) catch return error.Db;
    defer max_rows.deinit();
    if (max_rows.count() == 0 or max_rows.isNull(0, 0)) {
        deps.db.exec("ROLLBACK", null) catch {};
        return errorResponse(arena, .unprocessable_entity, "nothing new to commit on this branch", "Write revisions first, then commit again.");
    }
    const cutoff = try arena.dupeZ(u8, max_rows.get(0, 0));

    const commit_id = Uuid.nextAfter(deps.io, if (parent) |p| (Uuid.parse(p) catch null) else null);
    if (parent) |p| {
        deps.db.execParams(
            "INSERT INTO commits (commit_id, dataset_id, branch, parent_id, cutoff_rev, message, author, authored_at) " ++
                "VALUES ($1::uuid, $2::uuid, $3, $4::uuid, $5::uuid, $6, $7, now())",
            &.{ try arena.dupeZ(u8, &commit_id.toString()), ds.id, branch_z, try arena.dupeZ(u8, p), cutoff, try arena.dupeZ(u8, req.message), try arena.dupeZ(u8, req.author) },
            &diag,
        ) catch return error.Db;
    } else {
        deps.db.execParams(
            "INSERT INTO commits (commit_id, dataset_id, branch, parent_id, cutoff_rev, message, author, authored_at) " ++
                "VALUES ($1::uuid, $2::uuid, $3, NULL, $4::uuid, $5, $6, now())",
            &.{ try arena.dupeZ(u8, &commit_id.toString()), ds.id, branch_z, cutoff, try arena.dupeZ(u8, req.message), try arena.dupeZ(u8, req.author) },
            &diag,
        ) catch return error.Db;
    }
    deps.db.execParams(
        "INSERT INTO refs (dataset_id, name, kind, commit_id) VALUES ($1::uuid, $2, 'branch', $3::uuid) " ++
            "ON CONFLICT (dataset_id, name) DO UPDATE SET commit_id = excluded.commit_id",
        &.{ ds.id, branch_z, try arena.dupeZ(u8, &commit_id.toString()) },
        &diag,
    ) catch return error.Db;
    deps.db.exec("COMMIT", &diag) catch return error.Db;

    return json(arena, .created, .{ .commit = &commit_id.toString() });
}

fn isPurged(arena: std.mem.Allocator, deps: *Deps, hash: []const u8) HandleError!bool {
    var rows = deps.db.query(
        "SELECT 1 FROM purged_items WHERE item_hash = decode($1, 'hex')",
        &.{try arena.dupeZ(u8, hash)},
        null,
    ) catch return error.Db;
    defer rows.deinit();
    return rows.count() > 0;
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
