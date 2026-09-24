//! USB 协议层：64 字节帧的编解码与数据解码。纯函数，无 I/O。
//!
//! 帧布局（固定 64 字节，report ID 4）：
//! ```text
//! [0]     = 0x04
//! [1:2]   = 校验和（第 3 字节起全部字节求和 & 0xffff，小端）
//! [3]     = 命令
//! [4]     = 数据长度
//! [5:6]   = 偏移（小端）
//! [7]     = 请求保留 0x00；响应状态
//! [8:64]  = 数据（56 字节）
//! ```
//! 响应状态：0x00 成功、0xfe 忙、0xff 错误。report ID 5 一律拒绝。

const std = @import("std");

pub const frame_len = 64;
pub const report_id: u8 = 0x04;
pub const max_payload = 56;

/// v1 用到的命令。
pub const Command = enum(u8) {
    session_open = 0x01,
    session_close = 0x02,
    settings_read = 0x05,
    settings_write = 0x06,
    live_status = 0x1a,
};

/// 设置块的公开长度：仅 byte[13] 有语义，其余字节不透明、读-改-写原样保留。
pub const settings_len = 15;
const gear_byte = 13;

/// 挡位。
pub const Gear = enum(u8) {
    quiet = 0,
    balanced = 1,
    beast = 2,
    turbo = 3,
};

/// 实时状态：flag 与转速（rpm = rpm_raw >> 2）。
pub const LiveStatus = struct {
    flag: u8,
    rpm_raw: u16,
    rpm: u16,
};

/// 解码后的响应：数据从帧内拷出，不依赖调用方缓冲区的生命周期。
pub const Decoded = struct {
    offset: u16,
    buf: [max_payload]u8,
    len: u8,

    pub fn bytes(d: *const Decoded) []const u8 {
        return d.buf[0..d.len];
    }
};

pub const EncodeError = error{PayloadTooLong};
pub const DecodeError = error{ BadLength, BadReportId, CommandMismatch, Busy, DeviceError, BadStatus };

/// 读请求：数据区清零，长度字段 = 希望读回的字节数。
pub fn encodeRead(buf: *[frame_len]u8, command: Command, offset: u16, len: u8) EncodeError!void {
    if (len > max_payload) return error.PayloadTooLong;
    encode(buf, command, offset, len, &[_]u8{});
}

/// 写请求：payload 放入数据区（右侧补 0），长度字段 = payload 字节数。
pub fn encodeWrite(buf: *[frame_len]u8, command: Command, offset: u16, payload: []const u8) EncodeError!void {
    if (payload.len > max_payload) return error.PayloadTooLong;
    encode(buf, command, offset, @intCast(payload.len), payload);
}

/// 会话请求：open / close 各随 1 字节标记（0x01 / 0x02）。
pub fn encodeSession(buf: *[frame_len]u8, open: bool) EncodeError!void {
    const marker = [1]u8{if (open) 0x01 else 0x02};
    return encodeWrite(buf, if (open) .session_open else .session_close, 0, &marker);
}

/// 解码响应帧。协议规定响应恒为 64 字节：不足 64 的截断帧一律 `BadLength`，
/// 即使其声明的数据长度在帧内自洽也不接受；随后检查 report ID、命令回显与状态，
/// 不解引用短包；校验和不参与判定（USB 链路层已有 CRC）。
pub fn decodeResponse(raw: []const u8, expect: Command) DecodeError!Decoded {
    if (raw.len != frame_len) return error.BadLength;
    if (raw[0] != report_id) return error.BadReportId;
    if (raw[3] != @intFromEnum(expect)) return error.CommandMismatch;
    const len = raw[4];
    if (len > max_payload) return error.BadLength;
    switch (raw[7]) {
        0x00 => {},
        0xfe => return error.Busy,
        0xff => return error.DeviceError,
        else => return error.BadStatus,
    }
    var out: Decoded = .{ .offset = 0, .buf = undefined, .len = len };
    out.offset = @as(u16, raw[5]) | (@as(u16, raw[6]) << 8);
    @memcpy(out.buf[0..len], raw[8..][0..len]);
    return out;
}

/// 状态数据至少 3 字节：flag、rpm_raw（小端）。尾部未建模，不解读。
pub fn decodeStatus(data: []const u8) error{ShortData}!LiveStatus {
    if (data.len < 3) return error.ShortData;
    const rpm_raw = @as(u16, data[1]) | (@as(u16, data[2]) << 8);
    return .{ .flag = data[0], .rpm_raw = rpm_raw, .rpm = rpm_raw >> 2 };
}

/// 读设置块 byte[13] 得挡位。
pub fn decodeGear(block: *const [settings_len]u8) error{InvalidGear}!Gear {
    return std.meta.intToEnum(Gear, block[gear_byte]) catch error.InvalidGear;
}

/// 只改 byte[13]，其余不透明字节原样保留（调用方负责读-改-写）。
pub fn setGear(block: *[settings_len]u8, gear: Gear) void {
    block[gear_byte] = @intFromEnum(gear);
}

fn encode(buf: *[frame_len]u8, command: Command, offset: u16, len: u8, payload: []const u8) void {
    @memset(buf, 0);
    buf[0] = report_id;
    buf[3] = @intFromEnum(command);
    buf[4] = len;
    std.mem.writeInt(u16, buf[5..7], offset, .little);
    @memcpy(buf[8..][0..payload.len], payload);
    std.mem.writeInt(u16, buf[1..3], checksum(buf), .little);
}

/// 校验和覆盖校验字段之后的全部字节。
fn checksum(buf: *const [frame_len]u8) u16 {
    var sum: u16 = 0;
    for (buf[3..frame_len]) |b| sum +%= b;
    return sum;
}

/// 构造响应帧（测试用）。
fn buildResponse(buf: *[frame_len]u8, command: Command, offset: u16, status: u8, data: []const u8) void {
    encode(buf, command, offset, @intCast(data.len), data);
    buf[7] = status;
}

test "USB 读请求向量（0x1a, offset 0, length 3）" {
    var buf: [frame_len]u8 = undefined;
    try encodeRead(&buf, .live_status, 0, 3);
    var want = [_]u8{0} ** frame_len;
    want[0] = 0x04;
    want[1] = 0x1d; // 0x1a + 0x03，小端
    want[2] = 0x00;
    want[3] = 0x1a;
    want[4] = 0x03;
    try std.testing.expectEqualSlices(u8, &want, &buf);
}

test "状态解码向量（flag=0x02, rpm_raw=0x1ff4 → rpm=2045）" {
    const st = try decodeStatus(&.{ 0x02, 0xf4, 0x1f });
    try std.testing.expectEqual(@as(u8, 0x02), st.flag);
    try std.testing.expectEqual(@as(u16, 0x1ff4), st.rpm_raw);
    try std.testing.expectEqual(@as(u16, 2045), st.rpm);
    try std.testing.expectError(error.ShortData, decodeStatus(&.{ 0x02, 0xf4 }));
}

test "响应解码：校验通过并拷出数据" {
    var buf: [frame_len]u8 = undefined;
    buildResponse(&buf, .live_status, 0x0102, 0x00, &.{ 1, 2, 3 });
    const d = try decodeResponse(&buf, .live_status);
    try std.testing.expectEqual(@as(u16, 0x0102), d.offset);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, d.bytes());
}

test "响应解码：拒绝短包、report ID 5、回显不符与异常状态" {
    var buf: [frame_len]u8 = undefined;
    buildResponse(&buf, .live_status, 0, 0x00, &.{ 0, 0, 0 });

    try std.testing.expectError(error.BadLength, decodeResponse(buf[0..7], .live_status));
    try std.testing.expectError(error.BadLength, decodeResponse(buf[0..10], .live_status));

    // 截断帧：声明长度自洽也不接受（协议规定响应定长 64 字节）
    try std.testing.expectError(error.BadLength, decodeResponse(buf[0..63], .live_status));

    buf[4] = 200; // 长度字段越界
    try std.testing.expectError(error.BadLength, decodeResponse(&buf, .live_status));
    buf[4] = 3;

    buf[0] = 0x05; // report ID 5 一律拒绝
    try std.testing.expectError(error.BadReportId, decodeResponse(&buf, .live_status));
    buf[0] = report_id;

    try std.testing.expectError(error.CommandMismatch, decodeResponse(&buf, .settings_read));

    buf[7] = 0xfe;
    try std.testing.expectError(error.Busy, decodeResponse(&buf, .live_status));
    buf[7] = 0xff;
    try std.testing.expectError(error.DeviceError, decodeResponse(&buf, .live_status));
    buf[7] = 0x42;
    try std.testing.expectError(error.BadStatus, decodeResponse(&buf, .live_status));
}

test "挡位解码：byte[13] 取值 0-3，越界报错" {
    const gears = [_]Gear{ .quiet, .balanced, .beast, .turbo };
    var block = [_]u8{0} ** settings_len;
    for (gears, 0..) |want, i| {
        block[gear_byte] = @intCast(i);
        try std.testing.expectEqual(want, try decodeGear(&block));
    }
    block[gear_byte] = 4;
    try std.testing.expectError(error.InvalidGear, decodeGear(&block));
}

test "setGear 只改 byte[13]，其余不透明字节原样保留" {
    var block = [_]u8{0xAA} ** settings_len;
    setGear(&block, .turbo);
    try std.testing.expectEqual(@as(u8, 3), block[gear_byte]);
    for (0..settings_len) |i| {
        if (i == gear_byte) continue;
        try std.testing.expectEqual(@as(u8, 0xAA), block[i]);
    }
}

test "会话帧：1 字节标记（0x01 开 / 0x02 提交）" {
    var buf: [frame_len]u8 = undefined;
    try encodeSession(&buf, true);
    try std.testing.expectEqual(@as(u8, 0x01), buf[3]);
    try std.testing.expectEqual(@as(u8, 0x01), buf[4]);
    try std.testing.expectEqual(@as(u8, 0x01), buf[8]);
    try encodeSession(&buf, false);
    try std.testing.expectEqual(@as(u8, 0x02), buf[3]);
    try std.testing.expectEqual(@as(u8, 0x02), buf[8]);
}

test "写请求帧：0x06 设置块 15 字节；载荷超长报错" {
    const block = [_]u8{0xAB} ** settings_len;
    var buf: [frame_len]u8 = undefined;
    try encodeWrite(&buf, .settings_write, 0, &block);
    try std.testing.expectEqual(@as(u8, 0x06), buf[3]);
    try std.testing.expectEqual(@as(u8, settings_len), buf[4]);
    try std.testing.expectEqualSlices(u8, &block, buf[8..][0..settings_len]);

    const big = [_]u8{0} ** 57;
    try std.testing.expectError(error.PayloadTooLong, encodeWrite(&buf, .settings_write, 0, &big));
}
