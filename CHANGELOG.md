# 更新日志

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
