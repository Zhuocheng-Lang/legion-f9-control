# Changelog

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循语义化版本。项目处于 0.x，接口与输出格式仍可能调整。

## [Unreleased]

### Fixed

- `packaging/f9d.service` 增加 `RuntimeDirectory=f9d`：`ProtectSystem=strict` 下 `/run` 只读，
  而 `ReadWritePaths` 不会创建目录，`/run/f9d` 不存在时单元在挂载命名空间阶段直接失败
  （`226/NAMESPACE`），首次启用 f9d 根本起不来。
- `f9d` 的 `SIGTERM`/`SIGINT`/`SIGHUP` 现在立即打断 accept 前的 `poll`（自唤醒管道）：
  停机延迟从最多一个 200ms 轮询周期降到毫秒级（实测 1ms）。
- BLE：`Connect` 返回 `InProgress`/`AlreadyConnected` 时不再把自己登记成“已连接”，
  失败收尾不会 `Disconnect` 掉他方（其他主机/进程）建立的连接。
- BLE 扫描在 `find` 报错的提前返回路径上也会 `StopDiscovery`：适配器不再滞留 LE 扫描态。
- BLE 通知等待改为事务级绝对期限：持续收到不匹配旧通知时，5s 单操作上限不再被逐帧续期。
- BLE 适配器优先选 `Powered=true` 的那个：多适配器主机上不再锁到未启用的适配器。
- USB 枚举时，打开设备节点的非权限错误（节点忙、I/O 故障）改为上报，不再被“接口无应答”
  掩盖而错误回落 BLE。
- `f9ctl --socket <路径>` 连不上时按该路径报错，不再显示默认 socket 路径把排查引偏。
- `f9ctl` 的 stdout 管道被关闭（如 `f9ctl status | head -n0`）按成功退出，不再误报
  “与 f9d 的连接已断开”。
- 拒绝类响应不再被 RST 丢弃（daemon 半关闭 + 读空剩余输入，客户端容忍 reset）。
- `ServerBusy` 补进 `ipc.wire_errors`（f9d 同时在处理的连接已达上限）并给出“连接数已满”文案。
  此前该错误名不在 `ipc.wire_errors` 清单里，会退化成“f9d 返回未知错误”。
- `f9d` 关闭连接前先半关闭（`shutdown` write）并读空对端剩余输入（上限 200ms）：
  直接关闭仍有未读字节的 socket 会发 RST，把刚写出的响应一起丢掉，导致
  `ServerBusy`/`TrailingData`/`LineTooLong` 随机显示成“连接被重置”。
- `f9ctl` 读到完整响应行后遇到对端 reset 不再报错（视为没有排队字节），
  已收到的响应不会再被丢弃。
- 响应回显类错误（`LengthMismatch`/`OffsetMismatch`）的文案不再只写“BLE”。

### Changed

- 已接受的连接设 `SO_SNDTIMEO`（5s）：对端不读且发送缓冲区满时，工作线程不会永久阻塞。
- 拒绝连接的收尾在 accept 线程上只等 20ms（工作线程仍是 200ms），接入不会被赖着不关的
  对端长时间卡住。
- BLE 建链把服务与两个特征的查找合成一次 `GetManagedObjects`（省两次全树往返）；
  失败候选的断开收尾改按 `min(整请求预算, now+1s)`。
- 诊断日志可改道（`f9.log_sink`）：测试既能把输出静音，也能断言日志里不出现设备地址。

### Tests

- 离线测试 87 → 127 项，并修正若干“测试名与断言不符”的假覆盖：`daemon` 的信号处理
  未恢复默认处置、跨线程计数非原子、E2E 断言过松、夹具 socket 写在 `/tmp`；`ipc` 的
  “排队字节”用例从未走到 `hasPending`；`usb` 的 `alive` 只触发 `POLLNVAL`。
- 新增覆盖：连接上限（`ServerBusy`）、回读不一致（`GearMismatch` 后重建链路）、
  超长请求行、`connectTo` 的两种“未运行”归一、`checkTrustedDir` 符号链接与权限位、
  BLE 通知订阅的成对释放（含失败出口）与 visitor 过滤、USB `POLLHUP` 与 errno 全分支、
  `ops` 的失败收尾与 `ShortData`、`protocol` 的载荷与校验和边界；本轮新增
  `RuntimeDirectory` 之外的改动均带离线用例：`serve` 自唤醒（把轮询周期放到 5s 仍 < 1s 退出）、
  BLE `Powered` 适配器选择与 `parseGatt`（含特征排在服务之前的对象树）、
  事务级通知期限、USB 打开错误归类、`daemonNotRunningMsg` 的显式 socket 路径。
  `f9d` 单元测试耗时 808ms → 8ms（夹具收尾不再等轮询周期）。

## [0.1.0] - 2026-11-25

首个 Zig 实现版本（暂无发行包，按 README 自行编译）。

### Added

- `f9ctl`：`status`、`gear`、`gear <quiet|balanced|beast|turbo|0-3>` 命令；
  `--json`、`--link usb|ble`、`--socket <路径>`、`--version` / `-V`。
- `f9d`：USB 优先、BLE 回落的串行设备 daemon；Unix socket 单行 IPC；
  SIGINT/SIGTERM/SIGHUP 优雅退出（释放设备、删除 socket）。
- 系统集成文件：systemd 单元、udev uaccess 规则、bash/zsh/fish 补全、`f9ctl(1)` 手册页；
  `zig build install --prefix` 安装布局。
- CI：格式检查、离线测试、构建、安装布局冒烟与敏感信息检查。

### Fixed

- USB 响应帧现在校验 16 位校验和，并对读命令校验 offset/长度回显；校验和损坏
  不再被静默丢弃成“超时”，只收到坏帧/截断帧时报 `BadResponse`。
- 双链路都不可用时保留 USB 侧诊断（`DeviceNotResponding` 不再被
  `BluezUnavailable` 覆盖）；BLE 权限错误与 hidraw 权限错误分别报告。
- BLE 打开时收集多个候选设备并逐个尝试；扫描收尾使用独立期限；整请求预算耗尽后
  不再发起收尾用的 D-Bus 调用。
- BLE 超时拆分为连接（`ConnectTimeout`）、服务解析（`ResolveTimeout`）与
  命令响应（`Timeout`）；空闲断链/拔线后复用链路前先探活，USB 插入后自动切回。
- 慢客户端不再饿死其他请求：连接处理线程化，设备访问仍由互斥锁串行；连接数超过
  上限立即返回 `ServerBusy`。
- IPC 拒绝请求行之后的尾随字节（`TrailingData`），不再静默丢弃多行请求。
- `f9ctl` 能识别未知选项并指名报错；补齐 daemon 全部错误名的中文文案。

## [1.0.0] - 2026-09-07

旧 Rust 实现（已冻结在 `legacy` 分支，仅作参考）。
