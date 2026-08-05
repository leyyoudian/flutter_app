# Factory Animation Incremental Sync Design

## Goal

Build a server-managed official animation catalog that keeps the Android app,
iOS app, and ESP32-S3 SD card synchronized without requiring a new app build or
manual SD card copy for every animation release.

The server is the source of truth. Each client checks once per process start or
device boot, downloads only changed files, verifies them, and applies additions,
replacements, and allowed deletions transactionally.

## Scope

This feature includes:

- Server-side official animation catalog and administration UI.
- Single-item and multi-item ZIP import with staged preview and selection.
- Public catalog and file download APIs.
- ESP32-S3 direct background synchronization after Wi-Fi becomes stable.
- Android and iOS app synchronization when the app starts.
- Dynamic app previews loaded from downloaded files.
- New loop-style official animations F022 and F023.
- Add, replace, and delete propagation.
- Per-file SHA-256 validation and transactional updates.

User-created and reviewed materials remain a separate feature and are not part
of the official animation catalog.

## Protected Baseline

F001 through F021 are protected baseline animations.

- The server catalog includes them so replacements can be published.
- They may be replaced by a newer revision.
- They may not be deleted in the admin UI or through the admin API.
- A malformed or empty remote catalog must never remove them from the app or SD
  card.

Animations added after the baseline are server-managed. The server may delete
them, and clients remove them only if their local installation metadata proves
that they were installed by this catalog.

## Animation Types

Each catalog item declares one of three types:

- `split`: a normal official animation with `first_half` and optionally
  `second_half`; the first half freezes on its last frame and the second half
  plays when leaving it.
- `loop`: a complete animation that loops continuously and switches with the
  same direct logic as a user animation.
- `transition`: a directional special transition between two official
  animations. Existing F006/F007 transitions use this type.

F022 and F023 are `loop` animations. They appear in the official factory grid
but never use first-half freeze, second-half exit, or a special transition.

## Source And Generated Layout

The encoder uses explicit source directories so a loop animation is not
misidentified as a transition:

```text
animation_comd/
  first_half/
  second_half/
  third_half/
  factory_loop/
    22.mp4
    23.mp4
```

Generated ESP32 files:

```text
animation_sd/
  first_half/F001.eb4
  second_half/F001.eb4
  third_half/F007.eb4
  factory_loop/F022.eb4
  factory_loop/F023.eb4
```

Generated app preview files:

```text
app_gif/assets/factory_previews/
  F022.png
  F022_loop.mp4
  F023.png
  F023_loop.mp4
```

The encoder also creates an import ZIP containing one or more complete catalog
candidates. The server never runs FFmpeg and never generates `.eb4` files.

## Import ZIP Format

A ZIP may contain one or many candidates:

```text
factory-import.zip
  import.json
  items/
    F022/
      manifest.json
      app/F022.png
      app/F022_loop.mp4
      device/factory_loop/F022.eb4
    F023/
      manifest.json
      app/F023.png
      app/F023_loop.mp4
      device/factory_loop/F023.eb4
```

`import.json` lists candidate manifest paths. A single-item ZIP uses the same
format with one entry, avoiding two separate parsers.

Each candidate `manifest.json` contains:

```json
{
  "id": "F022",
  "title": "F022",
  "type": "loop",
  "protected": false,
  "minFirmwareVersion": "0.1.44",
  "appFiles": {
    "thumbnail": "app/F022.png",
    "loopVideo": "app/F022_loop.mp4"
  },
  "deviceFiles": [
    {
      "path": "factory_loop/F022.eb4",
      "source": "device/factory_loop/F022.eb4"
    }
  ]
}
```

The server calculates file sizes and SHA-256 values itself. Hashes supplied in
the ZIP are treated as optional assertions, not trusted metadata.

## Server Catalog

The published catalog has a monotonically increasing `catalogRevision` and a
stable schema version:

```json
{
  "schemaVersion": 1,
  "catalogRevision": 12,
  "publishedAt": "2026-08-05T12:00:00.000Z",
  "items": [
    {
      "id": "F022",
      "revision": 1,
      "type": "loop",
      "protected": false,
      "minFirmwareVersion": "0.1.44",
      "appFiles": {
        "thumbnail": {
          "url": "/downloads/factory/F022/1/F022.png",
          "size": 1234,
          "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        },
        "loopVideo": {
          "url": "/downloads/factory/F022/1/F022_loop.mp4",
          "size": 5678,
          "sha256": "1123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        }
      },
      "deviceFiles": [
        {
          "path": "factory_loop/F022.eb4",
          "url": "/downloads/factory/F022/1/device/factory_loop/F022.eb4",
          "size": 123456,
          "sha256": "2123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        }
      ]
    }
  ]
}
```

The public endpoint is `GET /api/factory-catalog`. Downloads are immutable by
item revision and use long-lived cache headers. Publishing writes a complete
new catalog to a temporary file and atomically renames it.

## Server Administration

The admin page adds an Official Animations section with:

- ZIP drag-and-drop and file selection.
- Validation before staging.
- A previewable candidate list with checkboxes.
- Video playback for MP4 previews.
- Candidate ID, type, file count, size, and validation status.
- Publish selected candidates.
- Replace an existing item by publishing the same ID; this increments the item
  revision.
- Delete non-protected items.
- Download current and historical files.
- View publish time and revision history.

ZIP extraction rejects absolute paths, `..` traversal, symlinks, duplicate
normalized paths, unknown top-level directories, oversized entries, and files
not referenced by a candidate manifest. Staging has size and item-count limits.

Deleting an item publishes a new catalog without it. Historical files remain
available to administrators until explicitly removed from history, but public
clients receive only the current catalog.

## ESP32-S3 Synchronization

The firmware starts one factory synchronization task after STA has an IP and
the connection is stable. It runs at most once per boot. Firmware OTA and
factory synchronization do not run concurrently.

Local metadata is stored at:

```text
/sdcard/.factory/catalog.json
/sdcard/.factory/install.json
```

Temporary files are stored under:

```text
/sdcard/.factory_sync/<catalogRevision>/
```

Synchronization steps:

1. Fetch and validate the catalog within strict JSON and item limits.
2. Compare item revision, file size, and SHA-256 with the installed manifest.
3. Calculate bytes required for changed files plus a safety margin.
4. If space is insufficient, log the condition and keep the old installation.
5. Download changed files sequentially to the temporary directory.
6. Stream SHA-256 while downloading and reject any mismatch.
7. Validate every downloaded `.eb4` header before commit.
8. If the currently playing item is affected, switch to an unaffected protected
   baseline item.
9. Rename old files to a rollback directory, move verified files into place,
   and save the new installed manifest.
10. Delete only server-managed files absent from the new catalog.
11. Rescan the animation manager.
12. Remove rollback files only after the rescan succeeds.

Power loss before commit leaves the active files unchanged. Power loss during
commit is recovered on the next boot using a small transaction journal. Stale
download directories are removed before a new synchronization attempt.

ESP32 target paths are allowlisted:

- `first_half/FNNN.eb4`
- `second_half/FNNN.eb4`
- `third_half/*.eb4`
- `factory_loop/FNNN.eb4`

The server cannot write outside these directories.

The player scans `factory_loop` as official entries with
`BADGE_PLAY_MODE_LOOP`. Switching to or from these entries follows the existing
user-animation direct-switch branch.

## App Synchronization

The Flutter layer owns the catalog model and UI state. Native Android and iOS
code provide file download and durable storage primitives where platform code
is already used by this project.

On each app start:

1. Load the built-in F001-F021 manifest immediately so the UI is usable.
2. Fetch the server catalog once.
3. Compare downloaded revisions and hashes.
4. Download changed app files to a temporary revision directory.
5. Verify SHA-256 and media type.
6. Atomically publish the new local catalog.
7. Remove only downloaded files belonging to deleted non-protected items.
8. Refresh the grid without requiring device connection.

Automatic downloads are permitted on both Wi-Fi and mobile data. A failed
download keeps the previous preview and does not remove the item.

Dynamic thumbnails use file-backed images. Dynamic MP4 previews use file-backed
video sources. Asset-backed paths remain supported for the protected baseline
and as offline fallback.

The app does not relay official animation files to the ESP32 in this design;
both clients synchronize independently from the same catalog.

## Deletion And Replacement Rules

- F001-F021 cannot be deleted.
- A replacement increments the item revision and publishes immutable new URLs.
- Clients keep the previous revision until every required file for the new
  revision passes verification.
- A server deletion removes only items marked server-managed in local metadata.
- Unknown files placed manually on the SD card are never deleted.
- An empty, malformed, unauthenticated, or older catalog never triggers deletion.
- The server retains at least the current and previous item revisions so an
  administrator can roll back by republishing the previous revision.

## Error Handling

- Catalog fetch failure: keep current files and finish this boot/start without
  retrying continuously.
- Individual download failure: abort the transaction and keep the old revision.
- Hash or size mismatch: delete the temporary file and reject the update.
- Invalid `.eb4`: reject before commit.
- Insufficient SD or app storage: keep the old installation and report status.
- Power loss: recover or roll back using the transaction journal.
- Item currently playing: switch to a safe baseline before replacement/deletion.
- OTA active: factory synchronization waits or skips; it never competes for
  flash, network, SD, or display resources.

## Testing

Server tests cover valid single and multi-item imports, staged selection,
replacement revisioning, protected deletion rejection, unprotected deletion,
ZIP traversal rejection, generated hash metadata, atomic publication, preview
streaming, and immutable downloads.

Encoder tests cover F022/F023 loop discovery, output paths, generated previews,
candidate manifests, transition compatibility, and deterministic ZIP manifests.

Firmware static and host-side tests cover catalog parsing, path allowlists,
diff planning, protected baseline rules, transaction recovery, loop animation
classification, and once-per-boot scheduling. Hardware verification covers
download interruption, SD-full behavior, reset during commit, playback during
download, and F022/F023 switching.

App tests cover catalog parsing, built-in fallback, file-backed preview paths,
revision diffing, deletion protection, interrupted download recovery, mobile
data behavior, F022/F023 loop preview, and Android/iOS parity.

## Delivery Order

1. Extend the encoder and generate F022/F023 plus import ZIPs.
2. Add server catalog storage, import validation, APIs, and admin UI.
3. Add ESP32 transactional synchronization and loop animation support.
4. Add Flutter/Android/iOS catalog synchronization and dynamic previews.
5. Run cross-client integration tests against the local server.
6. Build the firmware and app artifacts.
7. Deploy the server only after local integration passes.
