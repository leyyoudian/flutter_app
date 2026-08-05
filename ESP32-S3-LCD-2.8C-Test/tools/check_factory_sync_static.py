from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SYNC_H = ROOT / "main" / "Badge" / "BadgeFactorySync.h"
SYNC_C = ROOT / "main" / "Badge" / "BadgeFactorySync.c"
WIFI_C = (ROOT / "main" / "Wireless" / "WifiUpload.c").read_text(encoding="utf-8", errors="ignore")

assert SYNC_H.exists()
assert SYNC_C.exists()

H = SYNC_H.read_text(encoding="utf-8", errors="ignore")
C = SYNC_C.read_text(encoding="utf-8", errors="ignore")

assert "badge_factory_sync_start_once" in H
assert "badge_factory_sync_is_running" in H
assert "factory_loop/F" in C
assert "/sdcard/.factory/catalog.json" in C
assert "/sdcard/.factory/install.json" in C
assert "badge_anim_mgr_rescan" in C
assert "badge_factory_sync_start_once();" in WIFI_C
assert "s_auto_ota_check_done" in WIFI_C

print("factory sync static checks passed")
