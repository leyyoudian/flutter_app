from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WIFI_UPLOAD = ROOT / "main" / "Wireless" / "WifiUpload.c"
DISPLAY = ROOT / "main" / "Badge" / "BadgeDisplay.c"
PROTOCOL = ROOT / "main" / "Badge" / "BadgeProtocol.h"

wifi = WIFI_UPLOAD.read_text(encoding="utf-8")
display = DISPLAY.read_text(encoding="utf-8")
protocol = PROTOCOL.read_text(encoding="utf-8")

assert "BADGE_UPLOAD_TCP_PORT" in wifi, "firmware must expose a raw TCP upload port"
assert "tcp_upload_task" in wifi, "firmware must run a raw TCP upload server"
assert "BADGE_HTTP_UPLOAD_BUF (32u * 1024u)" in wifi, "HTTP upload buffer should fit internal memory"
assert "BADGE_TCP_UPLOAD_BUF (32u * 1024u)" in wifi, "TCP upload buffer should fit internal memory"
assert "BADGE_UPLOAD_WRITE_COALESCE_BYTES (32u * 1024u)" in wifi, "upload path should coalesce small recv chunks before SD writes"
assert "flush_upload_coalesce" in wifi, "upload path must flush coalesced writes"
assert "MALLOC_CAP_INTERNAL | MALLOC_CAP_DMA | MALLOC_CAP_8BIT" in wifi, "upload receive buffer should prefer internal DMA memory"
assert "upload_buf_caps" in wifi, "upload logs should report receive buffer capabilities"
assert "esp_wifi_set_protocol" in wifi and "WIFI_PROTOCOL_11N" in wifi, "AP must enable 11n protocol"
assert "esp_wifi_set_max_tx_power" in wifi, "AP should request high TX power"
assert "mbps_x100" in wifi, "upload logs must include throughput"
assert "badge_display_enter_upload_mode" in wifi, "upload path must enter display upload mode"
assert "badge_display_exit_upload_mode" in wifi, "upload path must exit display upload mode"
assert "badge_display_enter_upload_mode" in display, "display upload-mode API missing"
assert "show_upload_screen" in display, "display must blank or darken during upload"
assert "BADGE_EBAJ_FPS 20u" in protocol, "protocol must target stable 20fps"
assert "BADGE_EBAJ_FRAME_DELAY_MS 50u" in protocol, "frame delay must be 50ms"
