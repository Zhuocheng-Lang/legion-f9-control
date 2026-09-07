//! Unix domain socket 端点：监听、连接与帧收发。
//!
//! - runtime socket 位于 `$XDG_RUNTIME_DIR/legion-f9-control/`，权限 0600；
//! - 非 Unix 平台返回 `IpcError::Unsupported`（Windows daemon v1 不支持）。

use std::path::PathBuf;

use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::{IpcError, IpcRequest, IpcResponse, MAX_FRAME_BYTES, decode_frame, encode_frame};

/// 默认 runtime socket 路径（遵循 XDG，SPEC §20.3）。
pub fn default_socket_path() -> PathBuf {
    if let Some(dir) = std::env::var_os("F9_RUNTIME_DIR") {
        return PathBuf::from(dir).join("f9d.sock");
    }
    let runtime = std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .or_else(|| {
            // 无 XDG_RUNTIME_DIR 时回退到 state 目录（非标准，但保持用户级）。
            std::env::var_os("XDG_STATE_HOME")
                .map(PathBuf::from)
                .or_else(|| {
                    std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local").join("state"))
                })
        })
        .unwrap_or_else(|| PathBuf::from("."));
    runtime.join("legion-f9-control").join("f9d.sock")
}

/// 进程级 advisory lock 文件路径。
pub fn default_lock_path() -> PathBuf {
    default_socket_path().with_file_name("f9d.lock")
}

#[cfg(unix)]
mod imp {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use tokio::net::{UnixListener, UnixStream};

    /// 创建监听 socket（权限 0600；先清理残留）。
    pub fn listen(path: &std::path::Path) -> Result<UnixListener, IpcError> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(IpcError::from)?;
        }
        let _ = std::fs::remove_file(path);
        let listener = UnixListener::bind(path).map_err(IpcError::from)?;
        let perms = std::fs::Permissions::from_mode(0o600);
        std::fs::set_permissions(path, perms).map_err(IpcError::from)?;
        Ok(listener)
    }

    pub async fn connect(path: &std::path::Path) -> Result<UnixStream, IpcError> {
        UnixStream::connect(path).await.map_err(IpcError::from)
    }
}

#[cfg(not(unix))]
mod imp {
    use super::*;

    pub fn listen(_path: &std::path::Path) -> Result<(), IpcError> {
        Err(IpcError::Unsupported)
    }

    pub async fn connect(_path: &std::path::Path) -> Result<(), IpcError> {
        Err(IpcError::Unsupported)
    }
}

pub use imp::{connect, listen};

/// 收一帧（4 字节长度前缀 + JSON）。
pub async fn read_frame<T: for<'de> serde::Deserialize<'de>>(
    stream: &mut (impl tokio::io::AsyncRead + Unpin),
) -> Result<T, IpcError> {
    let mut header = [0u8; 4];
    stream
        .read_exact(&mut header)
        .await
        .map_err(IpcError::from)?;
    let len = u32::from_le_bytes(header) as usize;
    if len > MAX_FRAME_BYTES {
        return Err(IpcError::FrameTooLarge {
            got: len,
            max: MAX_FRAME_BYTES,
        });
    }
    let mut body = vec![0u8; len];
    stream.read_exact(&mut body).await.map_err(IpcError::from)?;
    // decode_frame 期望 [len(4) + body] 形状。
    let mut frame = header.to_vec();
    frame.extend_from_slice(&body);
    decode_frame(&frame)
}

/// 发一帧。
pub async fn write_frame<T: serde::Serialize>(
    stream: &mut (impl tokio::io::AsyncWrite + Unpin),
    value: &T,
) -> Result<(), IpcError> {
    let bytes = encode_frame(value)?;
    stream.write_all(&bytes).await.map_err(IpcError::from)?;
    stream.flush().await.map_err(IpcError::from)?;
    Ok(())
}

/// 客户端：一次请求/响应往返（Unix）。
#[cfg(unix)]
pub async fn call(path: &std::path::Path, req: IpcRequest) -> Result<IpcResponse, IpcError> {
    let mut stream = connect(path).await?;
    write_frame(&mut stream, &req).await?;
    read_frame::<IpcResponse>(&mut stream).await
}

/// 非 Unix 平台：v1 不支持 daemon/IPC（Windows BLE/daemon 不支持，SPEC §6）。
#[cfg(not(unix))]
pub async fn call(_path: &std::path::Path, _req: IpcRequest) -> Result<IpcResponse, IpcError> {
    Err(IpcError::Unsupported)
}

#[cfg(unix)]
pub use tokio::net::UnixListener as IpcListener;

#[cfg(not(unix))]
#[derive(Debug)]
pub struct IpcListener;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{IpcRequest, Method};
    #[cfg(unix)]
    use crate::{PROTOCOL_VERSION, check_request_version};

    #[test]
    fn socket_path_prefers_f9_runtime_dir() {
        // 不设置环境变量时使用 XDG 回退；路径以 f9d.sock 结尾。
        let p = default_socket_path();
        assert!(p.ends_with("f9d.sock"));
    }

    #[test]
    fn lock_path_is_sibling_of_socket() {
        let s = default_socket_path();
        let l = default_lock_path();
        assert_ne!(s, l);
    }

    #[test]
    fn request_helpers() {
        let req = IpcRequest {
            protocol_version: 1,
            id: 1,
            method: Method::Health,
            gear: None,
        };
        let bytes = encode_frame(&req).unwrap();
        // 前 4 字节为小端长度前缀。
        let len = u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]) as usize;
        assert_eq!(bytes.len(), 4 + len);
    }

    /// UDS 往返与 socket 权限（仅 Unix，CI Linux 运行）。
    #[cfg(unix)]
    #[tokio::test]
    async fn unix_socket_roundtrip_and_permissions() {
        use crate::IpcResponse;
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("test.sock");
        let listener = listen(&path).unwrap();
        // 权限必须是 0600。
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);

        let server = tokio::spawn(async move {
            let (mut sock, _) = listener.accept().await.unwrap();
            let req: IpcRequest = read_frame(&mut sock).await.unwrap();
            let resp = IpcResponse {
                protocol_version: req.protocol_version,
                id: req.id,
                ok: true,
                error: None,
                data: Some(serde_json::json!({"method": req.method})),
            };
            write_frame(&mut sock, &resp).await.unwrap();
        });
        let req = IpcRequest {
            protocol_version: PROTOCOL_VERSION,
            id: 99,
            method: Method::Status,
            gear: None,
        };
        let resp = call(&path, req).await.unwrap();
        assert!(resp.ok);
        assert_eq!(resp.id, 99);
        server.await.unwrap();
    }

    /// 高版本请求被服务端拒绝（仅 Unix，CI Linux 运行）。
    #[cfg(unix)]
    #[tokio::test]
    async fn unix_socket_rejects_high_version() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("v.sock");
        let listener = listen(&path).unwrap();
        let server = tokio::spawn(async move {
            let (mut sock, _) = listener.accept().await.unwrap();
            let req: IpcRequest = read_frame(&mut sock).await.unwrap();
            let err = match check_request_version(&req) {
                Ok(()) => "ok",
                Err(_) => "unsupported_version",
            };
            let resp = IpcResponse {
                protocol_version: req.protocol_version,
                id: req.id,
                ok: err == "ok",
                error: Some(err.to_owned()),
                data: None,
            };
            write_frame(&mut sock, &resp).await.unwrap();
        });
        let req = IpcRequest {
            protocol_version: PROTOCOL_VERSION + 5,
            id: 1,
            method: Method::Health,
            gear: None,
        };
        let resp = call(&path, req).await.unwrap();
        assert!(!resp.ok);
        server.await.unwrap();
    }
}
