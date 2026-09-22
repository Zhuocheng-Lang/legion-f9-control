//! 设备级操作：把协议帧组合成完整的业务动作（状态读取 / 挡位读写）。
//! 只被 f9d 使用；f9ctl 一律经 IPC 间接触达设备。
const std = @import("std");
const protocol = @import("protocol.zig");
const usb = @import("usb.zig");

/// 读取实时状态（flag 与 RPM）。
pub fn status(dev: usb.Device) !protocol.LiveStatus {
    var req: [protocol.frame_len]u8 = undefined;
    try protocol.encodeRead(&req, .live_status, 0, 3);
    const resp = try dev.transact(&req, .live_status);
    return protocol.decodeStatus(resp.bytes());
}

/// 读取挡位。
pub fn gearGet(dev: usb.Device) !protocol.Gear {
    const block = try readSettings(dev);
    return protocol.decodeGear(&block);
}

/// 设置挡位：会话 open → 读-改-写设置块（不透明字节原样保留）→ 会话 close 提交。
pub fn gearSet(dev: usb.Device, gear: protocol.Gear) !void {
    try session(dev, true);
    errdefer session(dev, false) catch {};
    var block = try readSettings(dev);
    protocol.setGear(&block, gear);
    try writeSettings(dev, &block);
    try session(dev, false);
}

fn session(dev: usb.Device, open: bool) !void {
    var req: [protocol.frame_len]u8 = undefined;
    try protocol.encodeSession(&req, open);
    _ = try dev.transact(&req, if (open) .session_open else .session_close);
}

fn readSettings(dev: usb.Device) ![protocol.settings_len]u8 {
    var req: [protocol.frame_len]u8 = undefined;
    try protocol.encodeRead(&req, .settings_read, 0, protocol.settings_len);
    const resp = try dev.transact(&req, .settings_read);
    const data = resp.bytes();
    if (data.len < protocol.settings_len) return error.ShortData;
    var block: [protocol.settings_len]u8 = undefined;
    @memcpy(&block, data[0..protocol.settings_len]);
    return block;
}

fn writeSettings(dev: usb.Device, block: *const [protocol.settings_len]u8) !void {
    var req: [protocol.frame_len]u8 = undefined;
    try protocol.encodeWrite(&req, .settings_write, 0, block);
    _ = try dev.transact(&req, .settings_write);
}

test {
    std.testing.refAllDecls(@This());
}
