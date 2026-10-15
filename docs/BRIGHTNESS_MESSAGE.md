# 1.1.0：App 内类型化亮度消息监控

当前两条监听路径由业务管理器严格互斥：Packet Tunnel 固定在扩展进程，App 内监控固定在主进程；不再按 VPN 状态自动切换宿主。当前版本以 `Config/Project.xcconfig` 为准，实际本机构建结果见 [STATIC_VALIDATION.md](STATIC_VALIDATION.md)，设备结果见 [DEVICE_ACCEPTANCE.md](DEVICE_ACCEPTANCE.md)。

## 历史来源（1.0.3 / build 1）

1.0.3 以 `fdc9a55`（1.0.2 / build 18）为基线，回退 build 19 的主 App `windowScene.screen.brightness` 临时读取试验。用户反馈两个入口效果没有变化；历史分支 `codex/archive-window-scene-build19` 与已有产物保留。当时用户要求暂停本机编译，仅交接源码。该暂停及“未编译”结论只描述 1.0.3 当轮，不限制当前 1.1.0 的构建工作。

## 新业务

`App/ScreenBrightnessMessageSampler.swift` 直接注册 `UIScreen.BrightnessDidChangeMessage`，使用 `NotificationCenter.addObserver(of: nil, for: UIScreen.BrightnessDidChangeMessage.self)` 并按 `message.screen` 身份过滤目标屏幕。观察 token 保持至停止，停用时显式移除并作废旧回调代次。没有旧 `brightnessDidChangeNotification` 回退，也没有 Darwin 或私有 API。

新业务只接收类型化亮度消息，不启动轮询。注册后的初次读取及睡眠后唤醒读取只建立新观测基线；后续事件读取消息给出的 `screen.brightness`。消息提供屏幕对象，没有携带亮度数值；新接口不保证后台读数更及时，仍需实际调亮度对照。调用形式、消息属性与 token 生命周期依据 Apple 的 [消息文档](https://developer.apple.com/documentation/uikit/uiscreen/brightnessdidchangemessage)、[类型化观察接口](https://developer.apple.com/documentation/foundation/notificationcenter/addobserver%28of%3Afor%3Ausing%3A%29-56bn4)和 [ObservationToken](https://developer.apple.com/documentation/foundation/notificationcenter/observationtoken)。

数学模型与 UIKit 输入没有深度耦合，因此复用 MathModel v2、`SwitchMonitor` 的冷却、去重、取消与通知提交逻辑。`pollingEnabled: false` 时不报告有效轮询间隔，不执行模型建议的变频。间断超过两秒、非法输入、睡眠 / 唤醒及配置更新仍重置观测；消息稀疏时，下一个读数可能只重新建立基线。冷却后的再次判断需要新消息，不用定时读取补齐。原业务保留事件加动态轮询的行为。

App 路径由 `MonitoringHostCoordinator(process: .app, ...)` 承载，后台许可只来自实际 active / reasserting 的 Location 或 PiP，与 VPN 是否连接无关。VPN 保活不赋予 App 后台执行许可。原采样器仍只位于 `PacketTunnelProvider`，使用 `process: .packetTunnel`；VPN 未连接时只保存选择等待，不启动 App fallback。主 App 不再创建旧事件加轮询采样器。

## 互斥及诊断

仪表提供 Packet Tunnel 与 App 内监控两个互斥选择，开启一条会先停用另一条。`ExclusiveMonitoringBusiness` 串行处理选择：先将两份配置保存为关闭，确认停止采样并等待已提交通知的最终结果，再启用目标。未知或超时回复不能视为已经停止；停用未确认时不启用目标。失败后的关闭配置只表示保存的意图，界面保留错误，不宣称未确认的运行已经停止。

两个协调器必须显式指定固定进程；App 消息业务使用独立 `MessageMonitoring` 私有目录。旧 `LocalMonitoring` 仅保留历史运行 / Boost 导出，不再采样。两条业务分别保留配置、快照、成功历史、运行日志和 Boost 记录，共用界面中的通知冷却参数。启动时按保存选择恢复；若两份旧配置都为开启，先保存关闭标准业务，再执行严格交接。业务切换与 App 发起的 VPN 启停互斥；切换期间取消并等待此前自动查询，防止旧配置随后被重新应用。每次路径选择还将最新 `initialConfiguration` 保存到 VPN profile；local-ipc 下系统重启 Provider 优先读取该选择，避免恢复私有目录中的旧启用配置。

运行 / Boost 导出均包含两套记录，新业务带 `scope=message_monitor`、`business=message`、`samplingMode=typed_message_only`。状态查询和界面刷新不产生样本或心跳。亮度不变时没有消息属于正常可能性，界面显示观察者注册状态及最近实际样本，不用轮询心跳过期规则判断新业务失败。Boost 保留真实收到的输入；无消息时不补采样，也不能保证存在完整的五秒上下文或两秒稳定结束记录。

## 当前构建与交付

源码需要 Xcode 26 / iOS 26 SDK 或更新版本，Swift 5 语言模式、最低部署 iOS 17；类型化消息业务以 iOS 26 可用性检查隔离。纯 Foundation 回归不能替代主 App 与扩展的 iPhoneOS 编译。

常规打包使用已安装的 iPhoneOS SDK：

```sh
bash tools/package_ipa.sh --direct-sdk --unsigned
```

1.1.0 / build 1 首次指定打包使用 `--current-build`，仅在该版本 / build 未使用时允许：

```sh
bash tools/package_ipa.sh --direct-sdk --current-build --unsigned
```

`--unsigned` 保留 `CODE_SIGNING_ALLOWED=NO`，不执行 codesign 或添加本地 ad-hoc 签名。脚本仍核对主 App / 扩展版本并导出 `Signing/AutoDarkShift.entitlements` 与 `Signing/PacketTunnel.entitlements` 供重签参考。输出为 `build/AutoDarkShift-1.1.0-build1-unsigned.ipa` 及校验文件，构建记录在 `build/1.1.0/build1/`。后续常规打包自动递增编号；resign、unsigned 产物或已有 build 目录均阻止复用。默认不带 `--unsigned` 时保留原占位签名流程。

不安装或下载平台、模拟器。未签名包须使用自己的证书和匹配描述文件重签主 App 与扩展；能力与交付说明见 [IPA_SIGNING.md](IPA_SIGNING.md)。本机编译、源码检查、重签与真机验收分别记录，当前设备专项尚未执行，不能填写为通过。
