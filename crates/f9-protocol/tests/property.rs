//! 属性测试（SPEC §17.1）：合法请求编码/解码不 panic；任意字节响应不 panic。

use f9_protocol::{BLE_FRAME_LEN, Command, Request, USB_FRAME_LEN, ble, decode_status, usb};
use proptest::prelude::*;

fn arb_command() -> impl Strategy<Value = Command> {
    prop_oneof![
        Just(Command::SessionOpen),
        Just(Command::SessionClose),
        Just(Command::InfoPage),
        Just(Command::Known0x04),
        Just(Command::SettingsRead),
        Just(Command::SettingsWrite),
        Just(Command::Known0x0d),
        Just(Command::LiveStatus),
        Just(Command::DeviceInfo),
        Just(Command::LightsWrite),
    ]
}

fn arb_request() -> impl Strategy<Value = Request> {
    (
        arb_command(),
        0u16..=0xffff,
        1u8..=15,
        proptest::collection::vec(any::<u8>(), 0..=15),
    )
        .prop_map(|(cmd, offset, len, payload)| {
            if payload.is_empty() {
                Request::read(cmd, offset, len).unwrap()
            } else {
                Request::write(cmd, offset, payload).unwrap()
            }
        })
}

proptest! {
    #[test]
    fn usb_encode_never_panics(req in arb_request()) {
        let _ = usb::encode(&req);
    }

    #[test]
    fn usb_decode_never_panics(cmd in arb_command(), buf in proptest::collection::vec(any::<u8>(), 0..=80)) {
        let _ = usb::decode(cmd, &buf);
    }

    #[test]
    fn usb_roundtrip(req in arb_request()) {
        if let Ok(frame) = usb::encode(&req)
            && let Ok(resp) = usb::decode(req.command, &frame)
        {
            prop_assert_eq!(resp.command, req.command);
            prop_assert_eq!(resp.offset, req.offset);
        }
    }

    #[test]
    fn ble_encode_never_panics(req in arb_request()) {
        let _ = ble::encode(&req);
    }

    #[test]
    fn ble_decode_never_panics(req in arb_request(), buf in proptest::collection::vec(any::<u8>(), 0..=40)) {
        let _ = ble::decode(&req, &buf);
    }

    #[test]
    fn ble_roundtrip(req in arb_request()) {
        if let Ok(frame) = ble::encode(&req)
            && let Ok(resp) = ble::decode(&req, &frame)
        {
            prop_assert_eq!(resp.command, req.command);
            prop_assert_eq!(resp.offset, req.offset);
            if req.is_write() {
                prop_assert_eq!(resp.data, req.payload);
            } else {
                // 读请求：响应 data 长度等于请求的 length 字段。
                prop_assert_eq!(resp.data.len(), req.length as usize);
            }
        }
    }

    #[test]
    fn status_decode_never_panics(data in proptest::collection::vec(any::<u8>(), 0..=64)) {
        let _ = decode_status(&data);
    }
}

#[test]
fn frame_lengths_are_the_documented_constants() {
    assert_eq!(USB_FRAME_LEN, 64);
    assert_eq!(BLE_FRAME_LEN, 20);
}
