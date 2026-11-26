//! `cid help` shows only everyday commands (rule 6).
//! Owner commands appear under `cid help --all`; admin ones under `cid admin`.
//! `cid help --json` is the same commands as one document, for a program
//! or an AI coding agent that has never read cid's docs: what each command
//! takes, whether it needs the server, what it changes, what an exit code
//! means (docs/roadmap.md, E3).

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
    \\'cid help <command>' for one command's options; 'cid help --all' also lists
    \\owner commands (init, tag, branch, merge, deploy-key).
    \\
;

const owner_text =
    \\
    \\For dataset owners:
    \\
    \\  init <address> --git <git-url>   create a dataset from this folder
    \\                     (--model when the folder holds a model's files)
    \\  tag <name>         make a release (never moves again); a model's may add
    \\                     --trained-on <dataset>@<release>, once per dataset release
    \\  branch <name>      a draft line of work, starting from main
    \\  merge <name>       merge a branch into main; conflicts are listed
    \\  remote [set-url [<address>] [--git <git-url>]]   the folder's address
    \\                     and git URL; set-url follows a renamed dataset
    \\  deploy-key add <name> <key.pub> [--write]   let a machine (CI) reach this
    \\                     dataset with its own SSH key: read, or push with --write
    \\  deploy-key list | remove <name>
    \\
    \\Without SSH (scripts, CI): a token from the dashboard, in the address
    \\(every command but init, which needs SSH):
    \\  cid clone https://you:TOKEN@host/<dataset>
    \\Server administration: 'cid admin'.
    \\For programs and AI agents: 'cid help --json' (every command, as data).
    \\
;

/// What a command changes, so a caller knows what it risks before running
/// it: nothing, this folder (and its `.cid/`), or the dataset on the server.
const Changes = enum { nothing, folder, server };

const Flag = struct { flag: []const u8, does: []const u8 };

const Command = struct {
    name: []const u8,
    usage: []const u8,
    does: []const u8,
    /// `everyday` is what `cid help` shows; `owner` what `--all` adds.
    group: enum { everyday, owner, plumbing },
    /// Whether it talks to the server (the rest work offline).
    network: bool,
    changes: Changes,
    flags: []const Flag = &.{},
};

const commands = [_]Command{
    .{ .name = "clone", .usage = "cid clone <address|git-url|https-url> [<folder>] [--release <v>] [--format <f>] [--split <s>]... [--class <c>]...", .does = "Download a dataset into a new folder: its latest release unless --release names another. --split and --class keep only matching items; such a folder is read-only and remembers its subset.", .group = .everyday, .network = true, .changes = .folder, .flags = &.{
        .{ .flag = "--release <v>", .does = "the release to download (default: the latest)" },
        .{ .flag = "--format <f>", .does = "an annotated dataset's export: yolo, coco, voc or jsonl (default: the dataset's own)" },
        .{ .flag = "--split <s>", .does = "keep only this split's items; repeatable" },
        .{ .flag = "--class <c>", .does = "keep only items with this class, and only its annotations; repeatable" },
    } },
    .{ .name = "pull", .usage = "cid pull [--continue]", .does = "Get new commits and releases. Unpushed commits are replayed on top when they changed different files; when both sides changed a file, the conflicts are listed (exit 2) and nothing is merged.", .group = .everyday, .network = true, .changes = .folder, .flags = &.{
        .{ .flag = "--continue", .does = "finish a pull once every listed conflict is decided with 'cid checkout --mine|--theirs <path>'" },
    } },
    .{ .name = "checkout", .usage = "cid checkout <release|branch|commit> | --mine <path> | --theirs <path>", .does = "Switch the folder to a release, branch or commit; only changed files download. With --mine or --theirs, decide one listed conflict of the pull or merge in progress.", .group = .everyday, .network = true, .changes = .folder, .flags = &.{
        .{ .flag = "--mine <path>", .does = "keep this folder's version of a conflicting path" },
        .{ .flag = "--theirs <path>", .does = "take the server's version of a conflicting path" },
    } },
    .{ .name = "status", .usage = "cid status", .does = "The branch, staged and unstaged changes, unpushed commits, the folder's subset and any pending conflicts.", .group = .everyday, .network = false, .changes = .nothing },
    .{ .name = "log", .usage = "cid log", .does = "The folder's branch, newest first: unpushed commits, then the server's, with releases named.", .group = .everyday, .network = true, .changes = .nothing },
    .{ .name = "diff", .usage = "cid diff [--staged] | cid diff <a> [<b>]", .does = "What changed. No arguments: unstaged edits. Two versions (releases, branches or commits): files added, modified and deleted, rows for CSV, Parquet and JSONL, items and annotations for an annotated dataset.", .group = .everyday, .network = true, .changes = .nothing, .flags = &.{
        .{ .flag = "--staged", .does = "what is staged for the next commit (--cached too, as in git)" },
    } },
    .{ .name = "add", .usage = "cid add <path>... | cid add -A", .does = "Stage added, changed and deleted files for the next commit ('cid add .' for everything). Files are hashed and copied to the local cache now. To remove or move a file, delete or move it in the folder and add the path. A symbolic link is refused (exit 1, nothing staged): cid stores files, not links.", .group = .everyday, .network = false, .changes = .folder, .flags = &.{
        .{ .flag = "-A, --all", .does = "everything, as 'cid add .'" },
    } },
    .{ .name = "restore", .usage = "cid restore [--staged] <path>...", .does = "Throw away local edits to a path, or with --staged, unstage it and keep the edits.", .group = .everyday, .network = false, .changes = .folder, .flags = &.{
        .{ .flag = "--staged", .does = "unstage instead of discarding edits" },
    } },
    .{ .name = "commit", .usage = "cid commit -m <message> [-a]", .does = "Save staged changes as a local commit: instant, offline, nothing leaves the machine until 'cid push'.", .group = .everyday, .network = false, .changes = .folder, .flags = &.{
        .{ .flag = "-m <message>", .does = "the commit message (required)" },
        .{ .flag = "-a", .does = "first stage every change to tracked files (new files still need 'cid add')" },
    } },
    .{ .name = "push", .usage = "cid push", .does = "Upload local commits and the files the server lacks. Refused (exit 2) when someone pushed since the last pull. Safe to run again after an interruption: it sends only what is missing.", .group = .everyday, .network = true, .changes = .server },
    .{ .name = "init", .usage = "cid init <address> --git <git-url> [--model]", .does = "Create a dataset on the server from the current folder, paired with its git repository (required; the server must be able to push to it).", .group = .owner, .network = true, .changes = .server, .flags = &.{
        .{ .flag = "--git <git-url>", .does = "the dataset's git repository, where cid writes one small commit per release" },
        .{ .flag = "--model", .does = "the folder holds a model's files (weights, configuration), not a dataset" },
    } },
    .{ .name = "tag", .usage = "cid tag <name> [-m <notes>] [--trained-on <dataset>@<release>]... | cid tag", .does = "Make a release of the pushed head. A release never moves or changes; tagging an existing name is an error. Alone (or -l), lists the releases and changes nothing.", .group = .owner, .network = true, .changes = .server, .flags = &.{
        .{ .flag = "-l, --list", .does = "list the releases, as 'cid tag' alone does" },
        .{ .flag = "-m <notes>", .does = "the release's own words: what it is and why, shown in its history and in git; kept with it, never changed" },
        .{ .flag = "--trained-on <dataset>@<release>", .does = "for a model: a dataset release it was trained on; repeatable" },
    } },
    .{ .name = "branch", .usage = "cid branch <name> | cid branch", .does = "Start a draft line of work from main; 'cid checkout <name>' then works on it. Alone (or -a), lists the branches, the folder's marked with *, and changes nothing.", .group = .owner, .network = true, .changes = .server, .flags = &.{
        .{ .flag = "-a, -l, --list", .does = "list the branches, as 'cid branch' alone does" },
    } },
    .{ .name = "merge", .usage = "cid merge <branch> | cid merge --continue", .does = "Merge a branch into main. Conflicts are listed (exit 2), never resolved silently; decide each with 'cid checkout --mine|--theirs <path>'.", .group = .owner, .network = true, .changes = .server, .flags = &.{
        .{ .flag = "--continue", .does = "finish a merge once every listed conflict is decided" },
    } },
    .{ .name = "remote", .usage = "cid remote [-v] | cid remote set-url [<address>] [--git <git-url>]", .does = "The folder's address and git URL; set-url points the folder at a renamed dataset.", .group = .owner, .network = false, .changes = .folder, .flags = &.{
        .{ .flag = "-v", .does = "the same as 'cid remote' (it always shows both addresses)" },
        .{ .flag = "--git <git-url>", .does = "with set-url: the dataset's new git repository URL" },
    } },
    .{ .name = "deploy-key", .usage = "cid deploy-key add <name> <key.pub> [--write] | list | remove <name>", .does = "A machine's own SSH key on this dataset, for CI: read, or push with --write.", .group = .owner, .network = true, .changes = .server, .flags = &.{
        .{ .flag = "--write", .does = "with add: the key may push as well as read" },
    } },
    .{ .name = "hash-object", .usage = "cid hash-object <file>...", .does = "Print each file's content hash (BLAKE3), the name cid stores it by.", .group = .plumbing, .network = false, .changes = .nothing },
};

const exit_codes = [_]struct { code: u8, means: []const u8 }{
    .{ .code = 0, .means = "ok" },
    .{ .code = 1, .means = "wrong usage, or no server configured: read the message, fix the command" },
    .{ .code = 2, .means = "conflict: someone pushed first, or both sides changed a file; a person decides" },
    .{ .code = 3, .means = "integrity failure: a hash did not match; do not retry blindly" },
    .{ .code = 4, .means = "server or network: safe to run the same command again" },
    .{ .code = 5, .means = "access denied" },
};

const environment = [_]struct { name: []const u8, does: []const u8 }{
    .{ .name = "CID_TOKEN", .does = "a personal token from the dashboard, used instead of an SSH key (scripts, CI); never written to disk" },
    .{ .name = "CID_SERVER", .does = "with CID_TOKEN, the server's URL: overrides the folder's address" },
    .{ .name = "CID_AUTHOR", .does = "the author of commits made here (default: user:$USER)" },
};

/// `cid help --json`: every everyday, owner and plumbing command as one
/// document. Stable keys; new ones may be added, none renamed.
pub fn printJson(out: *std.Io.Writer, version: []const u8) !void {
    var w: std.json.Stringify = .{ .writer = out, .options = .{ .whitespace = .indent_2 } };
    try w.beginObject();
    try w.objectField("tool");
    try w.write("cid");
    try w.objectField("version");
    try w.write(version);
    try w.objectField("about");
    try w.write("Version control for datasets: history, releases, diffs and one-command downloads for any files and their annotations. Same verbs as git, same meaning: add stages, commit saves locally, push uploads, pull downloads.");
    try w.objectField("conventions");
    try w.write([_][]const u8{
        "Inside a cloned folder the dataset is implied; outside, an address names it (cid@host:org/path, or https://user:TOKEN@host/org/path).",
        "--json anywhere on the line: the result as one JSON document on stdout (diff: one JSON line per change, then a summary); errors as {\"error\", \"exit\"} on stderr.",
        "Every error message ends with the command to run next.",
        "A release never moves; pushed history is never rewritten; conflicts are never resolved for you.",
        "In a clone of an annotated dataset the folder is an export and read-only: add, commit and push refuse.",
    });
    try w.objectField("exit_codes");
    try w.write(exit_codes);
    try w.objectField("environment");
    try w.write(environment);
    try w.objectField("commands");
    try w.write(commands);
    try w.objectField("more");
    try w.write("Server administration: 'cid admin'.");
    try w.endObject();
    try out.writeByte('\n');
}

/// One command's help, from the same table `--json` serves: its usage,
/// what it does, its options, and what it needs and changes. False when
/// no command has that name.
pub fn printFor(out: *std.Io.Writer, name: []const u8, json: bool) !bool {
    for (commands) |c| {
        if (!std.mem.eql(u8, c.name, name)) continue;
        if (json) {
            var w: std.json.Stringify = .{ .writer = out, .options = .{ .whitespace = .indent_2 } };
            try w.write(c);
            try out.writeByte('\n');
            return true;
        }
        try out.print("usage: {s}\n\n{s}\n", .{ c.usage, c.does });
        if (c.flags.len > 0) {
            try out.writeAll("\nOptions:\n");
            var width: usize = 0;
            for (c.flags) |f| width = @max(width, f.flag.len);
            for (c.flags) |f| {
                try out.print("  {s}", .{f.flag});
                try out.splatByteAll(' ', width - f.flag.len + 2);
                try out.print("{s}\n", .{f.does});
            }
        }
        try out.print("\n{s}; {s}.\n", .{
            if (c.network) "Needs the server" else "Works offline",
            switch (c.changes) {
                .nothing => "changes nothing",
                .folder => "changes this folder only",
                .server => "changes the dataset on the server",
            },
        });
        return true;
    }
    return false;
}

pub fn print(out: *std.Io.Writer) !void {
    try out.writeAll(text);
}

pub fn printAll(out: *std.Io.Writer) !void {
    try out.writeAll(text);
    try out.writeAll(owner_text);
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

test "help --json is one JSON document naming every command the help does" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try printJson(&buf.writer, "0.0.0-test");
    const Doc = struct {
        tool: []const u8,
        version: []const u8,
        exit_codes: []const struct { code: u8, means: []const u8 },
        commands: []const struct { name: []const u8, usage: []const u8, group: []const u8, network: bool, changes: []const u8 },
    };
    const parsed = try std.json.parseFromSlice(Doc, std.testing.allocator, buf.written(), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("cid", parsed.value.tool);
    try std.testing.expectEqual(@as(usize, 6), parsed.value.exit_codes.len);
    // The table and the words people read name the same commands: one
    // cannot gain a command the other lacks.
    for (parsed.value.commands) |c| {
        try std.testing.expect(std.mem.startsWith(u8, c.usage, "cid "));
        if (std.mem.eql(u8, c.group, "plumbing")) continue;
        const where = if (std.mem.eql(u8, c.group, "everyday")) text else owner_text;
        const line = try std.fmt.allocPrint(std.testing.allocator, "\n  {s} ", .{c.name});
        defer std.testing.allocator.free(line);
        try std.testing.expect(std.mem.indexOf(u8, where, line) != null);
    }
    var everyday: usize = 0;
    for (parsed.value.commands) |c| {
        if (std.mem.eql(u8, c.group, "everyday")) everyday += 1;
    }
    try std.testing.expectEqual(@as(usize, 10), everyday);
}
