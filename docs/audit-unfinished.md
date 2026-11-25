# 审计项处置记录

本文档记录 `docs/audit-unfinished.md`（初版审计）中每一项的处置结果与证据。
初版只列“尚未做好”的部分，不提供方案；本版改为逐项状态，未完成项如实标注。

状态：**已修复**（代码/文档已改，离线测试覆盖）、**已决定**（有意不做/范围外，已写入
spec/design/ROADMAP）、**待真机**（需要设备才能验收，已列入 ROADMAP）。

验证命令（仓库根目录）：

```sh
mise exec -- zig fmt --check src/*.zig build.zig
mise exec -- zig build test        # 3 个测试 unit：库 + f9ctl + f9d，共 127 项
mise exec -- zig build
mise exec -- zig build install --prefix /tmp/f9prefix
./tools/check-sensitive.sh
```

---

## 一、实现层面的逻辑缺陷与边界漏洞

### 1. 双链路都未发现设备时的错误语义 —— 已修复

- `daemon.combineLinkErrors`：BLE 侧的 `DeviceNotFound`/`BluezUnavailable` 不覆盖 USB
  诊断（保留 `DeviceNotResponding` 等），其余 BLE 错误（权限/连接/GATT）优先上报；
  被抑制的错误记一行日志。
- 证据：`daemon.zig` 的“设备选择”测试（USB 未找到 + BLE 无 BlueZ → `DeviceNotFound`；
  USB 无应答 + BLE 无设备 → `DeviceNotResponding`；USB 未找到 + BLE 权限 → `BleAccessDenied`；
  USB 权限错误不尝试 BLE）。
- 文档：design/0001“设备链路”。

### 2. BLE 多候选/同名设备的回退遍历 —— 已修复（待真机）

- `FindDevices` 收集至多 4 个候选，`Device.open` 逐个 `connectCandidate`
  （Connect → ServicesResolved → 服务/特征 → StartNotify），失败继续下一个并按诊断价值
  选最终错误；自己连上的失败候选尽力断开（1s 独立期限）。
- 证据：候选表去重/上限/顺序、`walkObjects` 真实 `a{oa{sa{sv}}}` 消息、错误排序的离线测试。
- 待真机：缓存旧设备 + 真设备同时存在时的实际回退（ROADMAP）。
- 文档：design/0002“设备发现与候选”。

### 3. BLE 超出 30s 整请求预算 —— 已修复

- `stopDiscoveryBestEffort` 用独立 1s 期限（且不超过预算），扫描耗到期限也能真正停止；
  `Device.read/write/session` 先用 `ensureBudget` 短路：预算耗尽直接 `Timeout`，
  `ops.gearSet` 的 errdefer 收尾不再发起“只剩 1us”的 D-Bus 调用。
- 打开阶段的总期限取 `min(预算, now+12s)`。
- 证据：`ble.zig`“预算耗尽：read/write/session 直接 Timeout，不再发起 D-Bus 调用”。

### 4. 复用链路的静默断连与 USB 优先切回 —— 已修复（待真机）

- `State.ensure` 复用前先决策（`shouldReplaceLink`）：显式链路不符就换；自动模式
  句柄挂断（USB `poll` 零超时 / BLE `Properties.Get Connected`）就重开；BLE 句柄遇到
  已接入的 USB（读 sysfs，不发帧）就切回。
- 证据：`shouldReplaceLink` 全分支测试、`State` 复用/强制链路测试、`usb.presentAt` 与
  `usb.alive` 测试。
- 待真机：拔插/空闲断链后的首次请求不再先失败一次（ROADMAP）。
- 文档：design/0001“设备链路”。

### 5. USB 帧校验不对称、坏帧诊断丢失 —— 已修复

- `protocol.decodeResponse` 现在校验 `[1:2]` 16 位校验和（`BadChecksum`），读命令还校验
  offset/长度回显（不符按旧帧丢弃）。`usb.exchange` 记录是否见过 report ID 4 形状的帧：
  期限用尽时只收到坏帧/截断帧报 `BadResponse`，完全没收到协议帧才是 `Timeout`。
- spec §2 同步：校验和 confirmed 并由主机强制；读回显 inferred（真机 `0x1a` 向量）；
  写/会话回显 unknown，不据此判错；并写明 `BadResponse` 的判定。
- 证据：protocol 的校验和/回显测试；usb 的“截断帧→BadResponse”“损坏帧→BadChecksum”
  “短通知→Timeout”“同命令旧帧被丢弃后接受匹配帧”测试。

### 6. 错误码映射与文案失真 —— 已修复

- `ipc.wire_errors` 成为 daemon 错误名的唯一清单（补 `NoSpaceLeft`、`DeviceBusy`、
  `FileNotFound`、`WouldBlock`、`InProgress`、`ServerBusy`、`TrailingData` 等）。
  `f9ctl` 测试逐项确认每个名字都有专用文案，不再退化成“f9d 返回未知错误”。
- 权限错误拆分：`UsbAccessDenied`（hidraw）与 `BleAccessDenied`（BlueZ），文案可区分。
- 超时拆分：`ConnectTimeout`、`ResolveTimeout`、`Timeout`（文案见 troubleshooting §6）。
- 证据：main.zig 的两个 wiring 测试 + 权限/超时措辞抽查；ble 的 `mapCallError` 表驱动测试。
- 文档：troubleshooting §5/§6。

### 7. IPC 信号处理、优雅退出、客户端滥用防护 —— 已修复

- `SIGINT/SIGTERM/SIGHUP` 置位停止标志；主循环 poll 到后停止 accept、`waitIdle`（3s）
  收尾、关闭设备、删除 socket。临时验证：单元测试覆盖 `serve` 停止路径与 socket 清理
  （`Harness.deinit`）；真实信号可用 `kill -TERM` 手测。
- 慢客户端防护：连接线程化 + 设备互斥锁 + 在用连接上限 8；超出立即 `ServerBusy`。
  证据：E2E 真的占满 8 个连接后再连一次，断言立即回 `{"error":"ServerBusy"}`
  （< 1s，不排队）；另有“空闲连接不阻塞其他客户端”的 E2E。
- 尾随数据：`readLine` 同时检查同一批数据和内核排队字节，命中报 `TrailingData`；
  证据：两条独立的 readLine 测试（同批判定、`hasPending` 排队判定各一条——用恰好
  容纳一行的缓冲区才能走到后者）+ E2E“尾随数据被拒绝”；`LineTooLong` 另有单测与 E2E。
- 关闭时序：拒绝类响应不再被 RST 丢弃（daemon 半关闭 + 读空剩余输入，客户端容忍 reset）；
  见下文“本轮修复的缺陷”。
- 文档：design/0001“架构”“IPC”。

### 8. CLI 参数解析 —— 已修复

- `f9ctl --version/-V`、`--socket <路径>`、`--link usb|ble`；未知选项/命令指名报错
  （`未知选项 --foo`），退出码 2；补全与手册页同步。
- 证据：`main.zig` 的参数解析/错误定位/输出格式测试；`packaging/completions/`、
  `packaging/man/f9ctl.1`。

## 二、测试与真机验收

### 本轮修复的缺陷（修测试时暴露出来的真实问题）—— 已修复

- **`ServerBusy` 没进 `ipc.wire_errors`**：daemon 在连接数达上限时直接回该错误名，
  但它不在线格式清单里，`f9ctl` 的 `errorFromName` 无法还原，用户会看到
  “f9d 返回未知错误（多为版本不一致）”而不是“连接数已满”。同时原测试用
  “遍历 `wire_errors`”自证完整，天然看不见清单本身的遗漏。
  修复：补进清单，并新增 E2E（占满 8 连接）+ `ipc.zig` 的必收录名单测试。
- **拒绝类响应可能被 RST 丢弃**：daemon 回完错误就 `close`，对端还有未读字节时内核发
  RST，连同刚写出的 JSON 一起丢掉，客户端只看到“连接被重置”。修测试时以
  `ServerBusy`/`LineTooLong` 两条 E2E 复现。
  修复：`finishConn` 先半关闭再把剩余输入读空（上限 200ms）再关闭；客户端
  `hasPending` 把“已有完整一行后的 reset”视为无排队数据，不再把已收到的响应变成失败。
- **测试自身的问题**：`daemon` 信号测试未恢复默认处置（会让测试进程无法被 TERM/INT 终止）、
  `FakeDevice.requests` 跨线程非原子、E2E 断言 `>= 5` 掩盖漏帧、夹具 socket 写在 `/tmp`
  且 `start` 失败会残留、`readLine` 的“排队字节”测试实际没走到 `hasPending`、
  `usb` 的 `alive` 测试只触发 `POLLNVAL`、“USB 切回”测试其实测的是 USB→USB。
  均已按测试名与实际断言对齐的方式修正（见下一条“离线自动化测试盲区”）。

### 1. 真机验收场景 —— 待真机（无法在离线环境完成）

- 未验收项完整列在 [ROADMAP](ROADMAP.md)：USB 权限/I/O 不回落、真机截断响应、
  设备忙/错误状态、两台同类 BLE 设备、无通知/写特征不支持/帧长异常、多候选回退与
  `ConnectTimeout`/`ResolveTimeout` 的实机表现。
- **本轮已在真机（蓝牙连接的风刃 F9）复测**：链路打开/复用（35ms / 14ms）、连续 10 对
  status+gear、强制 `--link ble`、强制 `--link usb` 返回 `DeviceNotFound` 且不回落、
  写回当前挡位（open→read→write→close→回读，75ms，风扇状态不变）、重启接管、SIGTERM
  清理，以及“未插 USB + BlueZ 不可用”返回 `未找到设备` 的双链路语义。详见 ROADMAP
  的 2026-11-25 记录。
- 未把任何未验收项写成“已通过”；新增 `--link usb|ble` 便于强制单链路复测，新增的错误名
  让复测结果更容易判定。

### 2. 离线自动化测试盲区 —— 已修复

- `ble.zig`：用**离线 sd_bus**（`sd_bus_new` + socketpair + `sd_bus_start`）构造/解析
  真实消息容器，覆盖 `parseProps`（全部建模键 + 未知键 + 类型不符）、`walkObjects`
  （`a{oa{sa{sv}}}`）、`readChangedValue`（`sa{sv}as`、空 Value、其它接口）、
  variant 各类型、`mapCallError`（错误名与 errno 表）、候选表与预算短路。
  过程中发现并修复：`ServicesResolved` 类型不符时被写成 `false`（现保持 null）。
- `daemon.zig`：E2E 测试用 socketpair 假 hidraw + 线程化服务 + 真实 `ipc.callOnPath`，
  覆盖 accept → serve → dispatch → `ops` → USB 事务 → 回包，含 gear set 回读、
  强制链路错误、尾随数据、超长请求行、连接上限（`ServerBusy`）、回读不一致
  （`GearMismatch` 后丢弃句柄、下个请求重新建链）、空闲连接并行；夹具 socket 建在
  `std.testing.tmpDir` 里，计数用原子量，关闭顺序固定（不再依赖“写端全关”来收尾）。
  另有 `dispatch` 级测试：非法请求不建链、直接回 `BadRequest`。
- `main.zig`：参数解析（含空值、单短横线、选项后置、大小写敏感）、错误定位、
  `parseGear`、JSON/人读输出格式、`unwrap` 的三条路径（透传 / 已知错误名 / 未知名）。
- `ipc.zig`：`LineTooLong` 边界、`connectTo` 的两种“未运行”归一、`checkTrustedDir`
  的权限位矩阵与符号链接判定、`wire_errors` 必须收录 daemon 直接回包的错误名。
- `ble.zig`：`FakeGatt` 记录通知订阅的装/卸次数，钉住成对释放（含写失败与坏帧出口）；
  visitor（适配器、别名命中、特征 flag/归属）、`onNotify` 路径过滤、`readChangedValue`
  的“无 Value / Value 非 ay”、`Str.set` 超长、`remainingUsec` 过期、`beginRequest`
  重置预算。
- `usb.zig`：`alive` 的 `POLLHUP`（管道关写端）与 `POLLNVAL` 两条路径、errno 全分支、
  uevent 匹配边界、“只见协议形状帧 → `BadResponse`”、帧源 I/O 错误透传。
- `ops.zig`：`ShortData`/`InvalidGear`、读阶段失败的收尾 close 与不写入、收尾 close
  也失败时保留原始错误、写入 offset/长度断言。
- `protocol.zig`：56/57 字节载荷边界、校验和高位非零时的小端字节序、会话帧完整性、
  `>64` 字节响应、`want` 为空时不判回显、状态尾部多余字节与 rpm 边界。
- 部署与运维：`f9d` 单元用 `RuntimeDirectory=f9d` 创建 `/run/f9d`（此前 `ReadWritePaths`
  指向不存在的目录，单元在挂载命名空间阶段直接失败，`systemd-analyze verify` 通过）；
  `serve` 自唤醒测试把轮询周期放到 5s，仍要求 < 1s 退出（证明停机不靠轮询超时，
  实测 SIGTERM → 退出 1ms）；接受连接设 `SO_SNDTIMEO`；拒绝路径收尾只等 20ms。
- 测试保持离线：不连接 system bus、不需要设备/BlueZ。

## 三、构建、打包、部署与运维

### 1. 系统集成与发布产物 —— 已修复

- `packaging/f9d.service`（systemd，`Restart=always` + 基础加固）、
  `packaging/99-legion-f9.rules`（hidraw `uaccess`）、
  `packaging/completions/{f9ctl.bash,_f9ctl,f9ctl.fish}`、`packaging/man/f9ctl.1`。
- `zig build install --prefix /usr` 安装程序/手册/补全/单元/udev；CI 验证安装布局。
- 版本定为 `0.1.0`（`build.zig` 与 `build.zig.zon` 同步，`--version` 输出）
  并新增 `CHANGELOG.md`；0.x 期间接口仍可能调整（版本策略见 ROADMAP）。
- 新增 `.github/workflows/ci.yml`：`zig fmt --check`、`zig build test`、`zig build`、
  安装布局冒烟、`tools/check-sensitive.sh`。

### 2. build.zig 对宿主机环境的脆弱假设 —— 已修复

- 链接仍按 `-lsystemd`（避免本机 `systemd` 空壳 .pc 吞掉 `-lsystemd`），
  头文件/库目录改为查询 `pkg-config --cflags/--libs libsystemd` 并加入模块；
  没有 pkg-config/该 .pc 或交叉编译时静默回退系统默认路径。
- 证据：本机 `zig build` 成功；移除/保留 pkg-config 都不影响默认环境。
  （NixOS/自定义 sysroot 的真实环境未验证，记入 ROADMAP 前提。）

## 四、协议功能范围与文档一致性

### 1. 已建模协议能力与功能范围 —— 已决定

- `0x03`/`0x1d` 未暴露：页长度、分块读语义与字段布局没有确认样本；按项目约束
  “不得猜测未确认的设备行为”“避免新增无用途的命令”，v1 不实现。`0x20`（inferred）、
  `0x04`/`0x0d`（unknown）同理；设置块其余 14 字节与状态尾部保持不透明。
- 已在 spec §4 增加“v1 暴露范围”表，design/0001“有意不做的”与 ROADMAP“功能范围”
  写明理由与再实现的前置条件（先采集脱敏样本、更新状态，再实现）。
- 旧实现的功能面（温控循环、配置文件、模拟器、Windows/F9 Lite）明确列为不在 v1 目标内。

### 2. 文档过时与不一致 —— 已修复

- `CONTRIBUTING.md` 死锚点改为 `README.md#快速开始`（对应标题存在）。
- `docs/design/0002-f9d-ble-link.md` 重写为现状设计文档：去掉委派任务口吻，把
  “响应必须恰好 20 字节”按真机结论改为“总长恰为 5+length”，修正记录保留在文末
  “真机验收记录与修正”。
- **日期核对（初版审计结论不成立）**：本仓库首个提交为 `2026-09-07`，真机验收
  `2026-09-21/24` 与 ROADMAP 截止 `2026-09-25` 都在当前日期 `2026-11-25` 之前，
  不是“未来日期”。初版审计写作时点早于这些日期，结论已过时；文档保持原日期。
  证据：`git log --reverse --format=%ad` 第一条为 2026-09-07，`date` 为 2026-11-25。
