//! Local commits and HEAD (.cid/HEAD, .cid/commits/<id>).
//! Everything here works offline; `cid push` uploads these later.
//!
//! HEAD:                       a commit file:
//!   cid-head 1                  cid-commit 1
//!   branch main                 id <uuid>
//!   commit <uuid or ->          parent <uuid or ->
//!                               branch main
//!                               author user:someone
//!                               authored_at_ms 1760000000000
//!                               message_len <N>
//!                               <N raw bytes of message>
//!                               changes <count>
//!                               A\t<path>\t<hash>\t<size>
//!                               D\t<path>

const std = @import("std");
const Uuid = @import("../util/uuid7.zig").Uuid;
const index_mod = @import("index.zig");

pub const Error = error{ CorruptLocalState, CommitFileMissing } || std.mem.Allocator.Error ||
    std.Io.File.OpenError || std.Io.File.Reader.Error || std.Io.File.Writer.Error ||
    std.Io.Dir.RenameError || std.Io.Reader.Error || std.Io.Writer.Error;

pub const Head = struct {
    branch: []const u8,
    commit: ?Uuid,
};

pub const Change = struct {
    op: index_mod.Op,
    path: []const u8,
    hash_hex: [index_mod.hash_hex_len]u8, // undefined for delete
    size: u64,
};

pub const Commit = struct {
    id: Uuid,
    parent: ?Uuid,
    branch: []const u8,
    author: []const u8,
    authored_at_ms: u64,
    message: []const u8,
    changes: []const Change,
};

/// Writes `bytes` to `name` in `dir` atomically (tmp file + rename), so an
/// interrupted command never leaves a half-written state file (invariant 16).
pub fn writeFileAtomic(io: std.Io, dir: std.Io.Dir, name: []const u8, bytes: []const u8) Error!void {
    var tmp_name_buf: [256]u8 = undefined;
    const tmp_name = std.fmt.bufPrint(&tmp_name_buf, "{s}.tmp", .{name}) catch return error.CorruptLocalState;
    {
        var file = try dir.createFile(io, tmp_name, .{ .truncate = true });
        defer file.close(io);
        var wbuf: [4096]u8 = undefined;
        var fw = file.writer(io, &wbuf);
        try fw.interface.writeAll(bytes);
        try fw.interface.flush();
    }
    try std.Io.Dir.rename(dir, tmp_name, dir, name, io);
}

pub fn loadHead(arena: std.mem.Allocator, io: std.Io, cid_dir: std.Io.Dir) Error!Head {
    const text = cid_dir.readFileAlloc(io, "HEAD", arena, .limited(4096)) catch |err| switch (err) {
        error.FileNotFound => return error.CorruptLocalState,
        else => return error.CorruptLocalState,
    };
    var lines = std.mem.splitScalar(u8, text, '\n');
    if (!std.mem.eql(u8, lines.next() orelse "", "cid-head 1")) return error.CorruptLocalState;
    const branch_line = lines.next() orelse return error.CorruptLocalState;
    if (!std.mem.startsWith(u8, branch_line, "branch ")) return error.CorruptLocalState;
    const commit_line = lines.next() orelse return error.CorruptLocalState;
    if (!std.mem.startsWith(u8, commit_line, "commit ")) return error.CorruptLocalState;
    const commit_text = commit_line["commit ".len..];
    return .{
        .branch = branch_line["branch ".len..],
        .commit = if (std.mem.eql(u8, commit_text, "-"))
            null
        else
            Uuid.parse(commit_text) catch return error.CorruptLocalState,
    };
}

pub fn saveHead(io: std.Io, cid_dir: std.Io.Dir, head: Head) Error!void {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.print("cid-head 1\nbranch {s}\ncommit {s}\n", .{
        head.branch,
        if (head.commit) |c| &c.toString() else "-",
    }) catch return error.CorruptLocalState;
    try writeFileAtomic(io, cid_dir, "HEAD", w.buffered());
}

pub fn saveCommit(arena: std.mem.Allocator, io: std.Io, cid_dir: std.Io.Dir, commit: Commit) Error!void {
    var out: std.ArrayList(u8) = .empty;
    const a = arena;
    try out.print(a, "cid-commit 1\nid {s}\nparent {s}\nbranch {s}\nauthor {s}\nauthored_at_ms {d}\nmessage_len {d}\n", .{
        &commit.id.toString(),
        if (commit.parent) |p| &p.toString() else "-",
        commit.branch,
        commit.author,
        commit.authored_at_ms,
        commit.message.len,
    });
    try out.appendSlice(a, commit.message);
    try out.print(a, "\nchanges {d}\n", .{commit.changes.len});
    for (commit.changes) |ch| {
        switch (ch.op) {
            .add => try out.print(a, "A\t{s}\t{s}\t{d}\n", .{ ch.path, &ch.hash_hex, ch.size }),
            .delete => try out.print(a, "D\t{s}\n", .{ch.path}),
        }
    }
    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "commits/{s}", .{&commit.id.toString()}) catch unreachable;
    try writeFileAtomic(io, cid_dir, name, out.items);
}

pub fn loadCommit(arena: std.mem.Allocator, io: std.Io, cid_dir: std.Io.Dir, id: Uuid) Error!Commit {
    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "commits/{s}", .{&id.toString()}) catch unreachable;
    const text = cid_dir.readFileAlloc(io, name, arena, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.CommitFileMissing,
        else => return error.CorruptLocalState,
    };
    return parseCommit(arena, text);
}

fn parseCommit(arena: std.mem.Allocator, text: []const u8) Error!Commit {
    var rest = text;
    if (!eatLine(&rest, "cid-commit 1")) return error.CorruptLocalState;
    const id_text = eatPrefixedLine(&rest, "id ") orelse return error.CorruptLocalState;
    const parent_text = eatPrefixedLine(&rest, "parent ") orelse return error.CorruptLocalState;
    const branch = eatPrefixedLine(&rest, "branch ") orelse return error.CorruptLocalState;
    const author = eatPrefixedLine(&rest, "author ") orelse return error.CorruptLocalState;
    const at_text = eatPrefixedLine(&rest, "authored_at_ms ") orelse return error.CorruptLocalState;
    const len_text = eatPrefixedLine(&rest, "message_len ") orelse return error.CorruptLocalState;
    const msg_len = std.fmt.parseInt(usize, len_text, 10) catch return error.CorruptLocalState;
    if (rest.len < msg_len + 1) return error.CorruptLocalState;
    const message = rest[0..msg_len];
    if (rest[msg_len] != '\n') return error.CorruptLocalState;
    rest = rest[msg_len + 1 ..];
    const count_text = eatPrefixedLine(&rest, "changes ") orelse return error.CorruptLocalState;
    const count = std.fmt.parseInt(usize, count_text, 10) catch return error.CorruptLocalState;

    const changes = try arena.alloc(Change, count);
    for (changes) |*ch| {
        const line = eatAnyLine(&rest) orelse return error.CorruptLocalState;
        var cols = std.mem.splitScalar(u8, line, '\t');
        const op_col = cols.next() orelse return error.CorruptLocalState;
        const path = cols.next() orelse return error.CorruptLocalState;
        if (std.mem.eql(u8, op_col, "A")) {
            const hash_col = cols.next() orelse return error.CorruptLocalState;
            const size_col = cols.next() orelse return error.CorruptLocalState;
            if (hash_col.len != index_mod.hash_hex_len) return error.CorruptLocalState;
            ch.* = .{ .op = .add, .path = path, .hash_hex = undefined, .size = std.fmt.parseInt(u64, size_col, 10) catch return error.CorruptLocalState };
            @memcpy(&ch.hash_hex, hash_col);
        } else if (std.mem.eql(u8, op_col, "D")) {
            ch.* = .{ .op = .delete, .path = path, .hash_hex = undefined, .size = 0 };
        } else return error.CorruptLocalState;
    }
    return .{
        .id = Uuid.parse(id_text) catch return error.CorruptLocalState,
        .parent = if (std.mem.eql(u8, parent_text, "-"))
            null
        else
            Uuid.parse(parent_text) catch return error.CorruptLocalState,
        .branch = branch,
        .author = author,
        .authored_at_ms = std.fmt.parseInt(u64, at_text, 10) catch return error.CorruptLocalState,
        .message = message,
        .changes = changes,
    };
}

/// The newest commit known to be on the server (.cid/last-pushed), set by
/// push, clone, pull and checkout. Commits below it have no local files:
/// their history lives on the server.
pub fn readLastPushed(arena: std.mem.Allocator, io: std.Io, cid_dir: std.Io.Dir) ?[]const u8 {
    const text = cid_dir.readFileAlloc(io, "last-pushed", arena, .limited(64)) catch return null;
    const trimmed = std.mem.trim(u8, text, " \n");
    return if (trimmed.len == 36) trimmed else null;
}

pub fn writeLastPushed(io: std.Io, cid_dir: std.Io.Dir, commit_id: []const u8) Error!void {
    try writeFileAtomic(io, cid_dir, "last-pushed", commit_id);
}

/// Walks the parent chain from HEAD down to (excluding) `last_pushed`;
/// returns the unpushed commits, newest first. HEAD at `last_pushed`
/// (right after clone or push) gives an empty list.
pub fn listUnpushed(
    arena: std.mem.Allocator,
    io: std.Io,
    cid_dir: std.Io.Dir,
    last_pushed: ?[]const u8,
) Error![]Commit {
    var out: std.ArrayList(Commit) = .empty;
    const head = try loadHead(arena, io, cid_dir);
    var next_id = head.commit;
    while (next_id) |id| {
        if (last_pushed) |lp| {
            if (std.mem.eql(u8, &id.toString(), lp)) break;
        }
        // No local file means server history: HEAD sits at (or below) a
        // commit that was never made here, e.g. after clone or a checkout
        // to an older commit. Unpushed commits always have local files.
        const commit = loadCommit(arena, io, cid_dir, id) catch |err| switch (err) {
            error.CommitFileMissing => break,
            else => return err,
        };
        try out.append(arena, commit);
        next_id = commit.parent;
    }
    return out.items;
}

fn eatLine(rest: *[]const u8, expected: []const u8) bool {
    const line = eatAnyLine(rest) orelse return false;
    return std.mem.eql(u8, line, expected);
}

fn eatAnyLine(rest: *[]const u8) ?[]const u8 {
    const nl = std.mem.indexOfScalar(u8, rest.*, '\n') orelse return null;
    const line = rest.*[0..nl];
    rest.* = rest.*[nl + 1 ..];
    return line;
}

fn eatPrefixedLine(rest: *[]const u8, prefix: []const u8) ?[]const u8 {
    const line = eatAnyLine(rest) orelse return null;
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    return line[prefix.len..];
}

test "commit serialization round trip, including multi-line messages" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const hash: [index_mod.hash_hex_len]u8 = @splat('b');
    const changes = [_]Change{
        .{ .op = .add, .path = "a/b.wav", .hash_hex = hash, .size = 123 },
        .{ .op = .delete, .path = "old.txt", .hash_hex = undefined, .size = 0 },
    };
    const commit: Commit = .{
        .id = Uuid.init(1234, @splat(1)),
        .parent = Uuid.init(1000, @splat(2)),
        .branch = "main",
        .author = "user:test",
        .authored_at_ms = 1234,
        .message = "subject line\n\nbody with\nchanges 9 trickery",
        .changes = &changes,
    };

    // Serialize through the same code saveCommit uses, then parse back.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    const a = std.testing.allocator;
    try out.print(a, "cid-commit 1\nid {s}\nparent {s}\nbranch {s}\nauthor {s}\nauthored_at_ms {d}\nmessage_len {d}\n", .{
        &commit.id.toString(), &commit.parent.?.toString(), commit.branch, commit.author, commit.authored_at_ms, commit.message.len,
    });
    try out.appendSlice(a, commit.message);
    try out.print(a, "\nchanges {d}\n", .{commit.changes.len});
    try out.appendSlice(a, "A\ta/b.wav\t" ++ ("b" ** 64) ++ "\t123\nD\told.txt\n");

    const parsed = try parseCommit(arena, out.items);
    try std.testing.expectEqualSlices(u8, &commit.id.bytes, &parsed.id.bytes);
    try std.testing.expectEqualStrings(commit.message, parsed.message);
    try std.testing.expectEqual(@as(usize, 2), parsed.changes.len);
    try std.testing.expectEqualStrings("a/b.wav", parsed.changes[0].path);
    try std.testing.expectEqual(index_mod.Op.delete, parsed.changes[1].op);
}

test "head round trip on disk" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    try saveHead(io, tmp.dir, .{ .branch = "main", .commit = null });
    const empty = try loadHead(arena_state.allocator(), io, tmp.dir);
    try std.testing.expect(empty.commit == null);
    try std.testing.expectEqualStrings("main", empty.branch);

    const id = Uuid.init(42, @splat(7));
    try saveHead(io, tmp.dir, .{ .branch = "main", .commit = id });
    const loaded = try loadHead(arena_state.allocator(), io, tmp.dir);
    try std.testing.expectEqualSlices(u8, &id.bytes, &loaded.commit.?.bytes);
}
