//! hidraw USB 传输：按 VID:PID 发现设备，收发 64 字节帧。
const std = @import("std");
const protocol = @import("protocol.zig");

/// Lenovo Legion F9（有线）的 USB 标识。
const vid = 0x17ef;
const pid = 0xf00c;

const response_timeout_ms = 2000;
/// 同一设备会枚举出多个 hidraw 接口，只有协议接口会应答，探测超时取短。
const probe_timeout_ms = 300;

pub const Device = struct {
    file: std.fs.File,

    /// 找到 VID:PID 匹配且能应答协议探测的接口并打开（读写）。
    pub fn open() !Device {
        return openFrom("/sys/class/hidraw");
    }

    /// 与 open 分离出来仅为可测：hidraw 子系统缺失/为空都归一化为 DeviceNotFound。
    fn openFrom(sys_class_hidraw: []const u8) !Device {
        var dir = std.fs.openDirAbsolute(sys_class_hidraw, .{ .iterate = true }) catch |err| switch (err) {
            // 无 hidraw 子系统（未加载/容器）：与“没插设备”同等对待
            error.FileNotFound => return error.DeviceNotFound,
            else => |e| return e,
        };
        defer dir.close();

        var matched = false;
        var denied = false;
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (!try isTarget(dir, entry.name)) continue;
            matched = true;
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "/dev/{s}", .{entry.name});
            const file = std.fs.openFileAbsolute(path, .{ .mode = .read_write }) catch |err| {
                if (err == error.AccessDenied) denied = true;
                continue;
            };
            if (probe(file)) |dev| return dev else |_| file.close();
        }
        // 权限问题优先报告，比“无应答”更可操作
        if (denied) return error.AccessDenied;
        return if (matched) error.DeviceNotResponding else error.DeviceNotFound;
    }

    pub fn close(dev: *Device) void {
        dev.file.close();
    }

    /// 一次事务：写请求帧 → 等响应帧 → 解码校验。
    pub fn transact(dev: Device, req: *const [protocol.frame_len]u8, expect: protocol.Command) !protocol.Decoded {
        return exchange(dev.file, req, expect, response_timeout_ms);
    }
};

/// 探测接口是否说本协议：发一次 0x1a 读请求并等合法响应（无副作用）。
fn probe(file: std.fs.File) !Device {
    var req: [protocol.frame_len]u8 = undefined;
    try protocol.encodeRead(&req, .live_status, 0, 3);
    _ = try exchange(file, &req, .live_status, probe_timeout_ms);
    return .{ .file = file };
}

fn exchange(file: std.fs.File, req: *const [protocol.frame_len]u8, expect: protocol.Command, timeout_ms: i32) !protocol.Decoded {
    try file.writeAll(req);

    var fds = [_]std.posix.pollfd{.{
        .fd = file.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    if (try std.posix.poll(&fds, timeout_ms) == 0) return error.Timeout;

    var buf: [protocol.frame_len]u8 = undefined;
    const n = try file.read(&buf);
    return protocol.decodeResponse(buf[0..n], expect);
}

/// uevent 的 HID_ID=<总线>:<VID>:<PID>（十六进制）匹配目标设备。
fn isTarget(dir: std.fs.Dir, name: []const u8) !bool {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const uevent_path = try std.fmt.bufPrint(&path_buf, "{s}/device/uevent", .{name});
    const f = dir.openFile(uevent_path, .{}) catch return false;
    defer f.close();
    var content: [1024]u8 = undefined;
    const n = try f.read(&content);
    return matchVidPid(content[0..n]);
}

fn matchVidPid(uevent: []const u8) bool {
    var lines = std.mem.splitScalar(u8, uevent, '\n');
    while (lines.next()) |line| {
        const prefix = "HID_ID=";
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        var fields = std.mem.splitScalar(u8, line[prefix.len..], ':');
        _ = fields.next() orelse return false;
        const v = std.fmt.parseInt(u32, fields.next() orelse return false, 16) catch return false;
        const p = std.fmt.parseInt(u32, fields.next() orelse return false, 16) catch return false;
        return v == vid and p == pid;
    }
    return false;
}

test "缺少 hidraw 子系统时归一化为 DeviceNotFound" {
    try std.testing.expectError(error.DeviceNotFound, Device.openFrom("/nonexistent-path"));
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try tmp.dir.realpath(".", &buf);
    try std.testing.expectError(error.DeviceNotFound, Device.openFrom(dir)); // 空目录无接口
}

test "匹配 uevent 中的 HID_ID" {
    try std.testing.expect(matchVidPid("HID_NAME=LEGION_F9_Wired\nHID_ID=0003:000017EF:0000F00C\n"));
    try std.testing.expect(!matchVidPid("HID_ID=0003:00003434:00000860\n"));
    try std.testing.expect(!matchVidPid("HID_NAME=LEGION_F9_Wired\n"));
}
