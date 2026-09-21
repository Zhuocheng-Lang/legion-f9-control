const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 唯一的库模块。protocol / transport / core / ipc 都挂在它下面，
    // 两个可执行文件共用同一份实现。
    const f9 = b.addModule("f9", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run library and executable unit tests");

    const apps = [_]struct {
        name: []const u8,
        root: []const u8,
        /// zig build <run_step>
        run_step: []const u8,
        description: []const u8,
    }{
        .{ .name = "f9ctl", .root = "src/main.zig", .run_step = "run", .description = "Run f9ctl with the given args" },
        .{ .name = "f9d", .root = "src/daemon.zig", .run_step = "run-f9d", .description = "Run f9d with the given args" },
    };

    for (apps) |app| {
        const exe = b.addExecutable(.{
            .name = app.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(app.root),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "f9", .module = f9 }},
            }),
        });
        b.installArtifact(exe);

        const run = b.addRunArtifact(exe);
        run.step.dependOn(b.getInstallStep());
        if (b.args) |args| run.addArgs(args);
        b.step(app.run_step, app.description).dependOn(&run.step);

        // 入口文件里的测试也要跑（zig build test 只认显式列出的 root）。
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = exe.root_module })).step);
    }

    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = f9 })).step);
}
