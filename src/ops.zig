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
/// dev 用 anytype 仅为了让测试注入 mock（usb.Device 以值语义满足同一调用形状）。
pub fn gearSet(dev: anytype, gear: protocol.Gear) !void {
    // open 失败也可能是“请求已送达、响应丢失”：设备侧会话其实已打开，
    // 必须 best-effort 补发 close，故清理从发出 open 起就覆盖。
    session(dev, true) catch |err| {
        session(dev, false) catch {};
        return err;
    };
    errdefer session(dev, false) catch {};
    var block = try readSettings(dev);
    protocol.setGear(&block, gear);
    try writeSettings(dev, &block);
    try session(dev, false);
}

fn session(dev: anytype, open: bool) !void {
    var req: [protocol.frame_len]u8 = undefined;
    try protocol.encodeSession(&req, open);
    _ = try dev.transact(&req, if (open) .session_open else .session_close);
}

fn readSettings(dev: anytype) ![protocol.settings_len]u8 {
    var req: [protocol.frame_len]u8 = undefined;
    try protocol.encodeRead(&req, .settings_read, 0, protocol.settings_len);
    const resp = try dev.transact(&req, .settings_read);
    const data = resp.bytes();
    if (data.len < protocol.settings_len) return error.ShortData;
    var block: [protocol.settings_len]u8 = undefined;
    @memcpy(&block, data[0..protocol.settings_len]);
    return block;
}

fn writeSettings(dev: anytype, block: *const [protocol.settings_len]u8) !void {
    var req: [protocol.frame_len]u8 = undefined;
    try protocol.encodeWrite(&req, .settings_write, 0, block);
    _ = try dev.transact(&req, .settings_write);
}

test {
    std.testing.refAllDecls(@This());
}

/// 记录 transact 调用序列的 mock；fail_at 命中时模拟“请求送达但响应丢失”。
/// settings_read 返回 read_block，settings_write 捕获请求帧数据区中的设置块，
/// 用于验证读-改-写只动挡位字节、其余原样保留。
const MockDev = struct {
    seq: [8]protocol.Command = undefined,
    n: usize = 0,
    fail_at: ?protocol.Command = null,
    read_block: [protocol.settings_len]u8 = [_]u8{0xA5} ** protocol.settings_len,
    written: ?[protocol.settings_len]u8 = null,

    pub fn transact(self: *MockDev, req: *const [protocol.frame_len]u8, expect: protocol.Command) !protocol.Decoded {
        self.seq[self.n] = expect;
        self.n += 1;
        if (self.fail_at == expect) return error.Timeout;
        if (expect == .settings_write) self.written = req[8..][0..protocol.settings_len].*; // 帧数据区
        var resp: protocol.Decoded = .{ .offset = 0, .buf = [_]u8{0} ** protocol.max_payload, .len = protocol.settings_len };
        if (expect == .settings_read) resp.buf[0..protocol.settings_len].* = self.read_block;
        return resp;
    }
};

test "gearSet：open 响应丢失时仍补发 session_close" {
    var mock: MockDev = .{ .fail_at = .session_open };
    try std.testing.expectError(error.Timeout, gearSet(&mock, .turbo));
    try std.testing.expectEqualSlices(protocol.Command, &.{ .session_open, .session_close }, mock.seq[0..mock.n]);
}

test "gearSet：中途失败经 errdefer 关闭会话" {
    var mock: MockDev = .{ .fail_at = .settings_write };
    try std.testing.expectError(error.Timeout, gearSet(&mock, .turbo));
    try std.testing.expectEqualSlices(
        protocol.Command,
        &.{ .session_open, .settings_read, .settings_write, .session_close },
        mock.seq[0..mock.n],
    );
}

test "gearSet：完整序列 open → read → write → close，写入帧为读-改-写结果" {
    var mock: MockDev = .{};
    try gearSet(&mock, .turbo);
    try std.testing.expectEqualSlices(
        protocol.Command,
        &.{ .session_open, .settings_read, .settings_write, .session_close },
        mock.seq[0..mock.n],
    );
    // 目标挡位已写入 byte[13]，其余不透明字节与读回块一致
    const written = mock.written.?;
    try std.testing.expectEqual(protocol.Gear.turbo, try protocol.decodeGear(&written));
    for (mock.read_block, 0..) |b, i| {
        if (i != 13) try std.testing.expectEqual(b, written[i]); // byte[13] = protocol 的挡位字节
    }
}
