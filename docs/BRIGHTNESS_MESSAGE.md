# 1.0.3 / build 1：亮度消息业务与新环境构建

本轮以 `fdc9a55`（1.0.2 / build 18）为基线，回退 build 19 的主 App `windowScene.screen.brightness` 临时读取试验。用户反馈两个读取入口的效果没有变化。build 19 提交仍保存在本地分支 `codex/archive-window-scene-build19`，已有 IPA、校验文件和构建目录保留。

用户要求必须使用新 SDK，并暂停本机编译。本轮交付 **1.0.3 / build 1 源码**；没有编译或生成对应 IPA，也没有执行 Swift/core/XCTest。静态检查与源码审查不能替代新环境编译和真机验证。

## 新业务

`App/ScreenBrightnessMessageSampler.swift` 直接注册 `UIScreen.BrightnessDidChangeMessage`，使用 `NotificationCenter.addObserver(of: nil, for: UIScreen.BrightnessDidChangeMessage.self)` 并按 `message.screen` 身份过滤目标屏幕。观察 token 保持至停止，停用时显式移除并作废旧回调代次。没有旧 `brightnessDidChangeNotification` 回退，也没有 Darwin 或私有 API。

新业务只接收类型化亮度消息，不启动轮询。注册后的初次读取及睡眠后唤醒读取只建立新观测基线；后续事件读取消息给出的 `screen.brightness`。消息提供屏幕对象，没有携带亮度数值；新接口不保证后台读数更及时，仍需实际调亮度对照。调用形式、消息属性与 token 生命周期依据 Apple 的 [消息文档](https://developer.apple.com/documentation/uikit/uiscreen/brightnessdidchangemessage)、[类型化观察接口](https://developer.apple.com/documentation/foundation/notificationcenter/addobserver%28of%3Afor%3Ausing%3A%29-56bn4)和 [ObservationToken](https://developer.apple.com/documentation/foundation/notificationcenter/observationtoken)。

数学模型与 UIKit 输入没有深度耦合，因此复用 MathModel v2、`SwitchMonitor` 的冷却、去重、取消与通知提交逻辑。`pollingEnabled: false` 时不报告有效轮询间隔，不执行模型建议的变频。间断超过两秒、非法输入、睡眠 / 唤醒及配置更新仍重置观测；消息稀疏时，下一个读数可能只重新建立基线。冷却后的再次判断需要新消息，不用定时读取补齐。原业务保留事件加动态轮询的行为。

新业务仅由 App 进程承载，后台许可仍来自实际 active / reasserting 的 Location 或 PiP；VPN 保活本身不赋予 App 后台执行许可。原 VPN 采样器和 PacketTunnel 入口未换用新 API。

## 互斥及诊断

仪表提供“原监听”和“亮度消息监听”两个开关，开启一条会先停用另一条。`ExclusiveMonitoringBusiness` 串行处理选择：先将两份配置保存为关闭，确认停止采样并等待已提交通知的最终结果，再启用目标。未知或超时回复不能视为已经停止；停用未确认时不启用目标。失败后的关闭配置只表示保存的意图，界面保留错误，不宣称未确认的运行已经停止。

标准业务由原宿主协调器管理；新业务使用独立 `MessageMonitoring` 私有目录。两者分别保留配置、快照、成功历史、运行日志和 Boost 记录，共用界面中的通知冷却参数。启动时按保存选择恢复；若两份旧配置都为开启，先保存关闭标准业务，再执行严格交接。业务切换与 App 发起的 VPN 启停互斥；切换期间取消并等待此前自动查询，防止旧配置随后被重新应用。

运行 / Boost 导出均包含两套记录，新业务带 `scope=message_monitor`、`business=message`、`samplingMode=typed_message_only`。状态查询和界面刷新不产生样本或心跳。亮度不变时没有消息属于正常可能性，界面显示观察者注册状态及最近实际样本，不用轮询心跳过期规则判断新业务失败。Boost 保留真实收到的输入；无消息时不补采样，也不能保证存在完整的五秒上下文或两秒稳定结束记录。

## 迁移后构建

需要装有 iOS 26 SDK 的 Xcode 26 或更新版本；Apple 的 [Xcode 26 发布说明](https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes)列出了 iOS 26 SDK 和 Swift 6.2。工程仍使用 Swift 5 语言模式、最低部署 iOS 17；新业务以 `@available(iOS 26.0, *)` 隔离，旧系统只能使用原业务。源码含新 SDK 类型，旧 Xcode 无法编译整个主 App。

在新 Mac 解压源码，打开 `AutoDarkShift.xcodeproj` 可直接编译配置中的 **1.0.3 / build 1**。或者进入项目目录执行：

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
python3 tools/validate_project.py
git diff --check  # 仅 Git checkout 中执行；源码 ZIP 没有 .git
python3 tools/run_core_checks.py
swift test --scratch-path build/MessageTests --disable-sandbox
bash tools/package_ipa.sh --direct-sdk --current-build
```

核心检查和 XCTest 包含真实 localhost TCP，执行环境须允许监听与连接。新接口的 UIKit 编译不由纯 Foundation 测试覆盖，必须完成 App / 扩展的 iPhoneOS 构建。

`--current-build` 仅用于本次已指定的 build 1 首次打包；已存在相同版本 / build 的输出则拒绝复用。随后常规运行 `bash tools/package_ipa.sh --direct-sdk` 会递增 build；失败的实际构建也保留编号。构建目录改为 `build/1.0.3/build1/`，不覆盖旧 `build/build18/` 等目录。成功后应生成：

- `build/AutoDarkShift-1.0.3-build1-resign.ipa`
- 对应 `.ipa.sha256` 校验文件
- `build/1.0.3/build1/unsigned-build.log` 和 `Signing/` 权限文件

打包只使用本地占位签名，主 App 和扩展仍需在手机侧重签；能力和标识符要求见 [IPA_SIGNING.md](IPA_SIGNING.md)。未安装或要求安装 iOS 虚拟机、模拟器。真机验收按 [DEVICE_ACCEPTANCE.md](DEVICE_ACCEPTANCE.md) 的亮度消息业务章节记录。
