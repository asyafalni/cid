//! `cid help` shows only everyday commands (rule 6).
//! Owner and admin commands appear under `cid help --all` (later).

const std = @import("std");

const text =
    \\cid — version control for datasets
    \\
    \\usage: cid <command> [arguments]
    \\
    \\Everyday commands, same meaning as git:
    \\
    \\  clone <address>    download a dataset into a new folder
    \\  pull               get new commits and releases
    \\  checkout <v>       switch the folder to a release or branch
    \\  status             what you have, what changed, what is unpushed
    \\  log                releases and commits, newest first
    \\  diff [<a>] [<b>]   what changed
    \\  add <path>...      stage added, changed and deleted files
    \\  restore <path>     unstage (--staged) or throw away local edits
    \\  commit -m <msg>    save staged changes locally (instant, offline)
    \\  push               upload local commits and their files
    \\
    \\'cid help --all' also lists owner commands (init, tag, branch, merge).
    \\
;

pub fn print(out: *std.Io.Writer) !void {
    try out.writeAll(text);
}

test "help fits one screen and names every everyday command" {
    const everyday = [_][]const u8{
        "clone", "pull", "checkout", "status", "log",
        "diff",  "add",  "restore",  "commit", "push",
    };
    for (everyday) |cmd| {
        try std.testing.expect(std.mem.indexOf(u8, text, cmd) != null);
    }
    // "only everyday commands": no admin or owner commands in plain help
    try std.testing.expect(std.mem.indexOf(u8, text, "admin") == null);
    try std.testing.expect(std.mem.count(u8, text, "\n") <= 25);
}
