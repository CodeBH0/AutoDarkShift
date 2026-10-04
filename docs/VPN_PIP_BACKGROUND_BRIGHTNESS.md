# VPN 与 PiP 后台亮度监听差异分析

分析日期：2026-10-04。当前源码基线：`8bf990d`，App 1.0.1 / build 17。设备日志报告系统版本为 iOS 27.0。

本文回应“VPN 方案能执行，PiP 已开启却没有在后台亮度变化时发送通知”的反馈。依据现有源码、最新 PiP 日志及两份历史 VPN 日志，区分已确认事实、合理推断和仍需验证的问题。本轮仅新增本文，不修改源码、不加入私有亮度接口、不重新打包；build 17 IPA 保持原样。

## 1. 当前能回答到什么程度

**VPN 与 PiP 的主要架构差别是监听所在的进程和生命周期。VPN 把监听放在系统管理的 Packet Tunnel 扩展中；PiP 让主 App 在后台承载监听。PiP 浮窗处于 active，并不会把后台 App 的 UIKit 场景变成前台，也不会额外赋予读取全局亮度的能力。**

但最新日志已经证明：PiP 系统启动成功，状态传播及后台执行许可正常，后台既有调度 tick，也有 MainActor 实际亮度读取。因此，这次不能解释为“PiP 不具备任何保活效果”或“监听根本没有运行”。当前问题更准确地表述为：**后台监听在执行，但读取到的亮度、模型触发条件与用户观察到的实际调节没有建立可靠对应。**

后台读数保持不变、部分读数变化集中在离开 background 后，这一模式使“后台 UIKit 亮度输入未及时更新”成为优先疑点。不过，日志没有记录用户实际调亮度的准确时刻，尚不能证明 UIKit 内部使用了某种缓存，也不能证明 VPN 始终能读到新鲜亮度。Apple 对 PiP 的说明描述的是媒体或视频通话的多任务能力，并未承诺任意后台业务或亮度读取的行为。[Apple：视频通话 PiP](https://developer.apple.com/documentation/avkit/adopting-picture-in-picture-for-video-calls)

## 2. 两种方案实际运行在哪里

| 比较项 | VPN 方案 | PiP 方案 |
| --- | --- | --- |
| 监听宿主 | `PacketTunnel.appex` 扩展进程 | 主 App 进程 |
| 系统入口 | `NEPacketTunnelProvider.startTunnel` | PiP delegate / AVKit 系统状态 |
| 监听初始化 | `PacketTunnelProvider` 创建自己的 `SwitchMonitor` | `AppComposition` 创建 App 内 `SwitchMonitor` |
| 主 App 进入后台 | 不直接让扩展监听 sleep；扩展响应自己的 Provider 生命周期 | AppController 根据前后台状态和保活 phase 决定 sleep / wake |
| build 17 轮询等待 | 保留主 RunLoop `Timer` | 独立队列上的 `DispatchSourceTimer` |
| 实际亮度读取 | MainActor 上的 `UIScreen.main.brightness` | 同样在 MainActor 上读取 `UIScreen.main.brightness` |
| 模型和通知 | 复用趋势模型、冷却、去重和通知输出实现 | 复用同一套实现 |

当前源码中的两条路径是：

```text
VPN 会话 → PacketTunnel 扩展进程
           → SwitchMonitor → ScreenBrightnessSampler → UIKit 亮度

PiP active → KeepAliveManager → AppController → MonitoringHostCoordinator
             → 主 App 的 SwitchMonitor → ScreenBrightnessSampler → UIKit 亮度
```

Apple 明确说明：启动使用 Packet Tunnel Provider 的 VPN 配置时，系统会启动扩展并在其中实例化 Provider。扩展有自己的生命周期，包含它的 App 不必保持运行。这使 VPN 监听有独立于主 App 场景的执行宿主；当前项目通过 Provider Message 或认证本机通信同步配置、状态与日志。[Apple：Packet tunnel provider](https://developer.apple.com/documentation/networkextension/packet-tunnel-provider)、[Apple：App Extension 架构](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html)

PiP 则仍然依托主 App。系统显示 PiP 内容时，主 App 的场景可以处于 background；窗口可见不代表 App 页面重新获得 active 场景。App 的后台执行受系统生命周期与具体后台能力管理。这里能确认的是两种执行上下文不同，不能由此直接推导出哪一种 `UIScreen` getter 一定更准确。[Apple：App 生命周期](https://developer.apple.com/documentation/uikit/managing-your-app-s-life-cycle)

项目实现依据：[宿主协调器](../Monitoring/MonitoringHostCoordinator.swift)、[App 组合入口](../App/AppComposition.swift)、[App 执行策略](../App/AppController.swift)、[VPN 扩展入口](../PacketTunnel/PacketTunnelProvider.swift)、[亮度采样器](../Platform/ScreenBrightnessSampler.swift)。VPN 和 PiP 同时开启时，当前策略优先选择 VPN 宿主；不能把这种运行中的成功通知直接归因于 PiP。

## 3. 最新 PiP 日志证明了哪些链路

输入文件：`local-data/device-logs/AutoDarkShift-runtime-6441CB55-BE30-42B5-BEAC-A41D8301197E.jsonl`。

元数据为 build 17、`keepAlive=pip`、`vpn=unavailable,pip=active,location=stopped`，监听宿主是“App 内监听”。本文时间表统一使用北京时间（UTC+8）；原始 JSONL 的 `Z` 时间为 UTC。

| 链路 | 日志证据 | 能确认的事实 |
| --- | --- | --- |
| PiP → 系统实际 active | 09:51:44.678 `pip_did_start`，`isPictureInPictureActive=true`、`didConfirmStart=true` | 系统已确认启动，状态不是仅由控制器创建推测 |
| PiP → KeepAliveManager | 09:51:44.684 `keepalive_pip_active` | Manager 收到了 active |
| Manager → AppController | 09:51:44.688 `app_execution_allowed`，`allowed=true` | App 内监听获准执行；此时 runtime 已是 running，不需要再强制 wake |
| App → 宿主与监听 | 三次进入 background 时均为 `allowed=true`、`pipPhase=active`、`runtimePhase=running` | 前后台切换没有撤销这段监听许可 |
| 等待 → 实际读取 | 严格 background 窗口内有 25 条 `poll_tick` 和 25 条 `brightness_sample`；tick 的 `readPending` 均为 false | worker 有触发，MainActor 也执行了读取，并非只有调度器在空转 |
| 读取 → 模型 | 有 `sample`、`trend_score`；第二段后台评分为 `S=-0.55` | 样本进入了监听与模型 |
| 候选 → 通知中心 | dark / light 各一次 `notification_result=success` | 两次通知请求被系统接受，但发生在 active / inactive 阶段 |

导出快照中 runtime 为 `.running`，`heartbeatAt` 与 `lastPollAt` 都是 09:52:53.858；计数为 373 次 poll、557 次样本、183 次事件回调、2 次通知尝试及 2 次成功。心跳由监听收到真实采样回调后更新，页面查询和 worker tick 不会生成心跳。这里的“真实采样”表示实际调用 getter，**不代表已验证 getter 数值等于当时的物理屏幕亮度**。

全文件有 65 条 `poll_tick`，其中只有 25 条落在严格 background 窗口，不能把 65 条全当作后台证据。常规 tick 和读取日志按秒节流，条数不是实际轮询次数或频率；应结合计数与 `activePollInterval` 判读。最后心跳发生在回到前台之后，也不能单凭它证明此前长期后台连续运行。

这些记录不支持将本次缺少预期通知归因于 active 没有传播、wake 没有安装轮询、MainActor 一直无法执行，或 PiP 启动阶段的 sleep → wake 竞态。它们只覆盖本次记录的短时测试，不构成无限期后台运行保证。

## 4. 为什么“有轮询”仍可能没有预期通知

### 4.1 后台执行与新鲜亮度是两个条件

按 AppController 的 `sceneState` 划分，从进入 background 到第一次离开 background，最新日志有以下三段：

| 北京时间窗口（2026-10-04） | tick / 读取日志条数 | 已记录的后台亮度 |
| --- | --- | --- |
| 09:51:47.519–09:51:59.788 | 7 / 7 | 约 0.560794，保持不变 |
| 09:52:04.687–09:52:27.496 | 13 / 13 | 约 0.308335，保持不变 |
| 09:52:32.272–09:52:39.333 | 5 / 5 | 约 0.308335，保持不变 |

第一段结束后，09:51:59.839 的 inactive 场景读到约 0.531999，随后读数继续下降；第三段结束后，09:52:39.378 产生 light 候选，对应的新亮度约为 0.507011。部分变化出现在离开严格后台后，符合“后台输入更新延迟”的怀疑。第二段回到 active 后仍有相同读数，因此也不能宣称“每次回前台都会立即刷新”。

如果用户确实在这些后台窗口内改变了亮度，而 getter 仍返回原值，轮询再频繁也只能反复把原值交给模型。调度器解决“何时执行读取”，不能改变“系统接口提供什么值”。目前缺少实际操作时间标记，所以这仍是待验证的输入问题，不是已经定位到某个 UIKit 缓存函数的结论。

### 4.2 模型不会在每次亮度变化时都发通知

当前模型 v2 只有 `S ≤ -0.50` 或 `S ≥ 0.50` 才请求对应目标，还需要通过成功历史去重、冷却及在途请求检查。第一段结束后读数开始变化时，最初评分约为 `-0.109`，尚未达到 dark 条件；09:52:01.015 评分到 `-0.520573` 才产生 dark 候选。该通知在 09:52:01.040 被系统接受，当时场景为 active。

第二段后台中，日志明确记录 `S=-0.55`、`scoredTarget=dark`、`lastSubmittedTarget=dark`、`pendingTarget=none`、`inFlight=none`。这时没有再次通知符合既有去重规则：最近成功提交的目标已经是 dark。这个窗口的“没有新通知”本身不能证明轮询或通知模块故障。

第三段结束后，09:52:39.378 产生 light 候选，09:52:39.431 返回 success。当时为 inactive，属于场景转换阶段，不能当成稳定 background 中成功提交的证明。日志中的 AppController 前后台许可和其他字段根据 UIKit applicationState 判断“不是 background”的含义不同；inactive 记录出现 `appForeground` 差异，也不能直接判作宿主许可竞态。

模型依据：[MathModel v2](models/MathModel-v2.md)、[通知状态机](../Shared/ThresholdStateMachine.swift)、[监听处理与诊断](../Monitoring/SwitchMonitor.swift)。

### 4.3 通知接受、通知显示、快捷指令执行也要分别看

本次两次授权结果均允许提交，通知结果没有 blocked / failed。项目中 success 表示通知中心接受了请求；它不确认横幅实际可见，也不确认外部快捷指令完成。如果用户指的是没有看到通知或没有切换外观，还需要与这两个 success 的时间分别对照，不能把所有现象统称为“没有发送”。[通知输出实现](../Platform/LocalModeNotificationSink.swift)

## 5. 历史 VPN 日志说明了什么

用户此前观察到 VPN 方案能工作，这一反馈应保留。日志中也存在 VPN 宿主收到亮度事件并提交成功通知的证据，但不支持“只要 VPN 保活成功，所有亮度变化就必然可读”。

| 历史输入 | 已确认结果 | 证据边界 |
| --- | --- | --- |
| build 12：`AutoDarkShift-AA6F65F6-4301-4AD8-89E4-E4D5B5B2B864.jsonl` | VPN 已连接；`provider_export_snapshot` 为 running；2404 次 poll、44 次事件回调、6 次通知成功；最后一次成功目标为 light | 没有逐次物理操作标记，不能把 6 次提交逐一对应到后台调节；这是模型 v1 的历史版本 |
| build 16：`AutoDarkShift-runtime-8AF01772-7C98-467A-90C8-882BA75A3B72.jsonl` | VPN active、宿主明确为 VPN 扩展；末次快照 457 次 poll / 458 次样本，心跳新鲜；314 条已记录 sample 均约为 0.55，事件回调与通知尝试均为 0 | 证明运行中也可以只有恒定输入；没有操作标记，不能据此认定当时发生的实际调节被漏读。该文件中的 PiP 启动失败属于另一阶段问题 |

这两份日志与最新 PiP 日志都报告 iOS 27.0，但 build、模型版本或采样调度实现并不完全相同，也不是同一条带操作时间标记的亮度轨迹。它们能支持“VPN 扩展可以独立持续监听，并且历史上曾收到事件和成功提交”，不能用作严格的 VPN / PiP 成功率对照。

因此，VPN 的执行优势可以用独立的系统服务宿主解释；VPN 的亮度读取可靠性仍需要设备条件下的证据。Network Extension 权限并不是 Apple 文档承诺的全局亮度访问权限。不能写成“VPN 直接读取硬件，而 PiP 只能读取缓存”，两者当前生产代码使用的是同一个 UIKit getter。

## 6. 公开接口能保证什么、不能保证什么

Apple 将 `UIScreen.brightness` 定义为主屏幕的 0–1 亮度属性，将 `brightnessDidChangeNotification` 定义为亮度变化通知。所查公开说明没有提供强制刷新亮度数据的接口，也没有说明后台 App 或 Packet Tunnel 扩展中的 getter / 事件在所有情况下都持续反映最新物理变化。[Apple：brightness](https://developer.apple.com/documentation/uikit/uiscreen/brightness)、[Apple：亮度变化通知](https://developer.apple.com/documentation/uikit/uiscreen/brightnessdidchangenotification)

项目已经将读取放在 MainActor，同时接入事件和轮询。MainActor 保证 UIKit 调用的线程约束，不保证数据新鲜；亮度事件也不是独立硬件数据源，其回调仍会再次读取同一个 getter。`DispatchSourceTimer` 只把轮询等待从主 RunLoop 分离，不能自行创造后台执行资格或刷新 UIKit 数据。

基于当前证据，继续重写 PiP source view、content controller 或轮询等待机制，没有明确理由能修复“调用正常但输入未变化”的问题。最新日志中来源高度为 44pt，未出现“一键 0.1pt”的应用记录，所以也没有依据把本次现象归因于 0.1pt。修改浮窗尺寸不会给亮度接口增加权限。

App Group 不可用后选择 `local-ipc-v1` 是现有存储回退；最新记录已确认 App 内读取与通知提交运行。`provider_logs_missing` 表示没有取得 Provider 日志，不足以推导 PiP 本地监听停止。本次分析不会为这些提示调整签名、存储或 VPN。

## 7. 当前判断与后续验证边界

| 判断 | 状态 |
| --- | --- |
| PiP 没有真正启动，所以后台链路未执行 | 与最新系统 active 回调及后台读取记录不符 |
| KeepAliveManager / 宿主协调丢失 active，造成监听一直 sleeping | 本次记录不支持；后台许可和 runtime 都正常 |
| Dispatch worker 触发，但 MainActor 没有执行读取 | 本次后台窗口同时有实际读取，不支持一直阻塞 |
| 后台 UIKit 读数未及时反映用户调节 | 优先疑点；需要实际操作时间对照才能确认 |
| 系统内部缓存或场景状态导致这种取值差异 | 尚未证实的机制解释，不能当作已知原因 |
| 第二段后台未重复发送 dark | 日志支持成功历史去重，是既有模型行为 |
| VPN 在同样条件下一定成功、PiP 一定失败 | 缺少同版本、同轨迹的对照证据 |

若之后继续定位，最有价值的验证是保持 build 17 和配置一致，分别只开 VPN、只开 PiP，在相同亮度轨迹上标记每次实际调节的时间，同时对照 `brightness_sample` / Provider `sample`、S、候选、授权、提交与设备实际表现。这样可以区分输入没有更新、模型没有达到新目标、通知已经提交但后续未展示或未联动。

本轮不执行上述新测试或实现。现有证据足以确认 PiP 已完成本次短时后台执行链路；尚未闭合的是“实际亮度调节 → 新鲜输入 → 新目标通知”的对应关系。私有系统亮度读取后备方案未接入。
