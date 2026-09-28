# 贡献指南

欢迎改进 legion-f9-control。当前只支持 Linux，项目处于早期阶段；提交前请阅读 [README](README.md)、[项目约束](AGENTS.md) 和与你的改动相关的 [协议规范](docs/spec/0001-legion-f9-protocols.md) / [设计文档](docs/design/0001-f9d-architecture-and-ipc.md)。

## 准备环境

需要 Linux、mise、C 编译/链接工具链和 libsystemd 开发文件；涉及 BLE 真机验证还需要 BlueZ 与适配器。使用仓库固定的 Zig/ZLS 版本：

```sh
mise install
mise exec -- zig build
mise exec -- zig build test
```

构建和纯函数单元测试不需要连接风扇。运行程序的方法见 [README 的快速上手](README.md#从源码运行)。

## 修改代码与文档

1. 先确定改动属于协议事实、USB/BLE 链路、业务操作、IPC 还是 CLI；保持 `f9d` 独占设备、请求串行，`f9ctl` 只做客户端。尽量在现有模块中完成改动，不增加无用的命令、依赖或通用框架。
2. 改动帧形状、校验、会话语义或链路选择时，先更新 `docs/spec/` 中对应的协议事实及确认状态（`confirmed`、`inferred`、`unknown`），再修改实现和测试；架构决策同步更新 `docs/design/`。没有真机证据时不要推断字段意义或宣称通过真机验收。
3. 为变更添加最小的可离线运行的测试，覆盖正常路径和关键错误路径；不要让 `zig build test` 依赖真实设备或 system bus。改动用户可见行为时同步更新 README，未验收/已知限制同步更新 [ROADMAP](docs/ROADMAP.md)。
4. 注释、文档、提交说明使用中文；保留代码标识符、协议字段和 Conventional Commits 类型的原样拼写。stdout 仅用于结果，错误/诊断写 stderr。

真机测试可能改变风扇行为：写入前确认设备与环境安全。若无法进行真机验证，只报告离线结果与未验收项；记录证据时脱敏，**不要提交真实 BLE 地址、设备日志原文、抓包、私有资料或凭证**。

## 提交前检查

在仓库根目录运行：

```sh
mise exec -- zig fmt --check src/*.zig build.zig
mise exec -- zig build test
mise exec -- zig build
git diff --check
```

如有文档改动，核对示例命令与当前实现、相对链接与风险提示。按改动范围检查差异与暂存文件，避免加入 `.legacy/`、本地环境文件或 `zig-out/`、`.zig-cache/`。未运行或失败的检查请在提交/合并请求说明中明确标注，不要把离线测试写作真机验收。

提交信息采用 Conventional Commits，类型用英文、摘要用中文，例如：

```text
fix: 修复 USB 短通知过滤

docs: 补充非 root 运行限制
```

提交/合并请求中简要写明改动目的、测试命令与结果、真机验收范围（或未验收原因），以及对协议和文档的影响。旧 Rust 实现位于冻结的 `legacy` 分支；本地 `.legacy/` 仅供参考，不属于提交范围。项目按 [MPL-2.0](LICENSE) 发布。
