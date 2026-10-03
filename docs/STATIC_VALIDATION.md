# 验证记录（1.0.1 / build 10，2026-10-02）

本版本按 `MathModel v1.md` 第 1–4 章与第 8 章开发评分和动态采样。环境为 macOS x86_64，使用下载目录中的完整 Xcode / iPhoneOS SDK，Swift 5 语言模式；没有修改系统工具链或归档中的旧版本源码。

本页记录 2026-10-02 完整本地归档的验证结果。2026-10-03 仓库整理后，历史源码、原始需求文档与产物不再随 Git 提交；新检出的静态检查只要求当前工程和归档元数据齐全，历史文件存在时仍检查原校验值。

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
