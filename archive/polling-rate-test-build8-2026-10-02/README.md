# 轮询率测试归档（build 8）

2026-10-02，用户确认测试已完成，当前 build 9 已拆除轮询 Boost、自动逐档测试和频率统计。本目录保存拆除前的完整源码基线、说明、测试以及 build 8 待重签安装包。此目录不参与当前 App、扩展或 Swift Package 的编译。

## 内容

- `source/`：拆除前 build 8 工程，包括 App、PacketTunnel、共享核心、平台适配、回归测试、构建工具和文档；未复制本机签名覆盖配置或 Xcode 用户设置。
- `source/docs/POLLING_BOOST.md`：1…1000 Hz、每档 10 秒的测试流程、统计字段及判定说明。
- `artifacts/AutoDarkShift-1.0.0-build8-resign.ipa`：保留测试功能的安装包，仍需自行重签 App 与扩展。
- `artifacts/`：本地已有的 build 7 诊断输入和 build 8 验证日志。用户确认测试完成，但本次未提供新的真机结果文件，因此归档未推断或填入真实 API 频率上限。
- `MANIFEST.json`：归档文件相对路径与 SHA-256，可检查源码、安装包及记录是否完整。

## 已拆除组件

| 组件 | 原始位置（均在 source/ 下） |
| --- | --- |
| Boost 档位与测试入口 | App/ControlView.swift、App/AppController.swift |
| 档位配置、测试命令与统计模型 | Shared/Models.swift、Shared/ServiceContracts.swift |
| 自动逐档、取消/恢复、分档与汇总统计 | Monitoring/SwitchMonitor.swift |
| 亮度 getter 耗时测量 | Platform/ScreenBrightnessSampler.swift |
| 测试控制传输 | Monitoring/MonitorControlEndpoint.swift、Monitoring/LocalMonitoringClient.swift、KeepAlive/VPNKeepAliveService.swift |
| 测试结果写入与独立轮转 | Shared/SharedStore.swift |
| 测试专用回归场景 | Tests/RuntimeRegressionScenarios.swift |

当前版本保留普通 `pollInterval` 设置、亮度事件、阈值通知，以及 build 8 修复的 Provider Message / 认证本机 TCP、分页日志回传、App 持久缓存与离线导出。旧配置里的 `pollingBoost` 和旧快照里的 `pollingTestID` 会被忽略，按原来的普通采样间隔运行。已有 `polling-results-*.jsonl` 仅供读取和导出，当前版本不会继续写入、修复或删除它们。

## 查看与复现

只需阅读测试实现时，在 `source/` 中查阅上述文件。需要独立复现测试版时，复制整个 `source/` 到另外的目录，再打开其中的 `AutoDarkShift.xcodeproj`，或在副本中运行 `python3 tools/run_core_checks.py` / `bash tools/package_ipa.sh`。采用完整 Xcode；回归包含仅本机的 TCP 测试。安装包须重签，归档不包含开发者证书。

重新集成个别组件时，以当前版本为基础审查相应文件的差异；不要直接覆盖当前共享通信与存储实现。当前主工程明确排除 `archive/`，将归档源码留在这里不会恢复任何运行入口。
