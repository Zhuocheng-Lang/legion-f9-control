//! f9d 配置文件模型与校验（SPEC §13.2）。
//!
//! - schema_version 必须显式存在；
//! - 未识别字段默认报错（防止拼写静默失效）；
//! - 启动前完整校验，错误配置不得部分生效；
//! - `config validate` 不访问硬件。

use serde::{Deserialize, Serialize};

use crate::control::CurvePoint;
use f9_protocol::Gear;

pub const CONFIG_SCHEMA_VERSION: u32 = 1;

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DaemonConfig {
    pub schema_version: u32,
    #[serde(default)]
    pub device: DeviceSection,
    #[serde(default)]
    pub daemon: DaemonSection,
    #[serde(default)]
    pub logging: LoggingSection,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DeviceSection {
    #[serde(default = "default_transport")]
    pub transport: String,
    /// 不得默认写入 MAC/序列号；仅允许会话内显式选择器。
    #[serde(default)]
    pub selector: Option<String>,
}

fn default_transport() -> String {
    "auto".to_owned()
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DaemonSection {
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default = "default_poll")]
    pub poll_interval: String,
    #[serde(default = "default_dwell")]
    pub min_dwell: String,
    #[serde(default = "default_hysteresis")]
    pub hysteresis_c: f64,
    #[serde(default)]
    pub allow_turbo: bool,
    #[serde(default = "default_failure_threshold")]
    pub failure_threshold: u8,
    #[serde(default = "default_true")]
    pub read_only_recovery: bool,
    #[serde(default)]
    pub curve: Vec<CurveEntry>,
}

fn default_true() -> bool {
    true
}
fn default_poll() -> String {
    "3s".to_owned()
}
fn default_dwell() -> String {
    "15s".to_owned()
}
fn default_hysteresis() -> f64 {
    3.0
}
fn default_failure_threshold() -> u8 {
    3
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct CurveEntry {
    pub at_c: f64,
    pub mode: Gear,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct LoggingSection {
    #[serde(default = "default_level")]
    pub level: String,
    #[serde(default = "default_format")]
    pub format: String,
    #[serde(default = "default_true")]
    pub redact_device_ids: bool,
}

impl Default for LoggingSection {
    fn default() -> Self {
        Self {
            level: default_level(),
            format: default_format(),
            redact_device_ids: true,
        }
    }
}

fn default_level() -> String {
    "info".to_owned()
}
fn default_format() -> String {
    "human".to_owned()
}

impl Default for DaemonSection {
    fn default() -> Self {
        Self {
            enabled: true,
            poll_interval: default_poll(),
            min_dwell: default_dwell(),
            hysteresis_c: default_hysteresis(),
            allow_turbo: false,
            failure_threshold: default_failure_threshold(),
            read_only_recovery: true,
            curve: Vec::new(),
        }
    }
}

impl Default for DaemonConfig {
    fn default() -> Self {
        Self {
            schema_version: CONFIG_SCHEMA_VERSION,
            device: DeviceSection::default(),
            daemon: default_daemon_section(),
            logging: LoggingSection::default(),
        }
    }
}

fn default_daemon_section() -> DaemonSection {
    DaemonSection {
        curve: vec![
            CurveEntry {
                at_c: 0.0,
                mode: Gear::Quiet,
            },
            CurveEntry {
                at_c: 50.0,
                mode: Gear::Balanced,
            },
            CurveEntry {
                at_c: 60.0,
                mode: Gear::Beast,
            },
        ],
        ..DaemonSection::default()
    }
}

impl DaemonConfig {
    /// 完整校验。错误配置不得部分生效。
    pub fn validate(&self) -> Result<(), String> {
        if self.schema_version != CONFIG_SCHEMA_VERSION {
            return Err(format!(
                "不支持的配置 schema_version {}（期望 {}）",
                self.schema_version, CONFIG_SCHEMA_VERSION
            ));
        }
        if !matches!(self.device.transport.as_str(), "auto" | "usb" | "ble") {
            return Err(format!(
                "device.transport 必须是 auto|usb|ble，得到 {:?}",
                self.device.transport
            ));
        }
        crate::parse_duration(&self.daemon.poll_interval)
            .map_err(|e| format!("daemon.poll_interval: {e}"))?;
        crate::parse_duration(&self.daemon.min_dwell)
            .map_err(|e| format!("daemon.min_dwell: {e}"))?;
        if self.daemon.curve.is_empty() {
            return Err("daemon.curve 不能为空".to_owned());
        }
        let cfg = self.control_config()?;
        cfg.validate()?;
        Ok(())
    }

    /// 转换为 f9-core 控制配置（curve 须按 at_c 升序）。
    pub fn control_config(&self) -> Result<crate::control::ControlConfig, String> {
        let dwell = crate::parse_duration(&self.daemon.min_dwell)
            .map_err(|e| format!("daemon.min_dwell: {e}"))?;
        let mut curve: Vec<CurvePoint> = self
            .daemon
            .curve
            .iter()
            .map(|c| CurvePoint {
                at_c: c.at_c,
                gear: c.mode,
            })
            .collect();
        curve.sort_by(|a, b| {
            a.at_c
                .partial_cmp(&b.at_c)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        Ok(crate::control::ControlConfig {
            min_dwell_ms: dwell.as_millis() as u64,
            hysteresis_c: self.daemon.hysteresis_c,
            allow_turbo: self.daemon.allow_turbo,
            failure_threshold: self.daemon.failure_threshold,
            curve,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const EXAMPLE: &str = r#"
schema_version = 1

[device]
transport = "auto"

[daemon]
enabled = true
poll_interval = "3s"
min_dwell = "15s"
hysteresis_c = 3.0
allow_turbo = false
failure_threshold = 3
read_only_recovery = true

[[daemon.curve]]
at_c = 0.0
mode = "quiet"

[[daemon.curve]]
at_c = 50.0
mode = "balanced"

[[daemon.curve]]
at_c = 60.0
mode = "beast"

[logging]
level = "info"
format = "human"
redact_device_ids = true
"#;

    #[test]
    fn parses_and_validates_example() {
        let cfg: DaemonConfig = toml::from_str(EXAMPLE).unwrap();
        assert!(cfg.validate().is_ok());
        let cc = cfg.control_config().unwrap();
        assert_eq!(cc.min_dwell_ms, 15_000);
        assert_eq!(cc.hysteresis_c, 3.0);
        assert!(!cc.allow_turbo);
        assert_eq!(cc.curve.len(), 3);
    }

    #[test]
    fn unknown_field_rejected() {
        let bad = EXAMPLE.replace("poll_interval = \"3s\"", "poll_intervel = \"3s\"");
        assert!(toml::from_str::<DaemonConfig>(&bad).is_err());
    }

    #[test]
    fn wrong_schema_version_rejected() {
        let bad = EXAMPLE.replace("schema_version = 1", "schema_version = 99");
        let cfg: DaemonConfig = toml::from_str(&bad).unwrap();
        assert!(cfg.validate().is_err());
    }

    #[test]
    fn bad_transport_rejected() {
        let bad = EXAMPLE.replace("transport = \"auto\"", "transport = \"serial\"");
        let cfg: DaemonConfig = toml::from_str(&bad).unwrap();
        assert!(cfg.validate().is_err());
    }

    #[test]
    fn bad_duration_rejected() {
        let bad = EXAMPLE.replace("min_dwell = \"15s\"", "min_dwell = \"fifteen\"");
        let cfg: DaemonConfig = toml::from_str(&bad).unwrap();
        assert!(cfg.validate().is_err());
    }

    #[test]
    fn empty_curve_rejected() {
        let bad: DaemonConfig = toml::from_str(EXAMPLE).unwrap();
        let bad = DaemonConfig {
            daemon: DaemonSection {
                curve: vec![],
                ..bad.daemon
            },
            ..bad
        };
        assert!(bad.validate().is_err());
    }
}
