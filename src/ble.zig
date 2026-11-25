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
// 测试用：把诊断输出改道，避免 zig build test 被“BlueZ D-Bus 失败”之类刷屏
const setLogSink = @import("root.zig").setLogSink;
const discardLog = @import("root.zig").discardLog;

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
/// 停止自己开启的 LE 扫描的独立期限（扫描期限早已过期时也要能真的停掉）。
const stop_discovery_timeout_ms = 1_000;
/// 复用链路前查询 Connected 的期限：只是探活，不能吃掉整请求预算。
const alive_timeout_ms = 1_000;
/// 候选设备上限：BlueZ 缓存可能留着多台已断电/同名的同类设备，
/// 全部遍历会把打开过程拖成对象树扫描；取前若干条逐个试。
const max_candidates = 4;
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
    /// BlueZ / system bus 权限被拒，与 hidraw 的 UsbAccessDenied 分开，文案不混淆
    BleAccessDenied,
    NotConnected,
    /// 连接在期限内没有建立（设备关闭/不在范围内/被他机占用），
    /// 与“已连接后命令没回应”的 Timeout 分开，避免文案误导
    ConnectTimeout,
    /// 连接已建立但 ServicesResolved 超时（GATT 服务解析没完成）
    ResolveTimeout,
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
    buf: [path_max]u8 = std.mem.zeroes([path_max]u8),
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
    service: Str = .{}, // GattCharacteristic1 所属服务的对象路径
    device: Str = .{}, // GattService1 所属设备的对象路径
    name: Str = .{},
    alias: Str = .{},
    services_resolved: ?bool = null,
    powered: ?bool = null, // Adapter1.Powered：蓝牙是否启用
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
    device_path: Str,
    write_path: Str,
    notify_path: Str,
    notify: NotifyCtx = .{},
    slot: ?*c.sd_bus_slot = null,
    budget_ms: i64 = 0,
    /// 本次事务等待通知的绝对期限（beginNotify 时确定）。
    /// 不能每次 nextFrame 重算：持续收到不匹配的旧通知时，5s 单操作上限会被无限续期，
    /// 事务只能靠 30s 整请求预算兜底（USB 侧是同事务一个固定期限）。
    notify_deadline_ms: i64 = 0,

    /// 发现并连接设备：适配器 → 候选设备（必要时有上限地扫描）→ 逐个 Connect →
    /// ServicesResolved → 按 UUID/服务/flags 复核写与通知特征 → StartNotify。
    /// 首个候选失败（缓存里的旧设备、同名干扰设备、GATT 不匹配）时不放弃：
    /// 继续试下一个候选，最后按诊断价值最高的错误上报。
    pub fn open() Error!Device {
        // 整请求预算从打开入口起算：扫描/连接/服务解析都花在同一份预算里，
        // 保证 f9d 侧 打开+请求 ≤ request_budget_ms（小于 f9ctl 的 IPC 超时）。
        const budget_ms = monoMs() + request_budget_ms;
        var bus: ?*c.sd_bus = null;
        const r = c.sd_bus_open_system(&bus);
        if (r < 0) return openBusError(r);
        const bus_ptr = bus orelse return error.BluezUnavailable;
        errdefer _ = c.sd_bus_flush_close_unref(bus_ptr);

        const deadline = @min(budget_ms, monoMs() + open_timeout_ms);

        // 适配器：BlueZ 在跑且蓝牙启用时才有 org.bluez.Adapter1 对象
        var adapter: Str = .{};
        _ = try find(bus_ptr, &FindAdapter{ .out = &adapter }, deadline);
        if (adapter.len == 0) return error.BluezUnavailable;

        // 已知对象里先找；找不到才开一次扫描（扫描有上限）。
        // 他方已在扫描时 startDiscovery 得 false：只随其扫描结果轮询，不重复发
        // StartDiscovery，退出时也不停止别人的会话。
        var cands: Candidates = .{};
        _ = try find(bus_ptr, &FindDevices{ .out = &cands }, deadline);
        var scanning = false;
        if (cands.len == 0) scanning = try startDiscovery(bus_ptr, adapter.z(), deadline);
        // 任何提前返回（包括下面的 find 报错）都必须停掉自己开的扫描，
        // 否则适配器会一直停在 LE 扫描态；用独立期限，扫描本身耗到期限也能真停掉。
        defer if (scanning) stopDiscoveryBestEffort(bus_ptr, adapter.z(), budget_ms);
        while (cands.len == 0 and monoMs() < deadline) {
            std.Thread.sleep(scan_poll_ms * std.time.ns_per_ms);
            _ = try find(bus_ptr, &FindDevices{ .out = &cands }, deadline);
        }
        // 正常出口先停一次：后面还要 Connect，不该把扫描带进连接阶段
        if (scanning) {
            stopDiscoveryBestEffort(bus_ptr, adapter.z(), budget_ms);
            scanning = false; // defer 成为空操作
        }
        if (cands.len == 0) {
            log("f9d: 未发现 BLE 设备（服务 UUID 或名称 LEGION_F9_BT）", .{});
            return error.DeviceNotFound;
        }

        var best_err: ?Error = null;
        for (cands.slice()) |*cand| {
            if (monoMs() >= budget_ms) break;
            const attempt_deadline = @min(budget_ms, monoMs() + open_timeout_ms);
            const dev = connectCandidate(bus_ptr, cand.slice(), attempt_deadline, budget_ms) catch |err| {
                // 只记错误名，不打印设备对象路径（地址可能变化，不入日志）
                log("f9d: BLE 候选设备不可用: {s}", .{@errorName(err)});
                best_err = moreInformative(best_err, err);
                continue;
            };
            log("f9d: BLE 设备已连接", .{});
            return dev;
        }
        return best_err orelse error.DeviceNotFound;
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

    /// 复用链路前的探活：BlueZ 仍认为设备已连接。
    /// 查询失败按“不可用”处理（多半是 BlueZ 重启或空闲断链），让 daemon 重新建链，
    /// 用户当次请求不必先在死句柄上失败一次。用独立短期限，不吃整请求预算。
    pub fn alive(self: *Device) bool {
        const deadline = monoMs() + alive_timeout_ms;
        return getBoolProp(self.bus, self.device_path.z(), device_iface, "Connected", deadline) catch false;
    }

    /// 整请求预算已耗尽时直接失败：不发起“只剩 1us”的 D-Bus 调用。
    /// ops.gearSet 的失败收尾（best-effort session close）在预算用尽后不再产生流量。
    fn ensureBudget(self: *Device) Error!void {
        if (monoMs() >= self.budget_ms) return error.Timeout;
    }

    /// 读命令：发读请求 → 等匹配通知。
    pub fn read(self: *Device, command: protocol.Command, offset: u16, len: u8) Error!protocol.Decoded {
        try self.ensureBudget();
        var req: [frame_len]u8 = undefined;
        try encodeRead(&req, command, offset, len);
        return transact(self, command, offset, len, &req);
    }

    /// 写命令：发写请求 → 等匹配通知。
    pub fn write(self: *Device, command: protocol.Command, offset: u16, payload: []const u8) Error!void {
        try self.ensureBudget();
        var req: [frame_len]u8 = undefined;
        try encodeWrite(&req, command, offset, payload);
        _ = try transact(self, command, offset, @intCast(payload.len), &req);
    }

    /// 会话命令：只推进 GATT 写完成，不等通知。
    pub fn session(self: *Device, is_open: bool) Error!void {
        try self.ensureBudget();
        var req: [frame_len]u8 = undefined;
        try encodeSession(&req, is_open);
        _ = try transact(self, if (is_open) .session_open else .session_close, 0, 0, &req);
    }

    // ---- transact 的四个 GATT 原语 ----

    /// 安装本次事务的通知订阅；必须在写请求之前调用，否则会漏掉设备回复。
    fn beginNotify(self: *Device) Error!void {
        self.endNotify();
        self.notify = .{};
        self.notify_deadline_ms = self.opDeadline(); // 事务开始即定死，事务内不续期
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
        const deadline = self.notify_deadline_ms;
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
        } else if (std.mem.eql(u8, key, "Device")) {
            try variantString(m, "o", 'o', &p.device); // GattService1.Device 是对象路径
        } else if (std.mem.eql(u8, key, "Name")) {
            try variantString(m, "s", 's', &p.name);
        } else if (std.mem.eql(u8, key, "Alias")) {
            try variantString(m, "s", 's', &p.alias);
        } else if (std.mem.eql(u8, key, "ServicesResolved")) {
            var b = false;
            // 类型不符时不采纳：保持 null，别把“没读到”伪装成设备报告的 false
            if (try variantBool(m, &b)) p.services_resolved = b;
        } else if (std.mem.eql(u8, key, "Powered")) {
            var b = false;
            if (try variantBool(m, &b)) p.powered = b;
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

/// variant 内的布尔值。返回是否真的读到了布尔：类型不符时跳过并返回 false，
/// 调用方据此保持“未知”而不是落成 false。
fn variantBool(m: *c.sd_bus_message, out: *bool) Error!bool {
    if (try variantEnter(m, "b")) {
        defer exitC(m);
        var b: c_int = 0;
        try check(c.sd_bus_message_read_basic(m, 'b', @ptrCast(&b)));
        out.* = b != 0;
        return true;
    }
    try skipValue(m);
    return false;
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

/// 适配器：优先 `Powered=true` 的那一个。
/// 多适配器主机上（内置 hci0 关闭 + 外接 hci1 开启）取首个会锁到没启用的适配器；
/// 没有已启用的适配器时仍记下首个，最终按“蓝牙未启用”（BluezUnavailable）上报，
/// 而不是伪装成“设备不在”。
const FindAdapter = struct {
    out: *Str,
    fn visit(self: *const FindAdapter, path: []const u8, iface: []const u8, props: *const Props) Error!bool {
        if (!std.mem.eql(u8, iface, adapter_iface)) return false;
        const powered = props.powered orelse false;
        if (self.out.len == 0) try self.out.set(path); // 兜底候选（可能未启用）
        if (!powered) return false; // 继续找已启用的
        try self.out.set(path);
        return true;
    }
};

/// 候选设备集合（固定上限，不分配）。旅程开始前收集全部候选，
/// 首选候选连接不上也能继续试下一条，而不是整个打开失败。
const Candidates = struct {
    paths: [max_candidates]Str = @splat(.{}),
    len: usize = 0,

    fn slice(self: *const Candidates) []const Str {
        return self.paths[0..self.len];
    }

    fn add(self: *Candidates, path: []const u8) Error!void {
        if (self.len == max_candidates) return; // 上限：多余候选忽略
        for (self.paths[0..self.len]) |*p| {
            if (std.mem.eql(u8, p.slice(), path)) return; // 同一路径只收一次
        }
        try self.paths[self.len].set(path);
        self.len += 1;
    }
};

/// 候选设备：服务 UUID 命中或名称命中。广告可能不含服务 UUID，故名称是必要的辅助。
/// 收集全部候选后返回 false（不提前结束遍历）。
const FindDevices = struct {
    out: *Candidates,
    fn visit(self: *const FindDevices, path: []const u8, iface: []const u8, props: *const Props) Error!bool {
        if (!std.mem.eql(u8, iface, device_iface)) return false;
        const name_hit = std.mem.eql(u8, props.name.slice(), device_name) or
            std.mem.eql(u8, props.alias.slice(), device_name);
        if (!props.uuid_hit and !name_hit) return false;
        try self.out.add(path);
        return false;
    }
};

/// 单个候选的完整复核：连接 → 服务解析 → 服务/特征（限该设备子树）→ StartNotify。
/// 只有我们自己发起的连接才在失败时断开，避免踢掉他方的连接。
fn connectCandidate(bus: *c.sd_bus, dev_path: []const u8, deadline_ms: i64, budget_ms: i64) Error!Device {
    var dev: Str = .{};
    try dev.set(dev_path);

    var we_connected = false;
    errdefer {
        if (we_connected) disconnectQuietly(bus, dev.z(), budget_ms);
    }

    // 上层连接可能还活着：Connected 为真就不重复 Connect。
    // Connect 报 InProgress/AlreadyConnected 说明连接属于他方：不算失败，交给
    // ServicesResolved 等待，但**不登记成我们连上的**——否则失败收尾会把他方的连接踢掉。
    const connected = getBoolProp(bus, dev.z(), device_iface, "Connected", deadline_ms) catch false;
    if (!connected) {
        if (callSimple(bus, dev.z(), device_iface, "Connect", deadline_ms)) |_| {
            we_connected = true;
        } else |err| switch (err) {
            error.InProgress => {},
            // 连接在期限内没有建立：报 ConnectTimeout，别让用户以为命令发出去了没回
            error.Timeout => return error.ConnectTimeout,
            // Connect 剩到 DbusError 的实测就是 org.bluez.Error.Failed（设备断电/远离
            // 无法接通）：报 NotConnected 比笼统的 DbusError 更可操作。
            error.DbusError => return error.NotConnected,
            else => |e| return e,
        }
    }
    try waitResolved(bus, dev.z(), deadline_ms);

    // 服务/特征在连接并解析后才出现；UUID、设备归属、所属服务与必需的 flags 都要对得上。
    // 一次 GetManagedObjects 取全量，再在本地走两遍（服务 → 特征），省两次全树往返。
    const gatt = try parseGatt(try managedObjects(bus, deadline_ms), dev.slice());

    // GATT 通知开一次；PropertiesChanged 订阅按事务装/卸（见 beginNotify）
    try callSimple(bus, gatt.notify.z(), char_iface, "StartNotify", deadline_ms);

    return .{
        .bus = bus,
        .device_path = dev,
        .write_path = gatt.write,
        .notify_path = gatt.notify,
        .budget_ms = budget_ms,
    };
}

/// 目标服务与两个特征（对象路径）。
const Gatt = struct {
    service: Str = .{},
    write: Str = .{},
    notify: Str = .{},
};

/// 取一次 GetManagedObjects 的响应（调用方负责 unref）。
fn managedObjects(bus: *c.sd_bus, deadline_ms: i64) Error!*c.sd_bus_message {
    const m = try newCall(bus, "/", objmgr_iface, "GetManagedObjects");
    defer _ = c.sd_bus_message_unref(m);
    return callBus(bus, m, deadline_ms);
}

/// 在对象树里定位服务与两个特征，只走一遍 D-Bus：
/// 先扫出属于本设备的服务，再 rewind 到开头按“所属服务 + UUID + flags”挑特征。
/// 不能在单遍里同时挑：对象树顺序由 BlueZ 决定，不保证特征排在所属服务之后。
fn parseGatt(reply: *c.sd_bus_message, device: []const u8) Error!Gatt {
    var out: Gatt = .{};
    // walkObjects 命中即提前返回，游标会停在容器里：每趟都从消息开头重新开始
    try check(c.sd_bus_message_rewind(reply, 1));
    _ = try walkObjects(reply, &FindService{ .out = &out.service, .device = device });
    if (out.service.len == 0) return error.GattUnsupported;

    try check(c.sd_bus_message_rewind(reply, 1));
    const wfind = FindCharacteristic{ .out = &out.write, .uuid = write_uuid, .service = out.service.z(), .flag = .write };
    if (!try walkObjects(reply, &wfind)) return error.GattUnsupported;

    try check(c.sd_bus_message_rewind(reply, 1));
    const nfind = FindCharacteristic{ .out = &out.notify, .uuid = notify_uuid, .service = out.service.z(), .flag = .notify };
    if (!try walkObjects(reply, &nfind)) return error.GattUnsupported;
    return out;
}

/// 失败候选的收尾断开：独立小期限，且不越过整请求预算。
/// 多个候选连续失败时，收尾各自 1s 会叠加到 30s 预算之外，这里与 budget 取小。
fn disconnectQuietly(bus: *c.sd_bus, dev: [:0]const u8, budget_ms: i64) void {
    callSimple(bus, dev, device_iface, "Disconnect", @min(budget_ms, monoMs() + 1_000)) catch {};
}

/// 候选错误里挑“诊断价值更高”的那个上报：
/// 权限/BlueZ 不可用 > GATT 不匹配 > 连接不上 > 等待超时 > 其他。
/// 这样缓存里的旧候选先失败时，不会把后一条“真正的设备 GATT 不对”覆盖成笼统错误。
fn moreInformative(current: ?Error, candidate: Error) ?Error {
    const cur = current orelse return candidate;
    return if (errorRank(candidate) > errorRank(cur)) candidate else cur;
}

fn errorRank(err: Error) u8 {
    return switch (err) {
        error.BleAccessDenied, error.BluezUnavailable => 5,
        error.GattUnsupported => 4,
        error.NotConnected => 3,
        error.ConnectTimeout, error.ResolveTimeout => 2,
        else => 1,
    };
}

/// 目标服务：UUID 命中且**属于选中的那台设备**。GetManagedObjects 返回全适配器
/// 的对象树；只按 UUID 全局查找会在多台同类设备同时在线时把别的设备的服务
/// 关联到当前候选设备上，所以必须用 GattService1.Device 限定归属。
const FindService = struct {
    out: *Str,
    device: []const u8,
    fn visit(self: *const FindService, path: []const u8, iface: []const u8, props: *const Props) Error!bool {
        if (!std.mem.eql(u8, iface, gatt_service_iface)) return false;
        if (!std.mem.eql(u8, props.uuid.slice(), service_uuid)) return false;
        if (!std.mem.eql(u8, props.device.slice(), self.device)) return false;
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

/// 停止自己开启的扫描：独立短期限（上限 1s，且不超过整请求预算）。
/// 扫描本身耗到期限时旧期限已过期，若沿用它，StopDiscovery 只剩 1us 必然超时、
/// 适配器会留在 LE 扫描状态。
fn stopDiscoveryBestEffort(bus: *c.sd_bus, adapter: [:0]const u8, budget_ms: i64) void {
    const deadline = @min(budget_ms, monoMs() + stop_discovery_timeout_ms);
    stopDiscovery(bus, adapter, deadline) catch |err| {
        log("f9d: 停止 LE 扫描失败: {s}", .{@errorName(err)});
    };
}

/// 等 Device1.ServicesResolved：轮询到 true，超期报 ResolveTimeout
/// （已连接但服务解析没完成，与命令响应超时区分开）。
fn waitResolved(bus: *c.sd_bus, dev: [:0]const u8, deadline_ms: i64) Error!void {
    while (true) {
        const resolved = getBoolProp(bus, dev, device_iface, "ServicesResolved", deadline_ms) catch |err| switch (err) {
            // 属性查询本身超时也是“服务解析没在期限内完成”，别退化成笼统的 Timeout
            error.Timeout => return error.ResolveTimeout,
            else => |e| return e,
        };
        if (resolved) return;
        if (monoMs() >= deadline_ms) return error.ResolveTimeout;
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
        return error.BleAccessDenied;
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
    // InProgress（他方正在连接）与 AlreadyConnected（读属性后、Connect 前他方已连上）
    // 对调用方都是“连接即将可用，继续等 ServicesResolved”，不当作失败。
    if (std.mem.eql(u8, name, "org.bluez.Error.InProgress") or
        std.mem.eql(u8, name, "org.bluez.Error.AlreadyConnected"))
        return error.InProgress;
    if (r == -@as(c_int, @intCast(@intFromEnum(std.posix.E.TIMEDOUT)))) return error.Timeout;
    if (r == -@as(c_int, @intCast(@intFromEnum(std.posix.E.ACCES))) or
        r == -@as(c_int, @intCast(@intFromEnum(std.posix.E.PERM))))
        return error.BleAccessDenied;
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
        return error.BleAccessDenied;
    log("f9d: 无法连接 system bus（BlueZ 未运行或未启用）", .{});
    return error.BluezUnavailable;
}

// ---- sd-bus 读取/构造小工具 ----

fn check(r: c_int) Error!void {
    if (r < 0) {
        // 只记返回码（不含地址/路径）：sd-bus 的 -EINVAL 等能指向构造错误
        log("f9d: sd-bus 调用失败: rc={d}", .{r});
        return error.DbusError;
    }
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
/// 装/卸通知订阅分别计数：订阅泄漏（装而不卸）会让后续事务收到过期通知，
/// 必须由测试钉住成对调用。
const FakeGatt = struct {
    frames: []const []const u8 = &.{},
    read_count: usize = 0,
    notify_count: usize = 0,
    end_notify_count: usize = 0,
    writes: [6][frame_len]u8 = undefined,
    write_count: usize = 0,
    /// 写失败：验证失败路径同样执行 endNotify（defer 覆盖所有出口）。
    fail_write: bool = false,

    fn beginNotify(self: *FakeGatt) Error!void {
        self.notify_count += 1;
    }

    fn endNotify(self: *FakeGatt) void {
        self.end_notify_count += 1;
    }

    fn writeFrame(self: *FakeGatt, raw: []const u8) Error!void {
        if (self.fail_write) return error.Timeout;
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

/// 构造 data 全为 fill、长度 n 的响应帧（测试用，避免数组重复初始化器）。
fn fillResponse(buf: *[frame_len]u8, command: protocol.Command, offset: u16, fill: u8, n: usize) []const u8 {
    var data = std.mem.zeroes([max_payload]u8);
    @memset(data[0..n], fill);
    return responseFrame(buf, command, offset, @intCast(n), data[0..n]);
}

/// 测试用对象树：模拟 GetManagedObjects 的条目（对象路径 / 接口 / 属性），
/// 按 `walkObjects` 相同的顺序逐项喂给 visitor。
const TestObject = struct {
    path: [:0]const u8,
    iface: [:0]const u8,
    props: Props,
};

fn visitTree(objects: []const TestObject, ctx: anytype) Error!bool {
    for (objects) |*o| {
        if (try ctx.visit(o.path, o.iface, &o.props)) return true;
    }
    return false;
}

/// 构造固定字符串属性（仅测试用：短字面量，不做长度校验）。
fn strOf(comptime s: []const u8) Str {
    comptime std.debug.assert(s.len < path_max - 1);
    var out: Str = .{};
    @memcpy(out.buf[0..s.len], s);
    out.buf[s.len] = 0;
    out.len = s.len;
    return out;
}

test "服务/特征归属：多设备对象树只采纳选中设备下的服务与特征" {
    const dev_a = "/org/bluez/hci0/dev_AA";
    const dev_b = "/org/bluez/hci0/dev_BB";
    const svc_a = dev_a ++ "/service0001";
    const svc_b = dev_b ++ "/service0001";
    const chr_a = svc_a ++ "/char0002";
    const chr_b = svc_b ++ "/char0002";

    // 两台同类设备同时在线：另一台设备的服务/特征刻意排在前面，
    // 只按 UUID 全局查找就会把 dev_B 的服务关联给 dev_A。
    const objects = [_]TestObject{
        .{ .path = dev_a, .iface = device_iface, .props = .{ .uuid_hit = true } },
        .{ .path = dev_b, .iface = device_iface, .props = .{ .name = strOf(device_name) } },
        .{ .path = svc_b, .iface = gatt_service_iface, .props = .{ .uuid = strOf(service_uuid), .device = strOf(dev_b) } },
        .{ .path = chr_b, .iface = char_iface, .props = .{ .uuid = strOf(write_uuid), .service = strOf(svc_b), .flag_write = true } },
        .{ .path = svc_a, .iface = gatt_service_iface, .props = .{ .uuid = strOf(service_uuid), .device = strOf(dev_a) } },
        .{ .path = chr_a, .iface = char_iface, .props = .{ .uuid = strOf(write_uuid), .service = strOf(svc_a), .flag_write = true } },
    };

    // 候选收集不提前结束：两台设备都进候选表，顺序与对象树一致
    var cands: Candidates = .{};
    try std.testing.expect(!try visitTree(&objects, &FindDevices{ .out = &cands }));
    try std.testing.expectEqual(@as(usize, 2), cands.len);
    try std.testing.expectEqualStrings(dev_a, cands.paths[0].slice());
    try std.testing.expectEqualStrings(dev_b, cands.paths[1].slice());

    var svc: Str = .{};
    try std.testing.expect(try visitTree(&objects, &FindService{ .out = &svc, .device = cands.paths[0].slice() }));
    try std.testing.expectEqualStrings(svc_a, svc.slice()); // 不是排在前面的 dev_B 服务

    var chr: Str = .{};
    const wfind = FindCharacteristic{ .out = &chr, .uuid = write_uuid, .service = svc.slice(), .flag = .write };
    try std.testing.expect(try visitTree(&objects, &wfind));
    try std.testing.expectEqualStrings(chr_a, chr.slice());

    // 选中另一台设备时仍能各自命中，且只命中自己那棵子树
    var svc_other: Str = .{};
    try std.testing.expect(try visitTree(&objects, &FindService{ .out = &svc_other, .device = dev_b }));
    try std.testing.expectEqualStrings(svc_b, svc_other.slice());

    // 选中设备没有目标服务时不得借用别人的：只保留 dev_B 那棵子树
    var none: Str = .{};
    try std.testing.expect(!try visitTree(objects[0..3], &FindService{ .out = &none, .device = dev_a }));
}

test "读请求编码向量（0x05, offset 0, length 15）" {
    var buf: [frame_len]u8 = undefined;
    try encodeRead(&buf, .settings_read, 0, max_payload);
    var want = std.mem.zeroes([frame_len]u8);
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
    const block: [max_payload]u8 = @splat(0xAB);
    var buf: [frame_len]u8 = undefined;
    try encodeWrite(&buf, .settings_write, 0x0102, &block);
    try std.testing.expectEqual(@as(u8, 0x06), buf[1]);
    try std.testing.expectEqual(@as(u8, max_payload), buf[2]);
    try std.testing.expectEqualSlices(u8, &.{ 0x02, 0x01 }, buf[3..5]);
    try std.testing.expectEqualSlices(u8, &block, buf[5..20]);

    const big = std.mem.zeroes([max_payload + 1]u8);
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
    const zeros = std.mem.zeroes([max_payload]u8);
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
    const f14 = fillResponse(&m, .settings_read, 0, 0, max_payload - 1);
    try std.testing.expectError(error.LengthMismatch, decodeResponse(f14, .settings_read, 0, max_payload));

    raw[4] = 1;
    try std.testing.expectError(error.OffsetMismatch, decodeResponse(full, .settings_read, 0, max_payload));
}

test "事务：普通命令必须等到匹配通知，旧通知丢弃" {
    var stale: [frame_len]u8 = undefined;
    const zeros = std.mem.zeroes([max_payload]u8);
    const f_stale = responseFrame(&stale, .settings_write, 0, max_payload, &zeros); // 旧命令
    var ok: [frame_len]u8 = undefined;
    const fill: [max_payload]u8 = @splat(0xA5);
    const f_ok = responseFrame(&ok, .settings_read, 0, max_payload, &fill);
    var g: FakeGatt = .{ .frames = &.{ f_stale, f_ok } };

    var req: [frame_len]u8 = undefined;
    try encodeRead(&req, .settings_read, 0, max_payload);
    const d = try transact(&g, .settings_read, 0, max_payload, &req);
    try std.testing.expectEqualSlices(u8, &fill, d.bytes());
    try std.testing.expectEqualSlices(u8, &req, &g.writes[0]); // 写出的就是这一帧
    try std.testing.expectEqual(@as(usize, 2), g.read_count); // 旧帧被丢弃后继续等
    try std.testing.expectEqual(@as(usize, 1), g.notify_count); // 订阅在写之前装好
    try std.testing.expectEqual(@as(usize, 1), g.end_notify_count); // 事务结束即卸载
}

test "事务：会话命令只等 GATT 写完成，不等通知" {
    var g: FakeGatt = .{}; // frames 为空：一旦等通知就会 Timeout
    var req: [frame_len]u8 = undefined;
    try encodeSession(&req, true);
    _ = try transact(&g, .session_open, 0, 0, &req);
    try std.testing.expectEqual(@as(usize, 1), g.write_count);
    try std.testing.expectEqual(@as(usize, 0), g.read_count);
    try std.testing.expectEqual(@as(usize, 0), g.notify_count); // 不为会话命令装订阅
    try std.testing.expectEqual(@as(usize, 0), g.end_notify_count); // 也就无需卸载

    // close 同样是 fire-and-forget：写的是 0x02 标记，且不等通知
    var g2: FakeGatt = .{};
    try encodeSession(&req, false);
    _ = try transact(&g2, .session_close, 0, 0, &req);
    try std.testing.expectEqual(@as(u8, 0x02), g2.writes[0][5]);
    try std.testing.expectEqual(@as(usize, 0), g2.notify_count);
}

test "事务：坏帧立即失败，等不到通知报 Timeout" {
    var bad: [frame_len]u8 = undefined;
    const f_bad = responseFrame(&bad, .live_status, 0, 3, &.{ 0, 0, 0 });
    bad[0] = 0xdd;
    var g1: FakeGatt = .{ .frames = &.{f_bad} };
    var req: [frame_len]u8 = undefined;
    try encodeRead(&req, .live_status, 0, 3);
    try std.testing.expectError(error.BadMagic, transact(&g1, .live_status, 0, 3, &req));

    try std.testing.expectEqual(@as(usize, 1), g1.end_notify_count); // 坏帧出口也卸载订阅

    var g2: FakeGatt = .{};
    try std.testing.expectError(error.Timeout, transact(&g2, .live_status, 0, 3, &req));
    try std.testing.expectEqual(@as(usize, 1), g2.end_notify_count);
}

test "事务：写失败时同样卸载通知订阅，不留下半套订阅" {
    var req: [frame_len]u8 = undefined;
    try encodeRead(&req, .live_status, 0, 3);

    var g: FakeGatt = .{ .fail_write = true };
    try std.testing.expectError(error.Timeout, transact(&g, .live_status, 0, 3, &req));
    try std.testing.expectEqual(@as(usize, 1), g.notify_count);
    try std.testing.expectEqual(@as(usize, 1), g.end_notify_count); // defer 覆盖失败出口
    try std.testing.expectEqual(@as(usize, 0), g.read_count);
}

test "事务：长度/offset 不符的通知视为旧通知丢弃，匹配帧随后被接受" {
    var wrong_len: [frame_len]u8 = undefined;
    const f_len = fillResponse(&wrong_len, .settings_read, 0, 0, max_payload - 1);
    var wrong_off: [frame_len]u8 = undefined;
    const f_off = fillResponse(&wrong_off, .settings_read, 1, 0, max_payload);
    var ok: [frame_len]u8 = undefined;
    const fill: [max_payload]u8 = @splat(0x5A);
    const f_ok = responseFrame(&ok, .settings_read, 0, max_payload, &fill);
    var g: FakeGatt = .{ .frames = &.{ f_len, f_off, f_ok } };

    var req: [frame_len]u8 = undefined;
    try encodeRead(&req, .settings_read, 0, max_payload);
    const d = try transact(&g, .settings_read, 0, max_payload, &req);
    try std.testing.expectEqualSlices(u8, &fill, d.bytes());
    try std.testing.expectEqual(@as(usize, 3), g.read_count); // 两帧旧通知都被丢弃
}

test "事务：写命令等待 len=payload 长度的匹配通知" {
    const block: [max_payload]u8 = @splat(0xC3);
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
    const f_short = fillResponse(&short, .settings_write, 0, 0, max_payload - 1);
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
// ---------------------------------------------------------------------------
// 离线 sd-bus 消息测试：只构造/解析消息，不连接总线
// ---------------------------------------------------------------------------

/// 离线的 sd_bus 对象：sd_bus_new() 不连接总线，只用于构造与解析消息容器。
/// 这样 parseProps / walkObjects / readChangedValue 的编解码路径能被真实覆盖，
/// 不需要 BlueZ、也不需要系统总线（zig build test 保持离线）。
const TestBus = struct {
    bus: *c.sd_bus,
    peer: std.posix.fd_t,

    /// 离线 bus：socketpair + sd_bus_start 让 bus 进入“已启动”状态，但不连接
    /// system bus（BlueZ 不参与）。sd-bus 只允许在已启动的 bus 上构造消息容器，
    /// 直接 sd_bus_new 会以 -ENOTCONN 拒绝。测试结束只关对端 fd，bus 侧随 bus 释放。
    fn init() !TestBus {
        var fds: [2]std.posix.fd_t = undefined;
        if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds) != 0) return error.SkipZigTest;
        errdefer std.posix.close(fds[0]);
        errdefer std.posix.close(fds[1]);

        var bus: ?*c.sd_bus = null;
        try check(c.sd_bus_new(&bus));
        const b = bus orelse return error.SkipZigTest;
        errdefer _ = c.sd_bus_flush_close_unref(b);
        try check(c.sd_bus_set_fd(b, fds[0], fds[0]));
        try check(c.sd_bus_start(b));
        return .{ .bus = b, .peer = fds[1] };
    }

    fn deinit(self: *TestBus) void {
        std.posix.close(self.peer);
        _ = c.sd_bus_flush_close_unref(self.bus);
    }

    fn newCall(self: *TestBus) !*c.sd_bus_message {
        var m: ?*c.sd_bus_message = null;
        try check(c.sd_bus_message_new_method_call(self.bus, &m, service_name, "/org/bluez/test", "org.test.I", "T"));
        return m orelse error.DbusError;
    }
};

fn appendPropStr(m: *c.sd_bus_message, key: [:0]const u8, typ: u8, contents: [:0]const u8, value: [:0]const u8) !void {
    try check(c.sd_bus_message_open_container(m, 'e', "sv"));
    try appendStr(m, key);
    try check(c.sd_bus_message_open_container(m, 'v', contents));
    try check(c.sd_bus_message_append_basic(m, typ, @ptrCast(value.ptr)));
    try check(c.sd_bus_message_close_container(m)); // v
    try check(c.sd_bus_message_close_container(m)); // e
}

fn appendPropStrs(m: *c.sd_bus_message, key: [:0]const u8, items: []const [:0]const u8) !void {
    try check(c.sd_bus_message_open_container(m, 'e', "sv"));
    try appendStr(m, key);
    try check(c.sd_bus_message_open_container(m, 'v', "as"));
    try check(c.sd_bus_message_open_container(m, 'a', "s"));
    for (items) |s| try appendStr(m, s);
    try check(c.sd_bus_message_close_container(m)); // a
    try check(c.sd_bus_message_close_container(m)); // v
    try check(c.sd_bus_message_close_container(m)); // e
}

fn appendPropBool(m: *c.sd_bus_message, key: [:0]const u8, value: bool) !void {
    var v: c_int = if (value) 1 else 0;
    try check(c.sd_bus_message_open_container(m, 'e', "sv"));
    try appendStr(m, key);
    try check(c.sd_bus_message_open_container(m, 'v', "b"));
    try check(c.sd_bus_message_append_basic(m, 'b', @ptrCast(&v)));
    try check(c.sd_bus_message_close_container(m)); // v
    try check(c.sd_bus_message_close_container(m)); // e
}

fn appendPropBytes(m: *c.sd_bus_message, key: [:0]const u8, value: []const u8) !void {
    try check(c.sd_bus_message_open_container(m, 'e', "sv"));
    try appendStr(m, key);
    try check(c.sd_bus_message_open_container(m, 'v', "ay"));
    try check(c.sd_bus_message_open_container(m, 'a', "y"));
    for (value) |b| try check(c.sd_bus_message_append_basic(m, 'y', @ptrCast(&b)));
    try check(c.sd_bus_message_close_container(m)); // a
    try check(c.sd_bus_message_close_container(m)); // v
    try check(c.sd_bus_message_close_container(m)); // e
}

fn appendPropU32(m: *c.sd_bus_message, key: [:0]const u8, value: u32) !void {
    try check(c.sd_bus_message_open_container(m, 'e', "sv"));
    try appendStr(m, key);
    try check(c.sd_bus_message_open_container(m, 'v', "u"));
    try check(c.sd_bus_message_append_basic(m, 'u', @ptrCast(&value)));
    try check(c.sd_bus_message_close_container(m)); // v
    try check(c.sd_bus_message_close_container(m)); // e
}

/// 消息写完后必须 seal 才能从头读：未 seal 的出站消息 rewind 返回 -EPERM。
fn sealAndRewind(m: *c.sd_bus_message) !void {
    try check(c.sd_bus_message_seal(m, 1, 0));
    try check(c.sd_bus_message_rewind(m, 1));
}

/// 把解析结果 Props 再写成 a{sv}：用于构造 walkObjects 的对象树与属性字典测试消息。
fn appendProps(m: *c.sd_bus_message, p: Props, with_unknown: bool) !void {
    try check(c.sd_bus_message_open_container(m, 'a', "{sv}"));
    if (p.uuid_hit) try appendPropStrs(m, "UUIDs", &.{service_uuid});
    if (p.flag_write or p.flag_notify) {
        var flags: [2][:0]const u8 = undefined;
        var n: usize = 0;
        if (p.flag_write) {
            flags[n] = "write";
            n += 1;
        }
        if (p.flag_notify) {
            flags[n] = "notify";
            n += 1;
        }
        try appendPropStrs(m, "Flags", flags[0..n]);
    }
    if (p.uuid.len > 0) try appendPropStr(m, "UUID", 's', "s", p.uuid.z());
    if (p.service.len > 0) try appendPropStr(m, "Service", 'o', "o", p.service.z());
    if (p.device.len > 0) try appendPropStr(m, "Device", 'o', "o", p.device.z());
    if (p.name.len > 0) try appendPropStr(m, "Name", 's', "s", p.name.z());
    if (p.alias.len > 0) try appendPropStr(m, "Alias", 's', "s", p.alias.z());
    if (p.services_resolved) |b| try appendPropBool(m, "ServicesResolved", b);
    if (p.powered) |b| try appendPropBool(m, "Powered", b);
    if (p.value.len > 0) try appendPropBytes(m, "Value", p.value.ptr[0..p.value.len]);
    if (with_unknown) try appendPropU32(m, "Unknown", 42); // 未建模键：走 skipValue 分支
    try check(c.sd_bus_message_close_container(m));
}

/// 完整属性字典消息：覆盖 parseProps 的每个建模键，外加一个未知键（skipValue）。
fn buildPropsMessage(tb: *TestBus) !*c.sd_bus_message {
    const value = [_]u8{ 0xee, 0x1a, 0x03 };
    const p: Props = .{
        .uuid_hit = true,
        .flag_write = true,
        .flag_notify = true,
        .uuid = strOf(write_uuid),
        .service = strOf("/org/bluez/hci0/dev_AA/service0001"),
        .device = strOf("/org/bluez/hci0/dev_AA"),
        .name = strOf(device_name),
        .alias = strOf("F9"),
        .services_resolved = true,
        .powered = true,
        .value = .{ .ptr = &value, .len = value.len },
    };
    const m = try tb.newCall();
    errdefer _ = c.sd_bus_message_unref(m);
    try appendProps(m, p, true);
    try sealAndRewind(m);
    return m;
}

/// 对象树消息：a{oa{sa{sv}}}，每个 TestObject 一条（路径可重复，测试只关心遍历）。
fn buildObjectsMessage(tb: *TestBus, objects: []const TestObject) !*c.sd_bus_message {
    const m = try tb.newCall();
    errdefer _ = c.sd_bus_message_unref(m);
    try check(c.sd_bus_message_open_container(m, 'a', "{oa{sa{sv}}}"));
    for (objects) |o| {
        try check(c.sd_bus_message_open_container(m, 'e', "oa{sa{sv}}"));
        try check(c.sd_bus_message_append_basic(m, 'o', @ptrCast(o.path.ptr)));
        try check(c.sd_bus_message_open_container(m, 'a', "{sa{sv}}"));
        try check(c.sd_bus_message_open_container(m, 'e', "sa{sv}"));
        try appendStr(m, o.iface);
        try appendProps(m, o.props, false);
        try check(c.sd_bus_message_close_container(m)); // e
        try check(c.sd_bus_message_close_container(m)); // a
        try check(c.sd_bus_message_close_container(m)); // e
    }
    try check(c.sd_bus_message_close_container(m));
    try sealAndRewind(m);
    return m;
}

/// PropertiesChanged 信号消息：sa{sv}as，Value 可缺省。
fn buildChangedMessage(tb: *TestBus, iface: [:0]const u8, value: ?[]const u8) !*c.sd_bus_message {
    var m: ?*c.sd_bus_message = null;
    try check(c.sd_bus_message_new_signal(
        tb.bus,
        &m,
        "/org/bluez/hci0/dev_AA/service0001/char0002",
        props_iface,
        "PropertiesChanged",
    ));
    const msg = m orelse return error.DbusError;
    errdefer _ = c.sd_bus_message_unref(msg);
    try appendStr(msg, iface);
    try check(c.sd_bus_message_open_container(msg, 'a', "{sv}"));
    if (value) |v| {
        try appendPropBytes(msg, "Value", v);
        try appendPropStr(msg, "Other", 's', "s", "x");
    }
    try check(c.sd_bus_message_close_container(msg));
    try check(c.sd_bus_message_open_container(msg, 'a', "s"));
    try check(c.sd_bus_message_close_container(msg));
    try sealAndRewind(msg);
    return msg;
}

test "parseProps：a{sv} 的每个建模键都能解码，未知键被跳过" {
    var tb = try TestBus.init();
    defer tb.deinit();
    const m = try buildPropsMessage(&tb);
    defer _ = c.sd_bus_message_unref(m);

    var p: Props = .{};
    try parseProps(m, &p);
    try std.testing.expect(p.uuid_hit);
    try std.testing.expect(p.flag_write);
    try std.testing.expect(p.flag_notify);
    try std.testing.expectEqualStrings(write_uuid, p.uuid.slice());
    try std.testing.expectEqualStrings("/org/bluez/hci0/dev_AA/service0001", p.service.slice());
    try std.testing.expectEqualStrings("/org/bluez/hci0/dev_AA", p.device.slice());
    try std.testing.expectEqualStrings(device_name, p.name.slice());
    try std.testing.expectEqualStrings("F9", p.alias.slice());
    try std.testing.expectEqual(@as(?bool, true), p.services_resolved);
    try std.testing.expectEqual(@as(?bool, true), p.powered);
    try std.testing.expectEqual(@as(usize, 3), p.value.len);
    try std.testing.expectEqualSlices(u8, &.{ 0xee, 0x1a, 0x03 }, p.value.ptr[0..p.value.len]);
}

test "parseProps：variant 类型不符时跳过该值，游标不破坏、字段保持默认" {
    var tb = try TestBus.init();
    defer tb.deinit();
    const m = try tb.newCall();
    defer _ = c.sd_bus_message_unref(m);
    try check(c.sd_bus_message_open_container(m, 'a', "{sv}"));
    try appendPropU32(m, "UUID", 1); // 期望字符串，实际 u32
    try appendPropStr(m, "Flags", 's', "s", "write"); // 期望 as，实际 s
    try appendPropStrs(m, "ServicesResolved", &.{"x"}); // 期望 b，实际 as
    try appendPropStr(m, "Value", 's', "s", "x"); // 期望 ay，实际 s
    try check(c.sd_bus_message_close_container(m));
    try sealAndRewind(m);

    var p: Props = .{};
    try parseProps(m, &p); // 不报错、不越界：类型不符只是“不采纳”
    try std.testing.expectEqual(@as(usize, 0), p.uuid.len);
    try std.testing.expect(!p.uuid_hit);
    try std.testing.expect(!p.flag_write);
    try std.testing.expectEqual(@as(?bool, null), p.services_resolved);
    try std.testing.expectEqual(@as(usize, 0), p.value.len);
}

test "walkObjects：真实 a{oa{sa{sv}}} 消息驱动候选/服务/特征查找" {
    var tb = try TestBus.init();
    defer tb.deinit();
    const dev_a = "/org/bluez/hci0/dev_AA";
    const dev_b = "/org/bluez/hci0/dev_BB";
    const svc_a = dev_a ++ "/service0001";
    const chr_a = svc_a ++ "/char0002";
    const objects = [_]TestObject{
        .{ .path = dev_a, .iface = device_iface, .props = .{ .uuid_hit = true } },
        .{ .path = dev_b, .iface = device_iface, .props = .{ .name = strOf(device_name) } },
        .{ .path = svc_a, .iface = gatt_service_iface, .props = .{ .uuid = strOf(service_uuid), .device = strOf(dev_a) } },
        .{ .path = chr_a, .iface = char_iface, .props = .{ .uuid = strOf(write_uuid), .service = strOf(svc_a), .flag_write = true } },
        .{ .path = "/unrelated", .iface = "org.example.Other", .props = .{} },
    };
    const m = try buildObjectsMessage(&tb, &objects);
    defer _ = c.sd_bus_message_unref(m);

    var cands: Candidates = .{};
    try std.testing.expect(!try walkObjects(m, &FindDevices{ .out = &cands }));
    try std.testing.expectEqual(@as(usize, 2), cands.len);
    try std.testing.expectEqualStrings(dev_a, cands.paths[0].slice());

    try check(c.sd_bus_message_rewind(m, 1));
    var svc: Str = .{};
    try std.testing.expect(try walkObjects(m, &FindService{ .out = &svc, .device = dev_a }));
    try std.testing.expectEqualStrings(svc_a, svc.slice());

    try check(c.sd_bus_message_rewind(m, 1));
    var chr: Str = .{};
    const wfind = FindCharacteristic{ .out = &chr, .uuid = write_uuid, .service = svc_a, .flag = .write };
    try std.testing.expect(try walkObjects(m, &wfind));
    try std.testing.expectEqualStrings(chr_a, chr.slice());
}

test "readChangedValue：只采纳 Value(ay)，空值与其它接口不置 have" {
    var tb = try TestBus.init();
    defer tb.deinit();

    const m = try buildChangedMessage(&tb, char_iface, &.{ 0xee, 0x1a, 0x03 });
    defer _ = c.sd_bus_message_unref(m);
    var ctx: NotifyCtx = .{};
    try readChangedValue(m, &ctx);
    try std.testing.expect(ctx.have);
    try std.testing.expectEqual(@as(usize, 3), ctx.len);
    try std.testing.expectEqualSlices(u8, &.{ 0xee, 0x1a, 0x03 }, ctx.buf[0..ctx.len]);

    const empty = try buildChangedMessage(&tb, char_iface, &.{});
    defer _ = c.sd_bus_message_unref(empty);
    var empty_ctx: NotifyCtx = .{};
    try readChangedValue(empty, &empty_ctx);
    try std.testing.expect(!empty_ctx.have);

    const other = try buildChangedMessage(&tb, "org.bluez.Other1", &.{ 1, 2 });
    defer _ = c.sd_bus_message_unref(other);
    var other_ctx: NotifyCtx = .{};
    try readChangedValue(other, &other_ctx);
    try std.testing.expect(!other_ctx.have);
}

test "mapCallError：BlueZ/D-Bus 错误名与 errno 映射为可诊断错误" {
    const log_prev = setLogSink(discardLog);
    defer _ = setLogSink(log_prev);
    // 名字优先判定；r 用 -EIO 占位，避免 -1 恰好等于 -EPERM 把名字分支掩盖掉
    const Case = struct { name: [:0]const u8, r: c_int = -@as(c_int, @intCast(@intFromEnum(std.posix.E.IO))), want: Error };
    const cases = [_]Case{
        .{ .name = "org.freedesktop.DBus.Error.AccessDenied", .want = error.BleAccessDenied },
        .{ .name = "org.bluez.Error.NotAuthorized", .want = error.BleAccessDenied },
        .{ .name = "org.freedesktop.DBus.Error.ServiceUnknown", .want = error.BluezUnavailable },
        .{ .name = "org.freedesktop.DBus.Error.NameHasNoOwner", .want = error.BluezUnavailable },
        .{ .name = "org.bluez.Error.NotReady", .want = error.BluezUnavailable },
        .{ .name = "org.freedesktop.DBus.Error.UnknownObject", .want = error.GattUnsupported },
        .{ .name = "org.freedesktop.DBus.Error.UnknownInterface", .want = error.GattUnsupported },
        .{ .name = "org.freedesktop.DBus.Error.UnknownMethod", .want = error.GattUnsupported },
        .{ .name = "org.bluez.Error.DoesNotExist", .want = error.GattUnsupported },
        .{ .name = "org.bluez.Error.InvalidArguments", .want = error.GattUnsupported },
        .{ .name = "org.bluez.Error.NotPermitted", .want = error.GattUnsupported },
        .{ .name = "org.bluez.Error.NotConnected", .want = error.NotConnected },
        .{ .name = "org.bluez.Error.InProgress", .want = error.InProgress },
        .{ .name = "org.bluez.Error.AlreadyConnected", .want = error.InProgress },
        .{ .name = "", .r = -@as(c_int, @intCast(@intFromEnum(std.posix.E.TIMEDOUT))), .want = error.Timeout },
        .{ .name = "", .r = -@as(c_int, @intCast(@intFromEnum(std.posix.E.ACCES))), .want = error.BleAccessDenied },
        .{ .name = "", .r = -@as(c_int, @intCast(@intFromEnum(std.posix.E.PERM))), .want = error.BleAccessDenied },
        .{ .name = "", .r = -@as(c_int, @intCast(@intFromEnum(std.posix.E.CONNRESET))), .want = error.NotConnected },
        .{ .name = "", .r = -@as(c_int, @intCast(@intFromEnum(std.posix.E.PIPE))), .want = error.NotConnected },
        .{ .name = "", .r = -@as(c_int, @intCast(@intFromEnum(std.posix.E.NOTCONN))), .want = error.NotConnected },
        .{ .name = "org.bluez.Error.Failed", .want = error.DbusError },
        .{ .name = "", .r = -@as(c_int, @intCast(@intFromEnum(std.posix.E.INVAL))), .want = error.DbusError },
    };
    for (cases) |case| {
        var err: c.sd_bus_error = std.mem.zeroes(c.sd_bus_error);
        if (case.name.len > 0) err.name = case.name.ptr;
        try std.testing.expectEqual(case.want, mapCallError(&err, case.r));
    }
}

test "候选设备表：按对象树顺序去重，超过上限后忽略" {
    var cands: Candidates = .{};
    try cands.add("/a");
    try cands.add("/a"); // 重复路径只收一次
    try cands.add("/b");
    try std.testing.expectEqual(@as(usize, 2), cands.len);
    var buf: [32]u8 = undefined;
    for (0..10) |i| {
        try cands.add(try std.fmt.bufPrint(&buf, "/p{d}", .{i}));
    }
    try std.testing.expectEqual(max_candidates, cands.len);
    try std.testing.expectEqualStrings("/a", cands.paths[0].slice());
    try std.testing.expectEqualStrings("/p0", cands.paths[2].slice());
}

test "候选错误选择：诊断价值高的错误不被低价值错误覆盖" {
    try std.testing.expectEqual(@as(?Error, error.ConnectTimeout), moreInformative(null, error.ConnectTimeout));
    try std.testing.expectEqual(
        @as(?Error, error.GattUnsupported),
        moreInformative(error.NotConnected, error.GattUnsupported),
    );
    // 低价值候选错误不覆盖已有的高价值错误
    try std.testing.expectEqual(
        @as(?Error, error.GattUnsupported),
        moreInformative(error.GattUnsupported, error.NotConnected),
    );
    try std.testing.expectEqual(
        @as(?Error, error.BleAccessDenied),
        moreInformative(error.GattUnsupported, error.BleAccessDenied),
    );
    // 同等级保持先到者（ConnectTimeout 与 ResolveTimeout 同级）
    try std.testing.expectEqual(
        @as(?Error, error.ConnectTimeout),
        moreInformative(error.ConnectTimeout, error.ResolveTimeout),
    );
}

test "readChangedValue：缺少 Value 键或 Value 非 ay 都不置 have" {
    var tb = try TestBus.init();
    defer tb.deinit();

    // 只有其它属性、没有 Value
    const no_value = try buildChangedMessage(&tb, char_iface, null);
    defer _ = c.sd_bus_message_unref(no_value);
    var ctx: NotifyCtx = .{};
    try readChangedValue(no_value, &ctx);
    try std.testing.expect(!ctx.have);

    // Value 是字符串而非 ay：跳过该值，继续等真响应
    var m: ?*c.sd_bus_message = null;
    try check(c.sd_bus_message_new_signal(
        tb.bus,
        &m,
        "/org/bluez/hci0/dev_AA/service0001/char0002",
        props_iface,
        "PropertiesChanged",
    ));
    const msg = m orelse return error.DbusError;
    defer _ = c.sd_bus_message_unref(msg);
    try appendStr(msg, char_iface);
    try check(c.sd_bus_message_open_container(msg, 'a', "{sv}"));
    try appendPropStr(msg, "Value", 's', "s", "x");
    try check(c.sd_bus_message_close_container(msg));
    try check(c.sd_bus_message_open_container(msg, 'a', "s"));
    try check(c.sd_bus_message_close_container(msg));
    try sealAndRewind(msg);

    var str_ctx: NotifyCtx = .{};
    try readChangedValue(msg, &str_ctx);
    try std.testing.expect(!str_ctx.have);
}

test "onNotify：只采纳目标特征路径的 PropertiesChanged，消息缺失也不崩" {
    var tb = try TestBus.init();
    defer tb.deinit();
    const m = try buildChangedMessage(&tb, char_iface, &.{ 0xee, 0x1a, 0x03 });
    defer _ = c.sd_bus_message_unref(m);

    var ctx: NotifyCtx = .{};
    try ctx.path.set("/org/bluez/hci0/dev_AA/service0001/char0002"); // 与消息路径一致
    try std.testing.expectEqual(@as(c_int, 0), onNotify(m, @ptrCast(&ctx), null));
    try std.testing.expect(ctx.have);

    // 同一 match 规则下别的特征/设备的信号：不能当成本次响应
    var other: NotifyCtx = .{};
    try other.path.set("/org/bluez/hci0/dev_BB/service0001/char0009");
    try std.testing.expectEqual(@as(c_int, 0), onNotify(m, @ptrCast(&other), null));
    try std.testing.expect(!other.have);

    // 回调必须能容忍空消息/空上下文（sd-bus 允许传 null）
    try std.testing.expectEqual(@as(c_int, 0), onNotify(null, @ptrCast(&ctx), null));
    try std.testing.expectEqual(@as(c_int, 0), onNotify(m, null, null));
}

test "查找 visitor：适配器、别名命中与特征 flag/归属过滤" {
    const dev = "/org/bluez/hci0/dev_AA";
    const svc = dev ++ "/service0001";
    const write_chr = svc ++ "/char0002";
    const notify_chr = svc ++ "/char0003";
    const objects = [_]TestObject{
        .{ .path = "/org/bluez/hci0", .iface = adapter_iface, .props = .{} },
        .{ .path = "/org/bluez/hci0/dev_BB", .iface = device_iface, .props = .{ .alias = strOf(device_name) } },
        .{ .path = "/org/bluez/hci0/dev_CC", .iface = device_iface, .props = .{ .name = strOf("Keyboard") } },
        .{ .path = svc, .iface = gatt_service_iface, .props = .{ .uuid = strOf(service_uuid), .device = strOf(dev) } },
        .{ .path = write_chr, .iface = char_iface, .props = .{ .uuid = strOf(write_uuid), .service = strOf(svc), .flag_write = true } },
        .{ .path = notify_chr, .iface = char_iface, .props = .{ .uuid = strOf(notify_uuid), .service = strOf(svc), .flag_notify = true } },
    };

    // 适配器对象没有 Powered 属性：仍记为兜底候选，但不算“找到已启用的适配器”
    var adapter: Str = .{};
    try std.testing.expect(!try visitTree(&objects, &FindAdapter{ .out = &adapter }));
    try std.testing.expectEqualStrings("/org/bluez/hci0", adapter.slice());

    // 广告里没有服务 UUID 时按名称/Alias 收集候选；名字不符的键盘不进候选表
    var cands: Candidates = .{};
    try std.testing.expect(!try visitTree(&objects, &FindDevices{ .out = &cands }));
    try std.testing.expectEqual(@as(usize, 1), cands.len);
    try std.testing.expectEqualStrings("/org/bluez/hci0/dev_BB", cands.paths[0].slice());

    // 通知特征：只认 flag 为 notify 的那条
    var notify_char: Str = .{};
    const nfind = FindCharacteristic{ .out = &notify_char, .uuid = notify_uuid, .service = svc, .flag = .notify };
    try std.testing.expect(try visitTree(&objects, &nfind));
    try std.testing.expectEqualStrings(notify_chr, notify_char.slice());

    // 特征挂在别的服务下（UUID 对、归属错）：不采纳
    var none: Str = .{};
    const wrong_owner = FindCharacteristic{ .out = &none, .uuid = write_uuid, .service = "/other/service", .flag = .write };
    try std.testing.expect(!try visitTree(&objects, &wrong_owner));

    // flag 不满足（write 特征当 notify 找）：不采纳
    const wrong_flag = FindCharacteristic{ .out = &none, .uuid = write_uuid, .service = svc, .flag = .notify };
    try std.testing.expect(!try visitTree(&objects, &wrong_flag));
}

test "FindAdapter：多适配器时优先 Powered=true 的那个" {
    const objects = [_]TestObject{
        // 内置 hci0 关闭、外接 hci1 开启：先入为主会锁到没启用的那个
        .{ .path = "/org/bluez/hci0", .iface = adapter_iface, .props = .{ .powered = false } },
        .{ .path = "/org/bluez/hci1", .iface = adapter_iface, .props = .{ .powered = true } },
    };
    var adapter: Str = .{};
    try std.testing.expect(try visitTree(&objects, &FindAdapter{ .out = &adapter }));
    try std.testing.expectEqualStrings("/org/bluez/hci1", adapter.slice());

    // 全都未启用：保留首个候选，由 open 报“蓝牙未启用”，而不是伪装成设备不在
    var off: Str = .{};
    try std.testing.expect(!try visitTree(objects[0..1], &FindAdapter{ .out = &off }));
    try std.testing.expectEqualStrings("/org/bluez/hci0", off.slice());
}

test "parseGatt：一次 GetManagedObjects 定位服务与两个特征，不依赖对象树顺序" {
    var tb = try TestBus.init();
    defer tb.deinit();
    const dev = "/org/bluez/hci0/dev_AA";
    const svc = dev ++ "/service0001";
    const wchr = svc ++ "/char0002";
    const nchr = svc ++ "/char0003";
    // 特征刻意排在所属服务之前：单遍扫描会漏掉，先定服务再 rewind 挑特征则不会
    const objects = [_]TestObject{
        .{ .path = wchr, .iface = char_iface, .props = .{ .uuid = strOf(write_uuid), .service = strOf(svc), .flag_write = true } },
        .{ .path = nchr, .iface = char_iface, .props = .{ .uuid = strOf(notify_uuid), .service = strOf(svc), .flag_notify = true } },
        .{ .path = svc, .iface = gatt_service_iface, .props = .{ .uuid = strOf(service_uuid), .device = strOf(dev) } },
    };
    const m = try buildObjectsMessage(&tb, &objects);
    defer _ = c.sd_bus_message_unref(m);

    const gatt = try parseGatt(m, dev);
    try std.testing.expectEqualStrings(svc, gatt.service.slice());
    try std.testing.expectEqualStrings(wchr, gatt.write.slice());
    try std.testing.expectEqualStrings(nchr, gatt.notify.slice());

    // 换一台设备：不得借用别人的服务/特征
    try std.testing.expectError(error.GattUnsupported, parseGatt(m, "/org/bluez/hci0/dev_BB"));
}

test "Str.set：超长路径不截断，直接报 DbusError" {
    var s: Str = .{};
    const too_long = [_]u8{'p'} ** path_max;
    try std.testing.expectError(error.DbusError, s.set(&too_long));
    try std.testing.expectEqual(@as(usize, 0), s.len); // 失败不留半个字符串

    try s.set("/a");
    try std.testing.expectEqualStrings("/a", s.slice());
    try std.testing.expectEqual(@as(u8, 0), s.buf[2]); // z() 依赖的 NUL 结尾
}

test "remainingUsec：已过期的期限返回 1us，未过期按毫秒折算" {
    try std.testing.expectEqual(@as(u64, 1), remainingUsec(monoMs() - 1000));
    const left = remainingUsec(monoMs() + 1000);
    try std.testing.expect(left > 900 * std.time.us_per_ms and left <= 1000 * std.time.us_per_ms);
}

test "encodeRead：非零 offset 按小端写入，payload 补零" {
    var buf: [frame_len]u8 = undefined;
    try encodeRead(&buf, .live_status, 0x0102, 3);
    try std.testing.expectEqualSlices(u8, &.{ magic, 0x1a, 0x03, 0x02, 0x01 }, buf[0..5]);
    for (buf[5..]) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "nextFrame：事务期限是绝对期限，事务内不按帧续期" {
    // 只验证期限判定：期限已过期时必须在触碰 bus 之前就返回 Timeout。
    var dev: Device = .{
        .bus = undefined,
        .device_path = .{},
        .write_path = .{},
        .notify_path = .{},
        .budget_ms = monoMs() + 30_000,
        .notify_deadline_ms = monoMs() - 1, // 事务开始时定下的期限已过
    };
    try std.testing.expectError(error.Timeout, dev.nextFrame());
}

test "beginRequest：复用链路时重置整请求预算" {
    var dev: Device = .{
        .bus = undefined, // 只验证预算字段，不碰 bus
        .device_path = .{},
        .write_path = .{},
        .notify_path = .{},
        .budget_ms = monoMs() - 1, // 上个请求已把预算耗尽
    };
    try std.testing.expectError(error.Timeout, dev.read(.live_status, 0, 3));
    dev.beginRequest();
    try std.testing.expect(dev.budget_ms > monoMs());
}

test "预算耗尽：read/write/session 直接 Timeout，不再发起 D-Bus 调用" {
    var dev: Device = .{
        .bus = undefined, // 预算检查在触碰 bus 之前返回
        .device_path = .{},
        .write_path = .{},
        .notify_path = .{},
        .budget_ms = monoMs() - 1,
    };
    try std.testing.expectError(error.Timeout, dev.read(.live_status, 0, 3));
    try std.testing.expectError(error.Timeout, dev.write(.settings_write, 0, &.{0}));
    try std.testing.expectError(error.Timeout, dev.session(false));
}
