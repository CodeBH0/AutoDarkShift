# AutoDarkShift

这是给 iOS 17+ 未越狱的iOS设备开发的亮度自动切换软件，目标是达成进入较暗/较亮环境时，自动切换外观模式（深色与浅色）。软件的基本实现逻辑是，通过轮询屏幕亮度来判定需要的外观模式。
当前使用 VPN 的 Packet Tunnel 进程运行保活，监听读取亮度并提交 `dark` / `light` 本地通知。外部快捷指令负责切换系统外观。
全程agent coding，一点人工的成分都没有。

## 安装

### 使用预编译 IPA

从 Releases 下载最新 IPA（目前还没有），并使用自己的证书重新签名安装。
由于开发过程是在 MacOS 14 虚拟机上进行的，只能使用 Xcode 16.2 进行打包，如果要启用 Liquid Glass 可以在签名软件内强制启用。

### 从源码构建

需要 Xcode 15+ 和 iOS 17+ SDK。

详细的 IPA 重签说明见 [IPA_SIGNING.md](docs/IPA_SIGNING.md)。
真机验收说明见 [DEVICE_ACCEPTANCE.md](docs/DEVICE_ACCEPTANCE.md)。
架构与实现细节见 [ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 使用

1. 打开 AutoDarkShift，点击“请求通知权限”，查看授权结果；已拒绝时可到系统设置重新授权。
2. 按需编辑参数，点击“保存并应用配置”。默认深色阈值 `0.20`、浅色阈值 `0.28`、采样间隔 `1 秒`、稳定时间 `1 秒`、通知冷却 `3 秒`。
3. 打开“保活”开关，首次开启时自动准备配置并请求系统 VPN 确认；关闭开关停止 VPN。准备和连接/断开期间禁止重复操作；启动失败、系统断开或从系统设置关闭 VPN 时，开关回到关闭。VPN 适配器根据 `NEVPNConnection.status` 更新真实保活状态，重新启用已禁用的旧配置并更新存储/协议元数据。
4. 用“发送测试通知”检查权限与前台横幅，测试标题是 `AutoDarkShift.Test`，不修改正常目标历史或扩展通知计数。
5. 添加快捷指令https://www.icloud.com/shortcuts/6fcf8f11160d495386943a8f6e774aa5监听 AutoDarkShift 发送的通知并切换外观。
6. 可在设置内关闭 AutoDarkShift 的横幅与锁屏显示，达到静默效果。


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
