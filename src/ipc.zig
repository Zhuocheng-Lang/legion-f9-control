//! f9ctl ↔ f9d 的 IPC：Unix socket 上的单行请求 / 单行 JSON 响应。
//!
//! - socket 路径：root 实例用 `/run/f9d/f9d.sock`（0666，本地用户均可连）；
//!   非 root（开发场景）用 `$XDG_RUNTIME_DIR/f9d.sock`。安全前提：该目录属主
//!   本人且权限不宽于 0700，f9d 启动前由 validateRuntimeDir 校验、不满足即拒绝
//!   启动。未设置 XDG_RUNTIME_DIR 时拒绝回退
//!   /tmp：可预测的 `/tmp/f9d-<euid>.sock` 及其 `.lock` 可被符号链接攻击，
//!   与其在公共目录里做防护，不如直接拒绝（P1 安全决策）。
//!   客户端先连系统级路径，失败（含陈旧 socket 拒连）再连当前用户路径。
//! - 请求一行（`\n` 结尾）：`status` / `gear` / `gear <0-3>`。
//! - 响应一行 JSON：成功 `{"flag":…,"rpm_raw":…,"rpm":…}` 或 `{"gear":…}`；
//!   失败 `{"error":"<zig 错误名>"}`。错误名即线格式，展示文案归 f9ctl。

const std = @import("std");
const protocol = @import("protocol.zig");
// 单调期限与 ble.zig 同源：墙钟回拨不放大 remaining，35s 慢滴上界始终成立
const monoMs = @import("root.zig").monoMs;

pub const root_dir = "/run/f9d";
pub const root_path = root_dir ++ "/f9d.sock";

pub const max_request_len = 128;
pub const max_reply_len = 256;
/// 客户端等响应的上限。预算：USB 链路 gear set 最多 5 次事务（open/read/write/
/// close + 回读）× 2s = 10s；BLE 链路单个请求含打开与失败收尾不超过 30s
/// （见 ble.zig 的 request_budget_ms），故取 35s 留出调度余量。
pub const io_timeout_ms = 35_000;

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
pub fn daemonSocketPath(buf: *[std.fs.max_path_bytes]u8) ![]const u8 {
    if (std.posix.geteuid() == 0) return root_path;
    return userSocketPath(buf);
}

/// XDG_RUNTIME_DIR 由登录会话创建（0700、属主本人），天然防 /tmp 占位；
/// 未设置时报 NoRuntimeDir——可预测的 /tmp 路径会被符号链接攻击，拒绝回退。
/// 拼接过长报 PathTooLong（该 env 由用户控制、可超长），不 panic。
/// 该前提由 f9d 启动前的 validateRuntimeDir 实际校验，这里只负责拼路径。
pub fn userSocketPath(buf: *[std.fs.max_path_bytes]u8) error{ NoRuntimeDir, PathTooLong }![]const u8 {
    const dir = std.posix.getenv("XDG_RUNTIME_DIR") orelse return error.NoRuntimeDir;
    if (dir.len == 0) return error.NoRuntimeDir; // 空串视为未设置：拒绝回退 /tmp
    return socketPathIn(dir, buf);
}

/// 与读环境变量分离仅为可测：`<dir>/f9d.sock` 拼不进固定缓冲时报 PathTooLong。
fn socketPathIn(dir: []const u8, buf: *[std.fs.max_path_bytes]u8) error{PathTooLong}![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/f9d.sock", .{dir}) catch return error.PathTooLong;
}

/// 非 root f9d 启动前的安全前提：XDG_RUNTIME_DIR 指向的目录必须属主本人、
/// 权限不宽于 0700，否则 socket/lock 仍可被同机其他用户占位干扰。
pub fn validateRuntimeDir() error{UntrustedRuntimeDir}!void {
    const dir = std.posix.getenv("XDG_RUNTIME_DIR") orelse return error.UntrustedRuntimeDir;
    if (dir.len == 0) return error.UntrustedRuntimeDir;
    return checkTrustedDir(dir);
}

/// 与读环境变量分离出来仅为可测。fstatat 跟随符号链接：链到 /tmp 一样被拒。
fn checkTrustedDir(dir: []const u8) error{UntrustedRuntimeDir}!void {
    const st = std.posix.fstatat(std.posix.AT.FDCWD, dir, 0) catch return error.UntrustedRuntimeDir;
    if (st.mode & std.posix.S.IFMT != std.posix.S.IFDIR) return error.UntrustedRuntimeDir;
    if (st.uid != std.posix.geteuid()) return error.UntrustedRuntimeDir;
    if (st.mode & 0o077 != 0) return error.UntrustedRuntimeDir;
}

/// 客户端连接 daemon：优先系统级 socket，其次当前用户的开发 socket。
pub fn connect() !std.net.Stream {
    if (std.fs.accessAbsolute(root_path, .{})) |_| {
        // 系统级 socket 存在但拒绝连接（陈旧文件）时仍回退用户级
        return connectUnix(root_path) catch |err| switch (err) {
            error.DaemonNotRunning => connectUser(),
            else => |e| return e,
        };
    } else |_| {}
    return connectUser();
}

fn connectUser() !std.net.Stream {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    // 无 XDG_RUNTIME_DIR 时 daemon 同样拒绝启动，直接报未运行
    const path = userSocketPath(&buf) catch return error.DaemonNotRunning;
    return connectUnix(path);
}

fn connectUnix(path: []const u8) !std.net.Stream {
    return std.net.connectUnixSocket(path) catch |err| switch (err) {
        // 文件缺失或残留（拒绝连接）都视为 daemon 未运行
        error.FileNotFound, error.ConnectionRefused => error.DaemonNotRunning,
        else => |e| return e,
    };
}

/// 读到 '\n' 为止（返回不含换行）；超时、对端关闭、超长各自报错。
/// timeout_ms 是进入函数起的绝对上限，防止逐字节慢滴无限续命。
/// 期限基于单调时钟（root.monoMs）：墙钟调整不会改变剩余时间。
pub fn readLine(stream: std.net.Stream, buf: []u8, timeout_ms: i32) ![]const u8 {
    const deadline = monoMs() + timeout_ms;
    var n: usize = 0;
    while (true) {
        if (n == buf.len) return error.LineTooLong;
        var fds = [_]std.posix.pollfd{.{
            .fd = stream.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const remaining = deadline - monoMs();
        if (remaining <= 0) return error.Timeout;
        if (try std.posix.poll(&fds, @intCast(@min(remaining, std.math.maxInt(i32)))) == 0)
            return error.Timeout;
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
    return parseReply(alloc, rline);
}

fn parseReply(alloc: std.mem.Allocator, line: []const u8) !std.json.Parsed(Reply) {
    // alloc_always：默认的 alloc_if_needed 会让无转义字符串借用源切片，
    // 而源是 call() 栈上的 rbuf，返回后 Reply."error" 悬垂
    return std.json.parseFromSlice(Reply, alloc, line, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
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
    if (std.posix.geteuid() == 0) {
        try std.testing.expectEqualStrings(root_path, try daemonSocketPath(&buf));
    } else if (std.posix.getenv("XDG_RUNTIME_DIR")) |dir| {
        if (dir.len > 0) {
            var expect_buf: [std.fs.max_path_bytes]u8 = undefined;
            const expect = std.fmt.bufPrint(&expect_buf, "{s}/f9d.sock", .{dir}) catch unreachable;
            return std.testing.expectEqualStrings(expect, try daemonSocketPath(&buf));
        }
        // 空字符串视为未设置：拒绝回退 /tmp
        try std.testing.expectError(error.NoRuntimeDir, daemonSocketPath(&buf));
        try std.testing.expectError(error.NoRuntimeDir, userSocketPath(&buf));
    } else {
        // 无 XDG_RUNTIME_DIR：拒绝回退 /tmp（可预测路径有符号链接攻击风险）
        try std.testing.expectError(error.NoRuntimeDir, daemonSocketPath(&buf));
        try std.testing.expectError(error.NoRuntimeDir, userSocketPath(&buf));
    }
}

test "socket 路径拼接过长报 PathTooLong（XDG_RUNTIME_DIR 可超长）" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var dir: [std.fs.max_path_bytes]u8 = undefined;
    @memset(&dir, 'a'); // 满长目录名 + "/f9d.sock" 必然放不下
    try std.testing.expectError(error.PathTooLong, socketPathIn(&dir, &buf));
    try std.testing.expectEqualStrings("/run/f9d/f9d.sock", try socketPathIn("/run/f9d", &buf));
}

test "parseReply：无转义字符串不借用源缓冲" {
    const alloc = std.testing.allocator;
    const line = "{\"error\":\"DeviceNotFound\"}";
    const parsed = try parseReply(alloc, line);
    defer parsed.deinit();
    const name = parsed.value.@"error".?;
    try std.testing.expectEqualStrings("DeviceNotFound", name);
    // 源缓冲（调用方栈上）失效后内容仍须有效：指针不得落在源切片内
    const src = @intFromPtr(line.ptr);
    const dst = @intFromPtr(name.ptr);
    try std.testing.expect(dst < src or dst >= src + line.len);
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

test "readLine：绝对超时，慢滴不能续命" {
    const fds = try std.posix.pipe();
    const left: std.net.Stream = .{ .handle = fds[0] };
    const right: std.fs.File = .{ .handle = fds[1] };
    defer left.close();

    // 每 20ms 滴一个字节；若每轮 poll 重新计时则永不超时（直至写满 LineTooLong）
    const drip = std.Thread.spawn(.{}, struct {
        fn run(f: std.fs.File) void {
            defer f.close();
            for (0..64) |_| {
                std.Thread.sleep(20 * std.time.ns_per_ms);
                f.writeAll("x") catch return;
            }
        }
    }.run, .{right}) catch unreachable;
    defer drip.join();

    const start = std.time.milliTimestamp();
    var buf: [128]u8 = undefined; // 与上限同尺寸，确保先触发 Timeout 而非 LineTooLong
    try std.testing.expectError(error.Timeout, readLine(left, &buf, 100));
    const elapsed = std.time.milliTimestamp() - start;
    try std.testing.expect(elapsed >= 100 and elapsed < 1000);
}

test "checkTrustedDir：属主本人且权限不宽于 0700 才接受" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try tmp.dir.realpath(".", &buf);

    // tmpDir 句柄是 O_PATH，Dir.chmod 走 fchmod 会 EBADF，只能按路径 fchmodat
    try std.posix.fchmodat(std.posix.AT.FDCWD, dir, 0o700, 0);
    try checkTrustedDir(dir); // 属主本人 + 0700：接受
    try std.posix.fchmodat(std.posix.AT.FDCWD, dir, 0o755, 0);
    try std.testing.expectError(error.UntrustedRuntimeDir, checkTrustedDir(dir)); // 他人可读：拒绝

    try tmp.dir.writeFile(.{ .sub_path = "f", .data = "" });
    const file = try tmp.dir.realpath("f", &buf);
    try std.testing.expectError(error.UntrustedRuntimeDir, checkTrustedDir(file)); // 非目录：拒绝
    try std.testing.expectError(error.UntrustedRuntimeDir, checkTrustedDir("/nonexistent-f9d-path"));
}
