//! f9d：Legion F9 设备 daemon。独占设备（优先 USB，必要时 BLE），经 Unix socket
//! 向 f9ctl 提供单行请求 / JSON 响应服务（协议见 ipc.zig）。前台运行，日志走 stderr
//! （systemd 收进 journal）；由 init 系统负责生命周期与重启。
//!
//! 并发模型：每个连接一个线程，真正的设备访问由一把互斥锁串行化（会话命令有状态，
//! 设备流量必须串行）。这样慢客户端/空闲连接只占自己的处理线程，不会把其他用户的
//! 请求饿死；同时在用连接数有上限，超过就立即回 ServerBusy 而不是排队。
//! SIGINT/SIGTERM/SIGHUP 只置位停止标志：主循环 poll 到后停止 accept，等在用连接
//! 收尾（有上限），再释放设备句柄并删除 socket。

const std = @import("std");
const f9 = @import("f9");

const protocol = f9.protocol;
const usb = f9.usb;
const ble = f9.ble;
const ops = f9.ops;
const ipc = f9.ipc;
const log = f9.log;
const monoMs = f9.monoMs;
const sleepMs = f9.sleepMs;

/// 客户端连上后保持沉默的上限，防止单个连接长期占着处理线程。
const conn_read_timeout_ms = 5000;
/// 同时处理的连接上限：设备本身串行，这里只防线程与内存被无限占满。
const max_connections = 8;
/// accept 前 poll 的等待上限。收到停止标志（或测试收尾）时由自唤醒管道立即打断，
/// 这个值只是没有唤醒时的兜底轮询周期。
const default_accept_poll_ms = 200;
/// 收到终止信号后等在用连接收尾的上限。
const shutdown_grace_ms = 3000;
/// 连接数已满时拒绝连接的收尾期限。
/// 拒绝路径跑在 accept 线程上，把它压到毫秒级：正常客户端连上就发请求、读完响应即关闭，
/// 几十毫秒足够把请求读空；赖着不关的对端最多让 accept 线程停 20ms，而不是 200ms。
const reject_drain_ms = 20;
/// 响应写不出去的兜底期限：对端不读且发送缓冲区满时，工作线程不会永久阻塞。
const send_timeout_ms = 5000;
/// 回完响应、关闭连接前把对端剩余输入读空的期限。
/// 直接 close 一个还有未读字节的 socket 会向对端发 RST，内核会连同我们刚写出的
/// 响应一起丢掉——客户端只看到“连接被重置”，看不到 ServerBusy / TrailingData /
/// LineTooLong 这些本该可诊断的错误。
/// 正常客户端读完响应即关闭，读空远快于这个上限；只有赖着不关的对端才会等满。
/// 拒绝路径（连接数已满）跑在 accept 线程上，因此这里取 200ms 而不是秒级：
/// 上限满时本来就以拒绝为主，这点延迟远小于 5s 的静默读超时。
const conn_drain_ms = 200;

/// 自唤醒管道：信号处理器只往写端塞 1 字节（write 是 async-signal-safe），
/// 主循环 poll 读端而不是死等轮询周期。停机与测试收尾都不再等一个 accept_poll。
/// 未初始化（fd < 0）时 wake 是空操作，单元测试里的信号测试可以照常跑。
var wake_pipe: [2]std.posix.fd_t = .{ -1, -1 };

fn initWakePipe() !void {
    if (wake_pipe[0] >= 0) return;
    var fds: [2]std.posix.fd_t = undefined;
    switch (std.posix.errno(std.posix.system.pipe2(&fds, .{ .NONBLOCK = true, .CLOEXEC = true }))) {
        .SUCCESS => wake_pipe = fds,
        else => return error.Unexpected,
    }
}

fn wake() void {
    if (wake_pipe[1] < 0) return;
    // write(2) 是 async-signal-safe：处理器里只做这一件事
    _ = std.posix.system.write(wake_pipe[1], "\x00", 1);
}

/// 读空唤醒管道（非阻塞）：多个信号/多次唤醒合并成一次处理。
fn drainWake() void {
    if (wake_pipe[0] < 0) return;
    var buf: [16]u8 = undefined;
    while (true) {
        const rc = std.posix.system.read(wake_pipe[0], &buf, buf.len);
        if (std.posix.errno(rc) != .SUCCESS) return;
        if (rc < buf.len) return;
    }
}

/// 链路：USB 优先，仅 USB 未找到/无应答时才用 BLE（见 openPreferred）。
/// 一次请求内不换链路、不重放写入；失败即丢弃句柄，下个请求重新选择。
/// ops 只依赖下面三个语义操作，具体帧与事务由 USB/BLE 各自实现。
const Link = union(enum) {
    usb: usb.Device,
    ble: ble.Device,

    fn tag(self: Link) std.meta.Tag(Link) {
        return std.meta.activeTag(self);
    }

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

    /// 复用前的探活：只查内核/BlueZ 状态，不发设备命令。
    fn alive(self: *Link) bool {
        return switch (self.*) {
            .usb => |d| d.alive(),
            .ble => |*d| d.alive(),
        };
    }

    pub fn close(self: *Link, io: std.Io) void {
        switch (self.*) {
            .usb => |*d| d.close(io),
            .ble => |*d| d.close(),
        }
    }
};

/// 链路打开方式：函数指针注入，生产指向 usb/ble 模块，测试注入 fake。
const Openers = struct {
    usb_present: *const fn (std.Io) bool,
    usb_open: *const fn (std.Io) anyerror!usb.Device,
    ble_open: *const fn () anyerror!ble.Device,

    const production: Openers = .{
        .usb_present = presentUsb,
        .usb_open = openUsb,
        .ble_open = openBle,
    };
};

fn presentUsb(io: std.Io) bool {
    return usb.Device.present(io);
}

fn openUsb(io: std.Io) anyerror!usb.Device {
    return usb.Device.open(io);
}

fn openBle() anyerror!ble.Device {
    return ble.Device.open();
}

fn tagOf(want: ipc.LinkKind) std.meta.Tag(Link) {
    return switch (want) {
        .usb => .usb,
        .ble => .ble,
    };
}

/// USB 优先；仅当 USB 未找到/无应答时回落 BLE。
/// 权限等其他 USB 错误原样上报：不能用 BLE 掩盖 USB 权限问题。
fn openPreferred(io: std.Io, openers: Openers) !Link {
    const dev = openers.usb_open(io) catch |usb_err| {
        if (!shouldTryBle(usb_err)) return usb_err;
        const ble_dev = openers.ble_open() catch |ble_err| return combineLinkErrors(usb_err, ble_err);
        return .{ .ble = ble_dev };
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

/// 两条链路都不可用时的最终错误。
/// BLE 侧的“没找到设备 / BlueZ 不可用”只说明这条路走不通，不能覆盖 USB 侧的原始
/// 诊断（例如“设备存在但协议接口无应答”）；BLE 侧其余错误（权限、连接、GATT）
/// 更有信息量，原样上报。
fn combineLinkErrors(usb_err: anyerror, ble_err: anyerror) anyerror {
    const ble_is_absence = switch (ble_err) {
        error.DeviceNotFound, error.BluezUnavailable => true,
        else => false,
    };
    if (!ble_is_absence) return ble_err;
    log("f9d: BLE 链路不可用（{s}），保留 USB 侧诊断", .{@errorName(ble_err)});
    return usb_err;
}

/// 复用决策（纯函数）：是否需要丢弃现有句柄、重新建链。
/// - 显式指定链路时，链路不符就换（不回落）；
/// - 自动选择时句柄已挂断就重开；
/// - 自动选择时 USB 优先：BLE 句柄遇到已接入的 USB 就切回。
fn shouldReplaceLink(tag: std.meta.Tag(Link), alive: bool, usb_present: bool, want: ?ipc.LinkKind) bool {
    // 挂断的句柄任何模式都先重开：显式 --link 也不能复用死连接
    if (!alive) return true;
    if (want) |w| return tag != tagOf(w);
    return tag == .ble and usb_present;
}

/// 尝试把现有句柄切到 USB：只有 USB 真正打开成功才切换。
/// 失败（设备在但协议接口无应答/权限变化）时继续用现有链路，只记一行日志。
fn trySwitchToUsb(io: std.Io, st: *State, openers: Openers) bool {
    const dev = openers.usb_open(io) catch |err| {
        log("f9d: USB 已接入但不可用（{s}），继续使用现有链路", .{@errorName(err)});
        return false;
    };
    log("f9d: 检测到可用 USB，切回 USB 链路", .{});
    st.drop(io);
    st.dev = .{ .usb = dev };
    return true;
}

/// 设备句柄：惰性打开（设备可能晚于 daemon 启动接入），失败后丢弃。
const State = struct {
    dev: ?Link = null,

    fn ensure(st: *State, io: std.Io, openers: Openers, want: ?ipc.LinkKind) !*Link {
        if (st.dev) |*cur| {
            const alive = cur.alive();
            // 只有 BLE 句柄才需要查“USB 是否已接入”，USB 句柄不必读 sysfs
            const usb_present = cur.tag() == .ble and openers.usb_present(io);
            if (shouldReplaceLink(cur.tag(), alive, usb_present, want)) {
                // USB 优先的切换只在现有链路仍可用、且 USB 真能打开时发生：
                // 设备插着但协议接口无应答时继续用现有 BLE，不把可用链路推倒重来。
                if (want == null and cur.tag() == .ble and alive and usb_present) {
                    _ = trySwitchToUsb(io, st, openers);
                } else {
                    log("f9d: 丢弃现有 {s} 链路，重新选择", .{@tagName(cur.tag())});
                    st.drop(io);
                }
            }
        }
        if (st.dev == null) {
            // 先在局部值里完成打开再写回：直接赋值给 st.dev 时，union 的 tag 会被先写入
            // 结果位置，payload 的 try 失败会留下“有 tag、无 payload”的半成品句柄。
            const opened: Link = if (want) |w| switch (w) {
                .usb => .{ .usb = try openers.usb_open(io) },
                .ble => .{ .ble = try openers.ble_open() },
            } else try openPreferred(io, openers);
            st.dev = opened;
            log("f9d: 设备已连接（{s}）", .{@tagName(st.dev.?.tag())});
            // 新链路：BLE 预算已从 open 入口起算（含打开），不再重置
        } else {
            st.dev.?.beginRequest(); // 复用：上个请求的预算可能已耗尽
        }
        return &st.dev.?;
    }

    /// 任何事务错误都丢弃句柄、由下个请求惰性重开来覆盖拔插/断线；
    /// 不做重试/退避，拔插频繁到日志噪声时可再加。
    fn drop(st: *State, io: std.Io) void {
        if (st.dev) |*d| d.close(io);
        st.dev = null;
    }
};

/// 终止信号标志：处理器只置位，主循环负责收尾。
var signal_stop = std.atomic.Value(bool).init(false);

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    signal_stop.store(true, .release);
    wake(); // 先置标志再唤醒：主循环看到可读时状态已经就绪
}

fn installSignalHandlers() void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    // INT/TERM 是正常停机；HUP 覆盖终端关闭。SIGPIPE 由 Zig 启动代码忽略，
    // 写已关闭的客户端连接只会得到 error.BrokenPipe，不会杀掉 daemon。
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    std.posix.sigaction(std.posix.SIG.HUP, &act, null);
}

/// 把 SIGINT/SIGTERM/SIGHUP 恢复成默认处置。仅供测试收尾：
/// 生产路径从不恢复（f9d 本来就该死在信号上）。
fn restoreDefaultSignalHandlers() void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    std.posix.sigaction(std.posix.SIG.HUP, &act, null);
}

/// 服务端共享状态：设备状态 + 串行化锁 + 连接计数 + 停止标志。
const Server = struct {
    io: std.Io,
    state: State = .{},
    openers: Openers = Openers.production,
    dev_mutex: std.Io.Mutex = std.Io.Mutex.init,
    active: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    stop: *std.atomic.Value(bool) = &signal_stop,
    /// 没有自唤醒时的兜底轮询周期；测试可以放大它来证明“唤醒真的生效了”。
    accept_poll_ms: i32 = default_accept_poll_ms,

    fn stopping(self: *const Server) bool {
        return self.stop.load(.acquire);
    }

    /// 循环：poll 等新连接 → 交给独立线程；读阶段与设备访问各自有界。
    fn serve(self: *Server, srv: *std.Io.net.Server) void {
        while (!self.stopping()) {
            var fds = [_]std.posix.pollfd{
                .{ .fd = srv.socket.handle, .events = std.posix.POLL.IN, .revents = 0 },
                .{ .fd = wake_pipe[0], .events = std.posix.POLL.IN, .revents = 0 },
            };
            const ready = std.posix.poll(&fds, self.accept_poll_ms) catch |err| {
                log("f9d: 等待连接失败: {s}", .{@errorName(err)});
                continue;
            };
            if (ready == 0) continue;
            if (fds[1].revents & std.posix.POLL.IN != 0) drainWake();
            // 唤醒与监听事件可能同批到达：先看停止标志，别再 accept 新连接
            if (self.stopping()) break;
            if (fds[0].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL) != 0) {
                // 监听 socket 失效（被外部关闭/替换）：继续 accept 只会忙等刷日志
                log("f9d: 监听 socket 失效，停止接受新连接", .{});
                return;
            }
            if (fds[0].revents & std.posix.POLL.IN == 0) continue;
            const conn = srv.accept(self.io) catch |err| {
                log("f9d: accept 失败: {s}", .{@errorName(err)});
                continue;
            };
            self.spawnConn(conn);
        }
    }

    fn spawnConn(self: *Server, stream: std.Io.net.Stream) void {
        if (self.active.load(.acquire) >= max_connections) {
            // 立即拒绝：宁可用户看到 ServerBusy，也不让所有人在队列里饿死
            respondError(stream.socket.handle, error.ServerBusy);
            // 拒绝路径在 accept 线程上：只做短暂收尾，不能让一个赖着不关的对端卡住接入
            finishConn(self.io, stream, reject_drain_ms);
            return;
        }
        _ = self.active.fetchAdd(1, .acq_rel);
        setSendTimeout(stream);
        const th = std.Thread.spawn(.{}, handleConn, .{ stream, self }) catch |err| {
            _ = self.active.fetchSub(1, .acq_rel);
            log("f9d: 创建工作线程失败: {s}", .{@errorName(err)});
            stream.close(self.io);
            return;
        };
        th.detach();
    }

    fn dispatch(self: *Server, line: []const u8, buf: []u8) []const u8 {
        const req = ipc.parseRequest(line) catch |err| return ipc.formatError(buf, err);
        // 设备访问串行：会话命令有状态，多请求并发会互相破坏读-改-写
        // 用 lockUncancelable：这里没有取消源，且响应必须写完再返回
        self.dev_mutex.lockUncancelable(self.io);
        defer self.dev_mutex.unlock(self.io);
        return self.runRequest(req, buf) catch |err| return ipc.formatError(buf, err);
    }

    fn runRequest(self: *Server, req: ipc.Request, buf: []u8) ![]const u8 {
        const dev = try self.state.ensure(self.io, self.openers, req.link);
        // ensure 之后发生的任何错误都视为设备链路问题，丢弃句柄待下次重开
        return onDevice(dev, req.op, buf) catch |err| {
            self.state.drop(self.io);
            return err;
        };
    }
};

fn onDevice(dev: *Link, op: ipc.Op, buf: []u8) ![]const u8 {
    return switch (op) {
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

/// 一个连接：读一行 → 串行处理 → 写回一行，然后关闭。
fn handleConn(stream: std.Io.net.Stream, srv: *Server) void {
    const fd = stream.socket.handle;
    defer {
        finishConn(srv.io, stream, conn_drain_ms);
        _ = srv.active.fetchSub(1, .acq_rel);
    }
    var rbuf: [ipc.max_request_len]u8 = undefined;
    const line = ipc.readLine(fd, &rbuf, conn_read_timeout_ms) catch |err| {
        // 能回就回错误名，让客户端看到 TrailingData / LineTooLong 而不是“提前关闭”
        respondError(fd, err);
        return;
    };
    var wbuf: [ipc.max_reply_len]u8 = undefined;
    const out = srv.dispatch(line, &wbuf);
    f9.writeAll(fd, out) catch return;
    f9.writeAll(fd, "\n") catch {};
}

fn respondError(fd: std.posix.fd_t, err: anyerror) void {
    var buf: [ipc.max_reply_len]u8 = undefined;
    const out = ipc.formatError(&buf, err);
    f9.writeAll(fd, out) catch return;
    f9.writeAll(fd, "\n") catch {};
}

/// 给已接受的连接设发送期限。响应只有几十到两百多字节，正常不会阻塞；
/// 但对端若把接收窗口压到极小又不读，工作线程会卡在 writeAll 上直到进程退出。
/// 设了期限后写失败返回 WouldBlock，连接随即关闭，线程不会泄漏。
fn setSendTimeout(stream: std.Io.net.Stream) void {
    const tv = std.posix.timeval{
        .sec = @intCast(@divTrunc(send_timeout_ms, 1000)),
        .usec = @intCast(@mod(send_timeout_ms, 1000) * 1000),
    };
    std.posix.setsockopt(
        stream.socket.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.SNDTIMEO,
        std.mem.asBytes(&tv),
    ) catch {};
}

/// 关闭前先读空对端剩余输入（有界），保证已写出的响应不被 RST 丢弃。
/// 半关闭（shutdown write）让对端立刻看到 EOF，再按期限清空接收队列；
/// 期限用尽就照常关闭——最坏情况退化成原来的一次性 close，不会无限挂住。
/// 期限由调用方给：工作线程可以等满 `conn_drain_ms`，accept 线程只给 `reject_drain_ms`。
fn finishConn(io: std.Io, stream: std.Io.net.Stream, drain_ms: i64) void {
    const fd = stream.socket.handle;
    stream.shutdown(io, .send) catch {};
    const deadline = monoMs() + drain_ms;
    var scratch: [256]u8 = undefined;
    while (monoMs() < deadline) {
        var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const left: i32 = @intCast(@min(deadline - monoMs(), @as(i64, 50)));
        if (left <= 0) break;
        const ready = std.posix.poll(&fds, left) catch break;
        if (ready == 0) continue;
        const n = f9.readSome(fd, &scratch) catch break;
        if (n == 0) break; // 对端已关闭：接收队列已空，可以干净地 close
    }
    stream.close(io);
}

/// 等在用连接收尾（有上限）。返回 true 表示已全部结束。
/// 超时返回 false：调用方不要此时释放设备状态（还有线程在用），交给进程退出回收。
fn waitIdle(srv: *Server, timeout_ms: i64) bool {
    const deadline = monoMs() + timeout_ms;
    while (srv.active.load(.acquire) != 0 and monoMs() < deadline) {
        sleepMs(10);
    }
    if (srv.active.load(.acquire) != 0) {
        log("f9d: 仍有连接在处理，直接退出", .{});
        return false;
    }
    return true;
}

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        log("f9d: 启动失败: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const io = init.io;
    // 环境变量只在入口取一次（Zig 0.16 起不再是全局状态）
    const xdg = init.minimal.environ.getPosix("XDG_RUNTIME_DIR");
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = ipc.daemonSocketPath(xdg, &path_buf) catch |err| switch (err) {
        error.NoRuntimeDir => {
            log("f9d: 未设置 XDG_RUNTIME_DIR，拒绝回退到 /tmp（可预测路径有符号链接攻击风险）", .{});
            std.process.exit(1);
        },
        error.PathTooLong => {
            log("f9d: XDG_RUNTIME_DIR 过长，socket 路径放不下，拒绝启动", .{});
            std.process.exit(1);
        },
    };
    const is_root = std.posix.system.geteuid() == 0;
    // 非 root 实例的安全前提：XDG_RUNTIME_DIR 属主本人且权限不宽于 0700，
    // 否则 socket/lock 仍可被同机其他用户占位——不满足即拒绝启动。
    if (!is_root) ipc.validateRuntimeDir(xdg) catch {
        log("f9d: XDG_RUNTIME_DIR 须为属主本人、权限不宽于 0700 的目录，拒绝启动", .{});
        std.process.exit(1);
    };
    if (is_root) std.Io.Dir.createDirAbsolute(io, ipc.root_dir, .fromMode(0o755)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |e| return e,
    };

    // 防双开：对锁文件 flock，持锁期间残留 socket 必属死实例，直接清掉再绑定。
    // （原来的 connect 探测 → 删除 → bind 三步有 TOCTOU 窗口）
    _ = try acquireLock(io, path);
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};

    var addr = try std.Io.net.UnixAddress.init(path);
    var srv_listen = try addr.listen(io, .{});
    defer srv_listen.deinit(io);
    // root 实例放开给任意本地用户（风扇控制，低敏）；要收紧就换用户组/polkit。
    // 失败必须上抛：权限没设成时非 root 客户端只会得到 EACCES，
    // 静默继续会把“socket 有、连不上”推迟成难排查的运行期问题。
    if (is_root) try std.Io.Dir.setFilePermissions(std.Io.Dir.cwd(), io, path, .fromMode(0o666), .{});

    // 自唤醒管道：信号处理器靠它打断 accept 前的 poll（未初始化时 wake 为空操作）
    try initWakePipe();
    installSignalHandlers();
    log("f9d: 监听 {s}", .{path});

    var srv: Server = .{ .io = io };
    srv.serve(&srv_listen);

    log("f9d: 收到终止信号，正在退出", .{});
    // 只有确认所有连接线程都结束后才释放设备状态：超时仍在处理时直接退出，
    // 由进程结束回收，避免在别的线程还持有 sd_bus/file 时关闭它。
    if (waitIdle(&srv, shutdown_grace_ms)) srv.state.drop(io);
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};
}

/// 对 <socket>.lock 加排他非阻塞 flock；已有实例持锁则报 AlreadyRunning。
/// 返回的 File 由调用方持有不关：锁随 fd 存活，进程退出自动释放。
fn acquireLock(io: std.Io, sock_path: []const u8) !std.Io.File {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    // XDG_RUNTIME_DIR 可超长：拼不进缓冲报错，不用 unreachable panic
    const lock_path = std.fmt.bufPrint(&buf, "{s}.lock", .{sock_path}) catch return error.PathTooLong;
    // truncate=false：即使锁文件路径被符号链接占位也不截断目标文件
    // （socket 目录本应可信，此为纵深防御）。
    const f = try std.Io.Dir.createFileAbsolute(io, lock_path, .{ .truncate = false });
    errdefer f.close(io);
    switch (std.posix.errno(std.posix.system.flock(f.handle, std.posix.LOCK.EX | std.posix.LOCK.NB))) {
        .SUCCESS => {},
        .AGAIN => return error.AlreadyRunning, // EAGAIN == EWOULDBLOCK
        else => |e| return std.posix.unexpectedErrno(e),
    }
    return f;
}

test {
    std.testing.refAllDecls(@This());
}

// ---------------------------------------------------------------------------
// 测试：链路选择、复用策略、端到端 socket 服务
// ---------------------------------------------------------------------------

/// 用裸 fd 造一个阻塞模式的 Io.File（假设备与夹具的连接端用）。
fn fdFile(fd: std.posix.fd_t) std.Io.File {
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

/// 连到夹具的 unix socket（等价于旧的 std.net.connectUnixSocket）。
fn connectUnix(io: std.Io, path: []const u8) !std.Io.net.Stream {
    var addr = try std.Io.net.UnixAddress.init(path);
    return addr.connect(io);
}

test "acquireLock：同一路径不可重复加锁，释放后可再加" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &dir_buf);
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const sock = try std.fmt.bufPrint(&path_buf, "{s}/f9d.sock", .{dir_buf[0..n]});

    const first = try acquireLock(io, sock);
    try std.testing.expectError(error.AlreadyRunning, acquireLock(io, sock));
    first.close(io);
    const second = try acquireLock(io, sock);
    second.close(io);
}

test "信号处理：SIGTERM 只置位停止标志，不终止进程" {
    installSignalHandlers();
    // 测试进程会继续跑别的测试：结束前必须换回默认处置，
    // 否则外部 SIGTERM/SIGINT 只置位标志、无法终止测试进程。
    defer restoreDefaultSignalHandlers();

    // 三个信号都必须装上同一个处理器（只测 TERM 会漏掉 INT/HUP 的接线）
    inline for ([_]std.posix.SIG{ std.posix.SIG.INT, std.posix.SIG.TERM, std.posix.SIG.HUP }) |sig| {
        const act: std.posix.Sigaction = .{
            .handler = .{ .handler = onSignal },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        var old: std.posix.Sigaction = undefined;
        std.posix.sigaction(sig, &act, &old); // 传 act 只为读回替换掉的旧值
        const installed = old.handler.handler orelse return error.TestUnexpectedResult;
        try std.testing.expect(installed == onSignal);
    }

    signal_stop.store(false, .release);
    try std.posix.raise(std.posix.SIG.TERM);
    try std.testing.expect(signal_stop.load(.acquire));
    var srv: Server = .{ .io = std.testing.io }; // 默认 stop 指向 signal_stop
    try std.testing.expect(srv.stopping());
    signal_stop.store(false, .release);
    try std.testing.expect(!srv.stopping());
}

test "acquireLock：锁路径过长报 PathTooLong，不触碰文件系统" {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    @memset(&path_buf, 'x'); // 满长 + ".lock" 必然放不下
    try std.testing.expectError(error.PathTooLong, acquireLock(std.testing.io, &path_buf));
}

const LinkFakes = struct {
    var usb_present: bool = false;
    var usb_calls: usize = 0;
    var ble_calls: usize = 0;
    var usb_err: ?anyerror = null;
    var ble_err: ?anyerror = null;

    fn reset() void {
        usb_present = false;
        usb_calls = 0;
        ble_calls = 0;
        usb_err = null;
        ble_err = null;
    }

    fn present(_: std.Io) bool {
        return usb_present;
    }

    fn openFakeUsb(io: std.Io) anyerror!usb.Device {
        usb_calls += 1;
        if (usb_err) |err| return err;
        // /dev/null 充当假句柄：alive 为真，close 无副作用
        return .{ .file = try std.Io.Dir.openFileAbsolute(io, "/dev/null", .{}) };
    }

    fn openFakeBle() anyerror!ble.Device {
        ble_calls += 1;
        if (ble_err) |err| return err;
        // 绝不返回“假 BLE 句柄”：ble.Device 必须持有真实 sd_bus，填 undefined
        // 只会在 alive()/close() 时炸掉。没有 ble_err 的用例想验证“BLE 可用”，
        // 就得改成默认设备不可用或另写离线 sd-bus 夹具。
        return error.BluezUnavailable;
    }

    const openers: Openers = .{ .usb_present = present, .usb_open = openFakeUsb, .ble_open = openFakeBle };
};

/// 静音 f9d 诊断输出，返回旧 sink 供 defer 恢复。
/// 这些用例会打“设备已连接/丢弃链路”等日志；测试输出应只留失败信息。
fn silenceLog() ?*const fn ([]const u8) void {
    return f9.setLogSink(f9.discardLog);
}

test "serve：停止标志 + 自唤醒后立即退出，不再等 poll 周期" {
    try initWakePipe();
    // 不自唤醒就要等满 5s 才会重新检查停止标志：这个值把“是否真被唤醒”变成确定断言
    var h: Harness = .{ .accept_poll_ms = 5000 };
    defer h.deinit();
    try h.start();

    h.stop.store(true, .release);
    const started = monoMs();
    wake();
    if (h.srv_thread) |t| {
        t.join();
        h.srv_thread = null;
    }
    try std.testing.expect(monoMs() - started < 1000);
}

test "设备选择：仅 USB 未找到/无应答才回落 BLE，两条都不可用保留 USB 诊断" {
    const io = std.testing.io;
    const log_prev = silenceLog();
    defer _ = f9.setLogSink(log_prev);
    LinkFakes.reset();
    LinkFakes.ble_err = error.BluezUnavailable;

    // USB 未找到 + BLE 无 BlueZ：设备确实不在，报 DeviceNotFound
    LinkFakes.usb_err = error.DeviceNotFound;
    try std.testing.expectError(error.DeviceNotFound, openPreferred(io, LinkFakes.openers));
    try std.testing.expectEqual(@as(usize, 1), LinkFakes.ble_calls);

    // USB 无应答 + BLE 无设备：保留“设备存在但协议接口无应答”
    LinkFakes.reset();
    LinkFakes.usb_err = error.DeviceNotResponding;
    LinkFakes.ble_err = error.DeviceNotFound;
    try std.testing.expectError(error.DeviceNotResponding, openPreferred(io, LinkFakes.openers));

    // USB 未找到 + BLE 权限被拒：BLE 的可诊断错误优先
    LinkFakes.reset();
    LinkFakes.usb_err = error.DeviceNotFound;
    LinkFakes.ble_err = error.BleAccessDenied;
    try std.testing.expectError(error.BleAccessDenied, openPreferred(io, LinkFakes.openers));

    // USB 权限错误：原样上报，绝不回落 BLE
    LinkFakes.reset();
    LinkFakes.usb_err = error.UsbAccessDenied;
    try std.testing.expectError(error.UsbAccessDenied, openPreferred(io, LinkFakes.openers));
    try std.testing.expectEqual(@as(usize, 0), LinkFakes.ble_calls);
    try std.testing.expect(!shouldTryBle(error.UsbAccessDenied));
    try std.testing.expect(!shouldTryBle(error.Timeout));
}

test "复用策略：显式链路优先、挂断重开、BLE 遇到 USB 切回" {
    // 显式指定链路：不符就换；但挂断的句柄即便链路相符也必须重开
    try std.testing.expect(shouldReplaceLink(.usb, true, true, .ble));
    try std.testing.expect(shouldReplaceLink(.ble, true, false, .usb));
    try std.testing.expect(shouldReplaceLink(.usb, false, true, .usb));
    try std.testing.expect(shouldReplaceLink(.ble, false, false, .ble));
    try std.testing.expect(!shouldReplaceLink(.usb, true, true, .usb));
    // 自动：挂断重开；BLE 句柄遇到 USB 就切回；USB 句柄不因 BLE 存在而换
    try std.testing.expect(shouldReplaceLink(.usb, false, false, null));
    try std.testing.expect(shouldReplaceLink(.ble, true, true, null));
    try std.testing.expect(!shouldReplaceLink(.ble, true, false, null));
    try std.testing.expect(!shouldReplaceLink(.usb, true, true, null));
}

test "State：复用期间不重复打开，丢弃后下个请求惰性重开" {
    const io = std.testing.io;
    const log_prev = silenceLog();
    defer _ = f9.setLogSink(log_prev);
    LinkFakes.reset();
    var st: State = .{};
    const first = try st.ensure(io, LinkFakes.openers, null);
    const again = try st.ensure(io, LinkFakes.openers, null);
    try std.testing.expect(first == again); // 同一句柄：不换链路、不重复打开
    try std.testing.expectEqual(@as(usize, 1), LinkFakes.usb_calls);
    st.drop(io); // 事务失败路径：丢弃句柄
    try std.testing.expect(st.dev == null);
    _ = try st.ensure(io, LinkFakes.openers, null); // 下个请求惰性重开
    try std.testing.expectEqual(@as(usize, 2), LinkFakes.usb_calls);
    try std.testing.expectEqual(@as(usize, 0), LinkFakes.ble_calls); // USB 可用就不碰 BLE
    st.drop(io);
}

test "State：双链路都不可用时 dev 保持空，错误原样上报" {
    const io = std.testing.io;
    const log_prev = silenceLog();
    defer _ = f9.setLogSink(log_prev);
    LinkFakes.reset();
    LinkFakes.usb_err = error.DeviceNotFound;
    LinkFakes.ble_err = error.BluezUnavailable;
    var st: State = .{};
    try std.testing.expectError(error.DeviceNotFound, st.ensure(io, LinkFakes.openers, null));
    try std.testing.expect(st.dev == null);
    // 显式链路失败同样不留半成品句柄
    try std.testing.expectError(error.BluezUnavailable, st.ensure(io, LinkFakes.openers, .ble));
    try std.testing.expect(st.dev == null);
    st.drop(io);
}

test "trySwitchToUsb：只有新链路真能打开才替换，失败保留现有句柄" {
    const io = std.testing.io;
    const log_prev = silenceLog();
    defer _ = f9.setLogSink(log_prev);
    LinkFakes.reset();
    var st: State = .{};
    _ = try st.ensure(io, LinkFakes.openers, .usb);
    const before = st.dev.?.usb.file.handle;

    // 打不开（设备在但协议接口无应答）：保留原句柄，不推倒重来
    LinkFakes.usb_err = error.DeviceNotResponding;
    try std.testing.expect(!trySwitchToUsb(io, &st, LinkFakes.openers));
    try std.testing.expectEqual(before, st.dev.?.usb.file.handle);

    // 能打开：替换句柄
    LinkFakes.usb_err = null;
    try std.testing.expect(trySwitchToUsb(io, &st, LinkFakes.openers));
    try std.testing.expect(st.dev.?.usb.file.handle != before);
    st.drop(io);
}

test "State：挂断的句柄在复用前被替换，不先用死句柄失败一次" {
    const io = std.testing.io;
    const log_prev = silenceLog();
    defer _ = f9.setLogSink(log_prev);
    LinkFakes.reset();
    var st: State = .{};

    // 管道写端关闭 = 拔线：poll 报 POLLHUP，句柄仍可正常关闭（无 fd 复用陷阱）
    const fds = try f9.pipeFds();
    f9.closeFd(fds[1]);
    st.dev = .{ .usb = .{ .file = fdFile(fds[0]) } };
    try std.testing.expect(!st.dev.?.alive());

    _ = try st.ensure(io, LinkFakes.openers, null); // 自动模式：死句柄不参与决策，直接重开
    try std.testing.expectEqual(std.meta.Tag(Link).usb, st.dev.?.tag());
    try std.testing.expect(st.dev.?.alive());
    try std.testing.expectEqual(@as(usize, 1), LinkFakes.usb_calls);
    st.drop(io);
}

test "State：显式链路与现有句柄不符时换链，不回落另一条链路" {
    const io = std.testing.io;
    const log_prev = silenceLog();
    defer _ = f9.setLogSink(log_prev);
    LinkFakes.reset();
    var st: State = .{};
    _ = try st.ensure(io, LinkFakes.openers, .usb);
    try std.testing.expectEqual(std.meta.Tag(Link).usb, st.dev.?.tag());

    // 强制 BLE：先丢弃 USB 句柄再打开 BLE；打不开就报错，不偷偷用回 USB
    LinkFakes.ble_err = error.BluezUnavailable;
    try std.testing.expectError(error.BluezUnavailable, st.ensure(io, LinkFakes.openers, .ble));
    try std.testing.expect(st.dev == null); // 旧句柄已丢弃，不留半成品
    try std.testing.expectEqual(@as(usize, 1), LinkFakes.ble_calls);
    st.drop(io);
}

test "State：强制链路不走回落，错误原样上报" {
    const io = std.testing.io;
    LinkFakes.reset();
    var st: State = .{};
    LinkFakes.ble_err = error.BluezUnavailable;
    try std.testing.expectError(error.BluezUnavailable, st.ensure(io, LinkFakes.openers, .ble));
    try std.testing.expectEqual(@as(usize, 1), LinkFakes.ble_calls);
    try std.testing.expectEqual(@as(usize, 0), LinkFakes.usb_calls); // 不偷偷回落 USB
    try std.testing.expect(st.dev == null);
    st.drop(io);
}

/// 假 hidraw：socketpair 的一端交给 usb.Device，另一端由设备线程回帧。
/// 每次 open 都 dup 一个副本：state.drop 关掉自己的副本后，重开的句柄仍然有效。
const FakeDevice = struct {
    var client: ?std.posix.fd_t = null;
    /// 线程间共享的计数一律用原子：设备线程写、测试线程读。
    var requests: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
    /// 建链次数：用于判定“失败后是否真的丢弃句柄、下个请求重新打开”。
    var opens: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
    /// 收到 settings_write 仍照常回帧但不落盘：制造 gear_set 的“回读不一致”。
    var ignore_writes: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
    /// 设备线程退出标志：不依赖“所有写端都已关闭”来收尾，join 必然有界。
    var stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
    var settings: [protocol.settings_len]u8 = std.mem.zeroes([protocol.settings_len]u8);

    /// 每个夹具启动时重置；ignore_writes 由用例自行设定（reset 不动它）。
    fn reset(fd: std.posix.fd_t) void {
        client = fd;
        requests.store(0, .release);
        opens.store(0, .release);
        stop.store(false, .release);
        @memset(&settings, 0xA5);
        settings[13] = 0x01; // balanced
    }

    fn present(_: std.Io) bool {
        return true;
    }

    fn openFakeUsb(_: std.Io) anyerror!usb.Device {
        const fd = client orelse return error.DeviceNotFound;
        _ = opens.fetchAdd(1, .acq_rel);
        const rc = std.posix.system.dup(fd);
        if (std.posix.errno(rc) != .SUCCESS) return error.Unexpected;
        return .{ .file = fdFile(@intCast(rc)) };
    }

    fn openFakeBle() anyerror!ble.Device {
        return error.BluezUnavailable;
    }

    const openers: Openers = .{ .usb_present = present, .usb_open = openFakeUsb, .ble_open = openFakeBle };

    /// 设备侧线程：按请求命令回 64 字节响应帧，直到 stop 被置位或对端关闭。
    fn serve(peer: std.posix.fd_t) void {
        var buf = std.mem.zeroes([protocol.frame_len]u8);
        while (!stop.load(.acquire)) {
            var fds = [_]std.posix.pollfd{.{ .fd = peer, .events = std.posix.POLL.IN, .revents = 0 }};
            if ((std.posix.poll(&fds, 100) catch return) == 0) continue;
            const n = f9.readSome(peer, &buf) catch return;
            if (n == 0) return;
            if (n != protocol.frame_len) continue;
            _ = requests.fetchAdd(1, .acq_rel);
            var resp = std.mem.zeroes([protocol.frame_len]u8);
            resp[0] = protocol.report_id;
            resp[3] = buf[3];
            const cmd: protocol.Command = @fromBackingInt(buf[3]);
            switch (cmd) {
                .live_status => {
                    resp[4] = 3;
                    resp[8] = 0x02;
                    resp[9] = 0xf4;
                    resp[10] = 0x1f;
                },
                .settings_read => {
                    resp[4] = protocol.settings_len;
                    @memcpy(resp[8..][0..protocol.settings_len], &settings);
                },
                .settings_write => {
                    // 持久化写入块：gear_set 的“回读确认”才能读到新值
                    if (!ignore_writes.load(.acquire)) @memcpy(settings[0..buf[4]], buf[8..][0..buf[4]]);
                    resp[4] = buf[4];
                    @memcpy(resp[8..][0..buf[4]], buf[8..][0..buf[4]]);
                },
                .session_open, .session_close => {
                    resp[4] = 1;
                    resp[8] = buf[8];
                },
            }
            protocol.stampChecksum(&resp);
            f9.writeAll(peer, &resp) catch return;
        }
    }
};

/// 端到端测试夹具：假设备 + 监听 socket + 服务线程。
/// 用法固定为 `var h: Harness = .{}; defer h.deinit(); try h.start();`：start 失败时
/// deinit 仍会按已初始化的部分收尾（不会留下 /tmp 里的 socket 或挂住的线程）。
/// 收尾顺序：停服务 → 关夹具持有的连接端 → 等在用连接收尾 → 释放设备副本
/// → 停设备线程 → 关监听与临时目录。
const Harness = struct {
    tmp: std.testing.TmpDir = undefined,
    tmp_ready: bool = false,
    sock_buf: [std.Io.Dir.max_path_bytes]u8 = undefined,
    sock: []const u8 = "",
    listener: ?std.Io.net.Server = null,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// 放大轮询周期以证明“停机靠自唤醒而不是靠 poll 超时”（见 serve 唤醒测试）。
    accept_poll_ms: i32 = default_accept_poll_ms,
    srv: Server = undefined,
    srv_ready: bool = false,
    srv_thread: ?std.Thread = null,
    dev_thread: ?std.Thread = null,
    peer: std.posix.fd_t = -1,
    peer_open: bool = false,
    client_fd: std.posix.fd_t = -1,

    fn start(self: *Harness) !void {
        const io = std.testing.io;
        // socket 放进测试临时目录：不再用固定的 /tmp 名字，也不会与并发测试撞名
        self.tmp = std.testing.tmpDir(.{});
        self.tmp_ready = true;
        var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = try self.tmp.dir.realPath(io, &dir_buf);
        self.sock = std.fmt.bufPrint(&self.sock_buf, "{s}/f9d.sock", .{dir_buf[0..n]}) catch return error.SkipZigTest;
        // unix socket 路径上限 107 字节（含结尾 0）：放不下就跳过，不截断
        if (self.sock.len >= 108) return error.SkipZigTest;

        var fds: [2]std.posix.fd_t = undefined;
        if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds) != 0) return error.SkipZigTest;
        self.client_fd = fds[0];
        self.peer = fds[1];
        self.peer_open = true;
        FakeDevice.reset(fds[0]);

        var addr = std.Io.net.UnixAddress.init(self.sock) catch return error.SkipZigTest;
        self.listener = try addr.listen(io, .{});
        self.srv = .{
            .io = io,
            .openers = FakeDevice.openers,
            .stop = &self.stop,
            .accept_poll_ms = self.accept_poll_ms,
        };
        self.srv_ready = true;
        self.dev_thread = try std.Thread.spawn(.{}, FakeDevice.serve, .{self.peer});
        const listener = if (self.listener) |*l| l else return error.TestUnexpectedResult;
        self.srv_thread = try std.Thread.spawn(.{}, ServeThread.run, .{ServeThread{ .srv = listener, .state = &self.srv }});
    }

    fn deinit(self: *Harness) void {
        const io = std.testing.io;
        initWakePipe() catch {}; // 唤醒管道不可用也不影响收尾（退化为轮询周期）
        self.stop.store(true, .release);
        wake();
        if (self.srv_thread) |t| t.join();
        self.srv_thread = null;
        // 设备句柄是 dup 出来的副本：先关夹具自己的连接端不会打断在用事务
        if (self.client_fd >= 0) {
            f9.closeFd(self.client_fd);
            self.client_fd = -1;
        }
        if (self.srv_ready and waitIdle(&self.srv, 3000)) self.srv.state.drop(io);
        FakeDevice.stop.store(true, .release);
        if (self.dev_thread) |t| t.join();
        self.dev_thread = null;
        if (self.peer_open) {
            f9.closeFd(self.peer);
            self.peer_open = false;
        }
        if (self.listener) |*l| {
            l.deinit(io);
            self.listener = null;
        }
        if (self.tmp_ready) {
            self.tmp.cleanup();
            self.tmp_ready = false;
        }
    }
};

/// serve 的线程入口（方法不能直接当线程函数传）。
const ServeThread = struct {
    srv: *std.Io.net.Server,
    state: *Server,
    fn run(self: ServeThread) void {
        self.state.serve(self.srv);
    }
};

test "端到端：socket → accept → dispatch → 设备事务（status/gear/gear set）" {
    const io = std.testing.io;
    const log_prev = silenceLog();
    defer _ = f9.setLogSink(log_prev);
    var h: Harness = .{};
    defer h.deinit();
    try h.start();

    const alloc = std.testing.allocator;
    const st = try ipc.callOnPath(io, alloc, h.sock, .{ .op = .status });
    defer st.deinit();
    try std.testing.expectEqual(@as(?u8, 0x02), st.value.flag);
    try std.testing.expectEqual(@as(?u16, 2045), st.value.rpm);
    try std.testing.expectEqual(@as(usize, 1), FakeDevice.requests.load(.acquire));

    const gear = try ipc.callOnPath(io, alloc, h.sock, .{ .op = .gear_get });
    defer gear.deinit();
    try std.testing.expectEqual(@as(?u8, 1), gear.value.gear);

    const set = try ipc.callOnPath(io, alloc, h.sock, .{ .op = .{ .gear_set = .turbo } });
    defer set.deinit();
    try std.testing.expectEqual(@as(?u8, 3), set.value.gear);
    // 精确帧数：status 1 + gear 1 + open/read/write/close/回读 5。少一帧说明
    // 回读确认或会话命令被跳过，>= 断言看不出来。
    try std.testing.expectEqual(@as(usize, 7), FakeDevice.requests.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), FakeDevice.opens.load(.acquire)); // 链路只打开一次

    // 强制 BLE：假 BLE 不可用，错误必须原样经 IPC 返回（不偷偷回落 USB）
    const forced = try ipc.callOnPath(io, alloc, h.sock, .{ .op = .status, .link = .ble });
    defer forced.deinit();
    try std.testing.expectEqualStrings("BluezUnavailable", forced.value.@"error".?);
    // 换链失败也不得用 USB 顶替：旧句柄已丢弃，没有发新帧
    try std.testing.expectEqual(@as(usize, 7), FakeDevice.requests.load(.acquire));
}

test "端到端：gear 回读不一致报 GearMismatch，下一个请求重新打开设备" {
    const io = std.testing.io;
    const log_prev = silenceLog();
    defer _ = f9.setLogSink(log_prev);
    FakeDevice.ignore_writes.store(true, .release); // 设备“收下写入但不生效”
    defer FakeDevice.ignore_writes.store(false, .release);

    var h: Harness = .{};
    defer h.deinit();
    try h.start();

    const alloc = std.testing.allocator;
    const failed = try ipc.callOnPath(io, alloc, h.sock, .{ .op = .{ .gear_set = .turbo } });
    defer failed.deinit();
    try std.testing.expectEqualStrings("GearMismatch", failed.value.@"error".?);
    try std.testing.expectEqual(@as(?u8, null), failed.value.gear); // 不把旧挡位当成功回包
    try std.testing.expectEqual(@as(usize, 1), FakeDevice.opens.load(.acquire));

    // 事务失败即丢弃句柄：下一个请求重新建链，而不是在坏句柄上再失败一次
    const again = try ipc.callOnPath(io, alloc, h.sock, .{ .op = .status });
    defer again.deinit();
    try std.testing.expectEqual(@as(?u16, 2045), again.value.rpm);
    try std.testing.expectEqual(@as(usize, 2), FakeDevice.opens.load(.acquire));
}

test "端到端：连接数达到上限时立即回 ServerBusy，不排队等空闲连接" {
    const io = std.testing.io;
    var h: Harness = .{};
    defer h.deinit();
    try h.start();

    // 占满上限：这些连接保持沉默（各占一个处理线程，不占设备锁）
    var idle: [max_connections]std.Io.net.Stream = undefined;
    var n: usize = 0;
    defer {
        for (idle[0..n]) |s| s.close(io);
    }
    for (&idle) |*s| {
        s.* = try connectUnix(io, h.sock);
        n += 1;
    }
    // accept 在服务线程里异步发生：等上限真的被占满再发下一个请求
    const deadline = monoMs() + 3000;
    while (h.srv.active.load(.acquire) < max_connections and monoMs() < deadline) {
        sleepMs(2);
    }
    try std.testing.expectEqual(max_connections, h.srv.active.load(.acquire));

    const start_ms = monoMs();
    const busy = try ipc.callOnPath(io, std.testing.allocator, h.sock, .{ .op = .status });
    defer busy.deinit();
    try std.testing.expectEqualStrings("ServerBusy", busy.value.@"error".?);
    // 立即拒绝：远小于空闲连接的 5s 读超时，也没有排队
    try std.testing.expect(monoMs() - start_ms < 1000);
    try std.testing.expectEqual(@as(usize, 0), FakeDevice.requests.load(.acquire));
}

test "端到端：尾随数据与超长请求行都被拒绝，空闲连接不阻塞其他客户端" {
    const io = std.testing.io;
    const log_prev = silenceLog();
    defer _ = f9.setLogSink(log_prev);
    var h: Harness = .{};
    defer h.deinit();
    try h.start();

    // 尾随数据：同一连接里换行后还有请求 → TrailingData，且不会被当成两个请求
    {
        const stream = try connectUnix(io, h.sock);
        defer stream.close(io);
        const fd = stream.socket.handle;
        try f9.writeAll(fd, "status\ngear\n");
        var buf: [ipc.max_reply_len]u8 = undefined;
        const line = try ipc.readLine(fd, &buf, 2000);
        try std.testing.expectEqualStrings("{\"error\":\"TrailingData\"}", line);
    }

    // 超长请求行：写满请求缓冲区仍无换行 → LineTooLong（不是静默截断成一条命令）
    {
        const stream = try connectUnix(io, h.sock);
        defer stream.close(io);
        const fd = stream.socket.handle;
        const long: [ipc.max_request_len + 8]u8 = @splat('s');
        try f9.writeAll(fd, &long);
        var buf: [ipc.max_reply_len]u8 = undefined;
        try std.testing.expectEqualStrings("{\"error\":\"LineTooLong\"}", try ipc.readLine(fd, &buf, 2000));
    }

    // 空闲连接占一个处理线程但不占设备锁：正常请求仍在短时间内完成
    const idle = try connectUnix(io, h.sock);
    defer idle.close(io);
    const start_ms = monoMs();
    const reply = try ipc.callOnPath(io, std.testing.allocator, h.sock, .{ .op = .status });
    defer reply.deinit();
    const elapsed = monoMs() - start_ms;
    try std.testing.expectEqual(@as(?u16, 2045), reply.value.rpm);
    // 远小于空闲连接的 5s 读超时：证明慢客户端没有占住设备锁/串行队列
    try std.testing.expect(elapsed < 4000);
}

test "调度：非法请求不打开设备，直接回 BadRequest" {
    const io = std.testing.io;
    LinkFakes.reset();
    var srv: Server = .{ .io = io, .openers = LinkFakes.openers };
    defer srv.state.drop(io);

    var buf: [ipc.max_reply_len]u8 = undefined;
    for ([_][]const u8{ "", "stats", "gear 4", "status  usb" }) |line| {
        try std.testing.expectEqualStrings("{\"error\":\"BadRequest\"}", srv.dispatch(line, &buf));
    }
    // 解析阶段就失败：没有任何链路建链尝试，设备错误也不会掩盖请求错误
    try std.testing.expectEqual(@as(usize, 0), LinkFakes.usb_calls);
    try std.testing.expectEqual(@as(usize, 0), LinkFakes.ble_calls);
    try std.testing.expect(srv.state.dev == null);
}
