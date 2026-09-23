const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 唯一的库模块。protocol / usb / ble / ops / ipc 都挂在它下面，
    // 两个可执行文件共用同一份实现。BLE 走系统 libsystemd 的 sd-bus C ABI，
    // 因此整个库链接 libc/systemd；gc-sections 同时压掉未用代码
    // （并避开 GCC 16 crt1.o 的 .sframe 重定位，旧 LLD 不支持它）。
    // systemd 不走 pkg-config：本机 pkg-config 里同时存在名为 systemd 的空壳包
    // （`pkg-config systemd --libs` 无输出），会被选成 -lsystemd 丢失；
    // 直接按名让链接器找 libsystemd，@cImport 的头文件路径由 libc 探测提供。
    const f9 = b.addModule("f9", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    f9.linkSystemLibrary("systemd", .{ .use_pkg_config = .no });

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
        exe.link_gc_sections = true;
        b.installArtifact(exe);

        const run = b.addRunArtifact(exe);
        run.step.dependOn(b.getInstallStep());
        if (b.args) |args| run.addArgs(args);
        b.step(app.run_step, app.description).dependOn(&run.step);

        // 入口文件里的测试也要跑（zig build test 只认显式列出的 root）。
        const unit_tests = b.addTest(.{ .root_module = exe.root_module });
        unit_tests.link_gc_sections = true;
        test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    }

    const lib_tests = b.addTest(.{ .root_module = f9 });
    lib_tests.link_gc_sections = true;
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);
}
