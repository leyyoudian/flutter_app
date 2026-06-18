# EBAJ4 20fps Indexed Stream Design

## Goal

Rebuild the badge asset pipeline so uploaded GIF/image/video assets play for their full duration at a stable 20fps output cadence on the existing ESP32-S3 + 480x480 RGB LCD hardware.

The primary success metric is smooth and complete playback. Visual quality is allowed to degrade automatically on high-motion or high-detail sources by reducing render resolution and color count. The firmware must not rely on flash fallback and must not require the full asset package to fit in PSRAM.

## Current Failure

The EBAJ3 pipeline stores RGB565 full frames or raw RGB565 tile deltas. A full 480x480 RGB565 frame is 460800 bytes; at 20fps this is about 9.2MB/s before decoder, SD, memcpy, and LCD bandwidth overhead. This exceeds the stable real-time budget for the current board when the material has large frame-to-frame changes.

The latest PSRAM preload experiment also conflicts with the user requirement. It limits the App package budget to 4MB and forces the firmware to preload the whole package into PSRAM, so longer assets are truncated or cannot be played completely.

## Chosen Approach

Introduce an EBAJ4 format and player built around indexed frames:

- The App always emits a 20fps timeline for the full input duration.
- The App transcodes frames into 8-bit indexed image data plus RGB565 palettes.
- The App chooses one render scale per uploaded asset:
  - 480x480 indexed for low-motion material.
  - 320x320 indexed for medium/high-motion material.
  - 240x240 indexed for worst-case high-motion material.
- The firmware streams from TF/SD sequentially with a PSRAM ring buffer. It does not preload the complete asset.
- The firmware converts indexed pixels to RGB565 on display composition, not in the stored asset.
- If the decode/read path misses a deadline, the display repeats the previous completed frame while keeping the 20fps output clock stable.

This design prefers deterministic bandwidth over maximum quality. MJPEG/JPEG is outside this pass and is considered only if EBAJ4 cannot meet the target after the 240x240 fallback is verified on hardware.

## Non-Goals

- Do not guarantee arbitrary full-color 480x480 high-motion video at 20fps.
- Do not preserve the old flash fallback path.
- Do not keep the 4MB PSRAM preload package limit for SD assets.
- Do not add JPEG/MJPEG decode in this pass.
- Do not add BLE asset transfer in this pass.

## EBAJ4 File Format

The App writes a single SD asset file to `/sdcard/badge.eb4`. Upload still uses HTTP POST with `X-EBAJ-CRC32`.

Header fields:

- `magic`: little-endian `0x344a4142` (`BAJ4`).
- `version`: `4`.
- `header_size`: size of the EBAJ4 header.
- `canvas_width`: `480`.
- `canvas_height`: `480`.
- `frame_count`: number of 20fps timeline frames.
- `fps`: `20`.
- `frame_table_offset`.
- `frame_data_offset`.
- `package_size`.
- `package_crc32`.
- `flags`.
- `stream_width`: encoded pixel width, one of `480`, `320`, or `240`.
- `stream_height`: encoded pixel height, one of `480`, `320`, or `240`.
- `palette_entries`: `256`.
- `reserved`.

Each frame table entry contains:

- `data_offset`: absolute payload offset.
- `data_size`: payload bytes.
- `delay_ms`: `50`.
- `codec`: one of the EBAJ4 frame codecs.
- `flags`: keyframe/dependent flags.
- `width`: encoded width for this frame.
- `height`: encoded height for this frame.
- `reserved`.

Frame codecs:

- `EBAJ4_FRAME_INDEXED_KEY`: palette + full index plane.
- `EBAJ4_FRAME_INDEXED_TILE`: palette + changed indexed tiles. Depends on the previous composited indexed frame.
- `EBAJ4_FRAME_INDEXED_REPEAT`: no image payload; repeats previous frame when the App samples duplicate source frames.

Payload layout:

- Key frame: `uint16 palette[256]` followed by `width * height` bytes of palette indices.
- Tile frame: `uint16 palette[256]`, `uint16 tile_count`, then repeated tile records. Each record is `uint16 tile_index` followed by `16 * 16` index bytes.
- Repeat frame: zero-byte payload.

All integers are little-endian. Palettes are RGB565.

## App Transcoder

The Android native encoder becomes the source of truth for playback cost:

1. Decode source frames at 20fps for the full duration.
2. Render each source frame into a 480x480 ARGB canvas.
3. Analyze frame complexity and motion:
   - changed tile ratio,
   - approximate color entropy,
   - projected EBAJ4 bytes per second.
4. Select stream resolution:
   - use 480x480 if projected sustained payload is below the SD target,
   - otherwise retry at 320x320,
   - otherwise retry at 240x240.
5. Quantize each rendered frame to a 256-entry RGB565 palette.
6. Encode key, tile, or repeat frame.
7. Never truncate the timeline because of projected package size. The first EBAJ4 pass relies on TF/SD capacity rather than an App-side preload budget.

The initial implementation uses a deterministic RGB332-style palette mapper. This keeps phone-side implementation risk low and makes firmware decode trivial. A better palette quantizer is a separate future enhancement and must still write 256 RGB565 palette entries.

## Firmware Storage

Storage is SD-only:

- Upload writes `/sdcard/badge.tmp`.
- After CRC and header validation, firmware renames it to `/sdcard/badge.eb4`.
- The normal playback path is EBAJ4-only. Old `badge.eb2` or `badge.eb3` compatibility is not required for this pass.
- No flash fallback and no PSRAM full-package preload.

The status endpoint must report SD availability and the active format, for example:

`storage=sd sd=1 format=ebaj4 fps=20 frames=1234`

## Firmware Playback Pipeline

Split playback into fixed-responsibility units:

- `BadgeProtocol`: validates EBAJ4 headers and frame entries.
- `BadgeStorage`: opens the active SD asset and provides sequential reads.
- `BadgeStream`: owns a PSRAM ring buffer and a reader task. It reads frame payloads in file order without per-frame seek during steady playback.
- `BadgeIndexed`: decodes key/tile/repeat payloads into indexed frame buffers.
- `BadgeDisplay`: owns the 20fps output clock and LCD frame presentation.

Runtime flow:

1. Open `/sdcard/badge.eb4`.
2. Read and validate header + frame table.
3. Start a reader task that fills a PSRAM ring buffer sequentially from `frame_data_offset`.
4. Start a compositor task that consumes frame payloads and updates one of two indexed framebuffers.
5. The display loop ticks every 50ms. If a newly composited frame is ready, it presents it; otherwise it repeats the last frame and increments an underrun counter.
6. On upload, playback pauses, file handles close, and playback restarts after successful activation.

Indexed framebuffer memory:

- 480x480 indexed: 230400 bytes per buffer.
- 320x320 indexed: 102400 bytes per buffer.
- 240x240 indexed: 57600 bytes per buffer.

This leaves PSRAM room for a large SD ring buffer without requiring the whole asset in memory.

## LCD Path

The first implementation may keep the existing RGB panel framebuffer mode and render indexed frames into a single RGB565 framebuffer before `esp_lcd_panel_draw_bitmap`. This is lower-risk and lets us validate the EBAJ4 format quickly.

If this still misses 20fps, the next display-only optimization is to switch the RGB panel to no-framebuffer/bounce-buffer mode and fill bounce lines from the indexed framebuffer using palette conversion. That removes persistent 480x480 RGB565 framebuffer pressure, but it is more invasive because the callback must be small, IRAM-safe, and must not perform SD or allocation work.

The implementation plan should make this a second-stage task, not block the first EBAJ4 player from compiling and running.

## Performance Budget

Target per 50ms frame:

- SD read average: below 20ms.
- indexed decode/composite: below 10ms.
- palette conversion/render: below 15ms.
- scheduling margin: at least 5ms.

Expected worst-case SD bandwidth:

- 480x480 indexed full key frame: about 230KB/frame, 4.6MB/s at 20fps.
- 320x320 indexed full key frame: about 100KB/frame, 2.0MB/s at 20fps.
- 240x240 indexed full key frame: about 56KB/frame, 1.15MB/s at 20fps.

The App must choose a resolution that keeps the projected payload in the 1-3MB/s range for high-motion material.

## Logging

Upload logs:

- receive time,
- SD write time,
- CRC time,
- finish/rename time,
- package size,
- format version.

Playback logs once per second:

- output frames presented,
- source frames consumed,
- SD read ms,
- ring buffer low-water mark,
- indexed decode/composite ms,
- palette conversion/display ms,
- underrun count,
- repeated frame count,
- active stream resolution.

The log line must make bottlenecks obvious without needing a debugger.

## Tests And Verification

Static checks:

- Firmware defines and validates `BADGE_EBAJ_MAGIC_V4`.
- Firmware no longer requires `preload_asset_to_psram` for playback.
- App SD budget is not the old 4MB preload budget.
- App emits `fps=20`.
- App does not break out early when projected package size grows for SD assets.

Unit or host tests:

- EBAJ4 header and frame table sizes match firmware structs.
- A generated key frame payload validates.
- A generated tile frame payload validates and applies correctly.
- Repeat frame preserves the previous indexed framebuffer.
- CRC covers the final package bytes.

Manual hardware verification:

- Upload a short GIF.
- Upload the current 6MB material that previously played at 1-5fps.
- Confirm serial logs show `format=ebaj4 fps=20`.
- Confirm playback logs stay near `frames=20` per second.
- If underruns remain high at 480/320, confirm App selected 240 stream resolution before considering MJPEG/JPEG.

## Fallback Decision

Only evaluate ESP32-S3 MJPEG/JPEG after EBAJ4 fails the hardware test with 240x240 indexed high-motion fallback. If that happens, run a separate experiment with a short fixed MJPEG/AVI clip and log JPEG decode time per frame before replacing the main pipeline.
