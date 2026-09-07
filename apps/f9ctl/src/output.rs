//! 输出模式：human（中文默认）与 JSON envelope（SPEC §11.2、§11.3）。

use serde_json::{Value, json};

/// JSON envelope schema 版本（SPEC §11.3）。
pub const SCHEMA_VERSION: u32 = 1;

/// 输出格式。
#[derive(Debug, Clone, Copy, PartialEq, Eq, clap::ValueEnum)]
pub enum OutputMode {
    Human,
    Json,
}

/// 单次命令的 JSON envelope。
#[derive(Debug, Clone)]
pub struct Envelope {
    pub command: String,
    pub ok: bool,
    pub device: Option<(String, String)>, // (device_id, transport)
    pub data: Option<Value>,
    pub warnings: Vec<String>,
    pub error: Option<(String, String, bool)>, // (code, message, retryable)
    pub capability: Option<&'static str>,
}

impl Envelope {
    pub fn ok(command: &str) -> Self {
        Self {
            command: command.to_owned(),
            ok: true,
            device: None,
            data: None,
            warnings: Vec::new(),
            error: None,
            capability: None,
        }
    }

    pub fn err(command: &str) -> Self {
        Self {
            ok: false,
            ..Self::ok(command)
        }
    }

    pub fn with_device(mut self, id: &str, transport: &str) -> Self {
        self.device = Some((id.to_owned(), transport.to_owned()));
        self
    }

    pub fn with_data(mut self, data: Value) -> Self {
        self.data = Some(data);
        self
    }

    pub fn with_warning(mut self, w: impl Into<String>) -> Self {
        self.warnings.push(w.into());
        self
    }

    pub fn with_capability(mut self, cap: &'static str) -> Self {
        self.capability = Some(cap);
        self
    }

    pub fn with_error(mut self, code: &str, message: &str, retryable: bool) -> Self {
        self.error = Some((code.to_owned(), message.to_owned(), retryable));
        self
    }

    /// 序列化为 envelope JSON（单次命令）。
    pub fn to_json(&self) -> Value {
        json!({
            "schema_version": SCHEMA_VERSION,
            "ok": self.ok,
            "command": self.command,
            "device": self.device.as_ref().map(|(id, t)| json!({
                "id": id,
                "transport": t,
            })),
            "data": self.data,
            "warnings": self.warnings,
            "capability": self.capability,
            "error": self.error.as_ref().map(|(code, message, retryable)| json!({
                "code": code,
                "message": message,
                "retryable": retryable,
            })),
        })
    }
}

/// status 的 human 渲染（中文）。
pub fn status_human(st: &f9_protocol::DeviceStatus, gear: Option<&str>) -> String {
    let gear = gear.unwrap_or("不可用");
    format!(
        "转速: {} RPM\n挡位: {}\nflag: 0x{:02x}",
        st.rpm, gear, st.flag
    )
}

/// monitor 单事件（JSON Lines，一行一个完整事件）。
pub fn monitor_event_json(
    st: &f9_protocol::DeviceStatus,
    device_id: &str,
    transport: &str,
) -> Value {
    json!({
        "schema_version": SCHEMA_VERSION,
        "ok": true,
        "command": "monitor",
        "device": { "id": device_id, "transport": transport },
        "data": {
            "rpm": st.rpm,
            "flag": format!("0x{:02x}", st.flag),
        },
        "warnings": [],
    })
}

/// info 的 human 渲染；不支持的字段显示“不可用”。
pub fn info_human(info: &[u8], device_info: Option<&[u8]>) -> String {
    let mut s = format!("信息页(0x03): {} 字节\n", info.len());
    s.push_str("  hex: ");
    for b in info {
        s.push_str(&format!("{b:02x} "));
    }
    s.push('\n');
    match device_info {
        Some(d) => {
            s.push_str(&format!("设备信息(0x1d): {} 字节\n", d.len()));
            s.push_str("  hex: ");
            for b in d {
                s.push_str(&format!("{b:02x} "));
            }
            s.push('\n');
        }
        None => s.push_str("设备信息(0x1d): 不可用\n"),
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn envelope_shape() {
        let e = Envelope::ok("status")
            .with_device("redacted-1", "usb")
            .with_data(json!({"rpm": 2012, "gear": "balanced"}));
        let v = e.to_json();
        assert_eq!(v["schema_version"], 1);
        assert_eq!(v["ok"], true);
        assert_eq!(v["command"], "status");
        assert_eq!(v["device"]["transport"], "usb");
        assert_eq!(v["data"]["rpm"], 2012);
        assert_eq!(v["warnings"], json!([]));
    }

    #[test]
    fn envelope_error_shape() {
        let e = Envelope::err("mode.set").with_error("verification_failed", "msg", false);
        let v = e.to_json();
        assert_eq!(v["ok"], false);
        assert_eq!(v["error"]["code"], "verification_failed");
        assert_eq!(v["error"]["retryable"], false);
    }

    #[test]
    fn human_unavailable_fields() {
        let s = info_human(&[1, 2], None);
        assert!(s.contains("不可用"));
        let s2 = status_human(&f9_protocol::decode_status(&[0, 0xF4, 0x1F]).unwrap(), None);
        assert!(s2.contains("不可用"));
    }

    #[test]
    fn monitor_event_is_json_line() {
        let st = f9_protocol::decode_status(&[0x01, 0xF4, 0x1F]).unwrap();
        let v = monitor_event_json(&st, "dev", "usb");
        assert_eq!(v["command"], "monitor");
        assert!(v["data"]["rpm"].is_u64());
    }
}
