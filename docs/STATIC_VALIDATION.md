# 验证记录（build 9，2026-10-02）

当前版本已拆除并归档轮询率测试组件。环境为 macOS x86_64，完整 Xcode 16.2（16C5032a）/ iOS 18.2 SDK，Swift 5 语言模式。通过 `DEVELOPER_DIR` 使用现有 Xcode，未修改系统工具链。

| 检查 | 实际结果 |
| --- | --- |
| `tools/validate_project.py` | 通过：147 个工程对象、37 个本地文件，源码归属、扩展嵌入、Scheme、plist/entitlement、协议及模块边界 |
| 测试组件拆除与归档隔离 | 通过：活动源码无 Boost、扫描控制、测试统计或 getter 耗时测量；Xcode 不引用归档，Swift Package 排除 archive/ |
| 归档完整性 | 通过：61 个文件均匹配 MANIFEST.json 中的 SHA-256，包含 build 8 源码基线和待重签安装包 |
| 生产 Foundation 核心直接编译与运行 | 通过：41 项回归场景 |
| Swift Package XCTest | 通过：21 个测试方法，0 失败；20 个阈值测试及包装 41 项回归场景的测试 |
| 真实本机 TCP 日志链路 | 通过：配置应用、实际状态查询、超过 4 KiB 的普通日志分块回传、缓存重开与离线导出、错误认证拒绝 |
| iPhone arm64 Release 编译、链接和归档 | 通过：主 App 与 PacketTunnel 扩展，最低 iOS 17 |
| IPA 内容与完整性 | 通过：App/扩展均为 build 9、协议 3；两个可执行文件无已拆除测试符号，保留历史记录只读导出；占位签名、ZIP 与 SHA-256 验证通过 |
| build 9 真实证书签名与设备安装 | 未执行 |

本轮新增或改写的回归验证：旧 Boost 配置和未完成测试快照正常加载，使用保存的普通采样间隔且不恢复逐档测试；保存后移除旧测试字段；已退役的控制指令明确拒绝且不改变采样；历史结果文件经过普通日志轮转仍能导出，导出跳过残片但不改写原文件；短采样间隔继续评估每次读数并持久保存通知结果，同时限制常规磁盘写入。

保留的通用回归覆盖监听生命周期、旧回调取消、通知结果与历史落盘、配置重载、授权恢复、去重、存储失败清理、同进程客户端、控制端点、身份校验、nil/超时重试、迟到或重复回复、取消、坏 JSON、日志尾部修复、阈值边界、共享/本地存储模式、保活开关生命周期、查询退避、原始通信探针、串行备用通道、固定分页快照和缓存完整性。真实 TCP 场景使用生产通信与存储实现，亮度与通知输入仍为模拟。

旧版频率测试场景与原验证记录已随源码归档，见 [轮询率测试归档](../archive/polling-rate-test-build8-2026-10-02/README.md)。用户已确认测试完成；本轮没有据模拟回归推断真实亮度 API 的频率上限。

## 可重复命令

在项目根目录运行，需要完整 Xcode。本机 TCP 回归需要允许 127.0.0.1 套接字监听和连接。SwiftPM 与模块缓存均放入项目 build/；再次完整验证时建议更换 scratch-path，避免本机 SwiftPM 旧构建描述问题。

```sh
export DEVELOPER_DIR=/Users/codebh0/Downloads/Xcode.app/Contents/Developer
python3 tools/validate_project.py
python3 tools/run_core_checks.py

CLANG_MODULE_CACHE_PATH="$PWD/build/CoreModuleCache9" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/CoreModuleCache9" \
swift test --scratch-path build/CoreTests9Final --cache-path build/PackageCache9 \
  --config-path build/PackageConfig9 --security-path build/PackageSecurity9 \
  --disable-sandbox -Xswiftc -module-cache-path -Xswiftc "$PWD/build/CoreModuleCache9"

bash tools/package_ipa.sh
```

构建脚本以 `CODE_SIGNING_ALLOWED=NO` 归档，再给打包副本添加携带权限的本地 ad-hoc 占位签名，不读取开发者证书或描述文件。产物为 `build/AutoDarkShift-1.0.0-build9-resign.ipa`；重签要求见 [IPA_SIGNING.md](IPA_SIGNING.md)。构建输出中的 CoreSimulator 服务与 locale 提示未阻止 iPhone 归档和打包。

验证日志：`build/core-checks-build9.log`、`build/core-xctest-build9.log`、`build/package-ipa-build9.log`、`build/unsigned-build.log`。本轮没有运行模拟器 XCTest，Swift Package 测试运行在本机 macOS。日志链路结构和当前版本复测步骤见 [LOG_TRANSPORT.md](LOG_TRANSPORT.md)。
