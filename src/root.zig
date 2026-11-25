//! legion-f9-control 共享库 `f9`：f9ctl 与 f9d 共用的唯一模块。
//!
//! - `protocol`：设备协议的数据解码与 USB 帧编解码（纯函数）
//! - `usb`：hidraw 设备发现与收发
//! - `ble`：BLE 帧编解码与 BlueZ D-Bus 事务
//! - `ops`：设备级业务操作（仅 f9d 使用）
//! - `ipc`：f9ctl ↔ f9d 的 Unix socket 协议与客户端

const std = @import("std");

/// 单调时钟毫秒（期限不受墙钟调整影响）。ble.zig 与 ipc.zig 共用，保证
/// D-Bus 事务与 IPC 读行的期限语义一致（墙钟回拨不放大剩余时间、不破坏上限）。
pub fn monoMs() i64 {
    const ts = std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC) catch return 0;
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), std.time.ns_per_ms);
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
    std.fs.File.stderr().writeAll(line) catch {};
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
