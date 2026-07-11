const std = @import("std");
const package_info = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const json_dep = b.dependency("json", .{ .target = target, .optimize = optimize });
    const toml_dep = b.dependency("toml", .{ .target = target, .optimize = optimize });
    const cli_dep = b.dependency("cli", .{ .target = target, .optimize = optimize });

    const options = b.addOptions();
    options.addOption([]const u8, "version", package_info.version);

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "json", .module = json_dep.module("json") },
            .{ .name = "toml", .module = toml_dep.module("toml") },
            .{ .name = "cli", .module = cli_dep.module("cli") },
        },
    });
    root_module.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = "holt",
        .root_module = root_module,
    });
    b.installArtifact(exe);

    const tests = b.addTest(.{ .root_module = root_module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const lib_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "json", .module = json_dep.module("json") },
            .{ .name = "toml", .module = toml_dep.module("toml") },
            .{ .name = "cli", .module = cli_dep.module("cli") },
        },
    });
    lib_module.addOptions("build_options", options);

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/bench.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "holt_lib", .module = lib_module },
        },
    });
    const bench_exe = b.addExecutable(.{ .name = "holt-bench", .root_module = bench_mod });
    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run the performance harness (synthetic workspace + timing baseline)");
    bench_step.dependOn(&run_bench.step);
}
