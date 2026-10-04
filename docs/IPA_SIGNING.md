# iPhone 重签 IPA

已使用 Xcode 16.2 / iOS 18.2 SDK 直接编译 App target，构建 iPhone arm64 Release 版本，最低系统 iOS 17.0。未安装 iOS 平台或模拟器。产物包含主 App 和 `PlugIns/PacketTunnel.appex`，版本 1.0.1，build 17，通信协议 3。

本次正常递增至 build 17，修复场景 inactive 造成多余 sleep / wake、许可与实际 runtime phase 不一致时未恢复的问题。App 内轮询等待与 UIKit 读数解耦，增加从平台 active 到评分、授权与通知完成的诊断。PiP 主体和 GlobalRefresh 的“开启悬浮窗 → 一键0.1pt”流程沿用 build 16，模型与 Boost 公式不变；Location 暂不修改，系统 Tab Bar 和两路导出沿用。平台说明见 [KEEP_ALIVE.md](KEEP_ALIVE.md)。

文件：`build/AutoDarkShift-1.0.1-build17-resign.ipa`。该包没有开发者证书签名或 provisioning profile；本地 ad-hoc 占位签名仅用于携带权限信息，不能直接安装。需要在 iPhone 的签名工具中使用你的 p12 证书和匹配的 `.mobileprovision` 描述文件重新签名。

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

扩展 Bundle ID 必须以主 App Bundle ID 加 `.` 为前缀。不能只修改主 App 的 Bundle ID 而保留旧的 `PacketTunnelBundleIdentifier`。本次展开的权限文件另存于 `build/build17/Signing/AutoDarkShift.entitlements` 和 `build/build17/Signing/PacketTunnel.entitlements`，便于签名工具手动配置。

如果签名工具不支持同步上述自定义字段，可先将自己的标识符写入 `Config/Local.xcconfig`，再运行打包脚本。构建无需把证书交给本机：

```sh
bash tools/package_ipa.sh --direct-sdk
```

`--direct-sdk` 显式使用已安装 iPhoneOS SDK 直接构建 Release target 和嵌入扩展，避开目的地查找，不安装平台或模拟器，不生成 Xcode archive。不带此参数仍沿用归档模式。

脚本优先使用 `DEVELOPER_DIR` 指定的 Xcode，其次使用系统已选择的完整 Xcode、`/Applications/Xcode.app` 或下载目录中的 Xcode。它不修改系统的 Xcode 选择，不读取证书，也不连接 Apple 账号。

每次执行会自动递增 `Config/Project.xcconfig` 中的 build 号，并将同一编号用于主 App 和扩展；失败的构建也保留该编号，不回退复用。归档、缓存、权限文件和编译日志保存在各自的 `build/build<编号>/`，IPA 与 SHA-256 文件名带 build 号，脚本拒绝覆盖已有产物。

## 验证范围

本机 61 项 core checks、56 个 XCTest 方法通过，0 失败；含 34 项模型、16 项多保活 / 宿主 / 读数到通知决定、5 项真实 DispatchSource 调度与资源释放，以及包装运行时 / 存储 / 通信场景的测试。真实 localhost TCP 实际执行。完整 iPhoneOS 18.2 SDK 验证 App / PacketTunnel 平台接口，arm64、最低 iOS 17、同为 1.0.1 / build 17。

本次正常递增 build。ZIP、双组件权限 / 标识符 / 版本、原生框架边界、占位签名与 SHA-256 独立核对结果保存在 `build/build17/ipa-verification.json`。包大小 866746 字节，SHA-256 `960c11c753919fe78b24f2b0edc45c350bdd1a3adac91a0d91bfd82089275b0a`；原有 12 份 IPA 校验值全部不变。

PiP 主体、44pt 开启与“一键0.1pt”流程不变。App 内监听显式使用 DispatchSourceTimer 等待、MainActor 读取 UIKit，VPN 使用原调度。重签后先关闭 VPN / Location，记录进入后台与物理调亮度时间；分别导出运行 / Boost 日志，按 [DEVICE_ACCEPTANCE.md](DEVICE_ACCEPTANCE.md) 第 13 节判断调度、读数、评分、授权与实际通知的断点。最新旧包日志虽有后台 poll，仍不能证明亮度读数新鲜或通知已展示；本机测试与占位签名不代表新包真机验收通过。
