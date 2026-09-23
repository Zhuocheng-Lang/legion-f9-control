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
