# 1.0.3 / build 2：BackBoard 后台亮度探针

本轮在 `422d04e`（1.0.3 / build 1）上增加第三条互斥监听，测试用户提供的 `BKSDisplayBrightnessGetCurrent`。仪表中的“BackBoard 探针监听”默认关闭；开启时先关闭原监听和亮度消息监听，确认停止采样及在途通知结算，再启动探针。失败时保留关闭意图与具体错误，不启动替代输入。保活开关仍独立。

## 输入与后台运行

`Platform/BackBoardBrightnessProbe.swift` 按示例用 `dlopen(..., RTLD_NOW)` 加载 `/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices`，用 `dlsym` 解析符号，调用类型为 `@convention(c) () -> Float`。解析结果只初始化一次，成功或符号缺失时均保留已打开的 handle，不在读取期间卸载框架。加载日志区分 `dlopen`、`dlsym` 和 `resolved`，保存实际 `dlerror`。该函数的 Float getter 形式也可在 [WebKit 的源代码](https://chromium.googlesource.com/external/github.com/WebKit/webkit/+/3b9cd5643fa9067f5bdbfb478e6761996fa889aa/Source/WebKit/UIProcess/Cocoa/WebProcessPoolCocoa.mm) 中核对；这不能证明普通 App 在当前设备上能访问或及时读到变化。

这是读取函数，没有变化订阅。本轮使用独立 `BackBoardBrightnessSampler` 定时读取，不注册旧 UIKit 通知或类型化亮度消息。读取与模型回调在 MainActor，等待使用现有 DispatchPollingScheduler，默认 1 Hz，沿用 MathModel v2 的 10 / 30 / 60 / 120 Hz 动态采样。initial / wake 重新建立基线，poll 才计入轮询；不会产生 event 回调。NaN、无穷和越界值原样交给既有非法输入处理，不裁剪成合法亮度。缺少 getter 不构造样本或心跳，不以 UIKit 回退。

探针只在主 App 运行，没有替换 PacketTunnel 的输入。后台执行许可来自实际 active / reasserting 的 PiP 或 Location；仅开启 VPN 不赋予 App 探针后台许可。关闭最后一个 App 保活后，后台监听 sleep，取消调度并清除心跳；回前台或实际恢复保活后 wake。停止 / 重启作废旧读取回调。私有 API 是否可用、后台数值是否及时、锁屏行为均待真机确认。

## 日志与切换

探针的配置、快照、成功历史、运行日志和 Boost 分别存在独立 `BackBoardMonitoring` 目录。模型、通知权限、冷却、成功历史去重和通知提交沿用原实现。三套业务先保存全部关闭配置，再逐一确认停止，最后只启用所选业务；恢复时若配置冲突，优先 BackBoard，再亮度消息，最后原监听。未选择探针时，不加载其框架，也不创建探针运行时。

“通知与统计”中的两个导出入口包含三套业务的对应流。探针块的元数据为 `scope=backboard_monitor`、`business=backboard`、`samplingMode=backboard_poll_only`、`api=BKSDisplayBrightnessGetCurrent`。Boost 保留所有进入模型的真实读数、五秒实际上下文和两秒稳定结束规则；UIKit 对照只写运行诊断，不参与模型或通知。

| 事件 | 含义 |
| --- | --- |
| `backboard_api_load` | 框架路径、符号、available、loadStage 和 loaderError；加载成功不等同于读数新鲜 |
| `backboard_sampler_started/stopped` | 实际采样生命周期，samplerGeneration 与 observer=none |
| `poll_tick` | worker 调度证据，business / api 标记；不会自行生成亮度样本 |
| `backboard_brightness_sample` | 实际 getter 调用结果、valid、source、UTC 时间、uptime、累计 readCount、App 状态与运行实例；最多每秒一条，initial / wake 另记 |
| `uiKitBrightness` / `difference` | 同次诊断中读取 UIKit 对照及 BackBoard 减 UIKit 的差值；仅用于对照，不作为物理亮度真值 |
| `backboard_read_unavailable` | 没有 getter 返回值；不生成替代样本 |
| `sample/trend_score/notification_*` | 同一探针运行实例的实际模型输入、评分、候选及系统提交结果 |

常规诊断条数不是真实读取频率，完整动态输入应结合 counters 与 Boost 判读；readCount 统计 getter 调用，包含无返回值的调用。日志中的 valid 只表示有限且位于 0–1，不确认值是新的。读取日志在模型回调前记录，因此其中 heartbeat / lastPoll 属于上一次已处理样本；以随后的运行快照与同实例 sample 为准。缺少后台记录只说明执行证据不足，不能直接判断 getter 缓存或通知失效。

## 测试与构建

先确认信息页为 **1.0.3 / build 2**，在仪表开启“BackBoard 探针监听”，再开启 PiP 或 Location。退出到桌面后交替降低 / 提高亮度，记录每次实际操作的 UTC 或带时区时间；分别导出运行 / Boost，核对后台调用、两种读数、S、候选、通知接受和设备实际外观。至少分别完成 PiP、Location 与无 App 保活的对照；细项见 [DEVICE_ACCEPTANCE.md](DEVICE_ACCEPTANCE.md) 第 16 节。

本机验证与 IPA 结果见 [STATIC_VALIDATION.md](STATIC_VALIDATION.md)。编译通过不确认设备上的私有符号可用或后台效果。输出为 `build/AutoDarkShift-1.0.3-build2-resign.ipa`；build 1 保留。常规重新打包会继续递增 build，不覆盖已有产物。
