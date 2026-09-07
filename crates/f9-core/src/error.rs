//! 设备层错误：区分 Timeout、Disconnected、ProtocolViolation、Unsupported、
//! PermissionDenied、Busy、VerificationFailed 与“结果不确定”（SPEC §9）。

use f9_protocol::ProtocolError;
use thiserror::Error;

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum DeviceError {
    #[error("operation timed out")]
    Timeout,
    #[error("device disconnected")]
    Disconnected,
    #[error("device or transport busy")]
    Busy,
    #[error("protocol violation: {0}")]
    ProtocolViolation(#[from] ProtocolError),
    #[error("not supported on this platform or transport")]
    Unsupported,
    #[error("permission denied")]
    PermissionDenied,
    #[error("verification failed")]
    VerificationFailed,
    /// 写超时且无法通过读回确认结果（SPEC §7.6：结果不确定）。
    #[error("outcome uncertain; write result could not be verified")]
    Uncertain,
    #[error("invalid input: {0}")]
    InvalidInput(String),
    #[error("internal error: {0}")]
    Internal(String),
}

impl From<crate::raw::RawViolation> for DeviceError {
    fn from(_v: crate::raw::RawViolation) -> Self {
        Self::PermissionDenied
    }
}

impl From<f9_transport::TransportError> for DeviceError {
    fn from(e: f9_transport::TransportError) -> Self {
        use f9_transport::TransportError as T;
        match e {
            T::Timeout => Self::Timeout,
            T::Disconnected => Self::Disconnected,
            T::Busy => Self::Busy,
            T::Unsupported => Self::Unsupported,
            T::PermissionDenied => Self::PermissionDenied,
            T::Protocol(p) => Self::ProtocolViolation(p),
            T::DeviceError => Self::ProtocolViolation(ProtocolError::DeviceError),
            T::Internal(m) => Self::Internal(m),
        }
    }
}

impl DeviceError {
    /// 稳定错误码（JSON envelope 与退出码映射，SPEC §11.3/§11.4）。
    pub fn code(&self) -> &'static str {
        match self {
            Self::Timeout => "timeout",
            Self::Disconnected => "disconnected",
            Self::Busy => "busy",
            Self::ProtocolViolation(_) => "protocol_violation",
            Self::Unsupported => "unsupported",
            Self::PermissionDenied => "permission_denied",
            Self::VerificationFailed => "verification_failed",
            Self::Uncertain => "uncertain",
            Self::InvalidInput(_) => "invalid_input",
            Self::Internal(_) => "internal",
        }
    }

    /// 是否值得重试（读操作）。
    pub fn retryable(&self) -> bool {
        matches!(self, Self::Timeout | Self::Disconnected | Self::Busy)
    }
}
