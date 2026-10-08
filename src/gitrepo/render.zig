//! Rendering a release's small files for the dataset repository
//! (docs/git-repository.md). Pure and deterministic: the same inputs
//! always produce the same bytes — no wall-clock timestamps, sorted
//! keys, fixed formats — so re-rendering a release never creates a new
//! git commit.

const std = @import("std");

pub const ReleaseInfo = struct {
    name: []const u8,
    message: []const u8,
    created_at_ms: u64,
    items: u64,
    /// What changed since the release before it (`refs.changes`), and
    /// which release that was; null for the first release.
    changes_from: ?[]const u8 = null,
    changes: ?Changes = null,
};

/// Counts only, so a restricted dataset shows them too.
pub const Changes = struct {
    added: u64 = 0,
    modified: u64 = 0,
    deleted: u64 = 0,
    ann_added: u64 = 0,
    ann_changed: u64 = 0,
    ann_removed: u64 = 0,
};

pub const ClassCount = struct { name: []const u8, count: u64 };
pub const Policy = struct { version: []const u8, body_json: []const u8 };

pub const Input = struct {
    dataset_name: []const u8,
    kind: []const u8 = "files",
    /// Annotated datasets: classes sorted by name (the yolo index order),
    /// split counts, and the newest policy used in this release.
    classes: []const ClassCount = &.{},
    splits: []const ClassCount = &.{},
    policy: ?Policy = null,
    git_url: []const u8,
    server_url: []const u8,
    release: []const u8,
    commit_id: []const u8,
    manifest_hash_hex: []const u8,
    created_at_ms: u64,
    items: u64,
    bytes: u64,
    /// Files per type, as every other view spells types (".jpg", "file").
    types: []const ClassCount = &.{},
    /// The release's items by path, when there are fewer than
    /// files_txt_limit of them; files.txt is written from these.
    files: []const Item = &.{},
    /// Every release, newest first (this one included).
    releases: []const ReleaseInfo,
    /// The card as it was when this release was made (`refs.card`, a JSON
    /// object of text fields), never the live one: editing the card later
    /// cannot change what this release renders.
    card: ?[]const u8 = null,
    /// A restricted dataset sends counts and nothing more (invariant 21):
    /// no file or class names, no policy, no card, no release notes.
    restricted: bool = false,
};

pub const Item = struct {
    path: []const u8,
    hash_hex: []const u8,
    size: u64,
};

pub const File = struct {
    path: []const u8,
    contents: []const u8,
};

/// files.txt is written only below this count (docs/git-repository.md).
pub const files_txt_limit = 10_000;

/// Every path cid ever writes in a dataset repository, and so the only
/// ones it may remove: a file `renderAll` stops writing (files.txt once a
/// dataset is restricted) goes, and anything else in the repository,
/// someone's code or docs, is theirs and is never touched.
pub const owned_paths = [_][]const u8{
    "README.md", "CHANGELOG.md", "release.json", "stats.yaml",
    ".cid",      "files.txt",    "classes.yaml", "policy.md",
};

pub fn renderAll(arena: std.mem.Allocator, input: Input) ![]const File {
    var out: std.ArrayList(File) = .empty;
    try out.append(arena, .{ .path = "README.md", .contents = try readme(arena, input) });
    try out.append(arena, .{ .path = "CHANGELOG.md", .contents = try changelog(arena, input) });
    try out.append(arena, .{ .path = "release.json", .contents = try releaseJson(arena, input) });
    try out.append(arena, .{ .path = "stats.yaml", .contents = try statsYaml(arena, input) });
    try out.append(arena, .{ .path = ".cid", .contents = try marker(arena, input) });
    if (input.restricted) return out.items;
    if (input.items < files_txt_limit) {
        try out.append(arena, .{ .path = "files.txt", .contents = try filesTxt(arena, input) });
    }
    if (std.mem.eql(u8, input.kind, "annotated")) {
        try out.append(arena, .{ .path = "classes.yaml", .contents = try classesYaml(arena, input) });
        if (input.policy) |policy| {
            const md = try std.fmt.allocPrint(arena, "# Labelling policy {s}\n\nThe policy version this release's annotations were made under.\n\n```json\n{s}\n```\n", .{ policy.version, policy.body_json });
            try out.append(arena, .{ .path = "policy.md", .contents = md });
        }
    }
    for (out.items) |f| std.debug.assert(owns(f.path));
    try fitAll(arena, out.items, input);
    return out.items;
}

/// Limits on what a release puts in git, so a long card or a changelog
/// that grows every release never makes the repository heavy: each file
/// at most `file_limit` bytes, and all of them together `release_limit`.
pub const file_limit = 1 << 20;
pub const release_limit = 5 << 20;

/// Cuts any file over its share at a line end and says so, with the
/// link to the full release on the dashboard. The largest file is cut
/// first when the release as a whole is over, so the outcome depends on
/// the contents alone. `.cid` and release.json are read by programs and
/// small by construction; they are never cut.
fn fitAll(arena: std.mem.Allocator, files: []File, input: Input) !void {
    const url = try std.fmt.allocPrint(arena, "{s}/d/{s}?release={s}", .{ input.server_url, input.dataset_name, input.release });
    for (files) |*f| if (cuttable(f.path) and f.contents.len > file_limit) {
        f.contents = try cut(arena, f.*, file_limit, url);
    };
    while (true) {
        var total: usize = 0;
        var largest: ?*File = null;
        for (files) |*f| {
            total += f.contents.len;
            if (cuttable(f.path) and (largest == null or f.contents.len > largest.?.contents.len)) largest = f;
        }
        if (total <= release_limit) return;
        const f = largest orelse return;
        const keep = f.contents.len - (total - release_limit);
        const shorter = try cut(arena, f.*, keep, url);
        if (shorter.len >= f.contents.len) return; // nothing left to cut
        f.contents = shorter;
    }
}

fn cuttable(path: []const u8) bool {
    return !std.mem.eql(u8, path, ".cid") and !std.mem.eql(u8, path, "release.json");
}

/// The file's first lines, `limit` bytes at most with the note, and the
/// note: in Markdown a line of its own, elsewhere a `#` comment.
fn cut(arena: std.mem.Allocator, f: File, limit: usize, url: []const u8) ![]const u8 {
    const note = if (std.mem.endsWith(u8, f.path, ".md"))
        try std.fmt.allocPrint(arena, "\n*cid cut this file here to keep the repository small. The whole release: {s}*\n", .{url})
    else
        try std.fmt.allocPrint(arena, "# cid cut this file here to keep the repository small. The whole release: {s}\n", .{url});
    const room = if (limit > note.len) limit - note.len else 0;
    var end = @min(room, f.contents.len);
    // At a line end when there is one, else at a character boundary.
    if (std.mem.lastIndexOfScalar(u8, f.contents[0..end], '\n')) |nl| {
        end = nl + 1;
    } else while (end > 0 and (f.contents[end] & 0xC0) == 0x80) end -= 1;
    return std.fmt.allocPrint(arena, "{s}{s}", .{ f.contents[0..end], note });
}

pub fn owns(path: []const u8) bool {
    for (owned_paths) |p| if (std.mem.eql(u8, p, path)) return true;
    return false;
}

/// index → name, the same order the yolo export numbers classes.
fn classesYaml(arena: std.mem.Allocator, input: Input) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (input.classes, 0..) |c, i| {
        try out.print(arena, "{d}: {s}\n", .{ i, c.name });
    }
    return out.items;
}

fn readme(arena: std.mem.Allocator, input: Input) ![]const u8 {
    var size_buf: [32]u8 = undefined;
    const head = try std.fmt.allocPrint(arena,
        \\# {s}
        \\
        \\A dataset versioned with **cid · Controlled Iterative Datasets**. cid keeps
        \\its readable record of releases here (this README, CHANGELOG.md and the
        \\other files it writes); anything else in this repository is left as it
        \\is. The data itself lives in cid.
        \\
        \\**Latest release here: {s}** · {d} items · {s} · {s}
        \\
        \\Get the data (the git URL works as a cid address):
        \\
        \\```
        \\cid clone {s}
        \\```
        \\
        \\Browse this release: {s}/d/{s}?release={s}
        \\
    , .{
        input.dataset_name,
        input.release,
        input.items,
        humanSize(&size_buf, input.bytes),
        &fmtDate(input.created_at_ms),
        input.git_url,
        input.server_url,
        input.dataset_name,
        input.release,
    });
    if (input.restricted) return std.fmt.allocPrint(arena, "{s}\nThis dataset is restricted: this repository holds counts only.\n", .{head});
    const card = input.card orelse return head;
    return std.fmt.allocPrint(arena, "{s}{s}", .{ head, try cardSection(arena, card) });
}

/// The card's fields in a fixed order (the known ones first, then any
/// others by name), text as written. A card that is not an object of
/// text fields renders nothing rather than guessing.
fn cardSection(arena: std.mem.Allocator, card_json: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, card_json, .{}) catch return "";
    if (parsed != .object) return "";
    const known = [_][2][]const u8{
        .{ "purpose", "Purpose" },       .{ "collection", "How it was collected" },
        .{ "license", "License" },       .{ "provenance", "Provenance" },
        .{ "known_gaps", "Known gaps" },
    };
    var out: std.ArrayList(u8) = .empty;
    for (known) |k| {
        const v = parsed.object.get(k[0]) orelse continue;
        if (v != .string or v.string.len == 0) continue;
        try out.print(arena, "\n**{s}:** {s}\n", .{ k[1], v.string });
    }
    var others: std.ArrayList([]const u8) = .empty;
    var it = parsed.object.iterator();
    outer: while (it.next()) |e| {
        for (known) |k| if (std.mem.eql(u8, k[0], e.key_ptr.*)) continue :outer;
        if (e.value_ptr.* == .string and e.value_ptr.string.len > 0) try others.append(arena, e.key_ptr.*);
    }
    std.mem.sort([]const u8, others.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    for (others.items) |key| try out.print(arena, "\n**{s}:** {s}\n", .{ key, parsed.object.get(key).?.string });
    if (out.items.len == 0) return "";
    return std.fmt.allocPrint(arena, "\n## About this dataset\n{s}", .{out.items});
}

fn changelog(arena: std.mem.Allocator, input: Input) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "# Changelog\n");
    for (input.releases, 0..) |r, i| {
        if (input.restricted) {
            try out.print(arena, "\n## {s} — {s}\n\n{d} items.", .{ r.name, &fmtDate(r.created_at_ms), r.items });
        } else {
            try out.print(arena, "\n## {s} — {s}\n\n{s}\n\n{d} items.", .{
                r.name, &fmtDate(r.created_at_ms), r.message, r.items,
            });
        }
        // Newest first, so the last is the first release.
        if (r.changes) |c| {
            try out.print(arena, " Since {s}: {s}", .{ r.changes_from orelse "the release before", try changeLine(arena, c, input.kind) });
        } else if (i == input.releases.len - 1) {
            try out.appendSlice(arena, " The first release.");
        }
        try out.append(arena, '\n');
    }
    return out.items;
}

/// "3 files added, 1 modified, 2 deleted; 40 annotations added, 2 changed,
/// 1 removed." — the annotation half only where there are annotations.
fn changeLine(arena: std.mem.Allocator, c: Changes, kind: []const u8) ![]const u8 {
    const files = if (c.added + c.modified + c.deleted == 0)
        try arena.dupe(u8, "no files changed")
    else
        try std.fmt.allocPrint(arena, "{d} file{s} added, {d} modified, {d} deleted", .{ c.added, plural(c.added), c.modified, c.deleted });
    const annotated = std.mem.eql(u8, kind, "annotated") or c.ann_added + c.ann_changed + c.ann_removed > 0;
    if (!annotated) return std.fmt.allocPrint(arena, "{s}.", .{files});
    return std.fmt.allocPrint(arena, "{s}; {d} annotation{s} added, {d} changed, {d} removed.", .{ files, c.ann_added, plural(c.ann_added), c.ann_changed, c.ann_removed });
}

fn plural(n: u64) []const u8 {
    return if (n == 1) "" else "s";
}

fn releaseJson(arena: std.mem.Allocator, input: Input) ![]const u8 {
    return std.fmt.allocPrint(arena, "{f}\n", .{std.json.fmt(.{
        .dataset = input.dataset_name,
        .release = input.release,
        .commit = input.commit_id,
        .manifest_hash = input.manifest_hash_hex,
        .created_at = &fmtDate(input.created_at_ms),
        .items = input.items,
        .changes_from = if (input.releases.len > 0) input.releases[0].changes_from else null,
        .changes = if (input.releases.len > 0) input.releases[0].changes else null,
        .clone = input.git_url,
        .dashboard = input.server_url,
    }, .{ .whitespace = .indent_2 })});
}

fn statsYaml(arena: std.mem.Allocator, input: Input) ![]const u8 {
    // Counts per file type, sorted by type (one value per line so git
    // diffs between releases read clearly).
    const types = try arena.dupe(ClassCount, input.types);
    std.mem.sort(ClassCount, types, {}, struct {
        fn lessThan(_: void, x: ClassCount, y: ClassCount) bool {
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.lessThan);

    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "release: {s}\nitems: {d}\nbytes: {d}\nfiles_by_extension:\n", .{
        input.release, input.items, input.bytes,
    });
    for (types) |t| {
        try out.print(arena, "  \"{s}\": {d}\n", .{ t.name, t.count });
    }
    if (input.classes.len > 0) {
        var ann_total: usize = 0;
        for (input.classes) |c| ann_total += c.count;
        if (input.restricted) {
            try out.print(arena, "annotations: {d}\n", .{ann_total});
            return out.items;
        }
        try out.print(arena, "annotations: {d}\nannotations_by_class:\n", .{ann_total});
        for (input.classes) |c| try out.print(arena, "  \"{s}\": {d}\n", .{ c.name, c.count });
    }
    if (input.splits.len > 0 and !input.restricted) {
        try out.appendSlice(arena, "items_by_split:\n");
        for (input.splits) |sp| try out.print(arena, "  \"{s}\": {d}\n", .{ sp.name, sp.count });
    }
    return out.items;
}

fn filesTxt(arena: std.mem.Allocator, input: Input) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (input.files) |item| {
        try out.print(arena, "{s}\t{d}\t{s}\n", .{ item.path, item.size, item.hash_hex[0..12] });
    }
    return out.items;
}

fn marker(arena: std.mem.Allocator, input: Input) ![]const u8 {
    return std.fmt.allocPrint(arena, "cid-marker 1\nserver {s}\ndataset {s}\n", .{
        input.server_url, input.dataset_name,
    });
}

/// "2026-10-01" from Unix milliseconds: the release's own date, nothing
/// finer, so renders stay stable.
fn fmtDate(ms: u64) [10]u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = ms / 1000 };
    const year_day = es.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    var out: [10]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        year_day.year, month_day.month.numeric(), month_day.day_index + 1,
    }) catch unreachable;
    return out;
}

fn humanSize(buf: []u8, n: u64) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var value: f64 = @floatFromInt(n);
    var unit: usize = 0;
    while (value >= 1024 and unit < units.len - 1) : (unit += 1) value /= 1024;
    if (unit == 0) return std.fmt.bufPrint(buf, "{d} B", .{n}) catch "?";
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ value, units[unit] }) catch "?";
}

test "rendering is deterministic and complete" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const input: Input = .{
        .dataset_name = "org/datasets/demo",
        .git_url = "git@example.invalid:org/datasets/demo.git",
        .server_url = "https://cid.example",
        .release = "v1.0.0",
        .commit_id = "01a00000-0000-7000-8000-000000000001",
        .manifest_hash_hex = "ab" ** 32,
        .created_at_ms = 1769904000000, // 2026-02-01
        .items = 2,
        .bytes = 2058,
        .types = &.{ .{ .name = ".wav", .count = 1 }, .{ .name = ".txt", .count = 1 } },
        .files = &.{
            .{ .path = "audio/a.wav", .hash_hex = "cd" ** 32, .size = 2048 },
            .{ .path = "notes.txt", .hash_hex = "ef" ** 32, .size = 10 },
        },
        .releases = &.{.{ .name = "v1.0.0", .message = "first", .created_at_ms = 1769904000000, .items = 2 }},
    };

    const files = try renderAll(arena, input);
    const again = try renderAll(arena, input);
    try std.testing.expectEqual(files.len, again.len);
    for (files, again) |a, b| {
        try std.testing.expectEqualStrings(a.path, b.path);
        try std.testing.expectEqualStrings(a.contents, b.contents);
    }

    var seen_marker = false;
    for (files) |f| {
        if (std.mem.eql(u8, f.path, ".cid")) {
            seen_marker = true;
            try std.testing.expect(std.mem.indexOf(u8, f.contents, "org/datasets/demo") != null);
        }
        if (std.mem.eql(u8, f.path, "stats.yaml")) {
            try std.testing.expect(std.mem.indexOf(u8, f.contents, "items: 2") != null);
            try std.testing.expect(std.mem.indexOf(u8, f.contents, "\".wav\": 1") != null);
        }
        if (std.mem.eql(u8, f.path, "README.md")) {
            try std.testing.expect(std.mem.indexOf(u8, f.contents, "2026-02-01") != null);
            try std.testing.expect(std.mem.indexOf(u8, f.contents, "cid clone") != null);
        }
        if (std.mem.eql(u8, f.path, "files.txt")) {
            try std.testing.expect(std.mem.indexOf(u8, f.contents, "audio/a.wav\t2048\t") != null);
        }
    }
    try std.testing.expect(seen_marker);
}

test "the changelog says what changed since the release before, in counts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var input: Input = .{
        .dataset_name = "org/datasets/calls",
        .git_url = "git@example.invalid:org/datasets/calls.git",
        .server_url = "https://cid.example",
        .release = "v2",
        .commit_id = "01a00000-0000-7000-8000-000000000002",
        .manifest_hash_hex = "ab" ** 32,
        .created_at_ms = 1769904000000,
        .items = 3,
        .bytes = 10,
        .releases = &.{
            .{ .name = "v2", .message = "March calls", .created_at_ms = 1769904000000, .items = 3, .changes_from = "v1", .changes = .{ .added = 2, .modified = 1, .deleted = 1 } },
            .{ .name = "v1", .message = "first", .created_at_ms = 1769817600000, .items = 2 },
        },
    };
    const files_log = try changelog(arena, input);
    try std.testing.expect(std.mem.indexOf(u8, files_log, "3 items. Since v1: 2 files added, 1 modified, 1 deleted.\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, files_log, "2 items. The first release.\n") != null);
    // No annotations in a files dataset, so no annotation half.
    try std.testing.expect(std.mem.indexOf(u8, files_log, "annotation") == null);

    // An annotated dataset says what happened to its annotations, even
    // when no file changed; restricted, the counts stay and the message goes.
    input.kind = "annotated";
    input.restricted = true;
    input.releases = &.{
        .{ .name = "v2", .message = "relabelled alice-smith", .created_at_ms = 1769904000000, .items = 3, .changes_from = "v1", .changes = .{ .ann_added = 1, .ann_changed = 4 } },
        .{ .name = "v1", .message = "first", .created_at_ms = 1769817600000, .items = 3 },
    };
    const ann_log = try changelog(arena, input);
    try std.testing.expect(std.mem.indexOf(u8, ann_log, "Since v1: no files changed; 1 annotation added, 4 changed, 0 removed.\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, ann_log, "alice-smith") == null);
    const json = try releaseJson(arena, input);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"changes_from\": \"v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ann_changed\": 4") != null);
}

test "a restricted release renders counts only; the card renders from its snapshot" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var input: Input = .{
        .dataset_name = "org/datasets/faces",
        .kind = "annotated",
        .git_url = "git@example.invalid:org/datasets/faces.git",
        .server_url = "https://cid.example",
        .release = "v1",
        .commit_id = "01a00000-0000-7000-8000-000000000001",
        .manifest_hash_hex = "ab" ** 32,
        .created_at_ms = 1769904000000,
        .items = 1,
        .bytes = 10,
        .classes = &.{.{ .name = "alice-smith", .count = 3 }},
        .splits = &.{.{ .name = "secret-split", .count = 1 }},
        .policy = .{ .version = "p1", .body_json = "{\"rule\":\"label alice-smith\"}" },
        .files = &.{.{ .path = "people/alice-smith.jpg", .hash_hex = "cd" ** 32, .size = 10 }},
        .releases = &.{.{ .name = "v1", .message = "added alice-smith", .created_at_ms = 1769904000000, .items = 1 }},
        .card = "{\"purpose\":\"face matching for alice-smith\",\"license\":\"internal\"}",
        .restricted = true,
    };
    for (try renderAll(arena, input)) |f| {
        if (std.mem.indexOf(u8, f.contents, "alice-smith") != null or std.mem.indexOf(u8, f.contents, "secret-split") != null) {
            std.debug.print("restricted content in {s}:\n{s}\n", .{ f.path, f.contents });
            return error.RestrictedContentRendered;
        }
        try std.testing.expect(!std.mem.eql(u8, f.path, "files.txt"));
        try std.testing.expect(!std.mem.eql(u8, f.path, "classes.yaml"));
        try std.testing.expect(!std.mem.eql(u8, f.path, "policy.md"));
    }

    // Not restricted: the card's fields, known ones first, in words.
    input.restricted = false;
    input.card = "{\"zeta\":\"last\",\"license\":\"CC-BY-4.0\",\"purpose\":\"find people\",\"empty\":\"\",\"n\":3}";
    const readme_text = (try renderAll(arena, input))[0].contents;
    const purpose = std.mem.indexOf(u8, readme_text, "**Purpose:** find people").?;
    const license = std.mem.indexOf(u8, readme_text, "**License:** CC-BY-4.0").?;
    const zeta = std.mem.indexOf(u8, readme_text, "**zeta:** last").?;
    try std.testing.expect(purpose < license and license < zeta);
    try std.testing.expect(std.mem.indexOf(u8, readme_text, "empty") == null);
}

test "no file over 1 MB and no release over 5 MB reaches git, and a cut says where the rest is" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A card of 3 MB, 9,000 releases whose messages are 400 bytes each,
    // and 9,999 files with long paths.
    const long = try arena.alloc(u8, 3 << 20);
    @memset(long, 'x');
    for (0..long.len / 100) |i| long[i * 100] = '\n';
    const card = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{ .purpose = long }, .{})});
    const releases = try arena.alloc(ReleaseInfo, 9000);
    for (releases, 0..) |*r, i| r.* = .{ .name = try std.fmt.allocPrint(arena, "v{d}", .{9000 - i}), .message = "m" ** 400, .created_at_ms = 0, .items = 9999 };
    const files = try arena.alloc(Item, 9999);
    for (files, 0..) |*f, i| f.* = .{ .path = try std.fmt.allocPrint(arena, "{s}/{d:0>5}.wav", .{ "deep/" ** 40, i }), .hash_hex = "ab" ** 32, .size = 1 };
    const input: Input = .{
        .dataset_name = "org/datasets/big",
        .git_url = "git@example.invalid:org/datasets/big.git",
        .server_url = "https://cid.example",
        .release = "v9000",
        .commit_id = "01a00000-0000-7000-8000-000000000001",
        .manifest_hash_hex = "ab" ** 32,
        .created_at_ms = 0,
        .items = 9999,
        .bytes = 9999,
        .files = files,
        .releases = releases,
        .card = card,
    };
    const out = try renderAll(arena, input);
    var total: usize = 0;
    for (out) |f| {
        try std.testing.expect(f.contents.len <= file_limit);
        try std.testing.expect(std.unicode.utf8ValidateSlice(f.contents));
        total += f.contents.len;
    }
    try std.testing.expect(total <= release_limit);
    for (out) |f| if (std.mem.eql(u8, f.path, "README.md") or std.mem.eql(u8, f.path, "CHANGELOG.md") or std.mem.eql(u8, f.path, "files.txt")) {
        const tail = if (std.mem.endsWith(u8, f.path, ".md")) "release=v9000*\n" else "release=v9000\n";
        try std.testing.expect(std.mem.endsWith(u8, f.contents, tail));
        try std.testing.expect(std.mem.indexOf(u8, f.contents, "The whole release: https://cid.example/d/org/datasets/big?") != null);
        // The newest releases stay; the cut takes the oldest.
        if (std.mem.eql(u8, f.path, "CHANGELOG.md")) try std.testing.expect(std.mem.startsWith(u8, f.contents, "# Changelog\n\n## v9000 "));
    };
    // Cut the same way every time, so a re-render makes no new commit.
    const again = try renderAll(arena, input);
    for (out, again) |a, b| try std.testing.expectEqualStrings(a.contents, b.contents);

    // A small release is untouched.
    var small = input;
    small.card = null;
    small.releases = releases[0..1];
    small.files = files[0..2];
    small.items = 2;
    for (try renderAll(arena, small)) |f| try std.testing.expect(std.mem.indexOf(u8, f.contents, "cid cut this file") == null);
}
