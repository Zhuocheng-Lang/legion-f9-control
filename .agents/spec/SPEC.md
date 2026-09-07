# legion-f9-control 完整产品与工程规格

> 状态：Draft / 已完成需求确认  
> 目标版本：v1.0.0  
> 文档语言：中文（主文档）  
> 许可证：MPL 2.0 
> 项目属性：非联想官方项目，与 Lenovo/Legion 无隶属或背书关系

## 1. 文档目的

本文定义 `legion-f9-control` 的产品边界、协议模型、系统架构、CLI、守护进程、安全策略、测试、发布及 GitHub 治理要求。实现者应能只依赖本文拆分任务、实现、验收并发布 v1。

这是一次全新实现，不在旧目录上渐进重构，不承诺源码、模块、配置、CLI 或内部 API 兼容。旧项目只作为私有事实核对环境；新仓库不得复制不适合公开发布的材料。

## 2. 已确认决策

| 主题 | 决策 |
| --- | --- |
| 仓库名 | `legion-f9-control` |
| 用户 CLI | `f9ctl` |
| 守护进程 | `f9d` |
| 技术栈 | Rust，Cargo workspace，Rust 2024 edition |
| 产品形态 | 跨平台 CLI + 独立后台守护进程 |
| v1 正式平台 | Linux x86_64、Linux aarch64 |
| v1 实验平台 | Windows x86_64，仅 USB 基础控制 |
| macOS | v1 不支持、不承诺 |
| Linux 传输 | USB HID 与 BLE 均为 v1 发布门槛 |
| Windows 传输 | USB 实验支持；BLE 延后，不阻塞 v1 |
| v1 用户功能 | 发现、状态、信息、四挡控制、监控、温控守护、受控 raw 调试 |
| v1 不包含 | RGB 控制、OTA/刷写、GUI、远程网络控制 |
| CLI 兼容 | 完全重新设计，不兼容旧 CLI |
| daemon 默认 | 用户级服务、TOML 配置、安全三挡曲线、滞回与最短驻留 |
| raw 安全 | 只读默认开放；写入必须显式解锁；永不提供 OTA report 5 |
| 测试策略 | 确定性模拟器进 CI；正式发布另需 Linux 真机验收 |
| 公开内容 | 原创源码和脱敏协议事实；不说明私有材料来源 |
| 文档 | 中文优先，英文提供精简但完整的安装、命令、贡献说明 |
| 许可证 | MIT |

## 3. 产品愿景

为 Lenovo Legion 风刃 F9 BT 散热器提供安全、可靠、可脚本化的非官方控制工具：

1. 插 USB 时低延迟、无需 root 地控制设备；
2. 独立供电时可通过 BLE 控制；
3. 根据主机 CPU 温度自动切换固定挡位；
4. 默认保护未知配置字节、设备 Flash 和用户硬件；
5. 输出既适合人读，也适合脚本和第三方集成；
6. 将协议实现与平台 I/O 解耦，允许未来添加 GUI、更多温度源或新平台。

## 4. 范围

### 4.1 v1 必须实现

- 按 VID/PID、HID report descriptor、BLE 名称或服务 UUID 发现设备；
- 列出设备及可用传输；
- `auto`、`usb`、`ble` 三种传输选择；
- 读取实时状态和 RPM；
- 读取公开且已建模的设备信息与 15 字节设置块；
- 设置 `quiet`、`balanced`、`beast`、`turbo` 四挡；
- 设置前先读、只修改目标字节、会话化写入、写后读回；
- 持续监控状态；
- Linux 用户级温控守护进程；
- 断线重连、故障退避、通道恢复；
- 稳定 JSON 输出模式和明确退出码；
- 受安全策略约束的 raw 调试；
- 模拟设备与故障注入；
- Linux USB/BLE 真机发布验收。

### 4.2 v1 明确不实现

- 固件升级、降级、备份、恢复或 HID report 5 的任何收发；
- RGB/灯效写入；
- 任意 PWM、连续转速或未验证模式控制；
- Web 服务、云服务、遥测上报或远程监听端口；
- root 常驻系统服务；
- Windows BLE、Windows daemon、macOS；
- 导入旧配置或模拟旧文本输出。

### 4.3 后续候选

- v1.1：RGB（须完成独立协议与真机验收）；
- v1.x：Windows BLE 可行性验证；
- v2：Windows daemon、稳定库 API、可选 GUI；
- OTA 只有在单独威胁模型、恢复方案和硬件实验完成后才可另立项目讨论，不得顺手加入本仓库。

## 5. 用户与典型场景

### 5.1 日常 Linux 用户

安装二进制和 udev 规则后执行：

```console
f9ctl status
f9ctl mode set beast
f9ctl monitor
f9ctl daemon install
f9ctl daemon start
```

默认不需要 root；安装系统文件时可由包管理器或显式安装命令请求提权。

### 5.2 自动化用户

```console
f9ctl --output json status
f9ctl --transport usb --output json mode get
```

JSON 输出必须稳定、可版本化；诊断日志只写 stderr。

### 5.3 协议调试者

```console
f9ctl debug raw --cmd 0x1a --length 6 --offset 0
f9ctl debug raw --cmd 0x06 --length 15 --data "..." --unsafe-write
```

写操作必须经过命令白/黑名单、危险确认和审计日志。OTA 通道不可解锁。

## 6. 平台与能力矩阵

| 能力 | Linux USB | Linux BLE | Windows USB | Windows BLE |
| --- | --- | --- | --- | --- |
| 发现 | 稳定 | 稳定 | 实验 | 不支持 |
| 状态/RPM | 稳定 | 稳定 | 实验 | 不支持 |
| 信息读取 | 稳定 | 受 BLE 命令集限制 | 实验 | 不支持 |
| 四挡设置 | 稳定 | 稳定 | 实验 | 不支持 |
| monitor | 稳定 | 稳定 | 实验 | 不支持 |
| daemon | 稳定 | 稳定 | 不支持 | 不支持 |
| raw | 稳定 | 稳定 | 实验 | 不支持 |

“稳定”表示进入 semver 兼容承诺并经过真机发布清单。“实验”表示可发布但可能在 minor 版本调整，CLI 必须标注 `experimental`。

## 7. 协议规格

### 7.1 设备标识

- USB VID：`0x17ef`
- USB PID：`0xf00c`
- USB 产品标识：`LEGION_F9_Wired`
- BLE 名称：`LEGION_F9_BT`
- BLE 服务 UUID：`19090909-0a0a-0b0b-0c0c-0d0d0e0e0f0f`
- BLE 写特征（主机 → 设备）：`19190909-0a0a-0b0b-0c0c-0d0d0e0e0f0f`
- BLE 通知特征（设备 → 主机）：`19290909-0a0a-0b0b-0c0c-0d0d0e0e0f0f`

BLE 地址可能变化，禁止硬编码、写入示例或提交日志。发现优先使用服务 UUID，其次名称；显式地址只作为单次用户提示。

### 7.2 USB 帧

固定 64 字节，report ID 4：

```text
[0]     = 0x04
[1:2]   = sum(bytes[3..63]) & 0xffff，小端
[3]     = command
[4]     = payload length
[5:6]   = offset，小端
[7]     = request 保留字；response status
[8:64]  = payload/data
```

响应状态：`0x00` 成功、`0xfe` 忙、`0xff` 错误。解码器必须检查长度、report ID、command 回显与状态，不得索引短包。

### 7.3 BLE 帧

固定 20 字节：

```text
request:  [0]=0xee [1]=command [2]=length [3:4]=offset LE [5:20]=payload
response: [0]=0xee [1]=command [2]=length [3:4]=offset LE [5:20]=data
```

- 单帧 payload 上限 15 字节；
- BLE 无 USB 校验和；
- `0x01`、`0x02` 会话命令不等待通知，按 fire-and-forget 处理；
- 其他命令必须匹配帧头、command、长度与 offset；
- 不能只用响应 `[7]` 判错，因为它在有效响应中属于数据；
- 支持集：`0x01`、`0x02`、`0x03`、`0x04`、`0x05`、`0x06`、`0x0d`、`0x1a`、`0x20`；
- v1 正常功能不得调用未建模命令；raw 对未支持命令默认拒绝。

### 7.4 已建模命令

| 命令 | 名称 | v1 用途 |
| --- | --- | --- |
| `0x01` | session open | 写配置前打开会话 |
| `0x02` | session close | 关闭/提交会话 |
| `0x03` | info page | 读取信息页 |
| `0x05` | settings read | 分块读取设置 |
| `0x06` | settings write | 分块写设置 |
| `0x1a` | live status | 读取 flag 与 RPM |
| `0x1d` | device info | 仅 USB 正常使用 |

`0x20` 虽已知为灯效写，但 v1 正常命令不暴露；raw 写仍应默认拒绝，直至 RGB 规格完成。

### 7.5 状态解码

状态数据至少校验 3 字节：

```text
flag    = data[0]
rpm_raw = little_endian(data[1], data[2])
rpm     = rpm_raw >> 2
```

未知尾部只能以 `unknown_fields`/原始十六进制在 expert 输出显示，不得赋予未经验证的语义。

### 7.6 设置块与挡位

设置块前 15 字节视为不透明结构，仅公开以下 v1 所需字段：

```text
byte[13] = gear
0 quiet
1 balanced
2 beast
3 turbo
```

写挡位的强制算法：

1. 读取完整 15 字节；
2. 如果 `byte[13]` 已等于目标，成功返回且绝不写 Flash；
3. 克隆原块，只修改 `byte[13]`；
4. 打开配置会话；
5. 写入完整 15 字节；
6. 无论成功或失败均 best-effort 关闭会话；
7. 再次读取 15 字节；
8. 仅当读回 `byte[13]` 与目标一致时报告成功。

绝不从默认模板重建整个设置块，绝不修改未知字节。写超时属于“结果不确定”，必须先读回再决定是否重试，禁止盲目重复写入。

### 7.7 安全不变量

- 正常 API 不表达 OTA/report 5；
- 所有编码器检查 payload、offset 与 frame 容量；
- 所有解码器拒绝短帧、错 command 和错 transport；
- 同一设备同一时刻最多一个未完成命令；
- 配置写必须序列化；
- transport 切换不能发生在一次事务中间；
- 未知协议事实不得被包装成稳定字段。

## 8. 系统架构

### 8.1 Cargo workspace

```text
legion-f9-control/
├─ Cargo.toml
├─ Cargo.lock
├─ rust-toolchain.toml
├─ crates/
│  ├─ f9-protocol/       # 纯帧、命令、解析、校验；无平台 I/O
│  ├─ f9-transport/      # Transport trait、发现模型、通用重试策略
│  ├─ f9-transport-usb/  # HID report 4；Linux 稳定、Windows 实验
│  ├─ f9-transport-ble/  # Linux BLE；Windows feature 默认关闭
│  ├─ f9-core/           # Device API、事务、安全策略、daemon 控制逻辑
│  ├─ f9-sim/            # 确定性模拟设备与故障注入
│  └─ f9-ipc/            # f9ctl ↔ f9d 的本地版本化 IPC
├─ apps/
│  ├─ f9ctl/
│  └─ f9d/
├─ config/
│  └─ f9d.example.toml
├─ packaging/
│  ├─ systemd/
│  ├─ udev/
│  └─ completions/
├─ docs/
│  ├─ protocol.md
│  ├─ architecture.md
│  ├─ safety.md
│  ├─ hardware-testing.md
│  └─ troubleshooting.md
├─ tests/
│  ├─ fixtures/          # 仅手工构造、脱敏、最小数据
│  └─ integration/
├─ README.md
├─ README.en.md
├─ CONTRIBUTING.md
├─ SECURITY.md
├─ CODE_OF_CONDUCT.md
├─ LICENSE
└─ NOTICE.md              # 非官方声明与商标说明，不是 Apache NOTICE
```

### 8.2 依赖方向

```text
f9-protocol ← f9-transport ← USB/BLE adapters
      ↑             ↑
      └──────── f9-core ← f9d
                    ↑      ↕ f9-ipc
                   f9ctl ───┘

f9-sim implements the same transport boundary.
```

禁止：

- protocol 依赖 Tokio、HID、BLE 或 CLI；
- transport 依赖 daemon 策略；
- CLI 直接拼协议帧；
- 平台条件分支散落到 core。

### 8.3 Rust 工程约定

- Rust 2024 edition；
- `rust-toolchain.toml` 固定 CI 与开发工具链；
- 二进制项目提交 `Cargo.lock`；
- `unsafe` 默认禁止；必须使用时局部封装、写明 safety contract 并专项测试；
- library error 使用结构化枚举（如 `thiserror`），应用边界再添加上下文；
- CLI 使用 `clap` derive，序列化使用 `serde`；
- 异步运行时统一使用 Tokio，不混用多套 executor；
- 日志使用 `tracing`，不得用散乱 `println!` 输出诊断；
- 依赖选择以维护状态、平台支持、许可证和最小 API 面为准；
- Windows 平台 API 优先通过维护良好的 Rust 绑定；不得复制私有厂商实现。

建议候选：`clap`、`serde`、`toml`、`tokio`、`tracing`、`thiserror`、`hidapi`、`btleplug`、`directories`、`proptest`。实际锁定前必须做最小 PoC 和许可证审查，尤其验证 Linux BLE 的通知订阅/write-with-response 及 Windows 已连接设备行为。

## 9. 核心接口

示意接口，不要求逐字采用名称，但语义必须保持：

```rust
pub trait Transport {
    async fn exchange(&self, request: Request, policy: ExchangePolicy)
        -> Result<Response, TransportError>;
    async fn close(&self) -> Result<(), TransportError>;
    fn identity(&self) -> &TransportIdentity;
}

pub struct Device<T: Transport> { /* single-command lock */ }

impl<T: Transport> Device<T> {
    pub async fn status(&self) -> Result<DeviceStatus, DeviceError>;
    pub async fn info(&self) -> Result<DeviceInfo, DeviceError>;
    pub async fn gear(&self) -> Result<Gear, DeviceError>;
    pub async fn set_gear(&self, gear: Gear) -> Result<SetGearOutcome, DeviceError>;
}
```

公共模型必须：

- 使用 `Gear` 枚举而不是裸 `u8`；
- 区分 `Timeout`、`Disconnected`、`ProtocolViolation`、`Unsupported`、`PermissionDenied`、`Busy`、`VerificationFailed`；
- 区分“未执行”“已确认成功”“结果不确定”；
- 保存 transport/device identity，便于日志和 JSON 输出；
- 不在普通错误中泄露 BLE 地址或序列号。

v1 不承诺 Rust crate 的 semver 稳定公共 API；默认仅发布 workspace 内部 crates，待 v2 再决定 crates.io 发布。

## 10. 设备发现与传输选择

### 10.1 `auto` 策略

1. 找到合格 USB vendor interface 时优先 USB；
2. 否则扫描 BLE 服务 UUID；
3. 多设备时不自动猜测，提示 `--device`；
4. 一次命令选定 transport 后不得中途切换；
5. daemon 可在事务结束后重选 transport，USB 插入时优先迁移，迁移前关闭旧连接；
6. transport 改变后先读状态/配置，不立即写。

### 10.2 USB 发现

不能依赖“第二个 hidraw 节点”之类顺序启发式作为主逻辑。必须验证：

- VID/PID；
- report descriptor 包含 report ID 4；
- 输入/输出 report 长度与协议预期相符。

Linux 通过 udev `uaccess` 授权当前登录用户；规则只匹配 `17ef:f00c` 的 hidraw，不得使用全局宽权限。

### 10.3 BLE 发现

- 以服务 UUID 为主，名称为辅助；
- 不持久化真实地址；
- 明确连接/扫描超时；
- 指数退避含 jitter，设置最大值；
- 通知队列有容量上限；
- 只允许一个 in-flight 请求；
- 根据特征属性使用 write-with-response；不静默降级为未验证写法。

## 11. CLI 规格

### 11.1 全局结构

```text
f9ctl [GLOBAL OPTIONS] <COMMAND>

Global options:
  --transport <auto|usb|ble>   default: auto
  --device <selector>
  --output <human|json>        default: human
  --timeout <duration>
  -v, --verbose                repeatable
  --no-daemon                  bypass local f9d IPC
```

命令：

```text
f9ctl devices list
f9ctl status
f9ctl info
f9ctl mode get
f9ctl mode set <quiet|balanced|beast|turbo>
f9ctl monitor [--interval <duration>]
f9ctl daemon install|uninstall|start|stop|restart|status|logs|run
f9ctl config path|show|validate
f9ctl debug raw ...
```

### 11.2 行为要求

- 人类输出本地化以中文为默认，可通过环境/后续参数切换英文；
- `--output json` 禁止进度条、颜色和额外 stdout 文本；
- 日志、警告、弃用和错误详情写 stderr；
- `monitor --output json` 输出 JSON Lines，一行一个完整事件；
- 任何命令均支持 `--help`，示例不得包含真实 MAC、序列号或私有路径；
- `mode set turbo` 每次直接调用允许执行，但需打印供电/回退提示；daemon 中 turbo 默认禁用；
- 设备不支持的字段在 human 输出显示“不可用”，JSON 使用 `null` + capability，不伪造默认值。

### 11.3 JSON envelope

单次命令：

```json
{
  "schema_version": 1,
  "ok": true,
  "command": "status",
  "device": { "id": "redacted-stable-session-id", "transport": "usb" },
  "data": { "rpm": 2012, "gear": "balanced" },
  "warnings": []
}
```

错误：

```json
{
  "schema_version": 1,
  "ok": false,
  "command": "mode.set",
  "error": { "code": "verification_failed", "message": "...", "retryable": false }
}
```

同一 major 版本不得删除或改变已有字段含义；可添加字段。

### 11.4 退出码

| 码 | 含义 |
| --- | --- |
| 0 | 成功 |
| 2 | CLI 用法或配置错误 |
| 3 | 未发现设备 |
| 4 | 权限不足 |
| 5 | 设备/传输忙 |
| 6 | 超时或断线 |
| 7 | 协议响应无效 |
| 8 | 写后验证失败或结果不确定 |
| 9 | 当前平台/transport 不支持 |
| 10 | 安全策略拒绝 |
| 1 | 未分类内部错误；应尽量避免 |

## 12. raw 调试安全规格

### 12.1 默认只读

`debug raw` 默认仅允许明确白名单的读取命令，如 `0x03`、`0x05`、`0x1a`，USB 可加 `0x1d`。参数仍必须通过帧容量和 offset 校验。

### 12.2 写解锁

常规配置协议写入至少需要：

- `--unsafe-write`；
- TTY 下输入随机短确认词，而不是固定 `yes`；
- 非交互环境同时设置 `F9CTL_UNSAFE_WRITE_ACK=<本次命令摘要>`；
- stderr 显示 command、offset、length、transport 和不可逆风险；
- 日志记录命令摘要，但默认不记录完整敏感 payload。

以下始终禁止，即使有 `--unsafe-write`：

- report ID 5；
- OTA 帧、固件分块与升级命令；
- 超出已知配置地址空间的写；
- payload 溢出；
- 以 `--force` 绕过帧结构校验。

raw API 放在 `debug` 命名空间，不作为稳定自动化 API 承诺。

## 13. f9d 守护进程

### 13.1 部署模型

- Linux user service；
- 不以 root 运行；
- 单用户、单实例；
- 默认通过 systemd user unit 启动；
- 配置和 runtime socket 均位于 XDG 标准目录；
- 不监听 TCP/UDP；
- 本地 IPC 使用 Unix domain socket，权限 `0600`；
- CLI 检测到 daemon 时优先通过 IPC 读取状态和请求挡位，避免并发占用硬件。

### 13.2 配置文件

默认路径：

```text
$XDG_CONFIG_HOME/legion-f9-control/config.toml
或 ~/.config/legion-f9-control/config.toml
```

建议 schema：

```toml
schema_version = 1

[device]
transport = "auto"
# selector 不得默认写入 MAC/序列号

[daemon]
enabled = true
poll_interval = "3s"
min_dwell = "15s"
hysteresis_c = 3.0
allow_turbo = false
failure_threshold = 3
read_only_recovery = true

[[daemon.curve]]
at_c = 0.0
mode = "quiet"

[[daemon.curve]]
at_c = 50.0
mode = "balanced"

[[daemon.curve]]
at_c = 60.0
mode = "beast"

[logging]
level = "info"
format = "human"
redact_device_ids = true
```

要求：

- 启动前完整校验配置；错误配置不得部分生效；
- `config validate` 不访问硬件；
- 未识别字段默认报错，防止拼写静默失效；
- v1 不要求热重载；修改后 restart；
- 配置 schema 版本必须显式存在。

### 13.3 温度源

Linux v1：

1. 优先 CPU package 温度；
2. 支持 `x86_pkg_temp`、`TCPU` 和 coretemp package label；
3. aarch64 通过配置允许选择明确 thermal zone/hwmon；
4. 多候选时在日志中说明选择结果；
5. 温度源消失时停止写入，不猜测 0°C；
6. 拒绝 NaN、不合理值和解析溢出。

### 13.4 曲线算法

默认阶梯：

| 温度 | 挡位 |
| --- | --- |
| `< 50°C` | quiet |
| `50–<60°C` | balanced |
| `>= 60°C` | beast |

降挡需低于当前挡触发阈值至少 3°C；任意两次实际写入至少间隔 15 秒。升挡也遵守最短驻留，但若未来加入紧急保护，可另行定义且须测试。v1 默认不自动进入 turbo。

算法使用单调时钟计算间隔，不能依赖系统墙钟。

### 13.5 状态机

```text
Starting
  → Discovering
  → ConnectedReadOnly
  → Controlling
  → DegradedReadOnly
  → Reconnecting
  → Stopped
```

- 连接后先读设置，绝不立即写；
- 仅目标挡与读回挡不同且驻留条件满足时写；
- 连续 3 次读/写失败进入 `DegradedReadOnly`；
- 降级后只探测读取，不发送配置写；
- 一次完整读取成功后恢复控制，恢复前重新计算目标；
- 断线采用有上限指数退避；
- 退出信号触发会话清理、transport close 和 socket 清理；
- daemon 重启不应无条件产生一次 Flash 写。

### 13.6 IPC

v1 IPC 是本地私有协议，但必须版本化：

- request/response 带 `protocol_version` 和 request ID；
- 限制帧大小；
- 拒绝未知高版本；
- socket 权限 `0600`；
- 不通过 IPC 暴露 raw 写；
- 至少支持 health、status、mode get/set、pause/resume、shutdown（仅本用户）；
- CLI 可用 `--no-daemon` 强制直连；直连若设备锁已被 daemon 持有则返回 Busy，不抢占。

## 14. 并发、重试与资源管理

- 每个 transport 使用异步 mutex 保证单请求；
- 每个物理设备持有进程级 advisory lock；
- 读取超时可按受限策略重试；
- 写入超时先读回，不盲重发；
- BLE 通知按 command/offset 关联，陈旧通知丢弃并计数；
- 队列必须有界，溢出产生结构化警告；
- 所有后台任务必须可取消并 join；
- 关闭时 best-effort 取消订阅、断开 BLE、释放 HID、删除 socket/lock；
- 不允许 detached task 持有设备资源导致进程无法退出。

## 15. 日志、隐私与安全

### 15.1 日志

- 默认 `info`，支持 `RUST_LOG` 或配置覆盖；
- 正常 human 结果与日志分离；
- 日志字段结构化：event、transport、operation、attempt、duration、error code；
- 默认脱敏 BLE 地址、USB 序列号、用户路径；
- `--verbose` 仍不得打印完整敏感标识；只有显式 `--show-device-identifiers` 可临时展示；
- raw payload 仅在双重 debug 开关下显示。

### 15.2 威胁模型

重点防护：

- 恶意或异常设备返回短包/超长包；
- 非目标 HID 设备误匹配；
- 本地低权限进程调用 daemon socket；
- 配置文件注入错误阈值；
- raw 绕过安全写路径；
- 日志泄露设备标识；
- 供应链依赖风险；
- daemon 与 CLI 并发写造成 Flash 磨损。

项目不声称能抵御已控制当前用户账户的攻击者，也不提供远程安全边界。

### 15.3 SECURITY.md

应包含私下报告方式、支持版本、安全响应时限目标和明确范围。硬件损坏、协议未知行为和 OTA 请求必须按安全问题分流，不应鼓励公开提交带设备身份信息的日志。

## 16. 公开仓库内容与合规边界

### 16.1 可以提交

- 全新 Rust 源码；
- 人工编写的协议字段、常量、状态机与事实表；
- 脱敏、最小化、人工重构的测试向量；
- 自己编写的模拟器、文档、图表和测试；
- 公开构建、打包、CI 文件；
- 必需的设备 VID/PID、UUID、命令和字节语义。

协议文档只陈述实现所需事实，不描述私有材料来源、获取过程、文件名、内部路径或个人信息。

### 16.2 禁止提交

- 厂商安装包、升级器、DLL、EXE、固件镜像、资源文件；
- Ghidra 工程；
- 自动反编译的大段 C/汇编；
- 原始抓包、真实 MAC、序列号、主机名、用户名、绝对路径；
- `.venv`、`target/`、缓存、日志、临时转储；
- 旧仓库中的反编译产物或版权不明图片/字体；
- 声称或暗示厂商授权、官方身份的材料。

### 16.3 文案规则

README 顶部必须出现：

> 非官方社区项目。Lenovo 和 Legion 是其各自权利人的商标；本项目与 Lenovo 无关联、无背书。

不得披露协议事实的私有来源。提交历史、issue 模板和 PR 描述也适用同一规则。

### 16.4 仓库卫生

首次公开前必须：

- 在空白 Git 仓库中创建，禁止迁移旧 Git 历史；
- 执行 secret scan 与敏感标识 scan；
- 用二进制 allowlist 阻止 `.exe/.dll/.bin/.gpr/.rep/.pcap/.pcapng`；
- 设置单文件大小门槛；
- 检查全部文档示例无真实地址和私有路径；
- 审查每个依赖许可证；
- 确认 Git LFS 未被用于绕过上述限制。

## 17. 测试策略

### 17.1 测试金字塔

1. **协议单元测试**：帧编码、校验和、边界、命令匹配、短包拒绝；
2. **属性测试**：合法 Request 编码/解码不 panic，任意字节响应不 panic；
3. **core 状态机测试**：read-modify-write、不变不写、关闭会话、读回失败；
4. **模拟器集成测试**：USB/BLE 共同语义；
5. **daemon 时间测试**：使用虚拟时钟验证曲线、滞回、驻留、退避；
6. **CLI snapshot/schema 测试**：human 关键内容、JSON schema、退出码；
7. **平台编译测试**：Linux x86_64/aarch64、Windows x86_64；
8. **真机验收**：Linux USB 与 BLE。

### 17.2 模拟器能力

`f9-sim` 必须可配置：

- transport 类型；
- 当前设置块和 RPM；
- 支持/不支持命令；
- 超时、断线、busy、错 command、短包、陈旧通知；
- 写成功但回复丢失；
- 写失败；
- session open/close 无 BLE 通知；
- 重连后挡位已变化；
- 多设备发现；
- Flash 写次数计数。

关键断言：

- 相同挡位请求产生 0 次写；
- 写超时后若读回已成功，不重复写；
- 未知 14 字节在 set gear 后逐字节不变；
- daemon 稳态轮询不产生持续写；
- 进入 degraded 后不再写；
- transport 切换不会拆分一个写事务。

### 17.3 覆盖率目标

- `f9-protocol` 行覆盖率 ≥ 95%；
- `f9-core` 行覆盖率 ≥ 90%；
- workspace 总体 ≥ 80%；
- 安全关键分支（写事务、raw gate、frame bounds）要求分支全覆盖；
- 覆盖率不能替代真机验收。

## 18. 真机验收

### 18.1 发布前置条件

每个正式版本候选都必须在脱敏日志模式下完成：

#### Linux USB

- 非 root 发现目标 vendor interface；
- status 连续读取 5 分钟无解析错误；
- quiet → balanced → beast → quiet，逐次读回；
- 重复设置当前挡位时 Flash 写计数/总线观察确认无写；
- 拔插恢复；
- daemon 跑至少 30 分钟，阈值与滞回符合预期。

#### Linux BLE

- 服务 UUID 发现；
- 验证写特征为 `1919...`、通知为 `1929...`；
- status/设置读取；
- quiet → balanced → beast → quiet，逐次读回；
- 验证 session open/close 不依赖通知；
- 断连、重连和设备被占用时进入安全状态；
- daemon 跑至少 30 分钟且不重复写。

#### Turbo

- 只有在合适供电条件和人工看护下测试；
- 若 RPM 未达到预期平台，只记录硬件回退，不自动反复写 3；
- turbo 测试失败不应让前三挡回归被误判为失败，但 v1 必须明确警告能力限制。

### 18.2 验收记录

发布记录只能包含：版本、平台、内核/BlueZ 版本、transport、测试项结果、匿名设备固件标识（如确有公开必要）。不得包含 MAC、序列号、用户名、私有路径或协议来源。

## 19. CI 与质量门禁

每个 PR：

- `cargo fmt --check`；
- `cargo clippy --workspace --all-targets --all-features -- -D warnings`；
- `cargo test --workspace --all-features`；
- Linux/Windows 编译矩阵；
- 文档构建；
- 许可证与依赖策略检查（如 `cargo-deny`）；
- 已知漏洞检查（RustSec；工具故障与发现漏洞要区分）；
- secret scan；
- 禁止文件扩展与大文件检查；
- markdown/link 检查；
- JSON schema 兼容测试；
- 可选覆盖率上传，不上传含私有数据的 fixture。

合并保护：

- main 禁止直接 push；
- 至少一名 reviewer；
- 所有 required checks 通过；
- CODEOWNERS 覆盖 protocol、安全写路径、release workflow；
- Dependabot/Renovate 更新必须通过同等测试。

## 20. 构建、打包与安装

### 20.1 Release artifacts

- Linux x86_64 GNU；
- Linux aarch64 GNU；
- Windows x86_64（experimental 标签）；
- SHA-256 checksums；
- SBOM；
- shell completions 与 man page；
- 源码归档由 GitHub tag 生成。

优先评估 `cargo-dist` 或等价的可审计 release workflow。release workflow 必须固定 action commit SHA，并采用最小 GitHub token 权限。

### 20.2 Linux 安装内容

```text
/usr/bin/f9ctl
/usr/bin/f9d
/usr/lib/udev/rules.d/60-legion-f9-control.rules
/usr/lib/systemd/user/f9d.service
/usr/share/doc/legion-f9-control/
/usr/share/man/man1/f9ctl.1
```

服务文件不得硬编码开发者 home、仓库绝对路径或虚拟环境。

### 20.3 配置与数据路径

遵循 XDG：

- config：`$XDG_CONFIG_HOME/legion-f9-control/`；
- state：`$XDG_STATE_HOME/legion-f9-control/`；
- runtime socket/lock：`$XDG_RUNTIME_DIR/legion-f9-control/`；
- cache：仅在确有必要时使用 `$XDG_CACHE_HOME`。

## 21. 版本、发布与维护

### 21.1 SemVer

- CLI 命令、JSON schema、配置 schema 和正式平台行为属于兼容面；
- human 文本不是机器兼容面，但不得无理由频繁变化；
- experimental Windows 能力可在 minor 版本调整，但必须写 changelog；
- protocol 内部 crate v1 不对 crates.io 承诺稳定。

### 21.2 发布流程

1. CI 全绿；
2. 依赖、漏洞、许可证和 secret scan 通过；
3. Linux USB/BLE 真机清单通过；
4. 更新 `CHANGELOG.md` 与兼容说明；
5. 创建签名 tag；
6. GitHub Actions 构建 release artifacts；
7. 校验 checksums/SBOM；
8. 发布 GitHub Release；
9. 安装产物做 smoke test；
10. 保留验收摘要，不保留敏感原始日志。

### 21.3 提交规范

建议 Conventional Commits；至少区分 `feat`、`fix`、`docs`、`test`、`refactor`、`build`、`ci`、`security`。影响协议和安全不变量的 PR 必须在描述中列出风险与真机验证要求。

## 22. 文档要求

### 22.1 README.md（中文主文档）

必须包含：

- 非官方声明；
- 支持设备和平台矩阵；
- 30 秒安装与 status 示例；
- USB udev 与 BLE/BlueZ 前提；
- 四挡和 turbo 风险；
- daemon 快速配置；
- JSON 自动化示例；
- 隐私安全提示；
- 故障排查入口；
- 英文 README 链接。

### 22.2 README.en.md

虽为精简版，仍必须覆盖：安装、支持矩阵、基础命令、daemon、安全、贡献、许可证；不能只是中文 README 的一句链接。

### 22.3 protocol.md

只保留实现必需的脱敏事实、帧图、命令表、已知/未知边界和测试向量。不得披露来源、私有材料名称、逆向过程或个人信息。对每项事实标注 `confirmed`、`inferred` 或 `unknown`，实现只能依赖 confirmed 字段作为稳定语义。

## 23. 从旧环境提取事实的流程

这不是代码迁移，而是受控的事实重录：

1. 在新仓库建立本文与公开协议事实表；
2. 对每个常量和行为做双人/双证据核对；
3. 人工重新编写 Rust 实现与测试向量；
4. 不复制旧实现函数、注释、大段字节转储或历史日志；
5. 新测试 fixture 只保留最小字段并替换所有设备标识；
6. 在提交前运行敏感词、扩展名、大文件与 secret scan；
7. 新 Git 历史从空仓库开始。

需要优先核对的冲突事实：

- BLE 写/通知 UUID 方向必须以本规格为准：写 `1919...`，通知 `1929...`；
- BLE session open/close 不等待通知；
- BLE 响应不能单看字节 `[7]` 判断失败；
- 实现不得在后台线程/async 初始化中依赖未初始化同步原语；
- Windows 已连接 BLE 设备的发现行为不得假定与 Linux 相同。

## 24. 实施里程碑

### M0：仓库与合规骨架

- 空白 Git 仓库；
- workspace、许可证、非官方声明、贡献与安全文档；
- CI、禁止文件、大文件、secret 与许可证门禁。

**完成定义：** 空 workspace 在 Linux/Windows CI 全绿，仓库无旧材料。

### M1：协议核心与模拟器

- USB/BLE frame codec；
- typed commands/status/settings；
- 模拟器和属性测试；
- 安全不变量测试。

**完成定义：** protocol/core 关键覆盖率达标，任意字节输入不 panic。

### M2：Linux USB + CLI

- 可靠 HID 发现；
- devices/status/info/mode/monitor；
- JSON schema 与退出码；
- udev 与安装文档。

**完成定义：** Linux USB 真机基础清单通过。

### M3：Linux BLE

- UUID 服务发现、通知与 write-with-response；
- session fire-and-forget；
- 重连与错误关联；
- BLE 真机测试。

**完成定义：** Linux BLE 基础清单通过且与 USB core 共用语义。

### M4：f9d

- TOML config、温度源、曲线、滞回、驻留；
- degraded/recovery 状态机；
- IPC、锁与 systemd user service；
- 虚拟时钟测试。

**完成定义：** USB/BLE 各 30 分钟真机 daemon 验收，无重复写。

### M5：Windows USB experimental

- Windows HID 发现和基础命令；
- capability 标注；
- CI 编译和至少一次人工 smoke test。

**完成定义：** 不降低 Linux 发布质量；文档清楚标 experimental。

### M6：v1 发布加固

- raw 安全门；
- 文档、man/completion；
- release workflow、SBOM、checksums；
- 安全审查和完整发布清单。

**完成定义：** 所有 v1 验收标准满足并发布 `v1.0.0`。

## 25. 风险与缓解

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| Linux BLE 库行为与设备特征不兼容 | 阻塞正式发布 | M3 前做最小 PoC；固定 write-with-response 与通知测试 |
| 文档/旧实现存在 UUID 或响应语义冲突 | 写错特征、超时 | 单一 canonical protocol；真机验收；fixture 覆盖 |
| 配置写磨损 Flash | 缩短设备寿命 | 不变不写、驻留、读回、超时先读、写次数指标 |
| daemon 与 CLI 抢占设备 | 错乱或重复写 | UDS IPC + advisory lock + 单请求串行化 |
| turbo 供电不足回退 | 用户误判设置失败 | 明确警告、读回/RPM 区分、daemon 默认禁用 |
| Windows BLE 已连接设备难以发现 | Windows 功能延期 | v1 明确不支持，不阻塞 Linux |
| 发布材料侵权或泄露隐私 | 下架/隐私风险 | 空白历史、原创内容、扩展名门禁、脱敏 scan |
| 第三方依赖供应链风险 | 构建/安全问题 | 最小依赖、cargo-deny/audit、锁文件、固定 Actions SHA |
| 无真机的外部贡献破坏行为 | 硬件回归 | 模拟器 CI + 维护者真机 release gate |

## 26. v1 最终验收标准

只有同时满足以下条件才可称为 v1：

1. 新项目位于独立 `legion-f9-control` 目录，旧仓库零修改；
2. 公开历史中无厂商二进制、固件、反编译产物、原始抓包或个人标识；
3. Linux x86_64/aarch64 构建通过；Windows x86_64 实验构建通过；
4. Linux USB 与 BLE 均完成 status/info（按能力）/mode/monitor；
5. 挡位写严格遵循 read-modify-write、session close、readback；
6. daemon 默认曲线、3°C 滞回、15s 驻留、turbo 禁用有效；
7. 连续故障进入只读降级，恢复后先读再写；
8. raw 默认只读，写需显式解锁，OTA 永久拒绝；
9. JSON schema、退出码、配置 schema 有测试；
10. 模拟器覆盖超时、断连、陈旧通知、写回复丢失和多设备；
11. CI 全部门禁通过，关键覆盖率达标；
12. Linux USB/BLE 真机 release checklist 通过；
13. README 中文完整、英文精简完整、MIT 许可证和非官方声明齐备；
14. release 含 checksums、SBOM、man page、completion 和安装说明；
15. 无已知 blocking 安全问题或未处置高危依赖漏洞。

## 27. Definition of Done（适用于每个功能 PR）

- 需求与非目标清楚；
- 协议事实已标 confirmed/inferred/unknown；
- 正常、边界、失败、取消路径均有测试；
- 不增加未经审查的公开材料；
- human/JSON/exit code 行为已定义；
- 日志已脱敏；
- `fmt`、`clippy -D warnings`、test、docs、deny、audit 通过；
- 涉及硬件行为时更新真机验收清单；
- 涉及兼容面时更新 changelog/schema；
- 文档与示例不含真实设备标识、私有来源或开发者绝对路径。
