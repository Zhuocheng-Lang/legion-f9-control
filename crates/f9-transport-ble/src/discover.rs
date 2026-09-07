//! BLE 服务 UUID 发现（Linux）。
//!
//! 发现优先使用服务 UUID，其次名称；不持久化真实地址；明确连接/扫描超时。

use std::time::Duration;

use btleplug::api::{Central, Manager};
use btleplug::platform::{Adapter, Manager as PlatformManager};
use f9_protocol::ids::BLE_SERVICE_UUID;
use f9_transport::{Capability, DeviceCandidate, TransportError, TransportKind};

use crate::transport::linux_impl;

/// 扫描并返回匹配目标的候选（脱敏）。
pub async fn ble_candidates_public(
    timeout: Duration,
) -> Result<Vec<DeviceCandidate>, TransportError> {
    let (periphs, _adapter) = scan_peripherals(timeout).await?;
    Ok(periphs
        .into_iter()
        .map(|p| DeviceCandidate {
            transport: TransportKind::Ble,
            device_id: linux_impl::session_device_id(&p),
            capability: crate::platform_capability(),
            summary: format!("BLE service {BLE_SERVICE_UUID}"),
        })
        .collect())
}

/// 连接第一个匹配目标的外设并返回 transport。
pub async fn connect_first(timeout: Duration) -> Result<crate::BleTransport, TransportError> {
    let (periphs, adapter) = scan_peripherals(timeout).await?;
    let Some(p) = periphs.into_iter().next() else {
        return Err(TransportError::Disconnected);
    };
    let linux = linux_impl::LinuxBle::connect(p, adapter).await?;
    Ok(crate::BleTransport::from_linux(linux))
}

async fn central_adapter(manager: &btleplug::platform::Manager) -> Result<Adapter, TransportError> {
    let adapters = manager
        .adapters()
        .await
        .map_err(|e| TransportError::Internal(format!("ble adapters: {e}")))?;
    adapters
        .into_iter()
        .next()
        .ok_or(TransportError::Unsupported)
}

async fn scan_peripherals(
    timeout: Duration,
) -> Result<(Vec<btleplug::platform::Peripheral>, Adapter), TransportError> {
    let manager = PlatformManager::new()
        .await
        .map_err(|e| TransportError::Internal(format!("ble manager: {e}")))?;
    let adapter = central_adapter(&manager).await?;
    adapter
        .start_scan(linux_impl::scan_filter())
        .await
        .map_err(|e| TransportError::Internal(format!("ble scan: {e}")))?;
    tokio::time::sleep(timeout.min(Duration::from_secs(10))).await;
    let mut out = Vec::new();
    for p in adapter
        .peripherals()
        .await
        .map_err(|e| TransportError::Internal(format!("ble peripherals: {e}")))?
    {
        if linux_impl::matches_target(&p).await {
            out.push(p);
        }
    }
    adapter
        .stop_scan()
        .await
        .map_err(|e| TransportError::Internal(format!("ble stop scan: {e}")))?;
    Ok((out, adapter))
}

/// 平台能力（测试用）。
pub fn capability() -> Capability {
    crate::platform_capability()
}

/// 从已发现外设构造 transport（保留给 daemon 重连路径）。
pub async fn connect_peripheral(
    p: btleplug::platform::Peripheral,
    adapter: Adapter,
) -> Result<crate::BleTransport, TransportError> {
    let linux = linux_impl::LinuxBle::connect(p, adapter).await?;
    Ok(crate::BleTransport::from_linux(linux))
}
