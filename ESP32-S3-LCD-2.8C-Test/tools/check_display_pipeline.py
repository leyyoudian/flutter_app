from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DISPLAY = ROOT / "main" / "Badge" / "BadgeDisplay.c"
MAIN = ROOT / "main" / "main.c"
LCD_HEADER = ROOT / "main" / "LCD_Driver" / "ST7701S.h"
LCD_SOURCE = ROOT / "main" / "LCD_Driver" / "ST7701S.c"


def extract_function(source: str, name: str) -> str:
    marker = f"static void {name}("
    start = source.index(marker)
    while source.find(marker, start + 1) != -1:
        candidate = source.find(marker, start + 1)
        between = source[source.index(")", candidate) + 1:source.index("{", candidate)]
        if ";" not in between:
            start = candidate
            break
        start = candidate
    brace = source.index("{", start)
    depth = 0
    for index in range(brace, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise AssertionError(f"{name} body not found")


display_source = DISPLAY.read_text(encoding="utf-8", errors="ignore")
stream_source = (ROOT / "main" / "Badge" / "BadgeStream.c").read_text(encoding="utf-8", errors="ignore")
storage_source = (ROOT / "main" / "Badge" / "BadgeStorage.c").read_text(encoding="utf-8", errors="ignore")
protocol_source = (ROOT / "main" / "Badge" / "BadgeProtocol.h").read_text(encoding="utf-8", errors="ignore")
protocol_c_source = (ROOT / "main" / "Badge" / "BadgeProtocol.c").read_text(encoding="utf-8", errors="ignore")
switch_body = extract_function(display_source, "switch_panel_to_fb")
player_body_start = display_source.index("static esp_err_t player_loop_asset(")
assert "esp_lcd_rgb_panel_restart" not in switch_body, (
    "switch_panel_to_fb must not restart the RGB panel every frame"
)
assert "esp_err_t draw_ret = esp_lcd_panel_draw_bitmap" in switch_body and "draw_ret != ESP_OK" in switch_body, (
    "display path should log full-frame draw_bitmap errors"
)
assert "LCD_WaitForVsync" not in switch_body and "vsync wait failed" not in switch_body, (
    "triple-buffer playback should not block every frame waiting for vsync"
)

main_source = MAIN.read_text(encoding="utf-8", errors="ignore")
assert "BADGE_FW_BUILD_ID" in main_source, "firmware build id must be logged at boot"
assert "BADGE_EBAJ_MAGIC_V4" in protocol_source, "protocol must define EBAJ4"
assert "preload_asset_to_psram" not in display_source, "player must not preload full SD asset into PSRAM"
assert "BadgeStream.h" in display_source, "display path must use streamed SD prefetch"
assert "#define BADGE_STREAM_SLOT_COUNT 16u" in stream_source, "SD stream prefetch should keep more frames buffered"
assert "#define BADGE_STREAM_PREFILL_FRAMES 16u" in display_source, "player should prefill the full stream queue before playback"
assert "#define BADGE_SD_READ_STAGING_BYTES (256u * 1024u)" in storage_source, "SD reads should use a larger staging buffer when memory allows"
assert "BadgeIndexed.h" in display_source, "display path must decode indexed EBAJ4 frames"
assert "badge_stream_read_frame" in display_source, "player must consume prefetched frame payloads"
assert "frame_delay_us = (int64_t)badge_protocol_frame_delay_ms(asset->header.fps) * 1000" in display_source, (
    "player must derive output cadence from the uploaded asset fps"
)
assert "next_tick_us += frame_delay_us" in display_source, "player must advance using the dynamic frame interval"
assert "if (frame->codec == BADGE_FRAME_INDEXED_REPEAT)" in display_source, (
    "repeat frames should avoid full RGB565 re-rendering"
)
assert "badge_indexed_blit_dirty_rgb565" in display_source, (
    "tile frames should update only changed RGB565 tiles instead of rendering the whole screen"
)
assert "badge_indexed_dirty_rgb565_is_partial" in display_source, (
    "display path should avoid framebuffer copies for tile frames that need a full render"
)
assert "render_fb = last_render_fb" in display_source, (
    "dirty tile updates should blit in place on the previously displayed framebuffer instead of copying a full RGB565 frame"
)
assert "copy_framebuffer_if_needed(render_fb, last_render_fb)" not in display_source, (
    "480x480 dirty tile frames must not copy the full RGB565 framebuffer before every partial update"
)
assert "rendered_new_frame = true;" in display_source and "++s_perf_underrun;" in display_source, (
    "player must distinguish rendered frames from underruns"
)
assert "switch_panel_to_fb(last_render_fb" not in display_source, (
    "underruns must not resubmit the same framebuffer and burn a vsync"
)
assert "underrun" in display_source, "player must log underruns"
assert "#define BADGE_FPS_OVERLAY_ENABLED 0u" in display_source, "runtime FPS overlay must be disabled by default"
assert "#include \"BadgeLz4.h\"" not in display_source, "display path must not depend on realtime LZ4 decode"
assert "BADGE_EBAJ_MAGIC_V3" not in protocol_c_source, "runtime header validator must reject old EBAJ3 packages"
assert "asset format magic=" in display_source, "player must log asset format and codec distribution"

lcd_header_source = LCD_HEADER.read_text(encoding="utf-8", errors="ignore")
lcd_source = LCD_SOURCE.read_text(encoding="utf-8", errors="ignore")
assert "EXAMPLE_LCD_NUM_FB > 1 ? 0 :" in lcd_source, (
    "RGB panel must not enable bounce buffers when using multiple full frame buffers"
)
assert "#define BADGE_STATIC_LCD_TEST 0u" in display_source, (
    "normal firmware should run badge playback; set BADGE_STATIC_LCD_TEST to 1 only for LCD static diagnostics"
)
assert "draw_static_lcd_test_pattern" in display_source, (
    "static LCD diagnostic helper should remain available for future panel timing tests"
)
assert "#define EXAMPLE_LCD_PIXEL_CLOCK_HZ     (14 * 1000 * 1000)" in lcd_header_source, (
    "2.5 inch RGB panel should keep the user-verified 14 MHz PCLK for higher FPS"
)
assert ".hsync_back_porch = 30" in lcd_source and ".hsync_front_porch = 30" in lcd_source, (
    "2.5 inch RGB panel should use the vendor horizontal porch timing"
)
assert ".hsync_pulse_width = 30" in lcd_source, (
    "horizontal sync pulse width should stay aligned with the vendor timing"
)
assert "set LCD reset low failed\");\n    vTaskDelay(pdMS_TO_TICKS(20));" in lcd_source, (
    "LCD reset should hold the panel low long enough for deterministic boot state"
)
assert "set LCD reset high failed\");\n    vTaskDelay(pdMS_TO_TICKS(120));" in lcd_source, (
    "LCD reset should wait after release before SPI init starts"
)
assert "ST7701S_screen_init(st7701s, 1);\n    vTaskDelay(pdMS_TO_TICKS(120));" in lcd_source, (
    "RGB clocks should start only after ST7701S command init has settled"
)
