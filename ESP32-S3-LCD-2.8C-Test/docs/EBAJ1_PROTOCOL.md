# EBAJ1 动画包与 BLE 上传协议

## 固件目标

本固件不在 ESP32-S3 上解码原始 GIF。Flutter App 需要把 GIF/图片预处理成 480x480 RGB565 帧，再封装为 `EBAJ1` 包。ESP32 端只负责接收、校验、单槽保存、双 framebuffer 播放。

推荐 App 默认输出 24fps；简单素材可尝试 30fps。60fps 只建议作为小体积素材压测目标。

## EBAJ1 文件结构

所有整数均为 little-endian。

```c
struct ebaj_header {
    uint32_t magic;              // 0x314a4142, "BAJ1"
    uint16_t version;            // 1
    uint16_t header_size;        // sizeof(ebaj_header)
    uint16_t width;              // 480
    uint16_t height;             // 480
    uint16_t frame_count;
    uint16_t fps;
    uint32_t frame_table_offset;
    uint32_t frame_data_offset;
    uint32_t package_size;
    uint32_t package_crc32;      // 预留，当前固件用 BLE START 里的 CRC 校验整个包
    uint32_t flags;              // 预留
};

struct ebaj_frame {
    uint32_t data_offset;        // 相对包起点
    uint32_t data_size;
    uint32_t raw_size;           // 必须为 480 * 480 * 2
    uint16_t delay_ms;
    uint8_t codec;               // 0 raw RGB565, 1 LZ4, 2 XOR delta + LZ4
    uint8_t reserved;
};
```

像素格式为 RGB565，按行从左到右、从上到下排列。

`codec=0`：`data` 是完整 RGB565 帧。

`codec=1`：`data` 是标准 LZ4 block，解压后得到完整 RGB565 帧。

`codec=2`：`data` 是标准 LZ4 block，解压后得到与上一显示帧 XOR 的 delta；固件会对离屏 framebuffer 原地 XOR。第一帧不要使用 delta。

## BLE 服务

设备名：`ESP-BAJI`

服务 UUID：`31494a41-6252-4288-b942-2f8d009e1ab1`

控制/状态特征 UUID：`31494a41-6252-4288-b942-2f8d019e1ab1`

数据特征 UUID：`31494a41-6252-4288-b942-2f8d029e1ab1`

控制特征支持 read/write/notify。数据特征支持 write/write without response。

## 上传流程

1. 写控制特征 `START`：

```text
byte 0      opcode = 0x01
byte 1..4   package_size uint32
byte 5..8   package_crc32 uint32
```

2. 连续写数据特征：

```text
byte 0..3   offset uint32
byte 4..N   package bytes
```

固件当前要求 offset 严格顺序递增。Flutter 端建议每 8-16 个 chunk 读一次控制特征或订阅 notify 来确认状态。

3. 写控制特征 `FINISH`：

```text
byte 0      opcode = 0x02
```

固件会校验传输 CRC、Flash 回读 CRC、EBAJ1 header。全部通过后请求播放器重载当前素材。

4. 出错或取消时写 `ABORT`：

```text
byte 0      opcode = 0x03
```

5. 需要查询状态时写 `STATUS` 或 read 控制特征：

```text
byte 0      opcode = 0x04
```

6. 设置屏幕背光亮度时写 `SET_BRIGHTNESS`：

```text
byte 0      opcode = 0x10
byte 1      brightness uint8, 0..100
```

固件会将亮度限制在 `0..100`，成功后状态 notify/read 返回类似 `OK brightness 70`。

## 分区

单个 `asset` 分区为 10MB。上传开始后播放器会停止读取素材，写入时按需擦除即将写入的 Flash 扇区；只有校验成功后才更新 NVS 的素材大小和 CRC。因为当前是单槽设计，上传失败、取消或断电后不能保证旧素材仍然保留。

## App 端建议

- 转码在 isolate 中进行，避免阻塞 Flutter UI。
- 输出前先缩放/裁剪到 480x480。
- 默认 24fps，超过 10MB hard limit 前按 20fps、16fps 降级。
- 第一帧用 raw 或 LZ4 全帧；后续优先尝试 XOR delta + LZ4。
- 每个 BLE chunk 总长度不要超过协商 MTU 减 ATT 开销；固件默认 copy buffer 为 520 bytes，MTU 517 时建议数据特征 payload 不超过 512 bytes。
