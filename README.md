# legion-f9-control

Linux 下控制联想 Legion F9 散热风扇的用户态工具，Zig 实现。读取实时状态
（flag、风扇转速 RPM），读取与设置挡位（quiet / balanced / beast / turbo）。

> [!WARNING]
> **当前版本 v0.0.0，处于早期开发阶段。不保证 CLI 参数、JSON 输出形状、
> IPC 协议与内部 API 的任何稳定性，均可能在不预告的情况下破坏性变更。**
> 真机验收尚未全面覆盖，已知缺口见下文「稳定性与验收状态」。

## 架构：f9d + f9ctl

- **f9d**（daemon）：独占设备，串行执行一切设备流量，经 Unix socket 提供服务。
  前台运行，生命周期交给 init 系统。会话命令是有状态的，必须单点独占，
  多点直连会互相破坏读-改-写序列。
- **f9ctl**（CLI）：纯客户端，只通过 socket 与 f9d 通信，不直接访问设备，
  无需 root。stdout 只输出结果，诊断日志一律走 stderr。

链路选择：**USB 优先**（hidraw，VID `17ef` PID `f00c`，64 字节帧）；
仅当 USB 报「设备不存在 / 无应答」时才回落 **BLE**（BlueZ，设备名
`LEGION_F9_BT`）；USB 权限、I/O 等其他错误原样上报，不用 BLE 掩盖。
一次请求只走一条链路，失败不重放写入、不中途换链路；失败后丢弃句柄，
下个请求惰性重建并重新选择链路（拔插恢复即由此覆盖）。

## 构建

**必须使用 mise 提供的 Zig 0.15.1**（`mise.toml` 钉死 zig 与 zls 版本）。
系统自带的其他版本 zig 与本项目不兼容，**不要绕过 mise 直接运行 `zig`**。

```sh
mise install               # 安装锁定版本的 zig / zls
mise exec -- zig build     # 构建
```

产物：`zig-out/bin/f9d` 与 `zig-out/bin/f9ctl`。BLE 链路经系统
libsystemd 的 sd-bus 连接 BlueZ，因此构建依赖 libc 与 libsystemd 头文件/库。

开发时也可直接运行：

```sh
mise exec -- zig build run -- status        # 构建并运行 f9ctl
mise exec -- zig build run-f9d              # 构建并运行 f9d
```

## 运行前提

- **Linux**，且 BLE 链路依赖 **BlueZ**（system bus 可达、适配器已启用）。
- **USB 访问权限**：f9d 以 root 运行即可；非 root 运行需通过 udev
  （如 uaccess 标签）授予 hidraw 节点权限。
- **非 root 开发实例**要求 `XDG_RUNTIME_DIR` 已设置，且目录属主本人、
  权限不宽于 `0700`，否则 f9d 拒绝启动（不回退 /tmp，防可预测路径占位）。

## 用法

```sh
# 1. 启动 daemon（前台运行；root 实例需要 hidraw 权限）
sudo zig-out/bin/f9d

# 2. 客户端（无需 root）
zig-out/bin/f9ctl status          # 实时状态：flag、RPM
zig-out/bin/f9ctl gear            # 读挡位
zig-out/bin/f9ctl gear turbo      # 写挡位：quiet|balanced|beast|turbo 或 0-3
zig-out/bin/f9ctl --json status   # JSON 输出（--json 对所有命令有效）
```

写挡位是有副作用的操作（open 会话 → 读设置块 → 改挡位字节 → 写入 →
close → 回读确认），只在确认安全时执行。

Socket 行为：

| 实例 | 监听路径 | 说明 |
| --- | --- | --- |
| root | `/run/f9d/f9d.sock`（0666） | 本地所有用户均可控制风扇 |
| 非 root 开发 | `$XDG_RUNTIME_DIR/f9d.sock` | 仅本人可连 |

f9ctl 先连系统级路径，失败再连用户级路径。f9d 对 `<socket>.lock` 持排他
flock 防双开；每连接一请求一响应，单行 JSON。f9ctl 等响应上限 35 秒，
BLE 单请求预算 30 秒——任何失败都有界，不会无限等待。

## 测试

```sh
mise exec -- zig build test                      # 全部单元测试（纯函数，无需硬件）
mise exec -- zig fmt --check src/*.zig build.zig # 格式检查
```

## 稳定性与验收状态

**v0.0.0，可能随时破坏性变更；请勿当作稳定接口依赖。**

已完成三轮 BLE/USB 真机验收（状态/挡位读写、连续请求、断连重连、
USB 拔插、多 hidraw 接口与短通知过滤等，详见
[docs/ROADMAP.md](docs/ROADMAP.md)），但以下场景**仍未真机验收**：

- USB 权限 / I/O 错误下「不回落 BLE」的行为（仅单测覆盖）；
- 两台同类 BLE 设备同时在线时的服务/特征归属；
- BlueZ 未启动、无通知、写特征不支持、真机出现截断响应帧；
- 部署与发布：systemd 单元、安装说明、打包与版本号策略；
- [docs/troubleshooting.md](docs/troubleshooting.md) 尚为骨架，条目未补齐。

待定夺事项：设备关闭时 f9d 在有界预算内返回 `Timeout`，f9ctl 文案
「等待响应超时」易被误读为客户端等待超时，实际语义是连接/服务解析超时，
文案尚未调整。

## 文档

- [docs/spec/0001-legion-f9-protocols.md](docs/spec/0001-legion-f9-protocols.md) — 硬件协议事实（改动协议行为先改这里）
- [docs/design/0001-f9d-architecture-and-ipc.md](docs/design/0001-f9d-architecture-and-ipc.md) — f9d/f9ctl 架构与 IPC 协议
- [docs/design/0002-f9d-ble-link.md](docs/design/0002-f9d-ble-link.md) — BLE 链路实现边界与验收记录
- [docs/ROADMAP.md](docs/ROADMAP.md) — 里程碑、真机验收记录与未验收项
- [docs/troubleshooting.md](docs/troubleshooting.md) — 故障排查（骨架）

## Legacy（旧 Rust 实现）

本项目最初由 Rust 实现，现已冻结在 **`legacy` 分支**，仅作存档与移植参考，
不再维护。当前 `main` 是从零重写的 Zig 版本，与 Rust 版无代码共享。

## 许可证

[Mozilla Public License 2.0](LICENSE)。
