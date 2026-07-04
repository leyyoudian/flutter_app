# Connected Review and OTA Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement server-backed asset review, reviewer demo mode, app version checks, ESP32 STA provisioning, GPIO0 Wi-Fi reset, and ESP32 OTA.

**Architecture:** Firmware becomes a non-blocking STA-first network service with AP provisioning fallback. Flutter gates user uploads through backend moderation and adds demo mode. A local Node backend supplies version, moderation, admin, and OTA manifest APIs.

**Tech Stack:** ESP-IDF C, Flutter/Dart, Android Kotlin, iOS Swift, Node.js built-in HTTP/file storage.

## Global Constraints

- Do not roll back existing uncommitted user changes.
- Keep ESP32 display/playback startup independent from Wi-Fi availability.
- Use App Store / Google Play links for App binary updates.
- Require approval before uploading user-made assets to the badge.
- Keep backend deployable without mandatory third-party npm dependencies.

---

### Task 1: Tests First

**Files:**
- Create: `ESP32-S3-LCD-2.8C-Test/tools/check_wifi_provisioning_ota.py`
- Create: `app_gif/test/moderation_demo_static_test.dart`
- Create: `server/test/api.test.js`

**Steps:**
- [ ] Add static tests for OTA partition table, STA provisioning, OTA endpoint, and GPIO0 reset.
- [ ] Add Flutter static tests for demo mode, backend version check, moderation fields, and upload gating.
- [ ] Add Node API tests for version, asset submission, approval, and OTA manifest.
- [ ] Run the tests and confirm they fail before implementation.

### Task 2: Firmware Networking and OTA

**Files:**
- Modify: `ESP32-S3-LCD-2.8C-Test/partitions.csv`
- Modify: `ESP32-S3-LCD-2.8C-Test/sdkconfig.defaults`
- Modify: `ESP32-S3-LCD-2.8C-Test/main/CMakeLists.txt`
- Modify: `ESP32-S3-LCD-2.8C-Test/main/Wireless/WifiUpload.h`
- Modify: `ESP32-S3-LCD-2.8C-Test/main/Wireless/WifiUpload.c`
- Modify: `ESP32-S3-LCD-2.8C-Test/main/main.c`

**Steps:**
- [ ] Add OTA partition slots and `otadata`.
- [ ] Add STA credential storage and AP provisioning endpoints matching `ProvisioningHTML.h`.
- [ ] Run STA connect in background and keep display startup non-blocking.
- [ ] Add `/ota?url=...` handler that starts an HTTPS OTA task.
- [ ] Add GPIO0 long-press credential reset in the main loop.

### Task 3: Local Backend

**Files:**
- Create: `server/package.json`
- Create: `server/src/app.js`
- Create: `server/src/server.js`
- Create: `server/data/versions.json`
- Create: `server/data/ota.json`
- Create: `server/README.md`

**Steps:**
- [ ] Implement version manifest endpoint.
- [ ] Implement asset submission and status endpoints.
- [ ] Implement admin list, approve, and reject endpoints guarded by `X-Admin-Token`.
- [ ] Implement OTA manifest endpoint.
- [ ] Add a small admin HTML page.

### Task 4: Flutter App

**Files:**
- Modify: `app_gif/lib/main.dart`
- Modify: `app_gif/test/widget_test.dart`
- Modify: `app_gif/test/moderation_demo_static_test.dart`

**Steps:**
- [ ] Add backend client using `dart:io` HTTP APIs.
- [ ] Add app version check method and UI status.
- [ ] Add demo mode state and reviewer-visible entry.
- [ ] Add review fields to `PreparedAsset` and `HistoryEntry`.
- [ ] Gate user asset upload: submit pending assets for review; upload approved assets only.
- [ ] Simulate device actions in demo mode.

### Task 5: Verification

**Steps:**
- [ ] Run `python ESP32-S3-LCD-2.8C-Test/tools/check_wifi_provisioning_ota.py`.
- [ ] Run `flutter test test/moderation_demo_static_test.dart test/widget_test.dart` in `app_gif`.
- [ ] Run `npm test` in `server`.
- [ ] Attempt ESP-IDF build if local IDF tooling is available.
