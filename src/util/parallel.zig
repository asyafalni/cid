//! Several transfers at once (CLAUDE.md: data moves over HTTPS in
//! parallel). One file at a time, a push of 100k small files took 798 s
//! and a clone 101 s on a local network: the time was round trips, not
//! bytes. The client's uploads and downloads go through here, and so do
//! the server's checks of what a push uploaded.
//!
//! `each` runs a job for every index on up to `workers` concurrent tasks.
//! Each task has an arena of its own, reset after every item, so memory
//! stays bounded whatever the count; the job records its own outcome per
//! index, and the caller deals with failures afterwards, one at a time.

const std = @import("std");

pub const workers = 8;

/// Calls `job.run(allocator, i)` for every `i` in `0..n`. `job` is shared by
/// every task: what it writes must be per index (or guarded).
pub fn each(io: std.Io, n: usize, job: anytype) void {
    if (n == 0) return;
    var next: std.atomic.Value(usize) = .init(0);
    const count = @min(workers, n);
    var group: std.Io.Group = .init;
    var inline_runs: usize = 0;
    for (0..count) |_| {
        group.concurrent(io, Worker(@TypeOf(job)).work, .{ job, &next, n }) catch {
            // No concurrency here (a single-threaded Io): this task runs
            // its share now, and the rest after it.
            inline_runs += 1;
        };
    }
    if (inline_runs > 0) Worker(@TypeOf(job)).work(job, &next, n);
    group.await(io) catch {};
}

fn Worker(comptime Job: type) type {
    return struct {
        fn work(job: Job, next: *std.atomic.Value(usize), n: usize) void {
            var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena_state.deinit();
            while (true) {
                const i = next.fetchAdd(1, .monotonic);
                if (i >= n) return;
                job.run(arena_state.allocator(), i);
                _ = arena_state.reset(.retain_capacity);
            }
        }
    };
}

test "every index once, on several tasks" {
    const Job = struct {
        seen: []std.atomic.Value(u32),
        pub fn run(self: *const @This(), arena: std.mem.Allocator, i: usize) void {
            const scratch = arena.alloc(u8, 64) catch return;
            scratch[0] = 1;
            _ = self.seen[i].fetchAdd(1, .monotonic);
        }
    };
    const seen = try std.testing.allocator.alloc(std.atomic.Value(u32), 1000);
    defer std.testing.allocator.free(seen);
    for (seen) |*s| s.* = .init(0);
    each(std.testing.io, seen.len, &Job{ .seen = seen });
    for (seen) |s| try std.testing.expectEqual(@as(u32, 1), s.load(.monotonic));
}
