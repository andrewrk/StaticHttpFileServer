const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("StaticHttpFileServer", .{
        .root_source_file = .{ .path = "root.zig" },
        .target = target,
        .optimize = optimize,
    });
    module.addImport("mime", b.dependency("mime", .{
        .target = target,
        .optimize = optimize,
    }).module("mime"));

    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "test.zig" },
        .target = target,
        .optimize = optimize,
    });
    unit_tests.root_module.addImport("StaticHttpFileServer", module);
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const serve_exe = b.addExecutable(.{
        .name = "serve",
        .root_source_file = .{ .path = "serve.zig" },
        .target = target,
        .optimize = optimize,
    });
    serve_exe.root_module.addImport("StaticHttpFileServer", module);
    const run_serve_exe = b.addRunArtifact(serve_exe);
    if (b.args) |args| run_serve_exe.addArgs(args);

    const serve_step = b.step("serve", "Serve a directory of files");
    serve_step.dependOn(&run_serve_exe.step);
}
