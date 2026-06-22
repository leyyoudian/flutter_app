# EBAJ4 20fps Indexed Stream Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current EBAJ3 RGB565/preload playback path with an SD-only EBAJ4 indexed stream path that preserves full asset duration and targets stable 20fps output.

**Architecture:** Android transcodes GIF/image/video into EBAJ4 with 20fps, one adaptive indexed resolution per asset, RGB565 palette entries, key/tile/repeat frames, and no package truncation. Firmware validates EBAJ4, stores `/sdcard/badge.eb4`, reads frame payloads sequentially from SD through a prefetch stream, decodes into indexed framebuffers, converts to RGB565 for the current LCD path, and logs read/decode/render/display/underrun timing.

**Tech Stack:** ESP-IDF C on ESP32-S3, FATFS SDMMC, esp_lcd RGB panel, FreeRTOS tasks/queues, Android Kotlin native encoder, Flutter tests, Python static checks.

## Global Constraints

- Target playback cadence is exactly `20fps` with `delay_ms=50`.
- Full input duration must be encoded; the App must not truncate frames because of an SD package budget.
- Storage is SD-only; flash fallback remains removed.
- The normal playback path is EBAJ4-only.
- Firmware must not preload the full asset package into PSRAM.
- High-motion material may fall back to `320x320` or `240x240` indexed stream resolution.
- MJPEG/JPEG is not part of this implementation pass.

---

### Task 1: Protocol And Static Tests

**Files:**
- Modify: `D:\Documents\esp-baji\ESP32-S3-LCD-2.8C-Test\main\Badge\BadgeProtocol.h`
- Modify: `D:\Documents\esp-baji\ESP32-S3-LCD-2.8C-Test\main\Badge\BadgeProtocol.c`
- Modify: `D:\Documents\esp-baji\ESP32-S3-LCD-2.8C-Test\tools\check_display_pipeline.py`
- Create: `D:\Documents\esp-baji\ESP32-S3-LCD-2.8C-Test\tools\check_ebaj4_protocol.py`

**Interfaces:**
- Produces: `BADGE_EBAJ_MAGIC_V4`, `BADGE_EBAJ_VERSION_V4`, `badge_ebaj_header_t`, `badge_ebaj_frame_t`, and codecs `BADGE_FRAME_INDEXED_KEY`, `BADGE_FRAME_INDEXED_TILE`, `BADGE_FRAME_INDEXED_REPEAT`.
- Produces: `badge_protocol_validate_header(const badge_ebaj_header_t *header, uint32_t slot_size)` validating only EBAJ4.

- [ ] Update protocol structs to EBAJ4 header size `44` and frame entry size `16`.
- [ ] Validate width/height `480`, fps `20`, palette entries `256`, stream size in `{480,320,240}`, frame table bounds, and package bounds.
- [ ] Replace EBAJ3 static checks with EBAJ4 checks.
- [ ] Add a Python struct-size/static validation script.
- [ ] Run `python ESP32-S3-LCD-2.8C-Test\tools\check_ebaj4_protocol.py`.

### Task 2: Android EBAJ4 Encoder

**Files:**
- Modify: `D:\Documents\esp-baji\app_gif\android\app\src\main\kotlin\com\example\app_gif\MainActivity.kt`
- Modify: `D:\Documents\esp-baji\app_gif\lib\main.dart`
- Modify: `D:\Documents\esp-baji\app_gif\test\native_encoder_static_test.dart`
- Modify: `D:\Documents\esp-baji\app_gif\test\budget_test.dart`

**Interfaces:**
- Consumes: EBAJ4 constants from Task 1.
- Produces: packages with `MAGIC=0x344a4142`, `VERSION=4`, `FPS=20`, RGB332 palette, indexed key/tile/repeat frames, and full timeline frame count.

- [ ] Update Dart budget helper so SD assets do not use the old 4MB preload budget.
- [ ] Change Kotlin encoder to force `TARGET_FPS=20`.
- [ ] Implement RGB332 palette generation and ARGB-to-index conversion.
- [ ] Encode candidates at `480`, then `320`, then `240`, selecting the first projected stream below the target bytes-per-second threshold; always keep full frame count.
- [ ] Pack EBAJ4 header and frame table.
- [ ] Update Flutter static tests to assert EBAJ4, 20fps, no frame truncation, and no preload budget.
- [ ] Run `flutter test` in `D:\Documents\esp-baji\app_gif`.

### Task 3: SD-Only EBAJ4 Storage

**Files:**
- Modify: `D:\Documents\esp-baji\ESP32-S3-LCD-2.8C-Test\main\Badge\BadgeStorage.c`
- Modify: `D:\Documents\esp-baji\ESP32-S3-LCD-2.8C-Test\main\Badge\BadgeStorage.h`
- Modify: `D:\Documents\esp-baji\ESP32-S3-LCD-2.8C-Test\tools\check_sd_paths.py`

**Interfaces:**
- Produces: active path `/sdcard/badge.eb4`, temp path `/sdcard/badge.tmp`, SD-only status with `format=ebaj4`.
- Produces: sequential read support used by Task 5.

- [ ] Change active SD asset path to `badge.eb4`.
- [ ] Validate uploaded headers as EBAJ4 before activation.
- [ ] Keep CRC, fsync, rename, and upload timing logs.
- [ ] Ensure status reports active format, fps, frame count, and SD availability.
- [ ] Keep FAT 8.3 path checks passing.

### Task 4: Indexed Decoder Module

**Files:**
- Create: `D:\Documents\esp-baji\ESP32-S3-LCD-2.8C-Test\main\Badge\BadgeIndexed.h`
- Create: `D:\Documents\esp-baji\ESP32-S3-LCD-2.8C-Test\main\Badge\BadgeIndexed.c`
- Modify: `D:\Documents\esp-baji\ESP32-S3-LCD-2.8C-Test\main\CMakeLists.txt`
- Create: `D:\Documents\esp-baji\ESP32-S3-LCD-2.8C-Test\tools\check_badge_indexed.py`

**Interfaces:**
- Consumes: EBAJ4 frame entries and payload layouts.
- Produces: `badge_indexed_init`, `badge_indexed_decode`, `badge_indexed_render_rgb565`, and `badge_indexed_deinit`.

- [ ] Allocate two indexed framebuffers in PSRAM for the selected stream resolution.
- [ ] Decode key frames by copying palette and full index plane.
- [ ] Decode tile frames by copying previous indexed buffer then applying 16x16 changed tiles.
- [ ] Decode repeat frames by preserving the active indexed buffer.
- [ ] Render indexed pixels to a 480x480 RGB565 framebuffer with precomputed scale maps.
- [ ] Add static checks for no full-package preload dependency.

### Task 5: Streamed Player

**Files:**
- Create: `D:\Documents\esp-baji\ESP32-S3-LCD-2.8C-Test\main\Badge\BadgeStream.h`
- Create: `D:\Documents\esp-baji\ESP32-S3-LCD-2.8C-Test\main\Badge\BadgeStream.c`
- Modify: `D:\Documents\esp-baji\ESP32-S3-LCD-2.8C-Test\main\Badge\BadgeDisplay.c`
- Modify: `D:\Documents\esp-baji\ESP32-S3-LCD-2.8C-Test\main\CMakeLists.txt`
- Modify: `D:\Documents\esp-baji\ESP32-S3-LCD-2.8C-Test\main\main.c`
- Modify: `D:\Documents\esp-baji\ESP32-S3-LCD-2.8C-Test\tools\check_display_pipeline.py`

**Interfaces:**
- Consumes: storage asset handle, frame table, indexed decoder.
- Produces: 20fps display loop with SD prefetch slots, no full asset preload, and per-second performance logs.

- [ ] Implement a FreeRTOS prefetch task with three PSRAM payload slots and free/ready queues.
- [ ] Rewrite `BadgeDisplay.c` to load the frame table, start `BadgeStream`, decode ready frames, render RGB565, and present at 50ms intervals.
- [ ] Repeat the previous rendered frame on underrun instead of skipping timeline output.
- [ ] Log `frames`, `read`, `decode`, `render`, `display`, `vsync`, `underrun`, `repeat`, and stream resolution once per second.
- [ ] Update firmware build id to an EBAJ4-specific string.
- [ ] Run static checks and `idf.py build`.

### Task 6: Verification

**Files:**
- Modify only if verification reveals a mismatch in files from Tasks 1-5.

**Commands:**
- `python ESP32-S3-LCD-2.8C-Test\tools\check_ebaj4_protocol.py`
- `python ESP32-S3-LCD-2.8C-Test\tools\check_badge_indexed.py`
- `python ESP32-S3-LCD-2.8C-Test\tools\check_display_pipeline.py`
- `python ESP32-S3-LCD-2.8C-Test\tools\check_sd_paths.py`
- `flutter test` from `D:\Documents\esp-baji\app_gif`
- `idf.py build` from `D:\Documents\esp-baji\ESP32-S3-LCD-2.8C-Test`

**Expected Result:**
- All static and Flutter tests pass.
- Firmware builds.
- Serial logs on hardware should show `format=ebaj4 fps=20` and playback perf near `frames=20` once a new EBAJ4 asset is uploaded.
