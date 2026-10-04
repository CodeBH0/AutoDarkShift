# 验证记录（当前 1.0.1 / build 16）

## 2026-10-04 VideoCall PiP 修复（build 16）

用户反馈 build 15 PiP 无法正常开启、Location 保活未成功。本轮只处理 PiP；用户进一步明确改用 VideoCall 路线，取消 AVPlayer / AVPlayerLayer 路线。参考 GlobalRefresh-PiP 的默认 VideoCall / PiP-only 分支，独立实现稳定根视图来源、空白内容容器、固定 0.1pt 内容首选高度、布局后启动、实际系统确认、失败诊断、有限后台过渡以及停止清理；没有移植动态显示、播放媒体、高刷计时器或私有 API。系统浮窗实际尺寸仍由 iOS 决定。

仅在 didStart 且 isPictureInPictureActive 为真时发布运行中。8 秒未确认启动记录错误与 possible / active / suspended、来源和内容尺寸、音频类别 / 模式 / 路线 / 调用结果，播放器状态明确为 not_used。取消或失败若已有系统启动请求，先保留会话请求停止；实际 inactive 且没有启动过渡后才清理，未确认时保持停止中。VideoCall / PiP-only 跟随参考释放媒体音频策略，协调器避免覆盖其他音频租约持有者，本方案不取得播放租约。

AppController 在前台或 PiP / Location 平台状态已确认为 active / reasserting 时允许本地监听，后台无确认保活则 sleep；回前台或恢复保活后 wake。后台首次创建宿主不先采样，失败恢复原配置并停止已创建实例。该策略只在 App 组合与监听宿主层，通用 KeepAlive 仍不依赖 AutoDarkShift，VPN 扩展与趋势算法未修改。

| 检查 | 本轮实际结果 |
| --- | --- |
| 工程 / 空白检查 | 通过：190 个对象、51 个工程文件、48 个唯一 XCTest 方法；git diff --check 通过 |
| core checks | 通过：61 项生产场景，包括实际 localhost TCP 双流传输 |
| Swift Package XCTest | 通过：48 个方法，0 失败；34 项模型、13 项多保活 / 宿主协调和包装 61 场景的运行时测试，运行于 macOS |
| 干净副本与生成器 | 通过：没有 AGENTS.md / DEVELOPMENT.md 的副本可验证、重建；生成工程与共享 Scheme 与当前完全一致 |
| iPhone Release 编译与 IPA | 通过：现有 iPhoneOS 18.2 SDK，arm64、最低 iOS 17；App / PacketTunnel 均为 1.0.1 / build 16，未安装平台或模拟器，未生成 archive |
| IPA 独立核对 | 通过：ZIP、双组件版本 / 标识符 / 权限、占位签名、框架边界；VideoCall 类型在 App 中，未引用 AVPlayer / AVPlayerLayer，也不包含媒体资源 |
| 大小与 SHA-256 | 810420 字节；`4f99e56607f5a17952959949b17461db91db01e5de6e4e4804ffe82d50d459c1` |
| 旧产物与本地资料 | 此前 11 份 IPA 校验值不变；标准脚本递增为 build 16，已交付 build 15 保留；日志、IPA、证书、AGENTS.md / DEVELOPMENT.md 不提交 |
| PiP 前台启动、后台 heartbeat、关闭后的真实资源与监听停止 | 未执行真机验收，按 DEVICE_ACCEPTANCE 第 12 节验证；Location 本轮暂不修复 |

初次沙箱执行受到编译缓存写入 / 本机监听权限限制，获准后完成实际编译和 TCP 场景。首次 XCTest 与核心检查并行造成测试端口冲突，未计为通过；复用 SwiftPM 目录又出现 unknown build description，最终以全新项目内缓存串行运行 61 场景及 48 个 XCTest 全部通过。没有跳过失败项或安装 iOS 平台。纯逻辑测试不包含 AVKit，iPhone 编译验证平台接口，不能替代实机可启动性或持续性结论。

最终本地记录：`build/validation-pip-videocall/core-final.log`、`xctest-final.log`、`preflight-final.log`、`package-ipa.log`、`previous-ipa-sha256.json`；最终包核对位于 `build/build16/ipa-verification.json`，打包编译与权限位于 `build/build16/unsigned-build.log` 与 `Signing/`。这些过程文件不提交。

## 2026-10-04 多方案保活、功能开关与原生 Tab（build 15）

用户反馈 build 14 实机测试通过。本轮在既有 VPN 方案旁新增 PiP 与 Location，三种保活可独立同时开启；KeepAlive 抽象只管理平台生命周期，Auto Dark Shift 通过独立开关控制同一生产监听。VPN 与 App 内宿主交接时，停止旧采样并等待已提交的通知完成，合并实际取得的较新历史；无回复仍记录为不可观测。独立静音音频方案按用户要求取消。

GUI 使用系统底部 Tab Bar：仪表、保活、信息均为独立 View，复用 AppController；切换监听与通知统计仍为二级模块。当前状态显示监听频率、S、采样亮度及当前 App 可见外观，未确认的开关状态明确提示等待确认，宿主切换清除旧快照。运行 / Boost 导出继续分开，App 内记录独立持久化，保留旧 Provider 缓存。

| 检查 | 本轮实际结果 |
| --- | --- |
| 工程、生成器与空白检查 | 通过：190 个工程对象、51 个工程文件；原生适配器仅进入 App，通用 KeepAlive 不依赖监听业务；生成器与工程一致，git diff --check 通过 |
| core checks | 通过：61 项场景，含新增关闭 / 重新开启、旧配置兼容、在途通知结算后交接及真实 localhost TCP 双流传输 |
| Swift Package XCTest | 通过：43 个方法，0 失败；34 项模型、8 项多保活 / 宿主协调及包装 61 项运行时场景的测试，运行于 macOS |
| 干净副本 | 通过：不含 AGENTS.md / DEVELOPMENT.md 的副本可验证与重建工程，生成结果相同 |
| iPhone Release 编译与 IPA | 通过：已有 iPhoneOS 18.2 SDK，App / PacketTunnel 均为 1.0.1 / build 15、arm64、最低 iOS 17；未安装平台或模拟器，未生成 Xcode archive |
| IPA 独立核对 | 通过：双组件版本、权限、原生框架边界、audio / location 后台模式和用途文案、占位签名、ZIP / SHA-256；797545 字节，SHA-256 `e6d138c39ce2c82e4fb38151199003e2dc8880ac93a26152ac0483ae7c899f7c` |
| 产物与 Git 边界 | 原有 10 份 IPA 校验值不变；按用户明确授权覆盖本轮旧 build 15，清理临时 build 16；本地文档、日志、IPA、缓存和签名资料继续不提交 |
| 新界面、权限、PiP / Location 后台持续性 | 未执行真机验收，由用户重签并按 DEVICE_ACCEPTANCE 专项测试；此前 build 14 通过为用户反馈 |

本轮最初已生成 build 15，最终补充未确认状态提示与旧快照清理后临时打包 build 16。用户随后明确要求不保留 build 15、直接覆盖；最终在本地一次性打包副本中固定 build 15，重新编译最终源码并核对，原 build 15 被替换、临时 build 16 删除。标准 `tools/package_ipa.sh` 默认递增与拒绝覆盖策略保持不变，新增可选 `--direct-sdk` 只改变编译路径。没有使用占位签名冒充设备安装通过。

最终本地记录位于忽略的 `build/validation-multi-keepalive/`：`core-checks-final.log`、`xctest-final.log`、`static-final.log`、`clean-static.log`、`package-ipa-build15-final.log`。最终双组件的编译、占位权限与独立核对在 `build/build15/unsigned-build.log`、`Signing/` 和 `ipa-verification.json`；这些文件不提交。

## 2026-10-04 二级菜单、独立导出入口与本地文档（build 14）

用户反馈 build 13 实机测试已通过，未补录设备型号、系统版本或各分项细节。本轮沿用数学模型 v2 和既有监听、通知逻辑；将“切换监听”与“通知与统计”放入二级页面，通知权限、查询、测试通知、统计与反馈均保留。前台刷新与分享 sheet 归属于整个导航栈，避免进入二级页面使根表单消失后停止刷新。

“导出运行日志”和“导出 Boost 日志”每次只同步、分享选中的一路。运行导出保留 App 与 Provider 诊断；共享模式的 Boost 直接读取共享记录。本地缓存、错误和取消路径分别处理，后台自动同步与关闭保活前同步仍保留两路。

| 检查 | 本轮实际结果 |
| --- | --- |
| 工程静态检查 / 空白检查 | 通过：150 个工程对象、37 个工程文件；生成器同步移除本地文档引用；`git diff --check` 通过 |
| core checks | 通过：57 项场景，包含真实 127.0.0.1 TCP 双流回传和离线缓存 |
| Swift Package XCTest | 通过：35 个方法，0 失败，运行于 macOS |
| 不含本地文档的干净副本 | 通过：工程静态检查、Package manifest 加载与生成后的工程检查；不要求 AGENTS.md / DEVELOPMENT.md 存在 |
| iPhone Release 编译与 IPA | 通过：使用已有 iPhoneOS 18.2 SDK 直接构建 App target 及嵌入扩展，两个组件均为 1.0.1 / build 14、arm64、最低 iOS 17；未安装平台或模拟器 |
| IPA 独立核对 | 通过：版本、标识符、Packet Tunnel / App Group 权限、占位签名、ZIP / SHA-256；670318 字节，SHA-256 `36d276fe3ac6eeb0721a15c36ce4f105382ac11a1c1facd29311cf0c60f2af9c` |
| 本地文件与旧 IPA | AGENTS.md 与 DEVELOPMENT.md 保留本地并停止跟踪；原有 9 份 IPA 校验值不变 |
| 本轮菜单操作、系统分享及真机测试 | 待用户重新签名并测试 build 14；核心测试和编译不代替此项 |

本次按用户明确要求复用 build 14，覆盖该编号未产出 IPA 的旧输出。没有修改标准打包脚本的递增策略，后续通常打包仍继续递增。当前包由直接构建的 `build/build14/Products/Release-iphoneos/AutoDarkShift.app` 生成，使用标准脚本原有的占位签名、ZIP 与校验步骤；本轮没有生成 Xcode archive。

验证输出保存在忽略的 `build/validation-menu-exports/`：`core-checks.log`、`xctest.log`、`static-final.log`、`clean-static.log`、`clean-generated-static.log`、`clean-package.json`、`package-ipa.log`。主 App / 扩展构建记录与核对位于 `build/build14/unsigned-build.log` 和 `build/build14/ipa-verification.json`。这些过程文件和 IPA 不提交。

## 2026-10-03 数学模型 v2、双日志与目录整理（build 13）

[模型 v2](models/MathModel-v2.md) 独立新增，v1 原文移动至 `docs/models/MathModel-v1.md`，SHA-256 与原文件及此前提交一致。删除 D，V 改为受幅度和物理空间限制的预测贡献；同向 Δ 跨采样退出与停留保留，峰谷累计反向 0.010 后重建起点，统一一秒速度窗。运行 / Boost 各自写入、轮转、分页、缓存和导出；紧凑样本保留逐行评分核验所需原状态，并支持旧格式解码。

| 检查 | 本轮实际结果 |
| --- | --- |
| 工程静态检查 / 空白检查 | 通过：151 个工程对象、38 个工程文件，两个模型文档和目标边界；`git diff --check` 通过 |
| core checks | 通过：57 项场景，实际允许 127.0.0.1 监听与连接，含双流回传和离线缓存 |
| Swift Package XCTest | 通过：35 个方法，0 失败；34 项模型测试及包装 57 项运行时场景的测试，运行于 macOS |
| 实测解码 / 生产模型回放 | 通过：旧导出 196 行 / 8 trace，105 独立观测、91 重复行；精确 uptime 回放频率变更 26→21、段内基线变更 8→0，缺口显式重置 |
| iPhone Release 编译、归档与 IPA | 通过：两个组件均为 1.0.1 / build 13、arm64、iPhoneOS 18.2 SDK / 最低 iOS 17 |
| IPA 独立核对 | 通过：标识符、Packet Tunnel / App Group 权限、占位签名、ZIP / SHA-256；508999 字节，SHA-256 `83dc9d10c2319cb222a901734318e3e18aae80026ef61ae16967b192500f5b48` |
| 旧文件与提交边界 | v1 原文校验不变；原有八份 IPA 校验不变；指定 build 8 实验归档删除，设备输入移至忽略的 `local-data/` |
| 真实证书签名、安装 / 真机行为 | 未执行，由用户使用本次 IPA 重签并按 [验收表](DEVICE_ACCEPTANCE.md) 复测 |

运行时验证包含普通在途通知不随评分回落取消、生命周期取消与冷却、全部真实样本与事件来源、记录稳定结束/中断、旧混合缓存迁移、单流失败保留旧数据、未获取 Boost 与成功空记录区分、紧凑生产编码→Python 解码还原、独立分享文件及分页快照内存回收。数学测试覆盖慢漂移、死区、预测约束、反向门槛、统一时间窗与旧快照 schema；新快照为 schema 3，旧 V 的含义在界面中标明。

回放沿用旧录制采样网格、可见首读数冷启动和立即接受通知的假设，无环境/外观标签。上述计数不是新定时器的真机达成率，也不是正确率或真实反应时间结论。设备日志缺失或读回超时仍属于可观测性问题。

首轮完整测试已通过；最后增加空 Boost 缓存语义断言后复验，SwiftPM 复用测试目录出现 `unknown build description`，改用全新 `CoreTestsDeliveryFresh` 及配套缓存后 35 项再次全部通过，没有跳过失败项或修改系统工具链。IPA 打包仅出现 locale 警告，未影响编译、占位签名及完整性核对。

本地记录：`build/validation-model-v2/core-checks-delivery.log`、`xctest-delivery-fresh.log`、`static-delivery.log`、`package-ipa.log`；IPA 核对在 `build/build13/ipa-verification.json`，编译日志与归档分别为 `build/build13/unsigned-build.log`、`build/build13/AutoDarkShift.xcarchive`。原始输入和回放报告位于 `local-data/`，以上过程文件均不提交。

下列为本轮实际命令。再次复测应换用尚未存在的一组测试 / 缓存目录；打包脚本会继续消耗新的 build，不覆盖 build 13：

```sh
export DEVELOPER_DIR=/Users/codebh0/Downloads/Xcode.app/Contents/Developer
python3 tools/validate_project.py
python3 tools/run_core_checks.py
CLANG_MODULE_CACHE_PATH="$PWD/build/validation-model-v2/DeliveryModuleCache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/validation-model-v2/DeliveryModuleCache" \
swift test --scratch-path build/validation-model-v2/CoreTestsDeliveryFresh \
  --cache-path build/validation-model-v2/DeliveryPackageCache \
  --config-path build/validation-model-v2/DeliveryPackageConfig \
  --security-path build/validation-model-v2/DeliveryPackageSecurity --disable-sandbox \
  -Xswiftc -module-cache-path -Xswiftc "$PWD/build/validation-model-v2/DeliveryModuleCache"
bash tools/package_ipa.sh
git diff --check
```

以下为历史验证，代表对应 build 当时的行为与执行范围。


## 2026-10-03 第二种完整亮度日志（build 12）

由归档 Boost 测试的独立结果存储与导出方式改造，新增 `BoostTraceRecorder` 并接入正式动态采样入口。前置 5 秒上下文与后续每次读取、评分参数和频率结果单独记录，连续 2 秒亮度波动不超过 0.005 且新轮询确认后完成，恢复 1 Hz 不结束。完成范围和真机操作见 [BOOST_TRACE_LOG.md](BOOST_TRACE_LOG.md)。

| 检查 | 本轮实际结果 |
| --- | --- |
| 工程静态检查 | 通过：151 个工程对象、38 个工程文件；新模块进入 App / 扩展 / 核心测试，历史归档校验通过 |
| core checks | 通过：54 项场景，包括真实 127.0.0.1 TCP 回传与离线导出 |
| Swift Package XCTest | 通过：30 个方法，0 失败；29 项模型测试及包装 54 项运行时场景的测试 |
| iPhone arm64 Release 编译、归档、IPA | 通过：主 App 与扩展均为 1.0.1 / build 12；最低 iOS 17、权限、占位签名、ZIP / SHA-256 校验通过 |
| build 11 保留 | 原 IPA 校验值保持不变，未覆盖 |
| git diff --check | 通过 |
| 真实证书签名、安装及设备验收 | 未执行，由用户进行 |

新增回归覆盖触发前五秒 1 Hz 上下文、高频全部读数与 A / Δ / V / D / S、恢复 1 Hz 后缓慢变化、独立稳定判定、事件造成的短暂变化、连续 Boost 的重叠记录、生命周期与非法输入中断、写入失败不影响正式通知、独立轮转与半行修复、超过单帧容量的分页缓存、真实本机 TCP 同步第二种日志及离线导出。普通日志仍节流，旧实验与原始归档校验不变。

首次受限 core checks 的 TCP 监听被沙箱拒绝；最终在允许本机通信的环境完整运行通过。SwiftPM 复用测试路径时出现 `unknown build description`，使用全新 `BoostTraceTestsFinal` 和配套缓存完成最终 XCTest，没有跳过失败项。

本地记录为 `build/core-checks-boost-trace-final.log`、`build/core-xctest-boost-trace-final.log`、`build/static-validation-build12.log`、`build/package-ipa-build12.log` 与 `build/build12/unsigned-build.log`。包内容独立核对保存在 `build/build12/ipa-verification.json`；安装包为 `build/AutoDarkShift-1.0.1-build12-resign.ipa`，仍需证书重签。

本次 Swift Package 验证使用完整 Xcode 与新目录：

```sh
export DEVELOPER_DIR=/Users/codebh0/Downloads/Xcode.app/Contents/Developer
python3 tools/validate_project.py
python3 tools/run_core_checks.py
CLANG_MODULE_CACHE_PATH="$PWD/build/BoostTraceFinalModuleCache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/BoostTraceFinalModuleCache" \
swift test --scratch-path build/BoostTraceTestsFinal --cache-path build/BoostTraceFinalPackageCache \
  --config-path build/BoostTraceFinalPackageConfig --security-path build/BoostTraceFinalPackageSecurity \
  --disable-sandbox -Xswiftc -module-cache-path -Xswiftc "$PWD/build/BoostTraceFinalModuleCache"
bash tools/package_ipa.sh
git diff --check
```

打包脚本每次执行会继续递增 build，复现时不会覆盖 build 12。

## 2026-10-02 模型实现历史验证（build 10）

本版本按 `docs/models/MathModel-v1.md` 第 1–4 章与第 8 章开发评分和动态采样。环境为 macOS x86_64，使用下载目录中的完整 Xcode / iPhoneOS SDK，Swift 5 语言模式；没有修改系统工具链或归档中的旧版本源码。

本页记录 2026-10-02 完整本地归档的验证结果。2026-10-03 仓库整理后，历史源码、原始需求文档与产物不再随 Git 提交；本轮已按要求删除 build 8 本地归档；当前静态检查不再依赖归档元数据，历史校验结果只代表当时执行范围。

以下 build 10 结果为历史执行记录。原安装包后来被同编号打包覆盖；按用户要求已删除覆盖后的安装包、校验文件、未按 build 分目录的归档、缓存、权限文件和编译日志，未尝试恢复 build 10。当前可用产物与验证结果见本页后续 build 11 记录。

| 检查 | 实际结果 |
| --- | --- |
| `tools/validate_project.py` | 通过：147 个工程对象、37 个本地工程文件，源码归属、扩展嵌入、Scheme、plist / entitlement、协议和模块边界 |
| 历史实验归档完整性 | 通过：61 个文件匹配原 MANIFEST.json 的 SHA-256；实验组件不进入当前 Target |
| 生产 Foundation 核心直接编译和运行 | 通过：43 项回归场景 |
| Swift Package XCTest | 通过：26 个测试方法，0 失败；25 个趋势模型测试和包装 43 项回归场景的测试 |
| 真实本机 TCP 日志回传 | 通过：配置应用、状态查询、普通日志分块传输、离线缓存和错误认证拒绝 |
| iPhone arm64 Release 编译、链接和归档 | 通过：主 App 与 PacketTunnel 扩展，最低 iOS 17 |
| IPA 内容、版本和完整性 | 通过：两个组件均为 1.0.1 / build 10、arm64、最低 iOS 17；占位签名、ZIP 和 SHA-256 验证通过 |
| 真实证书签名、iPhone 安装及亮度 / VPN / 后台行为 | 未执行 |
| iOS 模拟器 XCTest | 未执行；本轮 XCTest 运行在 macOS |

模型测试覆盖 A / Δ / V / D / S 和裁剪，评分 ±0.50 等号边界、静止首值的模型边界、起点记录、常规 1 Hz 与事件的时间尺度、全部动态档位、0.20 秒固定速度窗、不均匀采样插值、0.005 噪声过滤、最近 10 次有效方向、按时间退出与低速计时重置、冷却 / 失败重试 / 去重 / 在途请求、非法数据和时间、睡眠及配置重置。

运行时回归新增变频保留观察者及有效授权候选、长采样间断不构造趋势、高速逐次评分同时限制常规磁盘写入。旧配置中的亮度阈值、普通采样间隔、稳定时间和 Boost 均被忽略；旧 schema 1 快照仍可读取，重新启动使用 1 Hz 并移除旧字段，计数和成功请求历史继续保留。保留通用的生命周期、存储失败、配置与消息确认、共享 / 本地存储、身份校验、通信退避、诊断分页与日志缓存回归。

本机沙箱禁止监听 127.0.0.1，因此包含真实 TCP 场景的最终检查在允许本机通信的执行环境完成。初次受限运行的通信失败不记为通过；最终日志为全部场景成功的实际记录。SwiftPM 在本机复用部分 scratch-path 时出现 `unknown build description`，使用新的目录完成最终构建和测试，没有修改项目来跳过失败项。

## 可重复命令

在项目根目录运行，需完整 Xcode。核心及 XCTest 中的真实 TCP 场景需要允许 127.0.0.1 监听 / 连接。缓存均写入 build/；本机再次完整验证时，建议使用新的 scratch-path。

```sh
export DEVELOPER_DIR=/Users/codebh0/Downloads/Xcode.app/Contents/Developer
python3 tools/validate_project.py
python3 tools/run_core_checks.py

CLANG_MODULE_CACHE_PATH="$PWD/build/CoreModuleCache10" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/CoreModuleCache10" \
swift test --scratch-path build/CoreTests10Delivery --cache-path build/PackageCache10 \
  --config-path build/PackageConfig10 --security-path build/PackageSecurity10 \
  --disable-sandbox -Xswiftc -module-cache-path -Xswiftc "$PWD/build/CoreModuleCache10"

bash tools/package_ipa.sh
```

打包以 `CODE_SIGNING_ALLOWED=NO` 归档，再给副本添加携带权限的本地 ad-hoc 占位签名，不读取开发者证书或描述文件。产物为 `build/AutoDarkShift-1.0.1-build10-resign.ipa`，需真实证书重签才能安装；要求见 [IPA_SIGNING.md](IPA_SIGNING.md)。构建输出中的 CoreSimulator 服务错误与打包 locale 提示没有阻止 iPhone 归档、编译和 IPA 完整性验证，不据此报告模拟器可用。

验证日志：`build/static-validation-build10.log`、`build/core-checks-build10.log`、`build/core-xctest-build10.log`、`build/package-ipa-build10.log`、`build/unsigned-build.log`。正式模型约定见 [TREND_MODEL.md](TREND_MODEL.md)，设备专项操作见 [DEVICE_ACCEPTANCE.md](DEVICE_ACCEPTANCE.md)。

## 2026-10-03 趋势与通知状态机修复复测

本轮修复恢复 1 Hz 后保留 baseline / Δ、普通采样不取消 inFlight 请求，以及 cancelled 不开始或延长 cooldown。候选生成不写入 lastAttemptAt；success / failed / blocked 沿用完成时刻的冷却规则。生命周期代次失效仍可取消未提交请求，已经调用通知中心的请求记录实际完成结果。

| 检查 | 本轮实际结果 |
| --- | --- |
| 工程静态检查 | 通过：147 个工程对象、37 个工程文件、归档隔离和校验 |
| 生产核心直接编译与 core checks | 通过：48 项回归场景 |
| Swift Package XCTest | 通过：30 个测试方法，0 失败；29 项模型测试及包装 48 项回归场景的测试 |
| git diff --check | 通过 |
| iPhone arm64 Release 归档与 IPA 打包 | 随后于 2026-10-03 通过：当前修复后的源码，两个组件均为 1.0.1 / build 11、最低 iOS 17；权限、占位签名、ZIP 和 SHA-256 校验通过 |
| 真实证书签名、iPhone 安装及设备行为 | 未执行 |

新增回归覆盖两个方向的 Δ 保留、动态退出 / 稳定轮询时快照与日志及 IPC 一致、评分回落或观测重置后仍提交原候选、重载 / 睡眠唤醒取消后立即提交新候选、取消保留此前实际请求的冷却、重复授权及结果回调只提交 / 计数一次。模型和通知输入为模拟，TCP 日志回传使用生产本机通信实现；真实端口测试在允许 127.0.0.1 监听的环境执行。

核心复测使用现有 Xcode，未修改工程或 Scheme；随后打包将共享 build 号递增到 11：

```sh
export DEVELOPER_DIR=/Users/codebh0/Downloads/Xcode.app/Contents/Developer
python3 tools/validate_project.py
python3 tools/run_core_checks.py
CLANG_MODULE_CACHE_PATH="$PWD/build/StateFixModuleCache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/StateFixModuleCache" \
swift test --scratch-path build/StateFixTests20261003 --cache-path build/StateFixPackageCache \
  --config-path build/StateFixPackageConfig --security-path build/StateFixPackageSecurity \
  --disable-sandbox -Xswiftc -module-cache-path -Xswiftc "$PWD/build/StateFixModuleCache"
git diff --check
```

本地日志：`build/static-validation-statefix-2026-10-03.log`、`build/core-checks-statefix-2026-10-03.log`、`build/core-xctest-statefix-2026-10-03.log`。按 Git 指引保留在本地，不提交构建目录。

本次打包执行 `bash tools/package_ipa.sh`，自动将 build 号从 10 递增到 11，产物为 `build/AutoDarkShift-1.0.1-build11-resign.ipa`，包含 baseline 保留、inFlight 提交和取消冷却三项修复。打包日志为 `build/package-ipa-build11.log`，编译日志为 `build/build11/unsigned-build.log`，归档为 `build/build11/AutoDarkShift.xcarchive`。产物大小为 406858 字节；独立检查包内两个 Info.plist、arm64 架构、Packet Tunnel / App Group 权限、占位签名与 ZIP / SHA-256 均通过，结果保存在 `build/build11/ipa-verification.json`。该包需用真实证书和匹配的描述文件重签后安装。

打包脚本已改为每次自动递增 build 号，归档、缓存、权限和编译日志按编号隔离，拒绝覆盖已有 IPA、校验文件和构建目录；失败构建不回退编号。错误覆盖的 build 10 产物已清理，未恢复。脚本语法、更新后的工程静态检查及 `git diff --check` 均通过，最新静态检查日志为 `build/static-validation-build11.log`。本轮打包只修改版本、打包流程及相关说明；上述 core checks 与 XCTest 的生产行为源码未再改变。
