//! Where a version's derived files live in storage (CLAUDE.md, storage
//! layout), named in one place for the server that writes them and for
//! `cid admin gc`, which keeps every one a row still names: an items file
//! (`states/`) or an export (`exports/`), each a `version_files` row, and
//! a pair's diff as the CLI reads it (`diffs/…jsonl.gz`), a
//! `version_diffs` row. Each is named by its subset and its content, so a
//! file rebuilt with other content (a provisional one written again, a
//! format changed) lands under a new key and the old one is left behind.

const std = @import("std");
const content_hash = @import("../util/hash.zig");

/// A version's items file (`kind` "state") or one of its exports (any
/// other kind: "jsonl", "yolo", "hf", "coco", "voc").
pub fn fileKey(arena: std.mem.Allocator, dataset_id: []const u8, commit_id: []const u8, kind: []const u8, subset_key: []const u8, file_hash: []const u8) error{OutOfMemory}![]const u8 {
    const sub = content_hash.hex(subset_key);
    if (std.mem.eql(u8, kind, "state"))
        return std.fmt.allocPrint(arena, "states/{s}/{s}-{s}-{s}.jsonl.gz", .{ dataset_id, commit_id, sub[0..16], file_hash[0..16] });
    return std.fmt.allocPrint(arena, "exports/{s}/{s}/{s}-{s}-{s}.jsonl.gz", .{ dataset_id, commit_id, kind, sub[0..16], file_hash[0..16] });
}

/// What changed between two versions, as `cid diff` streams it.
pub fn diffKey(arena: std.mem.Allocator, dataset_id: []const u8, a: []const u8, b: []const u8, file_hash: []const u8) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(arena, "diffs/{s}/{s}-{s}-{s}.jsonl.gz", .{ dataset_id, a, b, file_hash[0..16] });
}

/// The prefixes whose objects are derived files: anything there no row
/// names is left over. Under `diffs/` only the `.jsonl.gz` files are; the
/// compare's Parquet files there are named by the pair alone.
pub const prefixes = [_][]const u8{ "states/", "exports/", "diffs/" };

pub fn isDerived(key: []const u8) bool {
    if (std.mem.startsWith(u8, key, "diffs/")) return std.mem.endsWith(u8, key, ".jsonl.gz");
    return std.mem.startsWith(u8, key, "states/") or std.mem.startsWith(u8, key, "exports/");
}

test "derived keys are the server's, and only the files a row can name are derived" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const h = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const sub = content_hash.hex("{}");
    try std.testing.expectEqualStrings(
        try std.fmt.allocPrint(arena, "states/d/c-{s}-0123456789abcdef.jsonl.gz", .{sub[0..16]}),
        try fileKey(arena, "d", "c", "state", "{}", h),
    );
    try std.testing.expectEqualStrings(
        try std.fmt.allocPrint(arena, "exports/d/c/yolo-{s}-0123456789abcdef.jsonl.gz", .{sub[0..16]}),
        try fileKey(arena, "d", "c", "yolo", "{}", h),
    );
    try std.testing.expectEqualStrings("diffs/d/a-b-0123456789abcdef.jsonl.gz", try diffKey(arena, "d", "a", "b", h));
    try std.testing.expect(isDerived("diffs/d/a-b-0123456789abcdef.jsonl.gz"));
    try std.testing.expect(!isDerived("diffs/d/a-b.d1.items.parquet"));
    try std.testing.expect(isDerived("exports/d/c/jsonl-x-y.jsonl.gz"));
    try std.testing.expect(!isDerived("manifests/d/c.manifest"));
}
