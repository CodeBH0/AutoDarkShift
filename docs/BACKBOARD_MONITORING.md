# App 内 BackBoard 纯轮询（1.1.0 / build 2）

当前 App 路径使用 1.0.3 / build 2（`a7015e5`）的 `BKSDisplayBrightnessGetCurrent` getter；Packet Tunnel 继续使用 `UIScreen` 事件加轮询，不接入 BackBoard。两条路径固定进程、严格互斥，共用 `SwitchMonitor`、MathModel v2、通知逻辑和完整 Boost。当前最低 iOS 17，已移除 `UIScreen.BrightnessDidChangeMessage` 输入及其 iOS 26 限制。

## 读取与加载边界

`BackBoardBrightnessProbe` 使用 `dlopen(..., RTLD_NOW)` 加载 `/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices`，以 `dlsym` 查找 `BKSDisplayBrightnessGetCurrent`，调用类型为 `@convention(c) () -> Float`。解析结果保留，读取期间不卸载 handle。此私有接口在实际设备是否可用、后台值是否及时、锁屏行为均须实测；加载成功不能证明返回值新鲜。

只有选择 App 路径才 lazy 加载并预检 getter。未选择时不加载框架、不创建 App 采样实例；符号或框架不可用时明确返回实际错误，不生成样本或心跳，不以 `UIScreen` 回退。采样和诊断均不读取 UIKit 亮度作对照。NaN、无穷和越界值进入既有非法输入处理，不裁剪成合法亮度。

这是纯读取函数，没有亮度订阅。`BackBoardBrightnessSampler` 使用 `DispatchPollingScheduler` 等待，在 MainActor 读取并提交模型；initial / wake 从新基线开始，后续来源为 poll，无 event。常规 1 Hz，按 v2 统一一秒速度窗动态选择 10 / 30 / 60 / 120 Hz。停止、睡眠、重新安装和变频作废旧调度代次，不补发错过的读数。调度 tick 不等于实际 getter 调用，更不等于值新鲜。

## 固定进程、互斥与后台许可

`MonitoringHostCoordinator(process: .app, ...)` 固定承载 App 路径；VPN 的连接 / 断开不迁移该实例。PiP 或 Location 的实际 active / reasserting 才给予 App 后台执行许可，VPN 本身不给 App 此许可。没有已确认 App 保活时，进入后台 sleep 并取消采样；回前台或许可恢复后 wake。两种 App 保活同开也只运行一个采样实例。

`ExclusiveMonitoringBusiness` 先保存两路关闭配置，确认旧采样停止并等待已交给系统的通知结算，再启用目标。失败或超时不能视为已经停止，不能启动另一条路径。Packet Tunnel 未连接时只保存选择等待，不启动 App fallback。每次选择将最新 `initialConfiguration` 持久化到 VPN profile，避免系统重新拉起 Provider 时恢复旧启用状态。

App 使用私有 `BackBoardMonitoring` 目录，可复用 1.0.3 / build 2 已有配置、成功历史及双日志。无既有配置时默认关闭；不迁移旧消息业务启用值为 BackBoard 启用。旧 `MessageMonitoring` 和 `LocalMonitoring` 仅只读导出历史日志，不创建采样器。切换路径后重新建立模型基线，不把停采样期间的变化算作连续趋势。

## 完整日志与判读

两路分别保留运行日志和 Boost，导出保留来源、实例及原始时间。BackBoard 记录使用 `scope=backboard_monitor`、`business=backboard`、`samplingMode=backboard_poll_only`、`api=BKSDisplayBrightnessGetCurrent` 标识；历史 message / app scope 只代表旧记录。

| 证据 | 含义 |
| --- | --- |
| `backboard_api_load` | 实际框架 / 符号解析结果及加载错误，不能证明读数新鲜 |
| `backboard_sampler_started/stopped` | 采样生命周期与 generation，无亮度观察者 |
| `poll_tick` | worker 等待已触发，不自行生成亮度输入或心跳 |
| `backboard_brightness_sample` | 实际 getter 结果、valid、来源、时间及累计读取数；无 UIKit 比较值 |
| `backboard_read_unavailable` | 无可用 getter 返回值，不创建替代样本 |
| `sample/trend_score/notification_*` | 已进入共用业务的真实输入、评分、候选及系统提交结果 |

App 重新启用完整 Boost：保存触发前真实五秒上下文、触发后每次输入、评分与必要状态；恢复 1 Hz 不结束，连续两秒波动不超过 0.005 才完整结束。生命周期中断记录部分 trace，缺失执行期间不补造输入。按秒节流的诊断条数不代表读取频率，使用实际计数、时间和 Boost 输入判读。

缺少后台行只能说明没有执行证据，不能直接断言 getter 缓存。取得调用但数值没有随已记录的物理操作变化，才可记录读数新鲜度疑问。通知成功仅表示系统接受；通知展示与外部外观切换分别评价。

## 当前交付与验收

BKS 输入建立于 **1.1.0 / build 2**；build 3 起恢复正常递增，并默认关闭运行 / Boost 记录。需要日志时，先在信息页开启开发者模式，再在高级功能的通知与统计页开启记录。构建 / 回归 / 未签名 IPA 的实际范围见 [STATIC_VALIDATION.md](STATIC_VALIDATION.md) 与 [IPA_SIGNING.md](IPA_SIGNING.md)。不以历史 1.0.3 / build 2 的打包或读数结论替代当前结果。

按 [DEVICE_ACCEPTANCE.md](DEVICE_ACCEPTANCE.md) 的当前专项，分别验证前台、仅 PiP、仅 Location、无 App 保活、VPN 同开以及快速切路径和系统重连。记录真实调亮度时间、getter 调用及值、S、通知接受、实际展示和外观。本版本全部设备专项待实测，不以编译或模拟输入填写通过。
