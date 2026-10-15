# 多方案保活（1.1.0：VPN / PiP / Location）

三种方案在“保活”Tab 可独立同时开启；VPN / Location 使用开关，PiP 使用“开启悬浮窗 / 关闭悬浮窗”和“一键0.1pt”按钮。某种方案失败或关闭不停止其他方案。`silentAudio` 仅保留枚举扩展位，没有注册服务、GUI 或实际音频播放。仪表中的 Auto Dark Shift 控制监听业务，关闭它不关闭保活；通知冷却、测试通知、统计与两路导出仍在原有二级功能页面。

## 平台适配

| 方案 | 使用方式和真实状态 | 后台载体 |
| --- | --- | --- |
| VPN | 首次准备系统配置，状态跟随 NEVPNConnection；维持既有最小隧道与网络策略 | PacketTunnel 进程 |
| PiP | 在前台点击“开启悬浮窗”，确认实际浮窗后拖到侧边，再点“一键0.1pt”；系统 didStart 且 active 为真后才显示运行中 | App 进程 |
| Location | 前台开启连续定位；Best 精度、无距离过滤、不自动暂停，显示后台定位指示；权限变化与暂停后恢复明确呈现 | App 进程 |

PiP 采用参考项目默认 VideoCall 的 PiP-only 分支：AVPictureInPictureVideoCallViewController + ContentSource，没有 AVPlayer / AVPlayerLayer、占位视频、静音 PCM 或动态显示。保留 GlobalRefresh 的两阶段流程：普通开启先恢复 300 × 44pt 的来源和 preferredContentSize，系统确认运行后才允许“一键0.1pt”将来源约束与 preferredContentSize 调为 300 × 0.1pt。停止再开总是恢复 44pt，不在启动前缩小；没有自定义高度菜单。系统实际浮窗尺寸仍由 iOS 管理，侧边吸附后缩小的实际效果需真机记录。

PiPSourceHost 通过透明、不拦截触摸的 UIKit 宿主覆盖在整个 TabView 上，独立于表单行和各 Tab。会话来源仅作为该宿主的子视图，保持到本次 PiP 会话结束；空白内容子视图在创建 ContentSource 前完成边缘约束和布局。首次请求前恢复表面可见属性、提交布局事务，检查来源已入窗、非空尺寸和 isPictureInPicturePossible；最多三次请求，只有系统没有进入启动过渡时才重试，8 秒内没有实际启动确认即失败，错误区分未入窗、空尺寸、系统不可启动及未确认启动。didStart 与实际 active 同时满足后发布运行中；缩到 0.1pt 后仍按实际 active 维持状态，不能因来源尺寸缩小或 possible 改变虚报停止。自动从 inline 启动仅在用户有开启意图时允许，停止时取消。

上一版 build 16 的设备日志中，四次来源均已入窗但 sourceBounds 为 300 × 0，未产生任何 pip_start_requested / willStart / didStart。0.1pt 约束在设备布局后成为零高度是实际证据；本次恢复参考流程的 44pt 开启阶段，不把 UI 后台状态当成浮窗已开启。音频是否混播不构成这次失败的充分解释，最后一次没有其他音频仍出现同样的空来源。

AVAudioSession 跟随参考项目 PiP-only 分支：释放媒体会话并设置 soloAmbient / default，不启动静音播放或主动保持 playback 会话。音频中断、路线变化和配置 / 释放错误记录实际结果。没有公开的音频 active 读回接口，日志中的 audioSessionAcknowledgement 表示调用结果。失败日志包含系统错误、possible / active / suspended、来源与内容尺寸、播放器 not_used、音频类别 / 模式 / 路线及过渡任务状态。

进入后台时只申请一次有限的过渡宽限任务，过期、回前台或停止时结束，不续租、不产生持续空转计时器。系统关闭、主动关闭和启动失败清理控制器、内容、来源、KVO / 通知观察者、停止确认任务与过渡任务。启动取消但系统不发 didStop 时，短暂等待后仅对已实际 inactive 的控制器完成清理；系统仍 active 时保持停止中并记录未确认，避免虚报已停止。主 App 的 UIBackgroundModes 保留 audio / location；此段为 PiP 生命周期说明。后台持续性仍需真机确认。

## Location 连续后台会话（1.0.2）

Location 从原先三公里精度 / 最大距离过滤改为 `kCLLocationAccuracyBest`、`kCLDistanceFilterNone` 和 `.fitness`，保留 `allowsBackgroundLocationUpdates=true`、`pausesLocationUpdatesAutomatically=false`，并显示系统后台定位指示。持续定位会增加耗电。全部坐标在 delegate 入口丢弃，不保存、上传或传给亮度模型。

请在前台开启并允许定位，再进入后台。使用期间授权可以延续前台已启动的连续定位；它不等同于始终授权，暂停或停止后不能从后台重新启动。授权升级只在 active 前台请求，不阻塞定位或其他保活。Allow Once 失效时取消定位更新并等待回前台授权；拒绝 / 系统关闭定位时结束本次会话，用户需要重新开启。暂停后若是始终授权或已回前台，则重新调用 startUpdatingLocation；室内暂时无定位等错误保留会话，收到真实回调后清除中断状态。

每次开启创建新的 CLLocationManager，所有异步 delegate 处理先核对 manager 身份及开启意图；关闭、失败或旧会话的迟到回调不能重新激活。进入后台申请一个有限的过渡任务，定位回调、回前台、停止、失败或系统过期时结束；每个任务有独立 token，不续租、不用定时器周期重启定位。进程被终止后的自动重启不属于本版本承诺。

`location_updates_started` 表示调用系统启动接口；`location_update_received` 才表示实际收到定位回调，每五秒最多写一条，updateCount 保留累计回调数。日志含会话、权限 / 精度权限、配置、应用状态、回调时间、位置记录时间 / 年龄和水平精度；不含经纬度。`location_updates_paused`、`location_updates_resumed`、`location_update_interrupted` 和有限任务的开始 / 结束 / 过期另外记录。最后一次回调、调度 tick、亮度样本与通知结果需要分别评价；不能从定位请求或某一条回调推断整个后台时段都连续执行。

## 通用抽象与监听宿主

`KeepAliveService`、`KeepAliveManager` 和每种方案的 `KeepAliveSwitchControl` 只依赖 Foundation，不引用 AutoDarkShift 模型、监听或存储。注册新方案时实现平台适配器并在 AppComposition 注册。状态回调由平台驱动，每种方案保存自己的待开启状态、错误及停止意图。

AppController 复用配置、权限、状态读取及日志服务；`ExclusiveMonitoringBusiness` 管理两条互斥监听路径。`MonitoringHostCoordinator` 必须显式指定 `.packetTunnel` 或 `.app`，固定进程，不根据 VPN 状态改变宿主。Packet Tunnel 路径仅由扩展内原采样器运行；未连接时保存选择等待，禁止 App fallback。App 路径只用 iOS 26 类型化亮度消息，不启动事件加轮询的旧本地实现。

PiP 与 Location 只为 App 路径提供后台执行许可，与 VPN 状态无关。二者同开只使用一个消息监听实例；前台允许执行，后台仅在至少一个平台状态实际为 active / reasserting 时允许。启动中、失败、停止中不给后台资格；最后一个 App 保活关闭后 sleep 取消消息观察并清空心跳，回前台或确认恢复后 wake。VPN 连接不能替代此许可，App 许可也不影响扩展执行。

切路径先保存两路禁用配置，确认停止采样并等待已提交系统通知的最终结果，再启用目标；未知或超时不能视为已停止。保活服务开关独立：选 App 时 VPN 可继续连接但扩展采样禁用；选 Packet Tunnel 时 PiP / Location 可继续运行但不创建 App 消息监听。每次选择将最新配置写入 VPN profile 的 `initialConfiguration`，local-ipc 系统重启 Provider 时优先应用它，避免恢复旧启用状态。

App 消息业务存储于私有 `MessageMonitoring`，旧 `LocalMonitoring` 仅用于历史双日志导出，不再采样。运行与 Boost 记录分别导出，保留实际来源、原始时间与旧 Provider 缓存。完整边界和关系图见 [ARCHITECTURE.md](ARCHITECTURE.md)。

## 历史后台监听诊断（1.0.x build 17）

以下是旧 App 事件加轮询路径的诊断背景，不描述 1.1.0 消息路径的生产调度。

PiP 主体、来源宿主、44pt 开启与 0.1pt 缩小流程沿用 build 16。本轮修复 App 执行许可与 runtime phase 的协调，并把 App 内轮询等待改为 DispatchSourceTimer；UIKit 亮度读取仍在 MainActor，VPN 调度不变。`.inactive` 不再直接触发监听睡眠，实际后台且没有确认保活时仍 sleep。

调度和读数日志按秒汇总：worker 的 poll_tick 与 MainActor 的 brightness_sample 独立，累计 count 含义不同，实际读取数仍以 runtime counters 为准。高频变档时会即时记录 scheduler stop/start，monitor_sampling_installed 的 observationGeneration 用于核对生命周期；变频只替换调度代次，不替换观察者。授权请求、授权结果、系统提交与完成均记录实际回调。详见设备验收第 13 节。

## 参考来源

- 1.0.2 参考用户本地提供的华中大体育砸壳包，运动页通过 MAMapView 允许后台定位；精确调用、未知项及本工程的独立选择见 [LOCATION_REFERENCE.md](LOCATION_REFERENCE.md)。

- PiP 生命周期与公开视频通话内容源参考 [Yoroin/GlobalRefresh-PiP](https://github.com/Yoroin/GlobalRefresh-PiP)，其 NOTICE 同时注明 [CaiWanFeng/PiP](https://github.com/CaiWanFeng/PiP)。当前适配器在本工程中独立实现，没有引入上游后台定时、播放器或高刷逻辑。
- 初版低精度后台定位策略参考 [truongkma/t-location](https://github.com/truongkma/t-location)。该仓库使用 AGPL-3.0；本工程未复制其源码，使用系统 CoreLocation 接口独立实现权限与生命周期。
- 平台接口依据 Apple 的 [视频通话 PiP](https://developer.apple.com/documentation/avkit/adopting-picture-in-picture-for-video-calls)、[PiP 内容源](https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller/contentsource-swift.class)、[后台定位许可](https://developer.apple.com/documentation/corelocation/cllocationmanager/allowsbackgroundlocationupdates)及[音频会话中断](https://developer.apple.com/documentation/avfaudio/avaudiosession/interruptionnotification)。

历史版本曾进行接口编译、独立开关与宿主交接回归；当前 1.1.0 实际本机结果见 [STATIC_VALIDATION.md](STATIC_VALIDATION.md)，不由历史结果推定。系统授权、PiP 可启动性、后台与锁屏调度由 [DEVICE_ACCEPTANCE.md](DEVICE_ACCEPTANCE.md) 的专项实机检查确认。
