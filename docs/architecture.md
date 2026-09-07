# 架构（docs/architecture.md）

## 1. Workspace 布局

```text
crates/
├─ f9-protocol/       # 纯帧、命令、解析、校验；无平台 I/O
├─ f9-transport/      # Transport trait、发现模型、退避策略
├─ f9-transport-usb/  # HID report 4；Linux 稳定、Windows 实验
├─ f9-transport-ble/  # Linux BLE；其他平台 Unsupported 占位
├─ f9-core/           # Device API、写事务、安全门、daemon 控制逻辑
├─ f9-sim/            # 确定性模拟设备与故障注入
└─ f9-ipc/            # f9ctl ↔ f9d 的本地版本化 IPC
apps/
├─ f9ctl/             # 用户 CLI（lib + bin）
└─ f9d/               # 用户级守护进程
```

## 2. 依赖方向

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
- 平台条件分支散落到 core（平台分支只出现在 transport crates 与 daemon 平台入口）。

## 3. 关键机制

### 3.1 单命令串行化

- `Device` 内部 `tokio::sync::Mutex` 保证同一设备同一时刻最多一个未完成命令；
- USB transport 内部再加 `Mutex<Option<HidHandle>>`；BLE transport 用 in-flight 信号量；
- 每个物理设备持有进程级 advisory lock（Unix flock / Windows share_mode 0），
  daemon 持锁时 CLI 直连返回 Busy，不抢占。

### 3.2 写事务（read-modify-write）

见 `docs/protocol.md` §6。f9-core `Device::set_gear` 严格实现八步算法；
写超时先读回再判定，禁止盲重发（SPEC §14）。

### 3.3 传输选择（auto）

1. 合格 USB vendor interface 优先；
2. 否则扫描 BLE 服务 UUID；
3. 多设备时不自动猜测，提示 `--device`；
4. 一次命令选定 transport 后不中途切换；daemon 只在事务结束后重选，
   迁移前关闭旧连接，迁移后先读状态/配置再写。

### 3.4 USB 发现验证

不依赖“第二个 hidraw 节点”等顺序启发式：

- VID/PID 必须匹配 `17ef:f00c`；
- Linux hidraw 路径下读取 `/sys/class/hidraw/*/device/report_descriptor`，
  验证包含 report ID 4（`0x85 0x04` 全局项）；
- 无法读取描述符的后端回退为一次**只读**探针交换（0x1a）验证 report 4 收发。

### 3.5 daemon 状态机

```text
Starting → Discovering → ConnectedReadOnly → Controlling
                                        ↘ DegradedReadOnly
             Reconnecting ←（断线）        ↙（一次完整读取成功）
```

- 连接后先读设置，绝不立即写；
- 仅目标挡与读回挡不同且驻留满足时写；
- 连续 3 次读/写失败进入 DegradedReadOnly；降级只探测读取；
- 恢复前重新计算目标；
- 退出触发会话清理、transport close 与 socket 删除；
- daemon 重启不无条件产生 Flash 写。

## 4. 时间

- 滞回/驻留/退避使用单调时钟毫秒计数，不依赖墙钟；
- Controller 是纯逻辑（时间由调用方注入），可用虚拟时钟测试。
