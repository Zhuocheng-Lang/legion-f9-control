# 故障排查（docs/troubleshooting.md）

> 非官方社区项目。Lenovo 和 Legion 是其各自权利人的商标；本项目与 Lenovo 无关联、无背书。

## 1. 未发现设备（exit code 3）

```console
f9ctl devices list
```

USB：

- 确认设备已插入且产品为 `LEGION_F9_Wired`（`lsusb | grep 17ef:f00c`）；
- 安装 udev 规则并重载：

  ```console
  sudo cp packaging/udev/60-legion-f9-control.rules /usr/lib/udev/rules.d/
  sudo udevadm control --reload && sudo udevadm trigger
  ```

- 重新插拔或重新登录（uaccess 需要活动会话）。

BLE：

- 确认设备由电池供电（仅 USB 供电时不广播）；
- `bluetoothctl devices` 确认 `LEGION_F9_BT` 可见；
- BlueZ 版本建议 ≥ 5.55。

## 2. 权限不足（exit code 4）

- USB：udev 规则未生效或未重新插拔；
- daemon socket：确认是同一用户（`ls -l $XDG_RUNTIME_DIR/legion-f9-control/`，权限 0600）。

## 3. 设备忙（exit code 5）

- daemon 正在控制设备。用 IPC 路径（默认）或 `f9ctl daemon stop`；
- 其他 f9ctl 实例持有设备锁（`$XDG_RUNTIME_DIR/legion-f9-control/device-*.lock`）。

## 4. 超时/断线（exit code 6）

- USB：尝试换口/直连主板后置 USB；
- BLE：缩短距离、确认未被系统蓝牙面板独占。

## 5. raw 写被拒（exit code 10）

- 必须 `--unsafe-write`；
- TTY 会要求输入随机确认词；
- 脚本/CI 需设置 `F9CTL_UNSAFE_WRITE_ACK=<命令摘要>`（见 stderr 提示）；
- 白名单外命令与 OTA 永久拒绝，属预期行为。

## 6. daemon 不工作

```console
f9ctl config validate        # 先确认配置
f9ctl daemon status
journalctl --user -u f9d.service -n 50
```

- 配置错误不会部分生效（启动前完整校验）；
- 未识别字段默认报错，防止拼写静默失效；
- 修改配置后 `f9ctl daemon restart`（v1 无热重载）。

## 7. 温度读取为空

- daemon 找不到 CPU package 温度源时**停止写入**（不猜测 0 °C）；
- aarch64 平台可用 hwmon label 明确指定源（后续版本扩展配置）；
- `f9d -v` 日志会说明候选与选择结果。
