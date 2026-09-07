//! 设备连接逻辑：auto/usb/ble 选择、daemon IPC 优先、直连回退（SPEC §10、§13.6）。

use std::sync::Arc;

use f9_transport::{DeviceCandidate, Transport, TransportError, TransportKind};

use crate::output::OutputMode;

/// 传输选择参数。
#[derive(Debug, Clone, Copy, PartialEq, Eq, clap::ValueEnum)]
pub enum TransportArg {
    Auto,
    Usb,
    Ble,
}

impl TransportArg {
    fn kind(self) -> Option<TransportKind> {
        match self {
            Self::Auto => None,
            Self::Usb => Some(TransportKind::Usb),
            Self::Ble => Some(TransportKind::Ble),
        }
    }
}

/// 活动连接：直连设备句柄或 daemon IPC。
pub enum Connection {
    Direct(LockedTransport),
    /// daemon 接管硬件时，CLI 通过 IPC 交互。
    Daemon,
}

/// 持有直连 transport 及其进程级设备锁。
///
/// 锁必须与整个命令事务同寿命，不能在连接函数返回时提前释放。
pub struct LockedTransport {
    pub transport: Arc<dyn Transport>,
    _lock: f9_core::DeviceLock,
}

impl LockedTransport {
    pub(crate) fn new(transport: Arc<dyn Transport>) -> Result<Self, TransportError> {
        let lock = f9_core::locks::try_lock(transport.identity().kind)
            .map_err(|_| TransportError::Busy)?;
        Ok(Self {
            transport,
            _lock: lock,
        })
    }
}

/// 列出全部候选设备（脱敏）。
pub async fn list_candidates() -> Result<Vec<DeviceCandidate>, TransportError> {
    let mut out = Vec::new();
    out.extend(f9_transport_usb::usb_candidates_public()?);
    #[cfg(target_os = "linux")]
    {
        out.extend(
            f9_transport_ble::discover::ble_candidates_public(Duration::from_secs(2)).await?,
        );
    }
    Ok(out)
}

/// 建立到设备的连接（直连）。auto 策略：USB 优先，其次 BLE（SPEC §10.1）。
pub async fn connect_direct(
    choice: Option<TransportArg>,
    device: Option<&str>,
) -> Result<Arc<dyn Transport>, TransportError> {
    let wanted = choice.and_then(|t| t.kind());
    let candidates = list_candidates().await?;
    let mut usb: Vec<_> = candidates
        .iter()
        .filter(|c| c.transport == TransportKind::Usb)
        .collect();
    let mut ble: Vec<_> = candidates
        .iter()
        .filter(|c| c.transport == TransportKind::Ble)
        .collect();
    // 按 --device 选择器过滤（匹配脱敏 id）。
    if let Some(sel) = device {
        usb.retain(|c| c.device_id.contains(sel));
        ble.retain(|c| c.device_id.contains(sel));
    }
    // 多设备时不自动猜测（SPEC §10.1.3）。
    let mut_count = |v: &[&DeviceCandidate]| v.len();
    match wanted {
        Some(TransportKind::Usb) | None => {
            if mut_count(&usb) > 1 {
                return Err(TransportError::Internal(
                    "multiple devices found; use --device <selector>".into(),
                ));
            }
            if let Some(_c) = usb.first() {
                let mut opened = f9_transport_usb::discover_usb()?;
                if let Some(sel) = device {
                    opened.retain(|t| t.identity().device_id.contains(sel));
                }
                if opened.len() > 1 {
                    return Err(TransportError::Internal(
                        "multiple devices found; use --device <selector>".into(),
                    ));
                }
                if let Some(t) = opened.into_iter().next() {
                    return Ok(Arc::new(t));
                }
            }
            if wanted == Some(TransportKind::Usb) {
                return Err(TransportError::Disconnected);
            }
            // auto：回退 BLE。
        }
        _ => {}
    }
    match wanted {
        Some(TransportKind::Ble) | None => {
            #[cfg(target_os = "linux")]
            {
                if mut_count(&ble) > 1 {
                    return Err(TransportError::Internal(
                        "multiple devices found; use --device <selector>".into(),
                    ));
                }
                if mut_count(&ble) == 1 {
                    return Ok(Arc::new(
                        f9_transport_ble::discover::connect_first(Duration::from_secs(4)).await?,
                    ));
                }
                return Err(TransportError::Disconnected);
            }
            #[cfg(not(target_os = "linux"))]
            {
                let _ = ble;
                Err(TransportError::Unsupported)
            }
        }
        Some(TransportKind::Usb) => Err(TransportError::Disconnected),
    }
}

/// 建立工作连接：
/// 1. 非 `--no-daemon` 时尝试 daemon IPC；daemon 在线即接管硬件；
/// 2. 否则直连（若设备锁被 daemon 持有则返回 Busy，不抢占，SPEC §13.6）。
pub async fn connect(
    choice: Option<TransportArg>,
    device: Option<&str>,
    no_daemon: bool,
    _output: OutputMode,
) -> Result<Connection, TransportError> {
    if !no_daemon {
        let socket = f9_ipc::default_socket_path();
        let health = f9_ipc::IpcRequest {
            protocol_version: f9_ipc::PROTOCOL_VERSION,
            id: 1,
            method: f9_ipc::Method::Health,
            gear: None,
        };
        if f9_ipc::socket::call(&socket, health).await.is_ok() {
            return Ok(Connection::Daemon);
        }
    }
    let transport = connect_direct(choice, device).await?;
    Ok(Connection::Direct(LockedTransport::new(transport)?))
}
