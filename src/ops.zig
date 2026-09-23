//! 设备级操作：把设备语义操作组合成完整的业务动作（状态读取 / 挡位读写）。
//! 只被 f9d 使用；f9ctl 一律经 IPC 间接触达设备。
//!
//! 只依赖三个链路无关的语义操作，具体帧与事务由 USB/BLE 各自实现：
//! - `read(command, offset, len)`（返回带 `bytes()` 的响应数据）
//! - `write(command, offset, payload)`
//! - `session(open)`
//! 这里用 anytype 而非接口：usb.Device / ble.Device / daemon 的链路 union 以同一
//! 调用形状满足它，测试可注入 fake。
const std = @import("std");
const protocol = @import("protocol.zig");

/// 读取实时状态（flag 与 RPM）。
pub fn status(dev: anytype) !protocol.LiveStatus {
    const resp = try dev.read(.live_status, 0, 3);
    return protocol.decodeStatus(resp.bytes());
}

/// 读取挡位。
pub fn gearGet(dev: anytype) !protocol.Gear {
    const block = try readSettings(dev);
    return protocol.decodeGear(&block);
}

/// 设置挡位：会话 open → 读-改-写设置块（不透明字节原样保留）→ 会话 close 提交。
/// 失败不重放写入：open 一旦发出，失败路径也 best-effort 补 close（设备侧会话
/// 可能已开），但绝不重发写命令、也不在同一请求里换链路。
/// 每条失败路径至多补发一次 close：最终 close（提交）自身的失败不再补发。
pub fn gearSet(dev: anytype, gear: protocol.Gear) !void {
    // open 失败也可能是“请求已送达、响应丢失”：设备侧会话其实已打开，
    // 必须 best-effort 补发 close，故清理从发出 open 起就覆盖。
    dev.session(true) catch |err| {
        dev.session(false) catch {};
        return err;
    };
    {
        // errdefer 只覆盖读/写阶段，失败补一次 close；最终 close 在块外执行，
        // 失败不再补发第二次（已失败的链路上再等一个事务超时没有意义，
        // 设备侧会话由下次 open 收敛）。行为由 session_close 失败测试钉住。
        errdefer dev.session(false) catch {};
        var block = try readSettings(dev);
        protocol.setGear(&block, gear);
        try dev.write(.settings_write, 0, &block);
    }
    // close 是提交：失败不得当成功，也不再补发（见上）
    try dev.session(false);
}

fn readSettings(dev: anytype) ![protocol.settings_len]u8 {
    const resp = try dev.read(.settings_read, 0, protocol.settings_len);
    const data = resp.bytes();
    if (data.len < protocol.settings_len) return error.ShortData;
    var block: [protocol.settings_len]u8 = undefined;
    @memcpy(&block, data[0..protocol.settings_len]);
    return block;
}

test {
    std.testing.refAllDecls(@This());
}

const Op = enum { session_open, session_close, read, write };

/// 记录调用序列的设备 fake；fail_at 命中时模拟“请求送达但响应丢失”。
/// settings_read 返回 read_block，settings_write 捕获 payload，
/// 用于验证读-改-写只动挡位字节、其余原样保留，以及写失败不重放。
const MockDev = struct {
    seq: [8]Op = undefined,
    n: usize = 0,
    fail_at: ?Op = null,
    read_block: [protocol.settings_len]u8 = [_]u8{0xA5} ** protocol.settings_len,
    status_data: [3]u8 = .{ 0x02, 0xf4, 0x1f },
    reads: [4]struct { command: protocol.Command, offset: u16, len: u8 } = undefined,
    n_reads: usize = 0,
    writes: usize = 0,
    written: ?[protocol.settings_len]u8 = null,

    fn rec(self: *MockDev, op: Op) void {
        self.seq[self.n] = op;
        self.n += 1;
    }

    pub fn read(self: *MockDev, command: protocol.Command, offset: u16, len: u8) !protocol.Decoded {
        self.rec(.read);
        self.reads[self.n_reads] = .{ .command = command, .offset = offset, .len = len };
        self.n_reads += 1;
        if (self.fail_at == .read) return error.Timeout;
        var resp: protocol.Decoded = .{ .offset = offset, .buf = undefined, .len = 0 };
        switch (command) {
            .settings_read => {
                resp.buf[0..protocol.settings_len].* = self.read_block;
                resp.len = protocol.settings_len;
            },
            .live_status => {
                resp.buf[0..3].* = self.status_data;
                resp.len = 3;
            },
            else => return error.CommandMismatch,
        }
        return resp;
    }

    pub fn write(self: *MockDev, command: protocol.Command, offset: u16, payload: []const u8) !void {
        _ = offset;
        if (command != .settings_write) return error.CommandMismatch;
        self.rec(.write);
        // 计数在失败判定之前：用于断言“失败后不重放写入”
        self.writes += 1;
        self.written = payload[0..protocol.settings_len].*;
        if (self.fail_at == .write) return error.Timeout;
    }

    pub fn session(self: *MockDev, open: bool) !void {
        const op: Op = if (open) .session_open else .session_close;
        self.rec(op);
        if (self.fail_at == op) return error.Timeout;
    }
};

test "status：读 0x1a offset 0 长度 3，解码 rpm" {
    var mock: MockDev = .{};
    const st = try status(&mock);
    try std.testing.expectEqual(protocol.Command.live_status, mock.reads[0].command);
    try std.testing.expectEqual(@as(u16, 0), mock.reads[0].offset);
    try std.testing.expectEqual(@as(u8, 3), mock.reads[0].len);
    try std.testing.expectEqual(@as(u16, 2045), st.rpm);
    try std.testing.expectEqual(@as(u8, 0x02), st.flag);
}

test "gearGet：读 0x05 offset 0 长度 15 的 byte[13]" {
    var mock: MockDev = .{};
    mock.read_block[13] = 2;
    try std.testing.expectEqual(protocol.Gear.beast, try gearGet(&mock));
    try std.testing.expectEqual(protocol.Command.settings_read, mock.reads[0].command);
    try std.testing.expectEqual(@as(u8, protocol.settings_len), mock.reads[0].len);
}

test "gearSet：open 响应丢失时仍补发 session_close" {
    var mock: MockDev = .{ .fail_at = .session_open };
    try std.testing.expectError(error.Timeout, gearSet(&mock, .turbo));
    try std.testing.expectEqualSlices(Op, &.{ .session_open, .session_close }, mock.seq[0..mock.n]);
    try std.testing.expectEqual(@as(usize, 0), mock.writes); // 未写入
}

test "gearSet：中途失败经 errdefer 关闭会话，且不重放写入" {
    var mock: MockDev = .{ .fail_at = .write };
    try std.testing.expectError(error.Timeout, gearSet(&mock, .turbo));
    try std.testing.expectEqualSlices(
        Op,
        &.{ .session_open, .read, .write, .session_close },
        mock.seq[0..mock.n],
    );
    try std.testing.expectEqual(@as(usize, 1), mock.writes); // 只写过一次，没有重放
}

test "gearSet：close（提交）失败时不补发第二次 close，错误原样上报" {
    var mock: MockDev = .{ .fail_at = .session_close };
    try std.testing.expectError(error.Timeout, gearSet(&mock, .turbo));
    try std.testing.expectEqualSlices(
        Op,
        &.{ .session_open, .read, .write, .session_close },
        mock.seq[0..mock.n],
    );
    try std.testing.expectEqual(@as(usize, 1), mock.writes); // 已写入：close 失败不回滚也不重放
}

test "gearSet：完整序列 open → read → write → close，写入帧为读-改-写结果" {
    var mock: MockDev = .{};
    try gearSet(&mock, .turbo);
    try std.testing.expectEqualSlices(
        Op,
        &.{ .session_open, .read, .write, .session_close },
        mock.seq[0..mock.n],
    );
    try std.testing.expectEqual(protocol.Command.settings_read, mock.reads[0].command);
    try std.testing.expectEqual(@as(u8, protocol.settings_len), mock.reads[0].len);
    // 目标挡位已写入 byte[13]，其余不透明字节与读回块一致
    const written = mock.written.?;
    try std.testing.expectEqual(protocol.Gear.turbo, try protocol.decodeGear(&written));
    for (mock.read_block, 0..) |b, i| {
        if (i != 13) try std.testing.expectEqual(b, written[i]); // byte[13] = protocol 的挡位字节
    }
}
