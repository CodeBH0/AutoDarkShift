# 多方案保活（VPN / PiP / Location）

三种方案在“保活”Tab 可独立同时开启；VPN / Location 使用开关，PiP 使用“开启悬浮窗 / 关闭悬浮窗”和“一键0.1pt”按钮。某种方案失败或关闭不停止其他方案。独立静音音频方案已取消。仪表中的 Auto Dark Shift 控制监听业务，关闭它不关闭保活；通知冷却、测试通知、统计与两路导出仍在原有二级功能页面。

## 平台适配

| 方案 | 使用方式和真实状态 | 后台载体 |
| --- | --- | --- |
| VPN | 首次准备系统配置，状态跟随 NEVPNConnection；维持既有最小隧道与网络策略 | PacketTunnel 进程 |
| PiP | 在前台点击“开启悬浮窗”，确认实际浮窗后拖到侧边，再点“一键0.1pt”；系统 didStart 且 active 为真后才显示运行中 | App 进程 |
| Location | 请求使用期间定位，再请求始终定位；三公里精度、最大距离过滤、不自动暂停；拒绝与更新中断明确呈现 | App 进程 |

PiP 采用参考项目默认 VideoCall 的 PiP-only 分支：AVPictureInPictureVideoCallViewController + ContentSource，没有 AVPlayer / AVPlayerLayer、占位视频、静音 PCM 或动态显示。保留 GlobalRefresh 的两阶段流程：普通开启先恢复 300 × 44pt 的来源和 preferredContentSize，系统确认运行后才允许“一键0.1pt”将来源约束与 preferredContentSize 调为 300 × 0.1pt。停止再开总是恢复 44pt，不在启动前缩小；没有自定义高度菜单。系统实际浮窗尺寸仍由 iOS 管理，侧边吸附后缩小的实际效果需真机记录。

PiPSourceHost 通过透明、不拦截触摸的 UIKit 宿主覆盖在整个 TabView 上，独立于表单行和各 Tab。会话来源仅作为该宿主的子视图，保持到本次 PiP 会话结束；空白内容子视图在创建 ContentSource 前完成边缘约束和布局。首次请求前恢复表面可见属性、提交布局事务，检查来源已入窗、非空尺寸和 isPictureInPicturePossible；最多三次请求，只有系统没有进入启动过渡时才重试，8 秒内没有实际启动确认即失败，错误区分未入窗、空尺寸、系统不可启动及未确认启动。didStart 与实际 active 同时满足后发布运行中；缩到 0.1pt 后仍按实际 active 维持状态，不能因来源尺寸缩小或 possible 改变虚报停止。自动从 inline 启动仅在用户有开启意图时允许，停止时取消。

上一版 build 16 的设备日志中，四次来源均已入窗但 sourceBounds 为 300 × 0，未产生任何 pip_start_requested / willStart / didStart。0.1pt 约束在设备布局后成为零高度是实际证据；本次恢复参考流程的 44pt 开启阶段，不把 UI 后台状态当成浮窗已开启。音频是否混播不构成这次失败的充分解释，最后一次没有其他音频仍出现同样的空来源。

AVAudioSession 跟随参考项目 PiP-only 分支：释放媒体会话并设置 soloAmbient / default，不启动静音播放或主动保持 playback 会话。音频中断、路线变化和配置 / 释放错误记录实际结果。没有公开的音频 active 读回接口，日志中的 audioSessionAcknowledgement 表示调用结果。失败日志包含系统错误、possible / active / suspended、来源与内容尺寸、播放器 not_used、音频类别 / 模式 / 路线及过渡任务状态。

进入后台时只申请一次有限的过渡宽限任务，过期、回前台或停止时结束，不续租、不产生持续空转计时器。系统关闭、主动关闭和启动失败清理控制器、内容、来源、KVO / 通知观察者、停止确认任务与过渡任务。启动取消但系统不发 didStop 时，短暂等待后仅对已实际 inactive 的控制器完成清理；系统仍 active 时保持停止中并记录未确认，避免虚报已停止。主 App 的 UIBackgroundModes 保留 audio / location；本轮不修改 Location。后台持续性仍需真机确认。

Location 丢弃全部坐标，不保存或上传位置。使用期间授权会显示后台持续性有限，不显示为始终授权；权限请求不会锁住其他保活开关。系统定位服务关闭、拒绝、暂停和恢复分别记录，不能从“已请求位置更新”推断任意后台时段都持续调度。

## 通用抽象与监听宿主

`KeepAliveService`、`KeepAliveManager` 和每种方案的 `KeepAliveSwitchControl` 只依赖 Foundation，不引用 AutoDarkShift 模型、监听或存储。注册新方案时实现平台适配器并在 AppComposition 注册。状态回调由平台驱动，每种方案保存自己的待开启状态、错误及停止意图。

AppController 复用既有配置、权限、统计、状态读取和日志服务；MonitoringHostCoordinator 负责业务宿主交接。VPN 正在连接、运行、重连或断开时选择扩展，其余时间选择 App 内监听。PiP 与 Location 同时运行共用一个 App 内监听实例。App 前台允许本地监听；后台仅在 PiP 或 Location 的平台状态实际为 active / reasserting 时允许。启动中、失败、停止中均不给 PiP 后台监听资格；最后一个 App 保活关闭后 sleep 取消采样并清除心跳，回前台或确认保活恢复后 wake。VPN 扩展不受此本地执行策略影响。

由 App 发起连接时，先等待本地监听停止及已提交通知结算，再启动 VPN。由 App 发起断开时，先让扩展停止采样、确认 stopped 并取回最新成功历史，再断开连接。历史按完成时间合并，不用旧数据回退。外部断开、强杀或控制通道无回复时，只保留实际取得的历史，不推断未知通知结果。详见 [ARCHITECTURE.md](ARCHITECTURE.md)。

App 内监听使用私有 LocalMonitoring 目录，与 ProviderRuntime / App Group 的日志独立。运行、Boost 分别导出，导出汇集对应的 App 内记录与已有 Provider 记录，保留 scope 与实例 ID；新宿主不会覆盖旧 Provider 缓存。

## 参考来源

- PiP 生命周期与公开视频通话内容源参考 [Yoroin/GlobalRefresh-PiP](https://github.com/Yoroin/GlobalRefresh-PiP)，其 NOTICE 同时注明 [CaiWanFeng/PiP](https://github.com/CaiWanFeng/PiP)。当前适配器在本工程中独立实现，没有引入上游后台定时、播放器或高刷逻辑。
- 低精度后台定位策略参考 [truongkma/t-location](https://github.com/truongkma/t-location)。该仓库使用 AGPL-3.0；本工程未复制其源码，使用系统 CoreLocation 接口独立实现权限与生命周期。
- 平台接口依据 Apple 的 [视频通话 PiP](https://developer.apple.com/documentation/avkit/adopting-picture-in-picture-for-video-calls)、[PiP 内容源](https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller/contentsource-swift.class)、[后台定位许可](https://developer.apple.com/documentation/corelocation/cllocationmanager/allowsbackgroundlocationupdates)及[音频会话中断](https://developer.apple.com/documentation/avfaudio/avaudiosession/interruptionnotification)。

本机验证涵盖接口编译、独立开关与宿主交接回归；系统授权、PiP 可启动性、后台与锁屏调度由 [DEVICE_ACCEPTANCE.md](DEVICE_ACCEPTANCE.md) 的专项实机检查确认。
