# Device Asset Delete Synchronization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make app-side user material deletion durable and synchronize it to the original P4 device without deleting factory assets or newer content that reused the same `Uxxx` ID.

**Architecture:** A pure Dart tombstone queue owns deletion identity and retry policy. Android/iOS persist the queue and expose TCP identity/status/delete commands. P4 stores per-user-file CRC metadata, validates guarded switch/delete requests, and pauses playback before filesystem mutation.

**Tech Stack:** Flutter/Dart, Android Kotlin MethodChannel, iOS Swift/Network.framework, ESP-IDF 5.4 C/FreeRTOS/FatFS, pytest hardware protocol client.

**Spec:** `docs/superpowers/specs/2026-08-17-device-asset-delete-sync-design.md`

## Global Constraints

- Only exact `U` plus three decimal digits may be deleted.
- `Fxxx` factory assets must never reach a delete filesystem path.
- A deletion is addressed by stable P4 device key, device asset ID, and full package CRC32.
- Updated guarded switches must return `NEED_UPLOAD` on missing or mismatched content.
- App deletion intent must be persisted before visible history is removed.
- Existing uncommitted user changes must be preserved; do not commit dirty implementation files.
- TCP protocol remains backward-compatible with `SWITCH U006` without a CRC.

---

### Task 1: Pure Dart Tombstone Policy

**Files:**
- Create: `app_gif/lib/device_asset_delete.dart`
- Create: `app_gif/test/device_asset_delete_test.dart`

**Interfaces:**
- Produces: `PendingDeviceDeletion`, `DeviceAssetDeleteOutcome`, `isUserDeviceAssetId`, `coalescePendingDeviceDeletions`, `pendingDeletionsForDevice`, and `parseDeviceAssetDeleteResponse`.
- Consumes: JSON-compatible `Map<String, Object?>` values from platform preferences.

- [ ] **Step 1: Write failing model and policy tests**

```dart
test('only exact Uxxx IDs are deletable', () {
  expect(isUserDeviceAssetId('U006'), isTrue);
  for (final id in ['F006', 'U06', 'U1000', 'U00/', '../U006']) {
    expect(isUserDeviceAssetId(id), isFalse, reason: id);
  }
});

test('replayed old deletion cannot target a different device or crc', () {
  final old = PendingDeviceDeletion(
    deviceKey: 'P4-AAAA', deviceAssetId: 'U006', crc32: 0x11111111,
    createdAt: 1,
  );
  expect(old.matchesDevice('P4-BBBB'), isFalse);
  expect(old.operationKey, 'P4-AAAA|U006|11111111');
});

test('terminal responses clear queue while busy retries', () {
  expect(parseDeviceAssetDeleteResponse('OK DELETED U006'), DeviceAssetDeleteOutcome.deleted);
  expect(parseDeviceAssetDeleteResponse('OK MISSING U006'), DeviceAssetDeleteOutcome.missing);
  expect(parseDeviceAssetDeleteResponse('OK STALE U006'), DeviceAssetDeleteOutcome.stale);
  expect(parseDeviceAssetDeleteResponse('ERR BUSY'), DeviceAssetDeleteOutcome.retry);
});
```

- [ ] **Step 2: Run RED test**

Run: `flutter test test/device_asset_delete_test.dart`

Expected: FAIL because `device_asset_delete.dart` and its public API do not exist.

- [ ] **Step 3: Implement the minimal immutable model and pure policies**

```dart
bool isUserDeviceAssetId(String? value) =>
    value != null && RegExp(r'^U\d{3}$').hasMatch(value);

String crc32Hex(int value) =>
    (value & 0xffffffff).toRadixString(16).padLeft(8, '0');

enum DeviceAssetDeleteOutcome { deleted, missing, stale, retry, rejected }

class PendingDeviceDeletion {
  const PendingDeviceDeletion({
    required this.deviceKey,
    required this.deviceAssetId,
    required this.crc32,
    required this.createdAt,
  });
  final String? deviceKey;
  final String deviceAssetId;
  final int crc32;
  final int createdAt;
  String get operationKey =>
      '${deviceKey ?? 'legacy'}|$deviceAssetId|${crc32Hex(crc32)}';
  bool matchesDevice(String value) => deviceKey == value;
  Map<String, Object?> toMap() => <String, Object?>{
    'deviceKey': deviceKey,
    'deviceAssetId': deviceAssetId,
    'crc32': crc32,
    'createdAt': createdAt,
  };
  factory PendingDeviceDeletion.fromMap(Map<String, dynamic> map) {
    final id = map['deviceAssetId'] as String?;
    final crc = (map['crc32'] as num?)?.toInt();
    final created = (map['createdAt'] as num?)?.toInt();
    if (!isUserDeviceAssetId(id) || crc == null || created == null) {
      throw const FormatException('invalid pending device deletion');
    }
    return PendingDeviceDeletion(
      deviceKey: map['deviceKey'] as String?,
      deviceAssetId: id!,
      crc32: crc,
      createdAt: created,
    );
  }
}
```

Implement `fromMap` with strict ID/CRC validation and make coalescing retain the oldest operation by `operationKey`.

- [ ] **Step 4: Run GREEN tests and format**

Run: `dart format lib/device_asset_delete.dart test/device_asset_delete_test.dart && flutter test test/device_asset_delete_test.dart`

Expected: all policy tests pass.

### Task 2: P4 User Asset Identity and Metadata Store

**Files:**
- Create: `ESP32-S3-LCD-2.8C-Test/plus-idf/esp32-p4c5-dotloop/main/Badge/BadgeUserAsset.h`
- Create: `ESP32-S3-LCD-2.8C-Test/plus-idf/esp32-p4c5-dotloop/main/Badge/BadgeUserAsset.c`
- Modify: `ESP32-S3-LCD-2.8C-Test/plus-idf/esp32-p4c5-dotloop/main/CMakeLists.txt`
- Create: `tools/test_device_asset_delete_protocol.py`

**Interfaces:**
- Produces: `badge_user_asset_valid_id`, `badge_user_asset_device_key`, `badge_user_asset_write_meta`, `badge_user_asset_status`, and `badge_user_asset_unlink`.
- Consumes: `badge_crc32_update`/`badge_crc32_finish` and mounted `/sdcard/user`.

- [ ] **Step 1: Write a failing non-destructive protocol test**

```python
def test_identity_and_factory_delete_guard(client):
    assert client.command("IDENTITY\n").startswith("OK DEVICE P4-")
    assert client.command("DELETE F001 00000000\n") == "ERR FORBIDDEN"
    assert client.command("DELETE ../U001 00000000\n") == "ERR INVALID"
```

The client accepts `--host`, uses TCP port 3333, and never deletes a real user file in this step.

- [ ] **Step 2: Run RED hardware test against current firmware**

Run: `python tools/test_device_asset_delete_protocol.py --host 10.47.48.216 --non-destructive`

Expected: FAIL because `IDENTITY`/`DELETE` are not recognized.

- [ ] **Step 3: Implement strict IDs, stable identity, metadata, and legacy CRC**

```c
typedef enum {
    BADGE_USER_ASSET_MATCH,
    BADGE_USER_ASSET_MISSING,
    BADGE_USER_ASSET_STALE,
} badge_user_asset_status_t;

bool badge_user_asset_valid_id(const char *id);
esp_err_t badge_user_asset_device_key(char *out, size_t out_size);
esp_err_t badge_user_asset_write_meta(const char *id, uint32_t size, uint32_t crc32);
esp_err_t badge_user_asset_status(const char *id, uint32_t expected_crc,
                                  badge_user_asset_status_t *out_status);
esp_err_t badge_user_asset_unlink(const char *id);
```

Use base efuse MAC with the exact format `P4-%02X%02X%02X%02X%02X%02X`. Metadata is a packed fixed-width record written to `U006.meta.tmp`, `fsync`ed, then renamed to `U006.meta`. If metadata is absent, stream the `.eb4` file through the existing CRC implementation and create metadata only after a successful full read.

- [ ] **Step 4: Add `BadgeUserAsset.c` to the IDF component and build**

Run from the P4 project: `idf.py build`

Expected: build succeeds without new warnings in `BadgeUserAsset.c`.

### Task 3: P4 TCP Commands and Playback-Safe Delete

**Files:**
- Modify: `ESP32-S3-LCD-2.8C-Test/plus-idf/esp32-p4c5-dotloop/main/Badge/BadgeAnimMgr.h`
- Modify: `ESP32-S3-LCD-2.8C-Test/plus-idf/esp32-p4c5-dotloop/main/Badge/BadgeAnimMgr.c`
- Modify: `ESP32-S3-LCD-2.8C-Test/plus-idf/esp32-p4c5-dotloop/main/Wireless/WifiUpload.c`
- Test: `tools/test_device_asset_delete_protocol.py`

**Interfaces:**
- Produces: `badge_anim_mgr_delete_user(const char *id, uint32_t crc32, badge_user_asset_status_t *status)`.
- Consumes: Task 2 metadata/status API and existing display upload pause/resume API.

- [ ] **Step 1: Extend the failing protocol client for `STAT`, guarded `SWITCH`, and disposable upload/delete**

```python
assigned = client.upload(package_path)
assert client.command(f"STAT {assigned} {package_crc:08x}\n") == f"OK MATCH {assigned}"
assert client.command(f"SWITCH {assigned} {wrong_crc:08x}\n") == f"NEED_UPLOAD {assigned}"
assert client.command(f"DELETE {assigned} {wrong_crc:08x}\n") == f"OK STALE {assigned}"
assert client.command(f"DELETE {assigned} {package_crc:08x}\n") == f"OK DELETED {assigned}"
assert client.command(f"DELETE {assigned} {package_crc:08x}\n") == f"OK MISSING {assigned}"
```

Generate or select a small disposable valid EBAJ package and delete only the ID returned by that upload.

- [ ] **Step 2: Run RED test against the newly built but not-yet-modified command handler**

Expected: identity may pass after Task 2, while `STAT`, guarded `SWITCH`, and `DELETE` fail.

- [ ] **Step 3: Implement command parsing and metadata creation after upload**

Add exact parsers for:

```text
IDENTITY
STAT U006 89abcdef
DELETE U006 89abcdef
SWITCH U006 89abcdef
```

Keep legacy `SWITCH U006` behavior. After upload rename succeeds, call `badge_user_asset_write_meta(user_id, total_size, expected_crc32)` before returning `OK Uxxx`.

- [ ] **Step 4: Implement safe deletion in the animation manager**

Pause with `badge_display_pause_for_upload`, re-check content identity, unlink package/metadata, clear a deleted current/pending ID, rescan, select a factory fallback, update last-played persistence, then resume. Every error path must resume the display if this function paused it.

- [ ] **Step 5: Build and flash P4, then run protocol GREEN tests**

Run: `idf.py build flash -p COM13` followed by the protocol test using the discovered LAN IP.

Expected: all protocol cases pass and the disposable asset remains deleted after reboot.

### Task 4: Android and iOS Native Bridge

**Files:**
- Modify: `app_gif/android/app/src/main/kotlin/com/example/app_gif/MainActivity.kt`
- Modify: `app_gif/ios/Runner/AppDelegate.swift`
- Modify: `app_gif/test/android_wifi_upload_static_test.dart`
- Modify: `app_gif/test/ios_native_static_test.dart`

**Interfaces:**
- Produces MethodChannel methods: `loadPendingDeviceDeletes`, `savePendingDeviceDeletes`, `getDeviceIdentity`, `statDeviceAsset`, and `deleteDeviceAsset`.
- Extends: `switchToAsset` consumes optional `crc32`; `uploadAsset` result includes `deviceKey`.

- [ ] **Step 1: Add failing native contract tests**

Assert that both platform handlers expose all five methods, guarded switch includes eight-digit CRC, and upload results include `deviceKey`. These tests guard the app/platform boundary; protocol behavior remains covered by the real hardware test.

- [ ] **Step 2: Run RED platform tests**

Run: `flutter test test/android_wifi_upload_static_test.dart test/ios_native_static_test.dart`

Expected: FAIL on missing channel methods.

- [ ] **Step 3: Implement Android bridge and persistent queue**

Store JSON under `pending_device_deletes_v1` in the existing `esp_baji` SharedPreferences. Reuse `sendRawTcpCommandWithRetry` for identity/status/delete and serialize commands through one synchronization lock so delete cannot overlap upload or switch.

- [ ] **Step 4: Implement equivalent iOS bridge**

Store the same JSON-compatible maps in `UserDefaults`. Use the existing `sendRawTcpCommand` path and the same response strings.

- [ ] **Step 5: Run GREEN platform tests and Android compilation**

Run: `flutter test test/android_wifi_upload_static_test.dart test/ios_native_static_test.dart && flutter build apk --debug`

Expected: tests and Kotlin compilation pass.

### Task 5: Flutter Queue Orchestration and History Migration

**Files:**
- Modify: `app_gif/lib/main.dart`
- Modify: `app_gif/lib/transcode_policy.dart` only if stable identity helpers belong there
- Modify: `app_gif/test/widget_test.dart`
- Test: `app_gif/test/device_asset_delete_test.dart`

**Interfaces:**
- Consumes: Task 1 tombstone policy and Task 4 MethodChannel methods.
- Produces: crash-safe delete ordering, one-at-a-time reconciliation, and `deviceKey` persistence in `HistoryEntry`.

- [ ] **Step 1: Add failing orchestration tests**

Cover these observable outcomes with a mocked MethodChannel and real widget state:

```text
savePendingDeviceDeletes occurs before deleteAssetFiles and saveHistory
offline deletion removes one visible entry while retaining one tombstone
connection transition invokes getDeviceIdentity and deleteDeviceAsset
different device key leaves tombstone pending
new offline import has null deviceId/deviceKey
switchToAsset receives both deviceId and crc32
```

- [ ] **Step 2: Run RED Flutter tests**

Run: `flutter test test/device_asset_delete_test.dart test/widget_test.dart`

Expected: new orchestration assertions fail.

- [ ] **Step 3: Load and save the queue and device key**

Add `_pendingDeviceDeletes`, `_pendingDeletesLoaded`, `_deleteSyncInFlight`, and `_connectedDeviceKey`. Load history and queue before allowing reconciliation. Extend `HistoryEntry.fromMap`, `toMap`, and `copyWith` with nullable `deviceKey`.

- [ ] **Step 4: Implement crash-safe local deletion**

For assigned user material, persist the tombstone first. If persistence throws, show an error and leave history/local files unchanged. Otherwise delete local files, remove one history item, save history, and start reconciliation when connected.

- [ ] **Step 5: Implement serialized reconciliation and guarded switch**

Query identity once per connection. Flush matching tombstones; use `STAT` before binding a legacy null-device tombstone. Treat deleted/missing/stale as terminal. Retain transport failures. Pass history CRC to `switchToAsset`, and save both returned `assignedId` and `deviceKey` after upload.

- [ ] **Step 6: Run GREEN tests and analyzer**

Run: `dart format lib test && flutter test test/device_asset_delete_test.dart test/transcode_policy_test.dart test/widget_test.dart && flutter analyze`

Expected: targeted tests pass; analyzer has no new errors.

### Task 6: Release Build and End-to-End Verification

**Files:**
- Output: `app_gif/build/app/outputs/flutter-apk/app-release.apk`
- Output: `ESP32-S3-LCD-2.8C-Test/plus-idf/esp32-p4c5-dotloop/build/esp32-p4c5-dotloop.bin`

**Interfaces:**
- Consumes all prior tasks.
- Produces verified APK/P4 firmware and an exact manual verification report.

- [ ] **Step 1: Run all focused regression suites**

Run:

```powershell
python -m pytest tools/test_device_asset_delete_protocol.py tools/test_tcp_bench_protocol.py -q
Set-Location app_gif
flutter test test/device_asset_delete_test.dart test/transcode_policy_test.dart test/widget_test.dart test/android_wifi_upload_static_test.dart test/ios_native_static_test.dart
```

- [ ] **Step 2: Build release artifacts**

Run `idf.py build` in the P4 project and `flutter build apk --release` in `app_gif`.

- [ ] **Step 3: Flash final P4 firmware and verify boot**

Flash COM13, capture boot output, and confirm SD mount, user/factory scan, TCP server, Wi-Fi connection, and absence of new errors.

- [ ] **Step 4: Execute hardware scenarios**

Verify online deletion, reboot persistence, offline queue replay, wrong-device filtering where available, active-user fallback, factory rejection, and old-ID/new-CRC replay safety. Never use an existing user asset for destructive protocol tests; upload a disposable package first.

- [ ] **Step 5: Report artifacts and residual risks**

Report exact APK/P4 paths and hashes, tests run, protocol logs, and any manual-only scenario that could not be exercised.
