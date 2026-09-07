//! 传输层错误。与设备协议错误区分开。

use f9_protocol::ProtocolError;
use thiserror::Error;

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum TransportError {
    #[error("operation timed out")]
    Timeout,
    #[error("device disconnected")]
    Disconnected,
    #[error("device or transport busy")]
    Busy,
    #[error("unsupported on this platform or transport")]
    Unsupported,
    #[error("permission denied")]
    PermissionDenied,
    #[error("protocol violation: {0}")]
    Protocol(#[from] ProtocolError),
    #[error("device error")]
    DeviceError,
    #[error("internal transport error: {0}")]
    Internal(String),
}
