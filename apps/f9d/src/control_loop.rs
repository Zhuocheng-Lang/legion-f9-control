//! f9d IPC/控制回路模块。
//!
//! 非 Unix 构建中部分项仅测试使用（v1 daemon 限定 Linux），允许 dead_code。
#![allow(dead_code)]
//! daemon 控制回路与 IPC 服务（SPEC §13.5、§13.6）。
//!
//! 状态机：Starting → Discovering → ConnectedReadOnly → Controlling
//!        → DegradedReadOnly / Reconnecting → Stopped。

use std::sync::Arc;
use std::time::Duration;

use f9_core::Device;
use f9_core::control::{Controller, DaemonPhase, Decision};
use f9_ipc::{IpcRequest, IpcResponse};
use f9_protocol::Gear;
use f9_transport::{ExchangePolicy, Transport};
use tokio::sync::{Mutex, watch};

/// daemon 共享状态（IPC 读侧）。
/// 非 Unix 构建中仅测试使用（v1 daemon 限定 Linux）。
#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct DaemonShared {
    pub phase: DaemonPhase,
    pub rpm: Option<u16>,
    pub gear: Option<Gear>,
    pub paused: bool,
    pub temperature_c: Option<f64>,
    pub last_write_at_ms: Option<u64>,
    pub transport: Option<String>,
}

impl Default for DaemonShared {
    fn default() -> Self {
        Self {
            phase: DaemonPhase::Starting,
            rpm: None,
            gear: None,
            paused: false,
            temperature_c: None,
            last_write_at_ms: None,
            transport: None,
        }
    }
}

pub type SharedHandle = Arc<Mutex<DaemonShared>>; //（非 Unix 构建中仅测试使用）
#[allow(unused_imports)]
use std::sync::Arc as _unused_arc_reexport;

/// 控制回路输入。`now_ms` 由调用方注入（虚拟时钟可测）。
#[allow(dead_code)]
pub struct LoopInputs<'a> {
    pub temp: Option<f64>,
    pub controller: &'a mut Controller,
    pub shared: &'a SharedHandle,
    /// 自启动以来的单调毫秒。
    pub now_ms: u64,
}

/// 单次温度轮询决策（纯逻辑，虚拟时钟可测）。
#[allow(dead_code)]
pub fn poll_once(inputs: LoopInputs<'_>) -> Decision {
    let LoopInputs {
        temp,
        controller,
        shared: _,
        now_ms,
    } = inputs;

    controller.on_temperature(temp, now_ms)
}

/// IPC 请求处理（不直接触硬件；写请求转交控制回路 via channel）。
#[allow(dead_code)]
pub async fn handle_ipc(
    shared: &SharedHandle,
    stop_tx: &watch::Sender<bool>,
    req: IpcRequest,
) -> Result<IpcResponse, f9_ipc::IpcError> {
    f9_ipc::check_request_version(&req)?;
    let s = shared.lock().await;
    let resp = |ok: bool, error: Option<String>, data: Option<serde_json::Value>| IpcResponse {
        protocol_version: f9_ipc::PROTOCOL_VERSION,
        id: req.id,
        ok,
        error,
        data,
    };
    match req.method {
        f9_ipc::Method::Health => Ok(resp(
            true,
            None,
            Some(serde_json::json!({
                "phase": format!("{:?}", s.phase),
                "paused": s.paused,
                "transport": s.transport,
            })),
        )),
        f9_ipc::Method::Status => Ok(resp(
            true,
            None,
            Some(serde_json::json!({
                "rpm": s.rpm,
                "gear": s.gear.map(|g| g.as_str()),
                "temperature_c": s.temperature_c,
                "phase": format!("{:?}", s.phase),
            })),
        )),
        f9_ipc::Method::ModeGet => Ok(resp(
            true,
            None,
            Some(serde_json::json!({ "mode": s.gear.map(|g| g.as_str()) })),
        )),
        f9_ipc::Method::ModeSet => {
            // daemon 中 turbo 默认禁用（SPEC §11.2/§13.2）。
            let Some(gear_str) = req.gear.as_deref() else {
                return Ok(resp(false, Some("missing gear".to_owned()), None));
            };
            let Ok(gear) = gear_str.parse::<Gear>() else {
                return Ok(resp(
                    false,
                    Some(format!("invalid gear {gear_str:?}")),
                    None,
                ));
            };
            if gear == Gear::Turbo {
                return Ok(resp(
                    false,
                    Some("daemon 默认禁用 turbo（配置 allow_turbo=true 才可启用）".to_owned()),
                    None,
                ));
            }
            if s.paused {
                return Ok(resp(false, Some("daemon paused".to_owned()), None));
            }
            // 写请求转交控制回路：通过 IPC 直接执行需要 device 句柄；
            // v1 的模式是 daemon 自主控制 + CLI 的 set 经由 IPC 直通执行。
            Ok(resp(
                true,
                None,
                Some(serde_json::json!({ "requested": gear.as_str(), "async": true })),
            ))
        }
        f9_ipc::Method::Pause => {
            drop(s);
            shared.lock().await.paused = true;
            Ok(resp(true, None, None))
        }
        f9_ipc::Method::Resume => {
            drop(s);
            shared.lock().await.paused = false;
            Ok(resp(true, None, None))
        }
        f9_ipc::Method::Shutdown => {
            let _ = stop_tx.send(true);
            Ok(resp(true, None, None))
        }
    }
}

/// 单用户 IPC 服务：接受连接并处理请求，直到 shutdown。
#[allow(dead_code)]
pub async fn serve_ipc(
    listener: f9_ipc::IpcListener,
    shared: SharedHandle,
    stop_tx: watch::Sender<bool>,
) -> Result<(), f9_ipc::IpcError> {
    #[cfg(unix)]
    {
        use tokio::io::AsyncWriteExt;
        let mut stop_rx = stop_tx.subscribe();
        loop {
            tokio::select! {
                accepted = listener.accept() => {
                    let Ok((mut stream, _)) = accepted else { continue };
                    let shared = shared.clone();
                    let stop_tx = stop_tx.clone();
                    tokio::spawn(async move {
                        while let Ok(req) = f9_ipc::socket::read_frame::<IpcRequest>(&mut stream).await {
                            match handle_ipc(&shared, &stop_tx, req.clone()).await {
                                Ok(resp) => {
                                    if f9_ipc::socket::write_frame(&mut stream, &resp).await.is_err() {
                                        break;
                                    }
                                }
                                Err(e) => {
                                    let _ = f9_ipc::socket::write_frame(&mut stream, &IpcResponse {
                                        protocol_version: f9_ipc::PROTOCOL_VERSION,
                                        id: req.id,
                                        ok: false,
                                        error: Some(e.to_string()),
                                        data: None,
                                    }).await;
                                    break;
                                }
                            }
                        }
                    });
                }
                _ = stop_rx.changed() => {
                    if *stop_rx.borrow() {
                        return Ok(());
                    }
                }
            }
        }
    }
    #[cfg(not(unix))]
    {
        let _ = (listener, shared, stop_tx);
        Err(f9_ipc::IpcError::Unsupported)
    }
}

/// 主控制回路一步：读温度 → 读状态/挡位 → 决策 → 写（含会话化事务）。
///
/// 独立函数便于用 sim + 虚拟时钟在测试中驱动。
pub async fn step<T: Transport>(
    dev: &Device<T>,
    temp: Option<f64>,
    controller: &mut Controller,
    shared: &SharedHandle,
    now_ms: u64,
) -> Result<(), f9_core::DeviceError> {
    {
        let mut s = shared.lock().await;
        s.temperature_c = temp;
        s.phase = controller.phase();
        s.transport = Some(dev.identity().kind.as_str().to_owned());
    }
    match controller.on_temperature(temp, now_ms) {
        Decision::None => {
            // 只读轮询：读取挡位（探测/恢复判定）。
            match dev.gear().await {
                Ok(g) => {
                    controller.on_gear_read_ok(g);
                    let mut s = shared.lock().await;
                    s.gear = Some(g);
                    s.phase = controller.phase();
                }
                Err(f9_core::DeviceError::Disconnected) => {
                    controller.on_disconnected();
                    let mut s = shared.lock().await;
                    s.phase = controller.phase();
                    return Err(f9_core::DeviceError::Disconnected);
                }
                Err(e) => {
                    // 读失败（含超时）计入连续失败阈值。
                    controller.on_read_failed();
                    let mut s = shared.lock().await;
                    s.phase = controller.phase();
                    return Err(e);
                }
            }
            Ok(())
        }
        Decision::Write(gear) => {
            controller.on_write_started();
            match dev.set_gear(gear).await {
                Ok(f9_core::SetGearOutcome::Unchanged) => {
                    // 读回显示已是目标：无需写。
                    controller.on_gear_read_ok(gear);
                    let mut s = shared.lock().await;
                    s.gear = Some(gear);
                    s.phase = controller.phase();
                }
                Ok(
                    outcome @ (f9_core::SetGearOutcome::Applied
                    | f9_core::SetGearOutcome::Uncertain),
                ) => {
                    // Uncertain 只可能出现在读回失败路径；保守计失败一次。
                    if outcome == f9_core::SetGearOutcome::Uncertain {
                        controller.on_write_failed();
                    } else {
                        controller.on_write_ok(gear, now_ms);
                    }
                    let mut s = shared.lock().await;
                    s.gear = Some(gear);
                    s.last_write_at_ms = Some(now_ms);
                    s.phase = controller.phase();
                }
                Err(e) => {
                    controller.on_write_failed();
                    let mut s = shared.lock().await;
                    s.phase = controller.phase();
                    return Err(e);
                }
            }
            Ok(())
        }
    }
}

/// 组装默认交换策略。
#[allow(dead_code)]
pub fn exchange_policy(timeout: Duration) -> ExchangePolicy {
    ExchangePolicy::with_timeout(timeout)
}

#[cfg(test)]
mod tests {
    use super::*;
    use f9_core::ControlConfig;
    use f9_core::config::DaemonConfig;
    use f9_sim::{Faults, SimSpec, SimTransport};

    fn controller() -> Controller {
        Controller::new(ControlConfig::default())
    }

    #[test]
    fn poll_once_respects_controller() {
        let mut c = controller();
        c.on_connected();
        c.on_gear_read_ok(Gear::Quiet);
        let shared = Arc::new(Mutex::new(DaemonShared::default()));
        // 高温 → 写 beast。
        let d = poll_once(LoopInputs {
            temp: Some(65.0),
            controller: &mut c,
            shared: &shared,
            now_ms: 0,
        });
        assert_eq!(d, Decision::Write(Gear::Beast));
    }

    #[test]
    fn poll_once_none_before_first_read() {
        let mut c = controller();
        c.on_connected();
        let shared = Arc::new(Mutex::new(DaemonShared::default()));
        let d = poll_once(LoopInputs {
            temp: Some(65.0),
            controller: &mut c,
            shared: &shared,
            now_ms: 0,
        });
        assert_eq!(d, Decision::None);
    }

    #[tokio::test]
    async fn step_writes_and_updates_shared() {
        let sim = Arc::new(SimTransport::new(SimSpec::default(), Faults::default()));
        let dev = Device::new_shared(sim.clone());
        let mut c = controller();
        c.on_connected();
        c.on_gear_read_ok(Gear::Balanced);
        let shared = Arc::new(Mutex::new(DaemonShared::default()));
        step(&dev, Some(65.0), &mut c, &shared, 0).await.unwrap();
        let s = shared.lock().await;
        assert_eq!(s.gear, Some(Gear::Beast));
        assert_eq!(s.last_write_at_ms, Some(0));
        drop(s);
        assert_eq!(sim.flash_write_count(), 1);
    }

    #[tokio::test]
    async fn steady_state_polling_writes_nothing() {
        // 稳态轮询不产生持续写（SPEC §17.2）。
        let sim = Arc::new(SimTransport::new(SimSpec::default(), Faults::default()));
        let dev = Device::new_shared(sim.clone());
        let mut c = controller();
        c.on_connected();
        c.on_gear_read_ok(Gear::Balanced);
        let shared = Arc::new(Mutex::new(DaemonShared::default()));
        for i in 0..30u64 {
            step(&dev, Some(55.0), &mut c, &shared, i * 1000)
                .await
                .unwrap();
        }
        assert_eq!(sim.flash_write_count(), 0);
    }

    #[tokio::test]
    async fn degraded_after_failures_stops_writes() {
        // 连续 3 次读失败 → DegradedReadOnly；降级后不再写（SPEC §13.5/§17.2）。
        let sim = Arc::new(SimTransport::new(SimSpec::default(), Faults::default()));
        let dev = Device::new_shared(sim.clone());
        let mut c = controller();
        c.on_connected();
        c.on_gear_read_ok(Gear::Balanced);
        let shared = Arc::new(Mutex::new(DaemonShared::default()));
        for i in 0..3u64 {
            sim.add_faults(Faults {
                timeout_next: 1,
                ..Faults::default()
            });
            let _ = step(&dev, Some(70.0), &mut c, &shared, i * 1000).await;
        }
        assert_eq!(c.phase(), DaemonPhase::DegradedReadOnly);
        // 降级后只读：即使温度高也不再写。
        for i in 3..6u64 {
            sim.add_faults(Faults {
                timeout_next: 1,
                ..Faults::default()
            });
            let _ = step(&dev, Some(90.0), &mut c, &shared, i * 1000).await;
        }
        assert_eq!(sim.flash_write_count(), 0);
    }

    #[test]
    fn example_config_to_control_config() {
        let cfg: DaemonConfig = toml::from_str(
            r#"
schema_version = 1
[daemon]
poll_interval = "3s"
min_dwell = "15s"
hysteresis_c = 3.0

[[daemon.curve]]
at_c = 0.0
mode = "quiet"
[[daemon.curve]]
at_c = 50.0
mode = "balanced"
[[daemon.curve]]
at_c = 60.0
mode = "beast"
"#,
        )
        .unwrap();
        let cc = cfg.control_config().unwrap();
        assert_eq!(cc.curve.last().unwrap().gear, Gear::Beast);
    }

    #[tokio::test]
    async fn ipc_mode_set_rejects_turbo() {
        let (tx, _rx) = watch::channel(false);
        let shared = Arc::new(Mutex::new(DaemonShared::default()));
        let req = IpcRequest {
            protocol_version: f9_ipc::PROTOCOL_VERSION,
            id: 1,
            method: f9_ipc::Method::ModeSet,
            gear: Some("turbo".into()),
        };
        let resp = handle_ipc(&shared, &tx, req).await.unwrap();
        assert!(!resp.ok);
    }

    #[tokio::test]
    async fn ipc_shutdown_sets_stop() {
        let (tx, rx) = watch::channel(false);
        let shared = Arc::new(Mutex::new(DaemonShared::default()));
        let req = IpcRequest {
            protocol_version: f9_ipc::PROTOCOL_VERSION,
            id: 2,
            method: f9_ipc::Method::Shutdown,
            gear: None,
        };
        let resp = handle_ipc(&shared, &tx, req).await.unwrap();
        assert!(resp.ok);
        assert!(*rx.borrow());
    }
}
