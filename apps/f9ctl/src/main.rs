//! f9ctl：Lenovo Legion F9 散热器控制 CLI（非官方）。
//!
//! 声明：非官方社区项目。Lenovo 和 Legion 是其各自权利人的商标；
//! 本项目与 Lenovo 无关联、无背书。

use clap::{ArgAction, Parser, Subcommand};
use f9_protocol::Gear;

use f9ctl::commands::{ConfigAction, Ctx, DaemonAction, RawParams};
use f9ctl::output::OutputMode;
use f9ctl::{commands, connect, output};

/// 全局选项与命令结构（SPEC §11.1）。
#[derive(Parser)]
#[command(
    name = "f9ctl",
    version,
    about = "Lenovo Legion F9 散热器控制（非官方）",
    long_about = "非官方社区项目。Lenovo 和 Legion 是其各自权利人的商标；本项目与 Lenovo 无关联、无背书。"
)]
struct Cli {
    /// 传输选择：auto|usb|ble
    #[arg(long, value_enum, default_value = "auto")]
    transport: connect::TransportArg,
    /// 设备选择器（脱敏会话 id 的子串）
    #[arg(long)]
    device: Option<String>,
    /// 输出格式：human|json
    #[arg(long, value_enum, default_value = "human")]
    output: OutputMode,
    /// 超时（如 2s、500ms）
    #[arg(long)]
    timeout: Option<String>,
    /// 提高日志详细度（可重复；仍不打印完整敏感标识）
    #[arg(short = 'v', long, action = ArgAction::Count)]
    verbose: u8,
    /// 临时展示设备标识（默认脱敏）
    #[arg(long)]
    show_device_identifiers: bool,
    /// 绕过本地 f9d IPC，强制直连
    #[arg(long)]
    no_daemon: bool,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// 列出设备与可用传输
    Devices {
        #[command(subcommand)]
        action: DevicesAction,
    },
    /// 读取实时状态与转速
    Status,
    /// 读取设备信息（按能力）
    Info,
    /// 挡位操作
    Mode {
        #[command(subcommand)]
        action: ModeAction,
    },
    /// 持续监控
    Monitor {
        /// 采样间隔（如 1s）
        #[arg(long, default_value = "1s")]
        interval: String,
    },
    /// 守护进程管理
    Daemon {
        #[command(subcommand)]
        action: DaemonAction,
    },
    /// 配置文件操作
    Config {
        #[command(subcommand)]
        action: ConfigAction,
    },
    /// 受安全策略约束的 raw 调试（非稳定自动化 API）
    Debug {
        #[command(subcommand)]
        action: DebugAction,
    },
}

#[derive(Subcommand)]
enum DevicesAction {
    /// 列出设备
    List,
}

#[derive(Subcommand)]
enum ModeAction {
    /// 读取当前挡位
    Get,
    /// 设置挡位
    Set {
        /// quiet|balanced|beast|turbo
        #[arg(value_parser = gear_parser)]
        gear: Gear,
    },
}

fn gear_parser(s: &str) -> Result<Gear, String> {
    s.parse::<Gear>()
        .map_err(|_| format!("无效挡位 {s:?}（可选 quiet|balanced|beast|turbo）"))
}

#[derive(Subcommand)]
enum DebugAction {
    /// 受安全策略约束的 raw 交换
    Raw {
        /// 命令字节（如 0x1a）
        #[arg(long, value_parser = parse_u8_hex)]
        cmd: u8,
        /// 读取长度
        #[arg(long, default_value_t = 0)]
        length: u8,
        /// 偏移
        #[arg(long, default_value_t = 0)]
        offset: u16,
        /// 写数据（十六进制字节串）；提供时为写操作
        #[arg(long)]
        data: Option<String>,
        /// 显式解锁写（仍需确认词或 ACK 环境变量）
        #[arg(long)]
        unsafe_write: bool,
    },
}

fn parse_u8_hex(s: &str) -> Result<u8, String> {
    let t = s.trim().trim_start_matches("0x");
    u8::from_str_radix(t, 16).map_err(|e| format!("无效字节 {s:?}: {e}"))
}

fn main() {
    let cli = Cli::parse();
    let timeout = cli
        .timeout
        .as_deref()
        .map(f9ctl::parse_duration)
        .transpose()
        .unwrap_or_else(|e| {
            eprintln!("f9ctl: {e}");
            std::process::exit(2);
        })
        .unwrap_or(std::time::Duration::from_secs(5));

    // 日志：诊断只写 stderr；RUST_LOG 或 -v 控制。
    let filter = match cli.verbose {
        0 => "info",
        1 => "debug",
        _ => "trace",
    };
    let _ = tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new(filter)),
        )
        .with_writer(std::io::stderr)
        .try_init();

    let ctx = Ctx {
        output: cli.output,
        transport: Some(cli.transport),
        device: cli.device.clone(),
        no_daemon: cli.no_daemon,
        timeout,
    };

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("tokio runtime");

    let result = runtime.block_on(run(&cli, &ctx));
    match result {
        Ok(code) => std::process::exit(code),
        Err(fail) => {
            if cli.output == OutputMode::Json {
                let env = output::Envelope::err("command").with_error(
                    &fail.error_code,
                    &fail.message,
                    fail.retryable,
                );
                println!("{}", env.to_json());
            } else {
                eprintln!("f9ctl: {}", fail.message);
            }
            std::process::exit(fail.code.as_i32());
        }
    }
}

async fn run(cli: &Cli, ctx: &Ctx) -> Result<i32, f9ctl::CommandFailure> {
    match &cli.command {
        Command::Devices {
            action: DevicesAction::List,
        } => {
            let (code, envs) = commands::devices_list(ctx).await?;
            print_envelopes(ctx, code, &envs);
            Ok(code)
        }
        Command::Status => {
            let (code, envs) = commands::status(ctx).await?;
            print_envelopes(ctx, code, &envs);
            Ok(code)
        }
        Command::Info => {
            let (code, envs) = commands::info(ctx).await?;
            print_envelopes(ctx, code, &envs);
            Ok(code)
        }
        Command::Mode { action } => match action {
            ModeAction::Get => {
                let (code, envs) = commands::mode_get(ctx).await?;
                print_envelopes(ctx, code, &envs);
                Ok(code)
            }
            ModeAction::Set { gear } => {
                let (code, envs) = commands::mode_set(ctx, *gear).await?;
                print_envelopes(ctx, code, &envs);
                Ok(code)
            }
        },
        Command::Monitor { interval } => {
            let interval = f9ctl::parse_duration(interval)
                .map_err(|e| f9ctl::CommandFailure::new(f9ctl::ExitCode::Usage, "usage", e))?;
            let (code, _envs) = commands::monitor(ctx, interval).await?;
            Ok(code)
        }
        Command::Daemon { action } => {
            if matches!(action, DaemonAction::Run) {
                // 前台运行转交 f9d 二进制（f9ctl daemon run 只是提示）。
                eprintln!("请运行 f9d run（前台）或 f9ctl daemon start（systemd user service）");
                return Ok(2);
            }
            let (code, envs) = commands::daemon(ctx, action).await?;
            print_envelopes(ctx, code, &envs);
            Ok(code)
        }
        Command::Config { action } => {
            let (code, envs) = commands::config(ctx, action).await?;
            print_envelopes(ctx, code, &envs);
            Ok(code)
        }
        Command::Debug {
            action:
                DebugAction::Raw {
                    cmd,
                    length,
                    offset,
                    data,
                    unsafe_write,
                },
        } => {
            let params = RawParams {
                cmd: *cmd,
                length: *length,
                offset: *offset,
                data: data.clone(),
                unsafe_write: *unsafe_write,
                unlocked: false,
            };
            let params = raw_write_gate(params)?;
            let (code, envs) = commands::debug_raw(ctx, &params).await?;
            print_envelopes(ctx, code, &envs);
            Ok(code)
        }
    }
}

fn print_envelopes(ctx: &Ctx, code: i32, envs: &[output::Envelope]) {
    for env in envs {
        if ctx.output == OutputMode::Json {
            println!("{}", env.to_json());
        } else if let Some(data) = &env.data {
            // human 输出：中文友好格式（ diagnostics 一律 stderr）。
            if let Some(cands) = data.as_array() {
                for c in cands {
                    println!(
                        "[{}] {} ({}) {}",
                        c["transport"].as_str().unwrap_or("?"),
                        c["id"].as_str().unwrap_or("?"),
                        c["capability"].as_str().unwrap_or("?"),
                        c["summary"].as_str().unwrap_or("")
                    );
                }
            } else {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&env.to_json()).unwrap_or_default()
                );
            }
        }
        for w in &env.warnings {
            eprintln!("警告: {w}");
        }
    }
    let _ = code;
}

/// raw 写解锁门（SPEC §12.2）：
/// - `--unsafe-write` 必须；
/// - TTY 下输入随机短确认词；
/// - 非交互环境需 `F9CTL_UNSAFE_WRITE_ACK=<本次命令摘要>`。
fn raw_write_gate(p: RawParams) -> Result<RawParams, f9ctl::CommandFailure> {
    let is_write = p.data.is_some();
    if !is_write {
        return Ok(p.clone());
    }
    if !p.unsafe_write {
        return Err(f9ctl::CommandFailure::new(
            f9ctl::ExitCode::SafetyDenied,
            "write_locked",
            "raw 写被拒绝：需要 --unsafe-write 与确认词（TTY）或 F9CTL_UNSAFE_WRITE_ACK（非交互）",
        ));
    }
    // 构造与 commands::debug_raw 相同摘要所需的 Request。
    let payload = data_bytes(p.data.as_deref().unwrap_or_default());
    let cmd = f9_protocol::Command::from_u8(p.cmd).map_err(|e| {
        f9ctl::CommandFailure::new(
            f9ctl::ExitCode::SafetyDenied,
            "unsupported_command",
            e.to_string(),
        )
    })?;
    let req = f9_protocol::Request::write(cmd, p.offset, payload).map_err(|e| {
        f9ctl::CommandFailure::new(f9ctl::ExitCode::Usage, "invalid_input", e.to_string())
    })?;
    let digest = f9_core::unsafe_write_digest(&req);

    if !is_tty() {
        // 非交互：F9CTL_UNSAFE_WRITE_ACK 必须等于本次命令摘要。
        let ack = std::env::var("F9CTL_UNSAFE_WRITE_ACK").unwrap_or_default();
        if ack != digest {
            return Err(f9ctl::CommandFailure::new(
                f9ctl::ExitCode::SafetyDenied,
                "ack_missing",
                format!("非交互环境需设置 F9CTL_UNSAFE_WRITE_ACK={digest}（本次命令摘要）"),
            ));
        }
        let mut p = p.clone();
        p.unlocked = true;
        return Ok(p);
    }
    // TTY：随机短确认词。
    let word = random_word();
    eprintln!(
        "即将执行 raw 写：cmd=0x{:02x} offset={} length={}\n这是不可逆操作，可能损坏设备配置。",
        p.cmd, p.offset, p.length
    );
    eprintln!("请输入确认词 {word} 以继续：");
    let mut line = String::new();
    std::io::stdin()
        .read_line(&mut line)
        .map_err(|e| f9ctl::CommandFailure::new(f9ctl::ExitCode::Usage, "stdin", e.to_string()))?;
    if line.trim() != word {
        return Err(f9ctl::CommandFailure::new(
            f9ctl::ExitCode::SafetyDenied,
            "confirmation_mismatch",
            "确认词不匹配，已取消",
        ));
    }
    let mut p = p.clone();
    p.unlocked = true;
    Ok(p)
}

fn data_bytes(hex_str: &str) -> Vec<u8> {
    let s = hex_str.replace([',', ' '], "");
    (0..s.len())
        .step_by(2)
        .filter_map(|i| u8::from_str_radix(&s[i..i + 2], 16).ok())
        .collect()
}

fn is_tty() -> bool {
    // 无 unsafe：标准库 IsTerminal。
    std::io::IsTerminal::is_terminal(&std::io::stdin())
}

/// 随机短确认词（不是固定 "yes"）。
fn random_word() -> String {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0)
        .hash(&mut h);
    std::process::id().hash(&mut h);
    format!("F9{:04x}", (h.finish() & 0xffff) as u16)
}
