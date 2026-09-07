//! 设置块与挡位（confirmed，SPEC §7.6）。
//!
//! 前 15 字节视为不透明结构，仅公开 `byte[13] = gear`。
//! 未知字节在 set gear 后必须逐字节不变。

use crate::SETTINGS_BLOCK_LEN;
use crate::error::ProtocolError;

/// 四个固定挡位（confirmed）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(rename_all = "lowercase"))]
pub enum Gear {
    Quiet,
    Balanced,
    Beast,
    Turbo,
}

impl std::str::FromStr for Gear {
    type Err = InvalidGear;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ok(match s {
            "quiet" => Self::Quiet,
            "balanced" => Self::Balanced,
            "beast" => Self::Beast,
            "turbo" => Self::Turbo,
            other => return Err(InvalidGear(other.to_owned())),
        })
    }
}

/// 无效挡位字符串。
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("invalid gear {0:?} (expected quiet|balanced|beast|turbo)")]
pub struct InvalidGear(pub String);

impl Gear {
    pub fn as_u8(self) -> u8 {
        match self {
            Self::Quiet => 0,
            Self::Balanced => 1,
            Self::Beast => 2,
            Self::Turbo => 3,
        }
    }

    pub fn from_u8(v: u8) -> Option<Self> {
        Some(match v {
            0 => Self::Quiet,
            1 => Self::Balanced,
            2 => Self::Beast,
            3 => Self::Turbo,
            _ => return None,
        })
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Quiet => "quiet",
            Self::Balanced => "balanced",
            Self::Beast => "beast",
            Self::Turbo => "turbo",
        }
    }
}

/// 15 字节不透明设置块。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SettingsBlock(pub [u8; SETTINGS_BLOCK_LEN]);

impl SettingsBlock {
    /// 从恰好 15 字节构造。
    pub fn from_bytes(bytes: &[u8]) -> Result<Self, ProtocolError> {
        let arr: [u8; SETTINGS_BLOCK_LEN] =
            bytes.try_into().map_err(|_| ProtocolError::ShortFrame {
                expected: SETTINGS_BLOCK_LEN,
                got: bytes.len(),
            })?;
        Ok(Self(arr))
    }

    pub fn as_bytes(&self) -> &[u8] {
        &self.0
    }

    /// 读取当前挡位（byte[13]）。
    pub fn gear(&self) -> Result<Gear, ProtocolError> {
        Gear::from_u8(self.0[13]).ok_or(ProtocolError::BadStatus(self.0[13]))
    }

    /// 克隆原块并只修改 `byte[13]`；绝不修改未知字节。
    pub fn with_gear(&self, gear: Gear) -> Self {
        let mut next = self.clone();
        next.0[13] = gear.as_u8();
        next
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_block(gear: u8) -> Vec<u8> {
        let mut b = (0..15).collect::<Vec<u8>>();
        b[13] = gear;
        b
    }

    #[test]
    fn gear_byte_position() {
        let block = SettingsBlock::from_bytes(&sample_block(2)).unwrap();
        assert_eq!(block.gear().unwrap(), Gear::Beast);
    }

    #[test]
    fn with_gear_only_touches_byte_13() {
        let block = SettingsBlock::from_bytes(&sample_block(0)).unwrap();
        let next = block.with_gear(Gear::Turbo);
        assert_eq!(next.0[13], 3);
        for (i, (a, b)) in block.0.iter().zip(next.0.iter()).enumerate() {
            if i != 13 {
                assert_eq!(a, b, "byte {i} changed");
            }
        }
    }

    #[test]
    fn invalid_gear_byte_rejected() {
        let block = SettingsBlock::from_bytes(&sample_block(9)).unwrap();
        assert!(block.gear().is_err());
    }

    #[test]
    fn wrong_length_rejected() {
        assert!(SettingsBlock::from_bytes(&[0u8; 14]).is_err());
        assert!(SettingsBlock::from_bytes(&[0u8; 16]).is_err());
    }
}
