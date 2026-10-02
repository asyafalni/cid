const std = @import("std");

/// Keep in sync with build.zig.zon.
const version = "0.1.0-dev";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    // Nilo (pinned commit; CLAUDE.md, Zig conventions): the server's HTTP
    // framework, and its native Postgres driver (.sql fetches pg.zig),
    // which is replacing libpq module by module.
    const nilo_dep = b.dependency("nilo", .{
        .target = target,
        .optimize = optimize,
        .sql = true,
    });

    // sql/migrations/*.sql, embedded into the binary for `cid admin migrate`.
    const migrations_mod = buildMigrationsModule(b, target, optimize);

    // web/dist, embedded so deployment stays one binary (docs/dashboard.md).
    // Absent (dashboard not built), the server says so instead of 404ing.
    const assets_mod = buildAssetsModule(b, target, optimize);

    // The cid library: everything except main().
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/cid.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addOptions("build_options", options);
    lib_mod.addImport("nilo_http", nilo_dep.module("nilo_http"));
    lib_mod.addImport("nilo_sql", nilo_dep.module("nilo_sql"));
    lib_mod.addImport("nilo_s3", nilo_dep.module("nilo_s3"));
    lib_mod.addImport("nilo_fetch", nilo_dep.module("nilo_fetch"));
    lib_mod.addImport("migrations", migrations_mod);
    lib_mod.addImport("web_assets", assets_mod);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("cid", lib_mod);
    exe_mod.addImport("nilo_http", nilo_dep.module("nilo_http"));

    const exe = b.addExecutable(.{
        .name = "cid",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // DuckDB (CLAUDE.md): browse, compare, table statistics and row diffs.
    // Always linked. The C API only, translated once; nothing in cid sees
    // C++. Linked dynamically: the release's static archive is built
    // against libstdc++, which zig's libc++ cannot stand in for, so the
    // library ships beside the binary and is found there.
    if (b.lazyDependency("duckdb", .{})) |duck| {
        const header = b.addTranslateC(.{
            .root_source_file = duck.path("duckdb.h"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        lib_mod.addImport("duckdb_c", header.createModule());
        lib_mod.addLibraryPath(duck.path(""));
        lib_mod.linkSystemLibrary("duckdb", .{});
        lib_mod.link_libc = true;
        exe_mod.addRPathSpecial("$ORIGIN");
        // Test binaries run from the cache: find it where it was fetched.
        lib_mod.addRPath(duck.path(""));
        b.getInstallStep().dependOn(&b.addInstallBinFile(duck.path("libduckdb.so"), "libduckdb.so").step);
    }

    const run_step = b.step("run", "Run cid");
    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    // Unit tests: no services needed.
    const test_step = b.step("test", "Run unit tests (no services)");
    const unit_tests = b.addTest(.{ .root_module = lib_mod });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // Integration tests: need docker-compose.test.yml services up.
    const integration_step = b.step("integration", "Run integration tests (needs docker compose services)");
    const integration_mod = b.createModule(.{
        .root_source_file = b.path("tests/integration.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_mod.addImport("cid", lib_mod);
    const integration_tests = b.addTest(.{ .root_module = integration_mod });
    integration_step.dependOn(&b.addRunArtifact(integration_tests).step);
}

/// Scans sql/migrations/ and generates a module:
///   pub const Migration = struct { version, name, sql };
///   pub const all = [_]Migration{ … };  // sorted by version
fn buildMigrationsModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const wf = b.addWriteFiles();
    const io = b.graph.io;

    var names: std.ArrayList([]const u8) = .empty;
    var dir = b.build_root.handle.openDir(io, "sql/migrations", .{ .iterate = true }) catch
        @panic("sql/migrations/ is missing");
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch @panic("cannot read sql/migrations/")) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".sql")) continue;
        names.append(b.allocator, b.dupe(entry.name)) catch @panic("OOM");
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);

    var src: std.ArrayList(u8) = .empty;
    src.appendSlice(b.allocator,
        \\pub const Migration = struct { version: u32, name: [:0]const u8, sql: [:0]const u8 };
        \\pub const all = [_]Migration{
        \\
    ) catch @panic("OOM");
    for (names.items) |name| {
        const stem = name[0 .. name.len - ".sql".len];
        const ver = std.fmt.parseInt(u32, stem[0..4], 10) catch
            @panic("migration file names start with 4 digits: NNNN_name.sql");
        src.appendSlice(
            b.allocator,
            b.fmt("    .{{ .version = {d}, .name = \"{s}\", .sql = @embedFile(\"{s}\") }},\n", .{ ver, stem, name }),
        ) catch @panic("OOM");
        _ = wf.addCopyFile(b.path(b.fmt("sql/migrations/{s}", .{name})), name);
    }
    src.appendSlice(b.allocator, "};\n") catch @panic("OOM");

    const root = wf.add("migrations.zig", src.items);
    return b.createModule(.{
        .root_source_file = root,
        .target = target,
        .optimize = optimize,
    });
}

fn lessThan(_: void, a: []const u8, b_: []const u8) bool {
    return std.mem.lessThan(u8, a, b_);
}

/// Embeds every file under web/dist (recursively) as
///   pub const files = [_]Asset{ .{ .path, .mime, .bytes }, … };
/// Missing dist → an empty list, and the server explains itself.
fn buildAssetsModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const wf = b.addWriteFiles();
    const io = b.graph.io;

    var src: std.ArrayList(u8) = .empty;
    src.appendSlice(b.allocator,
        \\pub const Asset = struct { path: []const u8, mime: []const u8, bytes: []const u8 };
        \\pub const files = [_]Asset{
        \\
    ) catch @panic("OOM");

    collectAssets(b, wf, &src, io, "web/dist", "") catch {};

    src.appendSlice(b.allocator, "};\n") catch @panic("OOM");
    const root = wf.add("web_assets.zig", src.items);
    return b.createModule(.{
        .root_source_file = root,
        .target = target,
        .optimize = optimize,
    });
}

fn collectAssets(
    b: *std.Build,
    wf: *std.Build.Step.WriteFile,
    src: *std.ArrayList(u8),
    io: std.Io,
    fs_dir: []const u8,
    rel: []const u8,
) !void {
    const full = if (rel.len == 0) fs_dir else b.fmt("{s}/{s}", .{ fs_dir, rel });
    var dir = try b.build_root.handle.openDir(io, full, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const child = if (rel.len == 0) b.dupe(entry.name) else b.fmt("{s}/{s}", .{ rel, entry.name });
        switch (entry.kind) {
            .directory => try collectAssets(b, wf, src, io, fs_dir, child),
            .file => {
                _ = wf.addCopyFile(b.path(b.fmt("{s}/{s}", .{ fs_dir, child })), child);
                src.appendSlice(b.allocator, b.fmt(
                    "    .{{ .path = \"{s}\", .mime = \"{s}\", .bytes = @embedFile(\"{s}\") }},\n",
                    .{ child, mimeOf(child), child },
                )) catch @panic("OOM");
            },
            else => {},
        }
    }
}

fn mimeOf(path: []const u8) []const u8 {
    const exts = [_]struct { ext: []const u8, mime: []const u8 }{
        .{ .ext = ".html", .mime = "text/html; charset=utf-8" },
        .{ .ext = ".js", .mime = "text/javascript" },
        .{ .ext = ".css", .mime = "text/css" },
        .{ .ext = ".woff2", .mime = "font/woff2" },
        .{ .ext = ".svg", .mime = "image/svg+xml" },
        .{ .ext = ".png", .mime = "image/png" },
        .{ .ext = ".webp", .mime = "image/webp" },
        .{ .ext = ".ico", .mime = "image/x-icon" },
        .{ .ext = ".map", .mime = "application/json" },
        .{ .ext = ".json", .mime = "application/json" },
    };
    for (exts) |e| {
        if (std.mem.endsWith(u8, path, e.ext)) return e.mime;
    }
    return "application/octet-stream";
}
