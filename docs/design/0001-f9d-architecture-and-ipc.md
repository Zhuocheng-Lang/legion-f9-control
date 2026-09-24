# f9d / f9ctl 架构与 IPC 协议

## 架构

- **f9d 独占设备**。会话命令（0x01/0x02）是有状态的，多点直连设备会互相破坏
  读-改-写序列；因此一切设备流量只经 f9d，且由 f9d 串行执行。f9d 以 root 运行
  （hidraw 权限），前台执行，生命周期交给 init 系统（`Restart=always` 即覆盖拔插恢复）。
- **f9ctl 是纯客户端**，不直接打开设备，用户态即可运行；命令与 IPC JSON 形状不随链路变化。

## 设备链路

- **选择规则：USB 优先**。只有 USB `DeviceNotFound` / `DeviceNotResponding` 才尝试 BLE；
  权限等其他 USB 错误原样上报，不用 BLE 掩盖。两条链路都不可用时返回 `DeviceNotFound`。
- **一次请求只用一条链路**：事务失败不重放写入、不在同请求内换链路；
  daemon 丢弃句柄（`State.drop`），下个请求惰性重开并重新选择。
- **USB**：`usb.zig`，按 VID:PID 发现 hidraw 接口，64 字节帧事务；响应不足 64 字节
  视为坏帧（不回比请求 offset/长度，见 spec §2）。同一节点还承载键盘等其他报告与设备
  主动推送的短通知，事务层丢弃非本次响应的帧（spec §2 真机 confirmed）。
  同一设备会枚举出多个 hidraw 接口，
  逐个探测（发一次无副作用的 `0x1a` 读）：只有“接口不应答”（`Timeout`）或“设备已拔”
  （`NoDevice`）才继续试下一个接口；协议层的应答错误（`Busy` / `DeviceError` / 未知状态）
  与权限、I/O 错误一律原样上报，不得吞成 `DeviceNotResponding`——否则会把
  “没权限 / I/O 失败 / 设备报错”误导为“设备不在”而错误回落 BLE。
  拔线中的 errno 自行翻译（拔线实测写回 `EPROTO`，普通拔线可能是 `ENODEV`/`ENXIO`/
  `ESHUTDOWN`）：一律归为 `NoDevice`；不用 `std.fs.File.write/read` 是因为它们对未建模
  errno 会打整段堆栈并只给 `Unexpected`（用户看到“未预期的系统错误”，且不会回落 BLE）。
- **BLE**：`ble.zig`，请求定长 20 字节、响应变长（5 字节头 + length 字节，spec §3 confirmed）；
  经系统 libsystemd 的 sd-bus 直连 BlueZ。
  设备发现以服务 UUID 为主、名称 `LEGION_F9_BT` 为辅（广告可能不含服务 UUID），
  连接后按 `ServicesResolved`、服务/特征 UUID、服务所属设备（`GattService1.Device`
  必须等于选中设备路径）与 flags（`write` / `notify`）复核：GetManagedObjects 返回的是
  全适配器的对象树，只按 UUID 全局查找会在多台同类设备同时在线时把别的设备的服务
  关联到当前候选设备上（服务限定到选中设备后，特征按所属服务路径随之不跨设备）；
  真机复核（20260924）：BlueZ 在 GetManagedObjects 中确实给出 `GattService1.Device`；
  名称不作为认证，也不硬编码地址或对象路径。写特征用 `WriteValue(type="request")`
  （write-with-response），不支持即报错，不降级为无响应写。
  普通命令发车前先装 `PropertiesChanged` 订阅，等到命令/长度/offset 都匹配的通知才算完成；
  会话命令只等 GATT 写完成（fire-and-forget）。USB 与 BLE 各自实现帧与事务，
  业务层（`ops.zig`）只依赖 `read` / `write` / `session` 三个语义操作。
- **期限**：BLE 的扫描、连接/服务解析、每次写入与通知等待都用单调时钟绝对期限；
  单个 IPC 请求（含失败时的会话收尾）不超过 30s。不自动配对，也不无限等待。
- 日志与测试向量不含真实 BLE 地址：只记录错误名，不打印设备对象路径。

## IPC（Unix socket）

- 路径：root 实例 `/run/f9d/f9d.sock`（0666，本地用户均可控制风扇）；
  非 root 开发实例 `$XDG_RUNTIME_DIR/f9d.sock`（避免 /tmp 可预测路径被占位）。
  安全前提：该目录属主本人且权限不宽于 0700——非 root f9d 启动前校验，不满足拒绝启动。
  未设置 XDG_RUNTIME_DIR 时 f9d 拒绝启动（报 NoRuntimeDir），不回退 `/tmp/f9d-<euid>.sock`：
  公共 /tmp 下可预测的 socket/lock 路径仍可被占位干扰（锁文件创建曾会截断被链接的目标文件，
  现创建时 `.truncate = false` 已消除该副作用，但占位与干扰本身仍在），
  最小安全方案就是只用可信目录。客户端先连系统级路径，失败（含陈旧 socket 拒连）再连用户级路径。
- 防双开：daemon 对 `<socket>.lock` 持排他 flock（随进程退出自动释放），
  持锁后残留 socket 必属死实例，直接删除再绑定，无 TOCTOU 窗口。
- 每连接一请求一响应，均为 `\n` 结尾的一行。
- 请求：`status` / `gear` / `gear <0-3>`。
- 响应（JSON）：成功 `{"flag":…,"rpm_raw":…,"rpm":…}` 或 `{"gear":…}`；
  失败 `{"error":"<zig 错误名>"}`。错误名即线格式，展示文案归 f9ctl。
- 超时：f9ctl 等响应上限 35s，大于 BLE 单个请求 30s 的整请求预算
  （扫描/连接/服务解析 + gear set 的 open/read/write/close/回读），
  USB 路径的最坏预算（5 次事务 × 2s + 惰性打开与多接口探测）也在其内。

## 有意不做的

- info 页（0x03/0x1d）、灯效（0x20）、raw 命令：spec 已记录但 v1 无用途。
- 并发 accept：设备会话要求串行，单线程顺序处理即可。
- 防占位饿死 / 收缩 root socket 暴露面：root 实例 socket 0666 + 单线程顺序 accept，
  任意本地用户都能连上并占住 daemon（每连接静默上限 5s，单请求处理落在 ≤35s 的
  IPC 预算内），恶意客户端循环占用会让其他用户的风扇控制一直排队饿死。
  v1 判定为低危（同机本地、只影响风扇控制）并接受该威胁：不做连接鉴权与并发，
  需要时与下条一并换 polkit / 用户组。
- 设备事务的重试/退避：失败后丢弃句柄、下个请求惰性重开即可覆盖拔插。
- polkit / 用户组鉴权：需要收紧时再换。
