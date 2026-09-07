//! 已建模命令与支持集（SPEC §7.3/§7.4）。

use thiserror::Error;

/// 已知命令集合。
///
/// `Modeled` 命令在 v1 正常功能中使用；`KnownUnmodeled` 表示协议已知但
/// v1 正常功能不得调用（raw 默认拒绝），例如 0x20（灯效写）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Command {
    /// 0x01 打开配置会话（BLE 上 fire-and-forget，不等待通知）。
    SessionOpen,
    /// 0x02 关闭/提交配置会话（BLE 上 fire-and-forget）。
    SessionClose,
    /// 0x03 信息页读取。
    InfoPage,
    /// 0x04 已知命令，v1 未建模。
    Known0x04,
    /// 0x05 设置块分块读取。
    SettingsRead,
    /// 0x06 设置块分块写入。
    SettingsWrite,
    /// 0x0d 已知命令，v1 未建模。
    Known0x0d,
    /// 0x1a 实时状态（flag 与 RPM）。
    LiveStatus,
    /// 0x1d 设备信息（仅 USB 正常使用）。
    DeviceInfo,
    /// 0x20 已知为灯效写；v1 正常功能不暴露，raw 默认拒绝。
    LightsWrite,
}

/// 命令字节不属于支持集时的错误。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
#[error("unsupported command 0x{0:02x}")]
pub struct UnsupportedCommand(pub u8);

impl Command {
    /// BLE 支持集（confirmed）：0x01、0x02、0x03、0x04、0x05、0x06、0x0d、0x1a、0x20。
    pub const BLE_SUPPORTED: &'static [u8] =
        &[0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x0d, 0x1a, 0x20];

    pub fn as_u8(self) -> u8 {
        match self {
            Self::SessionOpen => 0x01,
            Self::SessionClose => 0x02,
            Self::InfoPage => 0x03,
            Self::Known0x04 => 0x04,
            Self::SettingsRead => 0x05,
            Self::SettingsWrite => 0x06,
            Self::Known0x0d => 0x0d,
            Self::LiveStatus => 0x1a,
            Self::DeviceInfo => 0x1d,
            Self::LightsWrite => 0x20,
        }
    }

    /// 按字节解析命令；`0x1d` 仅 USB 支持。
    pub fn from_u8(v: u8) -> Result<Self, UnsupportedCommand> {
        Ok(match v {
            0x01 => Self::SessionOpen,
            0x02 => Self::SessionClose,
            0x03 => Self::InfoPage,
            0x04 => Self::Known0x04,
            0x05 => Self::SettingsRead,
            0x06 => Self::SettingsWrite,
            0x0d => Self::Known0x0d,
            0x1a => Self::LiveStatus,
            0x1d => Self::DeviceInfo,
            0x20 => Self::LightsWrite,
            other => return Err(UnsupportedCommand(other)),
        })
    }

    /// 是否为已建模命令（v1 正常功能可用）。
    pub fn is_modeled(self) -> bool {
        matches!(
            self,
            Self::SessionOpen
                | Self::SessionClose
                | Self::InfoPage
                | Self::SettingsRead
                | Self::SettingsWrite
                | Self::LiveStatus
                | Self::DeviceInfo
        )
    }

    /// 是否为已知但未建模命令（raw 默认拒绝）。
    pub fn is_known_unmodeled(self) -> bool {
        matches!(self, Self::Known0x04 | Self::Known0x0d | Self::LightsWrite)
    }

    /// 会话命令在 BLE 上不等待通知，按 fire-and-forget 处理（confirmed）。
    pub fn is_session_command(self) -> bool {
        matches!(self, Self::SessionOpen | Self::SessionClose)
    }

    /// 写命令（配置写）。0x20 虽然是写，但 v1 不在 raw 写白名单内。
    pub fn is_write_command(self) -> bool {
        matches!(self, Self::SettingsWrite)
    }
}

impl TryFrom<u8> for Command {
    type Error = UnsupportedCommand;

    fn try_from(v: u8) -> Result<Self, Self::Error> {
        Self::from_u8(v)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_all_commands() {
        for b in [0x01u8, 0x02, 0x03, 0x04, 0x05, 0x06, 0x0d, 0x1a, 0x1d, 0x20] {
            assert_eq!(Command::from_u8(b).unwrap().as_u8(), b);
        }
    }

    #[test]
    fn unknown_command_rejected() {
        for b in [0x00u8, 0x07, 0x0c, 0x19, 0x21, 0xff] {
            assert!(Command::from_u8(b).is_err());
        }
    }

    #[test]
    fn session_commands_fire_and_forget() {
        assert!(Command::SessionOpen.is_session_command());
        assert!(Command::SessionClose.is_session_command());
        assert!(!Command::SettingsRead.is_session_command());
    }

    #[test]
    fn lights_write_not_modeled() {
        assert!(Command::LightsWrite.is_known_unmodeled());
        assert!(!Command::LightsWrite.is_modeled());
    }
}
