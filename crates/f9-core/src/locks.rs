//! 进程级 advisory 设备锁（SPEC §14）。
//!
//! 每个物理设备一把锁；daemon 持锁时，CLI 直连返回 Busy（不抢占）。
//! Unix 使用 flock；Windows 使用独占打开（share_mode 0）。无 unsafe。

use std::path::PathBuf;

/// 设备锁文件路径：runtime 目录下按 transport 命名。
pub fn device_lock_path(kind: f9_transport::TransportKind) -> PathBuf {
    crate::runtime_dir().join(format!("device-{}.lock", kind.as_str()))
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum LockError {
    #[error("device is locked by another process")]
    Busy,
    #[error("io error acquiring device lock: {0}")]
    Io(String),
}

/// 持有的设备锁；Drop 时释放。
pub struct DeviceLock {
    // Windows 上独占打开即持有锁；字段仅用于句柄生命周期。
    #[allow(dead_code)]
    file: std::fs::File,
    path: PathBuf,
}

impl Drop for DeviceLock {
    fn drop(&mut self) {
        #[cfg(unix)]
        {
            use std::os::unix::io::AsRawFd;
            let _ = libc::flock(self.file.as_raw_fd(), libc::LOCK_UN);
        }
        // Windows：关闭文件句柄即释放锁。锁文件保留（0 字节）以便下次独占打开。
        let _ = &self.path;
    }
}

#[cfg(unix)]
fn acquire(file: &std::fs::File) -> Result<(), LockError> {
    use std::os::unix::io::AsRawFd;
    let rc = libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB);
    if rc != 0 {
        return Err(LockError::Busy);
    }
    Ok(())
}

#[cfg(windows)]
fn acquire(file: &std::fs::File) -> Result<(), LockError> {
    // share_mode(0) 独占打开已在创建时阻止第二个进程；此处无需额外动作。
    let _ = file;
    Ok(())
}

/// 尝试获取设备锁；被其他进程持有时返回 Busy。
pub fn try_lock(kind: f9_transport::TransportKind) -> Result<DeviceLock, LockError> {
    let path = device_lock_path(kind);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| LockError::Io(e.to_string()))?;
    }
    #[cfg(windows)]
    let file = {
        use std::os::windows::fs::OpenOptionsExt;
        std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .share_mode(0)
            .open(&path)
            .map_err(|_| LockError::Busy)?
    };
    #[cfg(unix)]
    let file = {
        use std::os::unix::fs::OpenOptionsExt;
        std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .mode(0o600)
            .open(&path)
            .map_err(|e| LockError::Io(e.to_string()))?
    };
    acquire(&file)?;
    Ok(DeviceLock { file, path })
}

#[cfg(test)]
mod tests {
    use super::*;
    use f9_transport::TransportKind;

    #[test]
    fn lock_and_release() {
        let l1 = try_lock(TransportKind::Usb).unwrap();
        drop(l1);
        let l2 = try_lock(TransportKind::Usb).unwrap();
        drop(l2);
    }

    #[cfg(windows)]
    #[test]
    fn second_lock_is_busy_on_windows() {
        let l1 = try_lock(TransportKind::Ble).unwrap();
        let r = try_lock(TransportKind::Ble);
        assert!(
            matches!(r, Err(LockError::Busy)),
            "share_mode(0) must block second open"
        );
        drop(l1);
        let l2 = try_lock(TransportKind::Ble);
        assert!(l2.is_ok());
    }

    #[cfg(unix)]
    #[test]
    fn second_lock_is_busy_on_unix() {
        let l1 = try_lock(TransportKind::Ble).unwrap();
        let r = try_lock(TransportKind::Ble);
        assert!(matches!(r, Err(LockError::Busy)));
        drop(l1);
        assert!(try_lock(TransportKind::Ble).is_ok());
    }
}
