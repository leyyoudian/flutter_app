# iOS 与 Android 1.0.53 同步核对

用户要求核对动画上传、黑底启动 Logo、背包卡片及其他既有流程，发现问题先修，检查通过后推送 GitHub 供 Codemagic 构建。

## 发布范围

App 源码版本为 1.0.53+55，Android 同版本已发布主备服务器。此次 GitHub 同步包含当前实际 App/资源/测试及 CI 配置，不包含本地固件、服务器、私钥、构建产物或手机调试记录。取消的新游戏和个人创作工具不恢复。

- 制作/封面：Android 和 iOS 共用 Flutter 页面；名称留空及自动命名、0.5–4 倍缩放、GIF/视频封面帧、静态图片封面和预览取景修复一致。
- 上传：iOS 保留素材审批/硬件参数、包下载、热点接入、TCP 分段行响应、素材身份确认、安装真实进度及失败恢复桥接。权限与热点 entitlement 已接入 Runner 工程。
- 启动：iOS LaunchScreen 黑底高清 LaunchLogo 资源已接入资源编译；Flutter 共用 StartupLogoSplash 完成 1.25 秒图标动效后显示已有页面。
- 背包：Sharingan/Faceit 卡片、封面、素材目录和展开后的选择逻辑共用；测试分别运行 Android/iOS 平台变体。
- 云端目录：App 的固件静态契约测试兼容整理前后两种仓库布局，仍要求真实源码存在；没有跳过断言或把本地固件混入 App 发布。

## 验证与边界

最终证据见 `artifacts/ios-parity-2026-10-30/`。使用独立 Git 索引构建发布树，再导出实际待提交快照运行 Flutter 测试和分析，核对所有静态资源、两份 Codemagic 配置和 iOS 原生桥接检查。

Windows 本地不能执行带 ImageIO/AVFoundation/CryptoKit 的 Swift 测试或 Xcode Runner 编译。两条 Codemagic macOS 工作流均已配置运行四组生产 Swift 提取测试、Flutter 回归及相应 iOS release 构建。本地源码检查通过不能等同于 IPA 构建或 iPhone 真机上传/播放已通过，最终原生编译、签名及设备行为仍需云端/真机证据。

推送只使用独立索引与快进提交；真实索引、工作树、HEAD 和当前分支保留。没有手动触发 TestFlight/App Store 发布、手机安装或固件操作。GitHub 提交与远端核对结果以 `github-publication.json` 为准。
