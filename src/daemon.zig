//! f9d：Legion F9 设备 daemon。独占设备（优先 USB，必要时 BLE），经 Unix socket
//! 向 f9ctl 提供单行请求 / JSON 响应服务（协议见 ipc.zig）。前台运行，日志走 stderr
//! （systemd 收进 journal）；由 init 系统负责生命周期与重启。

const std = @import("std");
const f9 = @import("f9");

const protocol = f9.protocol;
const usb = f9.usb;
const ble = f9.ble;
const ops = f9.ops;
const ipc = f9.ipc;
const log = f9.log;

/// 客户端连上后保持沉默的上限，防止单个连接堵死所有请求。
const conn_read_timeout_ms = 5000;

/// 设备链路：USB 优先，仅 USB 未找到/无应答时才用 BLE（见 openPreferred）。
/// 一次请求内不换链路、不重放写入；失败即丢弃句柄，下个请求重新选择。
/// ops 只依赖下面三个语义操作，具体帧与事务由 USB/BLE 各自实现。
const Link = union(enum) {
    usb: usb.Device,
    ble: ble.Device,

    pub fn read(self: *Link, command: protocol.Command, offset: u16, len: u8) !protocol.Decoded {
        return switch (self.*) {
            .usb => |d| d.read(command, offset, len),
            .ble => |*d| d.read(command, offset, len),
        };
    }

    pub fn write(self: *Link, command: protocol.Command, offset: u16, payload: []const u8) !void {
        return switch (self.*) {
            .usb => |d| d.write(command, offset, payload),
            .ble => |*d| d.write(command, offset, payload),
        };
    }

    pub fn session(self: *Link, open: bool) !void {
        return switch (self.*) {
            .usb => |d| d.session(open),
            .ble => |*d| d.session(open),
        };
    }

    /// 复用链路时重置 BLE 的整请求预算（上个请求的可能已耗尽）。
    /// 新打开的链路由 ble.open 入口起算预算（含扫描/连接/服务解析），不重置。
    /// ops 不依赖它；USB 无状态，是空操作。
    pub fn beginRequest(self: *Link) void {
        switch (self.*) {
            .usb => {},
            .ble => |*d| d.beginRequest(),
        }
    }

    pub fn close(self: *Link) void {
        switch (self.*) {
            .usb => |*d| d.close(),
            .ble => |*d| d.close(),
        }
    }
};

/// USB 优先；仅当 USB 未找到/无应答时回落 BLE。
/// 权限等其他 USB 错误原样上报：不能用 BLE 掩盖 USB 权限问题。
fn openPreferred(usb_open: anytype, ble_open: anytype) !Link {
    const dev = usb_open() catch |err| {
        if (!shouldTryBle(err)) return err;
        return .{ .ble = try ble_open() };
    };
    return .{ .usb = dev };
}

/// 纯策略：只有“未发现设备 / 设备无应答”允许尝试 BLE。
fn shouldTryBle(usb_err: anyerror) bool {
    return switch (usb_err) {
        error.DeviceNotFound, error.DeviceNotResponding => true,
        else => false,
    };
}

/// 设备句柄：惰性打开（设备可能晚于 daemon 启动接入），失败后丢弃。
/// 打开函数注入仅为可测；生产调用传 usb.Device.open / ble.Device.open。
const State = struct {
    dev: ?Link = null,

    fn ensure(st: *State, usb_open: anytype, ble_open: anytype) !*Link {
        if (st.dev == null) {
            st.dev = try openPreferred(usb_open, ble_open);
            log("f9d: 设备已连接（{s}）", .{@tagName(st.dev.?)});
            // 新链路：BLE 预算已从 open 入口起算（含打开），不再重置
        } else {
            st.dev.?.beginRequest(); // 复用：上个请求的预算可能已耗尽
        }
        return &st.dev.?;
    }

    /// ponytail: 任何事务错误都丢弃句柄、由下个请求惰性重开来覆盖拔插/断线；
    /// 不做重试/退避，拔插频繁到日志噪声时可再加。
    fn drop(st: *State) void {
        if (st.dev) |*d| d.close();
        st.dev = null;
    }
};

pub fn main() void {
    run() catch |err| {
        log("f9d: 启动失败: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run() !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = ipc.daemonSocketPath(&path_buf) catch |err| switch (err) {
        error.NoRuntimeDir => {
            log("f9d: 未设置 XDG_RUNTIME_DIR，拒绝回退到 /tmp（可预测路径有符号链接攻击风险）", .{});
            std.process.exit(1);
        },
        error.PathTooLong => {
            log("f9d: XDG_RUNTIME_DIR 过长，socket 路径放不下，拒绝启动", .{});
            std.process.exit(1);
        },
    };
    const is_root = std.posix.geteuid() == 0;
    // 非 root 实例的安全前提：XDG_RUNTIME_DIR 属主本人且权限不宽于 0700，
    // 否则 socket/lock 仍可被同机其他用户占位——不满足即拒绝启动。
    if (!is_root) ipc.validateRuntimeDir() catch {
        log("f9d: XDG_RUNTIME_DIR 须为属主本人、权限不宽于 0700 的目录，拒绝启动", .{});
        std.process.exit(1);
    };
    if (is_root) std.fs.makeDirAbsolute(ipc.root_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |e| return e,
    };

    // 防双开：对锁文件 flock，持锁期间残留 socket 必属死实例，直接清掉再绑定。
    // （原来的 connect 探测 → 删除 → bind 三步有 TOCTOU 窗口）
    _ = try acquireLock(path);
    std.fs.deleteFileAbsolute(path) catch {};

    const addr = try std.net.Address.initUnix(path);
    var server = try addr.listen(.{});
    // root 实例放开给任意本地用户（风扇控制，低敏）；要收紧就换用户组/polkit。
    if (is_root) try std.posix.fchmodat(std.posix.AT.FDCWD, path, 0o666, 0);
    log("f9d: 监听 {s}", .{path});

    var st: State = .{};
    defer st.drop();
    // ponytail: 单线程顺序 accept；设备会话本身要求串行，并发需求出现时再上线程。
    while (true) {
        const conn = server.accept() catch |err| {
            log("f9d: accept 失败: {s}", .{@errorName(err)});
            continue;
        };
        serve(conn.stream, &st);
        conn.stream.close();
    }
}

/// 对 `<socket>.lock` 加排他非阻塞 flock；已有实例持锁则报 AlreadyRunning。
/// 返回的 File 由调用方持有不关：锁随 fd 存活，进程退出自动释放。
fn acquireLock(sock_path: []const u8) !std.fs.File {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    // XDG_RUNTIME_DIR 可超长：拼不进缓冲报错，不用 unreachable panic
    const lock_path = std.fmt.bufPrint(&buf, "{s}.lock", .{sock_path}) catch return error.PathTooLong;
    // truncate=false：即使锁文件路径被符号链接占位也不截断目标文件
    // （socket 目录本应可信，此为纵深防御）。
    const f = try std.fs.createFileAbsolute(lock_path, .{ .truncate = false });
    errdefer f.close();
    std.posix.flock(f.handle, std.posix.LOCK.EX | std.posix.LOCK.NB) catch |err| switch (err) {
        error.WouldBlock => return error.AlreadyRunning,
        else => |e| return e,
    };
    return f;
}

fn serve(stream: std.net.Stream, st: *State) void {
    serveInner(stream, st) catch |err| {
        log("f9d: 连接处理失败: {s}", .{@errorName(err)});
    };
}

fn serveInner(stream: std.net.Stream, st: *State) !void {
    var rbuf: [ipc.max_request_len]u8 = undefined;
    const line = try ipc.readLine(stream, &rbuf, conn_read_timeout_ms);
    var wbuf: [ipc.max_reply_len]u8 = undefined;
    const out = dispatch(st, line, &wbuf);
    try stream.writeAll(out);
    try stream.writeAll("\n");
}

fn dispatch(st: *State, line: []const u8, buf: []u8) []const u8 {
    const req = ipc.parseRequest(line) catch |err| return ipc.formatError(buf, err);
    return runRequest(st, req, buf) catch |err| return ipc.formatError(buf, err);
}

fn runRequest(st: *State, req: ipc.Request, buf: []u8) ![]const u8 {
    const dev = try st.ensure(usb.Device.open, ble.Device.open);
    // ensure 之后发生的任何错误都视为设备链路问题，丢弃句柄待下次重开
    return onDevice(dev, req, buf) catch |err| {
        st.drop();
        return err;
    };
}

fn onDevice(dev: *Link, req: ipc.Request, buf: []u8) ![]const u8 {
    return switch (req) {
        .status => ipc.formatStatus(buf, try ops.status(dev)),
        .gear_get => ipc.formatGear(buf, try ops.gearGet(dev)),
        .gear_set => |g| blk: {
            try ops.gearSet(dev, g);
            const got = try ops.gearGet(dev); // 回读确认
            if (got != g) return error.GearMismatch;
            break :blk ipc.formatGear(buf, got);
        },
    };
}

test {
    std.testing.refAllDecls(@This());
}

test "acquireLock：同一路径不可重复加锁，释放后可再加" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try tmp.dir.realpath(".", &dir_buf);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sock = try std.fmt.bufPrint(&path_buf, "{s}/f9d.sock", .{dir});

    const first = try acquireLock(sock);
    try std.testing.expectError(error.AlreadyRunning, acquireLock(sock));
    first.close();
    const second = try acquireLock(sock);
    second.close();
}

test "设备选择：仅 USB 未找到/无应答才回落 BLE，权限错误不兜底" {
    const Fake = struct {
        var ble_calls: usize = 0;
        fn usbMissing() !usb.Device {
            return error.DeviceNotFound;
        }
        fn usbSilent() !usb.Device {
            return error.DeviceNotResponding;
        }
        fn usbDenied() !usb.Device {
            return error.AccessDenied;
        }
        fn bleOpened() !ble.Device {
            ble_calls += 1;
            return undefined; // 只验证选择逻辑，不碰真实会话
        }
    };

    Fake.ble_calls = 0;
    const missing = try openPreferred(Fake.usbMissing, Fake.bleOpened);
    try std.testing.expectEqual(@as(usize, 1), Fake.ble_calls);
    try std.testing.expectEqual(std.meta.activeTag(missing), .ble);

    const silent = try openPreferred(Fake.usbSilent, Fake.bleOpened);
    try std.testing.expectEqual(@as(usize, 2), Fake.ble_calls);
    try std.testing.expectEqual(std.meta.activeTag(silent), .ble);

    // 权限错误原样上报，且不得再试 BLE
    try std.testing.expectError(error.AccessDenied, openPreferred(Fake.usbDenied, Fake.bleOpened));
    try std.testing.expectEqual(@as(usize, 2), Fake.ble_calls);
    try std.testing.expect(!shouldTryBle(error.AccessDenied));
    try std.testing.expect(!shouldTryBle(error.Timeout));
}

test "State：复用期间不重复打开，丢弃后下个请求惰性重开" {
    const Fake = struct {
        var usb_calls: usize = 0;
        var ble_calls: usize = 0;
        fn usbOk() !usb.Device {
            usb_calls += 1;
            // /dev/null 充当假句柄：close 只关它，无副作用
            return .{ .file = try std.fs.openFileAbsolute("/dev/null", .{}) };
        }
        fn bleDown() !ble.Device {
            ble_calls += 1;
            return error.BluezUnavailable;
        }
    };

    Fake.usb_calls = 0;
    Fake.ble_calls = 0;
    var st: State = .{};
    const first = try st.ensure(Fake.usbOk, Fake.bleDown);
    const again = try st.ensure(Fake.usbOk, Fake.bleDown);
    try std.testing.expect(first == again); // 同一句柄：不换链路、不重复打开
    try std.testing.expectEqual(@as(usize, 1), Fake.usb_calls);
    st.drop(); // 事务失败路径：丢弃句柄
    try std.testing.expect(st.dev == null);
    _ = try st.ensure(Fake.usbOk, Fake.bleDown); // 下个请求惰性重开并重新选择
    try std.testing.expectEqual(@as(usize, 2), Fake.usb_calls);
    try std.testing.expectEqual(@as(usize, 0), Fake.ble_calls); // USB 可用就不碰 BLE
    st.drop();
}

test "State：双链路都不可用时 dev 保持空，错误原样上报" {
    const Fake = struct {
        fn usbMissing() !usb.Device {
            return error.DeviceNotFound;
        }
        fn bleDown() !ble.Device {
            return error.BluezUnavailable;
        }
    };
    var st: State = .{};
    try std.testing.expectError(error.BluezUnavailable, st.ensure(Fake.usbMissing, Fake.bleDown));
    try std.testing.expect(st.dev == null);
}

test "acquireLock：锁路径过长报 PathTooLong，不触碰文件系统" {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    @memset(&path_buf, 'x'); // 满长 + ".lock" 必然放不下
    try std.testing.expectError(error.PathTooLong, acquireLock(&path_buf));
}
