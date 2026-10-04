# Location 后台方案参考与实现（1.0.2）

本轮只读检查用户提供的“华中大体育”砸壳包：Bundle ID `com.chinahzchingo.hkty`，版本 1.3.2 / build 2，arm64 主程序 `ChingoItemHKTY` 的 SHA-256 为 `59586b43c7d05d7f4a871c1a4638ebb423948fdd4bf5571189f9142c6b086e8d`。没有运行、修改或重新分发该 App，没有取用账号或网络业务。原始包仍留在本地，选取的定位反汇编片段留在忽略的 `local-data/analysis/location-reference-20261005/`。

## 静态证据

| 路径 / 方法 | 已确认行为 | 证据位置 |
| --- | --- | --- |
| Info.plist | UIBackgroundModes 为 audio / fetch / location，包含三种定位用途文案 | 用户提供的包内 Info.plist |
| MinRunningVC → MinRunningMapView → SPMapView | 运动页面创建 / 加入地图视图 | MinRunningVC.viewDidLoad，IMP `0x1001086e0` |
| SPMapView.initWithFrame: → MAMapView | 开启用户定位、跟随，设置地图层自动暂停为 YES、允许后台定位为 YES | IMP `0x1000a4b54`；对应调用 `0x1000a4bd4`、`0x1000a4bec`、`0x1000a4c00`、`0x1000a4c14` |
| AMapLocationManager.initCLManager | SDK 创建 CLLocationManager、安装 delegate，将 desiredAccuracy 设为 kCLLocationAccuracyBest | IMP `0x10046c7e8`；常量载入 `0x10046c91c`，调用 `0x10046c92c` |
| AMapLocationManager 初始化 | SDK manager 的自动暂停设为 NO | `0x10046c7d8`；不能由此反推运动页地图层的实际生效值 |
| TZLocationManager | startLocation 启动更新，位置回调后停止更新；属于一次性取址 helper | 独立 CLLocationManagerDelegate 实现，不作为运动持续定位的依据 |
| AppDelegate 的后台 / 前台 / 激活 / 终止方法 | 四个实现均为 ret，无自写前后台恢复动作 | `0x10020a5e0` 至 `0x10020a5ec` |

运动页可确认通过地图 SDK 开启定位和允许后台定位。SDK 内同时存在不同暂停配置，尚未把运动页活动 manager 的最终精度、distanceFilter、activityType 精确对应起来。二进制有 beginBackgroundTask / endBackgroundTask 符号，但没有建立这些调用与运动流程的关联；不据此宣称原 App 使用后台任务循环保活。idleTimerDisabled 防止自动熄屏，也不能当作后台资格。

可用 `plutil -p Info.plist` 查看后台声明，用 `otool -ov ChingoItemHKTY` 核对 Objective-C 方法 / IMP，再用 `otool -arch arm64 -tvV ChingoItemHKTY` 检查相应指令。上述地址与校验值仅适用于这个输入包；静态调用存在不证明运行时授权、实际回调频率或长期后台存活。

## AutoDarkShift 的取舍

采用持续开启定位服务、声明 location 后台模式的方向，使用系统 CoreLocation 独立实现，不引入高德 SDK。与此前三公里精度 / 最大距离过滤相比，本次使用 Best 精度与无距离过滤，便于真机验证静止场景下的持续定位；`.fitness`、禁止自动暂停和后台定位指示是本工程的明确选择，不声称这些都是参考 App 的最终运行参数。

前台开启后保留同一会话，处理权限变化、暂停 / 恢复与前台恢复；每次用户重新开启更换 manager，拒绝旧 manager 的迟到回调。室内暂时取不到位置时保留会话，权限被拒则结束。有限后台过渡任务只用于进入后台的交接，收到定位回调、回前台、停止 / 失败或过期即结束，没有周期性重启或续租。位置坐标在 delegate 入口丢弃，仅记录回调时间、记录年龄和水平精度。

[Apple 的授权说明](https://developer.apple.com/documentation/corelocation/requesting-authorization-to-use-location-services)确认，启用连续后台更新时，使用期间授权可延续前台已开始的定位；会话停止后不能把它当成后台重启许可。[暂停说明](https://developer.apple.com/documentation/corelocation/cllocationmanager/pauseslocationupdatesautomatically)要求 App 自己处理重新启动；本工程在始终授权或回到前台时恢复，并保留系统实际回调诊断。

持续定位会增加耗电。Location 提供的 App 后台运行资格与 UIKit 亮度值是否新鲜是两个需分别验证的条件，本轮没有修改亮度接口。回归 / 编译范围见 [STATIC_VALIDATION.md](STATIC_VALIDATION.md)，手机测试见 [DEVICE_ACCEPTANCE.md](DEVICE_ACCEPTANCE.md) 第 14 节。
