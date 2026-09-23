//! f9ctl：Legion F9 控制命令行。作为 f9d 的客户端经 Unix socket 收发请求，
//! 不直接访问设备。stdout 只输出结果（默认人读、--json 为 JSON），诊断走 stderr。

const std = @import("std");
const f9 = @import("f9");

const protocol = f9.protocol;
const ipc = f9.ipc;

const usage =
    \\用法: f9ctl [--json] <命令>        （需要先启动 f9d）
    \\
    \\命令:
    \\  status                            读取实时状态（flag、RPM）
    \\  gear                              读取挡位
    \\  gear <quiet|balanced|beast|turbo>  设置挡位（也可用 0-3）
    \\
    \\选项:
    \\  --json                            以 JSON 输出结果
    \\
;

pub fn main() void {
    run() catch |err| fail(err);
}

fn run() !void {
    var json = false;
    var cmd: ?[]const u8 = null;
    var value: ?[]const u8 = null;

    var args = std.process.args();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try std.fs.File.stdout().writeAll(usage);
            return;
        } else if (cmd == null) {
            cmd = arg;
        } else if (value == null) {
            value = arg;
        } else {
            return error.Usage;
        }
    }

    const c = cmd orelse return error.Usage;
    const alloc = std.heap.page_allocator;

    if (std.mem.eql(u8, c, "status")) {
        if (value != null) return error.Usage;
        const parsed = try ipc.call(alloc, .status);
        defer parsed.deinit();
        const st = try unwrap(parsed.value);
        const flag = st.flag orelse return error.BadReply;
        const rpm_raw = st.rpm_raw orelse return error.BadReply;
        const rpm = st.rpm orelse return error.BadReply;
        if (json) {
            try print("{{\"flag\":{d},\"rpm_raw\":{d},\"rpm\":{d}}}\n", .{ flag, rpm_raw, rpm });
        } else {
            try print("flag: 0x{x:0>2}\nrpm: {d}\n", .{ flag, rpm });
        }
    } else if (std.mem.eql(u8, c, "gear")) {
        // 先校验挡位参数，再碰 daemon
        const req: ipc.Request = if (value) |v|
            .{ .gear_set = try parseGear(v) }
        else
            .gear_get;
        const parsed = try ipc.call(alloc, req);
        defer parsed.deinit();
        const n = (try unwrap(parsed.value)).gear orelse return error.BadReply;
        const gear = std.meta.intToEnum(protocol.Gear, n) catch return error.BadReply;
        if (json) {
            try print("{{\"gear\":{d},\"gear_name\":\"{s}\"}}\n", .{ n, @tagName(gear) });
        } else {
            try print("gear: {s} ({d})\n", .{ @tagName(gear), n });
        }
    } else {
        return error.Usage;
    }
}

/// daemon 返回的 error 字段转回本地错误，统一走 fail() 文案。
fn unwrap(reply: ipc.Reply) !ipc.Reply {
    if (reply.@"error") |name| {
        if (errorFromName(name)) |err| return err;
        return error.DaemonError;
    }
    return reply;
}

/// 错误名是 IPC 线格式的一部分，与 daemon 侧 @errorName 一一对应。
const daemon_errors = error{
    DeviceNotFound,
    DeviceNotResponding,
    AccessDenied,
    Timeout,
    Busy,
    DeviceError,
    BadStatus,
    BadLength,
    BadReportId,
    CommandMismatch,
    ShortData,
    InvalidGear,
    GearMismatch,
    PayloadTooLong,
    BadRequest,
    // BLE 链路（ble.zig）：帧层
    BadMagic,
    LengthMismatch,
    OffsetMismatch,
    // BLE 链路（ble.zig）：链路层
    BluezUnavailable,
    GattUnsupported,
    NotConnected,
    DbusError,
    // hidraw 拔插：write 侧 EIO/ENODEV、read 侧 EIO，以及 posix 层的兜底
    InputOutput,
    NoDevice,
    Unexpected,
};

fn errorFromName(name: []const u8) ?daemon_errors {
    inline for (@typeInfo(daemon_errors).error_set.?) |e| {
        if (std.mem.eql(u8, name, e.name)) return @field(daemon_errors, e.name);
    }
    return null;
}

fn parseGear(s: []const u8) error{InvalidGearValue}!protocol.Gear {
    if (std.mem.eql(u8, s, "quiet")) return .quiet;
    if (std.mem.eql(u8, s, "balanced")) return .balanced;
    if (std.mem.eql(u8, s, "beast")) return .beast;
    if (std.mem.eql(u8, s, "turbo")) return .turbo;
    if (std.fmt.parseInt(u8, s, 10)) |n| {
        return std.meta.intToEnum(protocol.Gear, n) catch error.InvalidGearValue;
    } else |_| {}
    return error.InvalidGearValue;
}

fn print(comptime fmt: []const u8, args: anytype) !void {
    var buf: [512]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, fmt, args);
    try std.fs.File.stdout().writeAll(line);
}

/// DaemonNotRunning 文案：按实际尝试过的 socket 路径拼，避免非 root 场景误导。
fn daemonNotRunningMsg(buf: []u8) []const u8 {
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.fs.accessAbsolute(ipc.root_path, .{})) |_| {
        return "f9d 未运行（socket: " ++ ipc.root_path ++ "）";
    } else |_| {}
    const upath = ipc.userSocketPath(&pbuf) catch
        return "f9d 未运行（且未设置 XDG_RUNTIME_DIR，用户级 f9d 拒绝回退 /tmp）";
    return std.fmt.bufPrint(buf, "f9d 未运行（socket: {s}）", .{upath}) catch "f9d 未运行";
}

fn fail(err: anyerror) noreturn {
    if (err == error.Usage) {
        std.fs.File.stderr().writeAll(usage) catch {};
        std.process.exit(2);
    }
    var buf: [256]u8 = undefined;
    const msg = messageFor(err, &buf);
    var out: [320]u8 = undefined;
    const line = std.fmt.bufPrint(&out, "f9ctl: {s}\n", .{msg}) catch "f9ctl: 出错\n";
    std.fs.File.stderr().writeAll(line) catch {};
    std.process.exit(1);
}

/// 错误 → 用户文案。buf 供需要动态拼接的分支使用。
fn messageFor(err: anyerror, buf: []u8) []const u8 {
    return switch (err) {
        error.DaemonNotRunning => daemonNotRunningMsg(buf),
        error.DaemonError => "f9d 返回未知错误",
        error.BadReply => "f9d 响应格式异常",
        error.LineTooLong => "与 f9d 通信的报文超长",
        error.EndOfStream => "f9d 提前关闭了连接",
        error.DeviceNotFound => "未找到设备（USB 17ef:f00c 或 BLE 服务 UUID/LEGION_F9_BT）",
        error.DeviceNotResponding => "USB 设备存在但协议接口无应答",
        error.AccessDenied => "无权限访问设备或 BlueZ（hidraw 需 root 或 udev 规则；BLE 需能连 system bus）",
        error.Timeout => "等待响应超时",
        error.Busy => "设备忙（状态 0xfe）",
        error.DeviceError => "设备返回错误（状态 0xff）",
        error.BadStatus => "响应状态字节未知",
        error.BadLength => "响应帧长度异常",
        error.BadReportId => "响应 report ID 异常",
        error.CommandMismatch => "响应命令回显不匹配",
        error.ShortData => "响应数据过短",
        error.InvalidGear => "设置块中的挡位值无效",
        error.GearMismatch => "设置后回读的挡位与请求不一致",
        error.InputOutput => "设备 I/O 错误，可能已拔出",
        error.NoDevice => "设备不存在，可能已拔出",
        error.BluezUnavailable => "BlueZ 不可用（system bus 未运行、无蓝牙适配器或蓝牙未启用）",
        error.GattUnsupported => "设备缺少目标 GATT 服务/特征，或写特征不支持 write-with-response、通知特征不支持 notify",
        error.NotConnected => "BLE 设备未连接或链路中断",
        error.DbusError => "BlueZ D-Bus 调用失败（细节见 f9d 日志）",
        error.BadMagic => "BLE 响应帧头（0xee）异常",
        error.LengthMismatch => "BLE 响应声明长度与请求不符",
        error.OffsetMismatch => "BLE 响应偏移与请求不符",
        error.InvalidGearValue => "无效挡位（quiet/balanced/beast/turbo 或 0-3）",
        error.PayloadTooLong => "协议层载荷超长",
        error.BadRequest => "f9d 报告请求格式异常（f9ctl 与 f9d 版本不一致？）",
        error.Unexpected => "未预期的系统错误（细节见 f9d 日志）",
        else => std.fmt.bufPrint(buf, "出错: {s}", .{@errorName(err)}) catch "出错",
    };
}

test "错误名解析：daemon 线格式全部可往返，未知名返回 null" {
    // daemon 侧用 @errorName 作 IPC 线格式；这里保证每个名字都能映射回本地错误
    inline for (@typeInfo(daemon_errors).error_set.?) |e| {
        const err = errorFromName(e.name) orelse return error.TestUnexpectedError;
        try std.testing.expectEqualStrings(e.name, @errorName(err));
    }
    try std.testing.expect(errorFromName("NoSuchError") == null);
}

test "daemon 线格式错误名都有专用文案（含 BLE 链路新增），不走兜底" {
    var buf: [256]u8 = undefined;
    inline for (@typeInfo(daemon_errors).error_set.?) |e| {
        const msg = messageFor(@field(daemon_errors, e.name), &buf);
        try std.testing.expect(!std.mem.startsWith(u8, msg, "出错: "));
    }
    // BLE 链路错误名抽查关键措辞
    const msg = messageFor(error.BluezUnavailable, &buf);
    try std.testing.expect(std.mem.indexOf(u8, msg, "BlueZ") != null);
}
