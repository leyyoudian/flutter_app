# ESP32-S3 电子吧唧固件实现说明

## 当前实现

本工程已从官方扫描/演示例程收敛为电子吧唧播放固件：

- LCD 仍使用官方 `ST7701S` 初始化序列和 `esp_lcd` RGB panel driver。
- 主播放路径不使用 LVGL，也不在设备端解码原始 GIF。
- 播放器直接使用 RGB LCD 双 framebuffer。
- 动画资产使用 `EBAJ1` 包格式，由 Flutter App 预处理 GIF/图片后上传。
- BLE 使用 NimBLE GATT peripheral，自定义上传服务。
- Flash 使用单个 `asset` 素材槽，分区大小 10MB。
- 电池 ADC、QMI8658 IMU、SD/FATFS 和官方扫描 demo 已从主固件构建路径移除。

## 关键文件

- `main/Badge/BadgeProtocol.*`：BLE 上传包解析、EBAJ1 header/frame table 校验、CRC32。
- `main/Badge/BadgeLz4.*`：最小标准 LZ4 block 解码器。
- `main/Badge/BadgeStorage.*`：单 asset 槽写入、回读校验、NVS 素材元数据。
- `main/Badge/BadgeDisplay.*`：RGB framebuffer 播放任务、raw/LZ4/XOR delta 帧解码、超时跳帧。
- `main/Wireless/Wireless.*`：NimBLE GATT 上传服务。
- `partitions.csv`：3MB factory + 10MB `asset` + 512KB reserved。
- `docs/EBAJ1_PROTOCOL.md`：Flutter App 需要实现的包格式和 BLE 协议。

## 构建目录提醒

本次改动位于：

```text
D:\Documents\esp-baji\ESP32-S3-LCD-2.8C-Test
```

你贴出的编译日志来自：

```text
D:\Downlowads\ESP32-S3-LCD-2.8C-Demo\ESP-IDF\ESP32-S3-LCD-2.8C-Test
```

那份目录仍是官方原始例程，所以会继续编译旧 `LVGL_Driver.c`，并因为 `main/CMakeLists.txt` 没有声明 `REQUIRES esp_lcd` 而报：

```text
fatal error: esp_lcd_panel_rgb.h: No such file or directory
```

解决方式二选一：

1. 直接在 `D:\Documents\esp-baji\ESP32-S3-LCD-2.8C-Test` 构建。
2. 把本目录的改动同步到 `D:\Downlowads\...` 那份工程后再构建。

## ESP-IDF 环境要求

推荐使用 ESP-IDF 5.4.2：

```bat
cd /d D:\espidf\v5.4.2\esp-idf
install.bat
export.bat
cd /d D:\Documents\esp-baji\ESP32-S3-LCD-2.8C-Test
idf.py set-target esp32s3
idf.py build
```

当前机器上的 v5.4.2 环境缺少 Python 依赖和 constraints 文件，例如：

```text
D:\Espressif\espidf.constraints.v5.4.txt
psutil
esp-idf-nvs-partition-gen
```

因此需要先跑 v5.4.2 的 `install.bat` 或重新安装 ESP-IDF 5.4.2 工具链。

## 播放模型

启动后流程：

1. 初始化按键、I2C、RTC、EXIO。
2. 初始化 NVS 和 `asset` 分区。
3. 初始化 ST7701S + RGB LCD panel。
4. 获取两个 RGB framebuffer。
5. 播放 `asset` 分区里的 EBAJ1 动画；没有素材时显示黑屏。
6. 启动 NimBLE，等待手机 App 上传新素材。
7. 上传完成并校验通过后请求播放器重载新素材。

播放 task 会在离屏 framebuffer 解码下一帧，再通过 `esp_lcd_panel_draw_bitmap()` 让 RGB panel driver 切换 framebuffer。若解码超时，会跳过后续 keyframe 追时间；delta 帧不会被随意跳入，避免花屏。

## App 端职责

Flutter App 需要：

- 选择 GIF/图片。
- 在 isolate 中缩放/裁剪到 480x480。
- 转 RGB565。
- 默认降到 24fps，必要时降到 20/16/12/8fps。
- 生成 `EBAJ1` 包。
- 通过 BLE 执行 `START -> DATA -> FINISH`。
- 订阅或读取控制特征获取状态。
- 通过控制特征写 `0x10 + brightness(0..100)` 调节屏幕亮度。

建议单个 BLE data write 总长度不超过 512 bytes。

## 后续验证标准

- `idf.py set-target esp32s3 && idf.py build` 成功。
- 启动日志确认 ESP32-S3、16MB Flash、PSRAM、240MHz。
- 24fps EBAJ1 动画循环 30 分钟，无闪屏、无 WDT、无 heap 持续下降。
- BLE 上传 1-2MB 素材和接近 10MB 的边界素材后 CRC 一致，切换新素材无黑屏。
- 上传中断或断电后不会花屏或崩溃；由于当前是单槽 10MB 设计，旧素材不保证保留。
