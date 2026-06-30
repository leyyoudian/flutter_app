from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WIFI_UPLOAD = ROOT / "main" / "Wireless" / "WifiUpload.c"
DISPLAY = ROOT / "main" / "Badge" / "BadgeDisplay.c"
PROTOCOL = ROOT / "main" / "Badge" / "BadgeProtocol.h"
SDKCONFIG = ROOT / "sdkconfig"
SDKCONFIG_DEFAULTS = ROOT / "sdkconfig.defaults"

wifi = WIFI_UPLOAD.read_text(encoding="utf-8")
display = DISPLAY.read_text(encoding="utf-8")
protocol = PROTOCOL.read_text(encoding="utf-8")
sdkconfig = SDKCONFIG.read_text(encoding="utf-8")
sdkconfig_defaults = SDKCONFIG_DEFAULTS.read_text(encoding="utf-8")

assert "BADGE_UPLOAD_TCP_PORT" in wifi, "firmware must expose a raw TCP upload port"
assert "tcp_upload_task" in wifi, "firmware must run a raw TCP upload server"
assert "BADGE_HTTP_UPLOAD_BUF (64u * 1024u)" in wifi, "HTTP upload buffer should use the faster SDIO path"
assert "BADGE_TCP_UPLOAD_BUF (64u * 1024u)" in wifi, "TCP upload buffer should use the faster SDIO path"
assert "BADGE_UPLOAD_BUF_FALLBACK_BYTES (32u * 1024u)" in wifi, "upload receive buffers must fall back when 64KB is unavailable"
assert "BADGE_UPLOAD_BUF_MIN_BYTES (16u * 1024u)" in wifi, "upload receive buffers need a small last-resort allocation"
assert "BADGE_UPLOAD_WRITE_COALESCE_BYTES (128u * 1024u)" in wifi, "upload path should coalesce larger SDIO writes"
assert "BADGE_UPLOAD_WRITE_COALESCE_FALLBACK_BYTES (64u * 1024u)" in wifi, "coalesce buffer must fall back when 128KB is unavailable"
assert "BADGE_UPLOAD_WRITE_COALESCE_MIN_BYTES (32u * 1024u)" in wifi, "coalesce buffer needs a small last-resort allocation"
assert "flush_upload_coalesce" in wifi, "upload path must flush coalesced writes"
assert "session->coalesce_size" in wifi, "coalesce logic must use the allocated fallback size"
assert "if (session->coalesce == NULL || session->coalesce_size == 0)" in wifi, "upload must continue without coalesce memory"
assert "no coalesce memory" not in wifi, "coalesce allocation failure must not abort uploads"
assert "MALLOC_CAP_INTERNAL | MALLOC_CAP_DMA | MALLOC_CAP_8BIT" in wifi, "upload receive buffer should prefer internal DMA memory"
assert "upload_buf_caps" in wifi, "upload logs should report receive buffer capabilities"
assert "esp_wifi_set_protocol" in wifi and "WIFI_PROTOCOL_11N" in wifi, "AP must enable 11n protocol"
assert "WIFI_PROTOCOL_11B | WIFI_PROTOCOL_11G | WIFI_PROTOCOL_11N" in wifi, (
    "ESP-IDF SoftAP should keep the valid b/g/n protocol mask"
)
assert "BADGE_WIFI_INACTIVE_TIME_SEC" in wifi and "esp_wifi_set_inactive_time(WIFI_IF_AP" in wifi, (
    "SoftAP should keep the phone associated during slow uploads"
)
assert "BADGE_UPLOAD_DIAG_STEP_BYTES (64u * 1024u)" in wifi, "upload diagnostics should log early enough to catch first-body stalls"
assert "upload chunk offset=" in wifi, "failed uploads need per-chunk recv/write timing diagnostics"
assert "BADGE_TCP_RCVBUF_BYTES" in wifi and "SO_RCVBUF" in wifi, "TCP uploads should request a larger receive buffer"
assert "CONFIG_LWIP_SO_RCVBUF=y" in sdkconfig, "SO_RCVBUF must be enabled or the TCP receive buffer request is ignored"
assert "CONFIG_LWIP_SO_RCVBUF=y" in sdkconfig_defaults, "defaults must keep SO_RCVBUF enabled for upload builds"
assert "CONFIG_LWIP_TCP_WND_DEFAULT=65535" in sdkconfig, "TCP receive window must not throttle phone uploads"
assert "CONFIG_LWIP_TCP_RECVMBOX_SIZE=32" in sdkconfig, "TCP recv mailbox should handle larger upload bursts"
assert "CONFIG_ESP_WIFI_RX_BA_WIN=16" in sdkconfig, "Wi-Fi AMPDU RX BA window should allow faster phone uploads"
assert "CONFIG_ESP_WIFI_DYNAMIC_RX_BUFFER_NUM=64" in sdkconfig, "Wi-Fi dynamic RX buffers should allow upload bursts"
assert "# CONFIG_SPI_FLASH_AUTO_SUSPEND is not set" in sdkconfig, (
    "Winbond flash on this board must not enable startup flash suspend"
)
assert "CONFIG_SPI_FLASH_AUTO_CHECK_SUSPEND_STATUS" not in sdkconfig, (
    "flash suspend status checks are invalid when suspend is disabled"
)
assert "CONFIG_SPI_FLASH_AUTO_SUSPEND=y" not in sdkconfig_defaults, (
    "defaults must not re-enable flash suspend on the next configure"
)
assert "WIFI_COUNTRY_POLICY_MANUAL" in wifi and ".ssid_hidden = 0" in wifi, "SoftAP should advertise predictably"
assert "try_spiram" in wifi and "alloc_upload_buffer_exact(size, false)" in wifi, (
    "upload receive buffer should prefer smaller internal memory before falling back to SPIRAM"
)
assert "esp_wifi_set_max_tx_power" in wifi, "AP should request high TX power"
assert "mbps_x100" in wifi, "upload logs must include throughput"
assert "send_tcp_ready" in wifi and "READY\\n" in wifi, "TCP upload should send READY before the phone streams payload"
assert "val ready = reader.readLine().orEmpty()" in (ROOT.parent / "app_gif" / "android" / "app" / "src" / "main" / "kotlin" / "com" / "example" / "app_gif" / "MainActivity.kt").read_text(encoding="utf-8"), (
    "Android upload should wait for firmware READY before streaming payload"
)
assert "badge_display_enter_upload_mode" in wifi, "upload path must enter display upload mode"
assert "badge_display_exit_upload_mode" in wifi, "upload path must exit display upload mode"
assert "badge_display_enter_upload_mode" in display, "display upload-mode API missing"
assert "show_upload_screen" in display, "display must blank or darken during upload"
assert "BADGE_EBAJ_DEFAULT_FPS 25u" in protocol, "protocol must target stable 25fps by default"
assert "BADGE_EBAJ_FRAME_DELAY_MS 40u" in protocol, "default frame delay must be 40ms"
assert "BADGE_EBAJ_MAX_FPS 30u" in protocol, "protocol should cap uploads at 30fps"
