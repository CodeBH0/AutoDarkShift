# AutoDarkShift 开发指引

- 开始修改前阅读 `DEVELOPMENT.md`，按需要查阅 `docs/ARCHITECTURE.md`、`docs/TREND_MODEL.md` 和 `docs/DEVICE_ACCEPTANCE.md`。
- 根目录 `README.md` 保留从 GitHub 下载的用户说明。其算法说明可能落后于当前源码；当前版本以 `Config/Project.xcconfig`、趋势模型文档和生产实现为准，不据旧 README 恢复阈值算法。
- Xcode 工程和两个共享 Scheme 已提交，可直接打开。工程生成脚本会覆盖工程和 Scheme；修改工程结构时同步维护生成脚本，避免无关重建。
- 源码、测试、公共配置和文档应提交；遵守 `.gitignore`，设备日志、清洗 CSV、分析过程文件、构建产物、归档安装包、个人签名配置和证书留在本地。不要强制添加被忽略的文件。
- 数学模型放在 `docs/models/`，新版本另写文件并保留旧版本。原始设备日志放在 `local-data/device-logs/`，清洗和分析输入放在 `local-data/analysis/`，原始需求资料放在 `local-data/reference/`；整个 `local-data/` 不提交且不进入构建。
- 项目内 build 8 轮询实验归档已删除。需要历史源码时查阅原始提交 `0cb2f8c`，不用旧源码覆盖当前实现；`build/` 中已有 IPA 和构建记录继续按 build 保留。
- 修改工程或仓库配置后运行 `python3 tools/validate_project.py`，并检查 `git diff --check`。核心行为修改再运行 `python3 tools/run_core_checks.py` 和 Swift Package XCTest；真实 TCP 场景需要允许本机监听，相关环境要求见 `docs/STATIC_VALIDATION.md`。
- 编译、模拟输入测试和占位签名不代表真机验收通过；只报告实际执行的验证范围。
- 每次打包必须递增 build 号，主 App 与扩展保持一致；使用 `tools/package_ipa.sh` 自动递增。已有 IPA、校验文件、归档和日志按 build 保留，不覆盖、不回退构建号。
