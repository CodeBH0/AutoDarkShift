# iPhone 重签 IPA

已使用 Xcode 16.2 / iOS 18.2 SDK 直接编译 App target，构建 iPhone arm64 Release 版本，最低系统 iOS 17.0。未安装 iOS 平台或模拟器。产物包含主 App 和 `PlugIns/PacketTunnel.appex`，版本 1.0.2，build 18，通信协议 3。

本次正常递增至 build 18，版本更新到 1.0.2。Location 改为连续定位，增加权限变化、暂停后恢复、旧会话回调隔离和有限过渡任务清理；参考本地华中大体育砸壳包的运动页后台定位路径，证据与区别见 [LOCATION_REFERENCE.md](LOCATION_REFERENCE.md)。界面增加前台开启、位置用途及耗电提示，运行日志可分别核对定位回调、亮度读取和通知结果。

文件：`build/AutoDarkShift-1.0.1-build18-resign.ipa`。该包没有开发者证书签名或 provisioning profile；本地 ad-hoc 占位签名仅用于携带权限信息，不能直接安装。需要在 iPhone 的签名工具中使用你的 p12 证书和匹配的 `.mobileprovision` 描述文件重新签名。

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

扩展 Bundle ID 必须以主 App Bundle ID 加 `.` 为前缀。不能只修改主 App 的 Bundle ID 而保留旧的 `PacketTunnelBundleIdentifier`。本次展开的权限文件另存于 `build/build18/Signing/AutoDarkShift.entitlements` 和 `build/build18/Signing/PacketTunnel.entitlements`，便于签名工具手动配置。

如果签名工具不支持同步上述自定义字段，可先将自己的标识符写入 `Config/Local.xcconfig`，再运行打包脚本。构建无需把证书交给本机：

```sh
bash tools/package_ipa.sh --direct-sdk
```

`--direct-sdk` 显式使用已安装 iPhoneOS SDK 直接构建 Release target 和嵌入扩展，避开目的地查找，不安装平台或模拟器，不生成 Xcode archive。不带此参数仍沿用归档模式。

脚本优先使用 `DEVELOPER_DIR` 指定的 Xcode，其次使用系统已选择的完整 Xcode、`/Applications/Xcode.app` 或下载目录中的 Xcode。它不修改系统的 Xcode 选择，不读取证书，也不连接 Apple 账号。

每次执行会自动递增 `Config/Project.xcconfig` 中的 build 号，并将同一编号用于主 App 和扩展；失败的构建也保留该编号，不回退复用。归档、缓存、权限文件和编译日志保存在各自的 `build/build<编号>/`，IPA 与 SHA-256 文件名带 build 号，脚本拒绝覆盖已有产物。

## 验证范围

本机 61 项 core checks、57 个 XCTest 方法通过，0 失败；包含真实 localhost TCP 双流传输，以及新增 Location / PiP 共享一个 App 内监听、独立关闭和最后一个保活停止后 sleep 的模拟宿主回归。测试运行于 macOS，不直接执行 UIKit / CoreLocation 适配器。完整 iPhoneOS 18.2 SDK 已编译 App / PacketTunnel，arm64、最低 iOS 17、同为 1.0.2 / build 18。

ZIP、双组件权限 / 标识符 / 版本、框架边界、占位签名与 SHA-256 独立核对结果保存在 `build/build18/ipa-verification.json`。包大小 873128 字节，SHA-256 `3d9edf4d4ce1c578d9da0b485913d1b713722d6d7f97bbe41fc71ddfff772f75`；原有 13 份 IPA 校验值全部不变。未读取开发者证书或描述文件，未安装 iOS 平台、模拟器或虚拟机。

重签后先关闭 VPN / PiP，单独开启 Location，按 [DEVICE_ACCEPTANCE.md](DEVICE_ACCEPTANCE.md) 第 14 节测试权限、静止 / 移动、后台至少 30 分钟、锁屏及关闭后恢复。记录实际调亮度的时间与通知结果，并分别导出运行 / Boost 日志；持续定位、后台 UIKit 亮度新鲜度和通知展示需要真机分别确认。本机编译、纯逻辑回归与占位签名不代表真机验收通过。
