//! A progress line for anything over a second (CLAUDE.md, rules for every
//! command): files, bytes, percentage, rate and time left, redrawn in place
//! on stderr at most ten times a second. Quiet when stderr is not a
//! terminal, and quiet for work that finishes within a second, so scripts
//! and short commands print exactly what they did before.

const std = @import("std");

pub const Progress = struct {
    io: std.Io,
    /// Null when stderr is not a terminal: everything is then a no-op.
    out: ?*std.Io.Writer,
    verb: []const u8 = "",
    files_total: u64 = 0,
    bytes_total: u64 = 0,
    files_done: u64 = 0,
    bytes_done: u64 = 0,
    started_ns: i96 = 0,
    drawn_ns: i96 = 0,
    shown: bool = false,

    const show_after_ns = std.time.ns_per_s;
    const redraw_every_ns = 100 * std.time.ns_per_ms;

    /// Starts a phase: "Uploading" 12 files, 3.4 GB.
    pub fn begin(self: *Progress, verb: []const u8, files: u64, bytes: u64) void {
        self.verb = verb;
        self.files_total = files;
        self.bytes_total = bytes;
        self.files_done = 0;
        self.bytes_done = 0;
        self.started_ns = self.now();
        self.drawn_ns = 0;
    }

    pub fn addBytes(self: *Progress, n: u64) void {
        self.bytes_done += n;
        self.maybeDraw();
    }

    pub fn fileDone(self: *Progress) void {
        self.files_done += 1;
        self.maybeDraw();
    }

    /// Ends the phase: the line is left showing the totals, then a newline,
    /// so what was done stays on screen.
    pub fn end(self: *Progress) void {
        if (self.shown) {
            self.draw();
            const out = self.out orelse return;
            out.writeAll("\n") catch {};
            out.flush() catch {};
        }
        self.shown = false;
    }

    fn now(self: *Progress) i96 {
        return std.Io.Timestamp.now(self.io, .awake).nanoseconds;
    }

    fn maybeDraw(self: *Progress) void {
        if (self.out == null) return;
        const t = self.now();
        if (t - self.started_ns < show_after_ns) return;
        if (self.shown and t - self.drawn_ns < redraw_every_ns) return;
        self.drawn_ns = t;
        self.shown = true;
        self.draw();
    }

    fn draw(self: *Progress) void {
        const out = self.out orelse return;
        var line_buf: [160]u8 = undefined;
        const line = self.render(&line_buf, self.now() - self.started_ns);
        out.print("\r{s}\x1b[K", .{line}) catch {};
        out.flush() catch {};
    }

    /// The line itself, from the counts and the time elapsed.
    pub fn render(self: *const Progress, buf: []u8, elapsed_ns: i96) []const u8 {
        var done_buf: [16]u8 = undefined;
        var total_buf: [16]u8 = undefined;
        var rate_buf: [16]u8 = undefined;
        const secs: f64 = @as(f64, @floatFromInt(@max(elapsed_ns, 1))) / std.time.ns_per_s;
        const rate: u64 = @intFromFloat(@as(f64, @floatFromInt(self.bytes_done)) / secs);
        const pct: u64 = if (self.bytes_total == 0) 100 else @min(100, self.bytes_done * 100 / self.bytes_total);
        var eta_buf: [24]u8 = undefined;
        const eta: []const u8 = if (rate == 0 or self.bytes_done >= self.bytes_total) "" else std.fmt.bufPrint(&eta_buf, ", ~{d}s left", .{(self.bytes_total - self.bytes_done) / rate}) catch "";
        return std.fmt.bufPrint(buf, "{s} {d}/{d} file{s}  {s} / {s}  {d}%  {s}/s{s}", .{
            self.verb,                              self.files_done,                  self.files_total,
            if (self.files_total == 1) "" else "s", size(&done_buf, self.bytes_done), size(&total_buf, self.bytes_total),
            pct,                                    size(&rate_buf, rate),            eta,
        }) catch buf[0..0];
    }
};

/// A progress for stderr: drawn only when stderr is a terminal.
pub fn forStderr(io: std.Io, writer: *std.Io.Writer) Progress {
    const tty = std.Io.File.stderr().isTty(io) catch false;
    return .{ .io = io, .out = if (tty) writer else null };
}

pub fn size(buf: []u8, n: u64) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var value: f64 = @floatFromInt(n);
    var unit: usize = 0;
    while (value >= 1000 and unit < units.len - 1) : (unit += 1) value /= 1000;
    if (unit == 0) return std.fmt.bufPrint(buf, "{d} B", .{n}) catch "?";
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ value, units[unit] }) catch "?";
}

test "the line: counts, sizes, percentage, rate and time left" {
    var p: Progress = .{ .io = std.testing.io, .out = null };
    p.begin("Uploading", 4, 4_000_000_000);
    p.files_done = 1;
    p.bytes_done = 1_000_000_000;
    var buf: [160]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Uploading 1/4 files  1.0 GB / 4.0 GB  25%  100.0 MB/s, ~30s left",
        p.render(&buf, 10 * std.time.ns_per_s),
    );
    p.bytes_done = 4_000_000_000;
    p.files_done = 4;
    try std.testing.expectEqualStrings(
        "Uploading 4/4 files  4.0 GB / 4.0 GB  100%  400.0 MB/s",
        p.render(&buf, 10 * std.time.ns_per_s),
    );
}

test "quiet without a terminal" {
    var p: Progress = .{ .io = std.testing.io, .out = null };
    p.begin("Downloading", 1, 10);
    p.addBytes(10);
    p.fileDone();
    p.end();
    try std.testing.expect(!p.shown);
}
