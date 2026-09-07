//! USB HID 传输（report ID 4）：Linux 稳定、Windows 实验（SPEC §6、§10.2）。

pub mod discover;
pub mod transport;

pub use discover::{discover_usb, list_usb_candidates, usb_candidates_public};
pub use transport::UsbTransport;

use f9_transport::Capability;

/// 当前平台能力（SPEC §6 能力矩阵）。
pub fn platform_capability() -> Capability {
    if cfg!(target_os = "linux") {
        Capability::Stable
    } else {
        Capability::Experimental
    }
}

/// 非 Linux/Windows 平台：v1 明确不支持。
pub const SUPPORTED_PLATFORM: bool = cfg!(any(target_os = "linux", target_os = "windows"));
