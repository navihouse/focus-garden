# 构建说明

当前机器使用上级 `work/` 中的 Flutter 3.47.7、Dart 3.13.5、JDK 21、Android SDK 35/36、Build Tools 36.0.0、NDK 28.2.13676358、Android CMake 3.22.1 和 Visual Studio 2022 C++ 工具链。`dev.ps1` 使用 P: 目录别名，避免路径空格影响原生构建。

本机 Gradle 缓存配置使用项目专用的 127.0.0.1:18884 下载缓存，依赖来自原始发布者仓库。`dev.ps1 -Action android` 在需要时自动启动此缓存服务；它不属于应用运行依赖，发布包无需开发工具或联网。

复制源码到另一台机器时，安装 Flutter 与对应平台工具链后可直接使用标准命令：

```powershell
flutter pub get
flutter analyze
flutter test
flutter build windows --release --target lib/main.dart
```

Android：创建自己的签名密钥，在 `android/key.properties` 中配置 `storeFile`、`storePassword`、`keyAlias`、`keyPassword` 后运行 `flutter build apk --release --target lib/main.dart`。当前设备的私人签名密钥在上级 `work/signing/`，不包含在源码包内。已有用户更新必须继续使用原密钥。

`lib/smoke_main.dart` 与 `test_support/native_probe.dart` 是隔离数据目录下的原生验证入口。生产构建始终使用 `lib/main.dart`。`package-release.py` 仅归档现有产物，运行前须确认它们来自生产入口。

`test_support/desktop_integration_probe.dart` 配合 `verify-desktop-integration.py <probe.exe> <空结果目录>` 验证真实 Windows 自启动注册、物理程序路径、隐藏启动、托盘恢复和退出。脚本会暂时改写当前用户的 FocusGarden 自启动项，并在 finally 中恢复原值；不操作已有应用窗口或个人数据库。验证完成后必须重新构建生产入口，再打包。

`test_support/workflow_probe.dart` 配合 `verify-workflow.py <probe.exe> <空结果目录>` 验证 Windows 原生置顶、任务提示音、完成置底、删除保存及托盘退出。1.3.0 增加实际短计时验证：第四次完成自动长休息、休息结束等待手动开始、两种到点提示音，确认只保存专注记录。全程使用独立数据库。`package-release.py` 将桌面产物放在 `releases/FocusGarden-<版本>-Windows-x64/FocusGarden-Windows-x64/`，避免覆盖仍在运行的旧版文件。

1.3.1 的原生验证还会打开任务详情、勾选子任务、检查音效错误、请求滚动至日期并验证名称位置，最后点击保存并核对结果。截图与结果写入指定空结果目录，不使用个人数据库。
