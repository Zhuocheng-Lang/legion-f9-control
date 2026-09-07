//! BLE transport 实现。
//!
//! Linux：btleplug 后端。非 Linux 平台为 Unsupported 占位（保持 API 形状）。

use std::sync::atomic::{AtomicU64, Ordering};

use async_trait::async_trait;
use f9_protocol::{Request, Response};
use f9_transport::{ExchangePolicy, Transport, TransportError, TransportIdentity};

#[cfg(target_os = "linux")]
pub(crate) mod linux_impl;

/// 通知队列容量常量的纯逻辑测试可在任何平台运行。
pub struct QueueStats {
    /// 陈旧/无主通知丢弃计数（按 command/offset 关联失败）。
    pub stale_dropped: u64,
}

/// BLE transport 公共句柄。
///
/// Linux 上持有 btleplug 外设连接与通知订阅；其他平台 exchange 恒返回
/// `Unsupported`（SPEC：Windows BLE v1 不支持）。
pub struct BleTransport {
    identity: TransportIdentity,
    /// 陈旧通知丢弃计数（所有平台共享语义）。
    stale_dropped: AtomicU64,
    #[cfg(target_os = "linux")]
    inner: Option<linux_impl::LinuxBle>,
}

impl BleTransport {
    /// 从已连接的 Linux 内部实现构造。
    #[cfg(target_os = "linux")]
    pub fn from_linux(inner: linux_impl::LinuxBle) -> Self {
        use f9_transport::Capability;
        Self {
            identity: TransportIdentity {
                kind: f9_transport::TransportKind::Ble,
                device_id: linux_impl::session_device_id(&inner.peripheral),
                capability: Capability::Stable,
            },
            stale_dropped: AtomicU64::new(0),
            inner: Some(inner),
        }
    }

    /// 非 Linux 平台的占位构造。
    #[cfg(not(target_os = "linux"))]
    pub fn unsupported() -> Self {
        Self {
            identity: TransportIdentity {
                kind: f9_transport::TransportKind::Ble,
                device_id: "ble-unavailable".to_owned(),
                capability: f9_transport::Capability::Experimental,
            },
            stale_dropped: AtomicU64::new(0),
        }
    }

    pub fn stale_dropped(&self) -> u64 {
        self.stale_dropped.load(Ordering::SeqCst)
    }

    #[cfg(target_os = "linux")]
    fn note_stale(&self) {
        self.stale_dropped.fetch_add(1, Ordering::SeqCst);
    }
}

#[async_trait]
impl Transport for BleTransport {
    async fn exchange(
        &self,
        request: Request,
        policy: ExchangePolicy,
    ) -> Result<Response, TransportError> {
        if !crate::SUPPORTED_PLATFORM {
            return Err(TransportError::Unsupported);
        }
        #[cfg(target_os = "linux")]
        {
            let Some(inner) = self.inner.as_ref() else {
                return Err(TransportError::Disconnected);
            };
            let buf = f9_protocol::ble::encode(&request)?;
            // 会话命令 fire-and-forget：写即返回，不等待通知（confirmed）。
            if request.command.is_session_command() {
                inner.write_with_response(&buf).await?;
                return Ok(Response {
                    command: request.command,
                    offset: request.offset,
                    data: request.payload.clone(),
                });
            }
            // 只允许一个 in-flight 请求。
            let _permit = inner.inflight.lock().await;
            inner.write_with_response(&buf).await?;
            // 等待匹配的通知；陈旧通知丢弃并计数。
            let deadline = tokio::time::Instant::now() + policy.timeout;
            loop {
                let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
                if remaining.is_zero() {
                    return Err(TransportError::Timeout);
                }
                match tokio::time::timeout(remaining, inner.notify_rx.lock().await.recv()).await {
                    Ok(Some(n)) => {
                        match f9_protocol::ble::decode(&request, &n) {
                            Ok(resp) => return Ok(resp),
                            Err(f9_protocol::ProtocolError::CommandMismatch { .. })
                            | Err(f9_protocol::ProtocolError::OffsetMismatch { .. }) => {
                                // 陈旧或无主通知：丢弃并计数。
                                self.note_stale();
                                tracing::debug!(transport = "ble", "stale notification dropped");
                                continue;
                            }
                            Err(e) => return Err(TransportError::Protocol(e)),
                        }
                    }
                    Ok(None) => return Err(TransportError::Disconnected),
                    Err(_elapsed) => return Err(TransportError::Timeout),
                }
            }
        }
        #[cfg(not(target_os = "linux"))]
        {
            let _ = (request, policy);
            Err(TransportError::Unsupported)
        }
    }

    async fn close(&self) -> Result<(), TransportError> {
        #[cfg(target_os = "linux")]
        {
            if let Some(inner) = self.inner.as_ref() {
                inner.disconnect().await;
            }
        }
        Ok(())
    }

    fn identity(&self) -> &TransportIdentity {
        &self.identity
    }
}

/// 通知通道容量检查（纯逻辑，所有平台可测）。
#[cfg(test)]
mod tests {
    use super::*;
    use crate::NOTIFY_QUEUE_CAPACITY;
    use f9_protocol::Command;
    use std::time::Duration;

    #[test]
    fn queue_capacity_is_bounded() {
        // 编译期断言（避免 clippy::assertions_on_constants）。
        const _: () = assert!(NOTIFY_QUEUE_CAPACITY > 0 && NOTIFY_QUEUE_CAPACITY <= 256);
        let cap: usize = NOTIFY_QUEUE_CAPACITY;
        assert!(cap > 0);
    }
    #[tokio::test]
    async fn unsupported_platform_returns_unsupported() {
        if crate::SUPPORTED_PLATFORM {
            return; // Linux 上没有占位实例可测，跳过。
        }
        let t = BleTransport::unsupported();
        let req = Request::read(Command::LiveStatus, 0, 3).unwrap();
        let err = t
            .exchange(req, ExchangePolicy::with_timeout(Duration::from_millis(50)))
            .await
            .unwrap_err();
        assert_eq!(err, TransportError::Unsupported);
    }
}
