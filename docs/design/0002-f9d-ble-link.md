# f9d BLE 链路重实现：委派执行单

本文件是实现任务，不是现状说明。目标是在 Linux/BlueZ 上让现有 `f9ctl status`、`f9ctl gear`、`f9ctl gear <挡位>` 经 `f9d` 使用 BLE 设备；命令与 IPC JSON 形状不变。协议事实只以 [硬件协议](../spec/0001-legion-f9-protocols.md) 为准；本文件只规定实现边界与验收办法。现有 [架构文档](0001-f9d-architecture-and-ipc.md) 中“不做 BLE”描述的是当前版本，实现时须同步修订。

## 开工边界

- 先读上述协议、`src/daemon.zig`、`src/ops.zig`、`src/protocol.zig`、`src/usb.zig`、`src/ipc.zig`、`src/main.zig`、`src/root.zig`、`build.zig`。使用 `mise exec -- zig ...`（项目锁定 Zig 0.15.1）；不要改动无关项目或原始资料。
- 不新增 CLI 命令、配置系统、后台线程、重试队列或通用传输框架。设备流量只由 f9d 串行执行；f9ctl 仍是纯 IPC 客户端。stdout 只输出结果，日志走 stderr。
- 设备选择的最小规则：先尝试已有 USB；仅当 USB `DeviceNotFound` / `DeviceNotResponding` 时尝试 BLE。USB 权限错误须原样报告，不能用 BLE 掩盖；一次事务失败后不在**同一请求**切换链路或重放写入。若两条链路都未发现设备，返回 `DeviceNotFound`；BlueZ/权限等其他失败保留可诊断错误。测试 BLE 时断开 USB。
- 规范未确认的行为不要猜。若真机发现帧形状、响应长度或会话语义不同，记录脱敏证据，**先修改 spec 并标注 confirmed/inferred**，再改代码和测试；不得为了“跑通”放松校验。

## 实现顺序

1. **纯 BLE 帧逻辑**：在 `src/ble.zig` 中实现 20 字节请求编码与响应解码，和操作系统 I/O 分开写成可直接测试的函数。请求头 `0xee`，命令、长度、offset 小端，尾部补零；读请求无 payload，`length` 表示期望读回数；写请求 `length` 为 payload 长度，最大 15。会话 open/close 分别发 `0x01`/`0x02`，offset=0、length=1、payload=同值。响应必须恰好 20 字节，校验 `0xee`、命令、声明长度（不得超过 15，且与本次预期一致）和 offset；复制出前 `length` 字节。**不可把 response[7] 当状态码**。保留现有 `protocol.zig` 中已验证的状态/挡位解码和不透明设置块逻辑，不复用其 USB 帧编码器。
2. **BlueZ 连接和事务**：仅在 `src/ble.zig` 做 Linux BlueZ D-Bus 客户端，使用系统 `libsystemd` 的 sd-bus C ABI（`@cImport`；在 `build.zig` 链接 libc/systemd），不引入 Zig 第三方包或解析 `bluetoothctl` 输出。连接 system bus；枚举 BlueZ 已知对象并在必要时进行有上限的 LE 扫描。按服务 UUID 优先、设备名称 `LEGION_F9_BT` 辅助筛选候选设备；**名称不能作为最终认证**，连接后等待 `ServicesResolved` 并检查目标服务及其写/通知特征的 UUID、所属服务和必要 flags。广告可能不含服务 UUID，所以只按 UUID 过滤扫描会漏掉名称候选；不要用固定地址或对象路径。无匹配设备、BlueZ 不可用、权限不足分别可诊断。既不自动配对，也不扫描/连接无限等待。
3. **通知事务**：在发送首帧前对通知特征 `StartNotify`，订阅该特征的 `org.freedesktop.DBus.Properties.PropertiesChanged` 的 `Value`；仅采纳来自目标特征的通知。向写特征 `WriteValue` 时明确指定 `type="request"`（write-with-response）；不支持则报错，绝不退化为无响应写。普通 `read/write` 必须在有界期限内收到并验证同一命令、长度及 offset 的通知，才能认为设备命令完成；已成功写入 GATT **不等于**设备命令响应。会话 `0x01/0x02` 等待 GATT 写完成即可，**不等待通知**。其他命令的旧通知不可当本次响应；坏帧立即失败。事务失败时先让业务层尽力收尾已打开的会话，再由 daemon 丢弃连接状态；下次 IPC 请求重新发现/连接。扫描只停止自己开启的会话，释放自身通知订阅与其他资源。
4. **接入业务层**：让 `ops` 只依赖三个设备语义操作：`read(command, offset, len)`、`write(command, offset, payload)`、`session(open)`。由 USB/BLE 各自实现帧与事务，不造 vtable/分配式接口。`status` 读 `0x1a` offset 0 长度 3；`gearGet` 读 `0x05` offset 0 长度 15；`gearSet` 维持 open → 读 → 只改设置块 byte[13] → 写 `0x06` → close → 回读确认；open 已发出后失败也 best-effort close，close 失败不得假报成功。`daemon.State` 用一个带 tag 的设备状态惰性持有当前链路，串行处理 IPC、失败后丢弃该句柄；`root.zig` 导出 BLE 模块。勿复制第二套挡位算法。
5. **错误与期限**：为扫描、连接/服务解析、每次 GATT 写及通知等待设置**单调时钟的绝对期限**，BLE 单个 IPC 请求（含失败时会话收尾）总计不超过 30 秒；`ipc.io_timeout_ms` 调整为大于此值（例如 35 秒），并同步修订架构文档中现有 15 秒预算。sd-bus 调用不能依赖默认无限等待。必要的新错误名同时加到 `main.zig` 的 IPC 错误解析/用户提示，不在 stdout 打印诊断；日志/测试向量不含实际 BLE 地址。状态/会话中途断线不得自动重试写入。

## 最小验收

- **纯函数测试（无蓝牙硬件）**：`ee 05 0f 0000 | 00*15` 精确编码；会话标记正确；短包/超长/头错/命令错/长度错/offset 错均拒绝；有效响应的 `response[7]` 可为 `0xfe`/`0xff` 而不能触发 USB 错误；15 字节上限；`flag=02,rpm_raw=0x1ff4 → rpm=2045`；只改 gear byte[13]。测试应覆盖普通命令需要匹配通知、会话命令不等待通知（可通过小型 fake 将 I/O 与帧函数隔离）。
- **回归（无硬件）**：现有 USB、IPC、业务操作测试全部通过；补一项设备选择测试，证明 USB 不可用才找 BLE、权限错误不兜底，且设置事务失败不重放写入。测试不要连接本机 system bus。
- **真机验收（须具备设备和 BlueZ）**：拔 USB，先运行 f9d，再运行 `f9ctl status`、`f9ctl gear`、`f9ctl gear quiet` 并回读；断开/重连 BLE 后再次请求可恢复；设备不在附近、BlueZ 未启动、无法写特征、无通知分别能在限定时间内结束并给出明确错误。改变挡位可能影响实际风扇，只有操作者确认安全才执行写入验收；若无真机，明确标记未验收，不声称完成。

离线检查（从项目根目录运行）：

```sh
mise exec -- zig fmt --check src/ble.zig src/ops.zig src/usb.zig src/daemon.zig src/root.zig src/main.zig build.zig
mise exec -- zig build test
mise exec -- zig build
```

参照 BlueZ 官方接口文档：[Adapter1](https://github.com/bluez/bluez/blob/master/doc/org.bluez.Adapter.rst)、[Device1](https://github.com/bluez/bluez/blob/master/doc/org.bluez.Device.rst)、[GattService1](https://github.com/bluez/bluez/blob/master/doc/org.bluez.GattService.rst)、[GattCharacteristic1](https://github.com/bluez/bluez/blob/master/doc/org.bluez.GattCharacteristic.rst)。这些链接用于核对 D-Bus 方法、flags 和 `Value` 通知，协议字节仍以本项目 spec 为准。

## 验收修正记录（真机 confirmed）

- **响应帧为变长**：真机通知总长 = 5 字节头 + `length` 字节（读 `0x1a` 长度 3 → 8 字节；
  读 `0x05` 长度 15 → 20 字节）。本文实现步骤 1 中“响应必须恰好 20 字节”按 spec §3
  修正为“总长恰为 5+length”，填零填充帧一律拒绝；校验未因此放宽。
- **BlueZ 属性类型**：`GattCharacteristic1.Service` 是对象路径（`o`），按字符串（`s`）
  读取会导致特征查找全部落空（`GattUnsupported`）；实现已按 `o` 解析。
- **`sd_bus_message_open_container('e', ...)` 的 contents 不带花括号**（`"sv"`，不是 `"{sv}"`），
  否则 `WriteValue` 的选项字典构造返回 `EINVAL`。
- **错误映射实测修正**（均为真机 confirmed）：适配器关闭时 `StartDiscovery` 与设备断电时
  `Connect` 都返回 `org.bluez.Error.Failed`，在各自调用点分别窄化为 `BluezUnavailable` /
  `NotConnected`；`Connect` 的 `InProgress`（他方正在连接）不再视为失败，交给
  `ServicesResolved` 等待。
- **30s 整请求预算从 `ble.open()` 入口起算**（含扫描/连接/服务解析），复用链路才由
  `beginRequest` 重置；预算过期即快速超时，不续期。
