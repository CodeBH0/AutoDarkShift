# 验证记录（当前 1.0.1 / build 13）

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
