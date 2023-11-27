const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("StaticHttpFileServer", .{
        .source_file = .{ .path = "root.zig" },
    });
    module.addModule("mime", b.dependency("mime", .{
        .target = target,
        .optimize = optimize,
    }).module("mime"));

    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "test.zig" },
        .target = target,
        .optimize = optimize,
    });
    unit_tests.addModule("StaticHttpFileServer", module);
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
