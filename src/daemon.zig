//! f9d：Legion F9 设备 daemon。独占 hidraw 设备，经 Unix socket 向 f9ctl
//! 提供单行请求 / JSON 响应服务（协议见 ipc.zig）。前台运行，日志走 stderr
//! （systemd 收进 journal）；由 init 系统负责生命周期与重启。

const std = @import("std");
const f9 = @import("f9");

const usb = f9.usb;
const ops = f9.ops;
const ipc = f9.ipc;

/// 客户端连上后保持沉默的上限，防止单个连接堵死所有请求。
const conn_read_timeout_ms = 5000;

/// 设备句柄：惰性打开（设备可能晚于 daemon 启动插入），失败后丢弃。
const State = struct {
    dev: ?usb.Device = null,

    fn ensure(st: *State) !usb.Device {
        if (st.dev == null) {
            st.dev = try usb.Device.open();
            log("f9d: 设备已连接", .{});
        }
        return st.dev.?;
    }

    /// ponytail: 任何事务错误都丢弃句柄、由下个请求惰性重开来覆盖拔插；
    /// 不做重试/退避，拔插频繁到日志噪声时可再加。
    fn drop(st: *State) void {
        if (st.dev) |*d| d.close();
        st.dev = null;
    }
};

pub fn main() void {
    run() catch |err| {
        log("f9d: 启动失败: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run() !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = ipc.daemonSocketPath(&path_buf);
    const is_root = std.posix.geteuid() == 0;
    if (is_root) std.fs.makeDirAbsolute(ipc.root_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |e| return e,
    };

    // 防双开：能连上说明已有实例在跑；连不上则清掉陈旧 socket 文件再绑定。
    if (std.net.connectUnixSocket(path)) |s| {
        s.close();
        return error.AlreadyRunning;
    } else |_| {
        std.fs.deleteFileAbsolute(path) catch {};
    }

    const addr = try std.net.Address.initUnix(path);
    var server = try addr.listen(.{});
    // root 实例放开给任意本地用户（风扇控制，低敏）；要收紧就换用户组/polkit。
    if (is_root) try std.posix.fchmodat(std.posix.AT.FDCWD, path, 0o666, 0);
    log("f9d: 监听 {s}", .{path});

    var st: State = .{};
    defer st.drop();
    // ponytail: 单线程顺序 accept；设备会话本身要求串行，并发需求出现时再上线程。
    while (true) {
        const conn = server.accept() catch |err| {
            log("f9d: accept 失败: {s}", .{@errorName(err)});
            continue;
        };
        serve(conn.stream, &st);
        conn.stream.close();
    }
}

fn serve(stream: std.net.Stream, st: *State) void {
    serveInner(stream, st) catch |err| {
        log("f9d: 连接处理失败: {s}", .{@errorName(err)});
    };
}

fn serveInner(stream: std.net.Stream, st: *State) !void {
    var rbuf: [ipc.max_request_len]u8 = undefined;
    const line = try ipc.readLine(stream, &rbuf, conn_read_timeout_ms);
    var wbuf: [ipc.max_reply_len]u8 = undefined;
    const out = dispatch(st, line, &wbuf);
    try stream.writeAll(out);
    try stream.writeAll("\n");
}

fn dispatch(st: *State, line: []const u8, buf: []u8) []const u8 {
    const req = ipc.parseRequest(line) catch |err| return ipc.formatError(buf, err);
    return runRequest(st, req, buf) catch |err| return ipc.formatError(buf, err);
}

fn runRequest(st: *State, req: ipc.Request, buf: []u8) ![]const u8 {
    const dev = try st.ensure();
    // ensure 之后发生的任何错误都视为设备链路问题，丢弃句柄待下次重开
    return onDevice(dev, req, buf) catch |err| {
        st.drop();
        return err;
    };
}

fn onDevice(dev: usb.Device, req: ipc.Request, buf: []u8) ![]const u8 {
    return switch (req) {
        .status => ipc.formatStatus(buf, try ops.status(dev)),
        .gear_get => ipc.formatGear(buf, try ops.gearGet(dev)),
        .gear_set => |g| blk: {
            try ops.gearSet(dev, g);
            break :blk ipc.formatGear(buf, try ops.gearGet(dev)); // 回读确认
        },
    };
}

fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    std.fs.File.stderr().writeAll(line) catch {};
}

test {
    std.testing.refAllDecls(@This());
}
