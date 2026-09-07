//! 确定性模拟设备与故障注入（SPEC §17.2）。
//!
//! 同一 Transport 边界的确定性实现，供 CI 与单测使用：
//! - 可配置 transport 类型、当前设置块与 RPM；
//! - 支持超时、断线、busy、错 command、短包、陈旧通知；
//! - 写成功但回复丢失、写失败、重连后挡位变化、Flash 写次数计数。

use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};

use async_trait::async_trait;
use f9_protocol::{Command, Gear, Request, Response, SettingsBlock};
use f9_transport::{
    Capability, ExchangePolicy, Transport, TransportError, TransportIdentity, TransportKind,
};

/// 模拟设备静态规格。
#[derive(Debug, Clone)]
pub struct SimSpec {
    pub kind: TransportKind,
    pub capability: Capability,
    /// 当前 15 字节设置块。
    pub settings: SettingsBlock,
    pub flag: u8,
    pub rpm: u16,
    /// 信息页与设备信息（USB 0x1d 用）。
    pub info_page: Vec<u8>,
    pub device_info: Vec<u8>,
    /// 支持的命令；`None` 表示全部已建模命令。
    pub supported: Option<Vec<Command>>,
}

impl Default for SimSpec {
    fn default() -> Self {
        // 默认设置块：未知字节固定模式，byte[13] = balanced。
        let mut settings = [0u8; 15];
        for (i, b) in settings.iter_mut().enumerate() {
            *b = i as u8;
        }
        settings[13] = 1;
        Self {
            kind: TransportKind::Usb,
            capability: Capability::Stable,
            settings: SettingsBlock::from_bytes(&settings).expect("15 bytes"),
            flag: 0,
            rpm: 2012,
            info_page: (0u8..16).collect(),
            device_info: (0u8..24).collect(),
            supported: None,
        }
    }
}

/// 故障注入配置；计数为“接下来 N 次交换触发一次”。
#[derive(Debug, Clone, Default)]
pub struct Faults {
    pub timeout_next: usize,
    pub disconnect_next: usize,
    pub busy_next: usize,
    /// 响应回显错误命令。
    pub wrong_command_next: usize,
    /// 返回短帧（USB < 64 / BLE < 20 字节）。
    pub short_frame_next: usize,
    /// 返回陈旧通知（上一次命令的响应数据）。
    pub stale_notify_next: usize,
    /// 写已生效但丢失回复（表现为 Timeout）。
    pub drop_write_reply_next: usize,
    /// 写失败（设备返回错误状态）。
    pub write_error_next: usize,
    /// 重连后设备挡位被外部改变。
    pub change_gear_on_reconnect: Option<Gear>,
}

#[derive(Debug)]
struct SimState {
    spec: SimSpec,
    faults: Faults,
    disconnected: bool,
    sessions_open: usize,
    last_response_data: Vec<u8>,
}

/// 确定性模拟 Transport。`Arc<SimTransport>` 可跨任务共享。
pub struct SimTransport {
    state: Mutex<SimState>,
    flash_writes: AtomicU64,
    identity: TransportIdentity,
}

impl SimTransport {
    pub fn new(spec: SimSpec, faults: Faults) -> Self {
        use std::sync::atomic::AtomicU64;
        static SIM_SEQ: AtomicU64 = AtomicU64::new(0);
        let n = SIM_SEQ.fetch_add(1, Ordering::SeqCst);
        let kind = spec.kind;
        let capability = spec.capability;
        Self {
            state: Mutex::new(SimState {
                spec,
                faults,
                disconnected: false,
                sessions_open: 0,
                last_response_data: Vec::new(),
            }),
            flash_writes: AtomicU64::new(0),
            identity: TransportIdentity {
                kind,
                // 会话内唯一的脱敏标识（多设备场景下互不相同）。
                device_id: format!("sim-{}-{n:04}", kind.as_str()),
                capability,
            },
        }
    }

    /// 累计 Flash 写次数（用于验证“不变不写”与防磨损）。
    pub fn flash_write_count(&self) -> u64 {
        self.flash_writes.load(Ordering::SeqCst)
    }

    pub fn settings_snapshot(&self) -> SettingsBlock {
        self.state.lock().expect("sim state").spec.settings.clone()
    }

    pub fn sessions_open(&self) -> usize {
        self.state.lock().expect("sim state").sessions_open
    }

    pub fn is_disconnected(&self) -> bool {
        self.state.lock().expect("sim state").disconnected
    }

    /// 模拟物理重连；若配置了挡位变化，则在此刻生效一次。
    pub fn reconnect(&self) {
        let mut s = self.state.lock().expect("sim state");
        s.disconnected = false;
        if let Some(gear) = s.faults.change_gear_on_reconnect {
            s.spec.settings = s.spec.settings.with_gear(gear);
            s.faults.change_gear_on_reconnect = None;
        }
    }

    /// 外部直接修改设置块（模拟其他写入方）。
    pub fn set_settings(&self, block: SettingsBlock) {
        self.state.lock().expect("sim state").spec.settings = block;
    }

    /// 合并注入新故障（计数取较大值）；供测试逐步驱动失败场景。
    pub fn add_faults(&self, faults: Faults) {
        let mut s = self.state.lock().expect("sim state");
        let f = &mut s.faults;
        f.timeout_next = f.timeout_next.max(faults.timeout_next);
        f.disconnect_next = f.disconnect_next.max(faults.disconnect_next);
        f.busy_next = f.busy_next.max(faults.busy_next);
        f.wrong_command_next = f.wrong_command_next.max(faults.wrong_command_next);
        f.short_frame_next = f.short_frame_next.max(faults.short_frame_next);
        f.stale_notify_next = f.stale_notify_next.max(faults.stale_notify_next);
        f.drop_write_reply_next = f.drop_write_reply_next.max(faults.drop_write_reply_next);
        f.write_error_next = f.write_error_next.max(faults.write_error_next);
        if faults.change_gear_on_reconnect.is_some() {
            f.change_gear_on_reconnect = faults.change_gear_on_reconnect;
        }
    }

    pub fn set_rpm(&self, rpm: u16) {
        self.state.lock().expect("sim state").spec.rpm = rpm;
    }
}

fn take(counter: &mut usize) -> bool {
    if *counter > 0 {
        *counter -= 1;
        *counter == 0
    } else {
        false
    }
}

#[async_trait]
impl Transport for SimTransport {
    async fn exchange(
        &self,
        request: Request,
        _policy: ExchangePolicy,
    ) -> Result<Response, TransportError> {
        // 同一时刻最多一个未完成命令：互斥锁覆盖整个交换。
        let mut s = self.state.lock().expect("sim state");
        if s.disconnected {
            return Err(TransportError::Disconnected);
        }
        let f = &mut s.faults;

        if take(&mut f.disconnect_next) {
            s.disconnected = true;
            return Err(TransportError::Disconnected);
        }
        let is_write = request.is_write();
        let is_data_write = is_write && !request.command.is_session_command();
        if take(&mut f.busy_next) {
            return Err(TransportError::Busy);
        }
        if take(&mut f.short_frame_next) {
            return Err(TransportError::Protocol(
                f9_protocol::ProtocolError::ShortFrame {
                    expected: 64,
                    got: 4,
                },
            ));
        }
        if take(&mut f.wrong_command_next) {
            // 回显错误命令（core 必须检测到 command mismatch）。
            let wrong = if request.command.as_u8() == 0x01 {
                Command::SessionClose
            } else {
                Command::SessionOpen
            };
            return Ok(Response {
                command: wrong,
                offset: request.offset,
                data: Vec::new(),
            });
        }
        if take(&mut f.stale_notify_next) {
            let stale = s.last_response_data.clone();
            return Ok(Response {
                command: request.command,
                offset: request.offset,
                data: stale,
            });
        }
        if is_data_write && take(&mut f.drop_write_reply_next) {
            // 写已在设备侧生效：应用到设置块并计入 Flash 写次数。
            let start = request.offset as usize;
            let end = start + request.payload.len();
            let mut block_bytes = s.spec.settings.as_bytes().to_vec();
            if end <= block_bytes.len() {
                block_bytes[start..end].copy_from_slice(&request.payload);
                s.spec.settings = SettingsBlock::from_bytes(&block_bytes).expect("same length");
                drop(s);
                self.flash_writes.fetch_add(1, Ordering::SeqCst);
                return Err(TransportError::Timeout);
            }
            return Err(TransportError::DeviceError);
        }
        if is_data_write && take(&mut f.write_error_next) {
            return Err(TransportError::DeviceError);
        }
        if take(&mut f.timeout_next) {
            return Err(TransportError::Timeout);
        }

        // 会话命令：不做能力检查（属于常规协议流）。
        if request.command.is_session_command() {
            let data = match request.command {
                Command::SessionOpen => {
                    s.sessions_open += 1;
                    vec![0x01]
                }
                Command::SessionClose => {
                    s.sessions_open = s.sessions_open.saturating_sub(1);
                    vec![0x02]
                }
                _ => unreachable!(),
            };
            let resp = Response {
                command: request.command,
                offset: request.offset,
                data,
            };
            s.last_response_data = resp.data.clone();
            return Ok(resp);
        }

        // 能力检查：未建模命令默认拒绝（SPEC §7.3）。
        if !request.command.is_modeled() {
            let supported = s
                .spec
                .supported
                .as_ref()
                .map(|list| list.contains(&request.command))
                .unwrap_or(false);
            if !supported {
                return Err(TransportError::DeviceError);
            }
        }

        let resp = match request.command {
            Command::SettingsRead => {
                let start = request.offset as usize;
                let end = start + request.length as usize;
                let bytes = s.spec.settings.as_bytes();
                if end > bytes.len() {
                    return Err(TransportError::DeviceError);
                }
                Response {
                    command: request.command,
                    offset: request.offset,
                    data: bytes[start..end].to_vec(),
                }
            }
            Command::SettingsWrite => {
                let start = request.offset as usize;
                let end = start + request.payload.len();
                let mut block_bytes = s.spec.settings.as_bytes().to_vec();
                if end > block_bytes.len() {
                    return Err(TransportError::DeviceError);
                }
                block_bytes[start..end].copy_from_slice(&request.payload);
                s.spec.settings = SettingsBlock::from_bytes(&block_bytes).expect("same length");
                let resp = Response {
                    command: request.command,
                    offset: request.offset,
                    data: request.payload.clone(),
                };
                s.last_response_data = resp.data.clone();
                drop(s);
                self.flash_writes.fetch_add(1, Ordering::SeqCst);
                return Ok(resp);
            }
            Command::LiveStatus => {
                let rpm_raw = s.spec.rpm << 2;
                Response {
                    command: request.command,
                    offset: request.offset,
                    data: vec![
                        s.spec.flag,
                        (rpm_raw & 0xff) as u8,
                        (rpm_raw >> 8) as u8,
                        0xA5,
                    ],
                }
            }
            Command::InfoPage => chunk(
                &s.spec.info_page,
                request.offset,
                request.length,
                request.command,
            ),
            Command::DeviceInfo => chunk(
                &s.spec.device_info,
                request.offset,
                request.length,
                request.command,
            ),
            other => {
                // 已知未建模命令若显式列入 supported，则回显。
                Response {
                    command: other,
                    offset: request.offset,
                    data: request.payload.clone(),
                }
            }
        };
        s.last_response_data = resp.data.clone();
        Ok(resp)
    }

    async fn close(&self) -> Result<(), TransportError> {
        Ok(())
    }

    fn identity(&self) -> &TransportIdentity {
        &self.identity
    }
}

fn chunk(buf: &[u8], offset: u16, length: u8, command: Command) -> Response {
    let start = offset as usize;
    let end = start + length as usize;
    let data = if end <= buf.len() {
        buf[start..end].to_vec()
    } else {
        Vec::new()
    };
    Response {
        command,
        offset,
        data,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use f9_protocol::Gear;

    fn sim() -> std::sync::Arc<SimTransport> {
        std::sync::Arc::new(SimTransport::new(SimSpec::default(), Faults::default()))
    }

    fn policy() -> ExchangePolicy {
        ExchangePolicy::default()
    }

    #[tokio::test]
    async fn live_status_returns_flag_and_rpm() {
        let s = sim();
        let req = Request::read(Command::LiveStatus, 0, 3).unwrap();
        let resp = s.exchange(req, policy()).await.unwrap();
        assert_eq!(resp.data.len(), 4);
        let st = f9_protocol::decode_status(&resp.data).unwrap();
        assert_eq!(st.rpm, 2012);
    }

    #[test]
    fn read_write_settings_roundtrip() {
        let s = sim();
        let block = s.settings_snapshot();
        let next = block.with_gear(Gear::Beast);
        s.set_settings(next);
        assert_eq!(s.settings_snapshot().gear().unwrap(), Gear::Beast);
    }

    #[tokio::test]
    async fn settings_write_counts_flash() {
        let s = sim();
        let req = Request::write(Command::SettingsWrite, 0, vec![0xAA; 15]).unwrap();
        s.exchange(req, policy()).await.unwrap();
        assert_eq!(s.flash_write_count(), 1);
        // 写入超出块尾：设备错误，不计数。
        let bad = Request::write(Command::SettingsWrite, 10, vec![0x00; 15]).unwrap();
        assert!(matches!(
            s.exchange(bad, policy()).await,
            Err(TransportError::DeviceError)
        ));
        assert_eq!(s.flash_write_count(), 1);
    }

    #[tokio::test]
    async fn fault_countdown_triggers_once() {
        let s = std::sync::Arc::new(SimTransport::new(
            SimSpec::default(),
            Faults {
                timeout_next: 1,
                busy_next: 1,
                ..Faults::default()
            },
        ));
        let req = Request::read(Command::LiveStatus, 0, 3).unwrap();
        // 当前顺序：busy 先于 timeout。
        assert!(matches!(
            s.exchange(req.clone(), policy()).await,
            Err(TransportError::Busy)
        ));
        assert!(matches!(
            s.exchange(req.clone(), policy()).await,
            Err(TransportError::Timeout)
        ));
        assert!(s.exchange(req, policy()).await.is_ok());
    }

    #[tokio::test]
    async fn disconnect_and_reconnect() {
        let s = std::sync::Arc::new(SimTransport::new(
            SimSpec::default(),
            Faults {
                disconnect_next: 1,
                change_gear_on_reconnect: Some(Gear::Turbo),
                ..Faults::default()
            },
        ));
        let req = Request::read(Command::LiveStatus, 0, 3).unwrap();
        assert!(matches!(
            s.exchange(req.clone(), policy()).await,
            Err(TransportError::Disconnected)
        ));
        assert!(matches!(
            s.exchange(req.clone(), policy()).await,
            Err(TransportError::Disconnected)
        ));
        s.reconnect();
        let resp = s.exchange(req, policy()).await.unwrap();
        let _ = f9_protocol::decode_status(&resp.data).unwrap();
        assert_eq!(s.settings_snapshot().gear().unwrap(), Gear::Turbo);
    }

    #[tokio::test]
    async fn drop_write_reply_applies_write_then_times_out() {
        let s = std::sync::Arc::new(SimTransport::new(
            SimSpec::default(),
            Faults {
                drop_write_reply_next: 1,
                ..Faults::default()
            },
        ));
        let req = Request::write(Command::SettingsWrite, 0, vec![0x03; 15]).unwrap();
        assert!(matches!(
            s.exchange(req, policy()).await,
            Err(TransportError::Timeout)
        ));
        assert_eq!(s.flash_write_count(), 1);
        assert_eq!(s.settings_snapshot().0[13], 0x03);
    }

    #[tokio::test]
    async fn stale_notify_returns_previous_data() {
        let s = std::sync::Arc::new(SimTransport::new(
            SimSpec::default(),
            Faults {
                stale_notify_next: 1,
                ..Faults::default()
            },
        ));
        // 第一次交换即注入陈旧通知：返回初始空数据。
        let status = Request::read(Command::LiveStatus, 0, 3).unwrap();
        let stale = s.exchange(status.clone(), policy()).await.unwrap();
        assert!(stale.data.is_empty());
        // 之后恢复正常：返回当前状态数据。
        let normal = s.exchange(status, policy()).await.unwrap();
        assert_eq!(normal.data.len(), 4);
    }

    #[tokio::test]
    async fn session_open_close_counting() {
        let s = sim();
        let open = Request::write(Command::SessionOpen, 0, vec![0x01]).unwrap();
        s.exchange(open, policy()).await.unwrap();
        assert_eq!(s.sessions_open(), 1);
        let close = Request::write(Command::SessionClose, 0, vec![0x02]).unwrap();
        s.exchange(close, policy()).await.unwrap();
        assert_eq!(s.sessions_open(), 0);
    }

    #[tokio::test]
    async fn unmodeled_command_rejected_by_default() {
        let s = sim();
        let req = Request::write(Command::LightsWrite, 0, vec![0u8; 4]).unwrap();
        assert!(matches!(
            s.exchange(req, policy()).await,
            Err(TransportError::DeviceError)
        ));
    }

    #[tokio::test]
    async fn wrong_command_echo() {
        let s = std::sync::Arc::new(SimTransport::new(
            SimSpec::default(),
            Faults {
                wrong_command_next: 1,
                ..Faults::default()
            },
        ));
        let req = Request::read(Command::LiveStatus, 0, 3).unwrap();
        let resp = s.exchange(req, policy()).await.unwrap();
        // 回显命令与请求不一致，调用方必须拒绝。
        assert_ne!(resp.command, Command::LiveStatus);
    }
}
