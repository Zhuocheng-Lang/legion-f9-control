# legion-f9-control

Zig 实现的联想 Legion F9 控制工具：`f9ctl`（CLI）+ `f9d`（daemon）。当前仅支持 Linux；开始修改前先阅读 [README](README.md) 与相关协议、设计文档。面向贡献者的流程见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 工作边界

- 旧 Rust 实现冻结在 `legacy` 分支，本地 `.legacy/` 被忽略。不要修改或重新提交旧实现；不要覆盖用户已有改动。
- 硬件协议事实以 `docs/spec/` 为准，设计决策以 `docs/design/` 为准。改变协议行为时先更新 spec 中的事实及 `confirmed` / `inferred` / `unknown` 状态，再修改实现与测试；不得猜测未确认的设备行为。
- 项目文档、注释与提交信息使用中文；协议字段、Zig 标识符、工具名与 Conventional Commits 类型保留其原文。开发规范写入本文件，贡献步骤写入 `CONTRIBUTING.md`，用户用法写入 `README.md`，避免互相复制长段内容。
- 不提交设备地址、真实设备数据、抓包、私有材料、凭证或构建产物；测试向量使用脱敏/手工构造数据。

## 实现约束

- `f9d` 独占设备并串行处理请求；`f9ctl` 仅通过 IPC 与 daemon 通信。stdout 只输出结果（人读或 JSON），诊断走 stderr。
- USB 优先，仅设备未找到/无应答时回落 BLE；权限与 I/O 错误原样报告。同一请求不换链路、不重放写入；失败后丢弃句柄，由下个请求重新连接。
- 设置挡位要保持现有会话读-改-写-关闭与回读确认语义；已打开会话出错时尽力关闭。不要在无真机证据时放松帧校验。
- 避免新增无用途的命令、抽象和依赖。保持协议编码、传输、业务操作及 IPC 的现有边界。

## 目录与命令

- `src/root.zig`：共享模块；`src/protocol.zig`：协议；`src/usb.zig` / `src/ble.zig`：链路；`src/ops.zig`：业务操作；`src/ipc.zig`：通信；`src/main.zig` / `src/daemon.zig`：入口。
- `docs/spec/`：协议事实；`docs/design/`：设计与验收；`docs/ROADMAP.md`：进展与未验收项。
- 工具版本固定于 `mise.toml`：`mise install`，随后使用 `mise exec -- zig build`、`mise exec -- zig build test`、`mise exec -- zig fmt --check src/*.zig build.zig`。
- 本地运行：`mise exec -- zig build run -- status` 或 `mise exec -- zig build run-f9d`。不要用系统 Zig 版本代替 mise 固定版本。

## 验证与交付

- 修改后运行格式检查、单元测试与构建；不能执行的检查要说明原因。纯函数测试不需要设备；真机读写、拔插及 BLE 异常场景只能在有设备且确认安全时验收，未验证不得写成已通过。
- 更新影响到的 README、spec、design 或 ROADMAP；变更提交遵循 Conventional Commits，如 `fix: 修复 USB 短通知过滤`。提交前检查暂存文件，不带入 `.legacy/` 或敏感材料。
