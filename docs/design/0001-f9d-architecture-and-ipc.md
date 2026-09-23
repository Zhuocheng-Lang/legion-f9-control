# f9d / f9ctl 架构与 IPC 协议

## 架构

- **f9d 独占设备**。会话命令（0x01/0x02）是有状态的，多点直连 hidraw 会互相破坏
  读-改-写序列；因此一切设备流量只经 f9d。f9d 以 root 运行（hidraw 权限），前台执行，
  生命周期交给 init 系统（`Restart=always` 即覆盖拔插恢复）。
- **f9ctl 是纯客户端**，不直接打开设备，用户态即可运行。

## IPC（Unix socket）

- 路径：root 实例 `/run/f9d/f9d.sock`（0666，本地用户均可控制风扇）；
  非 root 开发实例 `$XDG_RUNTIME_DIR/f9d.sock`（避免 /tmp 可预测路径被占位）。
  安全前提：该目录属主本人且权限不宽于 0700——非 root f9d 启动前校验，不满足拒绝启动。
  未设置 XDG_RUNTIME_DIR 时 f9d 拒绝启动（报 NoRuntimeDir），不回退 `/tmp/f9d-<euid>.sock`：
  公共 /tmp 下可预测的 socket/lock 路径可被符号链接攻击（锁文件创建会截断目标），
  最小安全方案就是只用可信目录。客户端先连系统级路径，失败（含陈旧 socket 拒连）再连用户级路径。
- 防双开：daemon 对 `<socket>.lock` 持排他 flock（随进程退出自动释放），
  持锁后残留 socket 必属死实例，直接删除再绑定，无 TOCTOU 窗口。
- 每连接一请求一响应，均为 `\n` 结尾的一行。
- 请求：`status` / `gear` / `gear <0-3>`。
- 响应（JSON）：成功 `{"flag":…,"rpm_raw":…,"rpm":…}` 或 `{"gear":…}`；
  失败 `{"error":"<zig 错误名>"}`。错误名即线格式，展示文案归 f9ctl。
- 超时：f9ctl 等响应上限 15s，大于 gear set 最坏预算（5 次 USB 事务 × 2s，
  外加设备惰性打开与多接口探测）。

## 有意不做的

- BLE 传输、info 页（0x03/0x1d）、灯效（0x20）、raw 命令：spec 已记录但 v1 无用途。
- 并发 accept：设备会话要求串行，单线程顺序处理即可。
- 设备事务的重试/退避：失败后丢弃句柄、下个请求惰性重开即可覆盖拔插。
- polkit / 用户组鉴权：需要收紧时再换。
