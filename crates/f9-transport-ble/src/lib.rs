//! BLE 传输（Linux；Windows BLE 在 v1 明确不支持，SPEC §6、§10.3）。
//!
//! 事实基准（confirmed）：
//! - 服务 `19090909-...`；写特征（主机→设备）`19190909-...`；通知特征 `19290909-...`；
//! - 会话命令 `0x01`/`0x02` 不等待通知，fire-and-forget；
//! - 响应匹配帧头/command/length/offset，不能只用 `[7]` 判错；
//! - 只允许一个 in-flight 请求；通知队列有上限；write-with-response。

pub mod transport;

#[cfg(target_os = "linux")]
pub mod discover;

pub use transport::BleTransport;

use f9_transport::TransportKind;

/// v1 仅 Linux 支持 BLE（SPEC §6）。
pub const SUPPORTED_PLATFORM: bool = cfg!(target_os = "linux");

/// 平台能力：Linux BLE 为 v1 发布门槛，标注 stable。
pub fn platform_capability() -> f9_transport::Capability {
    if cfg!(target_os = "linux") {
        f9_transport::Capability::Stable
    } else {
        f9_transport::Capability::Experimental
    }
}

pub fn kind() -> TransportKind {
    TransportKind::Ble
}

/// 通知队列容量上限（溢出丢弃并计数，产生结构化警告）。
pub const NOTIFY_QUEUE_CAPACITY: usize = 16;
