// SPDX-License-Identifier: BSL-1.0

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const encoding = b.dependency("fluxion_encoding", .{ .target = target, .optimize = optimize });
    const hash = b.dependency("fluxion_hash", .{ .target = target, .optimize = optimize });

    // The importable module. Consumers do:
    //   const data = @import("fluxion_data");
    const mod = b.addModule("fluxion_data", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fluxion_encoding", .module = encoding.module("fluxion_encoding") },
            .{ .name = "fluxion_hash", .module = hash.module("fluxion_hash") },
        },
    });

    // zig build test
    const tests = b.addTest(.{
        .name = "fluxion-data-tests",
        .root_module = mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the library test suite");
    test_step.dependOn(&run_tests.step);

    // zig build example
    const example_mod = b.createModule(.{
        .root_source_file = b.path("examples/demo.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "fluxion_data", .module = mod }},
    });
    const example = b.addExecutable(.{
        .name = "fluxion-data-demo",
        .root_module = example_mod,
    });
    b.installArtifact(example);

    const run_example = b.addRunArtifact(example);
    run_example.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_example.addArgs(args);
    const example_step = b.step("example", "Build and run the demo program");
    example_step.dependOn(&run_example.step);

    const example_tests = b.addTest(.{
        .name = "fluxion-data-demo-tests",
        .root_module = example_mod,
    });
    test_step.dependOn(&b.addRunArtifact(example_tests).step);

    // zig build docs -> zig-out/docs
    const docs_lib = b.addLibrary(.{
        .name = "fluxion-data",
        .root_module = mod,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate API documentation into zig-out/docs");
    docs_step.dependOn(&install_docs.step);
}
