# 更新日志

## 1.1.0

- Android 加入源码构建的 FFmpeg / FFprobe 和 LAME，支持原始流、MP3 / M4A / M4B / FLAC、标签及封面处理。
- 修复 Android 极验验证、官方音频跳转、外置存储安全保存和备份声音 ID 恢复。
- 升级 Flutter 3.47.9、Gradle 9.9.0、AGP 9.5.1、Kotlin 2.4.21 与 Android API 36；支持预测性返回和横屏、平板系统栏避让。
- Android 三 ABI 正式签名 APK；真机 WebView、外置存储及系统手势仍待验收。

## 1.0.0

XMPlus 首个发行版。

- 提供多账号、专辑搜索、在线收听、播放队列和应用内更新检查。
- Android 三 ABI 正式签名 APK；应用 ID `teikengstudio.xmplus`，最低 Android API 24。
- GitHub Actions 验证签名、包名、版本和发行校验值。

### 1.0.0 首版限制

- 首版 Android APK 未包含 FFmpeg / FFprobe，不支持离线媒体处理；这只描述 1.0.0 原始发行包。
- 当时未完成 Android 真机登录、极验和播放验收；当前未发行候选同样尚待真机验收。
- 首版因 Windows 第三方原生组件对应源码材料不完整，未公开发行 Windows 二进制；当前构建已更换原生组件来源。

请勿向 Issues 上传账号备份、Cookie、令牌或签名私钥。
