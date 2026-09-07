# 贡献指南（CONTRIBUTING.md）

> 非官方社区项目。Lenovo 和 Legion 是其各自权利人的商标；本项目与 Lenovo 无关联、无背书。

## 提交合规红线（先读）

**禁止提交**（SPEC §16.2，PR 中发现即拒绝）：

- 厂商安装包、升级器、DLL/EXE、固件镜像、资源文件；
- 反编译产物（Ghidra 工程、大段 C/汇编）；
- 原始抓包、真实 MAC、序列号、主机名、用户名、绝对路径；
- `.venv`、`target/`、缓存、日志、临时转储、`.exe/.dll/.bin/.gpr/.rep/.pcap/.pcapng`；
- 声称或暗示厂商授权、官方身份的材料。

协议文档/代码只陈述实现所需事实，不描述私有材料来源。提交历史同样适用。

## 开发流程

1. Fork / 分支；main 禁止直接 push，需要 review；
2. 提交信息建议 Conventional Commits：`feat|fix|docs|test|refactor|build|ci|security`；
3. 涉及协议或安全写路径的 PR 必须在描述中列出**风险与真机验证要求**。

## 本地门禁（CI 同款）

```console
cargo fmt --check
cargo clippy --workspace --all-targets --all-features -- -D warnings
cargo test --workspace --all-features
cargo deny check        # 许可证 + RustSec
```

- `rust-toolchain.toml` 固定工具链；
- `unsafe` 默认禁止（workspace lint）；
- 日志必须脱敏；诊断只写 stderr；
- human/JSON/exit code 行为变更必须同步测试与 changelog。

## 测试要求（Definition of Done）

- 正常、边界、失败、取消路径均有测试；
- 协议事实标注 confirmed/inferred/unknown；
- 涉及硬件行为时更新 `docs/hardware-testing.md` 清单；
- 模拟器（f9-sim）覆盖新增故障语义。

## 依赖

新增依赖需评估：维护状态、平台支持、许可证、最小 API 面。候选名单见 SPEC §8.3；
默认不允许引入未审查依赖。
