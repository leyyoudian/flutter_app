# Connected Review and OTA Design

## Goal

Add a server-backed workflow for app version checks, user asset moderation, review demo mode, ESP32 STA provisioning, GPIO0 credential reset, and ESP32 OTA.

## Scope

- ESP32 boots display normally even when Wi-Fi is unavailable.
- ESP32 stores Wi-Fi credentials once after AP provisioning and then runs in STA mode.
- GPIO0 long press clears saved Wi-Fi credentials and restarts provisioning mode.
- ESP32 exposes local HTTP/TCP control on whichever network is active.
- ESP32 OTA uses an OTA partition table and a non-blocking HTTPS OTA trigger.
- App exposes review/demo mode so store reviewers can see hardware-dependent screens without the device.
- App checks a backend version manifest and opens store URLs for app updates.
- User-created assets must be submitted to the backend and approved before normal upload to the badge.
- A local backend implementation is added for later deployment.

## Architecture

ESP32 networking becomes a background service. It starts the display and playback path independently, then tries saved STA credentials without blocking UI startup. If no credentials exist, or GPIO0 long press clears them, it starts a temporary provisioning AP that serves the existing `ProvisioningHTML.h` page and `/scan` plus `/set_config` endpoints. The same firmware HTTP server also exposes `/status`, `/upload`, `/brightness`, and `/ota`.

The App keeps local maker behavior, but uploading a user asset first submits it to the backend. Approved assets receive a review id/status and can then be uploaded to ESP32. Demo mode short-circuits device-dependent actions with simulated state.

The backend is a dependency-light Node service using filesystem JSON storage. It provides version manifests, asset submission/review APIs, a small admin UI, and OTA firmware manifests.

## Constraints

- App binaries update only through App Store / Google Play store URLs.
- User assets are locally previewable before approval but cannot be uploaded to ESP32 unless approved.
- Demo mode must be visible enough for reviewers and must not require hidden credentials.
- OTA requires repartitioning from single factory app to OTA slots, reducing the asset partition.
- OTA and Wi-Fi connection attempts must run outside the main display startup path.

## Testing

- Static firmware test verifies OTA partitions, STA/AP provisioning symbols, OTA symbols, and GPIO0 reset hook.
- Flutter static/widget tests verify demo mode, backend version check, moderation status, and upload gating.
- Node tests verify local backend version, moderation, admin approval, and OTA manifest endpoints.
