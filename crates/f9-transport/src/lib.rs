//! Transport trait、发现模型与共享交换策略（SPEC §8.2、§9、§10）。
//!
//! 依赖方向：`f9-protocol ← f9-transport ← USB/BLE adapters`。
//! 本 crate 不包含 daemon 策略，也不拼协议帧。

pub mod backoff;
pub mod discovery;
pub mod error;
pub mod policy;

pub use backoff::Backoff;
pub use discovery::{DeviceCandidate, TransportKind};
pub use error::TransportError;
pub use policy::ExchangePolicy;

use async_trait::async_trait;
use f9_protocol::{Request, Response};

/// `Arc<T>` 透传实现：允许 `Device<Arc<dyn Transport>>` 等共享句柄。
#[async_trait]
impl<T: Transport + ?Sized> Transport for std::sync::Arc<T> {
    async fn exchange(
        &self,
        request: Request,
        policy: ExchangePolicy,
    ) -> Result<Response, TransportError> {
        (**self).exchange(request, policy).await
    }

    async fn close(&self) -> Result<(), TransportError> {
        (**self).close().await
    }

    fn identity(&self) -> &TransportIdentity {
        (**self).identity()
    }
}

/// Transport 身份：用于日志与 JSON 输出。
///
/// `device_id` 必须是**脱敏的稳定会话标识**，不得包含 BLE 地址或 USB 序列号。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TransportIdentity {
    pub kind: TransportKind,
    pub device_id: String,
    /// 平台能力标注（Windows USB 为 `experimental`）。
    pub capability: Capability,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Capability {
    Stable,
    Experimental,
}

impl Capability {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Stable => "stable",
            Self::Experimental => "experimental",
        }
    }
}

/// 单设备单请求的传输接口（SPEC §9）。
///
/// 实现必须：
/// - 在 `exchange` 内部应用 `policy.timeout`；
/// - 同一时刻最多一个未完成命令（由实现内部互斥保证）；
/// - 解码时拒绝错 transport / 错命令 / 短帧。
#[async_trait]
pub trait Transport: Send + Sync {
    async fn exchange(
        &self,
        request: Request,
        policy: ExchangePolicy,
    ) -> Result<Response, TransportError>;
    async fn close(&self) -> Result<(), TransportError>;
    fn identity(&self) -> &TransportIdentity;
}
