//! BLE 链路：20 字节帧编解码（纯函数）+ Linux BlueZ 事务（sd-bus C ABI）。
//!
//! 帧（spec §3）：请求定长 20 字节；响应变长 = 5 字节头 + length 字节数据。
//! ```text
//! request:  [0]=0xee [1]=command [2]=length [3:4]=offset LE [5:20]=payload（定长 20，尾部补零）
//! response: [0]=0xee [1]=command [2]=length [3:4]=offset LE [5:5+length]=data（总长恰为 5+length）
//! ```
//! - 单帧 payload 上限 15 字节；无 USB 式校验和；响应 `[7]` 是数据，不是状态码。
//! - 响应不是定长 20：真机 confirmed（读 3 字节 → 通知共 8 字节），填零填充帧一律拒绝。
//! - 会话命令 `0x01`/`0x02` 只等 GATT 写完成，不等通知；其他命令必须等到匹配通知。
//!
//! 设备发现：服务 UUID 为主、名称 `LEGION_F9_BT` 为辅；名称只用于候选筛选，
//! 连接后仍按服务/特征 UUID 与 flags 复核，不按地址或对象路径硬编码。
//!
//! 期限：扫描、连接/服务解析、每次写入与通知等待都用单调时钟的绝对期限，
//! 单个 IPC 请求（含失败时会话收尾）不超过 request_budget_ms；sd-bus 调用
//! 一律显式传超时，不依赖默认值。

const std = @import("std");
const protocol = @import("protocol.zig");
// root ↔ ble 文件引用由 Zig 惰性分析支持；期限与日志同 f9d/ipc 共用一份
const monoMs = @import("root.zig").monoMs;
const log = @import("root.zig").log;

const c = @cImport({
    @cInclude("systemd/sd-bus.h");
});

/// 请求头字节（spec §3）。
pub const magic: u8 = 0xee;
/// BLE 帧固定 20 字节，payload 上限 15 字节。
pub const frame_len = 20;
pub const max_payload = 15;

/// 设备标识（spec §1）。UUID 与名称用于发现与复核，不是认证。
const device_name: [:0]const u8 = "LEGION_F9_BT";
const service_uuid: [:0]const u8 = "19090909-0a0a-0b0b-0c0c-0d0d0e0e0f0f";
const write_uuid: [:0]const u8 = "19190909-0a0a-0b0b-0c0c-0d0d0e0e0f0f";
const notify_uuid: [:0]const u8 = "19290909-0a0a-0b0b-0c0c-0d0d0e0e0f0f";

const service_name: [:0]const u8 = "org.bluez";
const adapter_iface: [:0]const u8 = "org.bluez.Adapter1";
const device_iface: [:0]const u8 = "org.bluez.Device1";
const gatt_service_iface: [:0]const u8 = "org.bluez.GattService1";
const char_iface: [:0]const u8 = "org.bluez.GattCharacteristic1";
const props_iface: [:0]const u8 = "org.freedesktop.DBus.Properties";
const objmgr_iface: [:0]const u8 = "org.freedesktop.DBus.ObjectManager";

/// 链路打开（扫描 + 连接 + 服务解析 + StartNotify）的期限。
const open_timeout_ms = 12_000;
/// 单次 GATT 写或通知等待的期限（整请求预算仍是硬上限）。
const op_timeout_ms = 5_000;
/// 单个 IPC 请求的绝对预算：含链路打开与失败时的会话收尾。
const request_budget_ms = 30_000;
/// 扫描 / 等服务解析的轮询间隔。
const scan_poll_ms = 250;
const resolve_poll_ms = 200;
/// 对象路径缓冲上限（BlueZ 特征路径约 60 字节）。
const path_max = 192;

/// 本模块对外错误集：帧层 + 链路层。
/// 链路层错误都可在限定时间内给出，且互相可区分（设备缺失 / BlueZ 缺失 / 权限 /
/// 未连接 / GATT 不支持 / 超时）。
pub const Error = error{
    // 帧层
    PayloadTooLong,
    BadLength,
    BadMagic,
    CommandMismatch,
    LengthMismatch,
    OffsetMismatch,
    // 链路层
    BluezUnavailable,
    DeviceNotFound,
    GattUnsupported,
    AccessDenied,
    NotConnected,
    InProgress,
    DbusError,
    Timeout,
};

// ---------------------------------------------------------------------------
// 纯帧逻辑（无 I/O，可直接测试）
// ---------------------------------------------------------------------------

/// 读请求：`length` = 期望读回的字节数，payload 补零。
pub fn encodeRead(buf: *[frame_len]u8, command: protocol.Command, offset: u16, len: u8) Error!void {
    if (len > max_payload) return error.PayloadTooLong;
    encode(buf, command, offset, len, &[_]u8{});
}

/// 写请求：`length` = payload 长度，payload 右侧补零。
pub fn encodeWrite(buf: *[frame_len]u8, command: protocol.Command, offset: u16, payload: []const u8) Error!void {
    if (payload.len > max_payload) return error.PayloadTooLong;
    encode(buf, command, offset, @intCast(payload.len), payload);
}

/// 会话请求：open / close 各随 1 字节标记（0x01 / 0x02），offset=0、length=1。
pub fn encodeSession(buf: *[frame_len]u8, open: bool) Error!void {
    const marker = [1]u8{if (open) 0x01 else 0x02};
    encode(buf, if (open) .session_open else .session_close, 0, 1, &marker);
}

/// 解码响应帧：变长，总长必须恰为 5+length（spec §3 confirmed）。校验 0xee、
/// 命令、声明长度（≤15 且与本次预期一致）与 offset，然后拷出前 `length` 字节。
/// 注意：`raw[7]` 是数据字节（可为 0xfe/0xff），不参与判错。
pub fn decodeResponse(raw: []const u8, command: protocol.Command, offset: u16, len: u8) Error!protocol.Decoded {
    if (raw.len < 5) return error.BadLength;
    if (raw[0] != magic) return error.BadMagic;
    if (raw[2] > max_payload) return error.BadLength;
    if (raw.len != 5 + @as(usize, raw[2])) return error.BadLength; // 变长帧：无填充
    if (raw[1] != @intFromEnum(command)) return error.CommandMismatch;
    if (raw[2] != len) return error.LengthMismatch;
    const got = @as(u16, raw[3]) | (@as(u16, raw[4]) << 8);
    if (got != offset) return error.OffsetMismatch;
    var out: protocol.Decoded = .{ .offset = offset, .buf = undefined, .len = len };
    @memcpy(out.buf[0..len], raw[5..][0..len]);
    return out;
}

fn encode(buf: *[frame_len]u8, command: protocol.Command, offset: u16, len: u8, payload: []const u8) void {
    @memset(buf, 0);
    buf[0] = magic;
    buf[1] = @intFromEnum(command);
    buf[2] = len;
    std.mem.writeInt(u16, buf[3..5], offset, .little);
    @memcpy(buf[5..][0..payload.len], payload);
}

fn isSession(command: protocol.Command) bool {
    return command == .session_open or command == .session_close;
}

/// 一次 BLE 事务。`g` 提供四个原语（真实实现见 Device，测试用 fake 隔离 I/O）：
/// beginNotify/endNotify 安装与释放通知订阅，writeFrame 写一帧，nextFrame 等下一帧。
/// - 会话命令只等 GATT 写完成；
/// - 其他命令必须等到命令/长度/offset 都匹配的通知才算完成；
/// - 其他命令的旧通知丢弃后继续等，结构性坏帧（头/长度非法）立即失败。
fn transact(g: anytype, command: protocol.Command, offset: u16, expect_len: u8, req: *const [frame_len]u8) Error!protocol.Decoded {
    if (isSession(command)) {
        try g.writeFrame(req);
        return .{ .offset = offset, .buf = undefined, .len = 0 };
    }
    try g.beginNotify();
    defer g.endNotify();
    try g.writeFrame(req);
    while (true) {
        const raw = try g.nextFrame();
        return decodeResponse(raw, command, offset, expect_len) catch |err| switch (err) {
            error.CommandMismatch, error.LengthMismatch, error.OffsetMismatch => continue,
            else => |e| return e,
        };
    }
}

// ---------------------------------------------------------------------------
// BlueZ（sd-bus）
// ---------------------------------------------------------------------------

/// 固定缓冲字符串：既用于比较，也用于 D-Bus 的 `const char *` 参数（带结尾 0）。
const Str = struct {
    buf: [path_max]u8 = [_]u8{0} ** path_max,
    len: usize = 0,

    fn slice(self: *const Str) []const u8 {
        return self.buf[0..self.len];
    }

    /// NUL 结尾视图（D-Bus 参数用）。
    fn z(self: *const Str) [:0]const u8 {
        return self.buf[0..self.len :0];
    }

    fn set(self: *Str, s: []const u8) Error!void {
        if (s.len >= self.buf.len) return error.DbusError; // 超长不截断，直接报错
        @memcpy(self.buf[0..s.len], s);
        self.buf[s.len] = 0;
        self.len = s.len;
    }
};

/// 消息内字节数组视图（仅在该消息 unref 前有效）。
const Bytes = struct {
    ptr: [*]const u8 = undefined,
    len: usize = 0,
};

/// 从 `a{sv}` 属性字典里挑出本协议需要的少量字段；未建模的键整段跳过。
/// 字符串值拷入固定缓冲（不借用消息生命周期），列表值只判命中、不收集整表。
const Props = struct {
    uuid: Str = .{},
    service: Str = .{},
    name: Str = .{},
    alias: Str = .{},
    services_resolved: ?bool = null,
    uuid_hit: bool = false, // UUIDs 含目标服务 UUID
    flag_write: bool = false, // Flags 含 write（write-with-response）
    flag_notify: bool = false, // Flags 含 notify
    value: Bytes = .{},
};

/// 通知回调用状态：一次事务内有效，由 beginNotify 重置并注册。
const NotifyCtx = struct {
    path: Str = .{}, // 目标通知特征路径：只采纳来自它的通知
    buf: [frame_len]u8 = undefined,
    len: usize = 0,
    have: bool = false,
};

pub const Device = struct {
    bus: *c.sd_bus,
    write_path: Str,
    notify_path: Str,
    notify: NotifyCtx = .{},
    slot: ?*c.sd_bus_slot = null,
    budget_ms: i64 = 0,

    /// 发现并连接设备：适配器 → 候选设备（必要时有上限地扫描）→ Connect →
    /// ServicesResolved → 按 UUID/服务/flags 复核写与通知特征 → StartNotify。
    pub fn open() Error!Device {
        // 整请求预算从打开入口起算：扫描/连接/服务解析都花在同一份预算里，
        // 保证 f9d 侧 打开+请求 ≤ request_budget_ms（小于 f9ctl 的 IPC 超时）。
        const budget_ms = monoMs() + request_budget_ms;
        var bus: ?*c.sd_bus = null;
        const r = c.sd_bus_open_system(&bus);
        if (r < 0) return openBusError(r);
        const bus_ptr = bus orelse return error.BluezUnavailable;
        errdefer _ = c.sd_bus_flush_close_unref(bus_ptr);

        const deadline = monoMs() + open_timeout_ms;

        // 适配器：BlueZ 在跑且蓝牙启用时才有 org.bluez.Adapter1 对象
        var adapter: Str = .{};
        if (!try find(bus_ptr, &FindAdapter{ .out = &adapter }, deadline)) return error.BluezUnavailable;

        // 已知对象里先找；找不到才开一次扫描（扫描有上限）。
        // 他方已在扫描时 startDiscovery 得 false：只随其扫描结果轮询，不重复发
        // StartDiscovery，退出时也不停止别人的会话。
        var dev: Str = .{};
        var found = try find(bus_ptr, &FindDevice{ .out = &dev }, deadline);
        var scanning = false;
        if (!found) scanning = try startDiscovery(bus_ptr, adapter.z(), deadline);
        while (!found and monoMs() < deadline) {
            std.Thread.sleep(scan_poll_ms * std.time.ns_per_ms);
            found = try find(bus_ptr, &FindDevice{ .out = &dev }, deadline);
        }
        // 只停止自己开启的扫描
        if (scanning) stopDiscovery(bus_ptr, adapter.z(), deadline) catch |err| {
            log("f9d: 停止 LE 扫描失败: {s}", .{@errorName(err)});
        };
        if (!found) {
            log("f9d: 未发现 BLE 设备（服务 UUID 或名称 LEGION_F9_BT）", .{});
            return error.DeviceNotFound;
        }

        // 上部连接可能还活着：Connected 为真就不重复 Connect。
        // Connect 报 InProgress 说明他方正在连接：不算失败，交给 ServicesResolved 等待。
        const connected = getBoolProp(bus_ptr, dev.z(), device_iface, "Connected", deadline) catch false;
        if (!connected) callSimple(bus_ptr, dev.z(), device_iface, "Connect", deadline) catch |err| switch (err) {
            error.InProgress => {},
            // Connect 剩到 DbusError 的实测就是 org.bluez.Error.Failed（设备断电/远离
            // 无法接通）：报 NotConnected 比笼统的 DbusError 更可操作。
            error.DbusError => return error.NotConnected,
            else => |e| return e,
        };
        try waitResolved(bus_ptr, dev.z(), deadline);

        // 服务/特征在连接并解析后才出现；UUID、所属服务与必需的 flags 都要对得上
        var service: Str = .{};
        if (!try find(bus_ptr, &FindService{ .out = &service }, deadline)) return error.GattUnsupported;
        var wchar: Str = .{};
        const wfind = FindCharacteristic{ .out = &wchar, .uuid = write_uuid, .service = service.z(), .flag = .write };
        if (!try find(bus_ptr, &wfind, deadline)) return error.GattUnsupported;
        var nchar: Str = .{};
        const nfind = FindCharacteristic{ .out = &nchar, .uuid = notify_uuid, .service = service.z(), .flag = .notify };
        if (!try find(bus_ptr, &nfind, deadline)) return error.GattUnsupported;

        // GATT 通知开一次；PropertiesChanged 订阅按事务装/卸（见 beginNotify）
        try callSimple(bus_ptr, nchar.z(), char_iface, "StartNotify", deadline);

        log("f9d: BLE 设备已连接", .{});
        return .{
            .bus = bus_ptr,
            .write_path = wchar,
            .notify_path = nchar,
            .budget_ms = budget_ms,
        };
    }

    /// 释放通知订阅与 D-Bus 连接（BlueZ 侧随连接关闭清理自己的订阅状态）。
    pub fn close(self: *Device) void {
        self.endNotify();
        _ = c.sd_bus_flush_close_unref(self.bus);
    }

    /// 复用链路的请求开始：重置整请求预算（上个请求的可能已耗尽）。
    /// 新打开的链路不调用：预算已从 open() 入口起算，重置会放宽到打开之后。
    /// ops 只依赖 read/write/session 三个语义操作，不依赖它。
    pub fn beginRequest(self: *Device) void {
        self.budget_ms = monoMs() + request_budget_ms;
    }

    /// 读命令：发读请求 → 等匹配通知。
    pub fn read(self: *Device, command: protocol.Command, offset: u16, len: u8) Error!protocol.Decoded {
        var req: [frame_len]u8 = undefined;
        try encodeRead(&req, command, offset, len);
        return transact(self, command, offset, len, &req);
    }

    /// 写命令：发写请求 → 等匹配通知。
    pub fn write(self: *Device, command: protocol.Command, offset: u16, payload: []const u8) Error!void {
        var req: [frame_len]u8 = undefined;
        try encodeWrite(&req, command, offset, payload);
        _ = try transact(self, command, offset, @intCast(payload.len), &req);
    }

    /// 会话命令：只推进 GATT 写完成，不等通知。
    pub fn session(self: *Device, is_open: bool) Error!void {
        var req: [frame_len]u8 = undefined;
        try encodeSession(&req, is_open);
        _ = try transact(self, if (is_open) .session_open else .session_close, 0, 0, &req);
    }

    // ---- transact 的四个 GATT 原语 ----

    /// 安装本次事务的通知订阅；必须在写请求之前调用，否则会漏掉设备回复。
    fn beginNotify(self: *Device) Error!void {
        self.endNotify();
        self.notify = .{};
        try self.notify.path.set(self.notify_path.slice());
        var rule_buf: [512]u8 = undefined;
        const rule = std.fmt.bufPrintZ(
            &rule_buf,
            "type='signal',sender='{s}',path='{s}',interface='{s}',member='PropertiesChanged',arg0='{s}'",
            .{ service_name, self.notify_path.slice(), props_iface, char_iface },
        ) catch return error.DbusError;
        var slot: ?*c.sd_bus_slot = null;
        try check(c.sd_bus_add_match(self.bus, &slot, rule.ptr, onNotify, @ptrCast(&self.notify)));
        self.slot = slot;
    }

    fn endNotify(self: *Device) void {
        if (self.slot) |s| _ = c.sd_bus_slot_unref(s);
        self.slot = null;
    }

    /// 写特征：WriteValue(value, {type:"request"})，返回即 GATT 写完成。
    /// 显式要求 write-with-response；不支持就报错，绝不退化为无响应写。
    fn writeFrame(self: *Device, raw: []const u8) Error!void {
        const m = try newCall(self.bus, self.write_path.z(), char_iface, "WriteValue");
        defer _ = c.sd_bus_message_unref(m);
        try check(c.sd_bus_message_append_array(m, 'y', raw.ptr, raw.len));
        // dict entry 的 contents 不带花括号（带括号 sd-bus 会拒为 EINVAL）
        try openC(m, 'a', "{sv}");
        try openC(m, 'e', "sv");
        try appendStr(m, "type");
        try openC(m, 'v', "s");
        try appendStr(m, "request");
        closeC(m); // v
        closeC(m); // e
        closeC(m); // a
        const reply = try callBus(self.bus, m, self.opDeadline());
        _ = c.sd_bus_message_unref(reply);
    }

    /// 等到一帧通知（有界）。只有目标特征的 Value 会被回调采纳。
    fn nextFrame(self: *Device) Error![]const u8 {
        const deadline = self.opDeadline();
        while (true) {
            if (monoMs() >= deadline) return error.Timeout;
            const r = c.sd_bus_process(self.bus, null);
            if (r < 0) return error.DbusError;
            if (self.notify.have) {
                self.notify.have = false;
                // 通知最长 20 字节：超长在这里就挡住（变长形状由 decodeResponse 判）
                if (self.notify.len > frame_len) return error.BadLength;
                return self.notify.buf[0..self.notify.len];
            }
            if (r > 0) continue;
            const w = c.sd_bus_wait(self.bus, remainingUsec(deadline));
            if (w < 0) return error.DbusError;
        }
    }

    /// 单个操作（一次写或一次通知等待）的绝对期限：整请求预算与 op_timeout 取小。
    /// 预算已过期时期限落在过去，调用处立即超时——预算是硬上限，不续期。
    fn opDeadline(self: *Device) i64 {
        return @min(self.budget_ms, monoMs() + op_timeout_ms);
    }
};

/// PropertiesChanged 回调：只采纳目标特征 Value(ay) 的原始字节。
/// match 回调里消息由 sd-bus 持有：只读、不 unref；坏内容交给事务层判定。
fn onNotify(m: ?*c.sd_bus_message, userdata: ?*anyopaque, ret_error: ?*c.sd_bus_error) callconv(.c) c_int {
    _ = ret_error;
    const msg = m orelse return 0;
    const ctx: *NotifyCtx = @ptrCast(@alignCast(userdata orelse return 0));
    if (c.sd_bus_message_is_signal(msg, props_iface, "PropertiesChanged") <= 0) return 0;
    const path = c.sd_bus_message_get_path(msg);
    if (path == null or !std.mem.eql(u8, std.mem.span(path), ctx.path.slice())) return 0;
    readChangedValue(msg, ctx) catch {};
    return 0;
}

/// 从 PropertiesChanged(sa{sv}as) 取出 Value(ay)；其他接口/属性忽略。
fn readChangedValue(m: *c.sd_bus_message, ctx: *NotifyCtx) Error!void {
    // 信号首参是普通字符串，不是容器：直接读
    if (!std.mem.eql(u8, try readString(m, 's'), char_iface)) return;
    try enter(m, 'a', "{sv}");
    defer exitC(m);
    while (!try atEnd(m)) {
        try enter(m, 'e', null);
        defer exitC(m);
        const key = try readString(m, 's');
        if (!std.mem.eql(u8, key, "Value")) {
            try skipValue(m);
            continue;
        }
        var bytes: Bytes = .{};
        try variantBytes(m, &bytes);
        adoptValue(ctx, bytes);
    }
}

/// 采纳 Value 字节到通知上下文。空值不构成响应帧，不置 have、继续等真响应：
/// 空 `ay` 与非 `ay`（variantBytes 跳过后 bytes 保持为空）若置位，transact 会收到
/// 0 字节帧，被 decodeResponse 判为结构性坏帧（BadLength）直接判死整个事务。
fn adoptValue(ctx: *NotifyCtx, bytes: Bytes) void {
    if (bytes.len == 0) return;
    ctx.len = bytes.len;
    const n = @min(bytes.len, ctx.buf.len);
    @memcpy(ctx.buf[0..n], bytes.ptr[0..n]);
    ctx.have = true;
}

// ---- 对象枚举：GetManagedObjects 的 a{oa{sa{sv}}} ----

/// 取一次 GetManagedObjects 交给 visitor 找目标；命中即提前结束。
fn find(bus: *c.sd_bus, ctx: anytype, deadline_ms: i64) Error!bool {
    const m = try newCall(bus, "/", objmgr_iface, "GetManagedObjects");
    defer _ = c.sd_bus_message_unref(m);
    const reply = try callBus(bus, m, deadline_ms);
    defer _ = c.sd_bus_message_unref(reply);
    return walkObjects(reply, ctx);
}

/// 遍历每个 (对象路径, 接口名, 属性) 调用 `ctx.visit`；返回 true 表示已找到。
fn walkObjects(m: *c.sd_bus_message, ctx: anytype) Error!bool {
    try enter(m, 'a', "{oa{sa{sv}}}");
    defer exitC(m);
    while (!try atEnd(m)) {
        try enter(m, 'e', null);
        defer exitC(m);
        var path: Str = .{};
        try readInto(m, 'o', &path);
        try enter(m, 'a', "{sa{sv}}");
        defer exitC(m);
        while (!try atEnd(m)) {
            try enter(m, 'e', null);
            defer exitC(m);
            var iface: Str = .{};
            try readInto(m, 's', &iface);
            var props: Props = .{};
            try parseProps(m, &props);
            if (try ctx.visit(path.slice(), iface.slice(), &props)) return true;
        }
    }
    return false;
}

/// 消费一个 `a{sv}` 属性字典；只提取下列字段，其余跳过。
fn parseProps(m: *c.sd_bus_message, p: *Props) Error!void {
    try enter(m, 'a', "{sv}");
    defer exitC(m);
    while (!try atEnd(m)) {
        try enter(m, 'e', null);
        defer exitC(m);
        const key = try readString(m, 's');

        // 不 peek：变体一律按期望签名 enter（签名不符时游标不动，可安全跳过）
        if (std.mem.eql(u8, key, "UUIDs")) {
            var hits = [_]bool{false};
            try variantListHits(m, &.{service_uuid}, &hits);
            p.uuid_hit = hits[0];
        } else if (std.mem.eql(u8, key, "Flags")) {
            var hits = [_]bool{ false, false };
            try variantListHits(m, &.{ "write", "notify" }, &hits);
            p.flag_write = hits[0];
            p.flag_notify = hits[1];
        } else if (std.mem.eql(u8, key, "UUID")) {
            try variantString(m, "s", 's', &p.uuid);
        } else if (std.mem.eql(u8, key, "Service")) {
            try variantString(m, "o", 'o', &p.service); // GattCharacteristic1.Service 是对象路径
        } else if (std.mem.eql(u8, key, "Name")) {
            try variantString(m, "s", 's', &p.name);
        } else if (std.mem.eql(u8, key, "Alias")) {
            try variantString(m, "s", 's', &p.alias);
        } else if (std.mem.eql(u8, key, "ServicesResolved")) {
            var b = false;
            try variantBool(m, &b);
            p.services_resolved = b;
        } else if (std.mem.eql(u8, key, "Value")) {
            try variantBytes(m, &p.value);
        } else try skipValue(m);
    }
}

/// 跳过当前一个完整类型（variant 内即它的内容）。
fn skipValue(m: *c.sd_bus_message) Error!void {
    try check(c.sd_bus_message_skip(m, null));
}

/// 进入 variant 的内容（类型与 contents 相符时）。
/// 返回 false 表示当前值不是期望类型：游标未动，调用方用 skipValue 跳过整个值。
/// 字符串/布尔是基本类型，不能当容器 enter；数组则由各自 helper 进入。
fn variantEnter(m: *c.sd_bus_message, contents: [:0]const u8) Error!bool {
    const r = c.sd_bus_message_enter_container(m, 'v', contents);
    if (r == 0) return false;
    if (r < 0) {
        // -ENXIO：此处没有该类型的容器（对我们就是“类型不符”）
        if (r == -@as(c_int, @intCast(@intFromEnum(std.posix.E.NXIO)))) return false;
        return error.DbusError;
    }
    return true;
}

/// variant 内的字符串/对象路径值（contents 与 typ 对应："s"/'s' 或 "o"/'o'）。
fn variantString(m: *c.sd_bus_message, contents: [:0]const u8, typ: u8, out: *Str) Error!void {
    if (try variantEnter(m, contents)) {
        defer exitC(m);
        try readInto(m, typ, out);
    } else try skipValue(m);
}

/// variant 内的布尔值；类型不符时保持 out 不变。
fn variantBool(m: *c.sd_bus_message, out: *bool) Error!void {
    if (try variantEnter(m, "b")) {
        defer exitC(m);
        var b: c_int = 0;
        try check(c.sd_bus_message_read_basic(m, 'b', @ptrCast(&b)));
        out.* = b != 0;
    } else try skipValue(m);
}

/// variant 内的 `ay`（通知原始字节）。read_array 要求读指针在数组之前，
/// 它会自行进入并离开数组；bytes 指向消息，仅在该消息存活期内有效。
fn variantBytes(m: *c.sd_bus_message, out: *Bytes) Error!void {
    if (try variantEnter(m, "ay")) {
        defer exitC(m);
        var ptr: ?*const anyopaque = null;
        var size: usize = 0;
        try check(c.sd_bus_message_read_array(m, 'y', &ptr, &size));
        if (size > 0 and ptr != null) out.* = .{ .ptr = @ptrCast(ptr.?), .len = size };
    } else try skipValue(m);
}

/// variant 内的 `as` 列表：单遍标记每个 needle 是否出现（不收集整表）。
fn variantListHits(m: *c.sd_bus_message, needles: []const []const u8, hits: []bool) Error!void {
    if (!try variantEnter(m, "as")) return skipValue(m);
    defer exitC(m);
    // variant 里是数组容器：还要再进一层才能逐个读字符串元素
    try enter(m, 'a', "s");
    defer exitC(m);
    while (!try atEnd(m)) {
        const str = try readString(m, 's');
        for (needles, 0..) |needle, i| {
            if (std.mem.eql(u8, str, needle)) hits[i] = true;
        }
    }
}

// ---- 查找用 visitor ----

const FindAdapter = struct {
    out: *Str,
    fn visit(self: *const FindAdapter, path: []const u8, iface: []const u8, props: *const Props) Error!bool {
        _ = props;
        if (!std.mem.eql(u8, iface, adapter_iface)) return false;
        try self.out.set(path);
        return true;
    }
};

/// 候选设备：服务 UUID 命中或名称命中。广告可能不含服务 UUID，故名称是必要的辅助。
const FindDevice = struct {
    out: *Str,
    fn visit(self: *const FindDevice, path: []const u8, iface: []const u8, props: *const Props) Error!bool {
        if (!std.mem.eql(u8, iface, device_iface)) return false;
        const name_hit = std.mem.eql(u8, props.name.slice(), device_name) or
            std.mem.eql(u8, props.alias.slice(), device_name);
        if (!props.uuid_hit and !name_hit) return false;
        try self.out.set(path);
        return true;
    }
};

const FindService = struct {
    out: *Str,
    fn visit(self: *const FindService, path: []const u8, iface: []const u8, props: *const Props) Error!bool {
        if (!std.mem.eql(u8, iface, gatt_service_iface)) return false;
        if (!std.mem.eql(u8, props.uuid.slice(), service_uuid)) return false;
        try self.out.set(path);
        return true;
    }
};

const FindCharacteristic = struct {
    out: *Str,
    uuid: []const u8,
    service: []const u8,
    flag: enum { write, notify },
    fn visit(self: *const FindCharacteristic, path: []const u8, iface: []const u8, props: *const Props) Error!bool {
        if (!std.mem.eql(u8, iface, char_iface)) return false;
        if (!std.mem.eql(u8, props.uuid.slice(), self.uuid)) return false;
        if (!std.mem.eql(u8, props.service.slice(), self.service)) return false;
        const ok = switch (self.flag) {
            .write => props.flag_write,
            .notify => props.flag_notify,
        };
        if (!ok) return false;
        try self.out.set(path);
        return true;
    }
};

// ---- BlueZ 方法与属性 ----

/// 开始 LE 扫描；true 表示扫描由我们开启（退出时须停止），
/// false 表示他方已在扫描（InProgress），不去停止别人的会话。
fn startDiscovery(bus: *c.sd_bus, adapter: [:0]const u8, deadline_ms: i64) Error!bool {
    callSimple(bus, adapter, adapter_iface, "StartDiscovery", deadline_ms) catch |err| switch (err) {
        error.InProgress => return false,
        // 适配器关闭时 StartDiscovery 真机返回 org.bluez.Error.Failed（文档写
        // NotReady；两者都已被 mapCallError 归为 BluezUnavailable/DbusError）。
        // 此处剩到 DbusError 的只剩 Failed 一类：报“蓝牙未启用”更可操作。
        error.DbusError => return error.BluezUnavailable,
        else => |e| return e,
    };
    return true;
}

fn stopDiscovery(bus: *c.sd_bus, adapter: [:0]const u8, deadline_ms: i64) Error!void {
    return callSimple(bus, adapter, adapter_iface, "StopDiscovery", deadline_ms);
}

/// 等 Device1.ServicesResolved：轮询到 true，超期报 Timeout。
fn waitResolved(bus: *c.sd_bus, dev: [:0]const u8, deadline_ms: i64) Error!void {
    while (true) {
        if (try getBoolProp(bus, dev, device_iface, "ServicesResolved", deadline_ms)) return;
        if (monoMs() >= deadline_ms) return error.Timeout;
        std.Thread.sleep(resolve_poll_ms * std.time.ns_per_ms);
    }
}

/// 读一个布尔属性（Properties.Get 回 variant）。
fn getBoolProp(bus: *c.sd_bus, path: [:0]const u8, iface: [:0]const u8, name: [:0]const u8, deadline_ms: i64) Error!bool {
    const m = try newCall(bus, path, props_iface, "Get");
    defer _ = c.sd_bus_message_unref(m);
    try appendStr(m, iface);
    try appendStr(m, name);
    const reply = try callBus(bus, m, deadline_ms);
    defer _ = c.sd_bus_message_unref(reply);
    // 布尔属性形状固定：类型不符说明对象不是预期的接口
    if (!try variantEnter(reply, "b")) return error.DbusError;
    defer exitC(reply);
    var b: c_int = 0;
    try check(c.sd_bus_message_read_basic(reply, 'b', @ptrCast(&b)));
    return b != 0;
}

/// 无参方法调用，只关心是否成功。
fn callSimple(bus: *c.sd_bus, path: [:0]const u8, iface: [:0]const u8, member: [:0]const u8, deadline_ms: i64) Error!void {
    const m = try newCall(bus, path, iface, member);
    defer _ = c.sd_bus_message_unref(m);
    const reply = try callBus(bus, m, deadline_ms);
    _ = c.sd_bus_message_unref(reply);
}

fn newCall(bus: *c.sd_bus, path: [:0]const u8, iface: [:0]const u8, member: [:0]const u8) Error!*c.sd_bus_message {
    var m: ?*c.sd_bus_message = null;
    try check(c.sd_bus_message_new_method_call(bus, &m, service_name, path, iface, member));
    return m orelse error.DbusError;
}

/// 同步调用：期限用绝对单调毫秒换算；错误名映射为可诊断错误。
fn callBus(bus: *c.sd_bus, m: *c.sd_bus_message, deadline_ms: i64) Error!*c.sd_bus_message {
    var err: c.sd_bus_error = std.mem.zeroes(c.sd_bus_error);
    defer c.sd_bus_error_free(&err);
    var reply: ?*c.sd_bus_message = null;
    const r = c.sd_bus_call(bus, m, remainingUsec(deadline_ms), &err, &reply);
    if (r < 0) return mapCallError(&err, r);
    return reply orelse error.DbusError;
}

/// D-Bus 错误 → 可诊断错误。只记录错误名（消息可能含设备地址，不入日志）。
fn mapCallError(err: *const c.sd_bus_error, r: c_int) Error {
    const name: []const u8 = if (err.name != null) std.mem.span(err.name) else "";
    if (std.mem.eql(u8, name, "org.freedesktop.DBus.Error.AccessDenied") or
        std.mem.eql(u8, name, "org.bluez.Error.NotAuthorized"))
        return error.AccessDenied;
    if (std.mem.eql(u8, name, "org.freedesktop.DBus.Error.ServiceUnknown") or
        std.mem.eql(u8, name, "org.freedesktop.DBus.Error.NameHasNoOwner") or
        std.mem.eql(u8, name, "org.bluez.Error.NotReady"))
        return error.BluezUnavailable;
    if (std.mem.eql(u8, name, "org.freedesktop.DBus.Error.UnknownObject") or
        std.mem.eql(u8, name, "org.freedesktop.DBus.Error.UnknownInterface") or
        std.mem.eql(u8, name, "org.freedesktop.DBus.Error.UnknownMethod") or
        std.mem.eql(u8, name, "org.bluez.Error.DoesNotExist") or
        std.mem.eql(u8, name, "org.bluez.Error.InvalidArguments") or
        std.mem.eql(u8, name, "org.bluez.Error.NotPermitted"))
        return error.GattUnsupported;
    if (std.mem.eql(u8, name, "org.bluez.Error.NotConnected")) return error.NotConnected;
    if (std.mem.eql(u8, name, "org.bluez.Error.InProgress")) return error.InProgress;
    if (r == -@as(c_int, @intCast(@intFromEnum(std.posix.E.TIMEDOUT)))) return error.Timeout;
    if (r == -@as(c_int, @intCast(@intFromEnum(std.posix.E.ACCES))) or
        r == -@as(c_int, @intCast(@intFromEnum(std.posix.E.PERM))))
        return error.AccessDenied;
    if (r == -@as(c_int, @intCast(@intFromEnum(std.posix.E.CONNRESET))) or
        r == -@as(c_int, @intCast(@intFromEnum(std.posix.E.PIPE))) or
        r == -@as(c_int, @intCast(@intFromEnum(std.posix.E.NOTCONN))))
        return error.NotConnected;
    if (name.len > 0) log("f9d: BlueZ D-Bus 失败: {s}", .{name});
    return error.DbusError;
}

/// 系统总线连不上（未运行 / 无权限 / 无 socket）。
fn openBusError(r: c_int) Error {
    if (r == -@as(c_int, @intCast(@intFromEnum(std.posix.E.ACCES))) or
        r == -@as(c_int, @intCast(@intFromEnum(std.posix.E.PERM))))
        return error.AccessDenied;
    log("f9d: 无法连接 system bus（BlueZ 未运行或未启用）", .{});
    return error.BluezUnavailable;
}

// ---- sd-bus 读取/构造小工具 ----

fn check(r: c_int) Error!void {
    if (r < 0) return error.DbusError;
}

fn enter(m: *c.sd_bus_message, typ: u8, contents: ?[*:0]const u8) Error!void {
    try check(c.sd_bus_message_enter_container(m, typ, contents));
}

fn exitC(m: *c.sd_bus_message) void {
    _ = c.sd_bus_message_exit_container(m);
}

fn atEnd(m: *c.sd_bus_message) Error!bool {
    const r = c.sd_bus_message_at_end(m, 0);
    if (r < 0) return error.DbusError;
    return r > 0;
}

fn readString(m: *c.sd_bus_message, typ: u8) Error![]const u8 {
    var p: [*c]const u8 = null;
    const r = c.sd_bus_message_read_basic(m, typ, @ptrCast(&p));
    if (r < 0) return error.DbusError;
    // r == 0 表示此处没有可读元素：形状不符，宁可失败也不返回空串
    if (r == 0 or p == null) return error.DbusError;
    return std.mem.span(p);
}

fn readInto(m: *c.sd_bus_message, typ: u8, out: *Str) Error!void {
    return out.set(try readString(m, typ));
}

fn openC(m: *c.sd_bus_message, typ: u8, contents: ?[*:0]const u8) Error!void {
    try check(c.sd_bus_message_open_container(m, typ, contents));
}

fn closeC(m: *c.sd_bus_message) void {
    _ = c.sd_bus_message_close_container(m);
}

fn appendStr(m: *c.sd_bus_message, s: [:0]const u8) Error!void {
    try check(c.sd_bus_message_append_basic(m, 's', @ptrCast(s.ptr)));
}

// ---- 期限 ----

fn remainingUsec(deadline_ms: i64) u64 {
    const left = deadline_ms - monoMs();
    if (left <= 0) return 1; // 已过期 → 让调用立刻超时
    return @as(u64, @intCast(left)) * std.time.us_per_ms;
}

// ---------------------------------------------------------------------------
// 测试（纯函数与 fake I/O，不连蓝牙）
// ---------------------------------------------------------------------------

/// 记录写入帧、按序吐出通知帧的 fake；通知用尽即 Timeout。
const FakeGatt = struct {
    frames: []const []const u8 = &.{},
    read_count: usize = 0,
    notify_count: usize = 0,
    writes: [6][frame_len]u8 = undefined,
    write_count: usize = 0,

    fn beginNotify(self: *FakeGatt) Error!void {
        self.notify_count += 1;
    }

    fn endNotify(_: *FakeGatt) void {}

    fn writeFrame(self: *FakeGatt, raw: []const u8) Error!void {
        self.writes[self.write_count] = raw[0..frame_len].*;
        self.write_count += 1;
    }

    fn nextFrame(self: *FakeGatt) Error![]const u8 {
        if (self.read_count == self.frames.len) return error.Timeout;
        const f = self.frames[self.read_count];
        self.read_count += 1;
        return f;
    }
};

fn responseFrame(buf: *[frame_len]u8, command: protocol.Command, offset: u16, len: u8, data: []const u8) []const u8 {
    @memset(buf, 0);
    buf[0] = magic;
    buf[1] = @intFromEnum(command);
    buf[2] = len;
    std.mem.writeInt(u16, buf[3..5], offset, .little);
    @memcpy(buf[5..][0..data.len], data);
    return buf[0 .. 5 + data.len]; // 响应变长：总长恰为 5+length
}

test "读请求编码向量（0x05, offset 0, length 15）" {
    var buf: [frame_len]u8 = undefined;
    try encodeRead(&buf, .settings_read, 0, max_payload);
    var want = [_]u8{0} ** frame_len;
    want[0] = 0xee;
    want[1] = 0x05;
    want[2] = 0x0f;
    try std.testing.expectEqualSlices(u8, &want, &buf);
}

test "会话请求编码：open=0x01 / close=0x02，length=1、payload 同值" {
    var buf: [frame_len]u8 = undefined;
    try encodeSession(&buf, true);
    try std.testing.expectEqualSlices(u8, &.{ 0xee, 0x01, 0x01, 0, 0, 0x01 }, buf[0..6]);
    try encodeSession(&buf, false);
    try std.testing.expectEqualSlices(u8, &.{ 0xee, 0x02, 0x01, 0, 0, 0x02 }, buf[0..6]);
}

test "写请求编码：length=payload 长度；15 字节上限" {
    const block = [_]u8{0xAB} ** max_payload;
    var buf: [frame_len]u8 = undefined;
    try encodeWrite(&buf, .settings_write, 0x0102, &block);
    try std.testing.expectEqual(@as(u8, 0x06), buf[1]);
    try std.testing.expectEqual(@as(u8, max_payload), buf[2]);
    try std.testing.expectEqualSlices(u8, &.{ 0x02, 0x01 }, buf[3..5]);
    try std.testing.expectEqualSlices(u8, &block, buf[5..20]);

    const big = [_]u8{0} ** (max_payload + 1);
    try std.testing.expectError(error.PayloadTooLong, encodeWrite(&buf, .settings_write, 0, &big));
    try std.testing.expectError(error.PayloadTooLong, encodeRead(&buf, .settings_read, 0, max_payload + 1));
}

test "响应解码：变长帧拷出前 length 字节，[7] 是数据而非状态码" {
    var raw: [frame_len]u8 = undefined;
    // 验收向量：flag=0x02、rpm_raw=0x1ff4 → rpm=2045（响应共 5+3=8 字节）
    const f = responseFrame(&raw, .live_status, 0, 3, &.{ 0x02, 0xf4, 0x1f });
    try std.testing.expectEqual(@as(usize, 8), f.len);
    const d = try decodeResponse(f, .live_status, 0, 3);
    const st = try protocol.decodeStatus(d.bytes());
    try std.testing.expectEqual(@as(u8, 0x02), st.flag);
    try std.testing.expectEqual(@as(u16, 0x1ff4), st.rpm_raw);
    try std.testing.expectEqual(@as(u16, 2045), st.rpm);

    // 数据字节为 0xfe/0xff 时不得触发 USB 式状态判错
    const f2 = responseFrame(&raw, .live_status, 0, 3, &.{ 0xfe, 0xff, 0x42 });
    const d2 = try decodeResponse(f2, .live_status, 0, 3);
    try std.testing.expectEqualSlices(u8, &.{ 0xfe, 0xff, 0x42 }, d2.bytes());
}

test "响应解码：真机向量（0x1a 变长 8 字节，spec §8 confirmed）" {
    const raw = [_]u8{ 0xee, 0x1a, 0x03, 0x00, 0x00, 0x01, 0x0d, 0x27 };
    const d = try decodeResponse(&raw, .live_status, 0, 3);
    const st = try protocol.decodeStatus(d.bytes());
    try std.testing.expectEqual(@as(u8, 0x01), st.flag);
    try std.testing.expectEqual(@as(u16, 0x270d), st.rpm_raw);
    try std.testing.expectEqual(@as(u16, 2499), st.rpm);
}

test "响应解码：短包/超长/填充帧/头错/命令错/长度错/offset 错均拒绝" {
    var raw: [frame_len]u8 = undefined;
    const zeros = [_]u8{0} ** max_payload;
    const full = responseFrame(&raw, .settings_read, 0, max_payload, &zeros); // 20 字节

    try std.testing.expectError(error.BadLength, decodeResponse(full[0..4], .settings_read, 0, max_payload));
    try std.testing.expectError(error.BadLength, decodeResponse(full[0..19], .settings_read, 0, max_payload));
    var long: [frame_len + 1]u8 = undefined;
    @memcpy(long[0..frame_len], full);
    try std.testing.expectError(error.BadLength, decodeResponse(&long, .settings_read, 0, max_payload));

    // 填充帧（声明短长度但总长 20）不是合法变长帧
    var padded: [frame_len]u8 = undefined;
    _ = responseFrame(&padded, .live_status, 0, 3, &.{ 0, 0, 0 });
    try std.testing.expectError(error.BadLength, decodeResponse(&padded, .live_status, 0, 3));

    raw[0] = 0xdd;
    try std.testing.expectError(error.BadMagic, decodeResponse(full, .settings_read, 0, max_payload));
    raw[0] = magic;

    raw[1] = 0x1a;
    try std.testing.expectError(error.CommandMismatch, decodeResponse(full, .settings_read, 0, max_payload));
    raw[1] = 0x05;

    raw[2] = max_payload + 1;
    try std.testing.expectError(error.BadLength, decodeResponse(full, .settings_read, 0, max_payload));
    raw[2] = max_payload;

    // 声明长度与总长自洽、但与本次预期不符 → LengthMismatch（事务层当旧通知）
    var m: [frame_len]u8 = undefined;
    const f14 = responseFrame(&m, .settings_read, 0, max_payload - 1, &[_]u8{0} ** (max_payload - 1));
    try std.testing.expectError(error.LengthMismatch, decodeResponse(f14, .settings_read, 0, max_payload));

    raw[4] = 1;
    try std.testing.expectError(error.OffsetMismatch, decodeResponse(full, .settings_read, 0, max_payload));
}

test "事务：普通命令必须等到匹配通知，旧通知丢弃" {
    var stale: [frame_len]u8 = undefined;
    const zeros = [_]u8{0} ** max_payload;
    const f_stale = responseFrame(&stale, .settings_write, 0, max_payload, &zeros); // 旧命令
    var ok: [frame_len]u8 = undefined;
    const fill = [_]u8{0xA5} ** max_payload;
    const f_ok = responseFrame(&ok, .settings_read, 0, max_payload, &fill);
    var g: FakeGatt = .{ .frames = &.{ f_stale, f_ok } };

    var req: [frame_len]u8 = undefined;
    try encodeRead(&req, .settings_read, 0, max_payload);
    const d = try transact(&g, .settings_read, 0, max_payload, &req);
    try std.testing.expectEqualSlices(u8, &fill, d.bytes());
    try std.testing.expectEqualSlices(u8, &req, &g.writes[0]); // 写出的就是这一帧
    try std.testing.expectEqual(@as(usize, 2), g.read_count); // 旧帧被丢弃后继续等
    try std.testing.expectEqual(@as(usize, 1), g.notify_count); // 订阅在写之前装好
}

test "事务：会话命令只等 GATT 写完成，不等通知" {
    var g: FakeGatt = .{}; // frames 为空：一旦等通知就会 Timeout
    var req: [frame_len]u8 = undefined;
    try encodeSession(&req, true);
    _ = try transact(&g, .session_open, 0, 0, &req);
    try std.testing.expectEqual(@as(usize, 1), g.write_count);
    try std.testing.expectEqual(@as(usize, 0), g.read_count);
    try std.testing.expectEqual(@as(usize, 0), g.notify_count);
}

test "事务：坏帧立即失败，等不到通知报 Timeout" {
    var bad: [frame_len]u8 = undefined;
    const f_bad = responseFrame(&bad, .live_status, 0, 3, &.{ 0, 0, 0 });
    bad[0] = 0xdd;
    var g1: FakeGatt = .{ .frames = &.{f_bad} };
    var req: [frame_len]u8 = undefined;
    try encodeRead(&req, .live_status, 0, 3);
    try std.testing.expectError(error.BadMagic, transact(&g1, .live_status, 0, 3, &req));

    var g2: FakeGatt = .{};
    try std.testing.expectError(error.Timeout, transact(&g2, .live_status, 0, 3, &req));
}

test "事务：长度/offset 不符的通知视为旧通知丢弃，匹配帧随后被接受" {
    var wrong_len: [frame_len]u8 = undefined;
    const f_len = responseFrame(&wrong_len, .settings_read, 0, max_payload - 1, &[_]u8{0} ** (max_payload - 1));
    var wrong_off: [frame_len]u8 = undefined;
    const f_off = responseFrame(&wrong_off, .settings_read, 1, max_payload, &[_]u8{0} ** max_payload);
    var ok: [frame_len]u8 = undefined;
    const fill = [_]u8{0x5A} ** max_payload;
    const f_ok = responseFrame(&ok, .settings_read, 0, max_payload, &fill);
    var g: FakeGatt = .{ .frames = &.{ f_len, f_off, f_ok } };

    var req: [frame_len]u8 = undefined;
    try encodeRead(&req, .settings_read, 0, max_payload);
    const d = try transact(&g, .settings_read, 0, max_payload, &req);
    try std.testing.expectEqualSlices(u8, &fill, d.bytes());
    try std.testing.expectEqual(@as(usize, 3), g.read_count); // 两帧旧通知都被丢弃
}

test "事务：写命令等待 len=payload 长度的匹配通知" {
    const block = [_]u8{0xC3} ** max_payload;
    var req: [frame_len]u8 = undefined;
    try encodeWrite(&req, .settings_write, 0, &block);

    var echo: [frame_len]u8 = undefined;
    const f_echo = responseFrame(&echo, .settings_write, 0, max_payload, &block);
    var g: FakeGatt = .{ .frames = &.{f_echo} };
    _ = try transact(&g, .settings_write, 0, max_payload, &req);
    try std.testing.expectEqualSlices(u8, &req, &g.writes[0]);
    try std.testing.expectEqual(@as(usize, 1), g.notify_count); // 订阅先于写装

    // 长度不回显的通知不算本次响应：等不到正确帧就超时
    var short: [frame_len]u8 = undefined;
    const f_short = responseFrame(&short, .settings_write, 0, max_payload - 1, &[_]u8{0} ** (max_payload - 1));
    var g2: FakeGatt = .{ .frames = &.{f_short} };
    try std.testing.expectError(error.Timeout, transact(&g2, .settings_write, 0, max_payload, &req));
}

test "事务：超过 20 字节的通知按结构性坏帧立即失败" {
    var long: [frame_len + 1]u8 = undefined;
    var raw: [frame_len]u8 = undefined;
    const f = responseFrame(&raw, .live_status, 0, 3, &.{ 0, 0, 0 });
    @memcpy(long[0..f.len], f);
    @memset(long[f.len..], 0);
    var g: FakeGatt = .{ .frames = &.{&long} };

    var req: [frame_len]u8 = undefined;
    try encodeRead(&req, .live_status, 0, 3);
    try std.testing.expectError(error.BadLength, transact(&g, .live_status, 0, 3, &req));
    try std.testing.expectEqual(@as(usize, 1), g.read_count); // 不继续等下一帧
}

test "adoptValue：空 ay 与非 ay 的 Value 不置 have，继续等真响应" {
    var ctx: NotifyCtx = .{};
    adoptValue(&ctx, .{}); // 空值：置 have 会产出 0 字节帧并把整个事务判死
    try std.testing.expect(!ctx.have);
    try std.testing.expectEqual(@as(usize, 0), ctx.len);

    const data = [_]u8{ 0xee, 0x1a, 0x03 };
    adoptValue(&ctx, .{ .ptr = &data, .len = data.len });
    try std.testing.expect(ctx.have);
    try std.testing.expectEqual(@as(usize, 3), ctx.len);
    try std.testing.expectEqualSlices(u8, &data, ctx.buf[0..ctx.len]);
}
