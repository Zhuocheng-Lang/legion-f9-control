# 协议事实表（docs/protocol.md）

> 只陈述实现所必需的脱敏事实，不描述任何私有材料来源、获取过程、文件名或个人信息。
> 每项事实标注 `confirmed`（真机验证）/ `inferred`（合理推断，真机验收前可调）/ `unknown`（未建模）。
> **实现只能依赖 `confirmed` 字段作为稳定语义。**

## 1. 设备标识 `confirmed`

- USB VID：`0x17ef`；USB PID：`0xf00c`；USB 产品标识字符串：`LEGION_F9_Wired`。
- BLE 名称：`LEGION_F9_BT`。
- BLE 服务 UUID：`19090909-0a0a-0b0b-0c0c-0d0d0e0e0f0f`。
- BLE 写特征（主机 → 设备）：`19190909-0a0a-0b0b-0c0c-0d0d0e0e0f0f`。
- BLE 通知特征（设备 → 主机）：`19290909-0a0a-0b0b-0c0c-0d0d0e0e0f0f`。
- BLE 地址可能变化：禁止硬编码、写入示例或提交日志。发现以服务 UUID 为主，名称为辅。

## 2. USB 帧 `confirmed`

固定 64 字节，report ID 4：

```text
[0]     = 0x04
[1:2]   = sum(bytes[3..63]) & 0xffff，小端
[3]     = command
[4]     = payload length
[5:6]   = offset，小端
[7]     = request 保留字；response status
[8:64]  = payload/data
```

- 响应状态：`0x00` 成功、`0xfe` 忙、`0xff` 错误。
- 解码器必须检查长度、report ID、command 回显与状态，不得索引短包。
- report ID 5 一律拒绝（不属于本协议实现的任何合法收发路径）。

## 3. BLE 帧 `confirmed`

固定 20 字节：

```text
request:  [0]=0xee [1]=command [2]=length [3:4]=offset LE [5:20]=payload
response: [0]=0xee [1]=command [2]=length [3:4]=offset LE [5:20]=data
```

- 单帧 payload 上限 15 字节；无 USB 式校验和。
- `0x01`、`0x02` 会话命令不等待通知，按 fire-and-forget 处理。
- 其他命令必须匹配帧头、command、长度与 offset。
- **不能只用响应 `[7]` 判错**——它在有效响应中属于数据。
- 支持集：`0x01`、`0x02`、`0x03`、`0x04`、`0x05`、`0x06`、`0x0d`、`0x1a`、`0x20`。
- BLE 写特征使用 write-with-response；不静默降级。

## 4. 命令表

| 命令 | 名称 | 状态 | v1 用途 |
| --- | --- | --- | --- |
| `0x01` | session open | confirmed | 写配置前打开会话（BLE fire-and-forget） |
| `0x02` | session close | confirmed | 关闭/提交会话（BLE fire-and-forget） |
| `0x03` | info page | confirmed | 读取信息页 |
| `0x05` | settings read | confirmed | 分块读取设置 |
| `0x06` | settings write | confirmed | 分块写设置 |
| `0x1a` | live status | confirmed | 读取 flag 与 RPM |
| `0x1d` | device info | confirmed | 仅 USB 正常使用 |
| `0x04` | unknown | unknown | v1 不调用 |
| `0x0d` | unknown | unknown | v1 不调用 |
| `0x20` | 灯效写（inferred） | inferred | v1 正常命令不暴露；raw 写默认拒绝 |
| OTA/report 5 | — | out of scope | 永不收发 |

## 5. 状态解码 `confirmed`

状态数据至少校验 3 字节：

```text
flag    = data[0]
rpm_raw = little_endian(data[1], data[2])
rpm     = rpm_raw >> 2
```

未知尾部只能以 `unknown_fields`/原始十六进制在 expert 输出显示，不得赋予未经证实的语义。

## 6. 设置块与挡位 `confirmed`

设置块前 15 字节视为不透明结构，仅公开：

```text
byte[13] = gear
0 quiet / 1 balanced / 2 beast / 3 turbo
```

写挡位强制算法：

1. 读取完整 15 字节；
2. 如果 `byte[13]` 已等于目标，成功返回且**绝不写 Flash**；
3. 克隆原块，只修改 `byte[13]`；
4. 打开配置会话；
5. 写入完整 15 字节；
6. 无论成败均 best-effort 关闭会话；
7. 再次读取 15 字节；
8. 仅当读回 `byte[13]` 与目标一致时报告成功。

写超时属于“结果不确定”：必须先读回再决定是否重试，禁止盲目重复写入。
绝不从默认模板重建整个设置块，绝不修改未知字节。

## 7. 会话命令会话语义 `inferred`（待真机验收复核）

- 会话 open/close 的请求体按 1 字节标记（`0x01`/`0x02`）发送；
- BLE 上不等待通知即视为已发送。

## 8. 测试向量（脱敏、手工构造）

构造向量仅覆盖帧结构，不含真实设备数据：

```text
# USB 读请求（0x1a, offset 0, length 3）
04 | cksum_le(2) | 1a 03 0000 00 | 00*56
# BLE 读请求（0x05, offset 0, length 15）
ee 05 0f 0000 | 00*15
# 状态数据
flag=02, rpm_raw=0x1FF4 → rpm = 0x1FF4 >> 2 = 2045
```
