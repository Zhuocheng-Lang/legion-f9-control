# f9d / f9ctl 架构与 IPC 协议

## 架构

- **f9d 独占设备**。会话命令（0x01/0x02）是有状态的，多点直连设备会互相破坏
  读-改-写序列；因此一切设备流量只经 f9d，且设备访问由一把互斥锁串行执行。f9d 以 root
  运行（hidraw 权限）或经 udev `uaccess` 以登录用户运行，前台执行，生命周期交给 init
  系统（systemd 单元的 `Restart=always` 覆盖异常退出）。
- **f9ctl 是纯客户端**，不直接打开设备，用户态即可运行；命令与 IPC JSON 形状不随链路变化。
- **连接并发、设备串行**：每个客户端连接由独立线程处理（读请求、发响应），设备访问在
  `dev_mutex` 下串行。慢客户端只占自己的线程，不会让其他用户的请求排队饿死；同时在用
  连接数有上限（8），超过时立即回 `{"error":"ServerBusy"}` 而不是无限排队。
  已接受的连接都设 `SO_SNDTIMEO`（5s）：对端把接收窗口压到极小又不读时，写响应不会让
  工作线程永久阻塞，连接会以写失败关闭。
- **信号处理**：`SIGINT`/`SIGTERM`/`SIGHUP` 只置位停止标志，并往**自唤醒管道**
  写 1 字节（`write` 是 async-signal-safe）；主循环 `poll` 同时等监听 socket 与唤醒管道，
  看到停止标志后立即停止 accept、等待在用连接收尾（上限 3s）、关闭设备句柄、删除 socket
  再退出。200ms 只是一个兜底轮询周期，不是停机延迟：实测 SIGTERM → 进程退出 1ms。
  没有自唤醒时，最坏要等满一个轮询周期才看见标志（此前 E2E 夹具也因此每次收尾多等 200ms）。若 3s 内仍有连接在处理，则**不**释放设备状态就直接退出（由进程结束
  回收，避免在别的线程还持有 sd_bus/文件句柄时关闭它）。写已断开的客户端只会得到
  `error.BrokenPipe`（Zig 启动代码忽略 SIGPIPE），不会杀掉 daemon。

## 设备链路

- **选择规则：USB 优先**。只有 USB `DeviceNotFound` / `DeviceNotResponding` 才尝试 BLE；
  权限等其他 USB 错误原样上报，不用 BLE 掩盖。
- **两条链路都不可用时**：BLE 侧的 `DeviceNotFound`/`BluezUnavailable` 只说明 BLE 这条路
  走不通，最终上报 USB 侧错误（例如保留“设备存在但协议接口无应答”）；BLE 侧其余错误
  （权限、连接、GATT）更有诊断价值，原样上报。BLE 被抑制的错误会记一行日志。
- **一次请求只用一条链路**：事务失败不重放写入、不在同请求内换链路；daemon 丢弃句柄
  （`State.drop`），下个请求惰性重开并重新选择。
- **复用前检查**（`State.ensure` + `shouldReplaceLink`）：
    - 显式 `--link usb|ble`：链路不符就换，且只打开指定链路（不回落）；
    - 自动选择：句柄已挂断（USB 零超时 `poll` 看到 HUP/ERR、BLE 的 `Connected` 为假）
      就先丢弃重开，用户请求不必先在死句柄上失败一次；
    - 自动选择：BLE 句柄遇到已接入的 USB（读 sysfs 的 hidraw 节点，不发帧）就切回 USB，
      遵守“USB 优先”而不是一直停在 BLE。
    - BLE 空闲断链/BlueZ 重启因此不会让下一次用户命令直接报错。
- **USB**：`usb.zig`，按 VID:PID 发现 hidraw 接口，64 字节帧事务；响应不足 64 字节
  视为坏帧（64 字节定长 + 校验和 + report ID + 命令回显，见 spec §2）。同一节点还承载
  键盘等其他报告与设备主动推送的短通知，事务层丢弃非本次响应的帧；读命令还要求
  offset/长度回显一致。只收到协议形状的坏帧/截断帧时报 `BadResponse`，与“设备没回”的
  `Timeout` 区分。校验和失配单独报 `BadChecksum`，不静默丢弃。
  同一设备会枚举出多个 hidraw 接口，逐个探测（发一次无副作用的 `0x1a` 读）：只有
  “接口不应答”（`Timeout`）、只收到坏帧（`BadResponse`）或“设备已拔”（`NoDevice`）
  才继续试下一个接口；协议层的应答错误（`Busy` / `DeviceError` / 未知状态）与权限、
  I/O 错误一律原样上报，不得吞成 `DeviceNotResponding`——否则会把“没权限 / I/O 失败 /
  设备报错”误导为“设备不在”而错误回落 BLE。
  拔线中的 errno 自行翻译（拔线实测写回 `EPROTO`，普通拔线可能是 `ENODEV`/`ENXIO`/
  `ESHUTDOWN`）：一律归为 `NoDevice`；不用 `std.fs.File.write/read` 是因为它们对未建模
  errno 会打整段堆栈并只给 `Unexpected`。权限错误归为 `UsbAccessDenied`，与 BlueZ 的
  `BleAccessDenied` 分开。
- **BLE**：`ble.zig`，请求定长 20 字节、响应变长（5 字节头 + length 字节，spec §3 confirmed）；
  经系统 libsystemd 的 sd-bus 直连 BlueZ。设备发现以服务 UUID 为主、名称 `LEGION_F9_BT`
  为辅；打开时收集至多 4 个候选设备并**逐个尝试**（Connect → ServicesResolved → 服务/特征
  → StartNotify），首个候选失败（缓存里的旧设备、同名干扰设备、GATT 不匹配）不再导致整个
  打开失败；我们自己连上的候选失败时尽力断开（独立 1s 期限），不踢他方连接。服务/特征必须
  限定在选中设备子树内（`GattService1.Device` 等于选中设备路径，特征再按所属服务路径
  限定）：GetManagedObjects 返回全适配器对象树，只按 UUID 全局查找会把别的设备的服务
  关联到当前候选设备上。服务与两个特征由**一次** GetManagedObjects 取出（先扫服务、再
  rewind 扫特征），不假设对象树里特征排在所属服务之后。
  适配器优先选 `Powered=true` 的那一个（多适配器主机上取首个会锁到没启用的适配器）；
  没有已启用的适配器时按“蓝牙未启用”报 `BluezUnavailable`。
  `Connect` 返回 `InProgress`/`AlreadyConnected` 说明连接属于他方：不算失败，但**不登记成
  我们连上的**，失败收尾时不会 `Disconnect` 掉别人的连接。写特征用 `WriteValue(type="request")`（write-with-response），
  不支持即报错，不降级为无响应写。普通命令发车前先装 `PropertiesChanged` 订阅，等到
  命令/长度/offset 都匹配的通知才算完成；会话命令只等 GATT 写完成（fire-and-forget）。
  通知等待的期限在事务开始时一次算定，事务内不按帧续期；候选失败的断开收尾用
  `min(整请求预算, now+1s)`，多个候选连续失败不会把总耗时推过预算。
  细节见 [BLE 链路设计](0002-f9d-ble-link.md)。
- **期限**：BLE 的扫描、连接/服务解析、每次写入与通知等待都用单调时钟绝对期限；
  单个 IPC 请求（含失败时的会话收尾）不超过 30s。预算耗尽后 `read`/`write`/`session`
  直接返回 `Timeout`，不再发起“只剩 1us”的收尾 D-Bus 调用。扫描收尾用独立 1s 期限，
  即使扫描本身已经耗到期限也能真正 `StopDiscovery`。
- 错误语义拆分：`ConnectTimeout`（连接没建立）、`ResolveTimeout`（已连接但服务解析超时）、
  `Timeout`（命令响应/预算超时），避免都把 BLE 阶段问题显示成“等待响应超时”。
- 日志与测试向量不含真实 BLE 地址：只记录错误名，不打印设备对象路径。

## IPC（Unix socket）

- 路径：root 实例 `/run/f9d/f9d.sock`（0666，本地用户均可控制风扇）；
  非 root 开发实例 `$XDG_RUNTIME_DIR/f9d.sock`（避免 /tmp 可预测路径被占位）。
  安全前提：该目录属主本人且权限不宽于 0700——非 root f9d 启动前校验，不满足拒绝启动。
  未设置 XDG_RUNTIME_DIR 时 f9d 拒绝启动（报 NoRuntimeDir），不回退 `/tmp/f9d-<euid>.sock`：
  公共 /tmp 下可预测的 socket/lock 路径仍可被占位干扰（锁文件创建曾会截断被链接的目标文件，
  现创建时 `.truncate = false` 已消除该副作用，但占位与干扰本身仍在），
  最小安全方案就是只用可信目录。客户端先连系统级路径，失败（含陈旧 socket 拒连）再连用户级路径。
  f9ctl 可用 `--socket <路径>` 直连指定 socket（开发/测试用）。
- 防双开：daemon 对 `<socket>.lock` 持排他 flock（随进程退出自动释放），
  持锁后残留 socket 必属死实例，直接删除再绑定，无 TOCTOU 窗口。
- 每连接一请求一响应，均为 `\n` 结尾的一行。**请求行之后不得再有字节**：同一次读入里
  换行后还有数据，或内核已排队后续字节，都回 `{"error":"TrailingData"}` 并关闭连接，
  不做“读一行丢其余”。请求行写满缓冲区仍无换行报 `LineTooLong`。
- **关闭时序**：写完响应先 `shutdown(write)`、再把对端剩余输入读空（工作线程上限
  200ms，拒绝路径——跑在 accept 线程上——上限 20ms）后才 `close`。直接关闭一个还有未读字节的 socket 会向对端发 RST，内核会连同刚写出的响应
  一起丢掉——`ServerBusy`/`TrailingData`/`LineTooLong` 这些拒绝类响应会随机退化成
  “连接被重置”。期限用尽就照常关闭，最坏情况退化为一次性 close，不会挂住。
  客户端侧对应地：拿到完整一行后，`poll` 看到对端 reset 视为“没有排队字节”，
  不把已收到的响应变成失败。
- 请求语法：`status` / `gear` / `gear <0-3>`，可带末尾独立的链路词 `usb`/`ble`
  （如 `status usb`、`gear 2 ble`），只走指定链路、不回落。其余形式的空白与多余参数一律
  `BadRequest`。
- 响应（JSON）：成功 `{"flag":…,"rpm_raw":…,"rpm":…}` 或 `{"gear":…}`；
  失败 `{"error":"<zig 错误名>"}`。错误名即线格式（`ipc.wire_errors` 是唯一清单，
  `f9ctl` 的测试逐项确认都有专用文案），展示文案归 f9ctl。
- 超时：f9ctl 等响应上限 35s，大于 BLE 单个请求 30s 的整请求预算
  （扫描/连接/服务解析 + gear set 的 open/read/write/close/回读），
  USB 路径的最坏预算（5 次事务 × 2s + 惰性打开与多接口探测）也在其内。
  连接的静默读上限 5s。
- 连接上限 8（`max_connections`）。超出时 daemon 立即回 `ServerBusy` 并关闭连接
  （走上面的关闭时序，响应不会丢）：恶意客户端持续占位最终只会看到自己的连接被拒，
  正常客户端不会无限排队。

## 部署与打包

- `zig build install --prefix /usr` 安装程序、`f9ctl.1` 手册页、bash/zsh/fish 补全、
  systemd 单元与 udev 规则（见 README“安装”）。
- 包构建时的 systemd 依赖定位：本机构建用 `linkSystemLibrary("libsystemd")` 并要求
  pkg-config 解析 `libsystemd.pc`（避免本机 `systemd` 空壳 .pc 吞掉 `-lsystemd`）；
  不用 `use_pkg_config = .yes`，它在 pkg-config 缺席时会按原名回退成链接不存在的
  `-llibsystemd`，因此缺 pkg-config 或该 `.pc` 时构建明确失败。交叉编译改用纯
  `-lsystemd`（宿主 pkg-config 与目标 sysroot 不匹配），该分支尚无构建验证。
- Zig 0.17 移除 `@cImport` 后不再需要 C 头文件：sd-bus 的 28 个函数与 3 个不透明类型
  在 `src/ble.zig` 里以 `extern` 直接声明（签名逐条对应 `systemd/sd-bus.h`），
  构建阶段只做链接，不跑 translate-c，也不引入外部包。
- CI（`.github/workflows/ci.yml`）执行格式检查、离线测试、构建、安装布局冒烟与
  `tools/check-sensitive.sh` 敏感信息检查；版本号在 `build.zig` 与 `build.zig.zon`
  同步维护，变更记录见 `CHANGELOG.md`。

## 有意不做的

- info 页（0x03/0x1d）、灯效（0x20）、raw 命令：页长度与字段布局未确认，v1 不猜测语义，
  也不新增无用途的命令（见 spec §4）。
- 配置文件、温控循环、模拟器、Windows/F9 Lite 支持：与 v1 目标无关，属于旧实现的
  功能面，需要单独设计与真机验收。
- 设备事务的重试/退避：失败后丢弃句柄、下个请求惰性重开即可覆盖拔插；重放写入会违反
  “同请求不重放”的约定。
- polkit / 用户组鉴权：root 实例的 socket 是 0666（风扇控制低敏），需要收紧时改用户组
  或 polkit；不做连接鉴权。
- 残留威胁面：root 实例仍允许任意本地用户连接并读取/设置风扇；连接上限与独立线程只
  缓解占位饿死，不能阻止持续恶意占用。共享主机应改用用户组/polkit 方案。
