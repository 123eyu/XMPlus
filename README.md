<div align="center">
  <img width="160" height="160" src="assets/branding/xmplus.png" alt="XMPlus">
  <h1>XMPlus</h1>
  <p>使用 Flutter 开发的喜马拉雅第三方下载与收听客户端</p>

  [![Android CI](https://github.com/teikengstudio/XMPlus/actions/workflows/android.yml/badge.svg)](https://github.com/teikengstudio/XMPlus/actions/workflows/android.yml)
  [![GitHub release](https://img.shields.io/github/v/release/teikengstudio/XMPlus)](https://github.com/teikengstudio/XMPlus/releases/latest)
  [![GitHub downloads](https://img.shields.io/github/downloads/teikengstudio/XMPlus/total)](https://github.com/teikengstudio/XMPlus/releases)
  [![License](https://img.shields.io/badge/license-AGPL--3.0--or--later-blue)](LICENSE)
</div>

<br/>

## 适配平台

- Windows x64：桌面界面、在线收听与下载。
- Android：独立签名 APK，通过 GitHub Actions 编译；具体支持范围与已知限制见对应发行说明。

Windows 现有本地候选包的第三方原生组件对应源码材料尚不完整，**不作为本仓库的公开二进制发行包**。详情见 [材料缺口说明](licenses/native/SOURCE-MATERIALS-INCOMPLETE.txt)；源码公开不表示该缺口已经解决。

Android 首版提供客户端基础界面和在线收听；现有下载落盘、媒体完整性校验与转码依赖桌面 FFmpeg / FFprobe，Android 包尚未集成这些原生工具，相关任务会明确报错，不应视为可用的离线下载功能。后续需完成原生媒体处理及其对应源码分发后再开放。

## 功能

- [x] 短信登录、极验验证与多账号管理
- [x] 专辑搜索、声音列表与在线收听
- [x] 播放队列、进度记忆、音质选择与定时停止
- [x] 下载任务管理、自动下载与本地音频管理
- [x] 媒体处理与标签配置（依赖可用的 FFmpeg / FFprobe）
- [x] 听时记录与扣时核对
- [x] 持久化音频地址缓存，按账号会话与实际音质隔离
- [x] 主题、播放与下载设置
- [x] 配置备份与恢复
- [x] 应用内检查 GitHub 稳定版更新

缓存地址不等于预付下载权益。在线收听仍遵循平台授权与正常计时；仅原任务已确认的整集预扣收据避免重复预扣。

<br/>

## 下载

从 [Releases](https://github.com/teikengstudio/XMPlus/releases) 下载对应版本。Android 根据设备选择 `arm64-v8a`、`armeabi-v7a` 或 `x86_64` APK；同一应用的后续版本应保持相同签名，避免卸载造成资料丢失。

应用内可在「设置 → 关于」手动检查更新，并配置启动自动检查（默认开启）、忽略某一版本或恢复提醒。版本比较读取真实安装包版本，只检查本仓库的 GitHub 稳定版；通过系统浏览器打开匹配当前架构的 APK / Windows ZIP，无匹配产物时打开该版本发布页，不会静默下载安装。

## 编译

当前工具链固定为 **Flutter 3.47.5 / Dart 3.13.4**；Android 使用 Java 17、Gradle 8.14.3、AGP 8.13.0 与 Kotlin 2.2.20，以兼容现有原生插件。依赖版本和归档校验值见 `pubspec.lock`，CI 从官方 `pub.dev` 获取并强制校验。

```sh
flutter pub get --enforce-lockfile
flutter build apk --release --split-per-abi
```

Android 正式构建需要配置签名；不使用 debug 证书冒充正式发行。GitHub Actions 使用以下仓库 Secrets：

| Secret | 内容 |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | JKS 签名文件的 Base64 |
| `ANDROID_KEYSTORE_PASSWORD` | 密钥库密码 |
| `ANDROID_KEY_PASSWORD` | 私钥密码 |
| `ANDROID_KEY_ALIAS` | 签名别名 |

私钥、密码与 `key.properties` 不得提交到仓库。请单独备份签名材料；丢失签名会影响后续覆盖升级。

本地正式构建读取环境变量 `ANDROID_KEYSTORE_PATH`（JKS 绝对路径）、`ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_PASSWORD`、`ANDROID_KEY_ALIAS`；CI 会把 Base64 Secret 解码到临时文件后设置路径。缺少签名时正式构建直接失败。

Android 原生音频库的固定构建配方、组件源码归档、许可证及已知浮动输入见 [`licenses/android/SOURCES.json`](licenses/android/SOURCES.json)。应用内「查看许可」也可阅读完整声明，源码归档不打入 APK。

推送 `main` 或提交 PR 会触发 Android 编译验证；手动触发可生成构建产物，`v*` 标签用于正式发行。版本号来自 `pubspec.yaml`，发行标签应与之对应。详细步骤以 [Android 工作流](.github/workflows/android.yml) 为准。

Windows 需要 Visual Studio C++ 构建工具。`tool/build_windows.ps1` 保留本地候选包及对应源码校验流程；材料缺口关闭前不得将 `-LocalCandidate` 产物作为正式公开包。

<br/>

## 声明

本项目是独立的第三方客户端，与喜马拉雅官方无隶属、合作或背书关系。接口来自官方服务，不提供付费内容破解或访问权限绕过。请遵守平台规则、版权及当地法律，仅处理自己有权访问的内容。

本项目按 [AGPL-3.0-or-later](LICENSE) 提供，不作任何担保。第三方组件保留各自许可证和版权声明，详见 [NOTICE](NOTICE) 与 `licenses/`；项目许可证不替代第三方组件的分发义务。

## 致谢

- [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus)：Material 界面、Windows runner、更新交互与 CI 组织方式的参考。固定参考修订为 `d9e9626f1a3f89cd9ca85e18f61aaba02634e12a`。
- [Flutter](https://flutter.dev/)
- [media-kit](https://github.com/media-kit/media-kit)
- [Dio](https://pub.dev/packages/dio)
- [FFmpeg](https://ffmpeg.org/)
- 其余组件及历史来源见 [NOTICE](NOTICE)。

## 交流

- [GitHub Issues](https://github.com/teikengstudio/XMPlus/issues)
- [Telegram](https://t.me/+csbfHjIyqkoyNDA1)

反馈问题时请附应用版本、系统版本与复现步骤，不要上传 Cookie、登录令牌、账号备份或私钥。
