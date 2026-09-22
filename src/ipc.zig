//! f9ctl ↔ f9d 的 IPC：Unix socket 上的单行请求 / 单行 JSON 响应。
//!
//! - socket 路径：root 实例用 `/run/f9d/f9d.sock`（0666，本地用户均可连）；
//!   非 root（开发场景）用 `/tmp/f9d-<euid>.sock`。客户端先连系统级路径，
//!   不存在再连当前用户路径。
//! - 请求一行（`\n` 结尾）：`status` / `gear` / `gear <0-3>`。
//! - 响应一行 JSON：成功 `{"flag":…,"rpm_raw":…,"rpm":…}` 或 `{"gear":…}`；
//!   失败 `{"error":"<zig 错误名>"}`。错误名即线格式，展示文案归 f9ctl。

const std = @import("std");
const protocol = @import("protocol.zig");

pub const root_dir = "/run/f9d";
pub const root_path = root_dir ++ "/f9d.sock";

pub const max_request_len = 128;
pub const max_reply_len = 256;
/// 客户端等响应的上限：覆盖设备 2s 收发 + 惰性重开的探测耗时。
pub const io_timeout_ms = 10_000;

pub const Request = union(enum) {
    status,
    gear_get,
    gear_set: protocol.Gear,
};

/// 响应：字段按命令可选填充；`error` 非空即失败（zig 错误名）。
pub const Reply = struct {
    flag: ?u8 = null,
    rpm_raw: ?u16 = null,
    rpm: ?u16 = null,
    gear: ?u8 = null,
    @"error": ?[]const u8 = null,
};

/// 解析一行请求（不含换行）。
pub fn parseRequest(line: []const u8) error{BadRequest}!Request {
    if (std.mem.eql(u8, line, "status")) return .status;
    if (std.mem.eql(u8, line, "gear")) return .gear_get;
    if (std.mem.startsWith(u8, line, "gear ")) {
        const n = std.fmt.parseInt(u8, line["gear ".len..], 10) catch return error.BadRequest;
        return .{ .gear_set = std.meta.intToEnum(protocol.Gear, n) catch return error.BadRequest };
    }
    return error.BadRequest;
}

/// 把请求写成一行（不含换行）。
pub fn formatRequest(buf: []u8, req: Request) []const u8 {
    return switch (req) {
        .status => "status",
        .gear_get => "gear",
        .gear_set => |g| std.fmt.bufPrint(buf, "gear {d}", .{@intFromEnum(g)}) catch unreachable,
    };
}

/// daemon 侧 socket 路径：root → 系统级，否则用户级。
pub fn daemonSocketPath(buf: *[std.fs.max_path_bytes]u8) []const u8 {
    if (std.posix.geteuid() == 0) return root_path;
    return userSocketPath(buf);
}

fn userSocketPath(buf: *[std.fs.max_path_bytes]u8) []const u8 {
    return std.fmt.bufPrint(buf, "/tmp/f9d-{d}.sock", .{std.posix.geteuid()}) catch unreachable;
}

/// 客户端连接 daemon：优先系统级 socket，其次当前用户的开发 socket。
pub fn connect() !std.net.Stream {
    if (std.fs.accessAbsolute(root_path, .{})) |_| {
        return connectUnix(root_path);
    } else |_| {}
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    return connectUnix(userSocketPath(&buf));
}

fn connectUnix(path: []const u8) !std.net.Stream {
    return std.net.connectUnixSocket(path) catch |err| switch (err) {
        // 文件缺失或残留（拒绝连接）都视为 daemon 未运行
        error.FileNotFound, error.ConnectionRefused => error.DaemonNotRunning,
        else => |e| return e,
    };
}

/// 读到 '\n' 为止（返回不含换行）；超时、对端关闭、超长各自报错。
pub fn readLine(stream: std.net.Stream, buf: []u8, timeout_ms: i32) ![]const u8 {
    var n: usize = 0;
    while (true) {
        if (n == buf.len) return error.LineTooLong;
        var fds = [_]std.posix.pollfd{.{
            .fd = stream.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        if (try std.posix.poll(&fds, timeout_ms) == 0) return error.Timeout;
        const got = try stream.read(buf[n..]);
        if (got == 0) return error.EndOfStream;
        // 旧数据里不可能有 '\n'（否则已返回），只搜新读入的段
        if (std.mem.indexOfScalar(u8, buf[n..][0..got], '\n')) |i| return buf[0 .. n + i];
        n += got;
    }
}

/// 客户端调用：发请求行、等响应行、解析 JSON。
/// 返回的 Parsed 由调用方 deinit。
pub fn call(alloc: std.mem.Allocator, req: Request) !std.json.Parsed(Reply) {
    var wbuf: [max_request_len]u8 = undefined;
    const line = formatRequest(&wbuf, req);
    const stream = try connect();
    defer stream.close();
    try stream.writeAll(line);
    try stream.writeAll("\n");
    var rbuf: [max_reply_len]u8 = undefined;
    const rline = try readLine(stream, &rbuf, io_timeout_ms);
    return std.json.parseFromSlice(Reply, alloc, rline, .{ .ignore_unknown_fields = true });
}

/// 以下三个 format* 供 daemon 构造响应行（不含换行）。
pub fn formatStatus(buf: []u8, st: protocol.LiveStatus) []const u8 {
    return std.fmt.bufPrint(buf, "{{\"flag\":{d},\"rpm_raw\":{d},\"rpm\":{d}}}", .{ st.flag, st.rpm_raw, st.rpm }) catch unreachable;
}

pub fn formatGear(buf: []u8, gear: protocol.Gear) []const u8 {
    return std.fmt.bufPrint(buf, "{{\"gear\":{d}}}", .{@intFromEnum(gear)}) catch unreachable;
}

/// zig 错误名是标识符（无引号/反斜杠），可安全嵌入 JSON 字符串。
pub fn formatError(buf: []u8, err: anyerror) []const u8 {
    return std.fmt.bufPrint(buf, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch unreachable;
}

test "请求解析：合法与非法" {
    try std.testing.expectEqual(.status, try parseRequest("status"));
    try std.testing.expectEqual(.gear_get, try parseRequest("gear"));
    try std.testing.expectEqual(Request{ .gear_set = .turbo }, try parseRequest("gear 3"));
    try std.testing.expectEqual(Request{ .gear_set = .quiet }, try parseRequest("gear 0"));
    for ([_][]const u8{ "", "stats", "gear ", "gear 4", "gear -1", "gear x", "status " }) |bad| {
        try std.testing.expectError(error.BadRequest, parseRequest(bad));
    }
}

test "请求格式化与解析往返" {
    const reqs = [_]Request{ .status, .gear_get, .{ .gear_set = .beast } };
    for (reqs) |req| {
        var buf: [max_request_len]u8 = undefined;
        try std.testing.expectEqual(req, try parseRequest(formatRequest(&buf, req)));
    }
}

test "socket 路径按 euid 分支" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = daemonSocketPath(&buf);
    if (std.posix.geteuid() == 0) {
        try std.testing.expectEqualStrings(root_path, p);
    } else {
        try std.testing.expect(std.mem.startsWith(u8, p, "/tmp/f9d-"));
        try std.testing.expect(std.mem.endsWith(u8, p, ".sock"));
    }
}

test "响应行是合法 JSON 且字段齐全" {
    var buf: [max_reply_len]u8 = undefined;
    const alloc = std.testing.allocator;

    const st = formatStatus(&buf, .{ .flag = 0x02, .rpm_raw = 0x1ff4, .rpm = 2045 });
    const st_parsed = try std.json.parseFromSlice(Reply, alloc, st, .{});
    defer st_parsed.deinit();
    try std.testing.expectEqual(@as(?u8, 0x02), st_parsed.value.flag);
    try std.testing.expectEqual(@as(?u16, 0x1ff4), st_parsed.value.rpm_raw);
    try std.testing.expectEqual(@as(?u16, 2045), st_parsed.value.rpm);
    try std.testing.expectEqual(@as(?[]const u8, null), st_parsed.value.@"error");

    const g = formatGear(&buf, .balanced);
    const g_parsed = try std.json.parseFromSlice(Reply, alloc, g, .{});
    defer g_parsed.deinit();
    try std.testing.expectEqual(@as(?u8, 1), g_parsed.value.gear);

    const e = formatError(&buf, error.DeviceNotFound);
    const e_parsed = try std.json.parseFromSlice(Reply, alloc, e, .{});
    defer e_parsed.deinit();
    try std.testing.expectEqualStrings("DeviceNotFound", e_parsed.value.@"error".?);
    try std.testing.expectEqual(@as(?u8, null), e_parsed.value.flag);
}

test "readLine：分片、超时与关闭" {
    // pipe 与 socket 在 poll/read 语义上一致，足够覆盖 readLine 的读取路径
    const fds = try std.posix.pipe();
    const left: std.net.Stream = .{ .handle = fds[0] };
    const right: std.fs.File = .{ .handle = fds[1] };
    defer left.close();

    try right.writeAll("sta");
    try right.writeAll("tus\n多余字节被忽略");
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("status", try readLine(left, &buf, 1000));

    try std.testing.expectError(error.Timeout, readLine(left, &buf, 50));

    right.close();
    try std.testing.expectError(error.EndOfStream, readLine(left, &buf, 1000));
}
