const std = @import("std");
const builtin = @import("builtin");

/// 发布版本号：与 build.zig.zon 的 version 保持一致（--version 与打包都用它）。
const version = "0.1.0";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 唯一的库模块。protocol / usb / ble / ops / ipc 都挂在它下面，
    // 两个可执行文件共用同一份实现。BLE 走系统 libsystemd 的 sd-bus C ABI，
    // 因此整个库链接 libc/systemd；gc-sections 同时压掉未用代码
    // （并避开 GCC 16 crt1.o 的 .sframe 重定位，旧 LLD 不支持它）。
    //
    // 链接按库名 (-lsystemd) 交给链接器，不用 pkg-config 的 "systemd" 包：
    // 本机 pkg-config 里同时存在名为 systemd 的空壳包（--libs 无输出），
    // 选它会把 -lsystemd 弄丢。头文件/库目录改由 libsystemd.pc 显式补充，
    // 这样 NixOS/Guix/自定义前缀或 sysroot 下也能找到（见 addSystemdPaths）。
    const f9 = b.addModule("f9", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    f9.linkSystemLibrary("systemd", .{ .use_pkg_config = .no });
    addSystemdPaths(b, f9, target);

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

    installDataFiles(b);
}

/// 用 libsystemd.pc 补充头文件与库目录（仅本机编译；交叉编译时宿主 pkg-config 不可用）。
/// 没有 pkg-config 或没有该 .pc 时静默回退到系统默认路径，保持原行为。
fn addSystemdPaths(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    if (target.result.cpu.arch != builtin.cpu.arch) return;
    if (target.result.os.tag != builtin.os.tag) return;

    if (pkgConfig(b, "--cflags")) |cflags| addFlagPaths(mod, cflags, "-I", .include);
    if (pkgConfig(b, "--libs")) |libs| addFlagPaths(mod, libs, "-L", .library);
}

fn pkgConfig(b: *std.Build, flag: []const u8) ?[]const u8 {
    var code: u8 = 0;
    const out = b.runAllowFail(&.{ "pkg-config", flag, "libsystemd" }, &code, .Ignore) catch return null;
    if (code != 0) return null;
    return out;
}

/// 从 pkg-config 输出里挑出 -I/-L 并加进模块；其他旗标（-D、-l）忽略。
fn addFlagPaths(mod: *std.Build.Module, text: []const u8, comptime prefix: []const u8, comptime kind: enum { include, library }) void {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (it.next()) |tok| {
        if (!std.mem.startsWith(u8, tok, prefix)) continue;
        const dir = tok[prefix.len..];
        if (dir.len == 0) continue;
        switch (kind) {
            .include => mod.addIncludePath(.{ .cwd_relative = dir }),
            .library => mod.addLibraryPath(.{ .cwd_relative = dir }),
        }
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
