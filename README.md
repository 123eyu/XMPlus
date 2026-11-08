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

- 多账号登录、专辑搜索、播放队列、在线收听和听时记录。
- 下载任务、本地媒体管理、可选转码与音频标签；自动下载需单独启用。
- Android 安装包内含源码构建的 FFmpeg / FFprobe 和 LAME，支持原始流保存、MP3、M4A、M4B、FLAC、标签及封面处理。
- 备份设置、书架、历史和可选账号信息；含登录凭据的备份未加密，请妥善保管。
- 播放与下载设置、持久音频地址缓存、主题和 GitHub 稳定版更新检查。


## 下载

从 [Releases](https://github.com/teikengstudio/XMPlus/releases) 下载。


## 编译

工具链：Flutter 3.47.9 / Dart 3.13.7、Java 25、Gradle 9.9.0、AGP 9.5.1、Kotlin 2.4.21；Android `compileSdk` / `targetSdk` 为 36，NDK 为 28.2.13676358。依赖版本和校验值锁定在 `pubspec.lock`。

先在 Linux x86_64 安装 Android NDK 28.2.13676358、`jq`、`make`、`tar`、`sha256sum`（构建 x86_64 时还需 `nasm`），再运行：

```sh
flutter pub get --enforce-lockfile
bash tool/build_android_media.sh
flutter build apk --release --split-per-abi --no-pub
```

正式 Android 构建必须配置 JKS 签名环境变量：`ANDROID_KEYSTORE_PATH`、`ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_PASSWORD`、`ANDROID_KEY_ALIAS`。签名材料不得提交到仓库。

Windows 构建命令见 `licenses/native/SOURCE-MATERIALS-INCOMPLETE.txt`。


## 许可与安全

项目按 [AGPL-3.0-or-later](LICENSE) 提供。第三方组件保留各自许可与版权声明，详见 [NOTICE](NOTICE) 和 `licenses/`；发布时须履行对应源码提供义务。

本项目与喜马拉雅无隶属、合作或背书关系。请遵守平台规则、版权及当地法律。反馈问题时请附应用版本、系统版本和复现步骤；不要上传 Cookie、令牌、账号备份或签名私钥。

## 致谢与交流

- [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus)：界面与 Windows runner 参考。
- [LinuxDo](https://linux.do/)
- [Flutter](https://flutter.dev/) · [media-kit](https://github.com/media-kit/media-kit) · [Dio](https://pub.dev/packages/dio) · [FFmpeg](https://ffmpeg.org/)
- [GitHub Issues](https://github.com/teikengstudio/XMPlus/issues) · [Telegram](https://t.me/+csbfHjIyqkoyNDA1)
