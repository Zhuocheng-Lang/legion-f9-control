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
                // 读：带超时。
                let mut buf = [0u8; f9_protocol::USB_FRAME_LEN];
                let n = with_handle(&handle, |d| {
                    d.read_timeout(&mut buf, read_ms).map_err(hid_err)
                })?;
                if n == 0 {
                    return Err(TransportError::Timeout);
                }
                frame::decode(request.command, &buf[..n]).map_err(TransportError::Protocol)
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
