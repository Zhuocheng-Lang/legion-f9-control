# 安全模型（docs/safety.md）

> 非官方社区项目。Lenovo 和 Legion 是其各自权利人的商标；本项目与 Lenovo 无关联、无背书。

## 1. 安全不变量

- 正常 API 不表达 OTA/report 5；任何路径（含 raw 与 `--force`）都不得收发 report 5 或 OTA 帧；
- 所有编码器检查 payload、offset 与 frame 容量；
- 所有解码器拒绝短帧、错 command 和错 transport；
- 同一设备同一时刻最多一个未完成命令；配置写必须序列化；
- transport 切换不能发生在一次事务中间；
- 未知协议事实不得被包装成稳定字段；
- `unsafe` 默认禁止（workspace `unsafe_code = "forbid"`）。

## 2. raw 调试门

- 默认只读：仅白名单读取命令（0x03、0x05、0x1a；USB 可加 0x1d）；
- 写解锁三要素：`--unsafe-write` + TTY 随机确认词（非固定 "yes"）或
  `F9CTL_UNSAFE_WRITE_ACK=<本次命令摘要>`；stderr 显示 command/offset/length/transport 与不可逆风险；
  日志只记录命令摘要（含首尾字节哈希），不记录完整 payload；
- 永久禁止：report ID 5、OTA、超出已知配置地址空间（15 字节设置块）的写、payload 溢出、
  以 `--force` 绕过帧结构校验；
- 0x20（灯效写）在 RGB 规格完成前于 raw 写路径默认拒绝。

## 3. 威胁模型

重点防护：

- 恶意或异常设备返回短包/超长包（解码器有界解析）；
- 非目标 HID 设备误匹配（VID/PID + report descriptor 验证 + 只读探针）；
- 本地低权限进程调用 daemon socket（UDS 权限 0600，仅本用户可见目录）；
- 配置文件注入错误阈值（deny unknown fields + 范围校验 + validate 不访问硬件）；
- raw 绕过安全写路径（白名单在 core 层强制，CLI 门只是外层）；
- 日志泄露设备标识（默认脱敏 BLE 地址/USB 序列号/用户路径；`--show-device-identifiers`
  仅临时展示；raw payload 需双重 debug 开关）；
- 供应链依赖风险（锁文件、cargo-deny、RustSec、固定 Actions SHA）；
- daemon 与 CLI 并发写造成 Flash 磨损（advisory lock + IPC 串行化 + 不变不写）。

**明确不设防**：已控制当前用户账户的攻击者；远程攻击（项目不提供远程边界）。

## 4. 隐私

- 日志默认 `info`，结构化字段（event、transport、operation、attempt、duration、error code）；
- 脱敏设备标识：`device_id` 是会话稳定的哈希，不是真实地址/序列号；
- 提交历史、issue、PR 同样不得包含真实 MAC、序列号、主机名、用户名、绝对路径。

## 5. 硬件保护

- 不变不写（相同挡位 0 次 Flash 写，模拟器测试断言）；
- 最短驻留 15s + 3 °C 滞回，防止 Flash 磨损；
- 写超时先读回，不盲重发；
- daemon 默认禁用 turbo；温度源消失时停止写入，不猜测 0 °C。
