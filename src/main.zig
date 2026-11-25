//! f9ctl：Legion F9 控制命令行。作为 f9d 的客户端经 Unix socket 收发请求，
//! 不直接访问设备。stdout 只输出结果（默认人读、--json 为 JSON），诊断走 stderr。

const std = @import("std");
const f9 = @import("f9");
const build_options = @import("build_options");

const protocol = f9.protocol;
const ipc = f9.ipc;

const usage =
    \\用法: f9ctl [选项] <命令>        （需要先启动 f9d）
    \\
    \\命令:
    \\  status                            读取实时状态（flag、RPM）
    \\  gear                              读取挡位
    \\  gear <quiet|balanced|beast|turbo>  设置挡位（也可用 0-3）
    \\
    \\选项:
    \\  --json                  以 JSON 输出结果
    \\  --link <usb|ble>        只走指定链路（不回落另一条链路）
    \\  --socket <路径>          连接指定 socket（默认 /run/f9d/f9d.sock，
    \\                          非 root 用 $XDG_RUNTIME_DIR/f9d.sock）
    \\  -h, --help              显示本帮助
    \\  -V, --version           显示版本
    \\
;

const Op = union(enum) {
    status,
    gear_get,
    gear_set: protocol.Gear,
    help,
    version,
};

const Options = struct {
    json: bool = false,
    link: ?ipc.LinkKind = null,
    socket_path: ?[]const u8 = null,
    op: Op,
};

/// 参数错误定位：arg 是触发错误的原始参数，hint 是可选说明。
const Diag = struct {
    arg: []const u8 = "",
    hint: []const u8 = "",
};

const ParseError = error{
    Usage,
    UnknownOption,
    UnknownCommand,
    MissingOptionValue,
    InvalidLinkValue,
    InvalidGearValue,
    TooManyArgs,
};

/// 解析除程序名之外的参数。纯函数（不读 environ、不碰文件系统），可直接测试。
fn parseArgs(args: []const []const u8, diag: *Diag) ParseError!Options {
    diag.* = .{};
    var opts: Options = .{ .op = .help };
    var cmd: ?[]const u8 = null;
    var value: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--json")) {
            opts.json = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            opts.op = .help;
            return opts;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            opts.op = .version;
            return opts;
        } else if (std.mem.eql(u8, arg, "--link")) {
            i += 1;
            if (i == args.len) {
                diag.arg = arg;
                return error.MissingOptionValue;
            }
            opts.link = parseLink(args[i], diag) catch return error.InvalidLinkValue;
        } else if (std.mem.startsWith(u8, arg, "--link=")) {
            opts.link = parseLink(arg["--link=".len..], diag) catch return error.InvalidLinkValue;
        } else if (std.mem.eql(u8, arg, "--socket")) {
            i += 1;
            if (i == args.len) {
                diag.arg = arg;
                return error.MissingOptionValue;
            }
            opts.socket_path = args[i];
        } else if (std.mem.startsWith(u8, arg, "--socket=")) {
            opts.socket_path = arg["--socket=".len..];
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            // 未知选项必须指名报错，不能当成子命令再统一打帮助
            diag.arg = arg;
            return error.UnknownOption;
        } else if (cmd == null) {
            cmd = arg;
        } else if (value == null) {
            value = arg;
        } else {
            diag.arg = arg;
            return error.TooManyArgs;
        }
    }

    const c = cmd orelse return error.Usage;
    if (std.mem.eql(u8, c, "status")) {
        if (value != null) return error.Usage;
        opts.op = .status;
    } else if (std.mem.eql(u8, c, "gear")) {
        // 先校验挡位参数，再碰 daemon
        opts.op = if (value) |v| .{ .gear_set = parseGear(v) catch |err| {
            diag.arg = v;
            return err;
        } } else .gear_get;
    } else {
        diag.arg = c;
        return error.UnknownCommand;
    }
    return opts;
}

fn parseLink(s: []const u8, diag: *Diag) error{InvalidLinkValue}!ipc.LinkKind {
    const link = std.meta.stringToEnum(ipc.LinkKind, s) orelse {
        diag.arg = s;
        return error.InvalidLinkValue;
    };
    return link;
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

pub fn main() void {
    var args_buf: [32][]const u8 = undefined;
    var n: usize = 0;
    var it = std.process.args();
    _ = it.next();
    while (it.next()) |arg| {
        if (n == args_buf.len) usageFail(.{ .arg = arg }, error.TooManyArgs);
        args_buf[n] = arg;
        n += 1;
    }

    var diag: Diag = .{};
    const opts = parseArgs(args_buf[0..n], &diag) catch |err| usageFail(diag, err);
    switch (opts.op) {
        .help => {
            std.fs.File.stdout().writeAll(usage) catch {};
            return;
        },
        .version => {
            print("{s} {s}\n", .{ f9.product_name, build_options.version }) catch {};
            return;
        },
        else => {},
    }
    execute(opts) catch |err| fail(err, opts.socket_path);
}

fn execute(opts: Options) !void {
    const alloc = std.heap.page_allocator;
    const req: ipc.Request = .{
        .op = switch (opts.op) {
            .status => .status,
            .gear_get => .gear_get,
            .gear_set => |g| .{ .gear_set = g },
            .help, .version => unreachable,
        },
        .link = opts.link,
    };
    const parsed = if (opts.socket_path) |path|
        try ipc.callOnPath(alloc, path, req)
    else
        try ipc.call(alloc, req);
    defer parsed.deinit();
    const reply = try unwrap(parsed.value);

    var out: [512]u8 = undefined;
    const line = switch (opts.op) {
        .status => statusLine(&out, opts.json, .{
            .flag = reply.flag orelse return error.BadReply,
            .rpm_raw = reply.rpm_raw orelse return error.BadReply,
            .rpm = reply.rpm orelse return error.BadReply,
        }),
        .gear_get, .gear_set => blk: {
            const n = reply.gear orelse return error.BadReply;
            const gear = std.meta.intToEnum(protocol.Gear, n) catch return error.BadReply;
            break :blk gearLine(&out, opts.json, gear);
        },
        .help, .version => unreachable,
    };
    // 结果写不出去（f9ctl status | head -n0）不是设备/通信故障：安静退出即可
    std.fs.File.stdout().writeAll(line) catch |err| switch (err) {
        error.BrokenPipe => return,
        else => |e| return e,
    };
}

const StatusView = struct {
    flag: u8,
    rpm_raw: u16,
    rpm: u16,
};

/// 状态输出（含结尾换行）。JSON 与字段名与 daemon 一致，方便脚本直接解析。
fn statusLine(buf: []u8, json: bool, v: StatusView) []const u8 {
    if (json) {
        return std.fmt.bufPrint(buf, "{{\"flag\":{d},\"rpm_raw\":{d},\"rpm\":{d}}}\n", .{ v.flag, v.rpm_raw, v.rpm }) catch unreachable;
    }
    return std.fmt.bufPrint(buf, "flag: 0x{x:0>2}\nrpm: {d}\n", .{ v.flag, v.rpm }) catch unreachable;
}

/// 挡位输出（含结尾换行）。
fn gearLine(buf: []u8, json: bool, gear: protocol.Gear) []const u8 {
    const n = @intFromEnum(gear);
    if (json) {
        return std.fmt.bufPrint(buf, "{{\"gear\":{d},\"gear_name\":\"{s}\"}}\n", .{ n, @tagName(gear) }) catch unreachable;
    }
    return std.fmt.bufPrint(buf, "gear: {s} ({d})\n", .{ @tagName(gear), n }) catch unreachable;
}

/// daemon 返回的 error 字段转回本地错误，统一走 fail() 文案。
fn unwrap(reply: ipc.Reply) !ipc.Reply {
    if (reply.@"error") |name| {
        if (errorFromName(name)) |err| return err;
        return error.DaemonError;
    }
    return reply;
}

/// 错误名是 IPC 线格式的一部分（ipc.wire_errors 与 daemon 侧 @errorName 一一对应）。
fn errorFromName(name: []const u8) ?ipc.wire_errors {
    inline for (@typeInfo(ipc.wire_errors).error_set.?) |e| {
        if (std.mem.eql(u8, name, e.name)) return @field(ipc.wire_errors, e.name);
    }
    return null;
}

/// 可信 stdout 输出（结果）。writeAll 失败只可能是管道关闭，忽略即可。
fn print(comptime fmt: []const u8, args: anytype) !void {
    var buf: [512]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, fmt, args);
    try std.fs.File.stdout().writeAll(line);
}

/// DaemonNotRunning 文案：按实际尝试过的 socket 路径拼，避免非 root 场景误导。
/// 显式给了 `--socket` 就报那个路径：报默认路径会把排查引到不存在的实例上。
fn daemonNotRunningMsg(buf: []u8, socket_path: ?[]const u8) []const u8 {
    if (socket_path) |path| return std.fmt.bufPrint(buf, "f9d 未运行（socket: {s}）", .{path}) catch "f9d 未运行";
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.fs.accessAbsolute(ipc.root_path, .{})) |_| {
        return "f9d 未运行（socket: " ++ ipc.root_path ++ "）";
    } else |_| {}
    const upath = ipc.userSocketPath(&pbuf) catch |err| switch (err) {
        error.NoRuntimeDir => return "f9d 未运行（且未设置 XDG_RUNTIME_DIR，用户级 f9d 拒绝回退 /tmp）",
        error.PathTooLong => return "XDG_RUNTIME_DIR 过长，拼不出 f9d socket 路径",
    };
    return std.fmt.bufPrint(buf, "f9d 未运行（socket: {s}）", .{upath}) catch "f9d 未运行";
}

fn usageFail(diag: Diag, err: anyerror) noreturn {
    var buf: [320]u8 = undefined;
    const reason = switch (err) {
        error.UnknownOption => std.fmt.bufPrint(&buf, "未知选项 {s}", .{diag.arg}),
        error.UnknownCommand => std.fmt.bufPrint(&buf, "未知命令 {s}", .{diag.arg}),
        error.MissingOptionValue => std.fmt.bufPrint(&buf, "选项 {s} 缺少参数", .{diag.arg}),
        error.InvalidLinkValue => std.fmt.bufPrint(&buf, "无效链路 {s}（可选 usb 或 ble）", .{diag.arg}),
        error.InvalidGearValue => std.fmt.bufPrint(&buf, "无效挡位 {s}（quiet/balanced/beast/turbo 或 0-3）", .{diag.arg}),
        error.TooManyArgs => std.fmt.bufPrint(&buf, "参数过多：{s}", .{diag.arg}),
        else => std.fmt.bufPrint(&buf, "参数错误", .{}),
    } catch "参数错误";
    var out: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&out, "f9ctl: {s}\n\n{s}", .{ reason, usage }) catch usage;
    std.fs.File.stderr().writeAll(text) catch {};
    std.process.exit(2);
}

fn fail(err: anyerror, socket_path: ?[]const u8) noreturn {
    var buf: [256]u8 = undefined;
    const msg = messageFor(err, &buf, socket_path);
    var out: [320]u8 = undefined;
    const line = std.fmt.bufPrint(&out, "f9ctl: {s}\n", .{msg}) catch "f9ctl: 出错\n";
    std.fs.File.stderr().writeAll(line) catch {};
    std.process.exit(1);
}

/// 错误 → 用户文案。buf 供需要动态拼接的分支使用。
/// 每个 ipc.wire_errors 成员都必须有专用文案（下方测试逐个检查），
/// 否则用户只会看到“f9d 返回未知错误”/“出错: <name>”。
fn messageFor(err: anyerror, buf: []u8, socket_path: ?[]const u8) []const u8 {
    return switch (err) {
        error.DaemonNotRunning => daemonNotRunningMsg(buf, socket_path),
        error.DaemonError => "f9d 返回未知错误（多为 f9ctl 与 f9d 版本不一致，细节见 f9d 日志）",
        error.BadReply => "f9d 响应格式异常",
        error.LineTooLong => "与 f9d 通信的报文超长",
        error.EndOfStream => "f9d 提前关闭了连接",
        error.TrailingData => "请求行后有多余数据（f9ctl 与 f9d 协议不一致？）",
        error.DeviceNotFound => "未找到设备（USB 17ef:f00c 或 BLE 服务 UUID/LEGION_F9_BT）",
        error.DeviceNotResponding => "USB 设备存在但协议接口无应答",
        error.UsbAccessDenied => "无权限访问 hidraw 设备（需 root 或 udev uaccess 规则）",
        error.BleAccessDenied => "无权限访问 BlueZ（需能访问 system bus）",
        error.Timeout => "等待设备响应超时（命令未在预算内应答）",
        error.ConnectTimeout => "BLE 连接超时（设备未开启、不在范围内或已被其他主机连接）",
        error.ResolveTimeout => "BLE 已连接但服务解析超时（设备状态异常）",
        error.Busy => "设备忙（状态 0xfe）",
        error.DeviceError => "设备返回错误（状态 0xff）",
        error.BadStatus => "响应状态字节未知",
        error.BadLength => "响应帧长度异常",
        error.BadReportId => "响应 report ID 异常",
        error.BadChecksum => "响应帧校验和错误（帧在传输中损坏）",
        error.BadResponse => "收到协议帧但不是本次请求的响应（帧损坏、截断或残留旧响应）",
        error.CommandMismatch => "响应命令回显不匹配",
        error.LengthMismatch => "响应声明长度与请求不符（旧响应或帧错位）",
        error.OffsetMismatch => "响应偏移与请求不符（旧响应或帧错位）",
        error.ShortData => "响应数据过短",
        error.InvalidGear => "设置块中的挡位值无效",
        error.GearMismatch => "设置后回读的挡位与请求不一致",
        error.InputOutput => "设备 I/O 错误，可能已拔出",
        error.NoDevice => "设备不存在，可能已拔出",
        error.DeviceBusy => "设备节点忙（其他进程正在使用）",
        error.NoSpaceLeft => "系统资源不足（ENOSPC）",
        error.WouldBlock => "设备暂时不可用（EAGAIN），请重试",
        error.FileNotFound => "设备节点不存在",
        error.PathTooLong => "路径过长",
        error.BluezUnavailable => "BlueZ 不可用（system bus 未运行、无蓝牙适配器或蓝牙未启用）",
        error.GattUnsupported => "设备缺少目标 GATT 服务/特征，或写特征不支持 write-with-response、通知特征不支持 notify",
        error.NotConnected => "BLE 设备未连接或链路中断",
        error.InProgress => "BLE 操作正在进行中（他方正在连接），请稍后重试",
        error.DbusError => "BlueZ D-Bus 调用失败（细节见 f9d 日志）",
        error.BadMagic => "BLE 响应帧头（0xee）异常",
        error.InvalidGearValue => "无效挡位（quiet/balanced/beast/turbo 或 0-3）",
        error.PayloadTooLong => "协议层载荷超长",
        error.BadRequest => "f9d 报告请求格式异常（f9ctl 与 f9d 版本不一致？）",
        error.ServerBusy => "f9d 连接数已满，请稍后重试",
        error.ConnectionRefused => "f9d 拒绝连接",
        error.ConnectionResetByPeer => "与 f9d 的连接被重置",
        error.ConnectionTimedOut => "与 f9d 的连接超时",
        error.SocketNotConnected => "与 f9d 的 socket 未连接",
        error.BrokenPipe => "与 f9d 的连接已断开",
        error.OutOfMemory => "内存不足",
        // 以下为客户端本地（socket/文件系统）错误，不是 daemon 的线格式
        error.AccessDenied => "无权限连接 f9d 的 socket（检查 socket 权限与实例用户）",
        error.NameTooLong => "socket 路径过长",
        error.NotDir => "socket 路径中的某一段不是目录",
        error.SystemResources => "系统资源不足（fd/内存），请稍后重试",
        error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => "文件描述符耗尽，请稍后重试",
        error.Unexpected => "未预期的系统错误（细节见 f9d 日志）",
        else => std.fmt.bufPrint(buf, "出错: {s}", .{@errorName(err)}) catch "出错",
    };
}

test "参数解析：命令、挡位、选项与链路" {
    var diag: Diag = .{};
    try std.testing.expectEqual(Op.status, (try parseArgs(&.{"status"}, &diag)).op);
    try std.testing.expectEqual(Op.gear_get, (try parseArgs(&.{"gear"}, &diag)).op);
    try std.testing.expectEqual(Op{ .gear_set = .turbo }, (try parseArgs(&.{ "gear", "turbo" }, &diag)).op);
    try std.testing.expectEqual(Op{ .gear_set = .quiet }, (try parseArgs(&.{ "gear", "0" }, &diag)).op);
    try std.testing.expectEqual(Op.help, (try parseArgs(&.{"--help"}, &diag)).op);
    try std.testing.expectEqual(Op.help, (try parseArgs(&.{"-h"}, &diag)).op);
    try std.testing.expectEqual(Op.version, (try parseArgs(&.{"--version"}, &diag)).op);
    try std.testing.expectEqual(Op.version, (try parseArgs(&.{"-V"}, &diag)).op);

    const json = try parseArgs(&.{ "--json", "status" }, &diag);
    try std.testing.expect(json.json);
    try std.testing.expectEqual(@as(?ipc.LinkKind, null), json.link);

    const linked = try parseArgs(&.{ "--link", "ble", "gear" }, &diag);
    try std.testing.expectEqual(@as(?ipc.LinkKind, .ble), linked.link);
    const linked_eq = try parseArgs(&.{ "--link=usb", "gear", "2" }, &diag);
    try std.testing.expectEqual(@as(?ipc.LinkKind, .usb), linked_eq.link);
    try std.testing.expectEqual(Op{ .gear_set = .beast }, linked_eq.op);

    const sock = try parseArgs(&.{ "--socket", "/tmp/x.sock", "status" }, &diag);
    try std.testing.expectEqualStrings("/tmp/x.sock", sock.socket_path.?);
    const sock_eq = try parseArgs(&.{ "--socket=/run/f9d/f9d.sock", "status" }, &diag);
    try std.testing.expectEqualStrings("/run/f9d/f9d.sock", sock_eq.socket_path.?);
}

test "参数解析：未知选项/命令、缺参数、非法链路与挡位都指名报错" {
    var diag: Diag = .{};
    try std.testing.expectError(error.UnknownOption, parseArgs(&.{"--foo"}, &diag));
    try std.testing.expectEqualStrings("--foo", diag.arg);
    try std.testing.expectError(error.UnknownOption, parseArgs(&.{ "status", "-x" }, &diag));
    try std.testing.expectError(error.UnknownCommand, parseArgs(&.{"stats"}, &diag));
    try std.testing.expectEqualStrings("stats", diag.arg);
    try std.testing.expectError(error.MissingOptionValue, parseArgs(&.{ "status", "--link" }, &diag));
    try std.testing.expectEqualStrings("--link", diag.arg);
    try std.testing.expectError(error.MissingOptionValue, parseArgs(&.{ "status", "--socket" }, &diag));
    try std.testing.expectError(error.InvalidLinkValue, parseArgs(&.{ "--link", "wifi", "status" }, &diag));
    try std.testing.expectEqualStrings("wifi", diag.arg);
    try std.testing.expectError(error.InvalidGearValue, parseArgs(&.{ "gear", "4" }, &diag));
    try std.testing.expectEqualStrings("4", diag.arg);
    try std.testing.expectError(error.InvalidGearValue, parseArgs(&.{ "gear", "turboo" }, &diag));
    try std.testing.expectError(error.TooManyArgs, parseArgs(&.{ "gear", "1", "2" }, &diag));
    try std.testing.expectError(error.Usage, parseArgs(&.{}, &diag));
    try std.testing.expectError(error.Usage, parseArgs(&.{ "status", "x" }, &diag));
}

test "挡位解析：名称与数字等价，越界报错" {
    try std.testing.expectEqual(protocol.Gear.quiet, try parseGear("quiet"));
    try std.testing.expectEqual(protocol.Gear.balanced, try parseGear("balanced"));
    try std.testing.expectEqual(protocol.Gear.beast, try parseGear("beast"));
    try std.testing.expectEqual(protocol.Gear.turbo, try parseGear("turbo"));
    try std.testing.expectEqual(protocol.Gear.turbo, try parseGear("3"));
    try std.testing.expectError(error.InvalidGearValue, parseGear("4"));
    try std.testing.expectError(error.InvalidGearValue, parseGear(""));
    try std.testing.expectError(error.InvalidGearValue, parseGear("-1"));
}

test "输出格式：状态与挡位的 JSON / 人读文本" {
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "{\"flag\":2,\"rpm_raw\":8180,\"rpm\":2045}\n",
        statusLine(&buf, true, .{ .flag = 2, .rpm_raw = 0x1ff4, .rpm = 2045 }),
    );
    try std.testing.expectEqualStrings(
        "flag: 0x02\nrpm: 2045\n",
        statusLine(&buf, false, .{ .flag = 2, .rpm_raw = 0x1ff4, .rpm = 2045 }),
    );
    try std.testing.expectEqualStrings("{\"gear\":3,\"gear_name\":\"turbo\"}\n", gearLine(&buf, true, .turbo));
    try std.testing.expectEqualStrings("gear: turbo (3)\n", gearLine(&buf, false, .turbo));
}

test "错误名解析：daemon 线格式全部可往返，未知名返回 null" {
    // daemon 侧用 @errorName 作 IPC 线格式；这里保证每个名字都能映射回本地错误
    inline for (@typeInfo(ipc.wire_errors).error_set.?) |e| {
        const err = errorFromName(e.name) orelse return error.TestUnexpectedError;
        try std.testing.expectEqualStrings(e.name, @errorName(err));
    }
    try std.testing.expect(errorFromName("NoSuchError") == null);
}

test "daemon 线格式错误名都有专用文案，不走兜底" {
    var buf: [256]u8 = undefined;
    inline for (@typeInfo(ipc.wire_errors).error_set.?) |e| {
        const msg = messageFor(@field(ipc.wire_errors, e.name), &buf, null);
        try std.testing.expect(!std.mem.startsWith(u8, msg, "出错: "));
    }
    // 关键措辞抽查：USB 与 BLE 的权限错误必须能区分
    const usb_msg = messageFor(error.UsbAccessDenied, &buf, null);
    try std.testing.expect(std.mem.indexOf(u8, usb_msg, "hidraw") != null);
    const ble_msg = messageFor(error.BleAccessDenied, &buf, null);
    try std.testing.expect(std.mem.indexOf(u8, ble_msg, "BlueZ") != null);
    // 超时语义必须能区分链路阶段
    const t = messageFor(error.Timeout, &buf, null);
    try std.testing.expect(std.mem.indexOf(u8, t, "连接") == null);
    const ct = messageFor(error.ConnectTimeout, &buf, null);
    try std.testing.expect(std.mem.indexOf(u8, ct, "连接") != null);
    // 连接上限：daemon 直接回包、不经过链路层，文案不能退化成“未知错误”
    const busy = messageFor(error.ServerBusy, &buf, null);
    try std.testing.expect(std.mem.indexOf(u8, busy, "连接数") != null);
    // 回显类错误两条链路都会产生：文案不能只写 BLE
    inline for ([_]anyerror{ error.LengthMismatch, error.OffsetMismatch }) |err| {
        try std.testing.expect(std.mem.indexOf(u8, messageFor(err, &buf, null), "BLE") == null);
    }
}

test "daemonNotRunningMsg：显式 --socket 时按用户给的路径拼文案" {
    var buf: [512]u8 = undefined;
    const custom = daemonNotRunningMsg(&buf, "/tmp/isolated/f9d.sock");
    try std.testing.expectEqualStrings("f9d 未运行（socket: /tmp/isolated/f9d.sock）", custom);

    // 未给 --socket：仍按实际探测的默认路径（系统级或用户级）拼，且不出现用户路径
    const def = daemonNotRunningMsg(&buf, null);
    try std.testing.expect(std.mem.indexOf(u8, def, "/tmp/isolated") == null);
    try std.testing.expect(std.mem.startsWith(u8, def, "f9d 未运行"));
}

test "unwrap：无 error 字段透传，已知名字还原，未知名退化为 DaemonError" {
    const ok = try unwrap(.{ .flag = 1, .rpm = 2 }); // 无 error：原样返回
    try std.testing.expectEqual(@as(?u8, 1), ok.flag);
    try std.testing.expectEqual(@as(?u16, 2), ok.rpm);

    // daemon 的线格式是 @errorName：必须能以本地错误类型回来
    try std.testing.expectError(error.ServerBusy, unwrap(.{ .@"error" = "ServerBusy" }));
    try std.testing.expectError(error.DeviceNotFound, unwrap(.{ .@"error" = "DeviceNotFound" }));

    // 版本不一致等场景：名字不在表里，只能报“未知错误”，不能当成成功
    try std.testing.expectError(error.DaemonError, unwrap(.{ .@"error" = "NoSuchError" }));
    try std.testing.expectError(error.DaemonError, unwrap(.{ .@"error" = "" }));
}

test "参数解析：命令之后的选项、空值与单短横线的边界" {
    var diag: Diag = .{};

    // 选项可出现在命令之后，值仍是挡位
    const after = try parseArgs(&.{ "gear", "turbo", "--json" }, &diag);
    try std.testing.expect(after.json);
    try std.testing.expectEqual(Op{ .gear_set = .turbo }, after.op);

    // 空值不算“缺参数”，要按非法值/原样接受区分
    try std.testing.expectError(error.InvalidLinkValue, parseArgs(&.{"--link="}, &diag));
    const empty_sock = try parseArgs(&.{ "--socket=", "status" }, &diag);
    try std.testing.expectEqualStrings("", empty_sock.socket_path.?);

    // "-" 长度 1：不是选项，落成未知命令（而不是悄悄当成功）
    try std.testing.expectError(error.UnknownCommand, parseArgs(&.{"-"}, &diag));
    try std.testing.expectEqualStrings("-", diag.arg);

    // --help/--version 立即返回，忽略后续参数（"f9ctl --help status" 不报错）
    try std.testing.expectEqual(Op.help, (try parseArgs(&.{ "--help", "status" }, &diag)).op);
    try std.testing.expectEqual(Op.version, (try parseArgs(&.{ "-V", "status" }, &diag)).op);

    // 挡位/链路名大小写敏感：显示名与 @tagName 一致，不做模糊匹配
    try std.testing.expectError(error.InvalidGearValue, parseArgs(&.{ "gear", "Turbo" }, &diag));
    try std.testing.expectError(error.InvalidLinkValue, parseArgs(&.{ "--link", "USB", "status" }, &diag));
}

test "输出格式：flag 十六进制补零覆盖 0x00/0x0a/0xff" {
    var buf: [512]u8 = undefined;
    for ([_]struct { flag: u8, rpm: u16, text: []const u8 }{
        .{ .flag = 0x00, .rpm = 0, .text = "flag: 0x00\nrpm: 0\n" },
        .{ .flag = 0x0a, .rpm = 1, .text = "flag: 0x0a\nrpm: 1\n" },
        .{ .flag = 0xff, .rpm = 4095, .text = "flag: 0xff\nrpm: 4095\n" },
    }) |case| {
        try std.testing.expectEqualStrings(
            case.text,
            statusLine(&buf, false, .{ .flag = case.flag, .rpm_raw = case.rpm * 4, .rpm = case.rpm }),
        );
    }
}
