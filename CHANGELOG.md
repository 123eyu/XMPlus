# 更新日志

## 未发行

- Android 随 APK 提供源码构建的 FFmpeg 9.0.2 / FFprobe 和 LAME 3.100，覆盖 arm64-v8a、armeabi-v7a、x86_64；仅从系统安装的原生目录执行，不下载可执行代码。
- 恢复 Android 的原始流保留、MP3 / M4A / M4B / FLAC 转换、标签与 PNG / JPEG 封面处理；下载准备、入队和重试在预扣听时前实际核验随附工具。
- Android 忽略从桌面备份恢复的工具路径，保留现有进程取消、超时、输出限制和失败时源缓存保留策略。
- 新增固定源码、校验值及配置记录的原生构建 CI；Android 自有工具使用 API 24 与 16 KiB ELF 页面对齐。
- Windows 不再分发来源无法完整追溯的 Gyan / 2023 libmpv 二进制，改为固定源码自建的 FFmpeg / FFprobe / libmpv；公开打包要求完整源码、构建配方、可重新链接的对象及校验收据。
- Windows 不再捆绑 MSVC CRT，提供微软官方运行库前置依赖链接；新增独立输出目录，保留现有候选包，且不会自动终止正在运行的客户端。
- 安装包与 Windows 运行 ZIP 不包含源码、SDK、构建日志、校验收据或重链接对象；这些材料只保留在独立开发目录，不作为软件附件混入。
- 验证：Android 模拟器通过真实免费下载、MP3/M4A/M4B/FLAC、原始流哈希、PNG/JPEG 封面、取消保源及缺失工具预扣前拒绝；Windows 通过同类媒体处理和原生 libmpv 静默输出的播放/暂停/跳转/结束验证。本机无可用声音输出设备，未声称完成扬声器出声验收。

## 1.0.0

XMPlus 首个发行版。

- 基于 Flutter 的 Material 界面、多账号管理、专辑搜索、播放队列与在线收听。
- 设置 → 关于：真实安装包版本、启动自动检查、手动检查、忽略版本与恢复提醒。仅查询本仓库 GitHub 稳定版，通过系统浏览器获取对应平台/架构的更新，不静默下载安装。
- Android 独立正式签名，提供 `arm64-v8a`、`armeabi-v7a`、`x86_64` APK；应用 ID 为 `teikengstudio.xmplus`，最低 Android 7.0（API 24）。
- GitHub Actions 在 main / PR 编译验证；标签发行构建逐个校验签名、包名、版本与 SHA-256。

### 当前限制

- Android 未集成下载处理所需的 FFmpeg / FFprobe，下载落盘、媒体校验、转码与依赖这些流程的离线功能不可用；在预扣听时与媒体下载前明确拒绝，不伪造成功。
- Android 尚未完成真机登录、极验与音频播放验收。编译与签名校验不代表设备端功能验收。
- Windows 现有本地候选包仍有第三方对应源码材料缺口，不随此版本公开发布。详情见 `licenses/native/SOURCE-MATERIALS-INCOMPLETE.txt`。
- 第三方原生音频库保留各自许可证与来源；Android 配方和来源材料见 `licenses/android/`，Windows 既有材料缺口声明不因本次 Android 构建而解除。

请勿向 Issues 上传账号备份、Cookie、令牌或签名私钥。
