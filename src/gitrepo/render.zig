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
    items: usize,
};

pub const ClassCount = struct { name: []const u8, count: usize };
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
    manifest_sha256_hex: []const u8,
    created_at_ms: u64,
    /// Sorted by path, as state-at-commit returns them.
    items: []const Item,
    /// Every release, newest first (this one included).
    releases: []const ReleaseInfo,
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

pub fn renderAll(arena: std.mem.Allocator, input: Input) ![]const File {
    var out: std.ArrayList(File) = .empty;
    try out.append(arena, .{ .path = "README.md", .contents = try readme(arena, input) });
    try out.append(arena, .{ .path = "CHANGELOG.md", .contents = try changelog(arena, input) });
    try out.append(arena, .{ .path = "release.json", .contents = try releaseJson(arena, input) });
    try out.append(arena, .{ .path = "stats.yaml", .contents = try statsYaml(arena, input) });
    try out.append(arena, .{ .path = ".cid", .contents = try marker(arena, input) });
    if (input.items.len < files_txt_limit) {
        try out.append(arena, .{ .path = "files.txt", .contents = try filesTxt(arena, input) });
    }
    if (std.mem.eql(u8, input.kind, "annotated")) {
        try out.append(arena, .{ .path = "classes.yaml", .contents = try classesYaml(arena, input) });
        if (input.policy) |policy| {
            const md = try std.fmt.allocPrint(arena, "# Labelling policy {s}\n\nThe policy version this release's annotations were made under.\n\n```json\n{s}\n```\n", .{ policy.version, policy.body_json });
            try out.append(arena, .{ .path = "policy.md", .contents = md });
        }
    }
    return out.items;
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
    var total: u64 = 0;
    for (input.items) |item| total += item.size;
    var size_buf: [32]u8 = undefined;
    return std.fmt.allocPrint(arena,
        \\# {s}
        \\
        \\A dataset versioned with **cid · Controlled Iterative Datasets**. This
        \\repository is cid's readable record of releases: cid writes it, people
        \\read it. The data itself lives in cid.
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
        input.items.len,
        humanSize(&size_buf, total),
        &fmtDate(input.created_at_ms),
        input.git_url,
        input.server_url,
        input.dataset_name,
        input.release,
    });
}

fn changelog(arena: std.mem.Allocator, input: Input) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "# Changelog\n");
    for (input.releases) |r| {
        try out.print(arena, "\n## {s} — {s}\n\n{s}\n\n{d} items.\n", .{
            r.name, &fmtDate(r.created_at_ms), r.message, r.items,
        });
    }
    return out.items;
}

fn releaseJson(arena: std.mem.Allocator, input: Input) ![]const u8 {
    return std.fmt.allocPrint(arena, "{f}\n", .{std.json.fmt(.{
        .dataset = input.dataset_name,
        .release = input.release,
        .commit = input.commit_id,
        .manifest_sha256 = input.manifest_sha256_hex,
        .created_at = &fmtDate(input.created_at_ms),
        .items = input.items.len,
        .clone = input.git_url,
        .dashboard = input.server_url,
    }, .{ .whitespace = .indent_2 })});
}

fn statsYaml(arena: std.mem.Allocator, input: Input) ![]const u8 {
    var total: u64 = 0;
    for (input.items) |item| total += item.size;

    // Counts per file extension, sorted by extension (one value per line so
    // git diffs between releases read clearly).
    var exts: std.StringArrayHashMapUnmanaged(u64) = .empty;
    for (input.items) |item| {
        const gop = try exts.getOrPut(arena, extensionOf(item.path));
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }
    exts.sortUnstable(struct {
        keys: []const []const u8,
        pub fn lessThan(self: @This(), a: usize, b: usize) bool {
            return std.mem.lessThan(u8, self.keys[a], self.keys[b]);
        }
    }{ .keys = exts.keys() });

    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "release: {s}\nitems: {d}\nbytes: {d}\nfiles_by_extension:\n", .{
        input.release, input.items.len, total,
    });
    for (exts.keys(), exts.values()) |ext, count| {
        try out.print(arena, "  \"{s}\": {d}\n", .{ ext, count });
    }
    if (input.classes.len > 0) {
        var ann_total: usize = 0;
        for (input.classes) |c| ann_total += c.count;
        try out.print(arena, "annotations: {d}\nannotations_by_class:\n", .{ann_total});
        for (input.classes) |c| try out.print(arena, "  \"{s}\": {d}\n", .{ c.name, c.count });
    }
    if (input.splits.len > 0) {
        try out.appendSlice(arena, "items_by_split:\n");
        for (input.splits) |sp| try out.print(arena, "  \"{s}\": {d}\n", .{ sp.name, sp.count });
    }
    return out.items;
}

fn filesTxt(arena: std.mem.Allocator, input: Input) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (input.items) |item| {
        try out.print(arena, "{s}\t{d}\t{s}\n", .{ item.path, item.size, item.hash_hex[0..12] });
    }
    return out.items;
}

fn marker(arena: std.mem.Allocator, input: Input) ![]const u8 {
    return std.fmt.allocPrint(arena, "cid-marker 1\nserver {s}\ndataset {s}\n", .{
        input.server_url, input.dataset_name,
    });
}

fn extensionOf(path: []const u8) []const u8 {
    const base_start = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| i + 1 else 0;
    const base = path[base_start..];
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return "(none)";
    if (dot == 0) return "(none)"; // dotfiles
    return base[dot..];
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
        .manifest_sha256_hex = "ab" ** 32,
        .created_at_ms = 1769904000000, // 2026-02-01
        .items = &.{
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
