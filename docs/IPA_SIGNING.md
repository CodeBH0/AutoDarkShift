# iPhone 重签 IPA

已使用 Xcode 16.2 / iOS 18.2 SDK 构建 iPhone arm64 Release 版本，最低系统 iOS 17.0。产物包含主 App 和 `PlugIns/PacketTunnel.appex`，版本 1.0.0，build 9，通信协议 3。

文件：`build/AutoDarkShift-1.0.0-build9-resign.ipa`。该包没有开发者证书签名或 provisioning profile；本地 ad-hoc 占位签名仅用于携带权限信息，不能直接安装。需要在 iPhone 的签名工具中使用你的 p12 证书和匹配的 `.mobileprovision` 描述文件重新签名。

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

扩展 Bundle ID 必须以主 App Bundle ID 加 `.` 为前缀。不能只修改主 App 的 Bundle ID 而保留旧的 `PacketTunnelBundleIdentifier`。展开的权限文件另存于 `build/Signing/AutoDarkShift.entitlements` 和 `build/Signing/PacketTunnel.entitlements`，便于签名工具手动配置。

如果签名工具不支持同步上述自定义字段，可先将自己的标识符写入 `Config/Local.xcconfig`，再运行打包脚本。构建无需把证书交给本机：

```sh
bash tools/package_ipa.sh
```

脚本优先使用 `DEVELOPER_DIR` 指定的 Xcode，其次使用系统已选择的完整 Xcode、`/Applications/Xcode.app` 或下载目录中的 Xcode。它不修改系统的 Xcode 选择，不读取证书，也不连接 Apple 账号。

## 验证范围

已通过 iPhone Release 编译和归档、主 App/扩展 arm64 与 iPhoneOS 平台检查、权限与共享标识符检查、占位签名完整性检查、IPA ZIP 完整性检查。真实证书签名、安装和设备上的 VPN、亮度及后台行为尚未验证。

运行时以单个“保活”开关准备并开启 VPN。build 9 已拆除并归档轮询率测试组件，保留普通监听与认证本机通道日志回传，并继续区分真实连接与运行详情读取；查询无回复不是要求重新签名或安装的依据。安装后的功能与可观测性分开记录，具体步骤见 [LOG_REPAIR.md](LOG_REPAIR.md)。

升级后关闭再开启一次保活，让旧 VPN profile 写入本机日志备用通道参数。新的回传链路与复测见 [LOG_TRANSPORT.md](LOG_TRANSPORT.md)。
