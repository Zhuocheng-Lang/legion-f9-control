//! 协议错误类型。解码器必须区分结构错误与设备返回的错误状态。

use thiserror::Error;

/// 设备返回的响应状态（USB bytes[7]，confirmed）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResponseStatus {
    /// 0x00 成功。
    Ok,
    /// 0xfe 忙。
    Busy,
    /// 0xff 错误。
    Error,
}

impl ResponseStatus {
    pub fn from_u8(v: u8) -> Option<Self> {
        match v {
            0x00 => Some(Self::Ok),
            0xfe => Some(Self::Busy),
            0xff => Some(Self::Error),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum ProtocolError {
    #[error("short frame: expected {expected} bytes, got {got}")]
    ShortFrame { expected: usize, got: usize },
    #[error("oversized frame: expected {expected} bytes, got {got}")]
    OversizedFrame { expected: usize, got: usize },
    #[error("bad report id: expected 0x{expected:02x}, got 0x{got:02x}")]
    BadReportId { expected: u8, got: u8 },
    #[error("bad frame header: expected 0x{expected:02x}, got 0x{got:02x}")]
    BadHeader { expected: u8, got: u8 },
    #[error("command echo mismatch: expected 0x{expected:02x}, got 0x{got:02x}")]
    CommandMismatch { expected: u8, got: u8 },
    #[error("offset mismatch: expected 0x{expected:04x}, got 0x{got:04x}")]
    OffsetMismatch { expected: u16, got: u16 },
    #[error("bad checksum: expected 0x{expected:04x}, got 0x{got:04x}")]
    BadChecksum { expected: u16, got: u16 },
    #[error("bad status byte 0x{0:02x}")]
    BadStatus(u8),
    #[error("device reported busy")]
    DeviceBusy,
    #[error("device reported error status")]
    DeviceError,
    #[error("payload too large for frame capacity")]
    PayloadTooLarge,
    #[error("invalid length field")]
    BadLength,
    #[error("data shorter than declared length: declared {declared}, got {got}")]
    ShortData { declared: usize, got: usize },
}
