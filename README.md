# legion-f9-control

> **非官方社区项目。** Lenovo 和 Legion 是其各自权利人的商标；本项目与 Lenovo 无关联、无背书。

为 Lenovo Legion 风刃 F9 BT 散热器提供安全、可靠、可脚本化的**非官方**控制工具。

- 插 USB 时低延迟、无需 root 地控制设备；
- 独立供电时可通过 BLE 控制；
- 根据主机 CPU 温度自动切换固定挡位；
- 默认保护未知配置字节、设备 Flash 和用户硬件；
- 输出既适合人读，也适合脚本（稳定 JSON）。

[English](README.en.md) | [协议事实](docs/protocol.md) | [安全模型](docs/safety.md)

## 支持矩阵

| 能力 | Linux USB | Linux BLE | Windows USB | Windows BLE |
| --- | --- | --- | --- | --- |
| 发现 / 状态 / 四挡设置 / monitor | 稳定 | 稳定 | 实验 | 不支持 |
| info 读取 | 稳定 | 受 BLE 命令集限制 | 实验 | 不支持 |
| daemon（温控） | 稳定 | 稳定 | 不支持 | 不支持 |
| raw 调试 | 稳定 | 稳定 | 实验 | 不支持 |

“稳定”进入 semver 兼容承诺；“实验”可发布但可能在 minor 版本调整（CLI 标注 `experimental`）。

## 30 秒上手

```console
# 安装（release 产物或 cargo build --release 后复制）
sudo install -m755 target/release/f9ctl target/release/f9d /usr/local/bin/
sudo cp packaging/udev/60-legion-f9-control.rules /usr/lib/udev/rules.d/
sudo udevadm control --reload && sudo udevadm trigger

f9ctl status
f9ctl mode set beast
f9ctl monitor
```

BLE 前提：设备由电池供电（仅 USB 供电时不广播）、BlueZ ≥ 5.55。

## 四挡与 turbo 风险

`quiet / balanced / beast / turbo` 四个固定挡位。**设置总是先读、只改目标字节、写后读回**；
重复设置当前挡位不产生任何 Flash 写。

- `turbo` 依赖供电；供电不足时设备可能自行回退（RPM 不达标），这**不代表设置失败**；
  CLI 每次设置 turbo 都会打印供电/回退提示；
- daemon 默认禁用 turbo（配置 `allow_turbo = true` 可开启，请自行评估供电）。

## daemon 快速配置

```console
f9ctl daemon install
cp config/f9d.example.toml ~/.config/legion-f9-control/config.toml
f9ctl config validate
f9ctl daemon start
```

默认曲线：`<50°C quiet`、`50–<60°C balanced`、`≥60°C beast`；
3 °C 降挡滞回、15 s 最短驻留；连续 3 次失败进入只读降级，恢复后先读再写。
修改配置后需 `f9ctl daemon restart`（无热重载）。

## JSON 自动化

```console
$ f9ctl --output json status
{
  "schema_version": 1,
  "ok": true,
  "command": "status",
  "device": { "id": "redacted-stable-session-id", "transport": "usb" },
  "data": { "rpm": 2012, "gear": "balanced" },
  "warnings": []
}
```

- 同一 major 版本不删除/改变已有字段含义，可添加字段；
- `monitor --output json` 输出 JSON Lines；
- 诊断日志只写 stderr。

退出码：0 成功；2 用法/配置；3 未发现设备；4 权限；5 忙；6 超时/断线；7 协议无效；
8 验证失败/结果不确定；9 平台/transport 不支持；10 安全策略拒绝。

## raw 调试（默认只读）

```console
f9ctl debug raw --cmd 0x1a --length 6 --offset 0
f9ctl debug raw --cmd 0x06 --length 15 --data "..." --unsafe-write
```

写需 `--unsafe-write` 加 TTY 随机确认词，或脚本中设置
`F9CTL_UNSAFE_WRITE_ACK=<命令摘要>`。OTA/report 5 **永久拒绝**。

## 隐私与安全

- 日志默认脱敏 BLE 地址、USB 序列号与用户路径；`--show-device-identifiers` 仅临时展示；
- 不监听任何网络端口；IPC 为本用户 Unix domain socket（0600）；
- 安全问题请勿公开提交：见 [SECURITY.md](SECURITY.md)。

## 故障排查

见 [docs/troubleshooting.md](docs/troubleshooting.md)（未发现设备、权限、忙、超时、raw 拒绝、daemon）。

## 安装内容（打包）

```text
/usr/bin/f9ctl
/usr/bin/f9d
/usr/lib/udev/rules.d/60-legion-f9-control.rules
/usr/lib/systemd/user/f9d.service
/usr/share/doc/legion-f9-control/
/usr/share/man/man1/f9ctl.1
```

## v1 范围外

固件升级/OTA、RGB 写入、任意 PWM、Web/云服务、root 系统服务、Windows BLE、macOS。
详见 `.agents/spec/SPEC.md` §4.2。

## 许可证

[MIT](LICENSE)。另见 [NOTICE.md](NOTICE.md)（非官方声明与商标说明）。
