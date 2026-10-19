# 专注花园 / Focus Garden

Windows 与 Android 离线番茄钟，使用 Flutter、SQLite/Drift、Windows 本地播放器和 Android Kotlin/Media3 服务。

- `app/`：Flutter 源码、Android Kotlin 后台服务、Windows 原生集成、测试与构建脚本。
- `app/lib/`：计时、任务、音乐、历史、统计报告及备份合并。
- `app/android/` 与 `app/windows/`：原生平台集成。
- `app/test/` 与 `app/test_support/`：自动测试及隔离数据的原生验证入口。
- `app/scripts/`：开发、签名、归档与隐私检查脚本。

支持可调番茄钟、任务关联、本地音乐联动、周/月/年报告、北京时间跨日统计，以及带冲突预览的 JSON 备份合并。Windows 1.0.1 支持待机音乐试听。

使用说明见 [app/README.md](app/README.md)，跨机器构建步骤见 [构建说明](app/scripts/README.md)。

本机工具、构建产物、音乐、个人记录、设备日志及私人签名材料不纳入 Git。隐私检查范围与结果见 [PRIVACY_CHECK.md](PRIVACY_CHECK.md)。

最近验证：15 项自动测试、Windows 25 分钟实跑、四种音频解码，以及 Windows 1.0.1 的 17 项音乐回归。Android 锁屏与后台行为、Windows 实际睡眠与重启仍需对应设备验收。
