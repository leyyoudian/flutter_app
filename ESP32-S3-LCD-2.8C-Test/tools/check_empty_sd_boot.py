from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ANIM = (ROOT / "main" / "Badge" / "BadgeAnimMgr.c").read_text(
    encoding="utf-8", errors="ignore"
)
WIFI = (ROOT / "main" / "Wireless" / "WifiUpload.c").read_text(
    encoding="utf-8", errors="ignore"
)
DISPLAY = (ROOT / "main" / "Badge" / "BadgeDisplay.c").read_text(
    encoding="utf-8", errors="ignore"
)
SYNC = (ROOT / "main" / "Badge" / "BadgeFactorySync.c").read_text(
    encoding="utf-8", errors="ignore"
)


def extract_block(source: str, start_marker: str, end_marker: str) -> str:
    start = source.index(start_marker)
    end = source.index(end_marker, start)
    return source[start:end]


init_block = extract_block(
    ANIM,
    "esp_err_t badge_anim_mgr_init(void)",
    "esp_err_t badge_anim_mgr_rescan(void)",
)
assert "bool last_user_exists = false;" in init_block
assert "last_user_exists = true;" in init_block
assert "else if (last_user_exists)" in init_block
assert "clear_last_anim_id();" in init_block

got_ip_block = extract_block(
    WIFI,
    "event_base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP",
    "static esp_err_t ensure_wifi_stack(void)",
)
assert "badge_factory_sync_start_once();" in got_ip_block
assert got_ip_block.index("badge_factory_sync_start_once();") < got_ip_block.index(
    "start_auto_ota_check();"
)

player_block = extract_block(
    DISPLAY,
    "static void player_task(void *arg)",
    "esp_err_t badge_display_play_asset_file",
)
assert "if (ret == ESP_ERR_NOT_FOUND)" in player_block
assert "portMAX_DELAY" in player_block
assert "no asset available; waiting for sync or upload" in player_block

# An empty card must not remain blank until the complete factory catalog has
# downloaded. F001 is published as soon as it has passed size/hash/header
# validation, while the remainder keeps syncing in the background.
assert "publish_bootstrap_file_if_empty" in SYNC
assert 'strcmp(file->path, "first_half/F001.eb4")' in SYNC
assert "badge_anim_mgr_rescan();" in SYNC

# Avoid adding a fixed one-tick sleep for every 4 KiB received from the server.
download_block = extract_block(
    SYNC,
    "static esp_err_t download_file",
    "static int installed_revision",
)
assert "vTaskDelay" not in download_block

print("empty SD boot checks passed")
