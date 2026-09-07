//! btleplug（BlueZ）实现：UUID 服务发现、write-with-response、通知订阅。

use std::str::FromStr;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use btleplug::api::{CharPropFlags, Characteristic, Peripheral as _, ScanFilter, WriteType};
use btleplug::platform::Adapter;
use f9_protocol::ids::{BLE_NOTIFY_UUID, BLE_SERVICE_UUID, BLE_WRITE_UUID};
use tokio::sync::{Mutex, mpsc};
use tokio_stream::StreamExt;

use crate::NOTIFY_QUEUE_CAPACITY;

pub(crate) struct LinuxBle {
    pub peripheral: btleplug::platform::Peripheral,
    #[allow(dead_code)] // adapter 留给重连路径。
    pub adapter: Adapter,
    pub write_char: Characteristic,
    pub notify_char: Characteristic,
    /// 通知接收端（有界队列，容量 NOTIFY_QUEUE_CAPACITY）。
    pub notify_rx: Mutex<mpsc::Receiver<Vec<u8>>>,
    /// 单 in-flight 请求许可。
    pub inflight: Arc<Mutex<()>>,
    /// 通知队列溢出计数。
    pub queue_overflow: Arc<AtomicU64>,
}

fn uuid(s: &str) -> uuid::Uuid {
    uuid::Uuid::from_str(s).expect("valid uuid constant")
}

impl LinuxBle {
    /// 连接外设并订阅通知特征。
    pub async fn connect(
        peripheral: btleplug::platform::Peripheral,
        adapter: Adapter,
    ) -> Result<Self, f9_transport::TransportError> {
        peripheral
            .connect()
            .await
            .map_err(|e| f9_transport::TransportError::Internal(format!("ble connect: {e}")))?;
        peripheral
            .discover_services()
            .await
            .map_err(|e| f9_transport::TransportError::Internal(format!("ble discover: {e}")))?;
        let chars = peripheral.characteristics();
        let write_char = chars
            .iter()
            .find(|c| c.uuid == uuid(BLE_WRITE_UUID))
            .ok_or(f9_transport::TransportError::Unsupported)?
            .clone();
        let notify_char = chars
            .iter()
            .find(|c| c.uuid == uuid(BLE_NOTIFY_UUID))
            .ok_or(f9_transport::TransportError::Unsupported)?
            .clone();
        // 写特征必须声明 write 能力；不静默降级为未验证写法。
        if !write_char.properties.contains(CharPropFlags::WRITE) {
            return Err(f9_transport::TransportError::Unsupported);
        }
        peripheral
            .subscribe(&notify_char)
            .await
            .map_err(|e| f9_transport::TransportError::Internal(format!("ble subscribe: {e}")))?;
        let overflow = Arc::new(AtomicU64::new(0));
        let (tx, rx) = mpsc::channel::<Vec<u8>>(NOTIFY_QUEUE_CAPACITY);
        let overflow2 = overflow.clone();
        let mut notes = peripheral.notifications().await.map_err(|e| {
            f9_transport::TransportError::Internal(format!("ble notifications: {e}"))
        })?;
        tokio::spawn(async move {
            while let Some(n) = notes.next().await {
                // 有界队列：满则丢弃并计数（结构化警告由调用方日志承载）。
                if tx.try_send(n.value).is_err() {
                    overflow2.fetch_add(1, Ordering::SeqCst);
                }
            }
        });
        Ok(Self {
            peripheral,
            adapter,
            write_char,
            notify_char,
            notify_rx: Mutex::new(rx),
            inflight: Arc::new(Mutex::new(())),
            queue_overflow: overflow,
        })
    }

    /// write-with-response（不静默降级）。
    pub async fn write_with_response(
        &self,
        buf: &[u8],
    ) -> Result<(), f9_transport::TransportError> {
        self.peripheral
            .write(&self.write_char, buf, WriteType::WithResponse)
            .await
            .map_err(|e| f9_transport::TransportError::Internal(format!("ble write: {e}")))
    }

    pub async fn disconnect(&self) {
        let _ = self.peripheral.unsubscribe(&self.notify_char).await;
        let _ = self.peripheral.disconnect().await;
    }
}

/// 脱敏、会话稳定的设备标识（不得含真实 MAC；地址不持久化）。
pub fn session_device_id(p: &btleplug::platform::Peripheral) -> String {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    format!("{:?}", p.id()).hash(&mut h);
    format!("ble-{:016x}", h.finish())
}

/// 供 discover.rs 使用的服务 UUID 过滤器。
pub fn scan_filter() -> ScanFilter {
    ScanFilter {
        services: vec![uuid(BLE_SERVICE_UUID)],
    }
}

/// 检查外设是否广播目标服务 UUID 或名称（服务 UUID 优先，名称辅助）。
pub async fn matches_target(p: &btleplug::platform::Peripheral) -> bool {
    let Ok(Some(props)) = p.properties().await else {
        return false;
    };
    let service_match = props
        .services
        .iter()
        .any(|s| s.to_string().eq_ignore_ascii_case(BLE_SERVICE_UUID));
    let name_match = props.local_name.as_deref() == Some(f9_protocol::ids::BLE_NAME);
    service_match || name_match
}

/// 供非 Linux 编译单元引用的占位（保持 CharPropFlags 导入一致）。
#[allow(dead_code)]
fn _props_unused() -> CharPropFlags {
    CharPropFlags::default()
}
