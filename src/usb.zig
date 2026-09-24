//! hidraw USB 传输：按 VID:PID 发现设备，收发 64 字节帧。
//! 同一 hidraw 节点还承载键盘/鼠标等其他 HID 报告与设备主动推送的短通知，
//! 事务层负责丢弃它们（见 `exchange`）。
const std = @import("std");
const protocol = @import("protocol.zig");
const monoMs = @import("root.zig").monoMs;
const log = @import("root.zig").log;

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
        var env_err: ?anyerror = null;
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
            const dev = probe(file) catch |err| {
                file.close();
                // 接口层面的“无应答 / 不是本协议”只说明这个接口不对，试下一个；
                // 权限、I/O 等环境错误先记下（不中断枚举，免得错过后面的真接口），
                // 没有可用接口时再原样上报——吞掉它们会让 f9d 误判为设备缺失而回落 BLE。
                if (probeSkippable(err)) continue;
                if (env_err == null) env_err = err;
                continue;
            };
            return dev;
        }
        // 权限问题优先报告，比“无应答”更可操作；其次探测中撞上的环境错误
        if (denied) return error.AccessDenied;
        if (env_err) |err| return err;
        return if (matched) error.DeviceNotResponding else error.DeviceNotFound;
    }

    pub fn close(dev: *Device) void {
        dev.file.close();
    }

    /// 一次事务：写请求帧 → 等本次响应帧 → 解码校验。
    pub fn transact(dev: Device, req: *const [protocol.frame_len]u8, expect: protocol.Command) !protocol.Decoded {
        var g = HidFrames{ .file = dev.file };
        return exchange(&g, req, expect, monoMs() + response_timeout_ms);
    }

    /// 读命令：与 BLE 链路同形语义，帧与事务由本层实现。
    pub fn read(dev: Device, command: protocol.Command, offset: u16, len: u8) !protocol.Decoded {
        var req: [protocol.frame_len]u8 = undefined;
        try protocol.encodeRead(&req, command, offset, len);
        return dev.transact(&req, command);
    }

    /// 写命令。
    pub fn write(dev: Device, command: protocol.Command, offset: u16, payload: []const u8) !void {
        var req: [protocol.frame_len]u8 = undefined;
        try protocol.encodeWrite(&req, command, offset, payload);
        _ = try dev.transact(&req, command);
    }

    /// 会话命令（USB 上同样要等响应帧，与 BLE 的 fire-and-forget 不同）。
    pub fn session(dev: Device, is_open: bool) !void {
        var req: [protocol.frame_len]u8 = undefined;
        try protocol.encodeSession(&req, is_open);
        _ = try dev.transact(&req, if (is_open) .session_open else .session_close);
    }
};

/// hidraw 帧源：一个事务内复用同一个缓冲区。等下一帧的期限语义归调用方
/// （`exchange`），这里只负责 poll + 读；测试用 fake 提供同一调用形状。
const HidFrames = struct {
    file: std.fs.File,
    buf: [protocol.frame_len]u8 = undefined,

    fn writeFrame(self: *HidFrames, req: *const [protocol.frame_len]u8) !void {
        try rawWriteAll(self.file, req);
    }

    /// 等下一帧；期限用尽报 Timeout。
    fn nextFrame(self: *HidFrames, timeout_ms: i32) ![]const u8 {
        var fds = [_]std.posix.pollfd{.{
            .fd = self.file.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        if (try std.posix.poll(&fds, timeout_ms) == 0) return error.Timeout;
        const n = try rawRead(self.file, &self.buf);
        // poll 可读但读到 0 字节 = 设备已拔（EOF）：归一为 NoDevice，
        // 否则 0 字节会被 decodeResponse 报成误导性的 BadLength“响应帧长度异常”
        if (n == 0) return error.NoDevice;
        return self.buf[0..n];
    }
};

/// 拔线相关 errno 的分类。
///
/// 不经 `std.fs.File.write/read`：它们对未建模的 errno 走 `unexpectedErrno`，会往
/// stderr 打整段堆栈，并且只给 `error.Unexpected`（f9ctl 显示“未预期的系统错误”）。
/// 真机实测（2026-09-24）：拔线中途写 hidraw 返回 `EPROTO`；`ENODEV`/`ENXIO`/
/// `ESHUTDOWN` 也是同一类“设备已不可用”。归为 `NoDevice` 才能给出可诊断文案，
/// 也才能在探测阶段被跳过、进而允许回落 BLE（`DeviceNotFound`）。
fn errnoError(e: std.posix.E) anyerror {
    switch (e) {
        .NODEV, .NXIO, .PROTO, .SHUTDOWN => return error.NoDevice,
        .IO => return error.InputOutput,
        .NOENT => return error.FileNotFound,
        .ACCES, .PERM => return error.AccessDenied,
        .NOSPC => return error.NoSpaceLeft,
        .BUSY => return error.DeviceBusy,
        .AGAIN => return error.WouldBlock,
        else => {
            log("f9d: hidraw 读写失败: 未建模的 errno {d}", .{@intFromEnum(e)});
            return error.Unexpected;
        },
    }
}

/// raw 写满一帧（EINTR 重试）。hidraw 一次写就是一帧，正常不会短写。
fn rawWriteAll(file: std.fs.File, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = std.posix.system.write(file.handle, bytes.ptr + off, bytes.len - off);
        switch (std.posix.errno(rc)) {
            .SUCCESS => off += @intCast(rc),
            .INTR => continue,
            else => |e| return errnoError(e),
        }
    }
}

/// raw 读一次（EINTR 重试）；一帧一次读，不拼接。0 = EOF（设备已拔）。
fn rawRead(file: std.fs.File, buf: []u8) !usize {
    while (true) {
        const rc = std.posix.system.read(file.handle, buf.ptr, buf.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => |e| return errnoError(e),
        }
    }
}

/// 探测接口是否说本协议：发一次 0x1a 读请求并等合法响应（无副作用）。
fn probe(file: std.fs.File) !Device {
    var req: [protocol.frame_len]u8 = undefined;
    try protocol.encodeRead(&req, .live_status, 0, 3);
    var g = HidFrames{ .file = file };
    _ = try exchange(&g, &req, .live_status, monoMs() + probe_timeout_ms);
    return .{ .file = file };
}

/// 一次事务：写请求帧 → 等到本次响应帧。
///
/// 响应恒为 report ID 4 的 64 字节帧，但同一 hidraw 节点还承载其他报告流
/// （键盘/鼠标/消费者）与设备主动推送的短通知（真机实测：挡位写入后约 50ms 出现
/// 3 字节 report 3 通知），旧响应也可能残留在队列里。这些“不是本次响应”的帧
/// 一律丢弃后继续等，直到单调时钟期限用尽（与 BLE 事务丢弃旧通知的判定一致）。
fn exchange(g: anytype, req: *const [protocol.frame_len]u8, expect: protocol.Command, deadline_ms: i64) !protocol.Decoded {
    try g.writeFrame(req);
    while (true) {
        const remaining = deadline_ms - monoMs();
        if (remaining <= 0) return error.Timeout;
        const raw = try g.nextFrame(@intCast(@min(remaining, std.math.maxInt(i32))));
        return protocol.decodeResponse(raw, expect) catch |err| switch (err) {
            // 没有 report ID 4、长度不是 64、命令不是本次请求：都不是本次响应
            // （异物报告 / 短通知 / 截断帧 / 旧响应），丢弃继续等
            error.BadReportId, error.BadLength, error.CommandMismatch => continue,
            // 设备确实用本次命令回了话：忙/错误/未知状态是真实结论，不得吞掉
            else => |e| return e,
        };
    }
}

/// 探测失败分类：只有“接口不应答”（Timeout）或“设备已拔”（NoDevice）才继续试下一个
/// 接口。
/// 事务层已丢弃异物报告，剩下能冒出来的帧都是 report ID 4 + 命令回显本次请求的——既然
/// 设备用本次命令回了话，就已经证明它是协议接口（Busy/DeviceError/未知状态 是设备
/// 的真实结论，不是“接口不对”）；权限、I/O 等环境错误同理。它们必须上报：f9d 仅对
/// `DeviceNotFound` / `DeviceNotResponding` 回落 BLE，吞掉它们会把“没权限 / I/O 失败 /
/// 设备报错”误报成“设备不在”。
fn probeSkippable(err: anyerror) bool {
    return switch (err) {
        error.Timeout, error.NoDevice => true,
        else => false,
    };
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

test "探测失败分类：仅无应答/设备已拔可跳过，设备报错与权限/IO 错误必须上报" {
    try std.testing.expect(probeSkippable(error.Timeout));
    try std.testing.expect(probeSkippable(error.NoDevice));
    try std.testing.expect(!probeSkippable(error.Busy));
    try std.testing.expect(!probeSkippable(error.DeviceError));
    try std.testing.expect(!probeSkippable(error.BadStatus));
    try std.testing.expect(!probeSkippable(error.AccessDenied));
    try std.testing.expect(!probeSkippable(error.InputOutput));
    try std.testing.expect(!probeSkippable(error.FileNotFound));
}

/// 在 tmpdir 里造一个假 hidraw 条目；条目名决定设备节点路径（/dev/{name}）。
/// 名字 `null` / `full` 分别映射到 /dev/null、/dev/full，用真实内核行为模拟
/// “无应答（EOF）”与“写入 I/O 错误”，无需 root、也无需真机。
fn makeFakeInterface(tmp: std.testing.TmpDir, name: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try tmp.dir.makePath(try std.fmt.bufPrint(&buf, "{s}/device", .{name}));
    const uevent = try tmp.dir.createFile(try std.fmt.bufPrint(&buf, "{s}/device/uevent", .{name}), .{});
    defer uevent.close();
    try uevent.writeAll("HID_ID=0003:000017EF:0000F00C\n");
}

test "枚举：候选接口无应答（EOF）仍归为 DeviceNotResponding（回落 BLE 的合法触发）" {
    std.fs.accessAbsolute("/dev/null", .{}) catch return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFakeInterface(tmp, "null");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectError(error.DeviceNotResponding, Device.openFrom(try tmp.dir.realpath(".", &buf)));
}

test "枚举：probe 的 I/O 错误原样上报，不被“无应答接口”吞掉" {
    // /dev/full 写入必 ENOSPC（环境错误）；同时放一个无应答接口（/dev/null，读 EOF），
    // 无论扫描顺序如何都必须报出 I/O 错误。
    // 修复前：所有 probe 错误被丢弃 → DeviceNotResponding → f9d 错误回落 BLE。
    std.fs.accessAbsolute("/dev/full", .{}) catch return error.SkipZigTest;
    std.fs.accessAbsolute("/dev/null", .{}) catch return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFakeInterface(tmp, "null");
    try makeFakeInterface(tmp, "full");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, Device.openFrom(try tmp.dir.realpath(".", &buf)));
}

test "errno 翻译：拔线相关错误码归为 NoDevice（可诊断、探测可跳过），其余按语义分类" {
    try std.testing.expectEqual(@as(anyerror, error.NoDevice), errnoError(.PROTO)); // 真机拔线实测
    try std.testing.expectEqual(@as(anyerror, error.NoDevice), errnoError(.NODEV));
    try std.testing.expectEqual(@as(anyerror, error.NoDevice), errnoError(.NXIO));
    try std.testing.expectEqual(@as(anyerror, error.NoDevice), errnoError(.SHUTDOWN));
    try std.testing.expectEqual(@as(anyerror, error.InputOutput), errnoError(.IO));
    try std.testing.expectEqual(@as(anyerror, error.AccessDenied), errnoError(.ACCES));
    try std.testing.expectEqual(@as(anyerror, error.NoSpaceLeft), errnoError(.NOSPC));
    try std.testing.expectEqual(@as(anyerror, error.Unexpected), errnoError(.INVAL));
    // 拔线错误在探测阶段必须可跳过，否则会以“未预期的系统错误”挡掉 BLE 回落
    try std.testing.expect(probeSkippable(errnoError(.PROTO)));
}

test "exchange：poll 可读但读到 0 字节（拔线 EOF）报 NoDevice" {
    // /dev/null 写入即丢、读立即返回 EOF，语义等同“设备消失”
    const f = try std.fs.openFileAbsolute("/dev/null", .{ .mode = .read_write });
    defer f.close();
    var req: [protocol.frame_len]u8 = undefined;
    try protocol.encodeRead(&req, .live_status, 0, 3);
    var g = HidFrames{ .file = f };
    try std.testing.expectError(error.NoDevice, exchange(&g, &req, .live_status, monoMs() + 100));
}

/// 记录写入帧、按序吐出输入帧的 fake；帧用尽即报期限用尽（Timeout）。
/// 序列可混入真机上的非响应帧：report 3 短通知、键盘报告、旧命令响应。
const FakeFrames = struct {
    frames: []const []const u8 = &.{},
    read_count: usize = 0,
    writes: [4][protocol.frame_len]u8 = undefined,
    write_count: usize = 0,

    fn writeFrame(self: *FakeFrames, req: []const u8) !void {
        self.writes[self.write_count] = req[0..protocol.frame_len].*;
        self.write_count += 1;
    }

    fn nextFrame(self: *FakeFrames, timeout_ms: i32) ![]const u8 {
        _ = timeout_ms; // 期限由 exchange 判定，这里用“帧用尽”模拟
        if (self.read_count == self.frames.len) return error.Timeout;
        const f = self.frames[self.read_count];
        self.read_count += 1;
        return f;
    }
};

/// 构造 64 字节响应帧（测试用；decodeResponse 不校验校验和）。
fn responseFrame(buf: *[protocol.frame_len]u8, command: protocol.Command, status: u8, data: []const u8) []const u8 {
    @memset(buf, 0);
    buf[0] = protocol.report_id;
    buf[3] = @intFromEnum(command);
    buf[4] = @intCast(data.len);
    buf[7] = status;
    @memcpy(buf[8..][0..data.len], data);
    return buf;
}

fn readReq() [protocol.frame_len]u8 {
    var req: [protocol.frame_len]u8 = undefined;
    protocol.encodeRead(&req, .live_status, 0, 3) catch unreachable;
    return req;
}

test "事务：跳过设备主动推送的短通知，拿到真正的 64 字节响应" {
    const notif = [_]u8{ 0x03, 0x03, 0x04 }; // 真机 report 3 短通知（3 字节）
    var resp: [protocol.frame_len]u8 = undefined;
    const r = responseFrame(&resp, .live_status, 0x00, &.{ 0x01, 0xf4, 0x1f });

    var fake: FakeFrames = .{ .frames = &.{ &notif, r } };
    const req = readReq();
    const d = try exchange(&fake, &req, .live_status, monoMs() + 100);
    try std.testing.expectEqual(@as(u8, 3), d.len);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0xf4, 0x1f }, d.bytes());
    try std.testing.expectEqual(@as(usize, 1), fake.write_count); // 请求只发一次，不重放
}

test "事务：跳过键盘报告与旧命令响应，只采纳本次响应" {
    // 真机 hidraw 节点同时承载键盘（report 1，16 字节）等其他报告
    const keyboard = [_]u8{0x01} ++ [_]u8{0xA5} ** 15;
    var stale_buf: [protocol.frame_len]u8 = undefined;
    const stale = responseFrame(&stale_buf, .settings_read, 0x00, &[_]u8{0xAB} ** 15);
    var ok_buf: [protocol.frame_len]u8 = undefined;
    const ok = responseFrame(&ok_buf, .live_status, 0x00, &.{ 0x02, 0xf4, 0x1f });

    var fake: FakeFrames = .{ .frames = &.{ &keyboard, stale, ok } };
    const req = readReq();
    const d = try exchange(&fake, &req, .live_status, monoMs() + 100);
    try std.testing.expectEqual(@as(u8, 3), d.len);
    try std.testing.expectEqual(@as(u8, 0x02), d.bytes()[0]);
}

test "事务：只有非响应帧（含截断响应）时报 Timeout，不把它们当结果" {
    const notif = [_]u8{ 0x03, 0x03, 0x04 };
    var buf: [protocol.frame_len]u8 = undefined;
    const truncated = responseFrame(&buf, .live_status, 0x00, &.{ 0, 0, 0 })[0..40]; // 截断帧

    var fake: FakeFrames = .{ .frames = &.{ &notif, truncated } };
    const req = readReq();
    try std.testing.expectError(error.Timeout, exchange(&fake, &req, .live_status, monoMs() + 100));
}

test "事务：设备用本次命令回话的忙/错误/未知状态为真实结论，不丢弃" {
    const req = readReq();
    var busy_buf: [protocol.frame_len]u8 = undefined;
    var busy: FakeFrames = .{ .frames = &.{responseFrame(&busy_buf, .live_status, 0xfe, &.{0})} };
    try std.testing.expectError(error.Busy, exchange(&busy, &req, .live_status, monoMs() + 100));

    var err_buf: [protocol.frame_len]u8 = undefined;
    var device_error: FakeFrames = .{ .frames = &.{responseFrame(&err_buf, .live_status, 0xff, &.{0})} };
    try std.testing.expectError(error.DeviceError, exchange(&device_error, &req, .live_status, monoMs() + 100));

    var odd_buf: [protocol.frame_len]u8 = undefined;
    var odd: FakeFrames = .{ .frames = &.{responseFrame(&odd_buf, .live_status, 0x42, &.{0})} };
    try std.testing.expectError(error.BadStatus, exchange(&odd, &req, .live_status, monoMs() + 100));
}

test "事务：期限已过时不读帧直接报 Timeout" {
    var fake: FakeFrames = .{};
    const req = readReq();
    try std.testing.expectError(error.Timeout, exchange(&fake, &req, .live_status, monoMs()));
    try std.testing.expectEqual(@as(usize, 1), fake.write_count); // 请求已发出，只是不再等
    try std.testing.expectEqual(@as(usize, 0), fake.read_count);
}
