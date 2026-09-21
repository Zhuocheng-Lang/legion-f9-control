//! legion-f9-control 库根：两个可执行文件共用的唯一模块。
//!
//! - `f9ctl`（src/main.zig）：命令行工具，人读 + JSON 输出
//! - `f9d`（src/daemon.zig）：温控 daemon
//!
//! 移植顺序按 .legacy/docs/architecture.md：protocol → transport → core → ipc。
//! 新模块加在 src/ 下，并在这里 re-export，避免调用方直接按文件路径 import。

const std = @import("std");

pub const product_name = "legion-f9-control";

test "库根可编译、可被测试" {
    try std.testing.expectEqualStrings("legion-f9-control", product_name);
}
