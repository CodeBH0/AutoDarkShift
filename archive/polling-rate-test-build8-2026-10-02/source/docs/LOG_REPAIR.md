# 日志分析与状态判定

build 8 的最新输入为 `build/AutoDarkShift-13E966D5-3B87-413F-9447-128FD4A0717C.jsonl`。45 次 Provider Message 全部空回复，其中含测试开始与日志导出，不能确认轮询测试已启动。build 8 增加即时回显探针、本机认证备用通道、分页回传与 App 持久化缓存，见 [LOG_TRANSPORT.md](LOG_TRANSPORT.md)。以下保留 build 6 的历史分析；“观测缺失不等于监听停止”仍然成立，但日志回传本身必须修复，不能仅修改提示。

最新输入：`AutoDarkShift-2D998352-F741-416C-824B-6A89A45CD2FD.jsonl`，build 5 / 协议 3 / local-ipc-v1。三个原始 JSONL 文件均保留不变。

## 最新日志支持的结论

| 现象 | 证据与解释 |
| --- | --- |
| VPN 能正常开启并保持连接 | 2026-10-02 19:13:39.562（Asia/Shanghai）为 active，19:57:41.582 才记录 stopped；约 44 分 2 秒，期间未记录中途状态断开，disconnectError=none |
| 当前设备整体使用正常 | 用户明确反馈；应作为实际使用证据保留，不被缺少诊断回复覆盖 |
| 运行详情读取不可用 | 48 次 handshake、6 次 reloadConfiguration 均未取得回复；没有 identity、status 或扩展日志，无法据此判断监听是否停止 |
| 配置保存与应用是不同结果 | App 保存了配置，最后为深色 0.34、浅色 0.35、间隔/稳定 0.5 秒、冷却 2 秒；6 次即时应用结果未确认，不等同于明确拒绝，也不能宣称已应用 |
| 存储回退已正常发生 | storageMode=local-ipc-v1，storageError=none；storageFallbackReason 解释为什么使用本地模式，不是当前错误 |
| 测试通知已提交 | test_notification_success 一次；说明系统接受请求，不证明每一次正常通知与外部自动化结果 |
| 仍有真实输入错误 | 4 次阈值不满足 0 ≤ 深色 < 浅色 ≤ 1；继续保留校验，避免无效参数覆盖配置 |

最新文件共有 181 条记录。11 条 app_operation_error 中，6 条为已保存配置但未取得确认，1 条为手动查询无回复，4 条为非法阈值。此前提示将前 7 条归为需要重装的故障，结论过强，现予以修正。

Apple 的 [sendProviderMessage 文档](https://developer.apple.com/documentation/networkextension/netunnelprovidersession/sendprovidermessage(_:responsehandler:)) 将 nil 回复描述为发送或返回结果过程中发生问题的通知；它不提供“监听已经停止”或“必须重装”的结论。当前日志也无法证明该环境永远不支持通信，因此保留手动重试和有界自动重试。

## build 6 调整

- 将保活状态与运行详情读取分别判定。nil/超时归为 unavailable，显示“保活已连接，实时状态暂不可读取”，不作为红色故障、不要求重装。
- 自动查询在连续无回复时按 30/60/120/300 秒退避；重复相同缺失不再持续记录同一 monitor_query_error。手动查询、保存配置仍可立即尝试。
- 配置消息无回复时显示“已保存，当前应用结果未知；重新开启保活使用新配置”。不自动停止正常运行，不伪造已应用 revision。
- 非法参数、存储失败、身份不兼容、坏 JSON 和扩展明确拒绝仍保留错误。
- 日志增加 readbackAvailability / readbackDetail，runtimeConfirmed=false 仅代表缺少当前回复。存储回退原因、历史错误与当前故障分别解释。
- 验收改为功能结果与可观测性分开记录。事件回调、sleep/wake、精确轮询间隔与完整后台日志不是所有设备必须同时取得的通过条件；缺失时记“不可观测”。

保活和独立监听的运行逻辑未修改，单开关与现有 VPN 后端继续使用，未接入 PiP。本轮没有将 VPN connected 改成“采样已证实”，也没有补造任何样本、心跳或通知成功记录。

## 当前设备记录与后续验证

build 5 的 VPN 连接区间由日志确认，整体功能可用来自用户反馈；逐次采样、即时应用确认和完整通知链路仍未从该导出中取得。此前“所有诊断字段可见才算正常”的门槛已取消，不将诊断不可用视作功能失败。

build 6 已完成本机核心测试与 iPhone 构建；具体验证范围见 [STATIC_VALIDATION.md](STATIC_VALIDATION.md)。安装后只需核对提示、开关及实际功能是否符合体验；[DEVICE_ACCEPTANCE.md](DEVICE_ACCEPTANCE.md) 将功能与可观测性分别记录。

## build 5 的存储与单开关修复（历史）

本轮输入：项目根目录的 `AutoDarkShift-18DF7D4B-8DEC-4D9B-A248-08F47E11221E.jsonl`。原始日志保留不变。

### 本次启动失败

日志来自 iOS 27.0、App 1.0.0 build 4、协议 2、`app-group-v1`：

- 2026-10-02 18:25:45（Asia/Shanghai），主 App 记录“App Group 容器不可用”。
- 18:26:31，VPN 配置保存成功。
- 18:26:33，启动后约 0.13 秒即从 starting 经 stopping 回到 stopped；第二次启动同样失败。
- 断开原因只有 `PacketTunnel.ProjectError (0)`、空 userInfo，无法从导出中读到扩展的具体报错。
- 测试通知提交成功，但没有监听采样、有效运行快照或共享日志。

build 4 的 App 和 Provider 都将 App Group 作为运行存储的必要前提。主 App 的容器失败已由日志直接确认；Provider 同样在创建监听前打开共享容器，这是与快速启动失败最吻合的源码路径。本次没有取得 Provider 私有日志，不能排除其他系统启动错误，也不能仅凭这个日志判断 Network Extension 签名权限是否有效。

### 修复

| 失效路径 | build 5 行为 |
| --- | --- |
| App Group 不可用，监听初始化直接失败 | App 检测共享目录打开与读写，失败时明确选择 `local-ipc-v1`；使用 App / Provider 各自的私有存储，通过扩展消息同步 |
| 两个私有目录无法共享配置 | App 开启 VPN 时携带完整配置；运行中配置消息带参数和 revision，扩展校验、保存、重载后返回实际应用版本 |
| App 无法读取扩展状态 | 前台约每秒查询扩展快照并缓存；缓存保留原始采样时间，查询不产生心跳 |
| 系统重新拉起扩展时配置可能回退 | 优先使用扩展已保存的配置与成功提交历史；首次本地初始化可从 VPN 配置中的初始参数恢复 |
| 不同进程各自回退导致身份失配 | 存储模式由 App 选择并写入 VPN 元数据；Provider 严格执行，不自行切换；协议升级为 3 |
| Swift 错误跨进程后只显示“错误 0” | `ProjectError` 提供稳定的 NSError domain、code 和本地化描述；启动回调按 NSError 返回具体原因 |
| 准备、开启、关闭分为多个动作 | 单个“保活”开关；首次开启自动准备配置；过渡期间禁用重复操作，失败或外部断开后复位 |
| 本地模式无法直接导出扩展文件 | 运行中取回最多 8 KiB 生命周期日志与 24 KiB 监听日志；导出区分 App 缓存和共享运行记录 |

共享容器可用时仍使用 `app-group-v1`。本地通信模式没有把两个目录当成共享文件，没有把亮度读取搬到主 App；采样、心跳、历史和通知仍由扩展中的独立监听负责。保活与监听接口继续分离，未接入 PiP，未改变隧道路由。

本轮版本为 **1.0.0 / build 5 / 协议 3**。App Group 能力缺失不再作为本地模式启动的前提，但 Network Extension 的有效签名权限仍由系统检查。

### build 5 当时拟定的检查（已由上文修订）

以下保留当时的诊断检查记录；build 6 不再将握手、心跳与全部日志可见作为功能可用的前提。当前操作与判定以本文开头和 DEVICE_ACCEPTANCE.md 为准。

1. 停止旧 VPN，重签并安装 build 5，确认主 App 与嵌入扩展一起更新。打开“保活”开关；首次安装应只需接受系统 VPN 配置确认，无需先点击准备。
2. 当前签名没有 App Group 时，应看到已改用扩展通信的提示。导出应有 `storageMode=local-ipc-v1`、`protocolVersion=3` 和具体 `storageFallbackReason`。若共享容器可用，应为 `app-group-v1`。
3. 应先连接，再完成握手并显示“监听正在采样（心跳有效）”。检查 `runtimeConfirmed=true`、真实 `heartbeatAt`、递增的 `sample.sequence`。测试通知成功不能替代监听成功。
4. 运行时保存参数，检查扩展返回的 `appliedRevision` 与保存值相同。低/高亮度各保持超过稳定与冷却时间，检查真实采样和目标通知。
5. 在 VPN 仍运行时导出日志，再关闭开关。确认系统 disconnected、开关关闭、采样提示不再显示运行。共享模式可读取最终 stopped 快照；本地模式停止后只能保留上次取得的快照，不能把缓存里的 running 当作当前状态。
6. 重开 App 或在系统设置关闭 VPN，确认开关与真实连接同步。重新开启应保留扩展的成功历史，避免同一目标重复提交。
7. 拒绝首次 VPN 配置确认或触发启动错误时，开关应复位且保留具体错误。旧配置被禁用时，开启会保存/重载后重新启用。
8. 若仍无法启动，保留 build 5 新日志；在 macOS Console 筛选 subsystem `AutoDarkShift` 获取 `vpn_start` / `vpn_error`。控制通道未建立时无法通过该通道导出 Provider 私有记录。

已通过核心测试与 iPhone Release 构建，但尚未完成重签后真机复测。实际验证范围见 [STATIC_VALIDATION.md](STATIC_VALIDATION.md)，完整验收见 [DEVICE_ACCEPTANCE.md](DEVICE_ACCEPTANCE.md)。

### 前轮 build 3 日志与分层修复

前轮输入为 `AutoDarkShift-8A9F2A91-84EA-4F70-98FD-84AB9036A6FB.jsonl`，build 3 / `local-v1`。其现象是 VPN connected 后 Provider Message 返回 nil，随后还出现“VPN 配置未启用”；该日志不能证明 nil 的唯一原因，也不能证明扩展亮度固定。

前轮已分离 KeepAliveService、MonitoringClient、MonitoringRuntime、采样、通知与存储接口；修复旧配置重新启用、多配置选择、连接后再握手、版本/存储身份检查、nil / 超时有界重试和独立诊断导出。build 4 强制共享存储的假设在本次日志中暴露，现由显式的双模式存储与配置同步补齐。

build 3 的参数曾为深色 0.26、浅色 0.29、间隔 1 秒、稳定 1 秒、冷却 2 秒；旧 `local-v1` 私有目录位置无法由现有源码确定，本轮未猜测或删除旧数据。当前目录没有 Git 历史可用于还原那份构建。
