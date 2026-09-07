# 更新日志（CHANGELOG.md）

格式参考 Keep a Changelog；语义化版本（SemVer）。
兼容面：CLI 命令、JSON schema（`schema_version`）、配置 schema、正式平台行为。

## [1.0.0] - 未发布

### Added

- Rust workspace：`f9-protocol`、`f9-transport`、`f9-transport-usb`、
  `f9-transport-ble`、`f9-core`、`f9-sim`、`f9-ipc` 与 `f9ctl`、`f9d`；
- USB HID（report 4）与 BLE 双传输：发现、状态、信息、四挡设置、监控；
- 挡位写事务：read-modify-write、会话化写入、写后读回、不变不写；
- f9d 用户级温控守护进程：TOML 配置、默认曲线、3 °C 滞回、15 s 驻留、
  turbo 默认禁用、连续失败只读降级与恢复；
- f9ctl ↔ f9d 版本化本地 IPC（UDS 0600），CLI `--no-daemon` 直连与设备 advisory lock；
- raw 调试安全门：默认只读白名单、写解锁确认词/ACK、OTA/report 5 永久拒绝；
- 确定性模拟器与故障注入（超时、断连、busy、错/短帧、陈旧通知、写回复丢失、
  重连挡位漂移、多设备、Flash 写计数）；
- JSON envelope（schema_version 1）与稳定退出码表；
- 打包：udev 规则、systemd user unit、shell 补全、man page；
- CI 门禁：fmt、clippy -D warnings、测试矩阵（Linux x86_64/aarch64、Windows
  x86_64 experimental）、cargo-deny、RustSec、secret scan、禁止文件/大文件检查。

### 兼容性说明

- 全新实现，不兼容任何旧版 CLI/配置/输出格式；
- Windows USB 为 `experimental`，可能在 minor 版本调整；
- Windows BLE、macOS、OTA/RGB：v1 明确不支持。
