# Device Asset Delete Synchronization Design

Date: 2026-08-17

## Goal

Deleting a user-imported material in the app must eventually remove the matching file from the original DotLoop device, including when the deletion is performed while the app or device is offline.

The implementation must never:

- delete factory assets;
- send a deletion to a different physical device;
- delete a newer asset that reused an old device slot such as `U006`;
- switch to stale `U006` content when the app is referring to a newly imported asset;
- unlink a file while the display player is still reading it.

## Current Behavior and Root Cause

`_deleteHistoryEntry` deletes native app cache files and removes the `HistoryEntry`. It does not send a command to the device or retain a deletion intent. The P4 TCP server supports upload, `SWITCH`, and `RANDOM`, but has no identity, asset verification, or delete command.

User asset IDs are allocated from files currently present on the SD card. A deleted highest-numbered ID can therefore be reused. An ID such as `U006` is a location, not a globally unique material identity.

## Chosen Approach

Use a durable deletion tombstone containing all three identity dimensions:

- stable physical device key;
- device asset ID, for example `U006`;
- full package CRC32, identifying the exact bytes that may be deleted.

The device key prevents cross-device deletion. The CRC prevents a delayed or replayed tombstone from deleting newer content that reused the same `Uxxx` ID.

Changing the allocator to never reuse IDs is not sufficient: IDs are finite, legacy data already exists, and replay safety would still depend on mutable allocation state.

## Data Model

### History Entry

Add `deviceKey` to `HistoryEntry`. `deviceId` continues to mean the device-local asset slot (`Uxxx`). New imports have neither value until a successful upload.

### Pending Deletion

Persist a bounded list of tombstones independently from visible history:

```text
PendingDeviceDeletion {
  operationKey: deviceKey + deviceAssetId + crc32
  deviceKey: stable P4 identity, nullable only for legacy migration
  deviceAssetId: Uxxx
  crc32: full uploaded package CRC32
  createdAt: epoch milliseconds
}
```

Duplicate tombstones with the same operation key collapse into one. Factory IDs are rejected before persistence.

The queue is stored in the existing platform preferences on Android and iOS. It is not derived from history, because the history entry is intentionally removed immediately from the UI.

## Stable Device Identity

The P4 derives a stable key from its base efuse MAC, independent of Wi-Fi IP, AP/STA mode, or the C5 network MAC. The wire representation is a fixed ASCII value such as `P4-AABBCCDDEEFF`.

The app queries this key after a connection is established and records it with every successful upload. A deletion is automatically sent only when its non-null `deviceKey` matches the connected device.

Legacy history entries have `deviceId` but no `deviceKey`. They remain unbound until the user explicitly connects a device and the device confirms that both the ID and CRC match. Only then may the app bind the entry or tombstone to that device. A legacy tombstone is never blindly sent to an arbitrary connected device.

## TCP Protocol

All commands remain one-line ASCII requests on port 3333. Existing clients remain compatible.

### Identity

```text
IDENTITY\n
OK DEVICE P4-AABBCCDDEEFF\n
```

### Asset Status

```text
STAT U006 89abcdef\n
OK MATCH U006\n
OK MISSING U006\n
OK STALE U006\n
ERR FORBIDDEN\n
ERR INVALID\n
```

`STALE` means the slot exists but contains different bytes. For an old deletion intent, both `MISSING` and `STALE` are terminal success because the exact old material is no longer present.

### Delete

```text
DELETE U006 89abcdef\n
OK DELETED U006\n
OK MISSING U006\n
OK STALE U006\n
ERR FORBIDDEN\n
ERR INVALID\n
ERR BUSY\n
```

Only the exact pattern `U` followed by three decimal digits is accepted. `Fxxx`, paths, separators, whitespace injection, and unknown forms are rejected before any filesystem access.

### Guarded Switch

```text
SWITCH U006 89abcdef\n
OK U006\n
NEED_UPLOAD U006\n
```

The CRC argument is optional for backward compatibility. Updated apps always send it for user history. A missing file or CRC mismatch returns `NEED_UPLOAD` instead of playing stale content.

## Device Metadata

After a successful upload is assigned an ID, the firmware atomically writes a small sidecar containing the transferred package size and CRC32 next to the user file. `STAT`, guarded `SWITCH`, and `DELETE` use the sidecar for constant-time verification.

For legacy files without a sidecar, the firmware may compute the full-file CRC once while the display is safely paused, then atomically create the sidecar. This slow path applies only to legacy material and is never required again for that file.

Sidecar writes use temporary-file plus rename. Deleting a user material removes both the `.eb4` package and its sidecar.

## App Deletion Flow

The order is deliberately crash-safe:

1. Validate that the entry is a user material. Factory catalog entries have no delete path.
2. If the entry has a device asset ID, construct and persist the tombstone before changing visible history.
3. Delete local package and preview files.
4. Remove the visible history entry and persist history.
5. If the matching device is online, start a queue flush without blocking local UI removal.

If tombstone persistence fails, the history entry remains visible and the app reports the failure. This prevents a deletion intent from being lost.

## Queue Reconciliation

Only one flush runs at a time. Reconciliation runs:

- after app startup data has loaded and a device connection becomes ready;
- when a connection changes from offline to online;
- immediately after an online deletion;
- before a user asset switch or upload uses the device command channel.

For each tombstone:

1. Query `IDENTITY`.
2. Skip tombstones belonging to other devices.
3. For a legacy unbound tombstone, run `STAT`; bind only on `MATCH` after an explicit user connection.
4. Send `DELETE`.
5. Remove and persist the tombstone after `DELETED`, `MISSING`, or `STALE`.
6. Retain it on transport failure, timeout, `BUSY`, or device restart and retry on the next reconciliation.

Commands are serialized with upload and switch operations. A newly imported offline material has no `deviceId`, so it can never be treated as the old `U006`. Before switching an existing uploaded material, the app uses guarded `SWITCH` with its CRC. Before uploading a new material, pending deletions for that device get one reconciliation attempt; upload then receives the ID actually assigned by the device.

If a crash happens after device deletion but before queue persistence is updated, replay is safe: `MISSING` clears the tombstone. If `U006` has already been reused, CRC mismatch yields `STALE`, so the new file is preserved.

## Safe Device Deletion

The firmware checks ID syntax and content identity before mutation. For an exact match:

1. Pause the display player and wait until its asset handle is released.
2. If the target is active or pending, clear that state and choose an available factory animation as the fallback. If no factory animation exists, choose another user animation; otherwise leave the upload/static screen visible.
3. Remove the user package and sidecar.
4. Rescan the animation manager and update the persisted last-played ID so reboot cannot resume the deleted file.
5. Resume playback and return `OK DELETED`.

The filesystem path is constructed only after strict `Uxxx` validation. No client-provided path is used.

## Error Handling and User Experience

Local deletion is immediate after durable queueing. A temporary offline state does not show an error because synchronization is expected later.

Transport errors keep the tombstone. Permanent protocol errors are logged and surfaced as a concise synchronization warning; they do not restore an already deleted local history entry. Queue size is bounded and duplicate operations coalesce.

The app does not expose a new management screen in this change. Existing connection/status text may briefly report that device deletions are synchronizing.

## Testing

### Pure App Policy Tests

- only `Uxxx` entries with a device assignment create tombstones;
- duplicate tombstones coalesce;
- queue filtering requires the matching device key;
- `DELETED`, `MISSING`, and `STALE` clear a tombstone;
- timeout, `BUSY`, and disconnect retain it;
- a new offline import never inherits the deleted entry's `deviceId` or `deviceKey`;
- guarded switching requires matching CRC.

### Native Bridge Tests

- Android and iOS persist and reload tombstones;
- identity, status, guarded switch, and delete responses are parsed consistently;
- connection transition triggers one serialized reconciliation;
- local history is not removed when queue persistence fails.

### Firmware Tests

- factory IDs and malformed IDs are rejected;
- a matching CRC deletes package and sidecar;
- mismatched CRC returns `STALE` without mutation;
- missing file is idempotent;
- legacy file CRC creates metadata once;
- deleting the active user animation safely selects a fallback;
- reboot does not resume a deleted user asset;
- replay after ID reuse preserves the newer file;
- legacy `SWITCH U006` remains compatible while guarded switch rejects stale content.

### End-to-End Hardware Checks

- online delete removes the SD file and survives reboot;
- offline delete disappears from the app immediately and removes the file after reconnect;
- delete old `U006`, import a new material offline, reconnect, and select it without ever displaying old `U006`;
- disconnect during delete, reconnect, and observe idempotent completion;
- connecting a different P4 does not consume another device's queue;
- factory assets remain present and playable.

## Non-Goals

- Remote deletion from the moderation/backend service.
- Automatic deletion of factory catalog assets.
- A cloud-synchronized deletion queue shared by multiple phones.
- Reclaiming or renumbering all existing `Uxxx` files.
