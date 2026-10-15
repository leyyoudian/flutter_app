# iOS / Android 一致性与 Codemagic 交付

当前目标版本：**1.0.31+33**（一致性修改最初交付于 1.0.30+32）。本次以当前 Android 的共享 Flutter 界面和功能流程为基准同步 iOS。

## 界面及互动

- App 明确使用同一套 Android Material 主题，统一返回图标、控件密度、页面过渡和滚动风格；播放模式开关使用 Material Switch。
- 随包携带 Flutter SDK 提供的 Roboto 常规／中等／粗体及其许可证，避免 iOS 找不到原声明字体而把英文、俄文换为系统字体。Roboto 不包含的中日文字形仍由系统字体回退，不能承诺不同手机逐像素一致。
- 顶部导航和素材选择使用 selectionClick；角度旋钮／步进使用 selectionClick（有节流），成功保存使用 mediumImpact；游戏开始成功使用 mediumImpact，触摸板轻点使用 lightImpact。触发条件共用代码，iPhone 与 Android 手机马达的物理震感不承诺相同。
- 游戏卡片与 Flappy Bird 精简页面、角度校正页、设置中的 TF 卡状态、亮度、语言切换使用共享实现。没有增加游戏蓝牙状态、重开按钮或角度页底部滑条。
- 系统相册、蓝牙权限、Wi-Fi 加入确认、键盘等由操作系统提供，保留各平台必要的原生交互。

## 功能检查和修复

| 流程 | 结论 |
| --- | --- |
| 素材导入、裁剪、命名、保存、历史记录 | 使用同一 Flutter 界面和参数；iOS 有 PHPicker 图片／GIF／视频导入与持久文件存储实现 |
| 服务器转码 | 修复 iOS 漏传 `deviceTransfer`，使新建素材及旧 S3 素材转为 P4 时与 Android 发送相同的设备用途参数；保留服务器返回的实际审核状态 |
| 大视频限制 | iOS 导入／本地处理／服务器转码对齐 Android 的 200 MiB 上限 |
| 转码结果查询 | iOS 改为和 Android 相同的 250 ms 查询间隔及约 10 分钟截止时间；单次网络请求还受自身超时约束 |
| 缩略图 | iOS 可选缩略图改为 5 秒请求超时、8 秒总超时及 8 MiB 上限，失败不使素材保存失败；避免原先 120／900 秒下载超时拖住保存流程 |
| 导入视频的 GIF 预览 | iOS 对齐 Android 的 192 像素、25 fps；出厂素材仍使用共享的视频预览播放器 |
| 素材包下载与上传 | 两端都有下载长度／SHA-256 检查、P4 JPEG 包与帧率检查，以及 TCP 流式上传和 HTTP 回退；共享层统一执行服务器下载 → 校验设备身份 → 加入设备热点 → 上传 → 返回正常网络 |
| 蓝牙控制与游戏 | iOS 实现当前 Flutter 所需全部原生方法；Android 额外的旧 `sendBleControl` 未被当前 Flutter 调用 |
| 亮度、角度、播放、删除 | P4 使用共享 DeviceControl 队列和两端原生 BLE 通道；断电保存由 P4 固件实现 |
| 手机中转 OTA | 两端有固件清单、硬件／设备身份、长度／SHA-256 校验；上传结果不确定时提示重连确认，不自动再上传 |

## 版本及云端构建

- `pubspec.yaml`：1.0.31+33；应用版本显示同步为 1.0.31。
- 根目录及 `app_gif/codemagic.yaml` 同步，沿用根配置的 `Codemagic CI` 集成和 `com.domainname.DotLoop` Bundle ID，消除两份配置原先的身份差异。
- 云端构建号为 **33 + PROJECT_BUILD_NUMBER**，同一个 Codemagic 项目每次重建都会递增。没有云端计数时直接失败，不悄悄使用重复号。脚本另检查 iOS 构建号范围。
- 构建命令显式传 `--build-name`、`--build-number`，先清理并重新生成 Flutter iOS 配置，避免使用 Windows 本地旧 Generated.xcconfig。
- `ios_app_store` 工作流在签名／构建前执行相关 Flutter 检查和版本脚本测试；沿用既有 TestFlight 上传设置，不自动提交 App Store 审核。本次未新增 push 触发器。
- 热点功能要求所选 Apple provisioning profile 包含 Hotspot Configuration 能力。代码已引用 Runner.entitlements，签名结果需由 Codemagic 实际构建确认。

## 验证范围

- Flutter 完整测试、Android／iOS 平台变体互动与素材导入保存测试、原生源代码合同检查，以及版本脚本测试在 Windows 执行。
- 本轮 Flutter **160 项通过**，`flutter analyze lib test` 无问题；云端构建号脚本 **5 项通过**。Android debug APK 构建作为共享代码编译检查。
- 原生 iOS 编译、签名、IPA 生成和 iPhone 实机蓝牙／热点／上传验证由 Mac/Codemagic 与 iPhone 完成；本地测试不能替代这些验收。
- 没有连接或操作已寄出的 P4 设备。1.0.30 的一致性检查没有修改线上服务器；1.0.31 的 Android APK 发布另记于下方。

本地日志位于 `artifacts/p4-priority-2026-10-15/ios-android-parity-all-tests.log`、`ios-android-parity-analyze.log` 与 `interaction-parity-tests.log`。

## 1.0.31 云端检查修复与 Android 发布

- Codemagic 日志显示三处 `SemanticsNode.hasFlag` 弃用提示使 `flutter analyze lib test` 返回 1，构建在 IPA 编译前停止；依赖存在可更新版本的提示不是此次失败原因。
- 素材分栏测试改为读取 `Semantics.properties.selected`，保留选中切换及无障碍标签检查，兼容本地 Flutter 3.32.8 和新版接口；没有关闭分析或忽略弃用提示。根目录和 App 内 Codemagic 配置都补入该测试文件。
- 版本升级至 **1.0.31+33**。完整 Flutter **160 项通过**、静态分析无问题、版本脚本 **5 项通过**；Android release APK 构建成功。
- APK：`DotLoop-1.0.31-release.apk`，78,368,254 字节，SHA-256 `43e4d37d2c192e06cd5e2d475088f31932fe4c1df48c91cbb9e2eca75cfbf783`。包名 `com.example.app_gif`；versionName=1.0.31、versionCode=33。签名已与线上 1.0.23 APK 比对一致，可覆盖升级。
- 主备服务器（47.108.204.22、60.205.122.153）均已更新 Android 版本为 1.0.31，保留最低版本 1.0.15、非强制更新。服务端发布前备份版本文件；iOS、固件和素材元数据保持原值，下载内容另作长度及 SHA-256 验证。
- 手机第一次覆盖安装被系统权限确认拦截；用户准备好后重试返回 **Success**，读回 V2301A（10ADC72TZJ0047K）的 versionName=1.0.31、versionCode=33。没有启动 App 或操作 P4。
- 尚未重新执行 Codemagic 云端 IPA 构建；本地检查不能替代新版云端 Flutter、Xcode 编译和签名验证。

本轮日志：`app-1.0.31-tests.log`、`app-1.0.31-analyze.log`、`app-1.0.31-release-build.log`、`app-1.0.31-server-publish.log`（均位于上述 artifacts 目录）。

## Codemagic 保留环境变量冲突修复

- 后续云端日志显示静态分析已通过，但 `flutter test` 启动前报 `FLUTTER_BUILD_NAME is used by the framework and cannot be set in the environment.`，未进入 IPA 构建。版本脚本此前向 `CM_ENV` 写入了 Flutter 的保留变量，本地 Flutter 3.32.8 没有新版的相同限制，导致先前未发现。
- 版本脚本现在导出 `DOTLOOP_BUILD_NAME`、`DOTLOOP_BUILD_NUMBER`；根目录及 App 内的两个 iOS 工作流均通过 `--build-name`、`--build-number` 显式传给 Flutter。没有关闭测试，也没有以 `--dart-define` 绕过检查。
- 版本继续为 **1.0.31**，云端构建号继续按 **33 + PROJECT_BUILD_NUMBER** 递增。这次仅改构建配置及脚本，不重新发布 Android APK。
- 新增版本 CLI 测试在修复前因导出 `FLUTTER_*` 而失败，修复后 **6 项 Python 测试通过**。携带新 CI 变量运行静态分析无问题、完整 Flutter **160 项通过**；两份 YAML 一致，实际 Bash 参数展开检查确认 App Store 和无签名工作流都收到预期版本及构建号。
- 验证日志为 `codemagic-env-fix-checks.log`、`codemagic-env-fix-build-args.log`，位于上述 artifacts 目录。Windows 未运行 Xcode，云端新版 Flutter 测试、IPA 编译及签名仍需 Codemagic 重跑确认。
