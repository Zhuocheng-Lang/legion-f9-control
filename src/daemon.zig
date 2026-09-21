//! f9d 温控 daemon 入口。由 init 系统拉起，日志走 stderr（systemd 收进 journal）。

const std = @import("std");
const f9 = @import("f9");

pub fn main() !void {
    try std.fs.File.stderr().writeAll(f9.product_name ++ " f9d: 尚未实现（Zig 移植进行中）\n");
}
