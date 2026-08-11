from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WIFI_UPLOAD = ROOT / "main" / "Wireless" / "WifiUpload.c"

wifi = WIFI_UPLOAD.read_text(encoding="utf-8")


def require(text: str, needle: str, message: str) -> None:
    if needle not in text:
        raise AssertionError(message)


require(wifi, "IP_EVENT_STA_LOST_IP", "STA lost-IP events must be registered and logged")
require(wifi, "wifi_health_task", "STA health monitor task must detect silent Wi-Fi state loss")
require(wifi, "BADGE_WIFI_HEALTH_INTERVAL_MS", "STA health monitor must run periodically")
require(wifi, "esp_wifi_sta_get_ap_info", "health monitor must verify STA association state")
require(wifi, "STA health", "health monitor logs must be searchable in serial output")
require(wifi, "schedule_saved_sta_retry", "all reconnect requests should go through one guarded scheduler")
require(wifi, "start_wifi_health_task", "Wi-Fi init must start the STA health monitor")
require(wifi, "WIFI_BW_HT20", "STA/AP should force HT20 for marginal RF hardware")
require(wifi, "sta_config.sta.failure_retry_cnt", "STA config should let the Wi-Fi driver retry marginal associations")
require(wifi, "create wifi retry task failed", "retry task creation failure must be logged")
require(wifi, "ESP_EVENT_ANY_ID", "Wi-Fi event handler should keep broad event visibility")

print("wifi STA resilience checks passed")
