const std = @import("std");
const builtin = @import("builtin");

/// 发布版本号：与 build.zig.zon 的 version 保持一致（--version 与打包都用它）。
const version = "0.1.0";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 唯一的库模块。protocol / usb / ble / ops / ipc 都挂在它下面，
    // 两个可执行文件共用同一份实现。BLE 走系统 libsystemd 的 sd-bus C ABI，
    // 因此整个库链接 libc/systemd；gc-sections 同时压掉未用代码。
    //
    // 链接交给 pkg-config 解析 libsystemd.pc：本机 pkg-config 里同时存在名为 systemd
    // 的空壳包（--libs 无输出），选它会把 -lsystemd 弄丢。这同时给出库目录，
    // NixOS/Guix/自定义前缀或 sysroot 下也能找到；pkg-config 或该 .pc 缺失时构建
    // 明确失败，而不是退回一个不存在的库名。
    // std.Io 时代不再需要 C 头文件（sd-bus 声明在 ble.zig 内以 extern 给出），
    // 因此这里只关心链接参数；交叉编译时宿主 pkg-config 不可用，退回按库名链接。
    const f9 = b.addModule("f9", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    linkSystemd(f9, target);

    // 版本号注入可执行文件（stdout 只输出结果，--version 也走它）
    const version_options = b.addOptions();
    version_options.addOption([]const u8, "version", version);

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
        exe.root_module.addOptions("build_options", version_options);
        exe.link_gc_sections = true;
        b.installArtifact(exe);

        const run = b.addRunArtifact(exe);
        run.step.dependOn(b.getInstallStep());
        // 透传参数在 make 阶段叠加，配置阶段看不到（Zig 0.17 起取代 b.args + addArgs：
        // 改变运行参数不再触发 build.zig 重新编译）。
        run.addPassthruArgs();
        b.step(app.run_step, app.description).dependOn(&run.step);

        // 入口文件里的测试也要跑（zig build test 只认显式列出的 root）。
        const unit_tests = b.addTest(.{ .root_module = exe.root_module });
        unit_tests.link_gc_sections = true;
        test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    }

    const lib_tests = b.addTest(.{ .root_module = f9 });
    lib_tests.link_gc_sections = true;
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);

    installDataFiles(b);
}

/// 链接系统 libsystemd。
/// 同架构同 OS（本机编译）时让 pkg-config 解析 libsystemd.pc（给出 -lsystemd 与
/// 库目录）；交叉编译时宿主 pkg-config 不可用，退回纯 -lsystemd。
fn linkSystemd(mod: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    const native = target.result.cpu.arch == builtin.target.cpu.arch and
        target.result.os.tag == builtin.target.os.tag;
    if (native) {
        // .force 而不是 .yes：.yes 在 pkg-config 缺席时按原名回退链接 -llibsystemd，
        // 那是个不存在的库，报错反而更难懂；本机构建要求 pkg-config 可用。
        mod.linkSystemLibrary("libsystemd", .{ .use_pkg_config = .force });
    } else {
        mod.linkSystemLibrary("systemd", .{ .use_pkg_config = .no });
    }
}

/// 用户文档与系统集成文件：zig build install --prefix /usr 即可部署到标准位置。
fn installDataFiles(b: *std.Build) void {
    b.installFile("packaging/man/f9ctl.1", "share/man/man1/f9ctl.1");
    b.installFile("packaging/completions/f9ctl.bash", "share/bash-completion/completions/f9ctl");
    b.installFile("packaging/completions/_f9ctl", "share/zsh/site-functions/_f9ctl");
    b.installFile("packaging/completions/f9ctl.fish", "share/fish/vendor_completions.d/f9ctl.fish");
    b.installFile("packaging/f9d.service", "lib/systemd/system/f9d.service");
    b.installFile("packaging/99-legion-f9.rules", "lib/udev/rules.d/99-legion-f9.rules");
    b.installFile("LICENSE", "share/licenses/legion-f9-control/LICENSE");
}
