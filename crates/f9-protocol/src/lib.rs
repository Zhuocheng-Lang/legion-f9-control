//! Legion F9 风扇/散热器协议核心：帧、命令、校验与解析。
//!
//! 本 crate 为纯协议层：**不**依赖 Tokio、HID、BLE 或 CLI（SPEC §8.2）。
//! 所有编码器检查 payload/offset/帧容量；所有解码器拒绝短帧、错命令与错传输格式。
//! 协议事实分级见 `docs/protocol.md`：实现只依赖 `confirmed` 字段作为稳定语义。

pub mod ble;
pub mod command;
pub mod error;
pub mod ids;
pub mod settings;
pub mod status;
pub mod usb;

pub use command::Command;
pub use error::ProtocolError;
pub use settings::{Gear, SettingsBlock};
pub use status::{DeviceStatus, decode_status};

/// USB 帧使用的 HID report ID（confirmed）。
pub const USB_REPORT_ID: u8 = 0x04;
/// USB 帧固定长度（confirmed）。
pub const USB_FRAME_LEN: usize = 64;
/// USB 单帧 payload 容量上限：bytes[8..64]。
pub const USB_MAX_PAYLOAD: usize = 56;
/// BLE 帧固定长度（confirmed）。
pub const BLE_FRAME_LEN: usize = 20;
/// BLE 单帧 payload 上限（confirmed）。
pub const BLE_MAX_PAYLOAD: usize = 15;
/// 设置块长度（confirmed）。
pub const SETTINGS_BLOCK_LEN: usize = 15;

/// 一次设备交换的请求（wire 级，与具体 transport 无关）。
///
/// - 读请求：`payload` 为空，`length` 表示期望读取的长度；
/// - 写请求：`length == payload.len()`。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Request {
    pub command: Command,
    pub offset: u16,
    /// 帧内 length 字段。
    pub length: u8,
    pub payload: Vec<u8>,
}

impl Request {
    /// 构造读请求。
    pub fn read(command: Command, offset: u16, length: u8) -> Result<Self, ProtocolError> {
        if length == 0 {
            return Err(ProtocolError::BadLength);
        }
        Ok(Self {
            command,
            offset,
            length,
            payload: Vec::new(),
        })
    }

    /// 构造写请求。
    pub fn write(command: Command, offset: u16, payload: Vec<u8>) -> Result<Self, ProtocolError> {
        if payload.is_empty() {
            return Err(ProtocolError::BadLength);
        }
        let len = u8::try_from(payload.len()).map_err(|_| ProtocolError::PayloadTooLarge)?;
        Ok(Self {
            command,
            offset,
            length: len,
            payload,
        })
    }

    pub fn is_write(&self) -> bool {
        !self.payload.is_empty()
    }
}

/// 一次成功交换的响应。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Response {
    pub command: Command,
    pub offset: u16,
    pub data: Vec<u8>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn read_request_rejects_zero_length() {
        assert!(Request::read(Command::LiveStatus, 0, 0).is_err());
    }

    #[test]
    fn write_request_rejects_empty_payload() {
        assert!(Request::write(Command::SettingsWrite, 0, Vec::new()).is_err());
    }

    #[test]
    fn write_request_length_matches_payload() {
        let r = Request::write(Command::SettingsWrite, 0, vec![1, 2, 3]).unwrap();
        assert_eq!(r.length, 3);
        assert!(r.is_write());
    }

    #[test]
    fn write_request_rejects_payload_over_255() {
        let big = vec![0u8; 256];
        assert!(Request::write(Command::SettingsWrite, 0, big).is_err());
    }
}
