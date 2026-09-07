//! 设备 API、写事务、安全策略与 daemon 控制逻辑（SPEC §9、§7.6、§12、§13）。

pub mod config;
pub mod control;
pub mod device;
pub mod error;
pub mod locks;
pub mod raw;

pub use control::{ControlConfig, Controller, CurvePoint, DaemonPhase, Decision};
pub use device::{Device, SetGearOutcome};
pub use error::DeviceError;
pub use locks::{DeviceLock, LockError};
pub use raw::{MAX_KNOWN_CONFIG_OFFSET, RawViolation, raw_read_allowed, unsafe_write_digest};

use f9_protocol::{Gear, SettingsBlock};

/// `f9-core` 公共版本（JSON schema 中的 `schema_version` 基准）。
pub const SCHEMA_VERSION: u32 = 1;

/// 常用交换策略。
pub mod policy {
    use f9_transport::ExchangePolicy;
    use std::time::Duration;

    pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(2);
    pub const WRITE_TIMEOUT: Duration = Duration::from_secs(3);

    pub fn default_read() -> ExchangePolicy {
        ExchangePolicy::with_timeout(DEFAULT_TIMEOUT)
    }

    pub fn default_write() -> ExchangePolicy {
        ExchangePolicy::with_timeout(WRITE_TIMEOUT)
    }
}

/// 便捷构造：从 `u8` 解析挡位。
pub fn gear_from_u8(v: u8) -> Option<Gear> {
    Gear::from_u8(v)
}

/// 设置块读取长度。
pub const SETTINGS_READ_LEN: u8 = 15;

/// 解析 `2s`/`500ms`/`1m`/`1h` 类时长。
/// f9ctl 的 `--timeout` 与 daemon 配置共用此实现。
pub fn parse_duration(s: &str) -> Result<std::time::Duration, String> {
    let s = s.trim();
    let (num, unit) = s.split_at(s.find(|c: char| c.is_ascii_alphabetic()).unwrap_or(s.len()));
    let value: u64 = num
        .parse()
        .map_err(|_| format!("invalid duration number: {num:?}"))?;
    let millis = match unit {
        "ms" => value,
        "s" => value * 1000,
        "m" => value * 60_000,
        "h" => value * 3_600_000,
        "" => return Err("duration requires a unit: ms|s|m|h".to_owned()),
        other => return Err(format!("unknown duration unit: {other:?}")),
    };
    Ok(std::time::Duration::from_millis(millis))
}

/// runtime 目录（XDG，SPEC §20.3）。
pub fn runtime_dir() -> std::path::PathBuf {
    if let Some(d) = std::env::var_os("F9_RUNTIME_DIR") {
        return std::path::PathBuf::from(d);
    }
    if let Some(d) = std::env::var_os("XDG_RUNTIME_DIR") {
        return std::path::PathBuf::from(d).join("legion-f9-control");
    }
    if let Some(d) = std::env::var_os("XDG_STATE_HOME") {
        return std::path::PathBuf::from(d).join("legion-f9-control");
    }
    if let Some(d) = std::env::var_os("HOME") {
        return std::path::PathBuf::from(d)
            .join(".local")
            .join("state")
            .join("legion-f9-control");
    }
    std::path::PathBuf::from(".")
}

/// 读回设置块的 wire 请求。
pub fn read_settings_request() -> Result<f9_protocol::Request, DeviceError> {
    f9_protocol::Request::read(f9_protocol::Command::SettingsRead, 0, SETTINGS_READ_LEN)
        .map_err(DeviceError::from)
}

/// 静默校验：读回的块与原块除 byte[13] 外逐字节不变。
pub fn block_differs_only_in_gear(before: &SettingsBlock, after: &SettingsBlock) -> bool {
    before.0[..13] == after.0[..13] && before.0[14] == after.0[14]
}
