# AutoDarkShift 开发指引

- 开始修改前阅读 `DEVELOPMENT.md`，按需要查阅 `docs/ARCHITECTURE.md`、`docs/TREND_MODEL.md` 和 `docs/DEVICE_ACCEPTANCE.md`。
- 根目录 `README.md` 保留从 GitHub 下载的用户说明。其算法说明可能落后于当前源码；当前版本以 `Config/Project.xcconfig`、趋势模型文档和生产实现为准，不据旧 README 恢复阈值算法。
- Xcode 工程和两个共享 Scheme 已提交，可直接打开。工程生成脚本会覆盖工程和 Scheme；修改工程结构时同步维护生成脚本，避免无关重建。
- 源码、测试、公共配置和文档应提交；遵守 `.gitignore`，设备日志、构建产物、归档安装包、个人签名配置和证书留在本地。不要强制添加被忽略的文件。
- `archive/` 只提交历史轮询实验的说明与校验清单；旧源码、产物和原始需求文档按云端整理留在本地并忽略。需要旧源码时查阅原始提交 `0cb2f8c`，不用归档版本覆盖当前实现。
- 修改工程或仓库配置后运行 `python3 tools/validate_project.py`，并检查 `git diff --check`。核心行为修改再运行 `python3 tools/run_core_checks.py` 和 Swift Package XCTest；真实 TCP 场景需要允许本机监听，相关环境要求见 `docs/STATIC_VALIDATION.md`。
- 编译、模拟输入测试和占位签名不代表真机验收通过；只报告实际执行的验证范围。
