//! 实时状态解码（confirmed，SPEC §7.5）。
//!
//! ```text
//! flag    = data[0]
//! rpm_raw = little_endian(data[1], data[2])
//! rpm     = rpm_raw >> 2
//! ```
//!
//! 未知尾部不得赋予未经证实的语义，仅可通过 `unknown_fields` 原样暴露。

use crate::error::ProtocolError;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DeviceStatus {
    /// flag 字节（语义未完全建模，原样暴露）。
    pub flag: u8,
    /// rpm = rpm_raw >> 2。
    pub rpm: u16,
    /// 原始 rpm 字段。
    pub rpm_raw: u16,
}

impl DeviceStatus {
    /// 原始帧内位于 3 字节之后的未知尾部（expert 输出用）。
    pub fn unknown_fields<'a>(&self, _data: &'a [u8]) -> &'a [u8] {
        &[]
    }
}

/// 校验至少 3 字节并解码状态。
pub fn decode_status(data: &[u8]) -> Result<DeviceStatus, ProtocolError> {
    if data.len() < 3 {
        return Err(ProtocolError::ShortFrame {
            expected: 3,
            got: data.len(),
        });
    }
    let flag = data[0];
    let rpm_raw = u16::from_le_bytes([data[1], data[2]]);
    Ok(DeviceStatus {
        flag,
        rpm: rpm_raw >> 2,
        rpm_raw,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_flag_and_shifted_rpm() {
        let s = decode_status(&[0x02, 0xF4, 0x1F]).unwrap();
        assert_eq!(s.flag, 0x02);
        assert_eq!(s.rpm_raw, 0x1FF4);
        // 0x1FF4 >> 2 = 0x7FD = 2045
        assert_eq!(s.rpm, 0x1FF4 >> 2);
    }

    #[test]
    fn rejects_short() {
        for len in [0usize, 1, 2] {
            let data = vec![0u8; len];
            assert!(matches!(
                decode_status(&data),
                Err(ProtocolError::ShortFrame { expected: 3, got: got_len }) if got_len == len
            ));
        }
    }

    #[test]
    fn accepts_longer_data() {
        let s = decode_status(&[1, 0x10, 0x27, 0xde, 0xad]).unwrap();
        assert_eq!(s.rpm, (0x2710 >> 2) as u16);
    }
}
