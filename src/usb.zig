//! hidraw USB 传输：按 VID:PID 发现设备，收发 64 字节帧。
//! 同一 hidraw 节点还承载键盘/鼠标等其他 HID 报告与设备主动推送的短通知，
//! 事务层负责丢弃它们（见 `exchange`）。
const std = @import("std");
const protocol = @import("protocol.zig");
const monoMs = @import("root.zig").monoMs;
const log = @import("root.zig").log;
// 测试用：把诊断输出改道，避免 zig build test 被 errno/日志断言之外的噪声刷屏
const setLogSink = @import("root.zig").setLogSink;
const discardLog = @import("root.zig").discardLog;

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
            const file = std.fs.openFileAbsolute(path, .{ .mode = .read_write }) catch |err| switch (err) {
                // 权限问题优先报告，比“无应答”更可操作
                error.AccessDenied => {
                    denied = true;
                    continue;
                },
                // 枚举 sysfs 到打开节点之间设备被拔掉：与“设备不在”同义，不是环境故障
                error.FileNotFound => continue,
                // 节点忙、I/O 故障等必须上报：吞掉会被误判成“接口无应答”而错误回落 BLE
                else => {
                    if (env_err == null) env_err = err;
                    continue;
                },
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
        if (denied) return error.UsbAccessDenied;
        if (env_err) |err| return err;
        return if (matched) error.DeviceNotResponding else error.DeviceNotFound;
    }

    pub fn close(dev: *Device) void {
        dev.file.close();
    }

    /// 静态检查是否存在本项目的 hidraw 接口（读 sysfs，不打开、不发帧）。
    /// daemon 复用 BLE 链路时用它发现“后插入的 USB”，避免每请求做一次探测事务。
    pub fn present() bool {
        return presentAt("/sys/class/hidraw") catch false;
    }

    fn presentAt(sys_class_hidraw: []const u8) !bool {
        var dir = std.fs.openDirAbsolute(sys_class_hidraw, .{ .iterate = true }) catch |err| switch (err) {
            // 无 hidraw 子系统 = 没有设备节点
            error.FileNotFound => return false,
            else => |e| return e,
        };
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (try isTarget(dir, entry.name)) return true;
        }
        return false;
    }

    /// 句柄是否仍然可用：零超时 poll 看挂断/错误事件（拔线后 hidraw 报 POLLERR/POLLHUP）。
    /// 只查内核状态、不发帧，供 daemon 在复用链路前预检，避免用户请求先失败一次。
    pub fn alive(dev: Device) bool {
        var fds = [_]std.posix.pollfd{.{
            .fd = dev.file.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        _ = std.posix.poll(&fds, 0) catch return false;
        return fds[0].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL) == 0;
    }

    /// 一次事务：写请求帧 → 等本次响应帧 → 解码校验。
    pub fn transact(dev: Device, req: *const [protocol.frame_len]u8, command: protocol.Command, want: protocol.Expect) !protocol.Decoded {
        var g = HidFrames{ .file = dev.file };
        return exchange(&g, req, command, want, monoMs() + response_timeout_ms);
    }

    /// 读命令：与 BLE 链路同形语义，帧与事务由本层实现。
    /// 读是唯一会变 offset/长度的命令，回显参与判定（见 exchange）。
    pub fn read(dev: Device, command: protocol.Command, offset: u16, len: u8) !protocol.Decoded {
        var req: [protocol.frame_len]u8 = undefined;
        try protocol.encodeRead(&req, command, offset, len);
        return dev.transact(&req, command, .{ .offset = offset, .len = len });
    }

    /// 写命令。写响应是否回显 offset/长度在真机未确认（spec §2），不据此判错。
    pub fn write(dev: Device, command: protocol.Command, offset: u16, payload: []const u8) !void {
        var req: [protocol.frame_len]u8 = undefined;
        try protocol.encodeWrite(&req, command, offset, payload);
        _ = try dev.transact(&req, command, .{});
    }

    /// 会话命令（USB 上同样要等响应帧，与 BLE 的 fire-and-forget 不同）。
    pub fn session(dev: Device, is_open: bool) !void {
        var req: [protocol.frame_len]u8 = undefined;
        try protocol.encodeSession(&req, is_open);
        _ = try dev.transact(&req, if (is_open) .session_open else .session_close, .{});
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
        // 与 BLE 的权限错误分开命名：用户能直接看出是 hidraw 还是 system bus 被拒
        .ACCES, .PERM => return error.UsbAccessDenied,
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
    _ = try exchange(&g, &req, .live_status, .{ .offset = 0, .len = 3 }, monoMs() + probe_timeout_ms);
    return .{ .file = file };
}

/// 一次事务：写请求帧 → 等到本次响应帧。
///
/// 响应恒为 report ID 4 的 64 字节帧，但同一 hidraw 节点还承载其他报告流
/// （键盘/鼠标/消费者）与设备主动推送的短通知（真机实测：挡位写入后约 50ms 出现
/// 3 字节 report 3 通知），旧响应也可能残留在队列里。这些“不是本次响应”的帧
/// 一律丢弃后继续等，直到单调时钟期限用尽（与 BLE 事务丢弃旧通知的判定一致）。
fn exchange(g: anytype, req: *const [protocol.frame_len]u8, expect: protocol.Command, want: protocol.Expect, deadline_ms: i64) !protocol.Decoded {
    try g.writeFrame(req);
    // 丢弃过“协议形状”的帧（report ID 4）时记下来：期限到了仍无有效响应，
    // 报 BadResponse 而不是 Timeout，用户才能区分“设备没回”与“回了坏帧/旧帧”。
    var saw_protocol_frame = false;
    while (true) {
        const remaining = deadline_ms - monoMs();
        if (remaining <= 0) return if (saw_protocol_frame) error.BadResponse else error.Timeout;
        const raw = g.nextFrame(@intCast(@min(remaining, std.math.maxInt(i32)))) catch |err| switch (err) {
            // 期限用尽：据是否见过协议形状的帧给出可区分的结论
            error.Timeout => return if (saw_protocol_frame) error.BadResponse else error.Timeout,
            else => |e| return e,
        };
        if (raw.len > 0 and raw[0] == protocol.report_id) saw_protocol_frame = true;
        return protocol.decodeResponse(raw, expect, want) catch |err| switch (err) {
            // 不是本次响应：异物报告 / 短通知 / 截断帧 / 旧响应（命令或 offset/长度不符）。
            // 丢弃继续等；hidraw 是非阻塞读，队列里可能还排着真正的响应。
            error.BadReportId, error.BadLength, error.CommandMismatch, error.LengthMismatch, error.OffsetMismatch => continue,
            // 设备确实用本次命令回了话：忙/错误/未知状态/校验和损坏是真实结论，不得吞掉
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
        // 探测层的“无应答”包含两种有界结论：完全没有帧（Timeout），或只收到坏帧/旧帧
        // （BadResponse）。两者都只说明这个接口不是协议接口，试下一个。
        error.Timeout, error.BadResponse, error.NoDevice => true,
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

test "uevent 匹配：大小写、字段缺失/非法与 PID 不符都不误判" {
    // 十六进制大小写都按同一数值解析（内核输出大写，手工样本可能是小写）
    try std.testing.expect(matchVidPid("HID_ID=0003:000017ef:0000f00c\n"));
    // HID_ID 不必在第一行，尾部多余字段不影响判定
    try std.testing.expect(matchVidPid("HID_NAME=x\nHID_ID=0003:000017EF:0000F00C\nDRIVER=hid-generic\n"));
    try std.testing.expect(matchVidPid("HID_ID=0003:000017EF:0000F00C:1\n"));

    try std.testing.expect(!matchVidPid("HID_ID=0003:000017EF\n")); // 缺 PID
    try std.testing.expect(!matchVidPid("HID_ID=0003:000017EF:0000F00D\n")); // 同厂不同型
    try std.testing.expect(!matchVidPid("HID_ID=0003:ZZZZZZ:0000F00C\n")); // 非十六进制
    try std.testing.expect(!matchVidPid("")); // 空 uevent
}

test "探测失败分类：仅无应答/设备已拔可跳过，设备报错与权限/IO 错误必须上报" {
    try std.testing.expect(probeSkippable(error.Timeout));
    try std.testing.expect(probeSkippable(error.BadResponse)); // 只收到坏帧/旧帧：接口不对
    try std.testing.expect(probeSkippable(error.NoDevice));
    try std.testing.expect(!probeSkippable(error.Busy));
    try std.testing.expect(!probeSkippable(error.DeviceError));
    try std.testing.expect(!probeSkippable(error.BadStatus));
    try std.testing.expect(!probeSkippable(error.BadChecksum));
    try std.testing.expect(!probeSkippable(error.UsbAccessDenied));
    try std.testing.expect(!probeSkippable(error.InputOutput));
    try std.testing.expect(!probeSkippable(error.FileNotFound));
}

/// 在 tmpdir 里造一个假 hidraw 条目；条目名决定设备节点路径（/dev/{name}）。
/// 名字 null / full 分别映射到 /dev/null、/dev/full，用真实内核行为模拟
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

test "枚举：打开设备节点的非权限错误原样上报，不被“接口无应答”掩盖" {
    // /dev/shm 是目录：打开必然失败（EISDIR），模拟“节点在但打不开”的环境故障
    std.fs.accessAbsolute("/dev/shm", .{}) catch return error.SkipZigTest;
    const log_prev = setLogSink(discardLog);
    defer _ = setLogSink(log_prev);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFakeInterface(tmp, "shm");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectError(error.IsDir, Device.openFrom(try tmp.dir.realpath(".", &buf)));
}

test "present：只按 sysfs 判断接口在不在（不打开、不发帧）" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try tmp.dir.realpath(".", &buf);
    try std.testing.expect(!try Device.presentAt(dir)); // 空目录
    try makeFakeInterface(tmp, "null");
    try std.testing.expect(try Device.presentAt(dir)); // 有 HID_ID 匹配的节点
    try std.testing.expect(!try Device.presentAt("/nonexistent-hidraw"));
}

test "alive：正常句柄可用，挂断（POLLHUP）与已关闭（POLLNVAL）报不可用" {
    // 管道：关写端后读端得到 POLLHUP，正是拔线后 hidraw 报的挂断事件。
    // 只用“关掉 fd”测不到这条路径——那只会得到 POLLNVAL。
    const fds = try std.posix.pipe();
    const hung_up: Device = .{ .file = .{ .handle = fds[0] } };
    defer hung_up.file.close();
    try std.testing.expect(hung_up.alive());
    std.posix.close(fds[1]);
    try std.testing.expect(!hung_up.alive());

    // 已关闭的 fd：poll 报 POLLNVAL，同样视为“不可复用”
    const f = try std.fs.openFileAbsolute("/dev/null", .{ .mode = .read_write });
    const closed: Device = .{ .file = f };
    try std.testing.expect(closed.alive());
    f.close();
    try std.testing.expect(!closed.alive());
}

test "errno 翻译：拔线相关错误码归为 NoDevice（可诊断、探测可跳过），其余按语义分类" {
    const log_prev = setLogSink(discardLog); // 未建模 errno 会记一行日志
    defer _ = setLogSink(log_prev);
    try std.testing.expectEqual(@as(anyerror, error.NoDevice), errnoError(.PROTO)); // 真机拔线实测
    try std.testing.expectEqual(@as(anyerror, error.NoDevice), errnoError(.NODEV));
    try std.testing.expectEqual(@as(anyerror, error.NoDevice), errnoError(.NXIO));
    try std.testing.expectEqual(@as(anyerror, error.NoDevice), errnoError(.SHUTDOWN));
    try std.testing.expectEqual(@as(anyerror, error.InputOutput), errnoError(.IO));
    try std.testing.expectEqual(@as(anyerror, error.UsbAccessDenied), errnoError(.ACCES));
    try std.testing.expectEqual(@as(anyerror, error.UsbAccessDenied), errnoError(.PERM));
    try std.testing.expectEqual(@as(anyerror, error.NoSpaceLeft), errnoError(.NOSPC));
    try std.testing.expectEqual(@as(anyerror, error.FileNotFound), errnoError(.NOENT));
    try std.testing.expectEqual(@as(anyerror, error.DeviceBusy), errnoError(.BUSY));
    try std.testing.expectEqual(@as(anyerror, error.WouldBlock), errnoError(.AGAIN));
    try std.testing.expectEqual(@as(anyerror, error.Unexpected), errnoError(.INVAL));
    // 权限错误必须上报（回落 BLE 会掩盖“没有 udev uaccess 规则”这一可操作信息）
    try std.testing.expect(!probeSkippable(errnoError(.ACCES)));
    try std.testing.expect(!probeSkippable(errnoError(.IO)));
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
    try std.testing.expectError(error.NoDevice, exchange(&g, &req, .live_status, .{}, monoMs() + 100));
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

/// 构造 64 字节响应帧（含有效校验和；测试需要改字段时改完须重新 stampChecksum）。
fn responseFrame(buf: *[protocol.frame_len]u8, command: protocol.Command, offset: u16, status: u8, data: []const u8) []const u8 {
    @memset(buf, 0);
    buf[0] = protocol.report_id;
    buf[3] = @intFromEnum(command);
    buf[4] = @intCast(data.len);
    std.mem.writeInt(u16, buf[5..7], offset, .little);
    buf[7] = status;
    @memcpy(buf[8..][0..data.len], data);
    protocol.stampChecksum(buf);
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
    const r = responseFrame(&resp, .live_status, 0, 0x00, &.{ 0x01, 0xf4, 0x1f });

    var fake: FakeFrames = .{ .frames = &.{ &notif, r } };
    const req = readReq();
    const d = try exchange(&fake, &req, .live_status, .{ .offset = 0, .len = 3 }, monoMs() + 100);
    try std.testing.expectEqual(@as(u8, 3), d.len);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0xf4, 0x1f }, d.bytes());
    try std.testing.expectEqual(@as(usize, 1), fake.write_count); // 请求只发一次，不重放
}

test "事务：跳过键盘报告与旧命令响应，只采纳本次响应" {
    // 真机 hidraw 节点同时承载键盘（report 1，16 字节）等其他报告
    var keyboard = std.mem.zeroes([16]u8);
    keyboard[0] = 0x01;
    @memset(keyboard[1..], 0xA5);
    var stale_payload = std.mem.zeroes([protocol.settings_len]u8);
    @memset(&stale_payload, 0xAB);
    var stale_buf: [protocol.frame_len]u8 = undefined;
    const stale = responseFrame(&stale_buf, .settings_read, 0, 0x00, &stale_payload);
    var ok_buf: [protocol.frame_len]u8 = undefined;
    const ok = responseFrame(&ok_buf, .live_status, 0, 0x00, &.{ 0x02, 0xf4, 0x1f });

    var fake: FakeFrames = .{ .frames = &.{ &keyboard, stale, ok } };
    const req = readReq();
    const d = try exchange(&fake, &req, .live_status, .{ .offset = 0, .len = 3 }, monoMs() + 100);
    try std.testing.expectEqual(@as(u8, 3), d.len);
    try std.testing.expectEqual(@as(u8, 0x02), d.bytes()[0]);
}

test "事务：同命令但 offset/长度不符的旧响应被丢弃，匹配帧随后被接受" {
    var stale_buf: [protocol.frame_len]u8 = undefined;
    var payload = std.mem.zeroes([3]u8);
    @memset(&payload, 0x11);
    const stale = responseFrame(&stale_buf, .live_status, 9, 0x00, &payload); // offset 不符
    var ok_buf: [protocol.frame_len]u8 = undefined;
    const ok = responseFrame(&ok_buf, .live_status, 0, 0x00, &.{ 0x03, 0x00, 0x00 });

    var fake: FakeFrames = .{ .frames = &.{ stale, ok } };
    const req = readReq();
    const d = try exchange(&fake, &req, .live_status, .{ .offset = 0, .len = 3 }, monoMs() + 100);
    try std.testing.expectEqual(@as(u8, 0x03), d.bytes()[0]);
    try std.testing.expectEqual(@as(usize, 2), fake.read_count); // 旧帧被丢弃
}

test "事务：只有短通知时报 Timeout（设备没回），不当成坏帧" {
    const notif = [_]u8{ 0x03, 0x03, 0x04 };
    var fake: FakeFrames = .{ .frames = &.{&notif} };
    const req = readReq();
    try std.testing.expectError(error.Timeout, exchange(&fake, &req, .live_status, .{}, monoMs() + 100));
}

test "事务：只收到协议形状的坏帧（截断/异命令）时报 BadResponse，区分“设备没回”" {
    var buf: [protocol.frame_len]u8 = undefined;
    const truncated = responseFrame(&buf, .live_status, 0, 0x00, &.{ 0, 0, 0 })[0..40]; // report 4 截断
    var fake: FakeFrames = .{ .frames = &.{truncated} };
    const req = readReq();
    try std.testing.expectError(error.BadResponse, exchange(&fake, &req, .live_status, .{}, monoMs() + 100));
}

test "事务：校验和损坏的帧以 BadChecksum 上报，不静默等到超时" {
    var buf: [protocol.frame_len]u8 = undefined;
    const f = responseFrame(&buf, .live_status, 0, 0x00, &.{ 1, 2, 3 });
    buf[8] ^= 0xff; // 数据位被改，校验和失配
    var fake: FakeFrames = .{ .frames = &.{f} };
    const req = readReq();
    try std.testing.expectError(error.BadChecksum, exchange(&fake, &req, .live_status, .{}, monoMs() + 100));
}

test "事务：设备用本次命令回话的忙/错误/未知状态为真实结论，不丢弃" {
    const req = readReq();
    var busy_buf: [protocol.frame_len]u8 = undefined;
    var busy: FakeFrames = .{ .frames = &.{responseFrame(&busy_buf, .live_status, 0, 0xfe, &.{0})} };
    try std.testing.expectError(error.Busy, exchange(&busy, &req, .live_status, .{}, monoMs() + 100));

    var err_buf: [protocol.frame_len]u8 = undefined;
    var device_error: FakeFrames = .{ .frames = &.{responseFrame(&err_buf, .live_status, 0, 0xff, &.{0})} };
    try std.testing.expectError(error.DeviceError, exchange(&device_error, &req, .live_status, .{}, monoMs() + 100));

    var odd_buf: [protocol.frame_len]u8 = undefined;
    var odd: FakeFrames = .{ .frames = &.{responseFrame(&odd_buf, .live_status, 0, 0x42, &.{0})} };
    try std.testing.expectError(error.BadStatus, exchange(&odd, &req, .live_status, .{}, monoMs() + 100));
}

test "事务：只见协议形状但都不匹配的帧，期限到了报 BadResponse" {
    // 旧命令响应：形状是 report 4 的 64 字节帧，但命令回显不是本次请求
    var stale_buf: [protocol.frame_len]u8 = undefined;
    const stale = responseFrame(&stale_buf, .settings_read, 0, 0x00, &.{ 1, 2, 3 });
    var fake: FakeFrames = .{ .frames = &.{ stale, stale } };
    const req = readReq();
    // “设备回了话但不是这次响应”与“设备根本没回”必须能区分开
    try std.testing.expectError(error.BadResponse, exchange(&fake, &req, .live_status, .{}, monoMs() + 100));
}

test "事务：帧源的 I/O 错误原样透传，不被当成没回" {
    const Failing = struct {
        fn writeFrame(_: *@This(), _: []const u8) !void {}
        // 显式 anyerror：exchange 里既有 Timeout 分支也有透传分支
        fn nextFrame(_: *@This(), _: i32) anyerror![]const u8 {
            return error.InputOutput;
        }
    };
    var g: Failing = .{};
    const req = readReq();
    try std.testing.expectError(error.InputOutput, exchange(&g, &req, .live_status, .{}, monoMs() + 100));
}

test "事务：期限已过时不读帧直接报 Timeout" {
    var fake: FakeFrames = .{};
    const req = readReq();
    try std.testing.expectError(error.Timeout, exchange(&fake, &req, .live_status, .{}, monoMs()));
    try std.testing.expectEqual(@as(usize, 1), fake.write_count); // 请求已发出，只是不再等
    try std.testing.expectEqual(@as(usize, 0), fake.read_count);
}
