//! f9ctl：Legion F9 控制命令行。
//!
//! stdout 只输出结果（默认人读、--json 为 JSON），诊断信息一律走 stderr。

const std = @import("std");
const f9 = @import("f9");

const protocol = f9.protocol;
const usb = f9.usb;

const usage =
    \\用法: f9ctl [--json] <命令>
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

    if (std.mem.eql(u8, c, "status")) {
        if (value != null) return error.Usage;
        var dev = try usb.Device.open();
        defer dev.close();
        try cmdStatus(dev, json);
    } else if (std.mem.eql(u8, c, "gear")) {
        // 先校验挡位参数，再碰设备
        const gear: ?protocol.Gear = if (value) |v| try parseGear(v) else null;
        var dev = try usb.Device.open();
        defer dev.close();
        try cmdGear(dev, json, gear);
    } else {
        return error.Usage;
    }
}

fn cmdStatus(dev: usb.Device, json: bool) !void {
    var req: [protocol.frame_len]u8 = undefined;
    try protocol.encodeRead(&req, .live_status, 0, 3);
    const resp = try dev.transact(&req, .live_status);
    const st = try protocol.decodeStatus(resp.bytes());

    if (json) {
        try printJson(.{ .flag = st.flag, .rpm_raw = st.rpm_raw, .rpm = st.rpm });
    } else {
        try print("flag: 0x{x:0>2}\nrpm: {d}\n", .{ st.flag, st.rpm });
    }
}

fn cmdGear(dev: usb.Device, json: bool, gear_arg: ?protocol.Gear) !void {
    if (gear_arg) |gear| {
        // 会话：0x01 打开 → 读-改-写设置块（其余不透明字节原样保留）→ 0x02 提交
        try session(dev, true);
        errdefer session(dev, false) catch {};
        var block = try readSettings(dev);
        protocol.setGear(&block, gear);
        try writeSettings(dev, &block);
        try session(dev, false);
    }

    const block = try readSettings(dev);
    const gear = try protocol.decodeGear(&block);
    if (json) {
        try printJson(.{ .gear = @intFromEnum(gear), .gear_name = @tagName(gear) });
    } else {
        try print("gear: {s} ({d})\n", .{ @tagName(gear), @intFromEnum(gear) });
    }
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

fn printJson(value: anytype) !void {
    const alloc = std.heap.page_allocator;
    const out = try std.json.Stringify.valueAlloc(alloc, value, .{});
    defer alloc.free(out);
    try std.fs.File.stdout().writeAll(out);
    try std.fs.File.stdout().writeAll("\n");
}

fn fail(err: anyerror) noreturn {
    if (err == error.Usage) {
        std.fs.File.stderr().writeAll(usage) catch {};
        std.process.exit(2);
    }
    var buf: [256]u8 = undefined;
    const msg: []const u8 = switch (err) {
        error.DeviceNotFound => "未找到设备（VID:PID 17ef:f00c）",
        error.DeviceNotResponding => "设备存在但协议接口无应答",
        error.AccessDenied => "无权限访问 /dev/hidraw*（需要 root 或 udev 规则）",
        error.Timeout => "等待设备响应超时",
        error.Busy => "设备忙（状态 0xfe）",
        error.DeviceError => "设备返回错误（状态 0xff）",
        error.BadStatus => "响应状态字节未知",
        error.BadLength => "响应帧长度异常",
        error.BadReportId => "响应 report ID 异常",
        error.CommandMismatch => "响应命令回显不匹配",
        error.ShortData => "响应数据过短",
        error.InvalidGear => "设置块中的挡位值无效",
        error.InvalidGearValue => "无效挡位（quiet/balanced/beast/turbo 或 0-3）",
        error.PayloadTooLong => "协议层载荷超长",
        else => std.fmt.bufPrint(&buf, "出错: {s}", .{@errorName(err)}) catch "出错",
    };
    var out: [320]u8 = undefined;
    const line = std.fmt.bufPrint(&out, "f9ctl: {s}\n", .{msg}) catch "f9ctl: 出错\n";
    std.fs.File.stderr().writeAll(line) catch {};
    std.process.exit(1);
}
