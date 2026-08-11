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
assert "badge_display_request_refresh()" in switch_body, (
    "refresh-on-demand RGB playback should explicitly request one panel refresh per new frame"
)
assert "LCD_WaitForPreparedVsync" not in switch_body and "vsync wait after framebuffer refresh failed" not in switch_body, (
    "normal playback should request refresh without blocking every frame on VSYNC"
)

main_source = MAIN.read_text(encoding="utf-8", errors="ignore")
assert "BADGE_FW_BUILD_ID" in main_source, "firmware build id must be logged at boot"
assert "ST7701S_PrepareBootCs()" in main_source, (
    "firmware must isolate LCD CS/GPIO0 high as early as possible after boot"
)
assert main_source.index("ST7701S_PrepareBootCs()") < main_source.index("vTaskDelay(pdMS_TO_TICKS(500));"), (
    "LCD CS/GPIO0 should be pulled high before the boot settle delay and Wi-Fi startup"
)
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
assert "render_fb = last_render_fb" not in display_source, (
    "dirty tile updates must not write into the framebuffer currently being scanned by the LCD"
)
assert "memcpy(s_fb[*render_fb], s_fb[last_render_fb], BADGE_EBAJ_FRAME_BYTES)" in display_source, (
    "dirty tile frames should copy the last stable RGB565 frame before applying tile deltas"
)
assert "rendered_new_frame = true;" in display_source and "++s_perf_underrun;" in display_source, (
    "player must distinguish rendered frames from underruns"
)
assert "switch_panel_to_fb(last_render_fb" not in display_source, (
    "underruns must not resubmit the same framebuffer and burn a vsync"
)
assert "underrun" in display_source, "player must log underruns"
assert "#define BADGE_FPS_OVERLAY_ENABLED 0u" in display_source, "runtime FPS overlay must be disabled by default"
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
assert "#define EXAMPLE_LCD_PIXEL_CLOCK_HZ     (10 * 1000 * 1000)" in lcd_header_source, (
    "local display-first build should use the original stable 10 MHz RGB PCLK"
)
assert "#define EXAMPLE_LCD_REFRESH_ON_DEMAND 0" in lcd_header_source, (
    "local display-first build should use continuous RGB refresh for smooth playback"
)
assert ".flags.refresh_on_demand = true" not in lcd_source, (
    "continuous playback build must not enable RGB refresh-on-demand"
)
assert "esp_err_t ST7701S_PrepareBootCs(void)" in lcd_source, (
    "LCD driver should provide an early boot CS isolation helper"
)
boot_cs_start = lcd_source.index("esp_err_t ST7701S_PrepareBootCs(void)")
boot_cs_end = lcd_source.index("esp_err_t ST7701S_reset(void)")
boot_cs_body = lcd_source[boot_cs_start:boot_cs_end]
assert "GPIO_MODE_OUTPUT_OD" in boot_cs_body and "GPIO_PULLUP_ENABLE" in boot_cs_body, (
    "LCD CS/GPIO0 boot isolation should use open-drain high with pull-up to avoid CH340/button contention"
)
assert boot_cs_body.index("gpio_set_level(LCD_CS, 1)") < boot_cs_body.index("gpio_config(&io_conf)"), (
    "LCD CS/GPIO0 should preload high before enabling the output driver"
)
lcd_init_start = lcd_source.index("void LCD_Init(void)")
lcd_init_end = lcd_source.index("/********************* BackLight")
lcd_init_body = lcd_source[lcd_init_start:lcd_init_end]
assert lcd_init_body.index("ST7701S_PrepareBootCs()") < lcd_init_body.index("vTaskDelay(pdMS_TO_TICKS(LCD_POWER_SETTLE_DELAY_MS));"), (
    "LCD init should keep CS high during the panel power-settle window"
)
assert lcd_init_body.index("ST7701S_newObject") < lcd_init_body.index("ST7701S_CS_EN();") < lcd_init_body.index("ST7701S_screen_init"), (
    "LCD CS should stay high while SPI is configured and only go low before ST7701S command init"
)
cs_en_start = lcd_source.index("esp_err_t ST7701S_CS_EN(void)")
cs_en_end = lcd_source.index("esp_err_t ST7701S_CS_Dis(void)")
cs_en_body = lcd_source[cs_en_start:cs_en_end]
assert "GPIO_MODE_OUTPUT_OD" in cs_en_body and "GPIO_PULLUP_ENABLE" in cs_en_body, (
    "LCD CS/GPIO0 active state should remain open-drain to avoid fighting external IO0 circuitry"
)
assert ".hsync_back_porch = 30" in lcd_source and ".hsync_front_porch = 30" in lcd_source, (
    "2.5 inch RGB panel should use the vendor horizontal porch timing"
)
assert ".hsync_pulse_width = 30" in lcd_source, (
    "horizontal sync pulse width should stay aligned with the vendor timing"
)
assert "#define LCD_POWER_SETTLE_DELAY_MS 400u" in lcd_source, (
    "LCD power settle delay should be explicit for cold-boot tuning"
)
assert "#define LCD_RESET_LOW_DELAY_MS 250u" in lcd_source, (
    "LCD reset low time should be explicit for cold-boot tuning"
)
assert "#define LCD_RESET_RELEASE_DELAY_MS 300u" in lcd_source, (
    "LCD reset release time should be explicit for cold-boot tuning"
)
assert "vTaskDelay(pdMS_TO_TICKS(LCD_POWER_SETTLE_DELAY_MS));\n    ST7701S_reset();" in lcd_source, (
    "LCD init should wait for panel power rails to settle before asserting reset"
)
reset_start = lcd_source.index("esp_err_t ST7701S_reset(void)")
reset_end = lcd_source.index("esp_err_t ST7701S_CS_EN(void)")
reset_body = lcd_source[reset_start:reset_end]
assert reset_body.index("gpio_set_level(LCD_RST, 0)") < reset_body.index("gpio_config(&io_conf)"), (
    "LCD reset GPIO should preload low before output enable"
)
assert "set LCD reset high failed" not in reset_body[:reset_body.index("gpio_set_level(LCD_RST, 0)")], (
    "LCD reset sequence must not drive high before the initial low reset pulse"
)
assert "set LCD reset low failed\");\n    ESP_RETURN_ON_ERROR(gpio_config(&io_conf)" in reset_body, (
    "LCD reset low should be applied before GPIO output mode"
)
assert "vTaskDelay(pdMS_TO_TICKS(LCD_RESET_LOW_DELAY_MS));" in reset_body, (
    "LCD reset should hold the panel low long enough for deterministic boot state"
)
assert "set LCD reset high failed\");\n    vTaskDelay(pdMS_TO_TICKS(LCD_RESET_RELEASE_DELAY_MS));" in reset_body, (
    "LCD reset should wait after release before SPI init starts"
)
assert "ST7701S_screen_init(st7701s, 1);\n    vTaskDelay(pdMS_TO_TICKS(200));" in lcd_source, (
    "RGB clocks should start only after ST7701S command init has settled"
)
