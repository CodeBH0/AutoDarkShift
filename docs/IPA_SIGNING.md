# iPhone 重签 IPA

已使用 Xcode 16.2 / iOS 18.2 SDK 直接编译 App target，构建 iPhone arm64 Release 版本，最低系统 iOS 17.0。未安装 iOS 平台或模拟器。产物包含主 App 和 `PlugIns/PacketTunnel.appex`，版本 1.0.1，build 15，通信协议 3。

2026-10-04 用户反馈 build 14 实机测试已通过。本轮新增 VPN / PiP / Location 三种可并行的保活方案、独立 Auto Dark Shift 开关与监听宿主交接。仪表、保活、信息采用系统底部 Tab Bar，各 Tab 为独立 View；当前状态显示监听频率、S、实际采样亮度及 App 可见外观。功能二级页面和运行 / Boost 独立导出沿用。静音音频方案已取消；平台说明见 [KEEP_ALIVE.md](KEEP_ALIVE.md)。

文件：`build/AutoDarkShift-1.0.1-build15-resign.ipa`。该包没有开发者证书签名或 provisioning profile；本地 ad-hoc 占位签名仅用于携带权限信息，不能直接安装。需要在 iPhone 的签名工具中使用你的 p12 证书和匹配的 `.mobileprovision` 描述文件重新签名。

## 签名时保留的内容

- 同时签名主 App 和 PacketTunnel 扩展，保留扩展。
- 两个组件的描述文件和最终签名都需要允许 `com.apple.developer.networking.networkextension = [packet-tunnel-provider]`。
- App Group 是可选共享模式。描述文件允许时，两个组件保留同一已注册分组；不允许时，在重签时移除两个组件的 `com.apple.security.application-groups`。App 无法访问共享容器后自动选择 `local-ipc-v1`，通过消息同步配置与状态。
- 当前主 App Bundle ID：`com.example.AutoDarkShift`。
- 当前扩展 Bundle ID：`com.example.AutoDarkShift.PacketTunnel`。
- 当前 App Group：`group.com.example.AutoDarkShift`。

这些是工程的默认标识符，不代表已在你的开发者账号中注册。p12 提供签名身份，描述文件决定允许的 App ID、权限和安装范围。请使用自己账号注册的标识符；保留共享能力时使用已注册的 App Group。具体要求参考 Apple 的 [Network Extensions 配置](https://developer.apple.com/documentation/xcode/configuring-network-extensions/)和 [Provisioning Profiles 说明](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)。本地通信只解决共享容器访问问题，不会赋予缺少的 VPN 签名权限。

如果签名工具修改 Bundle ID 或 App Group，还需要同步以下字段，避免 App 与扩展失配：

| 位置 | 字段 |
| --- | --- |
| 主 App `Info.plist` | `CFBundleIdentifier`、`PacketTunnelBundleIdentifier`、`AppGroupIdentifier` |
| 扩展 `Info.plist` | `CFBundleIdentifier`、`AppGroupIdentifier` |
| 主 App 和扩展的签名 entitlements | 保留共享能力时，`com.apple.security.application-groups` 使用相同、已注册的 App Group；无该能力时移除 |

扩展 Bundle ID 必须以主 App Bundle ID 加 `.` 为前缀。不能只修改主 App 的 Bundle ID 而保留旧的 `PacketTunnelBundleIdentifier`。本次展开的权限文件另存于 `build/build15/Signing/AutoDarkShift.entitlements` 和 `build/build15/Signing/PacketTunnel.entitlements`，便于签名工具手动配置。

如果签名工具不支持同步上述自定义字段，可先将自己的标识符写入 `Config/Local.xcconfig`，再运行打包脚本。构建无需把证书交给本机：

```sh
bash tools/package_ipa.sh --direct-sdk
```

`--direct-sdk` 显式使用已安装 iPhoneOS SDK 直接构建 Release target 和嵌入扩展，避开目的地查找，不安装平台或模拟器，不生成 Xcode archive。不带此参数仍沿用归档模式。

脚本优先使用 `DEVELOPER_DIR` 指定的 Xcode，其次使用系统已选择的完整 Xcode、`/Applications/Xcode.app` 或下载目录中的 Xcode。它不修改系统的 Xcode 选择，不读取证书，也不连接 Apple 账号。

每次执行会自动递增 `Config/Project.xcconfig` 中的 build 号，并将同一编号用于主 App 和扩展；失败的构建也保留该编号，不回退复用。归档、缓存、权限文件和编译日志保存在各自的 `build/build<编号>/`，IPA 与 SHA-256 文件名带 build 号，脚本拒绝覆盖已有产物。

## 验证范围

本机 61 项 core checks、43 个 XCTest 方法通过，0 失败；其中 34 项模型测试、8 项多保活 / 宿主交接测试及包装 61 项运行时 / 存储 / 通信场景的测试。包含独立同时开启、单方案失败、启动期间取消、通知完成后交接历史、无回复不启动重复宿主、禁用后恢复、旧配置兼容与两路日志保留。真实 localhost TCP 测试实际执行。

使用现有 iPhoneOS 18.2 SDK 构建 iPhone arm64 Release，主 App 与扩展均为 1.0.1 / build 15、最低 iOS 17。权限、版本、两种原生框架的 App target 边界、占位签名、ZIP 与 SHA-256 独立核对结果保存在 `build/build15/ipa-verification.json`。精确大小及校验值见 [STATIC_VALIDATION.md](STATIC_VALIDATION.md) 与 IPA 旁的 `.sha256` 文件。此前 10 份 IPA 校验值不变；按用户明确要求，最终源码直接覆盖本轮 build 15，临时 build 16 产物清理。标准打包脚本的默认递增策略未改变。本轮补充未确认开关状态提示与宿主变更时清除旧快照。

重签时保留主 App 的 audio / location 后台模式和定位用途文案；audio 用于 PiP，未实现静音音频。安装后停止再开启 VPN，使旧扩展退出并更新会话。先在保活页单独试用 PiP 与 Location，再验证并行开关和 Auto Dark Shift；在通知与统计页分别导出对应一路。具体后台、锁屏、权限与宿主交接操作见 [DEVICE_ACCEPTANCE.md](DEVICE_ACCEPTANCE.md)。编译和占位签名不代表新增方案的真机后台持续性已通过。
