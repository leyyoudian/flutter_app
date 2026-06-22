from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DISPLAY = ROOT / "main" / "Badge" / "BadgeDisplay.c"
MAIN = ROOT / "main" / "main.c"


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


display_source = DISPLAY.read_text(encoding="utf-8")
protocol_source = (ROOT / "main" / "Badge" / "BadgeProtocol.h").read_text(encoding="utf-8")
protocol_c_source = (ROOT / "main" / "Badge" / "BadgeProtocol.c").read_text(encoding="utf-8")
switch_body = extract_function(display_source, "switch_panel_to_fb")
player_body_start = display_source.index("static esp_err_t player_loop_asset(")
assert "esp_lcd_rgb_panel_restart" not in switch_body, (
    "switch_panel_to_fb must not restart the RGB panel every frame"
)
assert "esp_err_t draw_ret = esp_lcd_panel_draw_bitmap" in switch_body and "draw_ret != ESP_OK" in switch_body, (
    "display path should log full-frame draw_bitmap errors"
)
assert "esp_err_t vsync_ret = LCD_WaitForVsync" in switch_body and "vsync_ret != ESP_OK" in switch_body, (
    "display path should log vsync wait errors"
)

main_source = MAIN.read_text(encoding="utf-8")
assert "BADGE_FW_BUILD_ID" in main_source, "firmware build id must be logged at boot"
assert "BADGE_EBAJ_MAGIC_V4" in protocol_source, "protocol must define EBAJ4"
assert "preload_asset_to_psram" not in display_source, "player must not preload full SD asset into PSRAM"
assert "BadgeStream.h" in display_source, "display path must use streamed SD prefetch"
assert "BadgeIndexed.h" in display_source, "display path must decode indexed EBAJ4 frames"
assert "badge_stream_read_frame" in display_source, "player must consume prefetched frame payloads"
assert "BADGE_TARGET_FRAME_US 50000" in display_source, "player must drive a fixed stable 20fps output clock"
assert "underrun" in display_source, "player must log underruns"
assert "#define BADGE_FPS_OVERLAY_ENABLED 0u" in display_source, "runtime FPS overlay must be disabled by default"
assert "#include \"BadgeLz4.h\"" not in display_source, "display path must not depend on realtime LZ4 decode"
assert "BADGE_EBAJ_MAGIC_V3" not in protocol_c_source, "runtime header validator must reject old EBAJ3 packages"
assert "asset format magic=" in display_source, "player must log asset format and codec distribution"

lcd_source = (ROOT / "main" / "LCD_Driver" / "ST7701S.c").read_text(encoding="utf-8")
assert "EXAMPLE_LCD_NUM_FB > 1 ? 0 :" in lcd_source, (
    "RGB panel must not enable bounce buffers when using multiple full frame buffers"
)
