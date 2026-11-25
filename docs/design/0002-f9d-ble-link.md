# f9d BLE 链路设计

本文描述 `ble.zig` 在 Linux/BlueZ 上的**现状设计**（命令与 IPC JSON 形状不随链路变化）。
协议事实只以 [硬件协议](../spec/0001-legion-f9-protocols.md) 为准；真机验收记录与修正见文末。
实现不引入 Zig 第三方包，也不解析 `bluetoothctl` 输出。

## 范围与边界

- 设备流量只由 f9d 串行执行；f9ctl 仍是纯 IPC 客户端。BLE 只是 USB 的回落链路：
  仅当 USB `DeviceNotFound`/`DeviceNotResponding` 时才尝试；USB 权限错误原样上报。
- 不自动配对、不硬编码地址或对象路径、不扫描/连接无限等待。
- 不新增 CLI 命令、配置系统、后台线程或通用传输框架；业务层只依赖
  `read(command, offset, len)`、`write(command, offset, payload)`、`session(open)`。
- 帧形状、响应长度或会话语义若与真机不符，先更新 spec 并标注 confirmed/inferred，
  再改实现与测试；不得为了“跑通”放松校验。

## 帧层（纯函数）

- 请求定长 20 字节：`0xee`、命令、长度、offset 小端、payload（最多 15，尾部补零）。
  读请求无 payload、`length` 为期望读回数；写请求 `length` 为 payload 长度；
  会话 open/close 发 `0x01`/`0x02`，offset=0、length=1、payload 同值。
- 响应变长：总长必须恰为 `5 + length`（≤20），校验 `0xee`、命令、声明长度（≤15 且与本次
  预期一致）与 offset，再拷出前 `length` 字节。填零填充帧一律拒绝。
- **不能把 response[7] 当状态码**：它在有效响应里是数据（可为 0xfe/0xff）。
- 会话命令不等通知；其他命令必须等到命令/长度/offset 都匹配的通知。旧通知丢弃继续等，
  结构性坏帧（头/长度非法）立即失败。

## 设备发现与候选

- 服务 UUID 为主、名称 `LEGION_F9_BT` 为辅（广告可能不含服务 UUID，只按 UUID 过滤会漏）。
  名称只用于候选筛选，不作为认证。
- 遍历 `GetManagedObjects` 收集**全部**候选（至多 4 个，固定上限不分配），而不是命中第一个
  就停止；已知对象里找不到才开一次有上限的 LE 扫描。他方已在扫描时 `StartDiscovery` 返回
  “已在扫描”，只随其扫描结果轮询，退出时也不停止别人的会话。
- 扫描由我们开启时，收尾用**独立的 1s 期限**（且不超过整请求预算）：扫描本身耗到期限后
  旧期限已过期，沿用它会让 `StopDiscovery` 只剩 1us 必然失败、适配器留在扫描状态。

## 连接与 GATT 复核

- 适配器优先选 `Powered=true` 的那个：多适配器主机上（内置 `hci0` 关闭、外接 `hci1` 开启）
  取首个会锁到没启用的适配器。没有已启用的适配器时保留首个候选，最终按“蓝牙未启用”
  报 `BluezUnavailable`，不伪装成“设备不在”。
- 逐个候选执行：读 `Connected`（为真就不重复 Connect）→ `Connect` → 等
  `ServicesResolved` → 找服务 → 找写/通知特征 → `StartNotify`。`Connect` 的
  `InProgress`（他方正在连接）与 `AlreadyConnected`（读属性后、Connect 前他方已连上，
  见 BlueZ Device1 文档）都不算失败，交给 `ServicesResolved` 等待；但**不登记成“我们连上
  的”**，否则后面任一步失败时 `Disconnect` 收尾会把他方的连接踢掉。
- 某个候选失败时继续下一个；最终上报诊断价值最高的错误
  （权限/BlueZ 不可用 > GATT 不匹配 > 连接不上 > 等待超时 > 其他）。我们自己发起的连接
  在失败时尽力断开（`min(整请求预算, now+1s)`），避免踢掉他方的连接；多个候选连续
  失败时，收尾也不会把总耗时推过 30s 预算。
- 服务/特征必须限定在选中设备的子树内：`GattService1.Device` 必须等于选中设备路径，
  特征再按所属服务路径限定。GetManagedObjects 返回全适配器对象树，只按 UUID 全局查找会在
  多台同类设备同时在线时把别的设备的服务关联到当前候选上。
- 服务与两个特征由**一次** GetManagedObjects 取出（`parseGatt`：先扫服务，再 `rewind`
  扫特征），比三次全树往返省两次 D-Bus 序列化；分隔两趟而不是单遍扫描，是因为对象顺序
  由 BlueZ 决定，不保证特征排在所属服务之后。每趟开始都 `rewind`（命中即提前返回会
  把游标留在容器里）。
- `GattCharacteristic1.Service` 是对象路径（`o`），按字符串（`s`）读取会让特征查找
  全部落空（`GattUnsupported`）。
- 写特征用 `WriteValue(value, {type:"request"})`（write-with-response）；不支持就报错，
  绝不退化为无响应写。`sd_bus_message_open_container('e', ...)` 的 contents 不带花括号
  （`"sv"`，不是 `"{sv}"`），否则构造返回 EINVAL。

## 通知事务

- 普通命令：先对通知特征装 `PropertiesChanged` 订阅（限定 sender/path/interface/arg0），
  再写请求，然后等到命令/长度/offset 都匹配、来自目标特征的 `Value(ay)` 通知才算完成。
  已成功写入 GATT **不等于**设备命令响应。等待通知的期限在事务开始时算定
  （`beginNotify` 里写进 `notify_deadline_ms`），事务内不按帧续期：持续收到不匹配的旧通知
  时，5s 单操作上限不会被无限续期，不必只靠 30s 整请求预算兜底。
- 会话命令只等 GATT 写完成，不等通知。
- 通知最多 20 字节，超长按结构性坏帧立即失败；空 `ay` 或非 `ay` 的 `Value` 不置位，
  继续等真响应（否则会把 0 字节帧判成坏帧并让整个事务失败）。
- 事务失败时业务层尽力收尾已打开的会话，daemon 丢弃连接状态；下次请求重新发现/连接。

## 期限、预算与错误

- 扫描、连接/服务解析、每次写入与通知等待都用单调时钟绝对期限；单个 IPC 请求
  （含失败时会话收尾）总计不超过 30s。scan 12s、单次写/通知 5s、扫描收尾 1s、
  复用前探活 1s。
- 整请求预算从 `ble.open()` 入口起算（含扫描/连接/服务解析）；复用链路才由
  `beginRequest` 重置。预算耗尽后 `read`/`write`/`session` 直接返回 `Timeout`，
  不再发起收尾 D-Bus 调用（收尾也不会靠 1us 超时“走个形式”）。
- 错误语义：`ConnectTimeout`（连接在期限内没建立）、`ResolveTimeout`（已连接但
  ServicesResolved 超时）、`Timeout`（命令响应/预算超时）；加上 `BluezUnavailable`、
  `DeviceNotFound`、`GattUnsupported`、`BleAccessDenied`、`NotConnected`、
  `InProgress`、`DbusError` 与帧层错误，均可在限定时间内给出、互相可区分。
- 适配器关闭时 `StartDiscovery` 与设备断电时 `Connect` 都返回 `org.bluez.Error.Failed`，
  在各自调用点分别窄化为 `BluezUnavailable` / `NotConnected`（真机 confirmed）。
- 复用链路前探活：`Properties.Get Connected` 为假（或查询失败）就丢弃句柄重新建链，
  用户的当次请求不会先在死句柄上失败一次。

## 测试策略

- 纯帧函数、事务状态机（fake GATT：通知为 0 字节/超长/旧命令/旧 offset）、候选收集、
  错误排序、预算短路都有离线单元测试。
- sd-bus 编解码（`parseProps`、`walkObjects`、`readChangedValue`、variant 各类型、
  错误名映射）用**离线 bus**（`sd_bus_new` + socketpair + `sd_bus_start`）构造或解析真实
  消息容器：不连接 system bus、不需要 BlueZ 或蓝牙硬件。消息写完后必须 `sd_bus_message_seal`
  才能从头读。
- 真机验收（须具备设备和 BlueZ）：拔 USB 后 `f9ctl status`、`f9ctl gear`、
  `f9ctl gear quiet` 并回读；断开/重连 BLE 后再次请求可恢复；设备不在附近、BlueZ 未启动、
  无法写特征、无通知分别能在限定时间内结束并给出明确错误。改变挡位可能影响实际风扇，
  只有操作者确认安全才执行写入验收；无真机时明确标记未验收。

## 参考（BlueZ 上游文档）

- [Adapter1](https://github.com/bluez/bluez/blob/master/doc/org.bluez.Adapter.rst)：`StartDiscovery` 的
  `NotReady`/`Failed`/`InProgress`、`StopDiscovery`。
- [Device1](https://github.com/bluez/bluez/blob/master/doc/org.bluez.Device.rst)：`Connect` 的
  `NotReady`/`Failed`/`InProgress`/`AlreadyConnected`、`ServicesResolved`、`Disconnect`。
- [GattService1](https://github.com/bluez/bluez/blob/master/doc/org.bluez.GattService.rst)：`Device` 归属。
- [GattCharacteristic1](https://github.com/bluez/bluez/blob/master/doc/org.bluez.GattCharacteristic.rst)：
  `WriteValue` 的 `type` 取值（`request` = write with response）、`Flags`、`Value` 通知。

这些链接用于核对 D-Bus 方法、flags 与 `Value` 通知；协议字节仍以本项目 spec 为准。

## 真机验收记录与修正（2026-09-24，confirmed）

已通过：BLE 首次请求 34ms、链路复用约 15ms；`quiet`→回读、`turbo`→回读一致；
服务/特征归属（目标服务带 `GattService1.Device` 且等于选中设备）；重启 f9d 后残留
socket/lock 正常接管；30×status + 10×gear + 20×json 全部成功且链路只打开一次；
连接断开时旧句柄快速失败、12s 内给出有界错误；开机后首次请求 31ms 成功、挡位跨断电保持。

修正记录（均已落实到实现与 spec）：

- **响应帧为变长**：总长 = 5 字节头 + `length` 字节（读 `0x1a` 长度 3 → 8 字节；
  读 `0x05` 长度 15 → 20 字节）。早期“响应必须恰好 20 字节”的写法已按 spec §3 修正为
  “总长恰为 5+length”，填零填充帧一律拒绝；校验未放宽。
- **BlueZ 属性类型**：`GattCharacteristic1.Service` 是对象路径（`o`）。
- **容器 contents 不带花括号**（`"sv"`），否则 `WriteValue` 的选项字典构造返回 EINVAL。
- **错误映射**：`StartDiscovery` 与 `Connect` 的 `org.bluez.Error.Failed` 分别窄化为
  `BluezUnavailable` / `NotConnected`；`Connect` 的 `InProgress` 交给
  `ServicesResolved` 等待。
- **30s 整请求预算从 `ble.open()` 入口起算**（含扫描/连接/服务解析），复用链路才由
  `beginRequest` 重置；预算过期即快速超时，不续期。

仍未真机验收：两台同类 BLE 设备同时在线时只采纳选中设备（仅有离线单元测试）；
BlueZ 未启动、无通知、写特征不支持 write-with-response、真机响应帧长异常；
多候选回退（缓存旧设备 + 真设备）的实际表现。
