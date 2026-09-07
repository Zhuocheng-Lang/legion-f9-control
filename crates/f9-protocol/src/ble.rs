//! BLE 帧（固定 20 字节，confirmed，SPEC §7.3）。
//!
//! ```text
//! request:  [0]=0xee [1]=command [2]=length [3:4]=offset LE [5:20]=payload
//! response: [0]=0xee [1]=command [2]=length [3:4]=offset LE [5:20]=data
//! ```
//!
//! 注意（confirmed）：
//! - 单帧 payload 上限 15 字节；无 USB 式校验和；
//! - 响应不能只用 `[7]` 判错——它在有效响应中属于数据；
//! - `0x01`/`0x02` 会话命令不等待通知，fire-and-forget。

use crate::error::ProtocolError;
use crate::{BLE_FRAME_LEN, BLE_MAX_PAYLOAD, Request, Response};

const BLE_HEADER: u8 = 0xee;

/// 编码 BLE 请求帧。
pub fn encode(req: &Request) -> Result<[u8; BLE_FRAME_LEN], ProtocolError> {
    if req.length as usize > BLE_MAX_PAYLOAD {
        return Err(ProtocolError::PayloadTooLarge);
    }
    if req.is_write() {
        if req.payload.len() != req.length as usize {
            return Err(ProtocolError::BadLength);
        }
        if req.payload.len() > BLE_MAX_PAYLOAD {
            return Err(ProtocolError::PayloadTooLarge);
        }
    }
    let mut frame = [0u8; BLE_FRAME_LEN];
    frame[0] = BLE_HEADER;
    frame[1] = req.command.as_u8();
    frame[2] = req.length;
    frame[3..5].copy_from_slice(&req.offset.to_le_bytes());
    frame[5..5 + req.payload.len()].copy_from_slice(&req.payload);
    Ok(frame)
}

/// 解码 BLE 响应帧。匹配帧头、command、length 与 offset（confirmed）。
pub fn decode(req: &Request, buf: &[u8]) -> Result<Response, ProtocolError> {
    if buf.len() < BLE_FRAME_LEN {
        return Err(ProtocolError::ShortFrame {
            expected: BLE_FRAME_LEN,
            got: buf.len(),
        });
    }
    if buf[0] != BLE_HEADER {
        return Err(ProtocolError::BadHeader {
            expected: BLE_HEADER,
            got: buf[0],
        });
    }
    let echo = buf[1];
    let expected_cmd = req.command.as_u8();
    if echo != expected_cmd {
        return Err(ProtocolError::CommandMismatch {
            expected: expected_cmd,
            got: echo,
        });
    }
    let declared = buf[2] as usize;
    if declared > BLE_MAX_PAYLOAD {
        return Err(ProtocolError::ShortData {
            declared,
            got: BLE_MAX_PAYLOAD,
        });
    }
    let offset = u16::from_le_bytes([buf[3], buf[4]]);
    if offset != req.offset {
        return Err(ProtocolError::OffsetMismatch {
            expected: req.offset,
            got: offset,
        });
    }
    // 数据区在 buf[5..5+declared]；声明长度超过帧容量视为短包。
    if 5 + declared > buf.len() {
        return Err(ProtocolError::ShortData {
            declared,
            got: buf.len() - 5,
        });
    }
    Ok(Response {
        command: req.command,
        offset,
        data: buf[5..5 + declared].to_vec(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Command;

    #[test]
    fn encode_layout() {
        let req = Request::read(Command::LiveStatus, 0x0102, 3).unwrap();
        let f = encode(&req).unwrap();
        assert_eq!(f[0], 0xee);
        assert_eq!(f[1], 0x1a);
        assert_eq!(f[2], 3);
        assert_eq!(&f[3..5], &0x0102u16.to_le_bytes());
    }

    #[test]
    fn encode_rejects_oversized() {
        let mut req = Request::read(Command::SettingsRead, 0, 1).unwrap();
        req.length = 16;
        assert_eq!(encode(&req).unwrap_err(), ProtocolError::PayloadTooLarge);
        let req = Request::write(Command::SettingsWrite, 0, vec![0u8; 16]).unwrap();
        assert_eq!(encode(&req).unwrap_err(), ProtocolError::PayloadTooLarge);
    }

    #[test]
    fn decode_matches_full_frame() {
        let req = Request::read(Command::LiveStatus, 0x0102, 3).unwrap();
        let mut buf = [0u8; 20];
        buf[0] = 0xee;
        buf[1] = 0x1a;
        buf[2] = 3;
        buf[3..5].copy_from_slice(&0x0102u16.to_le_bytes());
        buf[5] = 0x11;
        buf[6] = 0x22;
        buf[7] = 0x33; // 数据字节，不是状态
        let out = decode(&req, &buf).unwrap();
        assert_eq!(out.data, vec![0x11, 0x22, 0x33]);
    }

    #[test]
    fn decode_rejects_header_and_echo() {
        let req = Request::read(Command::LiveStatus, 0, 3).unwrap();
        let mut buf = [0u8; 20];
        buf[0] = 0xdd;
        assert!(matches!(
            decode(&req, &buf),
            Err(ProtocolError::BadHeader { .. })
        ));
        buf[0] = 0xee;
        buf[1] = 0x03;
        assert!(matches!(
            decode(&req, &buf),
            Err(ProtocolError::CommandMismatch { got: 0x03, .. })
        ));
    }

    #[test]
    fn decode_rejects_offset_mismatch() {
        let req = Request::read(Command::SettingsRead, 0x10, 15).unwrap();
        let mut buf = [0u8; 20];
        buf[0] = 0xee;
        buf[1] = 0x05;
        buf[2] = 15;
        buf[3..5].copy_from_slice(&0x20u16.to_le_bytes());
        assert!(matches!(
            decode(&req, &buf),
            Err(ProtocolError::OffsetMismatch {
                expected: 0x10,
                got: 0x20
            })
        ));
    }

    #[test]
    fn decode_rejects_short() {
        let req = Request::read(Command::LiveStatus, 0, 3).unwrap();
        let buf = [0xee, 0x1a];
        assert!(matches!(
            decode(&req, &buf),
            Err(ProtocolError::ShortFrame {
                expected: 20,
                got: 2
            })
        ));
    }

    #[test]
    fn decode_rejects_oversized_declared_length() {
        let req = Request::read(Command::LiveStatus, 0, 3).unwrap();
        let mut buf = [0u8; 20];
        buf[0] = 0xee;
        buf[1] = 0x1a;
        buf[2] = 16;
        assert!(matches!(
            decode(&req, &buf),
            Err(ProtocolError::ShortData { .. })
        ));
    }

    #[test]
    fn session_commands_encode_like_any_other() {
        // 会话命令本身同样编码；fire-and-forget 语义由 transport 层处理。
        let req = Request::write(Command::SessionOpen, 0, vec![0x01]).unwrap();
        let f = encode(&req).unwrap();
        assert_eq!(f[0], 0xee);
        assert_eq!(f[1], 0x01);
        assert_eq!(f[2], 1);
        assert_eq!(f[5], 0x01);
    }
}
