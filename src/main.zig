//! f9ctl 命令行入口。诊断日志一律走 stderr，stdout 只出结果（人读或 JSON）。

const std = @import("std");
const f9 = @import("f9");

pub fn main() !void {
    try std.fs.File.stdout().writeAll(
        f9.product_name ++ " f9ctl: 尚未实现（Zig 移植进行中）\n" ++
            "用法: f9ctl [--output json] <status|info|mode|monitor|raw|config|daemon>\n",
    );
}
