# legion-f9-control

Zig 实现的联想 Legion F9 控制：`f9ctl`（CLI）+ `f9d`（daemon）

## 约定

- 移植自 rust 版，在 `.legacy/` 下。请不要修改 legacy 版，并且不要将其重复提交。
- 协议细节以 `docs/spec/` 为准，设计决策见 `docs/design/`、`docs/rfcs/`，改动协议行为先改文档。
- stdout 只输出结果（人读或 JSON），诊断日志一律走 stderr。
- 项目全局使用中文（包括注释、文档、提交信息等），提交信息遵循 conventional commit 格式。

## 布局

- `src/root.zig` — 共享库 `f9`
- `src/main.zig` — `f9ctl` 入口；`src/daemon.zig` — `f9d` 入口
- `docs/` — spec / design / rfcs / ROADMAP

## 命令

- `mise install` — 安装 Zig/zls
- `zig build` — 构建
- `zig build test` — 全部单元测试
- `zig build run -- <args>` / `zig build run-f9d -- <args>` — 运行
