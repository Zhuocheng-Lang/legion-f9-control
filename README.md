# legion-f9-control

在 Linux 上，不安装 LEGION ZONE，也能查看联想拯救者风刃 F9 散热风扇的转速、切换挡位。`legion-f9-control` 是一套开源的
Zig 命令行第三方工具，可通过 USB 或蓝牙连接设备。

- **看状态**：读取风扇转速（RPM）和设备状态标志。
- **调挡位**：查看或切换 quiet、balanced、beast、turbo 四种挡位。
- **按需接入**：提供 JSON 输出，方便在脚本中读取结果。

**目前仅支持 Linux 下的风刃 F9。**Windows、灯光控制和 F9 Lite 尚未支持。

> [!WARNING]
> 当前为早期版本（`0.0.0`），命令和输出格式可能变化。调节挡位会影响风扇运行，请确认安全后操作。以 root 启动服务时，**本机所有用户都能控制风扇**；共享主机请谨慎使用。部分场景尚未完成真机验收，见[已知限制](#已知限制)。

## 快速开始

目前需要自行编译，暂无现成安装包。准备好 Linux、[mise](https://mise.jdx.dev/) 和 C 编译/链接工具链，并安装 libsystemd 开发文件（例如 `libsystemd-dev` 或 `systemd-devel`）。本项目通过 [`mise.toml`](mise.toml) 固定 Zig `0.15.1`，请勿改用系统 Zig。

在项目目录下构建：

```sh
mise install
mise exec -- zig build
```

打开**两个终端**。第一个终端启动设备服务 `f9d`（保持运行）：
```sh
sudo ./zig-out/bin/f9d
```

第二个终端运行 `f9ctl`；先试试只读命令，无需 `sudo`：

```sh
./zig-out/bin/f9ctl status          # 查看状态和转速
./zig-out/bin/f9ctl gear            # 查看当前挡位
./zig-out/bin/f9ctl gear turbo      # 切换到 turbo 挡位
./zig-out/bin/f9ctl --json status   # 以 JSON 输出状态
```

挡位还可以指定为 `quiet`（静音）、`balanced`（均衡）、`beast` 或数字 `0`–`3`。`--json` 适用于所有命令；运行 `./zig-out/bin/f9ctl --help` 可查看完整用法。

连接设备时优先使用 USB；USB 未找到设备或设备无应答时，才会尝试蓝牙。要使用蓝牙，请确保 BlueZ 正在运行、蓝牙适配器已启用且 system bus 可用。USB 连接则要求运行 `f9d` 的用户有权访问设备的 hidraw 节点。

## 可选：手动安装

目前没有安装包、systemd 服务单元或经过验收的一键安装流程。如需从任意目录运行，可以复制编译好的程序；仍需在一个终端保持 `f9d` 运行：

```sh
sudo install -m 0755 zig-out/bin/f9d zig-out/bin/f9ctl /usr/local/bin/
sudo /usr/local/bin/f9d            # 终端 1
/usr/local/bin/f9ctl status         # 终端 2
```

不想以 root 运行？可以为当前登录用户配置 udev/uaccess 权限后，以该用户启动 `f9d`。此时必须设置 `XDG_RUNTIME_DIR`，且目录属于该用户、权限不宽于 `0700`。项目暂未提供通用 udev 规则或用户服务单元，需按发行版验证；也请避免同时启动 root 和用户实例，客户端会优先连接 root 实例。

## 已知限制

USB 和蓝牙已在真机上验证状态读取、挡位读写、连续请求和断连恢复，但尚未覆盖全部环境。特别是 USB 权限/I/O 错误、同时连接两台同类蓝牙设备，以及 BlueZ 不可用、蓝牙无通知或响应异常等场景，仍有待真机验收。请勿把当前版本当作稳定接口；详情见[验收记录与后续计划](docs/ROADMAP.md)。

如果无法连接，请先确认 `f9d` 正在运行、设备已开启，且服务有访问设备的权限。错误信息写到终端的 stderr；[故障排查文档](docs/troubleshooting.md)目前尚待完善。

## 了解项目与参与贡献

`f9d` 负责与设备通信，`f9ctl` 是无需直接访问设备的命令行客户端。设备操作由 `f9d` 串行执行；USB 权限错误不会通过切换到蓝牙来掩盖，同一次请求也不会自动重放写入。更多技术细节见[架构与 IPC](docs/design/0001-f9d-architecture-and-ipc.md)。

想参与开发？请从[贡献指南](CONTRIBUTING.md)开始；协议事实见[硬件协议文档](docs/spec/0001-legion-f9-protocols.md)，BLE 实现记录见[设计文档](docs/design/0002-f9d-ble-link.md)。旧 Rust 实现冻结在 `legacy` 分支，仅供参考；当前版本为 Zig 重写版。

## 许可证

[Mozilla Public License 2.0](LICENSE)。
