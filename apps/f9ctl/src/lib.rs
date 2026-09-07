//! f9ctl 公共实现（供二进制与集成测试使用）。

pub mod commands;
pub mod connect;
pub mod output;

/// 退出码（SPEC §11.4）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExitCode {
    Ok = 0,
    /// 未分类内部错误（尽量避免）。
    Internal = 1,
    /// CLI 用法或配置错误。
    Usage = 2,
    NoDevice = 3,
    Permission = 4,
    Busy = 5,
    Timeout = 6,
    Protocol = 7,
    Verification = 8,
    Unsupported = 9,
    SafetyDenied = 10,
}

impl From<f9_core::DeviceError> for ExitCode {
    fn from(e: f9_core::DeviceError) -> Self {
        use f9_core::DeviceError as E;
        match e {
            E::Timeout => Self::Timeout,
            E::Disconnected => Self::Timeout,
            E::Busy => Self::Busy,
            E::ProtocolViolation(_) => Self::Protocol,
            E::Unsupported => Self::Unsupported,
            E::PermissionDenied => Self::SafetyDenied,
            E::VerificationFailed => Self::Verification,
            E::Uncertain => Self::Verification,
            E::InvalidInput(_) => Self::Usage,
            E::Internal(_) => Self::Internal,
        }
    }
}

impl From<f9_ipc::IpcError> for ExitCode {
    fn from(e: f9_ipc::IpcError) -> Self {
        use f9_ipc::IpcError as E;
        match e {
            E::FrameTooLarge { .. } | E::BadFrame(_) => Self::Protocol,
            E::UnsupportedVersion { .. } => Self::Protocol,
            E::Io(_) => Self::Timeout,
            E::Unsupported => Self::Unsupported,
        }
    }
}

impl ExitCode {
    pub fn as_i32(self) -> i32 {
        self as i32
    }
}

/// 一次性成功运行后的退出码包装。
pub type CmdResult<T> = Result<T, CommandFailure>;

#[derive(Debug)]
pub struct CommandFailure {
    pub code: ExitCode,
    /// stderr 详情（human 模式）。
    pub message: String,
    /// JSON error.code。
    pub error_code: String,
    pub retryable: bool,
}

impl CommandFailure {
    pub fn new(code: ExitCode, error_code: &str, message: impl Into<String>) -> Self {
        Self {
            code,
            error_code: error_code.to_owned(),
            message: message.into(),
            retryable: false,
        }
    }

    pub fn retryable(mut self, r: bool) -> Self {
        self.retryable = r;
        self
    }
}

impl From<f9_transport::TransportError> for CommandFailure {
    fn from(e: f9_transport::TransportError) -> Self {
        Self::from(f9_core::DeviceError::from(e))
    }
}

impl From<f9_ipc::IpcError> for CommandFailure {
    fn from(e: f9_ipc::IpcError) -> Self {
        let code = ExitCode::from(e.clone());
        Self {
            code,
            message: e.to_string(),
            error_code: "ipc".to_owned(),
            retryable: false,
        }
    }
}

impl From<f9_core::DeviceError> for CommandFailure {
    fn from(e: f9_core::DeviceError) -> Self {
        let code = ExitCode::from(e.clone());
        let (error_code, retryable) = (e.code().to_owned(), e.retryable());
        Self {
            code,
            message: e.to_string(),
            error_code,
            retryable,
        }
    }
}

/// 解析 `--timeout` 类时长（如 `2s`、`500ms`、`1m`）。标准库 Duration 解析不支持后缀。
pub fn parse_duration(s: &str) -> Result<std::time::Duration, String> {
    let s = s.trim();
    let (num, unit) = s.split_at(s.find(|c: char| c.is_ascii_alphabetic()).unwrap_or(s.len()));
    let value: u64 = num
        .parse()
        .map_err(|_| format!("invalid duration number: {num:?}"))?;
    let millis = match unit {
        "ms" => value,
        "s" => value * 1000,
        "m" => value * 60_000,
        "h" => value * 3_600_000,
        "" => return Err("duration requires a unit: ms|s|m|h".to_owned()),
        other => return Err(format!("unknown duration unit: {other:?}")),
    };
    Ok(std::time::Duration::from_millis(millis))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn duration_parsing() {
        assert_eq!(
            parse_duration("2s").unwrap(),
            std::time::Duration::from_secs(2)
        );
        assert_eq!(
            parse_duration("500ms").unwrap(),
            std::time::Duration::from_millis(500)
        );
        assert_eq!(
            parse_duration("1m").unwrap(),
            std::time::Duration::from_secs(60)
        );
        assert!(parse_duration("2").is_err());
        assert!(parse_duration("2x").is_err());
    }

    #[test]
    fn exit_code_mapping() {
        assert_eq!(ExitCode::from(f9_core::DeviceError::Busy).as_i32(), 5);
        assert_eq!(ExitCode::from(f9_core::DeviceError::Uncertain).as_i32(), 8);
        assert_eq!(
            ExitCode::from(f9_core::DeviceError::PermissionDenied).as_i32(),
            10
        );
    }
}
