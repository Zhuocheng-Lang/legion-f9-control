//! f9d：用户级温控守护进程（Linux，非官方）。
//!
//! - 单用户、单实例、不以 root 运行（SPEC §13.1）；
//! - 配置与 runtime 均遵循 XDG；
//! - 不监听 TCP/UDP；IPC 走 Unix domain socket（0600）；
//! - 退出时清理会话、transport 与 socket。

//
// 非 Unix 构建中，Unix 专用路径不参与编译/使用（v1 daemon 限定 Linux）；
// 相关项在 Windows 构建中允许 dead_code（保持可编译与可测试）。
#![allow(dead_code)]
use std::sync::Arc;
use std::time::Duration;

#[cfg(unix)]
use f9_core::Device;
use f9_core::config::DaemonConfig;
#[cfg(unix)]
use f9_core::control::ControlConfig;
#[cfg(unix)]
use f9_protocol::Gear;
#[cfg(unix)]
use tokio::sync::{Mutex, mpsc, watch};

mod control_loop;
mod thermal;

fn main() {
    // 日志默认 info；RUST_LOG 可覆盖。诊断只写 stderr。
    let _ = tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .with_writer(std::io::stderr)
        .try_init();

    let args: Vec<String> = std::env::args().collect();
    // f9d run [--config <path>]
    if !args.iter().any(|a| a == "run") {
        eprintln!("用法: f9d run [--config <path>]");
        std::process::exit(2);
    }
    let config_path = args
        .iter()
        .position(|a| a == "--config")
        .and_then(|i| args.get(i + 1))
        .map(std::path::PathBuf::from)
        .unwrap_or_else(default_config_path);

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("tokio runtime");
    let code = runtime.block_on(run(config_path));
    std::process::exit(code);
}

fn default_config_path() -> std::path::PathBuf {
    config_path_from_xdg()
        .unwrap_or_else(|| std::path::PathBuf::from("legion-f9-control/config.toml"))
}

fn config_path_from_xdg() -> Option<std::path::PathBuf> {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(std::path::PathBuf::from)
        .or_else(|| {
            std::env::var_os("HOME").map(|h| std::path::PathBuf::from(h).join(".config"))
        })?;
    Some(base.join("legion-f9-control").join("config.toml"))
}

async fn run(config_path: std::path::PathBuf) -> i32 {
    tracing::info!(path = %config_path.display(), "f9d 启动（非官方社区项目）");

    // 平台门槛：v1 daemon 仅 Linux。
    if !cfg!(target_os = "linux") {
        tracing::error!("f9d 仅支持 Linux（v1）；Windows daemon 明确不支持");
        return 9;
    }

    // 配置：启动前完整校验，错误配置不得部分生效。
    let text = match std::fs::read_to_string(&config_path) {
        Ok(t) => t,
        Err(e) => {
            tracing::error!(path = %config_path.display(), error = %e, "无法读取配置");
            return 2;
        }
    };
    let cfg: DaemonConfig = match toml::from_str(&text) {
        Ok(c) => c,
        Err(e) => {
            tracing::error!(error = %e, "配置解析失败");
            return 2;
        }
    };
    if let Err(e) = cfg.validate() {
        tracing::error!(error = %e, "配置校验失败");
        return 2;
    }
    let poll = f9_core::parse_duration(&cfg.daemon.poll_interval).unwrap_or(Duration::from_secs(3));
    let Ok(ctrl_cfg) = cfg.control_config() else {
        tracing::error!("控制配置转换失败");
        return 2;
    };

    // 温度源。
    let Some(thermal) = thermal::platform_source() else {
        tracing::error!("未找到可用的 CPU 温度源（hwmon）");
        return 9;
    };

    // 平台分派：主回路仅 Unix。
    #[cfg(unix)]
    {
        return unix_run(thermal, &cfg.device.transport, ctrl_cfg, poll).await;
    }
    #[cfg(not(unix))]
    {
        drop((thermal, ctrl_cfg, poll));
        tracing::error!("f9d 主回路仅支持 Unix（v1 限定 Linux）");
        9
    }
}

/// Unix（Linux）主回路：设备发现、advisory lock、IPC 服务与控制循环。
#[cfg(unix)]
async fn unix_run(
    thermal: Box<dyn thermal::TemperatureSource>,
    desired_transport: &str,
    ctrl_cfg: ControlConfig,
    poll: Duration,
) -> i32 {
    use control_loop::{DaemonShared, SharedHandle};
    use f9_transport::Transport;

    tracing::info!(source = %thermal_source_name(&*thermal), "温度源已选定");

    let shared: SharedHandle = Arc::new(Mutex::new(DaemonShared {
        allow_turbo: ctrl_cfg.allow_turbo,
        ..DaemonShared::default()
    }));
    let (stop_tx, mut stop_rx) = watch::channel(false);
    let (manual_tx, mut manual_rx) = mpsc::channel(8);

    // IPC 服务（UDS 0600）。
    let socket_path = f9_ipc::default_socket_path();
    let listener = match f9_ipc::socket::listen(&socket_path) {
        Ok(l) => l,
        Err(e) => {
            tracing::error!(error = %e, "无法创建 IPC socket");
            return 4;
        }
    };
    let ipc_task = tokio::spawn(control_loop::serve_ipc(
        listener,
        shared.clone(),
        stop_tx.clone(),
        manual_tx,
    ));

    // 主回路。
    let mut controller = f9_core::control::Controller::new(ctrl_cfg);
    let mut device: Option<Device<Arc<dyn f9_transport::Transport>>> = None;
    let mut _lock_guard: Option<f9_core::DeviceLock> = None;
    let mut backoff =
        f9_transport::Backoff::new(Duration::from_millis(500), Duration::from_secs(30));
    let mut last_write_wall = 0u64; // 单调毫秒（进程内）
    let mut poll_index = 0u64;
    let result = loop {
        if *stop_rx.borrow() {
            break 0i32;
        }
        // 发现/重连。
        if device.is_none() {
            shared.lock().await.phase = f9_core::control::DaemonPhase::Discovering;
            match open_transport(desired_transport).await {
                Ok(t) => {
                    let kind = t.identity().kind;
                    // 进程级 advisory lock（daemon 长期持有）。
                    match f9_core::locks::try_lock(kind) {
                        Ok(guard) => {
                            _lock_guard = Some(guard);
                            let dev = Device::new_shared(t.clone());
                            device = Some(dev);
                            controller.on_connected();
                            backoff.reset();
                            tracing::info!(transport = kind.as_str(), "已连接设备");
                        }
                        Err(e) => {
                            tracing::error!(error = %e, "设备被其他进程占用（advisory lock）");
                            let _ = t.close().await;
                            device = None;
                        }
                    }
                }
                Err(e) => {
                    tracing::debug!(error = %e, "设备发现失败，退避重试");
                    let wait = backoff.next(pseudo_rand(poll_index));
                    tokio::time::sleep(wait.min(poll)).await;
                    poll_index += 1;
                    continue;
                }
            }
        }
        let Some(dev) = device.as_ref() else { break 1 };

        // 手动 mode.set 与自动温控共用同一设备句柄和串行事务边界。
        if let Ok(request) = manual_rx.try_recv() {
            let result = control_loop::set_manual_mode(
                dev,
                request.gear,
                &mut controller,
                &shared,
                last_write_wall,
            )
            .await;
            let disconnected = matches!(result, Err(f9_core::DeviceError::Disconnected));
            let reply = result.map_err(|e| e.to_string());
            let _ = request.reply.send(reply);
            if disconnected {
                controller.on_disconnected();
                shared.lock().await.phase = controller.phase();
                let _ = dev.close().await;
                device = None;
                _lock_guard = None;
            }
            continue;
        }

        // 控制一步。
        let temp = thermal.read_c();
        match control_loop::step(dev, temp, &mut controller, &shared, last_write_wall).await {
            Ok(()) => {
                shared.lock().await.phase = controller.phase();
            }
            Err(f9_core::DeviceError::Disconnected) => {
                tracing::warn!("设备断开，进入重连");
                controller.on_disconnected();
                shared.lock().await.phase = controller.phase();
                let _ = dev.close().await;
                device = None;
                _lock_guard = None; // 释放设备锁，允许重连后重新获取。
            }
            Err(e) => {
                tracing::warn!(error = %e, code = e.code(), "控制步失败");
            }
        }
        // 退出信号（SIGTERM/SIGINT）。
        tokio::select! {
            _ = tokio::time::sleep(poll) => {
                last_write_wall += poll.as_millis() as u64;
                poll_index += 1;
            }
            _ = signal_wait() => {
                tracing::info!("收到退出信号");
                break 0i32;
            }
            _ = stop_rx.changed() => {
                if *stop_rx.borrow() { break 0i32; }
            }
        }
    };

    // 清理：会话清理、transport close、socket 删除（SPEC §13.5）。
    if let Some(dev) = device.as_ref() {
        let _ = dev.close().await;
    }
    {
        let mut s = shared.lock().await;
        s.phase = f9_core::control::DaemonPhase::Stopped;
    }
    let _ = ipc_task.abort();
    let _ = std::fs::remove_file(&socket_path);
    result
}

#[allow(dead_code)] // v1 仅 Unix daemon 使用；保留编译供测试与平台移植。
fn thermal_source_name(t: &dyn thermal::TemperatureSource) -> String {
    // TemperatureSource trait 只有 read；名字在 HwmonSource 上。
    // 简化：这里仅报告可用性。
    let _ = t;
    "hwmon".to_owned()
}

#[allow(dead_code)] // v1 仅 Unix daemon 使用。
async fn open_transport(
    desired: &str,
) -> Result<Arc<dyn f9_transport::Transport>, f9_transport::TransportError> {
    #[cfg(target_os = "linux")]
    match desired {
        "usb" => {
            let list = f9_transport_usb::discover_usb()?;
            list.into_iter()
                .next()
                .map(|t| Arc::new(t) as Arc<dyn f9_transport::Transport>)
                .ok_or(f9_transport::TransportError::Disconnected)
        }
        "ble" => Ok(Arc::new(
            f9_transport_ble::discover::connect_first(Duration::from_secs(4)).await?,
        )),
        _ => {
            // auto：USB 优先，其次 BLE。
            if let Ok(list) = f9_transport_usb::discover_usb() {
                if let Some(t) = list.into_iter().next() {
                    return Ok(Arc::new(t) as Arc<dyn f9_transport::Transport>);
                }
            }
            Ok(Arc::new(
                f9_transport_ble::discover::connect_first(Duration::from_secs(4)).await?,
            ))
        }
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = desired;
        Err(f9_transport::TransportError::Unsupported)
    }
}

#[cfg(unix)]
async fn signal_wait() {
    use tokio::signal::unix::{SignalKind, signal};
    let mut term = signal(SignalKind::terminate()).expect("sigterm handler");
    let mut int = signal(SignalKind::interrupt()).expect("sigint handler");
    tokio::select! {
        _ = term.recv() => {}
        _ = int.recv() => {}
    }
}

/// 确定性伪随机（退避 jitter 用，测试友好）。
#[allow(dead_code)] // 仅 Unix 主回路使用。
fn pseudo_rand(i: u64) -> f64 {
    let x = i
        .wrapping_mul(6364136223846793005)
        .wrapping_add(1442695040888963407);
    ((x >> 33) as f64 / (u32::MAX as f64)).clamp(0.0, 1.0)
}
