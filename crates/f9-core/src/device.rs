//! Device API：单命令互斥、read-modify-write 挡位事务、状态/信息读取与 raw 门（SPEC §7.6、§9）。

use std::sync::Arc;

use f9_protocol::{Command, Gear, ProtocolError, Request, Response, SettingsBlock};
use f9_transport::{ExchangePolicy, Transport};
use tokio::sync::Mutex;

use crate::error::DeviceError;
use crate::policy::{default_read, default_write};
use crate::raw::{RawViolation, raw_read_allowed, raw_write_in_bounds};
use crate::{block_differs_only_in_gear, read_settings_request};

/// 挡位设置结果：区分“未执行”“已确认成功”“结果不确定”（SPEC §9）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SetGearOutcome {
    /// 设备挡位已等于目标，未产生任何 Flash 写。
    Unchanged,
    /// 写入并读回验证成功。
    Applied,
    /// 写超时且读回无法确认（结果不确定）。
    Uncertain,
}

/// 设备句柄。同一时刻最多一个未完成命令（内部互斥）。
pub struct Device<T: Transport> {
    transport: Arc<T>,
    /// 串行化所有交换（单命令锁）。
    lock: Mutex<()>,
}

impl<T: Transport> Device<T> {
    pub fn new(transport: Arc<T>) -> Self {
        Self {
            transport,
            lock: Mutex::new(()),
        }
    }

    pub fn transport(&self) -> &Arc<T> {
        &self.transport
    }
}

impl<T: Transport> Device<T> {
    pub async fn exchange(
        &self,
        req: Request,
        policy: ExchangePolicy,
    ) -> Result<Response, DeviceError> {
        let _g = self.lock.lock().await;
        self.exchange_locked(req, policy).await
    }

    async fn exchange_locked(
        &self,
        req: Request,
        policy: ExchangePolicy,
    ) -> Result<Response, DeviceError> {
        let resp = self.transport.exchange(req.clone(), policy).await?;
        // 回显与 offset 必须匹配；陈旧/错配响应一律拒绝。
        if resp.command != req.command {
            return Err(DeviceError::ProtocolViolation(
                ProtocolError::CommandMismatch {
                    expected: req.command.as_u8(),
                    got: resp.command.as_u8(),
                },
            ));
        }
        if resp.offset != req.offset {
            return Err(DeviceError::ProtocolViolation(
                ProtocolError::OffsetMismatch {
                    expected: req.offset,
                    got: resp.offset,
                },
            ));
        }
        Ok(resp)
    }

    /// 读取实时状态（0x1a）。
    pub async fn status(&self) -> Result<f9_protocol::DeviceStatus, DeviceError> {
        let req = Request::read(Command::LiveStatus, 0, 3).map_err(DeviceError::from)?;
        let resp = self.exchange(req, default_read()).await?;
        Ok(f9_protocol::decode_status(&resp.data)?)
    }

    /// 读取信息页（0x03）。
    pub async fn info(&self) -> Result<Vec<u8>, DeviceError> {
        let req = Request::read(Command::InfoPage, 0, 16).map_err(DeviceError::from)?;
        let resp = self.exchange(req, default_read()).await?;
        Ok(resp.data)
    }

    /// 读取设备信息（0x1d，仅 USB 正常使用）。
    pub async fn device_info(&self) -> Result<Vec<u8>, DeviceError> {
        if self.transport.identity().kind != f9_transport::TransportKind::Usb {
            return Err(DeviceError::Unsupported);
        }
        let req = Request::read(Command::DeviceInfo, 0, 24).map_err(DeviceError::from)?;
        let resp = self.exchange(req, default_read()).await?;
        Ok(resp.data)
    }

    /// 读取 15 字节设置块。
    pub async fn read_settings(&self) -> Result<SettingsBlock, DeviceError> {
        let resp = self
            .exchange(read_settings_request()?, default_read())
            .await?;
        SettingsBlock::from_bytes(&resp.data).map_err(|_| {
            DeviceError::ProtocolViolation(ProtocolError::ShortData {
                declared: 15,
                got: resp.data.len(),
            })
        })
    }

    /// 读取当前挡位。
    pub async fn gear(&self) -> Result<Gear, DeviceError> {
        let block = self.read_settings().await?;
        block.gear().map_err(DeviceError::ProtocolViolation)
    }

    /// 设置挡位：read-modify-write、会话化写入、写后读回（SPEC §7.6 强制算法）。
    pub async fn set_gear(&self, gear: Gear) -> Result<SetGearOutcome, DeviceError> {
        // 1. 读取完整 15 字节。
        let current = self.read_settings().await?;
        // 2. 已等于目标：成功返回且绝不写 Flash。
        if current.gear().map_err(DeviceError::ProtocolViolation)? == gear {
            return Ok(SetGearOutcome::Unchanged);
        }
        // 3. 克隆原块，只修改 byte[13]。
        let next = current.with_gear(gear);
        debug_assert!(block_differs_only_in_gear(&current, &next));

        // 4. 打开配置会话。
        self.session_open().await?;
        // 5. 写入完整 15 字节（无论成败，随后 best-effort 关闭会话）。
        let write_result = self.write_settings(&next).await;
        // 6. best-effort 关闭会话。
        let _ = self.session_close().await;

        // 写超时属于“结果不确定”：先读回再决定是否成功，禁止盲目重写。
        match write_result {
            Ok(()) => {}
            Err(DeviceError::Timeout) | Err(DeviceError::Busy) => {
                // 读回决定结果。
                match self.read_settings().await {
                    Ok(rb) if rb.gear().map_err(DeviceError::ProtocolViolation)? == gear => {
                        return Ok(SetGearOutcome::Applied);
                    }
                    Ok(_) => {
                        // 未生效：结果不确定（不确定是否需要重试由调用方决定）。
                        return Err(DeviceError::Uncertain);
                    }
                    Err(_) => return Err(DeviceError::Uncertain),
                }
            }
            Err(e) => return Err(e),
        }

        // 7. 再次读取 15 字节。
        let readback = self.read_settings().await?;
        // 8. 仅当读回挡位一致时报告成功。
        if readback.gear().map_err(DeviceError::ProtocolViolation)? == gear {
            Ok(SetGearOutcome::Applied)
        } else {
            Err(DeviceError::VerificationFailed)
        }
    }

    async fn session_open(&self) -> Result<(), DeviceError> {
        let req = Request::write(Command::SessionOpen, 0, vec![0x01]).map_err(DeviceError::from)?;
        self.exchange_locked(req, default_write()).await.map(|_| ())
    }

    async fn session_close(&self) -> Result<(), DeviceError> {
        let req =
            Request::write(Command::SessionClose, 0, vec![0x02]).map_err(DeviceError::from)?;
        self.exchange_locked(req, default_write()).await.map(|_| ())
    }

    async fn write_settings(&self, block: &SettingsBlock) -> Result<(), DeviceError> {
        let req = Request::write(Command::SettingsWrite, 0, block.as_bytes().to_vec())
            .map_err(DeviceError::from)?;
        self.exchange_locked(req, default_write()).await.map(|_| ())
    }

    /// 受安全策略约束的 raw 交换（SPEC §12）。
    ///
    /// `write_unlocked` 必须由 CLI 在完成确认词/ACK 校验后传入。
    pub async fn raw_exchange(
        &self,
        req: Request,
        policy: ExchangePolicy,
        write_unlocked: bool,
    ) -> Result<Response, DeviceError> {
        if req.is_write() {
            if !raw_write_in_bounds(&req) {
                return Err(DeviceError::PermissionDenied);
            }
            if !write_unlocked {
                return Err(DeviceError::from(RawViolation::WriteLocked));
            }
        } else if !raw_read_allowed(req.command, self.transport.identity().kind) {
            return Err(DeviceError::PermissionDenied);
        }
        self.exchange(req, policy).await
    }

    pub fn identity(&self) -> &f9_transport::TransportIdentity {
        self.transport.identity()
    }

    /// 关闭底层 transport。
    pub async fn close(&self) -> Result<(), DeviceError> {
        self.transport.close().await.map_err(DeviceError::from)
    }
}

impl<T: Transport + ?Sized> Device<Arc<T>> {
    /// 共享句柄构造：`Device<Arc<dyn Transport>>` 等。
    pub fn new_shared(transport: Arc<T>) -> Self {
        Self {
            transport: Arc::new(transport),
            lock: Mutex::new(()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::SetGearOutcome as O;
    use f9_protocol::Gear;
    use f9_sim::{Faults, SimSpec, SimTransport};
    use f9_transport::TransportKind;
    use std::sync::Arc;

    fn sim_device(faults: Faults) -> (Device<SimTransport>, Arc<SimTransport>) {
        let sim = Arc::new(SimTransport::new(SimSpec::default(), faults));
        (Device::new(sim.clone()), sim)
    }

    #[tokio::test]
    async fn status_reads_rpm() {
        let (dev, _sim) = sim_device(Faults::default());
        let st = dev.status().await.unwrap();
        assert_eq!(st.rpm, 2012);
    }

    #[tokio::test]
    async fn same_gear_produces_zero_writes() {
        let (dev, sim) = sim_device(Faults::default());
        let g = dev.gear().await.unwrap();
        let out = dev.set_gear(g).await.unwrap();
        assert_eq!(out, O::Unchanged);
        assert_eq!(sim.flash_write_count(), 0);
    }

    #[tokio::test]
    async fn set_gear_applies_and_verifies() {
        let (dev, sim) = sim_device(Faults::default());
        let out = dev.set_gear(Gear::Beast).await.unwrap();
        assert_eq!(out, O::Applied);
        assert_eq!(sim.flash_write_count(), 1);
        assert_eq!(dev.gear().await.unwrap(), Gear::Beast);
        // 未知 14 字节逐字节不变。
        let block = sim.settings_snapshot();
        assert_eq!(block.0[14], 14);
        assert_eq!(&block.0[..13], &(0u8..13).collect::<Vec<u8>>()[..]);
        // 会话已全部关闭。
        assert_eq!(sim.sessions_open(), 0);
    }

    #[tokio::test]
    async fn write_timeout_then_readback_matches_no_duplicate_write() {
        let (dev, sim) = sim_device(Faults {
            drop_write_reply_next: 1,
            ..Faults::default()
        });
        let out = dev.set_gear(Gear::Turbo).await.unwrap();
        // 写超时但读回确认已生效：成功且不重复写。
        assert_eq!(out, O::Applied);
        assert_eq!(sim.flash_write_count(), 1);
    }

    #[tokio::test]
    async fn write_timeout_and_unreadable_is_uncertain() {
        // 写超时（写已生效且回复丢失）后，读回也超时：结果不确定。
        // timeout_next=4：依次覆盖初始读、会话打开、会话关闭，再在读回阶段触发超时；
        // drop_write_reply_next=1：第一次数据写触发“已生效但丟包”。
        let (dev, sim) = sim_device(Faults {
            timeout_next: 4,
            drop_write_reply_next: 1,
            ..Faults::default()
        });
        let out = dev.set_gear(Gear::Quiet).await.unwrap_err();
        assert_eq!(out, DeviceError::Uncertain);
        // 只写过一次：禁止盲目重写。
        assert_eq!(sim.flash_write_count(), 1);
    }

    #[tokio::test]
    async fn echo_mismatch_is_protocol_violation() {
        let (dev, _sim) = sim_device(Faults {
            wrong_command_next: 1,
            ..Faults::default()
        });
        let err = dev.status().await.unwrap_err();
        assert!(matches!(err, DeviceError::ProtocolViolation(_)));
    }

    #[tokio::test]
    async fn device_error_maps_to_protocol_violation() {
        let (dev, _sim) = sim_device(Faults::default());
        // 未建模命令默认拒绝。
        let req = Request::write(Command::LightsWrite, 0, vec![0u8; 4]).unwrap();
        let err = dev.exchange(req, default_read()).await.unwrap_err();
        assert!(matches!(err, DeviceError::ProtocolViolation(_)));
    }

    #[tokio::test]
    async fn raw_gate_read_whitelist() {
        let (dev, _sim) = sim_device(Faults::default());
        // 0x1a 允许。
        let req = Request::read(Command::LiveStatus, 0, 3).unwrap();
        assert!(dev.raw_exchange(req, default_read(), false).await.is_ok());
        // 0x01 拒绝（会话命令不属于 raw 读取白名单）。
        let req = Request::read(Command::SessionOpen, 0, 1).unwrap();
        let err = dev
            .raw_exchange(req, default_read(), false)
            .await
            .unwrap_err();
        assert_eq!(err, DeviceError::PermissionDenied);
    }

    #[tokio::test]
    async fn raw_write_requires_unlock() {
        let (dev, _sim) = sim_device(Faults::default());
        let req = Request::write(Command::SettingsWrite, 0, vec![1u8; 15]).unwrap();
        let err = dev
            .raw_exchange(req.clone(), default_write(), false)
            .await
            .unwrap_err();
        assert!(matches!(err, DeviceError::PermissionDenied));
        let resp = dev.raw_exchange(req, default_write(), true).await.unwrap();
        assert_eq!(resp.data, vec![1u8; 15]);
    }

    #[tokio::test]
    async fn raw_write_out_of_bounds_denied_even_unlocked() {
        let (dev, _sim) = sim_device(Faults::default());
        let req = Request::write(Command::SettingsWrite, 10, vec![0u8; 6]).unwrap();
        let err = dev
            .raw_exchange(req, default_write(), true)
            .await
            .unwrap_err();
        assert_eq!(err, DeviceError::PermissionDenied);
    }

    #[tokio::test]
    async fn info_and_device_info() {
        let (dev, _sim) = sim_device(Faults::default());
        assert_eq!(dev.info().await.unwrap().len(), 16);
        assert_eq!(dev.device_info().await.unwrap().len(), 24);
    }

    #[test]
    fn transport_kind_metadata() {
        let (dev, _sim) = sim_device(Faults::default());
        assert_eq!(dev.identity().kind, TransportKind::Usb);
    }
}
