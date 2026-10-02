# AutoDarkShift

iOS 17+ 亮度自动切换验证工程。主 App 管理保活、通知权限和配置；当前仍由 VPN 的 Packet Tunnel 进程运行独立切换监听模块，读取亮度并提交 `dark` / `light` 本地通知。外部快捷指令负责切换系统外观。

build 9 已将轮询率测试组件拆出并归档：Boost 档位、逐档测试入口、测试控制指令和频率统计均从当前运行代码移除。保留普通采样间隔、阈值监听和完整日志回传链路。测试版源码、说明、回归与 build 8 安装包见 [轮询率测试归档](archive/polling-rate-test-build8-2026-10-02/README.md)。

Provider Message 不可用时使用仅本机的认证 TCP 通道，扩展日志分块取回并持久化到 App，关闭 VPN 后仍能导出已同步记录。具体链路见 [LOG_TRANSPORT.md](docs/LOG_TRANSPORT.md)。旧测试结果文件只读保留并继续支持导出；旧配置中的 Boost 与未完成测试状态不会恢复，采样使用保存的 `pollInterval`。

build 6 根据日志与实际使用反馈调整状态判定：保活连接与运行详情读取分别显示，查询无回复或超时归为“暂不可读取”，不要求重装或断言监听停止。配置已保存但没有确认时，明确提示重新开启保活可使用新参数。继续保留 build 5 的单个保活开关和共享/本地两种存储模式。保活与监听仍分层，仅参考 GlobalRefresh-PiP 的生命周期接口，**未切换到 PiP**。详见 [日志分析与修复](docs/LOG_REPAIR.md) 和 [架构与后续 PiP 接入边界](docs/ARCHITECTURE.md)。原始开发要求见 [WORK_VPN_BRIGHTNESS.md](WORK_VPN_BRIGHTNESS.md)，具体状态提示和验收标准以最新说明为准。

**入口：直接用 Xcode 打开 `AutoDarkShift.xcodeproj`，选择共享 Scheme `AutoDarkShift`。没有第三方依赖，也不需要先生成工程。**

这是需要真机确认可行性的实验工程。公开文档没有保证 Packet Tunnel 进程中的 `UIScreen.main.brightness` 能持续反映物理屏幕亮度，也没有保证该进程能收到亮度事件。零值合法，不能仅凭零值判断 API 失败；需与实际手动调整对照。工程不会把主 App 的亮度缓存当成扩展读数，也不会为了让系统接受隧道而添加默认捕获路由。

## 当前验证状态

本轮使用完整 Xcode 16.2 / iOS 18.2 SDK 验证。build 5 的设备日志已记录约 44 分钟的连接区间，用户反馈功能正常；本机没有取得扩展运行详情，不能据此填写逐次采样和即时配置应用的结论。用户已确认轮询率测试完成；测试功能已归档。本轮验证当前 build 9 的组件拆除与普通日志链路，未执行 build 9 真机安装。

| 项目 | 状态 |
| --- | --- |
| 工程、plist、签名配置、共享 Scheme、模块边界静态检查 | 通过 |
| 生产 Foundation 核心的直接编译与 41 项运行时/通信/存储/开关回归场景 | 通过 |
| 生产源码与回归测试编译 | 通过 |
| Swift Package XCTest | 通过：20 个阈值测试 + 包装 41 项回归场景的测试，0 失败 |
| Xcode iPhone arm64 Release 编译、链接、归档和待重签 IPA 打包 | 通过，版本 1.0.0 / build 9，最低 iOS 17 |
| build 9 真实证书签名、安装与设备行为 | 未执行 |

详细命令和范围见 [docs/STATIC_VALIDATION.md](docs/STATIC_VALIDATION.md)。编译和测试通过不能替代重签后设备上的 VPN、真实亮度与后台验收。

## 签名与安装

1. 在 Mac 上安装支持目标 iPhone 系统版本的 Xcode；源码使用 Swift 5 模式，最低要求为 Xcode 15 / iOS 17 SDK。
2. 将 `Config/Local.xcconfig.example` 复制为 `Config/Local.xcconfig`，填写自己的 Team ID、唯一的主 App Bundle ID 和注册的 App Group ID。也可直接修改 `Config/Project.xcconfig`。
3. 扩展 Bundle ID 默认是 `$(APP_BUNDLE_ID).PacketTunnel`，须以主 App Bundle ID 为前缀。两个 Target 使用同一开发团队，签名必须支持 Network Extensions。工程默认请求相同的 App Group；签名不提供该能力时，可移除两个组件的 App Group entitlement，运行时会使用 `local-ipc-v1`。不要把个人证书或 provisioning profile 放入源码目录。
4. 用 Xcode 打开工程，在 **AutoDarkShift** 与 **PacketTunnel** 两个 Target 的 Signing & Capabilities 中确认 **Automatically manage signing**、同一 Team，以及 **Network Extensions → Packet Tunnel**。若保留 **App Groups**，注册并在两个组件中使用与配置文件一致的分组。
5. 连接并信任 iPhone，开启设备 Developer Mode。选择 `AutoDarkShift` Scheme 和该 iPhone，执行 Product → Run。若签名失败，先确认团队权限、两个显式 App ID 的能力和 App Group 注册情况；文件里写 entitlement 本身不会赋予账号权限。
6. 真机后台验收：Product → Scheme → Edit Scheme → Run，取消 **Debug executable** 后安装并启动；或 Product → Archive → Organizer → Distribute App，选择团队可用的 Development / Ad Hoc 分发方式安装。关闭 Xcode 调试会话，从桌面重新打开 App。记录具体安装方式，不以调试器连接状态下的数据替代后台验收。

`Config/Local.xcconfig` 已列入忽略规则；工程没有个人团队 ID、证书、凭据或远程服务器配置。App 与扩展的版本号和 build number 统一继承 `Config/Project.xcconfig`。

如需在 iPhone 上使用 p12 重新签名，可运行 `bash tools/package_ipa.sh` 生成 `build/AutoDarkShift-1.0.0-build9-resign.ipa`。该包仅有携带权限的本地占位签名，需用自己的证书和匹配的描述文件重签主 App 与扩展。标识符、App Group 同步要求及实际验证范围见 [IPA 重签说明](docs/IPA_SIGNING.md)。

## 构建与纯逻辑测试

完整 Xcode 环境可在项目根目录执行以下构建 / XCTest 命令。本轮已完成 Swift Package XCTest、iPhone Release 归档和 IPA 打包；真机验收仍未执行：

```sh
# 编译主 App 及嵌入的扩展；模拟器构建不验证真机 VPN 能力。
xcodebuild -project AutoDarkShift.xcodeproj -scheme AutoDarkShift \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

# 查找实际可用的模拟器，再替换下条命令的 name。
xcodebuild -project AutoDarkShift.xcodeproj -scheme AutoDarkShiftCore -showdestinations
xcodebuild -project AutoDarkShift.xcodeproj -scheme AutoDarkShiftCore \
  -destination 'platform=iOS Simulator,name=iPhone 15' CODE_SIGNING_ALLOWED=NO test

# 状态机及运行时回归也可由 Swift Package 运行；不依赖 UIKit 或 iOS SDK。
swift test

# 真机归档；需要先填写签名配置。
xcodebuild -project AutoDarkShift.xcodeproj -scheme AutoDarkShift \
  -destination 'generic/platform=iOS' -archivePath build/AutoDarkShift.xcarchive \
  -allowProvisioningUpdates archive
```

在 Xcode 内也可选择 `AutoDarkShiftCore` Scheme 后 Product → Test。该 Scheme 仅构建纯逻辑测试 Target；`AutoDarkShift` Scheme 同时提供 App 构建、运行、归档和测试。测试 Target 与 Swift Package 均编译 `Shared/` 和 `Monitoring/` 中的同一份生产实现，不编译 UIKit、VPN 或 PiP 宿主。

`Tests/ThresholdStateMachineTests.swift` 覆盖阈值等号边界、0 和 1、中间区间、稳定计时重置、同一目标去重、相反切换、冷却结束重新确认、失败重试、历史恢复、非法亮度、在途请求、配置更新和睡眠重置。`RuntimeRegressionTests.swift` 包装 41 项运行时、消息通道、存储、配置同步、跨进程错误、保活开关及状态读取分类/重试回归场景，使用注入的采样、通知和存储接口。

无需 XCTest 的核心检查也使用同一批回归场景和生产文件：

```sh
python3 tools/run_core_checks.py
# 仅在 CLT 中同时出现两个 SwiftBridging modulemap 时使用；不修改系统工具链。
python3 tools/run_core_checks.py --isolate-clt-headers
```

## 使用

1. 打开 App，点击“请求通知权限”，查看授权结果；已拒绝时可到系统设置重新授权。
2. 按需编辑参数，点击“保存并应用配置”。默认深色阈值 `0.20`、浅色阈值 `0.28`、采样间隔 `1 秒`、稳定时间 `1 秒`、通知冷却 `3 秒`。
3. 打开“保活”开关，首次开启时自动准备配置并请求系统 VPN 确认；关闭开关停止 VPN。准备和连接/断开期间禁止重复操作；启动失败、系统断开或从系统设置关闭 VPN 时，开关回到关闭。VPN 适配器根据 `NEVPNConnection.status` 更新真实保活状态，重新启用已禁用的旧配置并更新存储/协议元数据。
4. 若取得新鲜且身份匹配的快照，会显示“监听正在采样（心跳有效）”；若查询无回复或超时，显示“保活已连接，实时状态暂不可读取”。后者属于观测信息缺失，不据此认定监听停止，也不伪造正在采样。握手仍核对协议版本、Bundle ID、build、App Group 和存储模式，心跳参考阈值为 `max(5 秒, 当前生效轮询间隔 × 3)`。
5. 运行期间保存参数会先原子保存配置，再发送 `reloadConfiguration` Provider Message；本地通信模式携带完整配置。只有返回实际应用的 revision 才显示确认。无回复或超时则显示“配置已保存；本次运行是否已应用尚未确认，重新开启保活会使用新配置”，保留现有运行，不自动重启。参数非法、明确拒绝、身份不兼容或坏回复仍显示错误。每次消息最多两次尝试，单次超时 2 秒、间隔 0.2 秒；自动状态查询在连续无回复时按 30/60/120/300 秒退避，手动查询仍可立即进行。查询不会产生采样或心跳。
6. 用“发送测试通知”检查权限与前台横幅，测试标题是 `AutoDarkShift.Test`，不修改正常目标历史或扩展通知计数。
7. 用“导出运行日志”打开标准系统分享界面，保存 JSONL 文件。共享模式可直接导出监听日志；本地模式在 VPN 运行时通过系统消息或认证本机通道取回扩展日志，分块校验后原子保存到 App。关闭保活后仍可导出已同步记录；未同步的私有文件需重新开启保活后取回。缓存保留原采样时间。导出会保留实际取得的记录和失败标记。

当前界面只提供普通采样间隔设置，默认仍为 1 秒。升级时忽略旧配置的 Boost 档位，并使用原来保存的普通采样间隔；旧测试状态不会继续执行。归档版本可独立复现旧测试。

阈值满足时间按观测到的样本计时，精度受采样间隔和系统调度影响。采样停顿超过 `max(2 秒, 当前生效轮询间隔 × 2)` 会记录 `sampling_gap` 并重新开始稳定计时。睡眠、唤醒和配置更新也会重置稳定计时。不得将轮询日志解释为系统亮度事件。

## 隧道和通知行为

`PacketTunnel/PacketTunnelProvider.swift` 使用 `127.0.0.1` 作为本地隧道地址标记，设置 `198.18.0.1/32` 虚拟接口，IPv4 included / excluded routes 均为空；不设置 IPv6、DNS、代理，不连接远程服务器。主 App 显式关闭 `includeAllNetworks` 和 `enforceRoutes`。目标是让常规联网保持系统原有路径，是否被系统接受必须通过真机验收。

网络设置应用成功、观察者和定时器初始化完成、初次状态写入完成后才返回启动成功。若系统拒绝该最小配置，扩展保留具体 domain、code、description 和 userInfo，返回原始错误并清理资源；不会自动捕获全部流量。停止时取消定时器、移除观察者，清空心跳；已发出的通知提交回调会先记录结果再完成停止。异常强制终止仍可能来不及保存最后一次结果。

亮度事件使用 `UIScreen.brightnessDidChangeNotification`，轮询独立读取 `UIScreen.main.brightness`；均在扩展主线程执行。来源分别为 `event`、`poll`，启动和唤醒立即采样标记为 `initial`、`wake`。非法输入在状态中设为无有效数值，`rawValue` 和错误日志保留原始结果。

正常通知示例：

```text
标题：AutoDarkShift.Mode
副标题：dark
正文：mode=dark;brightness=0.183;source=event
```

每次请求使用新的 UUID；正文亮度按三位小数格式化，日志保留实际读数。授权不足时继续采样，结果为 `blocked`；`add` 返回错误为 `failed`；无错误为 `success`，仅表示系统接受请求。通知可能被专注模式、摘要或用户的横幅设置影响。只有成功提交会更新去重历史；失败或权限不足按冷却间隔重试，每次重试需要新的合格样本。同一时刻最多一个请求在途。

中间区间保留既有目标，不产生通知，并清空本轮稳定计时。冷却期间合格目标保留为 `pendingTarget`，冷却结束后由新样本确认；离开条件就不能继续提交旧候选。重启从成功历史恢复去重和冷却，历史代表最近提交的请求，并非系统当前外观。

## 状态、日志和诊断

协议版本为 3，App 与扩展显式协商存储模式：

| 模式 | 配置与状态 |
| --- | --- |
| `app-group-v1` | App Group 可读写时使用同一容器；扩展写快照、历史和监听日志，App 读取 |
| `local-ipc-v1` | App Group 不可用时，App 的 `AppRuntime` 与扩展的 `ProviderRuntime` 各自持久化；通过启动参数和 Provider Message 同步配置，App 查询真实扩展快照并缓存 |

本地通信模式下，扩展保留成功提交历史，系统重新拉起时使用扩展保存的配置；由 App 开启时携带当前保存的配置。App 不采样、不生成心跳、不将自己的文件视作跨进程共享数据。导出 `scope=app_runtime_cache` 与共享模式的 `scope=shared_runtime` 有明确区分。

Provider Message 无回复时，首次故障增加即时回显探针并自动切换认证的 127.0.0.1 通道。控制与日志页串行发送，具体结构及设备验证见 [LOG_TRANSPORT.md](docs/LOG_TRANSPORT.md)。

各存储目录中的文件包括：

| 文件 | 含义 |
| --- | --- |
| `configuration.json` | 保存的参数和 revision；本地模式扩展通过消息保存自己的副本 |
| `status.json` | 扩展运行快照；本地模式 App 文件仅是查询回复的缓存 |
| `submission-history.json` | 最近成功提交目标及完成时间，独立于运行快照持久化 |
| `runtime-0.jsonl` 至 `runtime-3.jsonl` | 当前日志及三份轮转日志，每份最多 256 KiB，总计最多 1 MiB |
| `polling-results-0.jsonl`、`polling-results-1.jsonl` | build 7/8 遗留测试结果，只读保留并随日志导出；当前版本不再创建或追加 |
| `provider-diagnostics.jsonl` | App 保存的完整扩展日志副本，关闭 VPN 后可导出已同步记录 |
| `store.lock` | 目录读写锁；共享模式下两个进程共同使用 |

读写统一经过跨进程锁；JSON 快照采用原子替换。导出在共享读锁下复制日志和快照，不读取正在追加的半条记录；异常终止造成的日志末尾残片在下次追加前截断。导出副本包含设备通用型号、系统版本、App 版本与 build number。准确设备型号、调试器状态由测试者补录。时间戳为包含毫秒的 UTC ISO-8601 字符串。

每个样本在内存评估阈值。普通采样间隔小于 1 秒时，常规采样日志与快照约每秒写入，通知结果等关键事件仍及时持久化；采样间隔不小于 1 秒时继续逐条记录。当前版本不计算测试统计或产生测试结果。

关键状态字段：`activePollInterval`、`phase`、`updatedAt`、`heartbeatAt`、`lastPollAt`、`lastPollInterval`、`sample.{brightness,rawValue,source,timestamp,sequence,actualInterval}`、`appliedConfiguration.revision`、`pendingTarget`、`stableSince`、`submission.{result,detail,identifier}`、`history.{target,submittedAt}`、`lastError`。

`counters.eventCallbacks` 只统计系统观察者实际回调；`polls` 只统计定时读取；`samples` 含 initial / wake / event / poll；`notificationAttempts` 只统计正常通知实际调用 `add`，被权限阻止不算提交；`notificationSuccesses` 是 `add` 接受数；`extensionStarts` 为初始化独立监听状态的启动尝试数（为兼容旧数据保留字段名）。计数从上次快照恢复，启动失败也可能增加启动次数。

监听日志包括 `monitor_start`、`monitor_ready`、`monitor_stop`、`monitor_sleep`、`monitor_wake`、`monitor_error`、`sample`、`sampling_gap`、`invalid_brightness`、`configuration_applied`、`configuration_error`、`candidate_changed`、`notification_submit` 和 `notification_result`。VPN 生命周期、消息收发与初始化错误写入 Provider 本地诊断；App 操作、握手错误和测试通知写入 App 本地诊断。运行中通过 `exportDiagnosticPage` 固定快照、分块回传并缓存，内容含最多 8 KiB 的 Provider 生命周期日志；本地通信模式再附加最多 24 KiB 的扩展监听日志和旧版本保留的测试结果文件。每条都有 `timestamp`、`instanceID`、`event` 和 `fields`。

如果 App Group 无法打开或读写探测失败，App 正常使用本地模式，日志记录 `storageFallbackReason`，并将选择写入 VPN 配置；该回退不是运行错误。若本地存储也失败，则明确报错。无回复/超时通过 `readbackAvailability=unavailable` 记录，不等同于服务 failed；身份不兼容、坏回复等仍保留错误。`ProjectError` 和通信错误通过 `NSError` 保留具体原因。无法从控制通道取回扩展诊断时，可用 macOS Console 连接设备，筛选 subsystem `AutoDarkShift` 查看系统日志。若持久化失败，扩展保留内存错误并在后续样本重试成功历史写入；失败跨重启时仍可能重复提交，需据错误字段验收。

轮转日志不会无限保留；后台验收建议分段记录实际触发与切换结果。本地通信模式只取回有界尾部，覆盖不足时无法评价逐次采样连续性，应记为不可观测，不将缺少日志本身判为功能失败。文件保护采用 `completeUntilFirstUserAuthentication`，设备重启后未首次解锁时仍可能无法访问状态。App 仅在前台刷新，独立监听不依赖主 App 查询结果；后台实际响应以设备观察评价。

## 真机验收与外部快捷指令

按照 [docs/DEVICE_ACCEPTANCE.md](docs/DEVICE_ACCEPTANCE.md) 逐项操作并填写记录。其中包含文档要求的八项检查、观察字段、判定依据，以及快捷指令的 dark / light 过滤操作。

外部自动化能力取决于设备系统和使用的监听工具。Apple 在 [WWDC26 的 Shortcuts 说明](https://developer.apple.com/videos/play/wwdc2026/310/)中展示了按 App 和关键词过滤的通知自动化；不要据此假定最低部署版本 iOS 17 也具有该触发器。先确认设备实际提供“收到 App 通知”触发器；没有时将外部联动记为能力缺失 / 未执行，不编造可用步骤。工程只发送标记通知，不调用私有 API 或宣称能确认快捷指令执行。

路由配置参考 [Apple 的 VPN 路由文档](https://developer.apple.com/documentation/networkextension/routing-your-vpn-network-traffic)，通知提交使用 [UNUserNotificationCenter](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter)。[TN3120](https://developer.apple.com/documentation/technotes/tn3120-expected-use-cases-for-network-extension-packet-tunnel-providers) 说明了 Packet Tunnel 的预期用途是网络隧道；本实验的亮度后台行为不属于该文档承诺的用途。

## 工程结构

```text
App/                  SwiftUI 控制页、协议驱动的控制器、当前后端组合入口
KeepAlive/            VPN 启停/偏好/状态与跨进程监听控制适配
PacketTunnel/         仅作为 VPN 运行载体并组合独立监听
Monitoring/           与保活无关的切换监听、控制端点、同进程客户端
Platform/             UIKit 亮度采样与 UserNotifications 输出
Shared/               服务接口、模型、阈值状态机、消息通道、存储与日志
Tests/                原始阈值 XCTest + 共享运行时/通信/存储回归场景
Config/               共用标识符、版本号、签名配置及本地覆盖示例
AutoDarkShift.xcodeproj/  可直接打开的工程及两个共享 Scheme
docs/                 架构、日志修复、验收操作表和实际验证记录
tools/                工程生成/静态检查与独立核心回归运行器
```

如需重建工程，可执行 `python3 tools/generate_xcode_project.py`。该脚本会覆盖工程和 Scheme；正常构建不需要运行它，手工修改工程后也不应未经确认重建。
