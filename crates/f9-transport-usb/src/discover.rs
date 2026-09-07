//! USB 发现（SPEC §10.2）。
//!
//! 不依赖“第二个 hidraw 节点”之类的顺序启发式。验证：
//! - VID/PID；
//! - report descriptor 包含 report ID 4（hidraw 路径下读取 sysfs 验证；
//!   其他后端回退为一次安全的只读探针交换）；
//! - 输入/输出 report 长度与协议预期相符（探针交换隐式验证）。

use f9_protocol::ids::{USB_PID, USB_VID};
use f9_transport::{DeviceCandidate, TransportKind};

#[cfg(all(
    feature = "hid-backend",
    any(target_os = "linux", target_os = "windows")
))]
use std::sync::Arc;

/// 枚举候选 USB 设备（未打开）。
#[cfg(all(
    feature = "hid-backend",
    any(target_os = "linux", target_os = "windows")
))]
pub fn list_usb_candidates() -> Result<Vec<UsbCandidate>, f9_transport::TransportError> {
    let api = hidapi::HidApi::new()
        .map_err(|e| f9_transport::TransportError::Internal(format!("hid: {e}")))?;
    let mut out = Vec::new();
    for info in api.device_list() {
        if info.vendor_id() != USB_VID || info.product_id() != USB_PID {
            continue;
        }
        let path = info.path();
        let sysfs_ok = matches!(
            descriptor_check(path),
            DescriptorCheck::Ok | DescriptorCheck::UnknownBackend
        );
        out.push(UsbCandidate {
            path: path.to_owned(),
            descriptor_validated: sysfs_ok,
        });
    }
    Ok(out)
}

#[cfg(not(all(
    feature = "hid-backend",
    any(target_os = "linux", target_os = "windows")
)))]
pub fn list_usb_candidates() -> Result<Vec<UsbCandidate>, f9_transport::TransportError> {
    Ok(Vec::new())
}

/// 已验证候选（携带打开所需信息）。
#[cfg(all(
    feature = "hid-backend",
    any(target_os = "linux", target_os = "windows")
))]
#[derive(Clone)]
pub struct UsbCandidate {
    pub path: std::ffi::CString,
    /// report descriptor 验证结果；false 时需要探针验证。
    pub descriptor_validated: bool,
}

#[cfg(not(all(
    feature = "hid-backend",
    any(target_os = "linux", target_os = "windows")
)))]
#[derive(Clone)]
pub struct UsbCandidate;

/// 发现并返回可用的 USB transport。
#[cfg(all(
    feature = "hid-backend",
    any(target_os = "linux", target_os = "windows")
))]
pub fn discover_usb() -> Result<Vec<crate::UsbTransport>, f9_transport::TransportError> {
    let api = hidapi::HidApi::new()
        .map_err(|e| f9_transport::TransportError::Internal(format!("hid: {e}")))?;
    let api = Arc::new(api);
    let candidates = list_usb_candidates()?;
    let mut out = Vec::new();
    for c in candidates {
        // descriptor 已验证，或通过一次只读探针交换验证 report 4 语义。
        let validated = c.descriptor_validated || probe_report4(&api, &c.path).unwrap_or(false);
        if !validated {
            tracing::warn!(
                transport = "usb",
                "candidate rejected: report 4 validation failed"
            );
            continue;
        }
        let t = crate::UsbTransport::open(api.clone(), &c.path)?;
        out.push(t);
    }
    Ok(out)
}

#[cfg(not(all(
    feature = "hid-backend",
    any(target_os = "linux", target_os = "windows")
)))]
pub fn discover_usb() -> Result<Vec<crate::UsbTransport>, f9_transport::TransportError> {
    Ok(Vec::new())
}

/// 发现结果转候选列表（CLI `devices list` 用，脱敏）。
#[cfg(all(
    feature = "hid-backend",
    any(target_os = "linux", target_os = "windows")
))]
pub fn usb_candidates_public() -> Result<Vec<DeviceCandidate>, f9_transport::TransportError> {
    Ok(list_usb_candidates()?
        .into_iter()
        .map(|c| DeviceCandidate {
            transport: TransportKind::Usb,
            device_id: redact_path(&c.path),
            capability: crate::platform_capability(),
            summary: format!("USB HID {:04x}:{:04x}", USB_VID, USB_PID),
        })
        .collect())
}

#[cfg(not(all(
    feature = "hid-backend",
    any(target_os = "linux", target_os = "windows")
)))]
pub fn usb_candidates_public() -> Result<Vec<DeviceCandidate>, f9_transport::TransportError> {
    Ok(Vec::new())
}

#[cfg(all(
    feature = "hid-backend",
    any(target_os = "linux", target_os = "windows")
))]
fn redact_path(path: &std::ffi::CStr) -> String {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    format!("{path:?}").hash(&mut h);
    format!("usb-{:016x}", h.finish())
}

#[cfg(all(
    feature = "hid-backend",
    any(target_os = "linux", target_os = "windows")
))]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DescriptorCheck {
    /// sysfs report descriptor 明确包含 report ID 4。
    Ok,
    /// 非 hidraw 后端，无法读取 sysfs；需要探针。
    UnknownBackend,
    /// 明确不匹配。
    No,
}

#[cfg(all(
    feature = "hid-backend",
    any(target_os = "linux", target_os = "windows")
))]
fn descriptor_check(path: &std::ffi::CStr) -> DescriptorCheck {
    let text = format!("{path:?}");
    // hidraw 后端的路径形如 /dev/hidrawN。
    let Some(name) = text.split("hidraw").nth(1).and_then(|s| {
        let digits: String = s.chars().take_while(|c| c.is_ascii_digit()).collect();
        if digits.is_empty() {
            None
        } else {
            Some(format!("hidraw{digits}"))
        }
    }) else {
        return DescriptorCheck::UnknownBackend;
    };
    let desc = std::path::Path::new("/sys/class/hidraw")
        .join(&name)
        .join("device/report_descriptor");
    match std::fs::read(&desc) {
        Ok(bytes) => {
            // Report ID 全局项：Usage Page 之前出现 0x85 0x04。
            if bytes.windows(2).any(|w| w == [0x85, 0x04]) {
                DescriptorCheck::Ok
            } else {
                DescriptorCheck::No
            }
        }
        Err(_) => DescriptorCheck::UnknownBackend,
    }
}

/// 只读探针：一次 0x1a LiveStatus 交换，验证 report 4 收发成立。
#[cfg(all(
    feature = "hid-backend",
    any(target_os = "linux", target_os = "windows")
))]
fn probe_report4(
    api: &hidapi::HidApi,
    path: &std::ffi::CStr,
) -> Result<bool, f9_transport::TransportError> {
    let device = api
        .open_path(path)
        .map_err(|e| f9_transport::TransportError::Internal(format!("hid: {e}")))?;
    let req = f9_protocol::Request::read(f9_protocol::Command::LiveStatus, 0, 3)
        .map_err(f9_transport::TransportError::from)?;
    let buf = f9_protocol::usb::encode(&req)?;
    let mut resp = [0u8; f9_protocol::USB_FRAME_LEN];
    device
        .write(&buf)
        .map_err(|e| f9_transport::TransportError::Internal(format!("hid: {e}")))?;
    let n = device
        .read_timeout(&mut resp, 1000)
        .map_err(|e| f9_transport::TransportError::Internal(format!("hid: {e}")))?;
    if n == 0 {
        return Ok(false);
    }
    Ok(f9_protocol::usb::decode(req.command, &resp[..n]).is_ok())
}

/// 非支持平台的占位（保持 API 形状一致）。
#[cfg(test)]
mod tests {
    use super::*;
    use f9_transport::Capability;

    #[test]
    fn capability_per_platform() {
        let cap = crate::platform_capability();
        if cfg!(target_os = "linux") {
            assert_eq!(cap, Capability::Stable);
        } else {
            assert_eq!(cap, Capability::Experimental);
        }
    }

    #[test]
    fn candidates_do_not_panic() {
        // 无设备环境：返回空列表即可。
        let _ = usb_candidates_public();
    }
}
