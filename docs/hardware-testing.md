# 真机验收清单（docs/hardware-testing.md）

> CI 无法替代真机验收。每个正式版本候选都必须在**脱敏日志模式**下完成以下清单。
> 记录只包含：版本、平台、内核/BlueZ 版本、transport、测试项结果、匿名固件标识（如确有公开必要）。
> 不得包含 MAC、序列号、用户名、私有路径或协议来源。

## 1. Linux USB

- [ ] 非 root 发现目标 vendor interface（安装 udev 规则后）
- [ ] `f9ctl status` 连续读取 5 分钟无解析错误
- [ ] quiet → balanced → beast → quiet，逐次读回
- [ ] 重复设置当前挡位：Flash 写计数/总线观察确认无写
- [ ] 拔插恢复（monitor 模式观察重连）
- [ ] daemon 跑至少 30 分钟，阈值与滞回符合预期

## 2. Linux BLE

- [ ] 服务 UUID 发现（非地址）
- [ ] 写特征为 `1919...`、通知特征为 `1929...`（属性验证）
- [ ] status / 设置读取
- [ ] quiet → balanced → beast → quiet，逐次读回
- [ ] session open/close 不依赖通知
- [ ] 断连、重连、设备被占用时进入安全状态
- [ ] daemon 跑至少 30 分钟且不重复写

## 3. Turbo（可选，人工看护）

- [ ] 合适供电条件 + 人工看护下测试
- [ ] 若 RPM 未达预期平台：只记录硬件回退，不自动反复写 3
- [ ] 明确警告能力限制；前三挡回归不因 turbo 失败被误判

## 4. Windows USB（experimental）

- [ ] 发现 + status/mode 基础命令
- [ ] capability 标注 `experimental`；文档一致

## 5. 记录

结果写入 release checklist（内部），公开发布只保留 §0 规定的摘要字段。
