//! legion-f9-control 共享库 `f9`：f9ctl 与 f9d 共用的唯一模块。
//!
//! - `protocol`：USB 帧编解码与数据解码（纯函数）
//! - `usb`：hidraw 设备发现与收发
//! - `ops`：设备级业务操作（仅 f9d 使用）
//! - `ipc`：f9ctl ↔ f9d 的 Unix socket 协议与客户端

const std = @import("std");

pub const protocol = @import("protocol.zig");
pub const usb = @import("usb.zig");
pub const ops = @import("ops.zig");
pub const ipc = @import("ipc.zig");

pub const product_name = "legion-f9-control";

test {
    std.testing.refAllDecls(@This());
    _ = @import("protocol.zig");
    _ = @import("usb.zig");
    _ = @import("ops.zig");
    _ = @import("ipc.zig");
}

test "库根可编译、可被测试" {
    try std.testing.expectEqualStrings("legion-f9-control", product_name);
}
