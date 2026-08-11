# OTA Update Screen Plan

## Goal

Show a fixed on-device OTA update screen while firmware OTA is running, instead of leaving the LCD blank or showing the previous animation state.

## Scope

- Add a firmware-rendered RGB565 OTA screen in `BadgeDisplay.c`.
- Keep the existing OTA flow in `WifiUpload.c`: pause display before OTA, restart on success, resume playback if OTA fails.
- Add static verification that OTA pause draws the OTA screen and keeps failure recovery intact.

## Steps

1. Extend the OTA static check so the current code fails until an OTA screen renderer exists.
2. Add small RGB565 drawing helpers and a minimal text renderer for the OTA message.
3. Implement `show_ota_screen()` and call it from `badge_display_pause_for_ota()` after the player is paused.
4. Run the OTA/display checks and then build the ESP-IDF firmware.

## Acceptance

- `badge_display_pause_for_ota()` pauses playback, draws the OTA screen, and returns errors if pausing fails.
- OTA success still restarts the ESP32; OTA failure still releases the player.
- The screen visibly communicates that firmware update is in progress and power must not be removed.
