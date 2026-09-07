//! f9ctl ↔ f9d 的本地版本化 IPC（SPEC §13.6）。
//!
//! - Unix domain socket，权限 0600；
//! - request/response 带 `protocol_version` 与 request id；
//! - 限制帧大小；拒绝未知高版本；
//! - 不通过 IPC 暴露 raw 写；
//! - 支持 health、status、mode.get、mode.set、pause、resume、shutdown。

pub mod socket;

pub use socket::{IpcListener, default_lock_path, default_socket_path};

use serde::{Deserialize, Serialize};
use thiserror::Error;

/// IPC 协议版本（v1 = 1）。拒绝未知高版本。
pub const PROTOCOL_VERSION: u32 = 1;

/// 单帧上限（64 KiB）。
pub const MAX_FRAME_BYTES: usize = 64 * 1024;

/// IPC 方法集。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Method {
    Health,
    Status,
    ModeGet,
    ModeSet,
    Pause,
    Resume,
    Shutdown,
}

/// IPC 请求。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct IpcRequest {
    pub protocol_version: u32,
    /// 请求 ID（响应回显）。
    pub id: u64,
    pub method: Method,
    /// mode.set 的参数。
    #[serde(default)]
    pub gear: Option<String>,
}

/// IPC 响应。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct IpcResponse {
    pub protocol_version: u32,
    pub id: u64,
    pub ok: bool,
    #[serde(default)]
    pub error: Option<String>,
    /// JSON 编码的负载（status/mode.get 时为设备数据）。
    #[serde(default)]
    pub data: Option<serde_json::Value>,
}

#[derive(Debug, Clone, Error)]
pub enum IpcError {
    #[error("frame too large: {got} > {max}")]
    FrameTooLarge { got: usize, max: usize },
    #[error("unsupported protocol version {got} (supported: {supported})")]
    UnsupportedVersion { got: u32, supported: u32 },
    #[error("bad frame: {0}")]
    BadFrame(String),
    #[error("io error: {0}")]
    Io(String),
    #[error("unsupported on this platform")]
    Unsupported,
}

impl From<std::io::Error> for IpcError {
    fn from(e: std::io::Error) -> Self {
        Self::Io(e.to_string())
    }
}

/// 编码一帧：4 字节小端长度 + JSON。
pub fn encode_frame<T: Serialize>(value: &T) -> Result<Vec<u8>, IpcError> {
    let json = serde_json::to_vec(value).map_err(|e| IpcError::BadFrame(e.to_string()))?;
    if json.len() > MAX_FRAME_BYTES {
        return Err(IpcError::FrameTooLarge {
            got: json.len(),
            max: MAX_FRAME_BYTES,
        });
    }
    let mut out = Vec::with_capacity(4 + json.len());
    out.extend_from_slice(&(json.len() as u32).to_le_bytes());
    out.extend_from_slice(&json);
    Ok(out)
}

/// 解码一帧并校验大小与协议版本。
pub fn decode_frame<T: for<'de> Deserialize<'de>>(buf: &[u8]) -> Result<T, IpcError> {
    if buf.len() < 4 {
        return Err(IpcError::BadFrame("short frame header".into()));
    }
    let len = u32::from_le_bytes([buf[0], buf[1], buf[2], buf[3]]) as usize;
    if len > MAX_FRAME_BYTES {
        return Err(IpcError::FrameTooLarge {
            got: len,
            max: MAX_FRAME_BYTES,
        });
    }
    if buf.len() < 4 + len {
        return Err(IpcError::BadFrame("truncated frame".into()));
    }
    serde_json::from_slice(&buf[4..4 + len]).map_err(|e| IpcError::BadFrame(e.to_string()))
}

/// 服务端校验请求版本。
pub fn check_request_version(req: &IpcRequest) -> Result<(), IpcError> {
    if req.protocol_version > PROTOCOL_VERSION {
        return Err(IpcError::UnsupportedVersion {
            got: req.protocol_version,
            supported: PROTOCOL_VERSION,
        });
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_req() -> IpcRequest {
        IpcRequest {
            protocol_version: PROTOCOL_VERSION,
            id: 42,
            method: Method::ModeSet,
            gear: Some("beast".into()),
        }
    }

    #[test]
    fn frame_roundtrip() {
        let enc = encode_frame(&sample_req()).unwrap();
        let dec: IpcRequest = decode_frame(&enc).unwrap();
        assert_eq!(dec, sample_req());
    }

    #[test]
    fn frame_size_limit() {
        let big = IpcRequest {
            protocol_version: 1,
            id: 1,
            method: Method::Health,
            gear: Some("x".repeat(MAX_FRAME_BYTES)),
        };
        assert!(matches!(
            encode_frame(&big),
            Err(IpcError::FrameTooLarge { .. })
        ));
    }

    #[test]
    fn truncated_frame_rejected() {
        let enc = encode_frame(&sample_req()).unwrap();
        let truncated = &enc[..enc.len() - 2];
        assert!(decode_frame::<IpcRequest>(truncated).is_err());
    }

    #[test]
    fn short_header_rejected() {
        assert!(matches!(
            decode_frame::<IpcRequest>(&[1, 2]),
            Err(IpcError::BadFrame(_))
        ));
    }

    #[test]
    fn high_version_rejected() {
        let mut req = sample_req();
        req.protocol_version = PROTOCOL_VERSION + 1;
        assert!(matches!(
            check_request_version(&req),
            Err(IpcError::UnsupportedVersion { .. })
        ));
        req.protocol_version = PROTOCOL_VERSION;
        assert!(check_request_version(&req).is_ok());
    }

    #[test]
    fn response_roundtrip() {
        let resp = IpcResponse {
            protocol_version: 1,
            id: 7,
            ok: true,
            error: None,
            data: Some(serde_json::json!({"rpm": 2012})),
        };
        let enc = encode_frame(&resp).unwrap();
        let dec: IpcResponse = decode_frame(&enc).unwrap();
        assert_eq!(dec, resp);
    }
}
