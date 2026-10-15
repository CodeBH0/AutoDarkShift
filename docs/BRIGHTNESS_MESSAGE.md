# 历史：类型化亮度消息业务

本文入口只保留历史提示。1.0.3 曾引入 `UIScreen.BrightnessDidChangeMessage`，要求 iOS 26；当时暂停编译是该轮源码交付限制。1.1.0 / build 1 也曾保留此消息路径。

**1.1.0 / build 2 已彻底移除该输入路径。** 当前 App 内监控使用 1.0.3 / build 2（`a7015e5`）的 `BKSDisplayBrightnessGetCurrent` 纯轮询，实现与验收见 [BACKBOARD_MONITORING.md](BACKBOARD_MONITORING.md)。最低系统为 iOS 17，不再要求类型化消息 API 或 iOS 26。

旧 `MessageMonitoring` 仅只读导出历史运行与 Boost 日志，不注册观察者、不采样，也不把旧启用状态迁移为 BackBoard 启用状态。历史实现可从 Git 查询，不用于恢复当前消息采样路径。
