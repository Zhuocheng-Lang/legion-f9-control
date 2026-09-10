//! USB HID transport 实现（Linux 稳定 / Windows 实验）。
//!
//! 交换模型：编码为 64 字节 report 4 帧 → 写 → 带超时读 → 解码。
//! 单请求互斥由 `Device` 层与 `Mutex<hidapi::Device>` 双重保证。

use std::sync::Arc;

use async_trait::async_trait;
use f9_protocol::usb as frame;
use f9_protocol::{Request, Response};
use f9_transport::{ExchangePolicy, Transport, TransportError, TransportIdentity};

use crate::SUPPORTED_PLATFORM;

#[cfg(all(
    feature = "hid-backend",
    any(target_os = "linux", target_os = "windows")
))]
struct HidHandle {
    _api: Arc<hidapi::HidApi>,
    device: hidapi::HidDevice,
}

/// USB transport。未启用 hid-backend 或平台不支持时，exchange 返回 Unsupported。
pub struct UsbTransport {
    identity: TransportIdentity,
    #[cfg(all(
        feature = "hid-backend",
        any(target_os = "linux", target_os = "windows")
    ))]
    handle: Arc<std::sync::Mutex<Option<HidHandle>>>,
}

impl UsbTransport {
    /// 用已验证的 hidapi 设备路径构造。
    #[cfg(all(
        feature = "hid-backend",
        any(target_os = "linux", target_os = "windows")
    ))]
    pub fn open(api: Arc<hidapi::HidApi>, path: &std::ffi::CStr) -> Result<Self, TransportError> {
        if !SUPPORTED_PLATFORM {
            return Err(TransportError::Unsupported);
        }
        let device = api.open_path(path).map_err(hid_err)?;
        // 排空上一次会话残留的数据：设备会主动推送 report 3 短通知，
        // 且重连瞬间可能还有未读帧；不排空会污染第一次交换（真机实测：
        // 拔插后首个 exchange 读到 3 字节旧通知 → ShortFrame）。
        let mut discard = [0u8; 256];
        while device.read_timeout(&mut discard, 20).unwrap_or(0) > 0 {}
        Ok(Self {
            identity: TransportIdentity {
                kind: f9_transport::TransportKind::Usb,
                device_id: redacted_usb_id(path),
                capability: crate::platform_capability(),
            },
            handle: Arc::new(std::sync::Mutex::new(Some(HidHandle { _api: api, device }))),
        })
    }

    /// 不带 hidapi 的构造（仅用于 Unsupported 占位/纯逻辑测试）。
    #[cfg(not(all(
        feature = "hid-backend",
        any(target_os = "linux", target_os = "windows")
    )))]
    pub fn unsupported() -> Self {
        Self {
            identity: TransportIdentity {
                kind: f9_transport::TransportKind::Usb,
                device_id: "usb-unavailable".to_owned(),
                capability: Capability::Experimental,
            },
        }
    }

    #[cfg(all(
        feature = "hid-backend",
        any(target_os = "linux", target_os = "windows")
    ))]
    #[allow(dead_code)] // 保留给平台适配层（Windows usage 检查等）使用。
    fn with_device<R>(
        &self,
        f: impl FnOnce(&mut hidapi::HidDevice) -> Result<R, TransportError>,
    ) -> Result<R, TransportError> {
        let mut guard = self.handle.lock().expect("usb handle lock");
        let Some(h) = guard.as_mut() else {
            return Err(TransportError::Disconnected);
        };
        f(&mut h.device)
    }
}

#[cfg(all(
    feature = "hid-backend",
    any(target_os = "linux", target_os = "windows")
))]
fn with_handle<R>(
    handle: &Arc<std::sync::Mutex<Option<HidHandle>>>,
    f: impl FnOnce(&mut hidapi::HidDevice) -> Result<R, TransportError>,
) -> Result<R, TransportError> {
    let mut guard = handle.lock().expect("usb handle lock");
    let Some(h) = guard.as_mut() else {
        return Err(TransportError::Disconnected);
    };
    f(&mut h.device)
}

/// 生成脱敏、会话稳定的 USB 设备标识（不含序列号/私有路径）。
#[cfg(all(
    feature = "hid-backend",
    any(target_os = "linux", target_os = "windows")
))]
fn redacted_usb_id(path: &std::ffi::CStr) -> String {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    format!("{path:?}").hash(&mut h);
    format!("usb-{:016x}", h.finish())
}

#[cfg(all(
    feature = "hid-backend",
    any(target_os = "linux", target_os = "windows")
))]
fn hid_err(e: hidapi::HidError) -> TransportError {
    match e {
        hidapi::HidError::OpenHidDeviceWithDeviceInfoError { .. } => TransportError::Disconnected,
        hidapi::HidError::IoError { .. } => TransportError::Disconnected,
        // hidraw 后端：设备拔出时读/写返回 HidApiError（ENODEV / "No such device"）。
        // 映射为 Disconnected，让上层退避重连逻辑接管（真机实测 2026-09-10）。
        hidapi::HidError::HidApiError { .. } | hidapi::HidError::HidApiErrorEmpty => {
            TransportError::Disconnected
        }
        _ => TransportError::Internal(format!("hid: {e}")),
    }
}

#[async_trait]
impl Transport for UsbTransport {
    async fn exchange(
        &self,
        request: Request,
        policy: ExchangePolicy,
    ) -> Result<Response, TransportError> {
        #[cfg(not(all(
            feature = "hid-backend",
            any(target_os = "linux", target_os = "windows")
        )))]
        {
            let _ = (request, policy);
            Err(TransportError::Unsupported)
        }

        #[cfg(all(
            feature = "hid-backend",
            any(target_os = "linux", target_os = "windows")
        ))]
        {
            if !SUPPORTED_PLATFORM {
                return Err(TransportError::Unsupported);
            }
            let frame_buf = frame::encode(&request)?;
            let read_ms = policy.timeout.as_millis().min(i32::MAX as u128) as i32;
            let handle = self.handle.clone();
            let res = tokio::task::spawn_blocking(move || {
                // 写：完整 64 字节 report。
                with_handle(&handle, |d| {
                    let n = d.write(&frame_buf).map_err(hid_err)?;
                    if n != f9_protocol::USB_FRAME_LEN {
                        return Err(TransportError::Internal(format!("short hid write: {n}")));
                    }
                    Ok(())
                })?;
                // 读：带超时；跳过设备主动推送的 report 3 短通知与残帧。
                // 设备随时可能推送 3 字节通知（PROTOCOL.md §1），若恰好
                // 夹在请求-响应之间，直接把短帧当结果会误报协议违规
                // （真机实测：拔插重连后首个交换必现）。
                let deadline = std::time::Instant::now()
                    + std::time::Duration::from_millis(read_ms.max(0) as u64);
                let mut buf = [0u8; f9_protocol::USB_FRAME_LEN];
                let n = loop {
                    let remaining = deadline.saturating_duration_since(std::time::Instant::now());
                    if remaining.is_zero() {
                        break 0usize;
                    }
                    let n = with_handle(&handle, |d| {
                        d.read_timeout(&mut buf, remaining.as_millis().min(i32::MAX as u128) as i32)
                            .map_err(hid_err)
                    })?;
                    if n == f9_protocol::USB_FRAME_LEN {
                        break n;
                    }
                    if n == 0 {
                        break 0usize;
                    }
                    // 短帧：非目标数据（通知/残帧），丢弃继续等真正的响应。
                    tracing::debug!(transport = "usb", dropped_short = n, "跳过非响应短帧");
                };
                if n == 0 {
                    return Err(TransportError::Timeout);
                }
                frame::decode(&request, &buf[..n]).map_err(TransportError::Protocol)
            })
            .await;
            match res {
                Ok(inner) => inner,
                Err(join) => Err(TransportError::Internal(format!("hid task: {join}"))),
            }
        }
    }

    async fn close(&self) -> Result<(), TransportError> {
        #[cfg(all(
            feature = "hid-backend",
            any(target_os = "linux", target_os = "windows")
        ))]
        {
            *self.handle.lock().expect("usb handle lock") = None;
        }
        Ok(())
    }

    fn identity(&self) -> &TransportIdentity {
        &self.identity
    }
}
