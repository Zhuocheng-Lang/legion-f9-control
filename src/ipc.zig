//! f9ctl ↔ f9d 的 IPC：Unix socket 上的单行请求 / 单行 JSON 响应。
//!
//! - socket 路径：root 实例用 `/run/f9d/f9d.sock`（0666，本地用户均可连）；
//!   非 root（开发场景）用 `$XDG_RUNTIME_DIR/f9d.sock`。安全前提：该目录属主
//!   本人且权限不宽于 0700，f9d 启动前由 validateRuntimeDir 校验、不满足即拒绝
//!   启动。未设置 XDG_RUNTIME_DIR 时拒绝回退
//!   /tmp：可预测的 `/tmp/f9d-<euid>.sock` 及其 `.lock` 可被符号链接攻击，
//!   与其在公共目录里做防护，不如直接拒绝（P1 安全决策）。
//!   客户端先连系统级路径，失败（含陈旧 socket 拒连）再连当前用户路径。
//! - 请求一行（`\n` 结尾）：`status` / `gear` / `gear <0-3>`，可带尾随链路限定
//!   `usb` / `ble`（如 `status usb`、`gear 2 ble`），用于只走指定链路。
//!   请求行之后不得再有字节：多余数据一律 `TrailingData` 拒绝，不做“读一行丢其余”。
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

/// 显式限定链路（f9ctl --link）：不回落、不换链路，只走这一条。
pub const LinkKind = enum { usb, ble };

pub const Op = union(enum) {
    status,
    gear_get,
    gear_set: protocol.Gear,
};

pub const Request = struct {
    op: Op,
    link: ?LinkKind = null,
};

/// 响应：字段按命令可选填充；`error` 非空即失败（zig 错误名）。
pub const Reply = struct {
    flag: ?u8 = null,
    rpm_raw: ?u16 = null,
    rpm: ?u16 = null,
    gear: ?u8 = null,
    @"error": ?[]const u8 = null,
};

/// daemon 可能经 IPC 返回的全部错误名（线格式就是 @errorName）。
/// f9ctl 用它把名字还原成本地错误并给出专用文案；链路/协议新增错误时加在这里，
/// main.zig 的测试会逐个确认都有文案，避免退化成“f9d 返回未知错误”。
pub const wire_errors = error{
    // 设备与链路
    DeviceNotFound,
    DeviceNotResponding,
    UsbAccessDenied,
    BleAccessDenied,
    BluezUnavailable,
    GattUnsupported,
    NotConnected,
    ConnectTimeout,
    ResolveTimeout,
    InProgress,
    DbusError,
    InputOutput,
    NoDevice,
    NoSpaceLeft,
    DeviceBusy,
    FileNotFound,
    WouldBlock,
    Unexpected,
    PathTooLong,
    // 事务与协议
    Timeout,
    Busy,
    DeviceError,
    BadStatus,
    BadLength,
    BadReportId,
    BadChecksum,
    BadMagic,
    BadResponse,
    CommandMismatch,
    LengthMismatch,
    OffsetMismatch,
    ShortData,
    InvalidGear,
    GearMismatch,
    PayloadTooLong,
    // IPC
    /// 连接数超过上限时 daemon 立即回的错误（不走设备，但同样经 IPC 上线）
    ServerBusy,
    BadRequest,
    TrailingData,
    LineTooLong,
    EndOfStream,
    DaemonNotRunning,
    ConnectionRefused,
    ConnectionResetByPeer,
    BrokenPipe,
    OutOfMemory,
    DaemonError,
};

/// 解析一行请求（不含换行）。链路限定只认末尾一个独立词，其余部分按原语法严格匹配。
pub fn parseRequest(line: []const u8) error{BadRequest}!Request {
    const split = splitLink(line);
    const op: Op = if (std.mem.eql(u8, split.rest, "status"))
        .status
    else if (std.mem.eql(u8, split.rest, "gear"))
        .gear_get
    else if (std.mem.startsWith(u8, split.rest, "gear ")) blk: {
        const n = std.fmt.parseInt(u8, split.rest["gear ".len..], 10) catch return error.BadRequest;
        break :blk .{ .gear_set = std.meta.intToEnum(protocol.Gear, n) catch return error.BadRequest };
    } else return error.BadRequest;
    return .{ .op = op, .link = split.link };
}

/// 拆出末尾的链路词（`usb`/`ble`）；不是链路词时整行都算命令。
fn splitLink(line: []const u8) struct { rest: []const u8, link: ?LinkKind } {
    const i = std.mem.lastIndexOfScalar(u8, line, ' ') orelse return .{ .rest = line, .link = null };
    const link = std.meta.stringToEnum(LinkKind, line[i + 1 ..]) orelse return .{ .rest = line, .link = null };
    return .{ .rest = line[0..i], .link = link };
}

/// 把请求写成一行（不含换行）。结果总在 buf 里（不返回栈上的临时缓冲）。
pub fn formatRequest(buf: []u8, req: Request) []const u8 {
    var scratch: [max_request_len]u8 = undefined;
    const body = switch (req.op) {
        .status => "status",
        .gear_get => "gear",
        .gear_set => |g| std.fmt.bufPrint(&scratch, "gear {d}", .{@intFromEnum(g)}) catch unreachable,
    };
    if (req.link) |l| return std.fmt.bufPrint(buf, "{s} {s}", .{ body, @tagName(l) }) catch unreachable;
    @memcpy(buf[0..body.len], body);
    return buf[0..body.len];
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
    return connectTo(path);
}

/// 读到 '\n' 为止（返回不含换行）；超时、对端关闭、超长、尾随数据各自报错。
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
        if (std.mem.indexOfScalar(u8, buf[n..][0..got], '\n')) |i| {
            // 换行后同一批里还有字节，或内核已排队后续字节：都不属于“一行一请求”
            if (i + 1 < got) return error.TrailingData;
            if (try hasPending(stream)) return error.TrailingData;
            return buf[0 .. n + i];
        }
        n += got;
    }
}

/// 是否已有排队的后续字节。EOF 与对端 reset 都不算：对端写完一行就关闭是正常行为。
/// 用 poll + 读 1 字节而不是 recv(MSG_PEEK)：ipc 的读端也可能是 pipe（测试与
/// systemd socket 之外的场景），recv 对非 socket 会报 ENOTSOCK。
/// 注意它只在“本次 read 恰好止于换行”时才被调用：缓冲区大于一行时，
/// 尾随字节会和换行落在同一批里，走 readLine 里的同批判定。
/// 有数据时消费掉这 1 字节不影响语义——调用方随后会以 TrailingData 拒绝整个请求。
fn hasPending(stream: std.net.Stream) !bool {
    var fds = [_]std.posix.pollfd{.{
        .fd = stream.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    if (try std.posix.poll(&fds, 0) == 0) return false;
    var byte: [1]u8 = undefined;
    const n = stream.read(&byte) catch |err| switch (err) {
        error.WouldBlock => return false,
        // 对端 reset：我们已经拿到完整一行，且不可能再有“第二行请求”。
        // 把它当失败会让一条已经收到的响应变成“连接被重置”，
        // 也会让拒绝类响应（ServerBusy/TrailingData）在客户端变成随机失败。
        error.ConnectionResetByPeer => return false,
        else => |e| return e,
    };
    return n > 0;
}

/// 客户端调用：发请求行、等响应行、解析 JSON。返回的 Parsed 由调用方 deinit。
pub fn call(alloc: std.mem.Allocator, req: Request) !std.json.Parsed(Reply) {
    const stream = try connect();
    return callOnStream(alloc, stream, req);
}

/// 连到指定 socket 路径（f9ctl --socket / 测试用）。
pub fn callOnPath(alloc: std.mem.Allocator, path: []const u8, req: Request) !std.json.Parsed(Reply) {
    const stream = try connectTo(path);
    return callOnStream(alloc, stream, req);
}

fn callOnStream(alloc: std.mem.Allocator, stream: std.net.Stream, req: Request) !std.json.Parsed(Reply) {
    defer stream.close();
    var wbuf: [max_request_len]u8 = undefined;
    const line = formatRequest(&wbuf, req);
    try stream.writeAll(line);
    try stream.writeAll("\n");
    var rbuf: [max_reply_len]u8 = undefined;
    const rline = try readLine(stream, &rbuf, io_timeout_ms);
    return parseReply(alloc, rline);
}

/// 连接到指定路径：文件缺失/残留（拒绝连接）都视为 daemon 未运行。
pub fn connectTo(path: []const u8) !std.net.Stream {
    return std.net.connectUnixSocket(path) catch |err| switch (err) {
        error.FileNotFound, error.ConnectionRefused => error.DaemonNotRunning,
        else => |e| return e,
    };
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
    try std.testing.expectEqual(Request{ .op = .status }, try parseRequest("status"));
    try std.testing.expectEqual(Request{ .op = .gear_get }, try parseRequest("gear"));
    try std.testing.expectEqual(Request{ .op = .{ .gear_set = .turbo } }, try parseRequest("gear 3"));
    try std.testing.expectEqual(Request{ .op = .{ .gear_set = .quiet } }, try parseRequest("gear 0"));
    for ([_][]const u8{ "", "stats", "gear ", "gear 4", "gear -1", "gear x", "status ", "status  usb", "status usbx", "gear 3 turbo" }) |bad| {
        try std.testing.expectError(error.BadRequest, parseRequest(bad));
    }
}

test "请求解析/格式化：链路限定是末尾独立词，可与命令组合" {
    const cases = [_]struct { line: []const u8, req: Request }{
        .{ .line = "status usb", .req = .{ .op = .status, .link = .usb } },
        .{ .line = "status ble", .req = .{ .op = .status, .link = .ble } },
        .{ .line = "gear usb", .req = .{ .op = .gear_get, .link = .usb } },
        .{ .line = "gear 2 ble", .req = .{ .op = .{ .gear_set = .beast }, .link = .ble } },
        .{ .line = "gear 1", .req = .{ .op = .{ .gear_set = .balanced } } },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.req, try parseRequest(case.line));
        var buf: [max_request_len]u8 = undefined;
        try std.testing.expectEqualStrings(case.line, formatRequest(&buf, case.req));
        try std.testing.expectEqual(case.req, try parseRequest(formatRequest(&buf, case.req)));
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
    try right.writeAll("tus\n");
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("status", try readLine(left, &buf, 1000));

    try std.testing.expectError(error.Timeout, readLine(left, &buf, 50));

    right.close();
    try std.testing.expectError(error.EndOfStream, readLine(left, &buf, 1000));
}

test "readLine：同一次 read 里换行后还有字节 → TrailingData" {
    const fds = try std.posix.pipe();
    const left: std.net.Stream = .{ .handle = fds[0] };
    const right: std.fs.File = .{ .handle = fds[1] };
    defer left.close();
    defer right.close();

    // 缓冲区远大于一行：两个请求会落在同一次 read 里，命中的是 readLine 内部的
    // 同批判定（另一条路径由下一个测试用恰好一行的缓冲区覆盖）。
    var buf: [32]u8 = undefined;
    try right.writeAll("status\ngear\n");
    try std.testing.expectError(error.TrailingData, readLine(left, &buf, 1000));
    try std.testing.expectEqual(@as(i32, 0), try pollIdle(left)); // 未继续读走后续字节
}

test "readLine：换行处恰好读满缓冲区，排队字节经 hasPending 拒绝" {
    const fds = try std.posix.pipe();
    const left: std.net.Stream = .{ .handle = fds[0] };
    const right: std.fs.File = .{ .handle = fds[1] };
    defer left.close();
    defer right.close();

    // 缓冲区恰好等于 "status\n"（7 字节）：本次 read 止于换行且没有同批字节，
    // 尾随数据的判定只能来自 hasPending 的“另有排队字节”分支。
    try right.writeAll("status\n");
    right.writeAll("gear\n") catch return error.SkipZigTest; // 管道满等极少见场景跳过
    var buf: [7]u8 = undefined;
    try std.testing.expectError(error.TrailingData, readLine(left, &buf, 1000));
}

/// poll 一次：0 表示当前没有可读字节。
fn pollIdle(stream: std.net.Stream) !i32 {
    var fds = [_]std.posix.pollfd{.{ .fd = stream.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    return @intCast(try std.posix.poll(&fds, 0));
}

test "readLine：对端写完一行即关闭不是尾随数据" {
    const fds = try std.posix.pipe();
    const left: std.net.Stream = .{ .handle = fds[0] };
    const right: std.fs.File = .{ .handle = fds[1] };
    defer left.close();

    var buf: [32]u8 = undefined;
    try right.writeAll("status\n");
    right.close(); // EOF：hasPending 读到 0 字节，不是“有多余字节”
    try std.testing.expectEqualStrings("status", try readLine(left, &buf, 1000));
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

    const start = monoMs();
    var buf: [128]u8 = undefined; // 与上限同尺寸，确保先触发 Timeout 而非 LineTooLong
    try std.testing.expectError(error.Timeout, readLine(left, &buf, 100));
    const elapsed = monoMs() - start;
    // 下限证明遵守绝对期限；上限放宽以容忍 CI 负载，同时仍远小于“每字节续命”
    // 读完 64 字节所需的 1.28s（那种实现不会报 Timeout，而是 EndOfStream）。
    try std.testing.expect(elapsed >= 90 and elapsed < 3000);
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

test "checkTrustedDir：任意 group/other 权限位都不接受" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try tmp.dir.realpath(".", &buf);

    // 0o077 掩码逐位覆盖：多一位就足以让同机其他用户占位 socket/lock
    for ([_]std.posix.mode_t{ 0o701, 0o710, 0o750, 0o770, 0o777 }) |mode| {
        try std.posix.fchmodat(std.posix.AT.FDCWD, dir, mode, 0);
        try std.testing.expectError(error.UntrustedRuntimeDir, checkTrustedDir(dir));
    }
    for ([_]std.posix.mode_t{ 0o700, 0o500 }) |mode| {
        try std.posix.fchmodat(std.posix.AT.FDCWD, dir, mode, 0);
        try checkTrustedDir(dir);
    }
    try std.posix.fchmodat(std.posix.AT.FDCWD, dir, 0o700, 0); // 还原，便于清理
}

test "checkTrustedDir：符号链接按目标判定（指向宽权限目录即拒绝）" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &buf);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = try std.fmt.bufPrint(&path_buf, "{s}/open", .{root});
    try std.posix.mkdir(target, 0o700);
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const link = try std.fmt.bufPrint(&link_buf, "{s}/link", .{root});
    try std.posix.symlink(target, link);

    try std.posix.fchmodat(std.posix.AT.FDCWD, target, 0o700, 0);
    try checkTrustedDir(link); // 链接本身 0777，但 fstatat 跟随目标：可信
    try std.posix.fchmodat(std.posix.AT.FDCWD, target, 0o777, 0);
    try std.testing.expectError(error.UntrustedRuntimeDir, checkTrustedDir(link));

    // 悬空链接：无法判定目标，同样拒绝
    var dangling_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dangling = try std.fmt.bufPrint(&dangling_buf, "{s}/dangling", .{root});
    try std.posix.symlink("/nonexistent-f9d-target", dangling);
    try std.testing.expectError(error.UntrustedRuntimeDir, checkTrustedDir(dangling));
}

test "readLine：缓冲区写满仍无换行报 LineTooLong（恰好容纳一行时不报）" {
    const fds = try std.posix.pipe();
    const left: std.net.Stream = .{ .handle = fds[0] };
    const right: std.fs.File = .{ .handle = fds[1] };
    defer left.close();
    defer right.close();

    // 恰好容纳 "status\n"：不越界、正常返回
    try right.writeAll("status\n");
    var exact: [7]u8 = undefined;
    try std.testing.expectEqualStrings("status", try readLine(left, &exact, 1000));

    // 等长但没有换行：缓冲区被写满即报错，而不是继续等下一批字节
    try right.writeAll("statusx");
    var narrow: [7]u8 = undefined;
    try std.testing.expectError(error.LineTooLong, readLine(left, &narrow, 1000));
}

/// 造一个 <dir>/f9d.sock 路径（unix socket 路径上限 107 字节，过长则跳过）。
fn unixSocketPathForTest(dir: []const u8, buf: []u8) ![]const u8 {
    const path = try std.fmt.bufPrint(buf, "{s}/f9d.sock", .{dir});
    if (path.len >= 108) return error.SkipZigTest;
    return path;
}

test "connectTo：文件不存在与陈旧 socket 都归一为 DaemonNotRunning" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try tmp.dir.realpath(".", &dir_buf);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try unixSocketPathForTest(dir, &path_buf);

    try std.testing.expectError(error.DaemonNotRunning, connectTo(path));

    // 监听后直接关闭、保留 socket 文件：连接得到 ECONNREFUSED（死实例的典型残留）
    var listener = try (try std.net.Address.initUnix(path)).listen(.{});
    listener.deinit();
    try std.testing.expectError(error.DaemonNotRunning, connectTo(path));
}

test "wire_errors：daemon 经 IPC 上线的错误都在册，链路错误与连接上限无误漏" {
    // ServerBusy 由 daemon.spawnConn 在超过连接上限时直接回包，不经过链路层，
    // 漏在这一张表里就会让 f9ctl 显示“f9d 返回未知错误”。
    inline for ([_][]const u8{
        "ServerBusy",
        "BadRequest",
        "TrailingData",
        "LineTooLong",
        "DeviceNotFound",
        "DeviceNotResponding",
        "GearMismatch",
        "BadResponse",
    }) |name| {
        var found = false;
        inline for (@typeInfo(wire_errors).error_set.?) |e| {
            if (std.mem.eql(u8, name, e.name)) found = true;
        }
        try std.testing.expect(found);
    }
}
