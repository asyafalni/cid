const std = @import("std");

/// Keep in sync with build.zig.zon.
const version = "0.1.0-dev";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    // libpq built from source by the Zig build system (allyourcodebase/libpq,
    // pinned in build.zig.zon). SSL off: the database is reached over
    // localhost or a private network behind the reverse proxy.
    const libpq_dep = b.dependency("libpq", .{
        .target = target,
        .optimize = optimize,
        .ssl = .None,
        .@"disable-zlib" = true,
        .@"disable-zstd" = true,
    });

    // Nilo (pinned commit; CLAUDE.md, Zig conventions): the server's HTTP
    // framework. No .sql option, so none of its lazy drivers are fetched.
    const nilo_dep = b.dependency("nilo", .{
        .target = target,
        .optimize = optimize,
    });

    // sql/migrations/*.sql, embedded into the binary for `cid admin migrate`.
    const migrations_mod = buildMigrationsModule(b, target, optimize);

    // The cid library: everything except main().
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/cid.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addOptions("build_options", options);
    lib_mod.addImport("libpq", libpq_dep.module("libpq"));
    lib_mod.addImport("nilo_http", nilo_dep.module("nilo_http"));
    lib_mod.addImport("migrations", migrations_mod);

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
