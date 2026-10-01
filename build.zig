const std = @import("std");

/// Keep in sync with build.zig.zon.
const version = "0.1.0-dev";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addOptions("build_options", options);

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
    const unit_tests = b.addTest(.{ .root_module = exe_mod });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // Integration tests: need docker-compose.test.yml services up.
    const integration_step = b.step("integration", "Run integration tests (needs docker compose services)");
    const integration_mod = b.createModule(.{
        .root_source_file = b.path("tests/integration.zig"),
        .target = target,
        .optimize = optimize,
    });
    const integration_tests = b.addTest(.{ .root_module = integration_mod });
    integration_step.dependOn(&b.addRunArtifact(integration_tests).step);
}
