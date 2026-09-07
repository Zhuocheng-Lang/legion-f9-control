//! 发现模型与传输种类。

use thiserror::Error;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TransportKind {
    Usb,
    Ble,
}

impl TransportKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Usb => "usb",
            Self::Ble => "ble",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
#[error("unknown transport {0:?}")]
pub struct UnknownTransportKind(pub String);

impl std::str::FromStr for TransportKind {
    type Err = UnknownTransportKind;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "usb" => Ok(Self::Usb),
            "ble" => Ok(Self::Ble),
            other => Err(UnknownTransportKind(other.to_owned())),
        }
    }
}

/// 一个候选设备的发现结果。
///
/// `device_id` 为脱敏稳定会话标识（不得含真实 MAC/序列号）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceCandidate {
    pub transport: TransportKind,
    pub device_id: String,
    pub capability: crate::Capability,
    /// 供 human 输出的简短描述（已脱敏）。
    pub summary: String,
}
