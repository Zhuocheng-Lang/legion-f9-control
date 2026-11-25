# ROADMAP

## 当前状态

- `0.1.0`：USB/BLE 双链路、状态读取、挡位读写、JSON 输出、链路/ socket 选择、
  systemd 单元、udev 规则、bash/zsh/fish 补全、`f9ctl(1)` 手册页、`zig build install`
  安装布局与 CI 已完成。
- 离线验证：`mise run check`（格式、单元测试、构建、敏感信息检查）。
- 真机验证：2026-09-21/24 的 USB 与 BLE 验收、2026-11-25 的 BLE 复测见下文。
  本轮 BLE 侧改动（复用探活、预算短路、强制链路、优雅退出）已在真机复测通过；
  **USB 侧改动与超时/多候选等异常场景仍只有离线测试**，下表“未验收”项据此保持诚实标注。

## 后续事项

### 真机验收（仍未验收）

- USB 权限错误（`UsbAccessDenied`）/ I/O 错误不回退 BLE（真机未触发该类错误，只有单测）；
- 真机出现真正的截断响应（本机只观测到 report 3 短通知）→ 期望报 `BadResponse` 而不是 `Timeout`；
- 设备忙（`0xfe`）/ 错误（`0xff`）状态的真机样本与文案；
- 两台同类 BLE 设备同时在线时只采纳选中设备下的服务/特征（只有离线单测）；
- BLE 多候选回退（BlueZ 缓存旧设备 + 真设备）与 `ConnectTimeout`/`ResolveTimeout` 的实机表现；
- BlueZ 未启动、无通知、写特征不支持 write-with-response、真机响应帧长异常。
- 复测入口：本轮新增 `f9ctl --link usb|ble` 可强制单链路；`UsbAccessDenied` 可用
  无 udev 规则的非 root 终端复现；`f9ctl --socket <路径>` 便于隔离测试实例。

### 版本与发布

- 保持 `0.x`，直到上述真机验收补齐；之后按语义化版本发布，变更写入 `CHANGELOG.md`。
- 已有标准 `zig build install --prefix /usr` 布局与 systemd/udev/补全/手册；
  发行版打包（AUR/deb/rpm）与预编译产物尚未提供。

### 已解决（本轮）

- 超时文案二义性：拆分为 `ConnectTimeout`（连接没建立）、`ResolveTimeout`（已连接但服务
  解析超时）与 `Timeout`（命令响应/预算超时），f9ctl 文案相应区分；不再把 BLE 连接阶段
  显示成“等待响应超时”。
- 部署与发布缺项：systemd 单元、udev 规则、补全、手册页、安装布局、CI 与版本号（`0.1.0`）。
- 部署与加固缺陷（本轮）：`f9d.service` 缺 `RuntimeDirectory` 导致 `ProtectSystem=strict`
  下单元起不来（`226/NAMESPACE`）；`SIGTERM` 要等满一个 200ms 轮询周期才生效（现由自唤醒
  管道打断，实测 1ms）；BLE `Connect` 返回 `InProgress`/`AlreadyConnected` 时误把连接登记成
  自己的、失败收尾会踢掉他方连接；BLE 扫描在 `find` 报错路径上不 `StopDiscovery`。
  其余健壮性改动（`Powered` 适配器选择、事务级通知期限、单次 GetManagedObjects、
  `SO_SNDTIMEO`、USB 打开错误归类、`f9ctl --socket` 文案、stdout EPIPE）见 `CHANGELOG.md`。
- `ServerBusy` 文案与连接关闭时序：该错误名原先漏在 `ipc.wire_errors` 外（用户看到
  “未知错误”）；daemon 回完错误立刻 `close`，对端仍有未读字节时会发 RST 丢掉响应。
  现在补进清单，并在关闭前半关闭 + 读空剩余输入（客户端同时容忍 reset）；见
  [审计项处置](audit-unfinished.md#二测试与真机验收) 与 `CHANGELOG.md`。

### 功能范围（有意不做）

- info 页 `0x03`/`0x1d`、灯效 `0x20`、`0x04`/`0x0d`、设置块其余 14 字节与状态尾部
  未知字段：没有确认的布局/语义，按“不得猜测未确认设备行为”不实现（见 spec §4）。
- 旧 Rust 实现的温控循环、配置文件、模拟器、Windows/F9 Lite 支持：不在 v1 目标内。
- polkit/用户组鉴权：root 实例 socket 0666 是已知取舍；连接上限与独立线程已缓解占位饿死，
  真正收紧时再换用户组/polkit。

## 真机验收记录

### 20261125：本轮修复后的 BLE 复测（非 root 用户实例，Linux + BlueZ）

环境：本机仅有蓝牙连接的风刃 F9（USB 17ef:f00c 未接入），以普通用户 + 临时
`XDG_RUNTIME_DIR` 运行 `f9d`，`f9ctl --socket` 访问隔离实例。

已验收（均通过）：

- 启动/选择链路：日志显示 USB `DeviceNotFound` → 回落 BLE 成功；首次 `status` 35ms；
- 链路复用：后续 `status` 14ms、`gear` 15ms；10 对 status+gear 连续请求全部成功；
- 强制链路：`--link ble status` 成功；`--link usb status` 在 300ms 内返回
  `未找到设备`（不回落 BLE，且强制请求丢弃缓存的 BLE 句柄、下个请求自动重开）；
- 挡位写入（安全复测）：读取当前挡位 `turbo` 后写回同值，open→read→write→close→回读
  75ms 成功，回读仍为 `turbo`（未改变风扇状态，验证了会话/写入/回读路径）；
- 重启 daemon：残留 socket/lock 正常接管，首个请求 35ms 重建链路；
- 优雅退出：`SIGTERM` 后日志出现“收到终止信号，正在退出”，socket 被删除，退出码 0；
- 预算：所有请求远低于 30s 整请求预算，日志无收尾 D-Bus 超时；
- **双链路错误语义（审计项一.1 的真实场景）**：把 `DBUS_SYSTEM_BUS_ADDRESS` 指向不存在的
  socket 复现“未插 USB + BlueZ 不可用”：自动请求返回 `未找到设备`（不再被
  `BlueZ 不可用` 覆盖），f9d 日志保留“BLE 链路不可用（BluezUnavailable），保留 USB 侧诊断”；
  `--link ble` 则明确报 `BlueZ 不可用（system bus 未运行、无蓝牙适配器或蓝牙未启用）`。

未验收（本轮仍缺真机条件）：

- USB 链路（本机未接 17ef:f00c 有线接口）：本轮 USB 侧改动（校验和、读回显、
  `BadResponse`、`UsbAccessDenied`、`present`/`alive`）只有离线测试；
- `ConnectTimeout`/`ResolveTimeout`：需要让设备断电/远离或制造 GATT 解析失败，
  未在真机上诱导；
- 多候选回退（缓存旧设备 + 真设备）：本机只有一台设备；
- ServerBusy/连接上限：仅离线 E2E 测试（真机并发场景未压测）。

### 20260924：BLE 链路（非 root 开发实例，Linux + BlueZ）

已验收（均通过）：

- `f9ctl status` / `f9ctl gear`：真机 BLE 链路可用，首次请求 34ms、链路复用 ~15ms；
- 挡位写入：`quiet` → 回读一致 → `turbo` → 回读一致（各 75ms，无重放）；
- 服务/特征归属：真机 `GetManagedObjects` 中目标服务带 `GattService1.Device` 且等于选中设备，
  P1 修复的服务查找在真机通过（不通过则报 `GattUnsupported`）；
- 重启 f9d：残留 socket/lock 正常接管，重新发现/连接/服务解析成功；
- 连续请求：30×status + 10×gear+ 20×json 全部成功，链路只打开一次；
- 断开：旧句柄 1ms 内快速失败，丢弃句柄后 12s 内返回错误（有界，不卡死、不误报 USB 回落）；
  （20261125 起复用链路前会先探活，这类失败通常会在下一次请求开始时被发现并重连。）
- 重连：开机后首次请求 31ms 成功，挡位 turbo 跨断电保持，日志显示重新建链。

### 20260924：USB 链路（非 root 开发实例，udev uaccess 授权）

已验收（均通过）：

- 设备拓扑：同一 VID:PID 枚举出两个 hidraw 节点（接口 1.0 = Boot Keyboard，无 report 4；
  接口 1.1 = 协议接口，中断端点各 64 字节，描述符含 report 4 = 63 字节 + ID）。
  daemon 按 readdir 顺序枚举，先命中 1.1；对 1.0 的探测实测 300ms 无响应后被跳过（P3 语义）；
- 帧长（P2）：真机响应恰 64 字节（`04 1d 00 | 1a | 03 | 0000 | 00 | …`），
  截断帧不再被当作响应；
- 读写：`status` / `gear` 与 `gear quiet` → 回读 → `gear turbo` → 回读均一致，单次 ~11ms；
- 连续请求：多轮 status/gear 与三整轮 open→read→write→close 全部成功，链路只打开一次；
- **修复的第四个 bug（移植遗漏）**：hidraw 节点多路复用（键盘/鼠标/消费者报告 + 设备
  主动推送的 3 字节 report 3 短通知，实测挡位写入后 ~50ms 出现），旧实现把它当作响应
  → `BadLength` → 丢链路并级联超时。修复：事务层丢弃非本次响应的帧（report ID 非 4 /
  长度非 64 / 回显不符），在单调期限前继续等（`usb.exchange` + `HidFrames` 可注入帧源）。
  修复后同序列复测 3 轮 12 次请求全部成功，无重开链路。
- **拔插实测（业务执行中拔 USB，第 5–7s 拔、第 40s 插回）**：
    - 拔线瞬间旧链路请求 119ms 失败（未重放、未在同一请求内换链路）；
    - 断电期间每个请求走 USB `DeviceNotFound` → 回落 BLE，设备整机断电使 Connect 在
      12s 打开预算内失败（有界，未触发 f9ctl 35s 上限）；
    - 插回后首个请求 7ms 成功，日志重新建链，挡位停在断电前最后提交的值（无回滚/重放）。
- **修复的第五个 bug（拔线路径）**：拔线中途写 hidraw 回 `EPROTO`（errno 71），`std.posix`
  未建模 → `unexpectedErrno` 打 68 行堆栈，用户看到“未预期的系统错误”；更糟的是
  `Unexpected` 不在回落集合里，若出现在探测阶段会挡掉 BLE 回落。修复：`usb.zig` 自行翻译
  errno（`.NODEV/.NXIO/.PROTO/.SHUTDOWN → NoDevice`、`.IO → InputOutput`、
  `.ACCES/.PERM → UsbAccessDenied`（后续与 BLE 权限错误拆名）、`.NOSPC → NoSpaceLeft`、
  `.INTR → 重试`），其余记一行日志；
  真机复测见下。
- **第五个 bug 的真机复测（20260924）**：同样的拔插窗口内失败 2 次——首次为业务写入中途的
  `gear quiet`，2.9ms 返回 `设备不存在，可能已拔出`（不再有“未预期的系统错误”），f9d 日志
  仅 3 行、无堆栈与 unexpected errno；断电期间 1×12.0s 有界错误；插回后 5.8ms 恢复并重新
  建链；中断的写入未落盘（回读为上一个已提交值），无重放。

未验收（USB）：

- 真机出现真正的“截断响应”（本机只有短通知，截断响应仅单测覆盖）；
- 权限/I/O 错误下的不回落 BLE（需制造权限错误或 I/O 故障）；
- 拔插、`UsbAccessDenied`、设备忙（`0xfe`）/错误（`0xff`）状态的真机样本。

