//! CLI 命令实现（SPEC §11）。

use std::time::Duration;

use f9_core::Device;
use f9_protocol::Gear;
use f9_transport::{Transport, TransportError};

use crate::connect::{
    Connection, LockedTransport, TransportArg, connect, connect_direct, list_candidates,
};
use crate::output::{self, Envelope, OutputMode};
use crate::{CommandFailure, ExitCode};

/// daemon 子命令（SPEC §11.1）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, clap::Subcommand)]
pub enum DaemonAction {
    /// 安装 systemd user unit
    Install,
    /// 卸载 unit
    Uninstall,
    Start,
    Stop,
    Restart,
    /// 服务状态
    Status,
    /// 查看日志
    Logs,
    /// 前台运行（调试用）
    Run,
}

impl DaemonAction {
    pub fn name(&self) -> &'static str {
        match self {
            Self::Install => "install",
            Self::Uninstall => "uninstall",
            Self::Start => "start",
            Self::Stop => "stop",
            Self::Restart => "restart",
            Self::Status => "status",
            Self::Logs => "logs",
            Self::Run => "run",
        }
    }
}

/// config 子命令。
#[derive(Debug, Clone, Copy, PartialEq, Eq, clap::Subcommand)]
pub enum ConfigAction {
    /// 打印配置路径
    Path,
    /// 打印配置内容
    Show,
    /// 校验配置（不访问硬件）
    Validate,
}

impl ConfigAction {
    pub fn name(&self) -> &'static str {
        match self {
            Self::Path => "path",
            Self::Show => "show",
            Self::Validate => "validate",
        }
    }
}

/// 一次命令运行的上下文。
pub struct Ctx {
    pub output: OutputMode,
    pub transport: Option<TransportArg>,
    pub device: Option<String>,
    pub no_daemon: bool,
    /// 直连超时（用于 transport 选择与交换）。
    pub timeout: Duration,
}

impl Ctx {
    fn envelope_ok(&self, command: &str) -> Envelope {
        Envelope::ok(command)
    }
}

fn connection_failure(error: TransportError) -> CommandFailure {
    match error {
        TransportError::Disconnected => {
            CommandFailure::new(ExitCode::NoDevice, "no_device", "未发现设备")
        }
        other => CommandFailure::from(f9_core::DeviceError::from(other)),
    }
}

// ---------------------------------------------------------------- devices

pub async fn devices_list(ctx: &Ctx) -> Result<(i32, Vec<Envelope>), CommandFailure> {
    let candidates = list_candidates()
        .await
        .map_err(|e| CommandFailure::from(f9_core::DeviceError::from(e)))?;
    if candidates.is_empty() {
        return Err(CommandFailure::new(
            ExitCode::NoDevice,
            "no_device",
            "未发现设备",
        ));
    }
    let env = ctx.envelope_ok("devices.list").with_data(serde_json::json!(
        candidates
            .iter()
            .map(|c| serde_json::json!({
                "transport": c.transport.as_str(),
                "id": c.device_id,
                "capability": c.capability.as_str(),
                "summary": c.summary,
            }))
            .collect::<Vec<_>>()
    ));
    Ok((0, vec![env]))
}

// ---------------------------------------------------------------- status/info

async fn direct_transport(ctx: &Ctx) -> Result<LockedTransport, CommandFailure> {
    let transport = connect_direct(ctx.transport, ctx.device.as_deref())
        .await
        .map_err(|e| match e {
            TransportError::Disconnected => {
                CommandFailure::new(ExitCode::NoDevice, "no_device", "未发现设备")
            }
            other => CommandFailure::from(f9_core::DeviceError::from(other)),
        })?;
    LockedTransport::new(transport).map_err(|e| CommandFailure::from(f9_core::DeviceError::from(e)))
}

pub async fn status(ctx: &Ctx) -> Result<(i32, Vec<Envelope>), CommandFailure> {
    let command = "status";
    let (code, envelopes) = match connect(
        ctx.transport,
        ctx.device.as_deref(),
        ctx.no_daemon,
        ctx.output,
    )
    .await
    .map_err(connection_failure)?
    {
        Connection::Daemon => {
            let resp = ipc_call(&f9_ipc::Method::Status, None).await?;
            (0, vec![ipc_envelope(command, resp)])
        }
        Connection::Direct(locked) => {
            let dev = Device::new_shared(locked.transport.clone());
            let st = dev.status().await.map_err(CommandFailure::from)?;
            let gear = dev.gear().await.ok().map(|g| g.as_str().to_owned());
            let id = dev.identity().device_id.clone();
            let kind = dev.identity().kind.as_str().to_owned();
            let cap = dev.identity().capability.as_str();
            let mut env = ctx
                .envelope_ok(command)
                .with_device(&id, &kind)
                .with_capability(cap)
                .with_data(serde_json::json!({
                    "rpm": st.rpm,
                    "flag": format!("0x{:02x}", st.flag),
                    "gear": gear,
                }));
            env = env.with_warning("rpm_from_live_status");
            (0, vec![env])
        }
    };
    Ok((code, envelopes))
}

pub async fn info(ctx: &Ctx) -> Result<(i32, Vec<Envelope>), CommandFailure> {
    let command = "info";
    let locked = direct_transport(ctx).await?;
    let dev = Device::new_shared(locked.transport.clone());
    let info = dev.info().await.map_err(CommandFailure::from)?;
    let device_info = dev.device_info().await.ok();
    let id = dev.identity().device_id.clone();
    let kind = dev.identity().kind.as_str().to_owned();
    let cap = dev.identity().capability.as_str();
    let env = ctx
        .envelope_ok(command)
        .with_device(&id, &kind)
        .with_capability(cap)
        .with_data(serde_json::json!({
            "info_page_hex": hex(&info),
            "device_info_hex": device_info.as_ref().map(|d| hex(d)),
            "device_info_available": device_info.is_some(),
        }));
    Ok((0, vec![env]))
}

fn hex(bytes: &[u8]) -> String {
    bytes
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<Vec<_>>()
        .join("")
}

// ---------------------------------------------------------------- mode

pub async fn mode_get(ctx: &Ctx) -> Result<(i32, Vec<Envelope>), CommandFailure> {
    let command = "mode.get";
    let (code, envelopes) = match connect(
        ctx.transport,
        ctx.device.as_deref(),
        ctx.no_daemon,
        ctx.output,
    )
    .await
    .map_err(connection_failure)?
    {
        Connection::Daemon => {
            let resp = ipc_call(&f9_ipc::Method::ModeGet, None).await?;
            (0, vec![ipc_envelope(command, resp)])
        }
        Connection::Direct(locked) => {
            let dev = Device::new_shared(locked.transport.clone());
            let gear = dev.gear().await.map_err(CommandFailure::from)?;
            let id = dev.identity().device_id.clone();
            let kind = dev.identity().kind.as_str().to_owned();
            let env = ctx
                .envelope_ok(command)
                .with_device(&id, &kind)
                .with_data(serde_json::json!({ "mode": gear.as_str() }));
            (0, vec![env])
        }
    };
    Ok((code, envelopes))
}

pub async fn mode_set(ctx: &Ctx, gear: Gear) -> Result<(i32, Vec<Envelope>), CommandFailure> {
    let command = "mode.set";
    let mut warnings: Vec<String> = Vec::new();
    let (code, envelopes) = match connect(
        ctx.transport,
        ctx.device.as_deref(),
        ctx.no_daemon,
        ctx.output,
    )
    .await
    .map_err(connection_failure)?
    {
        Connection::Daemon => {
            let resp = ipc_call(&f9_ipc::Method::ModeSet, Some(gear.as_str().to_owned())).await?;
            if !resp.ok {
                return Err(CommandFailure::new(
                    ExitCode::Verification,
                    "daemon_refused",
                    resp.error.unwrap_or_default(),
                ));
            }
            (0, vec![ipc_envelope(command, resp)])
        }
        Connection::Direct(locked) => {
            let dev = Device::new_shared(locked.transport.clone());
            if gear == Gear::Turbo {
                // SPEC §11.2：每次直接调用允许，但必须打印供电/回退提示。
                warnings.push(
                    "turbo 需要充足供电；若 RPM 未达预期平台，设备可能硬件回退，这不代表设置失败"
                        .to_owned(),
                );
            }
            let outcome = dev.set_gear(gear).await.map_err(CommandFailure::from)?;
            let id = dev.identity().device_id.clone();
            let kind = dev.identity().kind.as_str().to_owned();
            let data = serde_json::json!({
                "mode": gear.as_str(),
                "outcome": match outcome {
                    f9_core::SetGearOutcome::Unchanged => "unchanged",
                    f9_core::SetGearOutcome::Applied => "applied",
                    f9_core::SetGearOutcome::Uncertain => "uncertain",
                },
            });
            let mut env = ctx
                .envelope_ok(command)
                .with_device(&id, &kind)
                .with_data(data);
            for w in warnings {
                env = env.with_warning(w);
            }
            (0, vec![env])
        }
    };
    Ok((code, envelopes))
}

// ---------------------------------------------------------------- monitor

pub async fn monitor(
    ctx: &Ctx,
    interval: Duration,
) -> Result<(i32, Vec<Envelope>), CommandFailure> {
    let mut locked = Some(direct_transport(ctx).await?);
    let is_json = ctx.output == OutputMode::Json;
    if !is_json {
        eprintln!("监控中，按 Ctrl+C 退出（间隔 {}ms）", interval.as_millis());
    }
    loop {
        let Some(active) = locked.as_ref() else {
            return Err(CommandFailure::new(
                ExitCode::Internal,
                "monitor_state",
                "monitor transport missing",
            ));
        };
        let dev = Device::new_shared(active.transport.clone());
        let id = dev.identity().device_id.clone();
        let kind = dev.identity().kind.as_str().to_owned();
        match dev.status().await {
            Ok(st) => {
                if is_json {
                    println!("{}", output::monitor_event_json(&st, &id, &kind));
                } else {
                    println!("{} RPM | flag 0x{:02x}", st.rpm, st.flag);
                }
            }
            Err(f9_core::DeviceError::Disconnected) => {
                if is_json {
                    println!(
                        "{}",
                        serde_json::json!({
                            "schema_version": output::SCHEMA_VERSION,
                            "ok": false,
                            "command": "monitor",
                            "error": { "code": "disconnected", "message": "设备断开", "retryable": true },
                        })
                    );
                } else {
                    eprintln!("设备断开，等待重连…");
                }
                let _ = dev.close().await;
                drop(dev);

                // 原 transport 已失效：释放其设备锁并重新执行发现/选择。
                drop(locked.take());
                loop {
                    tokio::time::sleep(Duration::from_millis(500)).await;
                    match direct_transport(ctx).await {
                        Ok(next) => {
                            locked = Some(next);
                            if !is_json {
                                eprintln!("设备已重新连接");
                            }
                            break;
                        }
                        Err(e) if matches!(e.code, ExitCode::NoDevice | ExitCode::Timeout) => {}
                        Err(e) => return Err(e),
                    }
                }
                continue;
            }
            Err(e) => return Err(CommandFailure::from(e)),
        }
        tokio::time::sleep(interval).await;
    }
}

// ---------------------------------------------------------------- daemon

pub async fn daemon(
    ctx: &Ctx,
    action: &crate::commands::DaemonAction,
) -> Result<(i32, Vec<Envelope>), CommandFailure> {
    let command = format!("daemon.{}", action.name());
    if action == &crate::commands::DaemonAction::Run {
        // 前台运行由 main 直接处理，不应到达这里。
        return Err(CommandFailure::new(
            ExitCode::Usage,
            "usage",
            "daemon run 须在主进程执行",
        ));
    }
    #[cfg(unix)]
    {
        let unit_dir = dirs_config().join("systemd/user");
        let unit_path = unit_dir.join("f9d.service");
        match action {
            crate::commands::DaemonAction::Install => {
                std::fs::create_dir_all(&unit_dir).map_err(|e| {
                    CommandFailure::new(ExitCode::Permission, "install_failed", e.to_string())
                })?;
                let unit = include_str!("../../../packaging/systemd/f9d.service");
                // 路径按安装布局展开；开发环境回退到 cargo target。
                let unit = unit.replace("@BINDIR@", "/usr/bin");
                std::fs::write(&unit_path, unit).map_err(|e| {
                    CommandFailure::new(ExitCode::Permission, "install_failed", e.to_string())
                })?;
                let _ = Proc::new("systemctl")
                    .args(["--user", "daemon-reload"])
                    .status();
                let env = ctx.envelope_ok(&command).with_data(serde_json::json!({
                    "installed": unit_path.display().to_string(),
                }));
                Ok((0, vec![env]))
            }
            crate::commands::DaemonAction::Uninstall => {
                let _ = std::fs::remove_file(&unit_path);
                let _ = Proc::new("systemctl")
                    .args(["--user", "daemon-reload"])
                    .status();
                let env = ctx.envelope_ok(&command);
                Ok((0, vec![env]))
            }
            crate::commands::DaemonAction::Start
            | crate::commands::DaemonAction::Stop
            | crate::commands::DaemonAction::Restart => {
                let verb = match action {
                    crate::commands::DaemonAction::Start => "start",
                    crate::commands::DaemonAction::Stop => "stop",
                    crate::commands::DaemonAction::Restart => "restart",
                    _ => unreachable!(),
                };
                let status = Proc::new("systemctl")
                    .args(["--user", verb, "f9d.service"])
                    .status()
                    .map_err(|e| {
                        CommandFailure::new(
                            ExitCode::Unsupported,
                            "systemctl_missing",
                            e.to_string(),
                        )
                    })?;
                Ok((status.code().unwrap_or(1), vec![ctx.envelope_ok(&command)]))
            }
            crate::commands::DaemonAction::Status => {
                let out = Proc::new("systemctl")
                    .args(["--user", "is-active", "f9d.service"])
                    .output()
                    .map_err(|e| {
                        CommandFailure::new(
                            ExitCode::Unsupported,
                            "systemctl_missing",
                            e.to_string(),
                        )
                    })?;
                let active = String::from_utf8_lossy(&out.stdout).trim().to_owned();
                let env = ctx
                    .envelope_ok(&command)
                    .with_data(serde_json::json!({ "active": active }));
                Ok((0, vec![env]))
            }
            crate::commands::DaemonAction::Logs => {
                let status = Proc::new("journalctl")
                    .args(["--user", "-u", "f9d.service", "-n", "100", "--no-pager"])
                    .status()
                    .map_err(|e| {
                        CommandFailure::new(
                            ExitCode::Unsupported,
                            "journalctl_missing",
                            e.to_string(),
                        )
                    })?;
                Ok((status.code().unwrap_or(1), vec![ctx.envelope_ok(&command)]))
            }
            crate::commands::DaemonAction::Run => unreachable!(),
        }
    }
    #[cfg(not(unix))]
    {
        let _ = (ctx, command);
        Err(CommandFailure::new(
            ExitCode::Unsupported,
            "unsupported",
            "Windows 不支持 daemon（v1 实验范围仅 USB 基础控制）",
        ))
    }
}

#[cfg(unix)]
fn dirs_config() -> std::path::PathBuf {
    std::env::var_os("XDG_CONFIG_HOME")
        .map(std::path::PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| std::path::PathBuf::from(h).join(".config")))
        .unwrap_or_else(|| std::path::PathBuf::from("."))
}

// ---------------------------------------------------------------- config

pub async fn config(
    ctx: &Ctx,
    action: &crate::commands::ConfigAction,
) -> Result<(i32, Vec<Envelope>), CommandFailure> {
    let command = format!("config.{}", action.name());
    let path = config_path();
    match action {
        crate::commands::ConfigAction::Path => {
            let env = ctx
                .envelope_ok(&command)
                .with_data(serde_json::json!({ "path": path.display().to_string() }));
            if ctx.output == OutputMode::Human {
                println!("{}", path.display());
            }
            Ok((0, vec![env]))
        }
        crate::commands::ConfigAction::Show => match std::fs::read_to_string(&path) {
            Ok(text) => {
                let env = ctx
                    .envelope_ok(&command)
                    .with_data(serde_json::json!({ "content": text }));
                if ctx.output == OutputMode::Human {
                    print!("{text}");
                }
                Ok((0, vec![env]))
            }
            Err(_) => Err(CommandFailure::new(
                ExitCode::Usage,
                "config_missing",
                "配置文件不存在；可用 f9d.example.toml 创建",
            )),
        },
        crate::commands::ConfigAction::Validate => {
            match std::fs::read_to_string(&path) {
                Ok(text) => {
                    // 完整校验：未知字段报错（不访问硬件）。
                    let parsed: Result<f9_core::config::DaemonConfig, _> = toml::from_str(&text);
                    match parsed {
                        Ok(cfg) => {
                            if let Err(e) = cfg.validate() {
                                return Err(CommandFailure::new(
                                    ExitCode::Usage,
                                    "config_invalid",
                                    e,
                                ));
                            }
                            let env = ctx
                                .envelope_ok(&command)
                                .with_data(serde_json::json!({ "valid": true }));
                            Ok((0, vec![env]))
                        }
                        Err(e) => Err(CommandFailure::new(
                            ExitCode::Usage,
                            "config_invalid",
                            e.to_string(),
                        )),
                    }
                }
                Err(_) => Err(CommandFailure::new(
                    ExitCode::Usage,
                    "config_missing",
                    "配置文件不存在",
                )),
            }
        }
    }
}

/// 配置路径（XDG，SPEC §13.2/§20.3）。
pub fn config_path() -> std::path::PathBuf {
    std::env::var_os("XDG_CONFIG_HOME")
        .map(std::path::PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| std::path::PathBuf::from(h).join(".config")))
        .unwrap_or_else(|| std::path::PathBuf::from("."))
        .join("legion-f9-control")
        .join("config.toml")
}

// ---------------------------------------------------------------- debug raw

#[derive(Clone)]
pub struct RawParams {
    pub cmd: u8,
    pub length: u8,
    pub offset: u16,
    pub data: Option<String>,
    pub unsafe_write: bool,
    /// 已确认的写解锁（CLI 完成确认词/ACK 校验后置位）。
    pub unlocked: bool,
}

pub async fn debug_raw(ctx: &Ctx, p: &RawParams) -> Result<(i32, Vec<Envelope>), CommandFailure> {
    let command = "debug.raw";
    let locked = direct_transport(ctx).await?;
    let kind = locked.transport.identity().kind;
    let req = if let Some(data_hex) = &p.data {
        let payload = parse_hex(data_hex)
            .map_err(|e| CommandFailure::new(ExitCode::Usage, "invalid_input", e))?;
        f9_protocol::Request::write(
            f9_protocol::Command::from_u8(p.cmd).map_err(|e| {
                CommandFailure::new(ExitCode::SafetyDenied, "unsupported_command", e.to_string())
            })?,
            p.offset,
            payload,
        )
        .map_err(|e| CommandFailure::new(ExitCode::Usage, "invalid_input", e.to_string()))?
    } else {
        f9_protocol::Request::read(
            f9_protocol::Command::from_u8(p.cmd).map_err(|e| {
                CommandFailure::new(ExitCode::SafetyDenied, "unsupported_command", e.to_string())
            })?,
            p.offset,
            p.length,
        )
        .map_err(|e| CommandFailure::new(ExitCode::Usage, "invalid_input", e.to_string()))?
    };
    // 安全门（SPEC §12）。
    let policy = f9_transport::ExchangePolicy::with_timeout(ctx.timeout);
    if req.is_write() {
        // stderr 审计：命令摘要，不记录完整 payload。
        eprintln!(
            "raw write: cmd=0x{:02x} offset={} length={} transport={} digest={} 不可逆操作",
            req.command.as_u8(),
            req.offset,
            req.length,
            kind.as_str(),
            f9_core::unsafe_write_digest(&req)
        );
    }
    let dev = Device::new_shared(locked.transport.clone());
    let resp = dev
        .raw_exchange(req, policy, p.unlocked)
        .await
        .map_err(CommandFailure::from)?;
    let env = ctx.envelope_ok(command).with_data(serde_json::json!({
        "data_hex": hex(&resp.data),
    }));
    Ok((0, vec![env]))
}

fn parse_hex(s: &str) -> Result<Vec<u8>, String> {
    let s = s.replace([',', ' '], "");
    if s.starts_with("0x") {
        return Err("data 使用十六进制字节串，如 \"0a1b2c\"（不要 0x 前缀）".to_owned());
    }
    if !s.len().is_multiple_of(2) {
        return Err("hex 长度必须为偶数".to_owned());
    }
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).map_err(|e| e.to_string()))
        .collect()
}

// ---------------------------------------------------------------- IPC 助手

async fn ipc_call(
    method: &f9_ipc::Method,
    gear: Option<String>,
) -> Result<f9_ipc::IpcResponse, CommandFailure> {
    let socket = f9_ipc::default_socket_path();
    let req = f9_ipc::IpcRequest {
        protocol_version: f9_ipc::PROTOCOL_VERSION,
        id: 1,
        method: *method,
        gear,
    };
    f9_ipc::socket::call(&socket, req)
        .await
        .map_err(CommandFailure::from)
}

fn ipc_envelope(command: &str, resp: f9_ipc::IpcResponse) -> Envelope {
    let mut env = Envelope::ok(command);
    env.ok = resp.ok;
    env.data = resp.data;
    if let Some(err) = resp.error {
        env.error = Some((err.clone(), err, false));
    }
    env
}
