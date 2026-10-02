# 验证记录（build 8，2026-10-02）

环境：macOS x86_64，完整 Xcode 16.2（16C5032a）/ iOS 18.2 SDK，Swift 5 语言模式。通过 `DEVELOPER_DIR` 选择下载目录中的 Xcode，未修改系统的 Xcode 选择或工具链。

| 检查 | 实际结果 |
| --- | --- |
| 工程生成与 `tools/validate_project.py` | 通过：147 个工程对象、37 个本地文件，三 Target 源码、扩展嵌入、两个 Scheme、plist/entitlement/协议与存储模式 |
| 模块边界 | 通过：监听核心无 UIKit/NetworkExtension/AVKit/UserNotifications，控制器/界面无 NetworkExtension，当前仍选 VPN |
| 生产 Swift 文件与回归源码编译 | 通过：iPhone 归档与 Foundation 测试分别覆盖对应源码 |
| 生产 Foundation 核心直接编译与运行 | 通过：44 项回归场景 |
| Swift Package XCTest | 通过：21 个测试方法、0 失败；20 个阈值测试 + 执行 44 项回归场景的包装测试 |
| iPhone arm64 Release 编译、链接和归档 | 通过：主 App 与 PacketTunnel 扩展，最低 iOS 17 |
| IPA 打包与完整性 | 通过：build 8、协议 3、两种受支持存储模式、组件标识符与权限、占位签名、ZIP、SHA-256 |
| 真实证书签名、provisioning、安装 | 未执行 |
| build 8 真机行为 | 未执行；build 5 的设备日志与用户体验另见 LOG_REPAIR.md |

build 7 新增的 7 项回归继续通过：旧配置与 Boost 全部档位、轮询统计/单调时钟/事件隔离、高频存储节流与阈值通知、完整扫描与重复请求、停止/睡眠/重载/异常终止、端点与同进程控制、测试日志独立保留与尾部修复。扫描流程使用模拟读数，最高合格档位的真实数值需在 iPhone 上运行测试后确定。详见 [POLLING_BOOST.md](POLLING_BOOST.md)。

build 6 新增的 3 项回归继续通过：实际 nil 回复只标记不可读取而不停止独立监听、不伪造心跳；连续无回复逐步退避且回复恢复/新会话后重置；坏 JSON 与身份拒绝仍归为明确错误。

build 5 的 8 项回归继续通过：共享不可用时明确选择本地存储、Provider 严格执行选择、完整配置经本地通信应用且查询不产生心跳、缺失/失配/非法配置不覆盖旧配置、NSError 序列化保留启动原因、开关跟随生命周期与外部断开、启动失败复位、异步准备时阻止重复启动。

此前 21 项场景继续覆盖监听生命周期、旧回调取消、通知结果落盘、重载配置、授权恢复、去重历史、存储失败清理、同进程客户端、控制端点、身份校验、nil / 超时重试、迟到/重复回复、取消、坏 JSON、日志残片修复和阈值边界。测试使用生产 `Shared/` 与 `Monitoring/` 源码；模拟采样和通知不能验证设备实际读数、调度或展示。

本轮新增 5 项回归涵盖原始消息探针与帧限制、串行备用通道与会话取消、固定分页快照及 UTF-8/并发、缓存完整性，以及真实本机 TCP 将完整轮询结果写入离线可导出的缓存。真实链路测试只连接 127.0.0.1；亮度输入仍模拟，详见 [LOG_TRANSPORT.md](LOG_TRANSPORT.md)。

## 可重复命令

以下在项目根目录运行。SwiftPM 缓存和模块缓存显式放在 `build/`，避免本机默认缓存权限问题：

```sh
export DEVELOPER_DIR=/Users/codebh0/Downloads/Xcode.app/Contents/Developer
python3 tools/validate_project.py
python3 tools/run_core_checks.py

CLANG_MODULE_CACHE_PATH="$PWD/build/CoreModuleCache8" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/CoreModuleCache8" \
swift test --scratch-path build/CoreTests8Final --cache-path build/PackageCache8 \
  --config-path build/PackageConfig8 --security-path build/PackageSecurity8 \
  --disable-sandbox -Xswiftc -module-cache-path -Xswiftc "$PWD/build/CoreModuleCache8"

bash tools/package_ipa.sh
```

构建脚本使用 `CODE_SIGNING_ALLOWED=NO` 归档，再对打包副本添加本地 ad-hoc 占位签名，不读取开发者证书或描述文件。产物：`build/AutoDarkShift-1.0.0-build8-resign.ipa`。详细重签要求见 [IPA_SIGNING.md](IPA_SIGNING.md)。

实际构建日志为 `build/unsigned-build.log`，打包日志为 `build/package-ipa-build8.log`，独立回归日志为 `build/core-checks-build8.log`，XCTest 日志为 `build/core-xctest-build8.log`。本轮 loopback 集成测试需要允许本机套接字，沙箱执行曾返回 Operation not permitted；授权仅本机测试后使用 build/CoreTests8Final 重新编译，21 个测试全部通过。早先 CLT 的重复 SwiftBridging 与 PackageDescription 问题已通过使用现有完整 Xcode 避开。

原始 build 5 日志记录连接与读取受限；用户反馈功能正常，保留为使用观察。缺少心跳/消息/完整日志时，将对应诊断项记为不可观测，不据此宣称功能失败或全部通过。build 8 频率测试见 [POLLING_BOOST.md](POLLING_BOOST.md)，既有设备验收见 [LOG_REPAIR.md](LOG_REPAIR.md) 和 [DEVICE_ACCEPTANCE.md](DEVICE_ACCEPTANCE.md)。
