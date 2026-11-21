//! The Hugging Face door: the part of the Hub's HTTP API that the
//! `huggingface_hub` client (and `datasets`, `transformers` above it)
//! reads, answered from cid, so `HF_ENDPOINT=<cid server>` with a cid
//! personal token in `HF_TOKEN` downloads a dataset at any release.
//! Read-only (docs/roadmap.md, decisions 1–3 and 9): writes stay `cid add`,
//! `commit`, `push`. No Xet: files are whole, behind presigned URLs, and
//! no `X-Xet-*` header is ever sent, so the client downloads over plain
//! HTTP with no configuration.
//!
//! An annotated dataset is served as its item files, at their paths, plus
//! its annotations: one gzip JSON-lines file per split under
//! `_annotations/` (the jsonl export's lines, built once per version and
//! kept; a release's ahead of its first reader, by the background worker),
//! and a generated `README.md` whose `configs:` name them as the
//! splits, so `load_dataset` reads them with no guessing.
//!
//! Like api.zig it is HTTP-free: `handle` takes a method and a target and
//! answers a status, headers, a body and, for a file, the redirect to it.
//!
//! The facts this follows were read from `huggingface_hub` 2.4.0,
//! `datasets` 5.2.0 and `transformers` 5.23.0 (docs/roadmap.md, C1):
//! errors are read from `X-Error-Code`; a file's metadata from the 302
//! itself (`X-Repo-Commit`, `X-Linked-Etag`, `X-Linked-Size`), which the
//! client then follows without the token; a tree pages by an absolute
//! `Link: <…>; rel="next"`.

const std = @import("std");
const api = @import("api.zig");
const browse = @import("browse/browse.zig");
const versions = @import("../core/version.zig");
const content_hash = @import("../util/hash.zig");
const Uuid = @import("../util/uuid7.zig").Uuid;

pub const Header = struct { name: []const u8, value: []const u8 };

pub const Answer = struct {
    status: std.http.Status,
    body: []const u8 = "",
    content_type: []const u8 = "application/json",
    headers: []const Header = &.{},
    /// A file: where its bytes are (a presigned URL), sent as `Location`.
    location: ?[]const u8 = null,
};

/// A tree page: at most this many files (and their folders) per answer.
pub const tree_page = 1000;
/// `paths-info` answers at most this many paths per request.
pub const max_paths = 1000;

const Kind = enum { datasets, models };

/// `base` is where the client reached this server (`http://host:port`),
/// for the absolute links a tree's next page needs.
pub fn handle(
    arena: std.mem.Allocator,
    deps: *api.Deps,
    scope: anytype,
    method: []const u8,
    target: []const u8,
    given: api.Caller,
    body: []const u8,
    base: []const u8,
) Answer {
    return handleInner(arena, deps, scope, method, target, given, body, base) catch |err| switch (err) {
        error.OutOfMemory => fail(arena, .internal_server_error, null, "out of memory", "Try again.", null),
        error.Db => fail(arena, .internal_server_error, null, "database error", "Check the server logs, then try again.", null),
        error.Storage => fail(arena, .internal_server_error, null, "storage error", "Check the server logs, then try again.", null),
        error.BadRequest, error.Collected => fail(arena, .bad_request, null, "this request is not one the Hugging Face door answers", "Update huggingface_hub, or use 'cid clone'.", null),
    };
}

fn handleInner(
    arena: std.mem.Allocator,
    deps: *api.Deps,
    scope: anytype,
    method: []const u8,
    target: []const u8,
    given: api.Caller,
    body: []const u8,
    base: []const u8,
) api.HandleError!Answer {
    const q_at = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    const path = target[0..q_at];
    const query = if (q_at < target.len) target[q_at + 1 ..] else "";

    // Segments are split before they are decoded: a revision or a file
    // name may carry an encoded '/'.
    var segs: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, path, '/');
    _ = it.next(); // the empty segment before the leading '/'
    while (it.next()) |s| try segs.append(arena, s);
    const parts = segs.items;

    const is_get = std.mem.eql(u8, method, "GET") or std.mem.eql(u8, method, "HEAD");
    // /datasets/{ns}/{name}/resolve/{rev}/{path…}
    if (is_get and parts.len >= 6 and std.mem.eql(u8, parts[0], "datasets") and std.mem.eql(u8, parts[3], "resolve"))
        return resolveFile(arena, deps, scope, given, .datasets, try decode(arena, parts[1]), try decode(arena, parts[2]), try decode(arena, parts[4]), try joinDecoded(arena, parts[5..]));
    // /{ns}/{name}/resolve/{rev}/{path…}: a model's file, at the root as
    // on the Hub (never a dashboard page: those all start /d/).
    if (is_get and parts.len >= 5 and std.mem.eql(u8, parts[2], "resolve") and isModelRoot(parts[0]))
        return resolveFile(arena, deps, scope, given, .models, try decode(arena, parts[0]), try decode(arena, parts[1]), try decode(arena, parts[3]), try joinDecoded(arena, parts[4..]));
    // /api/{datasets|models}/{ns}/{name}[/{action}/{rev}[/{path…}]]
    if (parts.len >= 4 and std.mem.eql(u8, parts[0], "api")) {
        const kind: Kind = if (std.mem.eql(u8, parts[1], "datasets")) .datasets else if (std.mem.eql(u8, parts[1], "models")) .models else return notFound(arena);
        const ns = try decode(arena, parts[2]);
        const name = try decode(arena, parts[3]);
        const action = if (parts.len > 4) parts[4] else "";
        const rev: []const u8 = if (parts.len > 5) try decode(arena, parts[5]) else "main";
        if (is_get and parts.len == 4) return info(arena, deps, scope, given, kind, ns, name, "main");
        if (is_get and std.mem.eql(u8, action, "revision") and parts.len == 6) return info(arena, deps, scope, given, kind, ns, name, rev);
        if (is_get and std.mem.eql(u8, action, "refs") and parts.len == 5) return refs(arena, deps, scope, given, kind, ns, name);
        if (is_get and std.mem.eql(u8, action, "tree") and parts.len >= 6)
            return tree(arena, deps, scope, given, kind, ns, name, rev, try joinDecoded(arena, parts[6..]), query, base, target);
        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, action, "paths-info") and parts.len == 6)
            return pathsInfo(arena, deps, scope, given, kind, ns, name, rev, body);
    }
    return notFound(arena);
}

/// Whether `/{first}/…/resolve/…` can be a model's file: not one of the
/// server's own prefixes.
pub fn isModelRoot(first: []const u8) bool {
    for ([_][]const u8{ "api", "datasets", "d", "v0", "auth", "assets", "fonts" }) |own| if (std.mem.eql(u8, first, own)) return false;
    return first.len > 0;
}

/// Whether a path the dashboard's catch-all received is a model's file
/// (`/{ns}/{name}/resolve/{rev}/{path…}`), for the door to answer.
pub fn isModelFile(path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    _ = it.next();
    const first = it.next() orelse return false;
    _ = it.next() orelse return false;
    const third = it.next() orelse return false;
    _ = it.next() orelse return false; // the revision
    const rest = it.next() orelse return false;
    return isModelRoot(first) and std.mem.eql(u8, third, "resolve") and rest.len > 0;
}

// ---------------------------------------------------------------------------
// Repositories and revisions
// ---------------------------------------------------------------------------

/// A Hugging Face repo id is `{ns}/{name}`; a cid path has any depth.
/// `org/datasets__speech-id` (the full form) is `org/datasets/speech-id`;
/// `org/speech-id` (the short form) is the one dataset of this kind in
/// `org` the caller can read whose path ends in `/speech-id`.
const Found = union(enum) {
    dataset: api.Dataset,
    /// Nothing the caller can read answers to it (whether it exists or
    /// not: existence is never told to someone who cannot read it).
    none,
    /// The short form names several: their full forms.
    several: []const []const u8,
};

fn findRepo(arena: std.mem.Allocator, deps: *api.Deps, scope: anytype, caller: api.Caller, kind: Kind, ns: []const u8, name: []const u8) api.HandleError!Found {
    var candidates: []const []const u8 = &.{};
    if (std.mem.indexOf(u8, name, "__") != null) {
        const full = try std.mem.concat(arena, u8, &.{ ns, "/", try std.mem.replaceOwned(u8, arena, name, "__", "/") });
        candidates = try arena.dupe([]const u8, &.{full});
    } else {
        candidates = deps.db.raw([]const u8, scope, "SELECT name FROM datasets WHERE left(name, length($1) + 1) = $1 || '/' " ++
            "AND right(name, length($2) + 1) = '/' || $2 ORDER BY name", .{ ns, name }) catch return error.Db;
    }
    var readable: std.ArrayList(api.Dataset) = .empty;
    for (candidates) |cand| {
        const ds = api.lookupDataset(arena, deps, scope, cand) orelse continue;
        const fits = switch (kind) {
            .models => std.mem.eql(u8, ds.kind, "model"),
            .datasets => !std.mem.eql(u8, ds.kind, "model"),
        };
        if (!fits or !api.authorized(arena, deps, scope, caller, ds.name, .read)) continue;
        try readable.append(arena, ds);
    }
    if (readable.items.len == 0) return .none;
    if (readable.items.len == 1) return .{ .dataset = readable.items[0] };
    const forms = try arena.alloc([]const u8, readable.items.len);
    for (forms, readable.items) |*f, ds| f.* = try repoId(arena, ds.name);
    return .{ .several = forms };
}

/// A cid path as a repo id, in the full form: `org/datasets/x` is
/// `org/datasets__x`; a two-segment path is itself.
pub fn repoId(arena: std.mem.Allocator, cid_path: []const u8) error{OutOfMemory}![]const u8 {
    const slash = std.mem.indexOfScalar(u8, cid_path, '/') orelse return cid_path;
    const rest = try std.mem.replaceOwned(u8, arena, cid_path[slash + 1 ..], "/", "__");
    return std.mem.concat(arena, u8, &.{ cid_path[0 .. slash + 1], rest });
}

/// A commit as the client wants a commit id: 40 hex digits. Its 32 hex
/// digits, then eight zeros, so it maps back without a table, and the
/// client's cache can use it (it recognises a revision as a commit by
/// `[0-9a-f]{40}` and then never asks again).
pub fn commitAlias(arena: std.mem.Allocator, commit_id: []const u8) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (commit_id) |c| if (c != '-') try out.append(arena, std.ascii.toLower(c));
    try out.appendSlice(arena, "00000000");
    return out.items;
}

fn aliasToCommit(arena: std.mem.Allocator, rev: []const u8) error{OutOfMemory}!?[]const u8 {
    if (rev.len == 36 and Uuid.parse(rev) != error.InvalidUuid) return rev;
    if (rev.len != 40 or !std.mem.endsWith(u8, rev, "00000000")) return null;
    for (rev) |c| if (!std.ascii.isHex(c)) return null;
    const h = rev[0..32];
    return try std.fmt.allocPrint(arena, "{s}-{s}-{s}-{s}-{s}", .{ h[0..8], h[8..12], h[12..16], h[16..20], h[20..32] });
}

const Version = struct {
    pub const nilo_table = .projection;
    commit: []const u8,
    at_ms: i64,
};

/// A revision as the client names it: a release, a branch (`main`), or a
/// commit (its 40-digit alias, or its UUID). A release wins over a branch
/// of the same name, as it never moves.
fn version(arena: std.mem.Allocator, deps: *api.Deps, scope: anytype, ds: api.Dataset, rev: []const u8) api.HandleError!?Version {
    const at_ms = "(extract(epoch from c.recorded_at) * 1000)::bigint AS at_ms";
    if (try aliasToCommit(arena, rev)) |commit| {
        return deps.db.rawOne(Version, scope, "SELECT c.commit_id::text AS commit, " ++ at_ms ++ " FROM commits c " ++
            "WHERE c.commit_id = $1::uuid AND c.dataset_id = $2::uuid", .{ commit, ds.id }) catch return error.Db;
    }
    const row = deps.db.rawOne(Version, scope, "SELECT c.commit_id::text AS commit, " ++ at_ms ++ " FROM refs r JOIN commits c ON c.commit_id = r.commit_id " ++
        "WHERE r.dataset_id = $1::uuid AND r.name = $2 ORDER BY (r.kind = 'release') DESC LIMIT 1", .{ ds.id, rev }) catch return error.Db;
    return row;
}

/// The caller, the repository and the version every route starts from,
/// or the answer that says which of them is missing.
const Start = union(enum) {
    ok: struct { caller: api.Caller, ds: api.Dataset, v: Version, sha: []const u8 },
    refused: Answer,
};

fn start(arena: std.mem.Allocator, deps: *api.Deps, scope: anytype, given: api.Caller, kind: Kind, ns: []const u8, name: []const u8, rev: []const u8) api.HandleError!Start {
    const caller = switch (try api.resolveCaller(arena, deps, scope, given)) {
        .caller => |c| c,
        .refused => return .{ .refused = repoNotFound(arena, kind, ns, name, given) },
    };
    const ds = switch (try findRepo(arena, deps, scope, caller, kind, ns, name)) {
        .dataset => |d| d,
        .none => return .{ .refused = repoNotFound(arena, kind, ns, name, given) },
        .several => |forms| return .{ .refused = fail(arena, .not_found, "RepoNotFound", try std.fmt.allocPrint(arena, "'{s}/{s}' names {d} repositories", .{ ns, name, forms.len }), try std.fmt.allocPrint(arena, "Name one in full: {s}.", .{try std.mem.join(arena, ", ", forms)}), null) },
    };
    const v = (try version(arena, deps, scope, ds, rev)) orelse
        return .{ .refused = fail(arena, .not_found, "RevisionNotFound", try std.fmt.allocPrint(arena, "{s} has no release, branch or commit '{s}'", .{ ds.name, rev }), "Pass a release name as revision= (see the dataset's history on the dashboard), or leave it out for main.", null) };
    return .{ .ok = .{ .caller = caller, .ds = ds, .v = v, .sha = try commitAlias(arena, v.commit) } };
}

fn repoNotFound(arena: std.mem.Allocator, kind: Kind, ns: []const u8, name: []const u8, given: api.Caller) Answer {
    const what = if (kind == .models) "model" else "dataset";
    // A 401 when no token came: the client then tells its user to log in.
    const status: std.http.Status = if (given.header == null and given.account == null) .unauthorized else .not_found;
    return fail(arena, status, "RepoNotFound", std.fmt.allocPrint(arena, "no {s} is named {s}/{s}, or your token cannot read it", .{ what, ns, name }) catch "repository not found", "Set HF_TOKEN to a cid personal token (the dashboard's Tokens page) of someone who can read it, and check the name: org/datasets__name names the dataset org/datasets/name.", null);
}

// ---------------------------------------------------------------------------
// An annotated dataset's annotations, and its README
// ---------------------------------------------------------------------------

pub const annotations_dir = "_annotations";

/// One split's annotations file: its path, the split name `datasets` reads
/// (letters, digits and `_` only), and the cid splits it holds (`""` for
/// items with none; empty for every item).
const Split = struct { path: []const u8, name: []const u8, splits: []const []const u8 };

fn isAnnotated(ds: api.Dataset) bool {
    return std.mem.eql(u8, ds.kind, "annotated");
}

/// The version's splits as files: one per split, `unsplit` for the items
/// with none; one `train` holding everything when there are no splits.
fn splitsOf(arena: std.mem.Allocator, deps: *api.Deps, scope: anytype, ds: api.Dataset, commit: []const u8) api.HandleError![]const Split {
    const st = versions.stats(arena, deps.db, scope, ds.id, commit) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Db,
    };
    var out: std.ArrayList(Split) = .empty;
    if (st.splits.len == 0) {
        try out.append(arena, .{ .path = annotations_dir ++ "/train.jsonl.gz", .name = "train", .splits = &.{} });
        return out.items;
    }
    var in_splits: u64 = 0;
    for (st.splits) |sp| {
        in_splits += sp.count;
        const name = try splitName(arena, sp.name);
        try out.append(arena, .{
            .path = try std.fmt.allocPrint(arena, "{s}/{s}.jsonl.gz", .{ annotations_dir, name }),
            .name = name,
            .splits = try arena.dupe([]const u8, &.{sp.name}),
        });
    }
    if (st.items > in_splits)
        try out.append(arena, .{ .path = annotations_dir ++ "/unsplit.jsonl.gz", .name = "unsplit", .splits = try arena.dupe([]const u8, &.{""}) });
    return out.items;
}

/// A split name as `datasets` accepts one (`\w+`): anything else becomes `_`.
fn splitName(arena: std.mem.Allocator, raw: []const u8) error{OutOfMemory}![]const u8 {
    if (raw.len == 0) return "unsplit";
    const out = try arena.dupe(u8, raw);
    for (out) |*c| if (!(std.ascii.isAlphanumeric(c.*) or c.* == '_')) {
        c.* = '_';
    };
    return out;
}

fn readme(arena: std.mem.Allocator, ds: api.Dataset, splits: []const Split) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "---\nconfigs:\n- config_name: default\n  data_files:\n");
    for (splits) |sp| try out.print(arena, "  - split: {s}\n    path: {s}\n", .{ sp.name, sp.path });
    try out.print(arena,
        \\---
        \\
        \\# {s}
        \\
        \\An annotated dataset versioned with cid · Controlled Iterative Datasets, served
        \\read-only to Hugging Face clients. Each split is a JSON-lines file under
        \\`{s}/`: one line per item, with its `path`, `hash` (BLAKE3), `size`,
        \\`split`, `width`, `height` and `annotations`. The items themselves are at
        \\their paths in this repository. `cid clone` gives the same release as a
        \\ready-to-train folder (`--format yolo` or `jsonl`).
        \\
    , .{ ds.name, annotations_dir });
    return out.items;
}

/// A split's file, built the first time anyone asks and kept (an export
/// of kind `hf`), with its size in storage.
const Built = struct { key: []const u8, hash: []const u8, size: u64 };

fn built(arena: std.mem.Allocator, deps: *api.Deps, scope: anytype, ds: api.Dataset, commit: []const u8, sp: Split) api.HandleError!Built {
    const file = switch (try api.ensureVersionFile(arena, deps, scope, ds, commit, .hf, .{ .splits = sp.splits })) {
        .ready => |f| f,
        .failed => return error.Storage, // the jsonl lines never fail
    };
    const size = (deps.s3.headObject(scope, file.key) catch return error.Storage) orelse return error.Storage;
    return .{ .key = file.key, .hash = file.file_hash, .size = size };
}

/// Every split's file of a version, built now: the server's background
/// worker does this for an annotated release, ahead of its first reader. A
/// Hugging Face client gives up on a file's metadata after 10 s, and the
/// first build of a 1M-item release's train split takes about a minute.
pub fn prepareSplits(arena: std.mem.Allocator, deps: *api.Deps, scope: anytype, ds: api.Dataset, commit: []const u8) api.HandleError!void {
    for (try splitsOf(arena, deps, scope, ds, commit)) |sp| _ = try built(arena, deps, scope, ds, commit, sp);
}

fn findSplit(splits: []const Split, path: []const u8) ?Split {
    for (splits) |sp| if (std.mem.eql(u8, sp.path, path)) return sp;
    return null;
}

/// The README and the split files, as tree entries (sizes real: a
/// streaming reader trusts them), under `prefix` ("" or the folder's).
fn annotatedEntries(arena: std.mem.Allocator, deps: *api.Deps, scope: anytype, ds: api.Dataset, commit: []const u8, prefix: []const u8, recursive: bool, out: *std.ArrayList(Entry)) api.HandleError!void {
    const splits = try splitsOf(arena, deps, scope, ds, commit);
    if (prefix.len == 0) {
        const text = try readme(arena, ds, splits);
        try out.append(arena, fileEntry("README.md", text.len, try arena.dupe(u8, &content_hash.hex(text))));
        try out.append(arena, folderEntry(annotations_dir));
        if (!recursive) return;
    } else if (!std.mem.eql(u8, prefix, annotations_dir ++ "/")) return;
    for (splits) |sp| {
        const b = try built(arena, deps, scope, ds, commit, sp);
        try out.append(arena, fileEntry(sp.path, b.size, b.hash));
    }
}

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------

fn info(arena: std.mem.Allocator, deps: *api.Deps, scope: anytype, given: api.Caller, kind: Kind, ns: []const u8, name: []const u8, rev: []const u8) api.HandleError!Answer {
    const s = switch (try start(arena, deps, scope, given, kind, ns, name, rev)) {
        .ok => |s| s,
        .refused => |a| return a,
    };
    return jsonAnswer(arena, .{
        ._id = s.ds.id,
        .id = try std.fmt.allocPrint(arena, "{s}/{s}", .{ ns, name }),
        .sha = s.sha,
        .private = true,
        .disabled = false,
        .gated = false,
        .lastModified = try isoDate(arena, s.v.at_ms),
        .tags = [_][]const u8{},
        .downloads = 0,
        .likes = 0,
    }, &.{});
}

fn refs(arena: std.mem.Allocator, deps: *api.Deps, scope: anytype, given: api.Caller, kind: Kind, ns: []const u8, name: []const u8) api.HandleError!Answer {
    const caller = switch (try api.resolveCaller(arena, deps, scope, given)) {
        .caller => |c| c,
        .refused => return repoNotFound(arena, kind, ns, name, given),
    };
    const ds = switch (try findRepo(arena, deps, scope, caller, kind, ns, name)) {
        .dataset => |d| d,
        else => return repoNotFound(arena, kind, ns, name, given),
    };
    const Row = struct {
        pub const nilo_table = .projection;
        name: []const u8,
        kind: []const u8,
        commit: []const u8,
    };
    const rows = deps.db.raw(Row, scope, "SELECT name, kind, commit_id::text AS commit FROM refs WHERE dataset_id = $1::uuid ORDER BY kind, name", .{ds.id}) catch return error.Db;
    const Ref = struct { name: []const u8, ref: []const u8, targetCommit: []const u8 };
    var branches: std.ArrayList(Ref) = .empty;
    var tags: std.ArrayList(Ref) = .empty;
    for (rows) |r| {
        const is_release = std.mem.eql(u8, r.kind, "release");
        const ref: Ref = .{
            .name = r.name,
            .ref = try std.fmt.allocPrint(arena, "refs/{s}/{s}", .{ if (is_release) "tags" else "heads", r.name }),
            .targetCommit = try commitAlias(arena, r.commit),
        };
        try (if (is_release) &tags else &branches).append(arena, ref);
    }
    return jsonAnswer(arena, .{ .branches = branches.items, .tags = tags.items, .converts = [_]Ref{} }, &.{});
}

const Entry = struct {
    type: []const u8,
    oid: []const u8,
    size: u64,
    path: []const u8,
};

/// A folder has no content hash of its own; the client never reads one.
const folder_oid = "0000000000000000000000000000000000000000";

fn fileEntry(path: []const u8, size: u64, hash: []const u8) Entry {
    return .{ .type = "file", .oid = hash, .size = size, .path = path };
}

fn folderEntry(path: []const u8) Entry {
    return .{ .type = "directory", .oid = folder_oid, .size = 0, .path = path };
}

/// The version's browse index (built once per version and kept), or the
/// answer for while another version is being indexed.
fn indexOf(arena: std.mem.Allocator, deps: *api.Deps, scope: anytype, ds: api.Dataset, commit: []const u8) api.HandleError!?api.BrowseIndex {
    return api.browseIndex(arena, deps, scope, ds, commit);
}

fn busy(arena: std.mem.Allocator) Answer {
    return fail(arena, .service_unavailable, null, "the server is indexing another version", "Try again in a minute.", null);
}

fn tree(
    arena: std.mem.Allocator,
    deps: *api.Deps,
    scope: anytype,
    given: api.Caller,
    kind: Kind,
    ns: []const u8,
    name: []const u8,
    rev: []const u8,
    dir: []const u8,
    query: []const u8,
    base: []const u8,
    target: []const u8,
) api.HandleError!Answer {
    const s = switch (try start(arena, deps, scope, given, kind, ns, name, rev)) {
        .ok => |s| s,
        .refused => |a| return a,
    };
    const recursive = blk: {
        const r = queryParam(query, "recursive") orelse break :blk false;
        break :blk std.ascii.eqlIgnoreCase(r, "true") or std.mem.eql(u8, r, "1");
    };
    const cursor: ?[]const u8 = if (queryParam(query, "cursor")) |c| try decodeForm(arena, c) else null;
    // Not the client's (it never sends one): a smaller page, for tests.
    const limit: u32 = if (queryParam(query, "limit")) |l| @min(tree_page, std.fmt.parseInt(u32, l, 10) catch return error.BadRequest) else tree_page;
    const index = (try indexOf(arena, deps, scope, s.ds, s.v.commit)) orelse return busy(arena);
    const prefix = if (dir.len == 0) "" else try std.mem.concat(arena, u8, &.{ std.mem.trimEnd(u8, dir, "/"), "/" });

    var entries: std.ArrayList(Entry) = .empty;
    var next: ?[]const u8 = null;
    // An annotated dataset's README and annotation files, on the first page.
    if (isAnnotated(s.ds) and cursor == null) {
        try annotatedEntries(arena, deps, scope, s.ds, s.v.commit, prefix, recursive, &entries);
        if (std.mem.eql(u8, prefix, annotations_dir ++ "/")) return jsonAnswer(arena, entries.items, &.{});
    }
    var db = try api.duckFor(arena, deps, index.dir);
    defer db.close();
    if (recursive) {
        const page = try api.browseQuery(deps, browse.filesUnder, .{ arena, &db, index.files, prefix, cursor, limit });
        // Each file's folders, once per page: the client builds its view
        // of the tree from both.
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        for (page.files) |f| {
            var i: usize = prefix.len;
            while (std.mem.indexOfScalarPos(u8, f.path, i, '/')) |slash| : (i = slash + 1) {
                const folder = f.path[0..slash];
                if ((try seen.getOrPut(arena, folder)).found_existing) continue;
                try entries.append(arena, folderEntry(folder));
            }
            try entries.append(arena, fileEntry(f.path, f.size, f.hash));
        }
        next = page.next;
    } else {
        const listing = try api.browseQuery(deps, browse.listDir, .{ arena, &db, index.files, prefix, cursor, limit });
        if (cursor == null) for (listing.folders) |f| {
            try entries.append(arena, folderEntry(try std.mem.concat(arena, u8, &.{ prefix, f.name })));
        };
        for (listing.files) |f| try entries.append(arena, fileEntry(f.path, f.size, f.hash));
        next = listing.next;
    }
    if (entries.items.len == 0 and dir.len > 0)
        return fail(arena, .not_found, "EntryNotFound", try std.fmt.allocPrint(arena, "{s} has no folder '{s}' at this version", .{ s.ds.name, dir }), "List the version's top folder, without a path.", s.sha);

    var headers: std.ArrayList(Header) = .empty;
    if (next) |after| {
        const q_at = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
        const link = try std.fmt.allocPrint(arena, "<{s}{s}?recursive={s}&cursor={s}{s}>; rel=\"next\"", .{
            base,                                                                                  target[0..q_at],
            if (recursive) "true" else "false",                                                    try escapeComponent(arena, after),
            if (limit == tree_page) "" else try std.fmt.allocPrint(arena, "&limit={d}", .{limit}),
        });
        try headers.append(arena, .{ .name = "Link", .value = link });
    }
    return jsonAnswer(arena, entries.items, headers.items);
}

fn pathsInfo(arena: std.mem.Allocator, deps: *api.Deps, scope: anytype, given: api.Caller, kind: Kind, ns: []const u8, name: []const u8, rev: []const u8, body: []const u8) api.HandleError!Answer {
    const s = switch (try start(arena, deps, scope, given, kind, ns, name, rev)) {
        .ok => |s| s,
        .refused => |a| return a,
    };
    // The client posts a form: `paths=a&paths=b&expand=false`.
    var paths: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, body, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eq], "paths")) continue;
        if (paths.items.len == max_paths) return error.BadRequest;
        try paths.append(arena, std.mem.trimEnd(u8, try decodeForm(arena, pair[eq + 1 ..]), "/"));
    }
    const index = (try indexOf(arena, deps, scope, s.ds, s.v.commit)) orelse return busy(arena);
    var db = try api.duckFor(arena, deps, index.dir);
    defer db.close();
    var entries: std.ArrayList(Entry) = .empty;
    const splits: []const Split = if (isAnnotated(s.ds)) try splitsOf(arena, deps, scope, s.ds, s.v.commit) else &.{};
    for (paths.items) |p| {
        // An annotated dataset's README and annotation files first.
        if (isAnnotated(s.ds)) {
            if (std.mem.eql(u8, p, "README.md")) {
                const text = try readme(arena, s.ds, splits);
                try entries.append(arena, fileEntry(p, text.len, try arena.dupe(u8, &content_hash.hex(text))));
                continue;
            }
            if (std.mem.eql(u8, p, annotations_dir)) {
                try entries.append(arena, folderEntry(p));
                continue;
            }
            if (findSplit(splits, p)) |sp| {
                const b = try built(arena, deps, scope, s.ds, s.v.commit, sp);
                try entries.append(arena, fileEntry(p, b.size, b.hash));
                continue;
            }
        }
        switch (try api.browseQuery(deps, browse.pathInfo, .{ arena, &db, index.files, p })) {
            .file => |f| try entries.append(arena, fileEntry(p, f.size, f.hash)),
            .folder => try entries.append(arena, folderEntry(p)),
            .none => {},
        }
    }
    return jsonAnswer(arena, entries.items, &.{});
}

/// A file at a version: the redirect to its bytes, with what the client
/// reads from the redirect itself. Answered the same to HEAD and GET.
fn resolveFile(arena: std.mem.Allocator, deps: *api.Deps, scope: anytype, given: api.Caller, kind: Kind, ns: []const u8, name: []const u8, rev: []const u8, file: []const u8) api.HandleError!Answer {
    const s = switch (try start(arena, deps, scope, given, kind, ns, name, rev)) {
        .ok => |s| s,
        .refused => |a| return a,
    };
    if (file.len == 0) return notFound(arena);
    if (isAnnotated(s.ds)) {
        const splits = try splitsOf(arena, deps, scope, s.ds, s.v.commit);
        if (std.mem.eql(u8, file, "README.md")) {
            const text = try readme(arena, s.ds, splits);
            return .{
                .status = .ok,
                .body = text,
                .content_type = "text/markdown; charset=utf-8",
                .headers = try arena.dupe(Header, &.{
                    .{ .name = "X-Repo-Commit", .value = s.sha },
                    .{ .name = "ETag", .value = try std.fmt.allocPrint(arena, "\"{s}\"", .{&content_hash.hex(text)}) },
                }),
            };
        }
        if (findSplit(splits, file)) |sp| {
            // Annotations are a restricted dataset's content too.
            if (s.ds.restricted)
                try api.logActivity(arena, deps, scope, s.ds, try api.actorOf(arena, deps, s.caller), "export", try std.fmt.allocPrint(arena, "{s} hf {s}", .{ s.v.commit, sp.name }), null);
            const b = try built(arena, deps, scope, s.ds, s.v.commit, sp);
            return redirect(arena, deps, scope, b.key, b.hash, b.size, s.sha);
        }
    }
    const where = versions.at(deps.db, scope, s.ds.id, s.v.commit) catch return error.Db;
    const Row = struct {
        pub const nilo_table = .projection;
        op: []const u8,
        hash: []const u8,
        size: i64,
        purged: bool,
    };
    const row = deps.db.rawOne(Row, scope, "SELECT r.op, encode(r.item_hash, 'hex') AS hash, coalesce(i.size_bytes, 0) AS size, " ++
        "EXISTS (SELECT 1 FROM purged_items p WHERE p.item_hash = r.item_hash) AS purged " ++
        "FROM item_revisions r LEFT JOIN items i ON i.item_hash = r.item_hash " ++
        "WHERE r.dataset_id = $1::uuid AND r.path = $2 " ++
        "AND ((r.branch = 'main' AND r.rev_id <= $5::uuid) OR (r.branch = $3 AND r.rev_id <= $4::uuid)) " ++
        "ORDER BY r.rev_id DESC LIMIT 1", .{ s.ds.id, file, where.branch, where.cutoff, where.main_cutoff }) catch return error.Db;
    const found = row orelse return entryNotFound(arena, s.ds.name, file, s.sha);
    if (std.mem.eql(u8, found.op, "delete")) return entryNotFound(arena, s.ds.name, file, s.sha);
    if (found.purged)
        return fail(arena, .not_found, "EntryNotFound", try std.fmt.allocPrint(arena, "{s} at this version holds '{s}', but its bytes were purged by an administrator", .{ s.ds.name, file }), "Leave the file out, or use another release; the dataset's owners know why it was removed.", s.sha);

    // Clear bytes of a restricted dataset are content: on the record
    // before the URL exists (invariants 11 and 20), as for any download.
    if (s.ds.restricted)
        try api.logActivity(arena, deps, scope, s.ds, try api.actorOf(arena, deps, s.caller), "download", null, .{ .items = 1 });
    const key = api.itemKey(arena, found.hash) catch return error.OutOfMemory;
    return redirect(arena, deps, scope, key, found.hash, @intCast(found.size), s.sha);
}

/// The answer for a file in storage: a redirect to a presigned URL, with
/// the metadata the client reads from the redirect itself.
fn redirect(arena: std.mem.Allocator, deps: *api.Deps, scope: anytype, key: []const u8, hash: []const u8, size: u64, sha: []const u8) api.HandleError!Answer {
    const url = deps.s3.presignGet(scope, key, api.presign_secs) catch return error.Storage;
    const etag = try std.fmt.allocPrint(arena, "\"{s}\"", .{hash});
    return .{
        .status = .found,
        .location = url,
        .headers = try arena.dupe(Header, &.{
            .{ .name = "X-Repo-Commit", .value = sha },
            .{ .name = "ETag", .value = etag },
            .{ .name = "X-Linked-Etag", .value = etag },
            .{ .name = "X-Linked-Size", .value = try std.fmt.allocPrint(arena, "{d}", .{size}) },
        }),
    };
}

fn entryNotFound(arena: std.mem.Allocator, dataset: []const u8, file: []const u8, sha: []const u8) Answer {
    return fail(arena, .not_found, "EntryNotFound", std.fmt.allocPrint(arena, "{s} has no file '{s}' at this version", .{ dataset, file }) catch "no such file", "Check the path on the dashboard's Files tab, at the same release.", sha);
}

fn notFound(arena: std.mem.Allocator) Answer {
    return fail(arena, .not_found, null, "the Hugging Face door does not answer this route", "It serves downloads (hf_hub_download, snapshot_download, load_dataset); uploads go through 'cid push'.", null);
}

// ---------------------------------------------------------------------------
// Answers and decoding
// ---------------------------------------------------------------------------

/// An error as the client reads it: `X-Error-Code` names the kind, the
/// JSON's `error` says what happened and `next` what to do.
fn fail(arena: std.mem.Allocator, status: std.http.Status, code: ?[]const u8, what: []const u8, next: []const u8, sha: ?[]const u8) Answer {
    var headers: std.ArrayList(Header) = .empty;
    if (code) |c| headers.append(arena, .{ .name = "X-Error-Code", .value = c }) catch {};
    // A missing file's 404 names the commit, so the client caches the miss.
    if (sha) |c| headers.append(arena, .{ .name = "X-Repo-Commit", .value = c }) catch {};
    headers.append(arena, .{ .name = "X-Error-Message", .value = what }) catch {};
    const body = std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{ .@"error" = what, .next = next }, .{})}) catch "{\"error\":\"out of memory\"}";
    return .{ .status = status, .body = body, .headers = headers.items };
}

fn jsonAnswer(arena: std.mem.Allocator, value: anytype, headers: []const Header) error{OutOfMemory}!Answer {
    return .{ .status = .ok, .body = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(value, .{})}), .headers = headers };
}

fn isoDate(arena: std.mem.Allocator, ms: i64) error{OutOfMemory}![]const u8 {
    const secs: u64 = @intCast(@max(0, @divFloor(ms, 1000)));
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        day.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(), @as(u64, @intCast(@mod(ms, 1000))),
    });
}

fn decode(arena: std.mem.Allocator, raw: []const u8) error{OutOfMemory}![]const u8 {
    return std.Uri.percentDecodeInPlace(try arena.dupe(u8, raw));
}

/// A form value: `+` is a space, then %XX.
fn decodeForm(arena: std.mem.Allocator, raw: []const u8) error{OutOfMemory}![]const u8 {
    const copy = try arena.dupe(u8, raw);
    std.mem.replaceScalar(u8, copy, '+', ' ');
    return std.Uri.percentDecodeInPlace(copy);
}

fn joinDecoded(arena: std.mem.Allocator, segs: []const []const u8) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (segs, 0..) |seg, i| {
        if (i > 0) try out.append(arena, '/');
        try out.appendSlice(arena, try decode(arena, seg));
    }
    return out.items;
}

fn queryParam(query: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}

/// A query value, percent-encoded for a URL.
fn escapeComponent(arena: std.mem.Allocator, raw: []const u8) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (raw) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~' or c == '/')
            try out.append(arena, c)
        else
            try out.print(arena, "%{X:0>2}", .{c});
    }
    return out.items;
}

test "a model's file path is told from the dashboard's pages" {
    try std.testing.expect(isModelFile("/org/detector/resolve/v1/config.json"));
    try std.testing.expect(isModelFile("/org/detector/resolve/main/weights/model.safetensors"));
    for ([_][]const u8{ "/d/org/resolve/v1/x", "/datasets/org/x/resolve/v1/y", "/api/models/org/x", "/org/detector/resolve/v1", "/org/detector/tree/v1/x", "/", "/keys" }) |p|
        try std.testing.expect(!isModelFile(p));
}

test "repo ids and commit aliases map both ways" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("org/datasets__speech-id", try repoId(arena, "org/datasets/speech-id"));
    try std.testing.expectEqualStrings("org/x", try repoId(arena, "org/x"));
    try std.testing.expectEqualStrings("org/a__b__c", try repoId(arena, "org/a/b/c"));
    const commit = "0190a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b";
    const alias = try commitAlias(arena, commit);
    try std.testing.expectEqualStrings("0190a1b2c3d47e5f8a9b0c1d2e3f4a5b00000000", alias);
    try std.testing.expectEqualStrings(commit, (try aliasToCommit(arena, alias)).?);
    try std.testing.expectEqualStrings(commit, (try aliasToCommit(arena, commit)).?);
    try std.testing.expect((try aliasToCommit(arena, "v1.0.0")) == null);
    try std.testing.expect((try aliasToCommit(arena, "0190a1b2c3d47e5f8a9b0c1d2e3f4a5b0000000z")) == null);
    try std.testing.expectEqualStrings("2026-11-18T12:34:56.789Z", try isoDate(arena, 1795005296789));
}
