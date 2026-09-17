# Server Migration And Firmware/App Failover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add primary/fallback server routing across the app and firmware, make server transcode hardware-aware, and prepare a safe migration of release artifacts to the new ECS.

**Architecture:** The client and firmware each maintain an ordered primary/fallback endpoint list and retry transport failures without changing the asset format. The server transcode endpoint receives a hardware target and selects the corresponding package encoder. Migration is a separate staged operation requiring authenticated remote access, with checksums and metadata validation before activation.

**Tech Stack:** Flutter/Dart, Kotlin, Swift, ESP-IDF C, Node.js/Express, FFmpeg, HTTP, SSH/Alibaba Workbench.

**Spec:** `docs/superpowers/specs/2026-09-17-server-migration-failover.md`

## Global Constraints

- New primary server: `http://47.108.204.22`; fallback server: `http://60.205.122.153`.
- Never commit the supplied server password or any other secret.
- S3 and P4 package formats must remain distinct and selected by hardware.
- Back up remote data before overwriting it.
- Preserve legacy HTTP OTA compatibility on TCP 80; do not expose internal port 8787 when a reverse proxy is used.

### Task 1: Add app endpoint failover

**Files:**
- Modify: `app_gif/lib/main.dart`
- Modify: `app_gif/android/app/src/main/kotlin/com/example/app_gif/MainActivity.kt`
- Modify: `app_gif/ios/Runner/AppDelegate.swift`
- Test: `app_gif/test/backend_failover_static_test.dart`

**Interfaces:**
- Produce `backendBaseCandidates`, `_withBackendFailover`, and `_invokeBackendNative` in `main.dart`.
- Native methods continue accepting a single `backendBase`; Dart retries them with the next candidate.

- [ ] **Step 1:** Add a static test that requires the primary and fallback constants, ordered retry helper usage, and no old private-LAN default.
- [ ] **Step 2:** Run the test and verify it fails on the current single-base implementation.
- [ ] **Step 3:** Implement ordered HTTP and native retries, retaining `ESP_BAJI_API_BASE` as an optional override.
- [ ] **Step 4:** Update Android native defaults to the primary public endpoint; keep Dart-provided overrides authoritative.
- [ ] **Step 5:** Run the focused Dart test and `flutter analyze --no-fatal-infos`.

### Task 2: Make server transcoding hardware-aware

**Files:**
- Modify: `server/src/transcode.js`
- Modify: `server/src/app.js`
- Modify: `app_gif/lib/transcode_policy.dart`
- Modify: `app_gif/lib/main.dart`
- Test: `server/test/transcode.test.js`

**Interfaces:**
- `transcodeToEbaj({ inputPath, outputPath, fps, streamSize, crop, hardware })` preserves the current EBAJ4 return shape and validates `hardware`.
- API payload includes `hardware: 'esp32s3'` or `hardware: 'esp32p4'`.

- [ ] **Step 1:** Add tests for fps cap at 80 and distinct S3/P4 hardware selection.
- [ ] **Step 2:** Run the tests to capture the current failure.
- [ ] **Step 3:** Implement explicit hardware validation and package selection without changing the existing S3 encoder behavior.
- [ ] **Step 4:** Pass the connected device hardware from the app upload/transcode request.
- [ ] **Step 5:** Run server tests and the app static tests.

### Task 3: Add firmware OTA/catalog fallback

**Files:**
- Modify: `ESP32-S3-LCD-2.8C-Test/main/Wireless/WifiUpload.c`
- Modify: `ESP32-S3-LCD-2.8C-Test/main/Badge/BadgeFactorySync.c`
- Modify: `ESP32-S3-LCD-2.8C-Test/plus-idf/esp32-p4c5-dotloop/main/Wireless/WifiUpload.c`
- Modify: `ESP32-S3-LCD-2.8C-Test/plus-idf/esp32-p4c5-dotloop/main/Badge/BadgeFactorySync.c`
- Modify: `ESP32-S3-LCD-2.8C-Test/plus-idf/esp32-p4c5-dotloop-2.5/main/Wireless/WifiUpload.c`
- Modify: `ESP32-S3-LCD-2.8C-Test/plus-idf/esp32-p4c5-dotloop-2.5/main/Badge/BadgeFactorySync.c`
- Test: `ESP32-S3-LCD-2.8C-Test/tools/check_wifi_provisioning_ota.py`

- [ ] **Step 1:** Add static checks for both endpoints in all three firmware variants.
- [ ] **Step 2:** Run the checker and verify it fails before implementation.
- [ ] **Step 3:** Implement bounded primary-then-fallback requests for OTA manifests and factory catalogs.
- [ ] **Step 4:** Run the checker and compile the S3 target if the local ESP-IDF toolchain is available.

### Task 4: Version and release metadata

**Files:**
- Modify: `app_gif/pubspec.yaml`
- Modify: `app_gif/lib/main.dart`
- Modify: `ESP32-S3-LCD-2.8C-Test/CMakeLists.txt`
- Modify: `server/data/versions.json`
- Modify: `server/data/app_versions.json`
- Modify: `server/data/ota.json`
- Modify: `server/data/firmware_versions.json`

- [ ] **Step 1:** Bump app and S3 firmware patch versions only after code changes are verified.
- [ ] **Step 2:** Update release metadata to use the primary URL while retaining legacy history.
- [ ] **Step 3:** Validate JSON and run static tests.

### Task 5: Authenticated server migration

**Files/Artifacts:**
- Remote backup directory: `/root/dotloop-migration-backup-<timestamp>`.
- Remote staging directory: `/root/dotloop-migration-staging-<release>`.

- [ ] **Step 1:** Authenticate to `47.108.204.22` with a user-supplied valid SSH key/password or Alibaba Workbench credentials and record the instance identity.
- [ ] **Step 2:** Inventory service, data, ports, and existing hashes; do not overwrite files yet.
- [ ] **Step 3:** Create a timestamped remote backup and upload the staged server data/artifacts.
- [ ] **Step 4:** Validate OTA/app manifests, artifact hashes, and factory catalog reads on the new server.
- [ ] **Step 5:** Upload the same release artifacts to the old server using its admin API and validate both manifests.
- [ ] **Step 6:** Report the final open ports and any server-side action still required.

## Verification

Run the focused static/unit tests, JSON parsing checks, firmware static checker, and read-only API probes against both servers. Do not claim migration complete while new-server authentication or port 80/443 health checks fail.
