const std = @import("std");

pub fn build(b: *std.Build) void {
    const bin = b.addExecutable(.{
        .name = "foo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bar.zig"),
            .target = b.graph.host,
            .link_libc = true,
        }),
    });

    b.installArtifact(bin);

    const kdl = b.dependency("kdl", .{});
    bin.root_module.addImport("kdl", kdl.module("kdl"));

    const run_bin = b.addRunArtifact(bin);
    if (b.args) |args| {
        run_bin.addArgs(args);
    }
    const run_step = b.step("run", "run the server");
    run_step.dependOn(&run_bin.step);
}
