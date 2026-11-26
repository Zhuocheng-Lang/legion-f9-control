//! legion-f9-control 共享库 `f9`：f9ctl 与 f9d 共用的唯一模块。
//!
//! - `protocol`：设备协议的数据解码与 USB 帧编解码（纯函数）
//! - `usb`：hidraw 设备发现与收发
//! - `ble`：BLE 帧编解码与 BlueZ D-Bus 事务
//! - `ops`：设备级业务操作（仅 f9d 使用）
//! - `ipc`：f9ctl ↔ f9d 的 Unix socket 协议与客户端
//!
//! 底层原语：Zig 0.16 起删除了 `std.posix` 的中层包装（`clock_gettime` / `write` /
//! `close` / `pipe` 等），官方给出的两条路是“向上用 `std.Io`”或“向下直接用
//! `std.posix.system`”。本项目的期限、RST 防护与 errno 归类都建立在固定 fd 的
//! 精确语义上，且仅在 Linux 运行，因此这些原语留在本文件里以最小包装呈现，
//! 不引入 `Io` 实例参数。

const std = @import("std");

/// 单调时钟毫秒（期限不受墙钟调整影响）。ble.zig 与 ipc.zig 共用，保证
/// D-Bus 事务与 IPC 读行的期限语义一致（墙钟回拨不放大剩余时间、不破坏上限）。
pub fn monoMs() i64 {
    var ts: std.posix.timespec = undefined;
    // 读时钟失败在生产路径上不可恢复；返回 0 只会让期限“立刻到期”，
    // 比编造一个未来时间更安全（错误会以 Timeout 上报，而不是无限等待）。
    if (std.posix.errno(std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts)) != .SUCCESS) return 0;
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), std.time.ns_per_ms);
}

/// 毫秒级睡眠，只用于轮询间隔。
/// `std.Thread.sleep` 在 Zig 0.16 随同步原语一并移除；被信号打断时提前返回，
/// 调用方的循环会重新 poll，语义与旧实现一致（最坏多跑一轮探测）。
pub fn sleepMs(ms: i64) void {
    const ts: std.posix.timespec = .{
        .sec = @intCast(@divTrunc(ms, std.time.ms_per_s)),
        .nsec = @intCast(@mod(ms, std.time.ms_per_s) * std.time.ns_per_ms),
    };
    _ = std.posix.system.nanosleep(&ts, null);
}

/// 关闭 fd（`std.posix.close` 已随中层包装移除）。失败无补救手段，静默忽略：
/// 调用方都是“放弃这个句柄”的路径，errno 不改变后续决策。
pub fn closeFd(fd: std.posix.fd_t) void {
    _ = std.posix.system.close(fd);
}

/// 创建匿名管道（`std.posix.pipe` 已移除，底层只剩 pipe2）。仅测试与自唤醒管道用。
pub const PipeError = error{Unexpected};

pub fn pipeFds() PipeError![2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    switch (std.posix.errno(std.posix.system.pipe2(&fds, .{}))) {
        .SUCCESS => return fds,
        else => return error.Unexpected,
    }
}

/// 写满一段字节（Zig 0.16 起 `std.fs.File.writeAll` 需要 Io.File 实例；
/// 这里只有裸 fd）。错误按 errno 归成调用方可判断的名字：`EAGAIN` 归为
/// `WouldBlock`，正是 socket 设了 `SO_SNDTIMEO` 后写期限到期的结果。
pub fn writeAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = std.posix.system.write(fd, bytes.ptr + off, bytes.len - off);
        switch (std.posix.errno(rc)) {
            .SUCCESS => off += @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .PIPE => return error.BrokenPipe,
            .CONNRESET => return error.ConnectionResetByPeer,
            else => |e| return std.posix.unexpectedErrno(e),
        }
    }
}

/// 读一次 fd（EINTR 重试）。0 = EOF。阻塞模式下 WouldBlock 不应出现，
/// 但 pipe 与设了 O_NONBLOCK 的场景要能区分出来。
pub fn readSome(fd: std.posix.fd_t, buf: []u8) !usize {
    while (true) {
        const rc = std.posix.system.read(fd, buf.ptr, buf.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .CONNRESET => return error.ConnectionResetByPeer,
            else => |e| return std.posix.unexpectedErrno(e),
        }
    }
}

/// 诊断日志的落点：生产为 null（直接写 stderr），测试可改写到 sink。
/// 可替换才有两件事：`zig build test` 不再被“设备已连接”等日志刷屏；
/// 以及能断言“日志里不出现设备地址/对象路径”（隐私约束不能只靠肉眼）。
pub var log_sink: ?*const fn ([]const u8) void = null;

/// 诊断日志统一走 stderr（stdout 只留结果）。f9d 与 ble 链路共用一份。
pub fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    if (log_sink) |sink| {
        sink(line);
        return;
    }
    // 直接用 fd 2 的原语：日志点遍布无 Io 上下文的纯逻辑与信号路径，
    // 把 Io 参数一路传下去只会污染接口，而 stderr 的写入语义并不需要它。
    _ = std.posix.system.write(std.posix.STDERR_FILENO, line.ptr, line.len);
}

/// 替换日志落点，返回旧值供 defer 恢复。只给测试用。
pub fn setLogSink(sink: ?*const fn ([]const u8) void) ?*const fn ([]const u8) void {
    const old = log_sink;
    log_sink = sink;
    return old;
}

/// 丢弃日志的 sink（测试静音用）。
pub fn discardLog(_: []const u8) void {}

test "log：sink 可替换，内容与格式保持不变" {
    const Capture = struct {
        var buf: [256]u8 = undefined;
        var len: usize = 0;
        fn sink(line: []const u8) void {
            @memcpy(buf[0..line.len], line);
            len = line.len;
        }
    };
    const old = setLogSink(Capture.sink);
    defer _ = setLogSink(old);

    log("f9d: 设备已连接（{s}）", .{"usb"});
    try std.testing.expectEqualStrings("f9d: 设备已连接（usb）\n", Capture.buf[0..Capture.len]);
}

test "writeAll：非阻塞写满后 EAGAIN 归为 WouldBlock" {
    // 管道写满 + O_NONBLOCK：与 socket 设了 SO_SNDTIMEO 到期同一类结果，
    // 是 daemon 关连接路径唯一可能出现 EAGAIN 的地方。
    var fds: [2]std.posix.fd_t = undefined;
    if (std.posix.errno(std.posix.system.pipe2(&fds, .{ .NONBLOCK = true })) != .SUCCESS) return error.SkipZigTest;
    defer closeFd(fds[0]);
    defer closeFd(fds[1]);

    var chunk: [4096]u8 = @splat(0);
    var rounds: usize = 0;
    while (true) : (rounds += 1) {
        if (rounds > 1024) return error.TestUnexpectedResult; // 非阻塞写必然 EAGAIN，走到这里说明映射错了
        writeAll(fds[1], &chunk) catch |err| {
            try std.testing.expectEqual(error.WouldBlock, err);
            return;
        };
    }
}

test "monoMs：单调推进，且不小于一秒前的值" {
    const a = monoMs();
    sleepMs(5);
    const b = monoMs();
    try std.testing.expect(b >= a);
    try std.testing.expect(b - a >= 4);
}

pub const protocol = @import("protocol.zig");
pub const usb = @import("usb.zig");
pub const ble = @import("ble.zig");
pub const ops = @import("ops.zig");
pub const ipc = @import("ipc.zig");

pub const product_name = "legion-f9-control";

test {
    std.testing.refAllDecls(@This());
    _ = @import("protocol.zig");
    _ = @import("usb.zig");
    _ = @import("ble.zig");
    _ = @import("ops.zig");
    _ = @import("ipc.zig");
}

test "库根可编译、可被测试" {
    try std.testing.expectEqualStrings("legion-f9-control", product_name);
}
