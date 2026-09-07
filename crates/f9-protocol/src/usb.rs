//! USB HID 帧（report ID 4，固定 64 字节，confirmed，SPEC §7.2）。
//!
//! ```text
//! [0]     = 0x04
//! [1:2]   = sum(bytes[3..63]) & 0xffff，小端
//! [3]     = command
//! [4]     = payload length
//! [5:6]   = offset，小端
//! [7]     = request 保留字；response status
//! [8:64]  = payload/data
//! ```

use crate::command::Command;
use crate::error::{ProtocolError, ResponseStatus};
use crate::{Request, Response, USB_FRAME_LEN, USB_MAX_PAYLOAD, USB_REPORT_ID};

/// 编码 USB 请求帧。所有容量在编码前检查。
pub fn encode(req: &Request) -> Result<[u8; USB_FRAME_LEN], ProtocolError> {
    let cap = u8::try_from(USB_MAX_PAYLOAD).expect("usb payload capacity fits u8");
    if req.length > cap {
        return Err(ProtocolError::PayloadTooLarge);
    }
    if req.is_write() && req.payload.len() != req.length as usize {
        return Err(ProtocolError::BadLength);
    }
    if req.payload.len() > USB_MAX_PAYLOAD {
        return Err(ProtocolError::PayloadTooLarge);
    }

    let mut frame = [0u8; USB_FRAME_LEN];
    frame[0] = USB_REPORT_ID;
    frame[3] = req.command.as_u8();
    frame[4] = req.length;
    frame[5..7].copy_from_slice(&req.offset.to_le_bytes());
    // [7] 为 request 保留字，恒 0。
    frame[8..8 + req.payload.len()].copy_from_slice(&req.payload);
    let sum: u32 = frame[3..63].iter().map(|b| u32::from(*b)).sum();
    frame[1..3].copy_from_slice(&((sum & 0xffff) as u16).to_le_bytes());
    Ok(frame)
}

/// 解码 USB 响应帧。检查长度、report ID、command 回显、校验和与状态。
pub fn decode(req_cmd: Command, buf: &[u8]) -> Result<Response, ProtocolError> {
    if buf.len() < USB_FRAME_LEN {
        return Err(ProtocolError::ShortFrame {
            expected: USB_FRAME_LEN,
            got: buf.len(),
        });
    }
    if buf.len() > USB_FRAME_LEN {
        return Err(ProtocolError::OversizedFrame {
            expected: USB_FRAME_LEN,
            got: buf.len(),
        });
    }
    if buf[0] != USB_REPORT_ID {
        return Err(ProtocolError::BadReportId {
            expected: USB_REPORT_ID,
            got: buf[0],
        });
    }
    let echo = buf[3];
    let expected_cmd = req_cmd.as_u8();
    if echo != expected_cmd {
        return Err(ProtocolError::CommandMismatch {
            expected: expected_cmd,
            got: echo,
        });
    }
    let sum: u32 = buf[3..63].iter().map(|b| u32::from(*b)).sum();
    let expected_sum = ((sum & 0xffff) as u16).to_le_bytes();
    if buf[1..3] != expected_sum {
        return Err(ProtocolError::BadChecksum {
            expected: u16::from_le_bytes(expected_sum),
            got: u16::from_le_bytes([buf[1], buf[2]]),
        });
    }
    match ResponseStatus::from_u8(buf[7]) {
        None => return Err(ProtocolError::BadStatus(buf[7])),
        Some(ResponseStatus::Busy) => return Err(ProtocolError::DeviceBusy),
        Some(ResponseStatus::Error) => return Err(ProtocolError::DeviceError),
        Some(ResponseStatus::Ok) => {}
    }
    let declared = buf[4] as usize;
    if declared > USB_MAX_PAYLOAD {
        return Err(ProtocolError::ShortData {
            declared,
            got: USB_MAX_PAYLOAD,
        });
    }
    let data_end = 8 + declared;
    if data_end > buf.len() {
        return Err(ProtocolError::ShortData {
            declared,
            got: buf.len() - 8,
        });
    }
    let offset = u16::from_le_bytes([buf[5], buf[6]]);
    Ok(Response {
        command: req_cmd,
        offset,
        data: buf[8..data_end].to_vec(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Command;

    fn read_req(cmd: Command, offset: u16, len: u8) -> Request {
        Request::read(cmd, offset, len).unwrap()
    }

    #[test]
    fn encode_layout() {
        let req = read_req(Command::LiveStatus, 0x1234, 3);
        let f = encode(&req).unwrap();
        assert_eq!(f[0], 0x04);
        assert_eq!(f[3], 0x1a);
        assert_eq!(f[4], 3);
        assert_eq!(&f[5..7], &0x1234u16.to_le_bytes());
        assert_eq!(f[7], 0);
        let sum: u32 = f[3..63].iter().map(|b| u32::from(*b)).sum();
        assert_eq!(&f[1..3], &((sum & 0xffff) as u16).to_le_bytes());
    }

    #[test]
    fn encode_write_layout() {
        let req = Request::write(Command::SettingsWrite, 0, vec![0xAA, 0xBB]).unwrap();
        let f = encode(&req).unwrap();
        assert_eq!(f[4], 2);
        assert_eq!(&f[8..10], &[0xAA, 0xBB]);
        assert!(f[10..].iter().all(|b| *b == 0));
    }

    #[test]
    fn encode_rejects_oversized_length() {
        let mut req = read_req(Command::SettingsRead, 0, 1);
        req.length = 0x7f;
        assert_eq!(encode(&req).unwrap_err(), ProtocolError::PayloadTooLarge);
    }

    #[test]
    fn roundtrip_ok() {
        let req = read_req(Command::SettingsRead, 0, 15);
        let mut resp = encode(&req).unwrap();
        resp[4] = 15;
        resp[7] = 0x00;
        for (i, b) in resp[8..23].iter_mut().enumerate() {
            *b = (i as u8).wrapping_mul(7);
        }
        resp[0] = 0x04;
        let sum: u32 = resp[3..63].iter().map(|b| u32::from(*b)).sum();
        resp[1..3].copy_from_slice(&((sum & 0xffff) as u16).to_le_bytes());
        let out = decode(Command::SettingsRead, &resp).unwrap();
        assert_eq!(out.command, Command::SettingsRead);
        assert_eq!(out.data.len(), 15);
    }

    #[test]
    fn decode_rejects_short_frame() {
        let short = vec![0u8; 32];
        assert!(matches!(
            decode(Command::LiveStatus, &short),
            Err(ProtocolError::ShortFrame {
                expected: 64,
                got: 32
            })
        ));
    }

    #[test]
    fn decode_rejects_bad_report_id() {
        let req = read_req(Command::LiveStatus, 0, 3);
        let mut frame = encode(&req).unwrap();
        frame[0] = 0x05;
        assert!(matches!(
            decode(Command::LiveStatus, &frame),
            Err(ProtocolError::BadReportId { got: 0x05, .. })
        ));
    }

    #[test]
    fn decode_rejects_command_mismatch() {
        let req = read_req(Command::LiveStatus, 0, 3);
        let mut frame = encode(&req).unwrap();
        frame[3] = 0x99;
        assert!(matches!(
            decode(Command::LiveStatus, &frame),
            Err(ProtocolError::CommandMismatch { got: 0x99, .. })
        ));
    }

    #[test]
    fn decode_rejects_bad_checksum() {
        let req = read_req(Command::LiveStatus, 0, 3);
        let mut frame = encode(&req).unwrap();
        frame[1] ^= 0xff;
        assert!(matches!(
            decode(Command::LiveStatus, &frame),
            Err(ProtocolError::BadChecksum { .. })
        ));
    }

    #[test]
    fn decode_maps_busy_and_error() {
        let req = read_req(Command::LiveStatus, 0, 3);
        let patch = |status: u8| {
            let mut frame = encode(&req).unwrap();
            frame[7] = status;
            let sum: u32 = frame[3..63].iter().map(|b| u32::from(*b)).sum();
            frame[1..3].copy_from_slice(&((sum & 0xffff) as u16).to_le_bytes());
            frame
        };
        assert_eq!(
            decode(Command::LiveStatus, &patch(0xfe)).unwrap_err(),
            ProtocolError::DeviceBusy
        );
        assert_eq!(
            decode(Command::LiveStatus, &patch(0xff)).unwrap_err(),
            ProtocolError::DeviceError
        );
        let frame = patch(0x42);
        assert!(matches!(
            decode(Command::LiveStatus, &frame),
            Err(ProtocolError::BadStatus(0x42))
        ));
    }

    #[test]
    fn decode_rejects_declared_length_beyond_capacity() {
        let req = read_req(Command::LiveStatus, 0, 3);
        let mut frame = encode(&req).unwrap();
        frame[4] = 0xff;
        // 校验和必须有效才能到达长度检查。
        let sum: u32 = frame[3..63].iter().map(|b| u32::from(*b)).sum();
        frame[1..3].copy_from_slice(&((sum & 0xffff) as u16).to_le_bytes());
        assert!(matches!(
            decode(Command::LiveStatus, &frame),
            Err(ProtocolError::ShortData { .. })
        ));
    }
}
