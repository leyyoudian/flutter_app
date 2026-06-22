# ESP Baji App

Flutter 电子吧唧手机端。当前版本是 Android-first：Flutter 负责黑白极简液态玻璃界面，Android Kotlin 原生层通过 MethodChannel 负责文件选择、GIF/图片/视频转 EBAJ1、Wi-Fi AP 扫描过滤、连接、上传和亮度控制。

## 页面

- 设备连接：只显示 SSID 为 `ESP-BAJI` / `ESP-BAJI-*` 的 Wi-Fi AP。
- 素材：主界面，包含连接状态、素材导入、圆屏预览、EBAJ1 打包、上传和历史导入。
- 设备控制：屏幕亮度 `0..100` 调节，走固件 HTTP `/brightness?value=xx`。

## Wi-Fi HTTP 协议

- AP SSID：`ESP-BAJI`，开放热点。
- 状态：`GET http://192.168.4.1/status`
- 上传：`POST http://192.168.4.1/upload`，body 为 EBAJ1 包，header `X-EBAJ-CRC32` 为十六进制 CRC32。
- 亮度：`GET http://192.168.4.1/brightness?value=70`

## 本机构建

如果 Codex 沙盒不能联网下载 Gradle，请在普通 PowerShell 里运行：

```powershell
cd D:\Documents\esp-baji\app_gif
flutter pub get

$env:JAVA_HOME='D:\AndroidStdio\jbr'
$env:PATH="$env:JAVA_HOME\bin;$env:PATH"
flutter build apk --debug
```

也可以直接运行 `tools/build_debug_apk.ps1`。

当前代码没有新增 pub.dev 第三方依赖；`pub get` 只用于刷新 Flutter 生成文件。

## 说明

Kotlin 原生层使用 Android `Movie` 解码 GIF，使用 `BitmapFactory` 解码图片，使用 `MediaMetadataRetriever` 抽取视频帧，统一按 480x480 居中裁剪输出 RGB565，再选择 raw / LZ4 / XOR delta + LZ4 封装成 EBAJ1。GIF 预览会优先使用缓存里的原始 GIF 文件，因此 App 端预览可以播放动画；图片、视频和降级场景会使用 PNG 缩略图。

当前固件分区是单个 `asset=10MB` 素材槽，所以限制的是“转换后的 EBAJ1 包”不能超过 10MB，不是原始文件不能超过 10MB。默认目标 30fps；如果 EBAJ1 超过 10MB，会按 30/24/20/16/12/8fps 自动降帧，仍超限才返回错误。

当前为了支持单个 10MB EBAJ1 包，ESP32 固件改成单素材槽。代价是上传会覆盖当前素材；上传失败、取消或断电后，旧素材不再保证保留。

当前版本不再使用 BLE。素材和亮度控制都走 ESP32 开放 Wi-Fi AP + HTTP。

后续若需要 iOS 或完全跨平台，可以把原生层替换为 `flutter_blue_plus + file_picker + image + shared_preferences` 等插件路线。
