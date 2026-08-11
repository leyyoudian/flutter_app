from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(text: str, needle: str, message: str) -> None:
    if needle not in text:
        raise AssertionError(message)


display = read("main/Badge/BadgeDisplay.c")
stream = read("main/Badge/BadgeStream.c")
storage = read("main/Badge/BadgeStorage.c")
lcd_h = read("main/LCD_Driver/ST7701S.h")
lcd_c = read("main/LCD_Driver/ST7701S.c")

require(
    lcd_h,
    "EXAMPLE_LCD_PIXEL_CLOCK_HZ     (12 * 1000 * 1000)",
    "normal RGB LCD PCLK should stay at the requested 12MHz target",
)
require(
    lcd_c,
    ".bounce_buffer_size_px = EXAMPLE_LCD_BOUNCE_BUFFER_LINES * EXAMPLE_LCD_H_RES",
    "RGB LCD should use an internal bounce buffer to reduce direct PSRAM DMA pressure",
)
if "esp_task_wdt.h" in display:
    raise AssertionError("badge player must not subscribe TWDT; frozen first-half frames are a normal state")
if "esp_task_wdt.h" in stream:
    raise AssertionError("SD stream must use a bounded active monitor instead of task TWDT subscription")
require(stream, "BADGE_STREAM_STALL_TIMEOUT_MS", "SD stream must define an active stall timeout")
require(stream, "BADGE_STREAM_MONITOR_INTERVAL_MS", "SD stream must define a monitor interval")
require(stream, "stream_monitor_task", "SD stream must create a software stall monitor")
require(stream, "last_progress_ms", "SD stream monitor must watch progress timestamps")
require(stream, "stream monitor stalled", "SD stream stall logs must be searchable in serial output")
require(stream, "xTaskCreate(stream_monitor_task", "SD stream monitor task must be started with each stream")
require(
    display,
    "BADGE_PLAYER_PRIORITY 4u",
    "badge player task must not outrank HTTP/Wi-Fi service work",
)
require(
    display,
    "BADGE_PLAYER_YIELD_EVERY_FRAMES 2u",
    "badge player must yield frequently during catch-up playback",
)
require(
    display,
    "BADGE_DISPLAY_DRAW_WARN_MS",
    "display path must log slow RGB framebuffer swaps",
)
require(
    display,
    "display swap slow",
    "display slow-swap logs must be searchable in serial output",
)
require(
    display,
    "BADGE_PLAYBACK_TRACE_START_FRAMES",
    "playback must trace the first few frames to locate startup stalls",
)
require(
    display,
    "BADGE_PLAYBACK_TRACE_PERIOD_FRAMES",
    "playback must keep sparse trace points after startup to locate later stalls",
)
require(
    display,
    "BADGE_PLAYBACK_CATCHUP_SKIP_FRAMES",
    "playback must define a bounded visual frame shedding policy",
)
require(
    display,
    "BADGE_PLAYBACK_STALL_TIMEOUT_MS",
    "badge player must define an active playback stall timeout",
)
require(
    display,
    "BADGE_PLAYBACK_MONITOR_INTERVAL_MS",
    "badge player must define a playback monitor interval",
)
require(
    display,
    "playback_trace_stage",
    "playback trace helper must keep startup stall logs consistent",
)
require(
    display,
    "playback_monitor_task",
    "badge player must monitor playback progress independently of the SD stream task",
)
require(
    display,
    "playback monitor stalled",
    "playback monitor restart logs must be searchable in serial output",
)
require(
    display,
    "xTaskCreate(playback_monitor_task",
    "playback monitor task must start during display init",
)
require(
    display,
    "playback_set_active(true)",
    "playback monitor must be enabled only during active playback",
)
require(
    display,
    "playback_set_active(false)",
    "playback monitor must be disabled while holding a frozen frame",
)
require(
    display,
    "should_skip_visual_frame",
    "playback must skip rendering non-essential visual frames when it falls behind",
)
require(
    display,
    "force_full_render_after_skip",
    "playback must force a full render after skipped tile frames to preserve delta correctness",
)
require(
    display,
    "s_perf_skipped_visual",
    "playback performance logs must count visually skipped frames",
)
require(
    display,
    "skip visual frame",
    "visual frame shedding must be searchable in serial output",
)
require(
    display,
    "play trace frame=%u stage=%s point=%s",
    "playback trace logs must show frame, stage, and begin/end point",
)
for stage in ("read", "decode", "render", "display"):
    require(
        display,
        f'"{stage}"',
        f"playback trace must include the {stage} stage",
    )
require(
    stream,
    "BADGE_STREAM_TASK_PRIORITY 4u",
    "SD stream prefetch task must not outrank HTTP/Wi-Fi service work",
)
require(
    stream,
    "BADGE_STREAM_READ_WARN_MS",
    "SD stream task must log slow SD reads",
)
require(
    stream,
    "stream read slow",
    "SD slow-read logs must be searchable in serial output",
)
require(
    stream,
    "BADGE_STREAM_STOP_TIMEOUT_MS",
    "stream shutdown must have a bounded timeout instead of hanging forever",
)
require(
    stream,
    "esp_restart()",
    "a wedged SD stream must reboot instead of leaving display and Wi-Fi stuck",
)
require(
    storage,
    "host.max_freq_khz = SDMMC_FREQ_HIGHSPEED",
    "SDMMC playback should use highspeed mode after stream TWDT false positives are removed",
)
require(
    storage,
    "esp_err_t ret = try_mount_sd_width_locked(4)",
    "SD playback should try 4-bit mode first",
)
require(
    storage,
    "return try_mount_sd_width_locked(1)",
    "SD playback should still fall back to 1-bit mode if 4-bit mount fails",
)
if "BADGE_SD_PLAYBACK_MAX_FREQ_KHZ 10000u" in storage:
    raise AssertionError("SD playback path should not force the temporary 10MHz workaround")

print("display Wi-Fi stall resilience checks passed")
