# Factory Animation Pack Design

## Goal

Add an official factory animation library so users can install new factory animations from the app without removing the SD card. Installed animations must behave like built-in factory animations, including large previews, grid previews, and full special transitions between every official factory animation.

## Current Context

The app currently bundles factory preview assets under `app_gif/assets/factory_previews`. The ESP32 scans SD card folders:

- `/sdcard/first_half`
- `/sdcard/second_half`
- `/sdcard/third_half`
- `/sdcard/user`

The existing app-to-device upload path handles a single user `.eb4` package and writes it under `/sdcard/user`. It is not enough for installing an official animation because official animation packs contain multiple `.eb4` files across several SD card folders.

## Package Format

Official animation packs are uploaded to the server as zip files. Each zip must contain:

```text
factory-pack-F019-v1.zip
  manifest.json
  preview/
    F019.png
    F019_dial.mp4
    F001_to_F019.mp4
    F019_to_F001.mp4
  device/
    first_half/F019.eb4
    second_half/F019.eb4
    third_half/F001_F019.eb4
    third_half/F019_F001.eb4
    third_half/F002_F019.eb4
    third_half/F019_F002.eb4
```

The `device/` folder is the source of truth for what will be installed to the ESP32 SD card. The `preview/` folder is only for the app and admin UI.

`manifest.json` fields:

```json
{
  "packId": "factory-F019",
  "animationId": "F019",
  "version": "1.0.0",
  "title": "F019",
  "description": "Official factory animation F019",
  "minFirmwareVersion": "0.1.4",
  "replaces": [],
  "deviceBytes": 12345678,
  "preview": {
    "thumbnail": "preview/F019.png",
    "dialVideo": "preview/F019_dial.mp4"
  },
  "transitions": {
    "F001": "preview/F019_to_F001.mp4"
  },
  "deviceFiles": [
    {
      "path": "first_half/F019.eb4",
      "size": 1234,
      "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    }
  ]
}
```

For this project, each new official animation pack should include complete mutual transitions between the new animation and all currently published official animations. That means both `old_new` and `new_old` third-half files must be included when applicable.

## Server

The backend gets a new admin section: "Official Animation Packs".

Admin capabilities:

- Upload a zip package.
- Validate that `manifest.json` exists.
- Validate package id, animation id, semantic version, device file paths, file sizes, and SHA-256 hashes.
- Reject unsafe paths such as `../x`, absolute paths, or files outside `preview/` and `device/`.
- Show preview thumbnail/video in the admin page.
- Mark one version of a pack as latest.
- Delete old pack versions and their zip files.

Public app endpoints:

- `GET /api/factory-packs`
  Returns the latest visible official animation packs with metadata, preview URLs, size, hash, and compatibility info.

- `GET /api/factory-packs/:packId`
  Returns one pack manifest.

- `GET /downloads/factory-packs/<filename>.zip`
  Downloads the zip through Nginx static serving with range support.

Admin endpoints:

- `POST /api/admin/factory-packs`
  Upload and publish a zip package.

- `GET /api/admin/factory-packs`
  List all pack versions.

- `DELETE /api/admin/factory-packs/:packId/:version`
  Delete a package version.

Server storage:

```text
server/data/factory_packs.json
server/data/downloads/factory-packs/<packId>_<version>.zip
server/data/factory-previews/<packId>/<version>/<preview-file>
```

## App

The app gets an "Official Animation Library" surface near the existing factory animation grid.

App behavior:

- Load pack list from `/api/factory-packs`.
- Show preview thumbnail/video, title, version, size, and status.
- Status values: `installed`, `notInstalled`, `updateAvailable`, `incompatible`, `notEnoughSpace`.
- Download zip to app cache when the user taps install.
- Verify zip SHA-256 before opening.
- Read `manifest.json` and verify every `deviceFiles` entry.
- Ask ESP32 for SD free space before installation.
- If free space is insufficient, show a message telling the user to delete installed official animation packs or user materials.
- Send only files under `device/` to ESP32.
- Persist installed pack metadata locally so the app can show installed/update status.

The app should not upload original source MP4 files to the ESP32. It only sends encoded `.eb4` files from the package.

## ESP32

The ESP32 gets a new batch installation protocol separate from the existing single user asset upload.

Required device capabilities:

- Report storage info: total bytes, free bytes, SD available.
- Begin official pack install with pack id, version, file count, total device bytes, and expected manifest hash.
- Receive each device file with relative target path, size, and SHA-256.
- Write incoming files to a temporary folder first.
- Commit only after every file has been received and verified.
- Abort and clean temporary files on failure.
- Refresh the animation manager after commit.
- Delete an installed official pack by manifest.

Temporary install layout:

```text
/sdcard/.install/factory-F019/
  manifest.json
  first_half/F019.eb4
  second_half/F019.eb4
  third_half/F001_F019.eb4
```

Commit moves files into:

```text
/sdcard/first_half/F019.eb4
/sdcard/second_half/F019.eb4
/sdcard/third_half/F001_F019.eb4
```

The commit should be all-or-cleanup from the user's point of view. If the device loses power during install, the next boot should remove stale `/sdcard/.install/*` folders before scanning animations.

## Protocol

Preferred first implementation: HTTP endpoints on the ESP32. It is easier to debug than extending the current raw TCP upload format.

ESP32 endpoints:

- `GET /storage`
  Returns JSON with `sdAvailable`, `totalBytes`, `freeBytes`.

- `GET /factory-packs/installed`
  Returns installed pack ids and versions.

- `POST /factory-packs/install/begin`
  Body includes pack id, version, file count, total bytes, and manifest hash.

- `PUT /factory-packs/install/file?path=<relativePath>`
  Streams one `.eb4` file. Headers include size and SHA-256.

- `POST /factory-packs/install/commit`
  Verifies all files, moves them to SD folders, saves installed manifest, rescans animations.

- `POST /factory-packs/install/abort`
  Removes temporary install files.

- `DELETE /factory-packs/:packId`
  Removes files listed in the installed manifest and rescans animations.

Path allowlist:

- `first_half/*.eb4`
- `second_half/*.eb4`
- `third_half/*.eb4`

No other target paths are accepted.

## Data Flow

Install flow:

1. App fetches official pack list from server.
2. User taps install.
3. App downloads the zip and verifies server SHA-256.
4. App reads the package manifest and sums `deviceBytes`.
5. App calls `GET /storage` on ESP32.
6. If space is enough, app calls install begin.
7. App uploads each `device/` file.
8. ESP32 verifies each file into temporary install storage.
9. App calls commit.
10. ESP32 moves files, saves installed manifest, rescans animations.
11. App marks the package as installed.

Delete flow:

1. App shows installed packs.
2. User taps delete.
3. App calls ESP32 delete endpoint.
4. ESP32 deletes files listed in the installed pack manifest.
5. ESP32 rescans animations.
6. App updates local installed state.

## Error Handling

- Server rejects invalid zip packages and unsafe paths.
- App refuses install if package hash or any device file hash does not match.
- App refuses install if ESP32 firmware is below `minFirmwareVersion`.
- App refuses install if SD free space is less than `deviceBytes` plus a safety margin.
- ESP32 refuses paths outside the allowlist.
- ESP32 cleans temporary install files on abort, commit failure, or boot.
- App can retry download and retry installation from the beginning.

## Compatibility

The feature requires a firmware update because current firmware does not expose batch install endpoints. The app should hide or disable official animation install for older firmware versions and tell the user to update firmware first.

The existing user custom material audit flow remains separate and unchanged.

## Testing

Server tests:

- Upload valid pack and list it publicly.
- Reject unsafe zip paths.
- Reject missing manifest or invalid hashes.
- Delete old pack version and file.

App tests:

- Parse pack list and display install state.
- Refuse install when storage is insufficient.
- Verify package hash before upload.
- Send only `device/` files.

ESP32 tests/manual checks:

- `GET /storage` reports SD free space.
- Install writes to temporary folder first.
- Commit moves files to SD folders and rescans.
- Boot cleanup removes stale install folders.
- Delete pack removes listed files and rescans.

## First Implementation Scope

The first implementation should include:

- Server admin upload/list/delete for official packs.
- Public pack list and static zip downloads.
- App official animation library UI.
- App zip download, hash validation, space check, installation, and delete.
- ESP32 HTTP batch install/delete endpoints.
- Installed pack manifest storage on ESP32.

Out of scope for the first implementation:

- Delta updates inside a zip.
- CDN upload automation.
- Generating `.eb4` files from MP4 on the server.
- User-created official animation submission.
