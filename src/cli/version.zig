//! `cid --version`: plain version when piped (scripts can parse it),
//! plus a small original ASCII airship when attached to a terminal.
//! The airship is our own; see the name-and-brand rule in CLAUDE.md.

const std = @import("std");
const build_options = @import("build_options");

const airship =
    \\         .-~~~~~~~~~~~~-.
    \\       .'  ~  c i d  ~   '.
    \\      (___________________)
    \\         `--.________.--'
    \\          /__|______|__\
    \\      ~   '---o----o---'   ~
    \\
;

pub fn print(out: *std.Io.Writer, is_tty: bool) !void {
    if (is_tty) {
        try out.writeAll(airship);
        try out.print("cid {s} · Controlled Iterative Datasets\n", .{build_options.version});
    } else {
        try out.print("cid {s}\n", .{build_options.version});
    }
}

test "piped output is a single parseable line" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try print(&w, false);
    const written = w.buffered();
    try std.testing.expect(std.mem.startsWith(u8, written, "cid "));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, written, "\n"));
}

test "terminal output carries the tagline and the airship" {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try print(&w, true);
    const written = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Controlled Iterative Datasets") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "c i d") != null);
}
