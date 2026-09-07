//! raw 调试安全门（SPEC §12）。
//!
//! - 默认只读：仅白名单读取命令（0x03、0x05、0x1a；USB 可加 0x1d）；
//! - 写必须显式解锁：仅允许设置块地址空间内的 0x06 配置写；
//! - 永不提供 OTA / report 5；0x20（灯效写）与已知未建模命令一律拒绝；
//! - `--force` 不能绕过帧结构校验。

use f9_protocol::{Command, Request};

/// 已知配置地址空间上限（15 字节设置块）。
pub const MAX_KNOWN_CONFIG_OFFSET: u16 = 15;

/// raw 违规类型。
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum RawViolation {
    #[error("command 0x{0:02x} is not on the raw read whitelist")]
    ReadNotAllowed(u8),
    #[error("command 0x{0:02x} is not allowed as raw write")]
    WriteNotAllowed(u8),
    #[error("write offset {0} exceeds known config address space")]
    WriteOutOfRange(u16),
    #[error("raw write is locked; unlock with --unsafe-write and confirmation")]
    WriteLocked,
    #[error("command not supported on this transport")]
    TransportUnsupported,
}

/// raw 读取白名单（confirmed 命令）。
pub fn raw_read_allowed(cmd: Command, transport: f9_transport::TransportKind) -> bool {
    use f9_transport::TransportKind as T;
    match cmd {
        Command::InfoPage | Command::SettingsRead | Command::LiveStatus => true,
        Command::DeviceInfo => transport == T::Usb,
        _ => false,
    }
}

/// raw 写白名单：仅 0x06，且写范围必须落在已知配置地址空间内。
pub fn raw_write_in_bounds(req: &Request) -> bool {
    req.command == Command::SettingsWrite
        && req.offset < MAX_KNOWN_CONFIG_OFFSET
        && u16::from(req.length) <= MAX_KNOWN_CONFIG_OFFSET - req.offset
}

/// 计算 raw 写请求的命令摘要（供 TTY 确认词与环境变量 ACK 匹配）。
/// 摘要不包含 payload 内容，避免日志泄露完整敏感数据。
pub fn unsafe_write_digest(req: &Request) -> String {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    req.command.as_u8().hash(&mut h);
    req.offset.hash(&mut h);
    req.length.hash(&mut h);
    // payload 只参与长度与首尾字节的哈希，不完整进入日志。
    if let (Some(first), Some(last)) = (req.payload.first(), req.payload.last()) {
        first.hash(&mut h);
        last.hash(&mut h);
    }
    format!("{:016x}", h.finish())
}

#[cfg(test)]
mod tests {
    use super::*;
    use f9_transport::TransportKind;

    #[test]
    fn read_whitelist() {
        assert!(raw_read_allowed(Command::InfoPage, TransportKind::Usb));
        assert!(raw_read_allowed(Command::SettingsRead, TransportKind::Ble));
        assert!(raw_read_allowed(Command::LiveStatus, TransportKind::Ble));
        assert!(raw_read_allowed(Command::DeviceInfo, TransportKind::Usb));
        assert!(!raw_read_allowed(Command::DeviceInfo, TransportKind::Ble));
    }

    #[test]
    fn everything_else_denied_for_read() {
        for cmd in [
            Command::SessionOpen,
            Command::SessionClose,
            Command::SettingsWrite,
            Command::Known0x04,
            Command::Known0x0d,
            Command::LightsWrite,
        ] {
            for t in [TransportKind::Usb, TransportKind::Ble] {
                assert!(!raw_read_allowed(cmd, t), "{cmd:?} on {t:?}");
            }
        }
    }

    #[test]
    fn write_bounds() {
        let ok = Request::write(Command::SettingsWrite, 0, vec![0u8; 15]).unwrap();
        assert!(raw_write_in_bounds(&ok));
        let partial = Request::write(Command::SettingsWrite, 10, vec![0u8; 5]).unwrap();
        assert!(raw_write_in_bounds(&partial));
        let beyond = Request::write(Command::SettingsWrite, 10, vec![0u8; 6]).unwrap();
        assert!(!raw_write_in_bounds(&beyond));
        let wrong_cmd = Request::write(Command::LightsWrite, 0, vec![0u8; 15]).unwrap();
        assert!(!raw_write_in_bounds(&wrong_cmd));
    }

    #[test]
    fn report_5_is_unrepresentable() {
        // 报告 ID 5 不在任何编码器中：唯一合法的 USB report id 是 4。
        assert_eq!(f9_protocol::USB_REPORT_ID, 0x04);
    }

    #[test]
    fn digest_stable_and_payload_insensitive() {
        let a = Request::write(Command::SettingsWrite, 0, vec![1u8; 15]).unwrap();
        let b = Request::write(Command::SettingsWrite, 0, vec![2u8; 15]).unwrap();
        // 摘要覆盖首尾字节，不同 payload 产生不同摘要。
        assert_ne!(unsafe_write_digest(&a), unsafe_write_digest(&b));
        assert_eq!(unsafe_write_digest(&a), unsafe_write_digest(&a.clone()));
    }
}
