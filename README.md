# legion-f9-control

Linux 下控制联想 Legion F9 风扇（挡位与转速状态）的用户态工具：

- **f9d** —— daemon，独占设备（USB 优先、必要时回落 BLE），经 Unix socket 提供服务；
- **f9ctl** —— 纯客户端 CLI，通过 f9d 读取状态、读写挡位，不直接访问设备。

协议事实见 [docs/spec/0001-legion-f9-protocols.md](docs/spec/0001-legion-f9-protocols.md)，
架构与 IPC 设计见 [docs/design/](docs/design/)，故障排查见 [docs/troubleshooting.md](docs/troubleshooting.md)。

## 构建

**必须使用 mise 提供的 Zig 0.15.1**（由 `mise.toml` 钉死，zls 同版本）。系统自带的
zig 0.16 与本项目不兼容，不要绕过 mise 直接运行 `zig build`。

```sh
mise install                                     # 安装锁定版本的 zig/zls
mise exec -- zig build                           # 构建，产物在 zig-out/bin/{f9d,f9ctl}
mise exec -- zig build test                      # 单元测试
mise exec -- zig fmt --check src/*.zig build.zig # 格式检查
```

## 用法

```sh
# 1. 启动 daemon（root 实例需要 hidraw 权限；前台运行，生命周期交给 init 系统）
sudo zig-out/bin/f9d

# 2. 客户端（无需 root）
zig-out/bin/f9ctl status         # 实时状态：flag、RPM
zig-out/bin/f9ctl gear           # 读挡位
zig-out/bin/f9ctl gear turbo     # 写挡位：quiet|balanced|beast|turbo 或 0-3
zig-out/bin/f9ctl --json status  # JSON 输出（stdout 只有结果，日志走 stderr）
```

非 root 开发实例监听 `$XDG_RUNTIME_DIR/f9d.sock`；f9d 启动前会校验该目录属主为
本人且权限不宽于 0700，未设置或不满足即拒绝启动。开发时也可以用
`mise exec -- zig build run -- <args>` / `mise exec -- zig build run-f9d -- <args>`。
