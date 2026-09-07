//! 设备标识常量（confirmed，SPEC §7.1）。
//!
//! BLE 地址可能变化：禁止硬编码、写入示例或提交日志。

/// USB VID。
pub const USB_VID: u16 = 0x17ef;
/// USB PID。
pub const USB_PID: u16 = 0xf00c;
/// USB 产品标识字符串。
pub const USB_PRODUCT: &str = "LEGION_F9_Wired";
/// BLE 广播名称。
pub const BLE_NAME: &str = "LEGION_F9_BT";

/// BLE 服务 UUID。
pub const BLE_SERVICE_UUID: &str = "19090909-0a0a-0b0b-0c0c-0d0d0e0e0f0f";
/// BLE 写特征 UUID（主机 → 设备）。
pub const BLE_WRITE_UUID: &str = "19190909-0a0a-0b0b-0c0c-0d0d0e0e0f0f";
/// BLE 通知特征 UUID（设备 → 主机）。
pub const BLE_NOTIFY_UUID: &str = "19290909-0a0a-0b0b-0c0c-0d0d0e0e0f0f";

/// 非官方声明（README/文档统一口径，SPEC §16.3）。
pub const UNOFFICIAL_NOTICE: &str =
    "非官方社区项目。Lenovo 和 Legion 是其各自权利人的商标；本项目与 Lenovo 无关联、无背书。";
