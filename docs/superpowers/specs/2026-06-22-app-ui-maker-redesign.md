# App UI and Maker Redesign

## Goal

Redesign the Flutter app so the main screen matches the reference app's operating model: the center screen is only for previewing, selecting, uploading, and deleting saved animations. Device connection/control moves into the left bottom device entry. Asset creation moves into the right bottom maker entry.

The saved maker output is added to the app library only. It must not upload automatically after saving.

## Current Context

The app is Android-first Flutter. `app_gif/lib/main.dart` currently contains three bottom pages:

- device connection
- material import/upload/history
- device control

Android `MainActivity.kt` owns media picking, GIF/image/video conversion, history persistence, Wi-Fi connection, TCP/HTTP upload, and brightness control through the `esp_baji/native` MethodChannel.

The current native encoder renders all source media with a fixed centered cover crop. Flutter passes an FPS value, but the Kotlin encoder currently uses a fixed target internally. The new maker crop UI must pass crop and zoom parameters into native encoding so the saved asset matches the preview.

## Approved Interaction

Keep the three-entry bottom bar, but change the roles:

- Left: Device
- Center: Main display library
- Right: Maker

The center main screen is the primary screen. It shows a large circular preview for the selected/saved animation and a grid of saved animations below it.

Tapping a saved animation uploads it to the ESP badge and switches the display.

Long pressing a saved animation opens a delete confirmation. Delete removes the entry from the app history and clears selection if that entry is selected.

The main screen must not show import, scan, disconnect, or brightness controls.

## Device Entry

The left bottom device entry opens a device panel instead of keeping connection and control split across separate pages. The panel contains:

- current connection state
- connected address/device name when available
- SD availability state when reported
- scan button and scan progress
- discovered ESP-BAJI devices
- connect and disconnect controls
- brightness slider

Brightness remains disabled while disconnected.

If the user taps a saved animation while disconnected, the app should show a short failure message and direct the user to the device panel.

## Maker Entry

The right bottom maker entry opens the maker screen. The maker supports:

- importing image, GIF, or video
- circular preview matching the badge display
- drag to move the source media inside the circular viewport
- pinch or slider zoom
- reset crop
- save

Save calls native `prepareAsset` with the selected media, requested FPS, package budget, and crop transform. When native preparation succeeds, the result is inserted at the top of the saved animation library and persisted through the existing history mechanism. Save does not upload.

The maker preview and the native encoder must use the same crop model:

- `scale`: zoom multiplier relative to cover-fit
- `offsetX`: normalized horizontal offset in output-view coordinates
- `offsetY`: normalized vertical offset in output-view coordinates

Native rendering applies these values when drawing image, GIF, and video frames before indexed encoding and preview PNG generation.

## Native Encoding Changes

Extend the MethodChannel `prepareAsset` payload with:

- `cropScale`
- `cropOffsetX`
- `cropOffsetY`

Add a small native data object for the crop transform and thread it through:

- preview generation
- still image rendering
- GIF frame rendering
- video frame rendering
- stream-resolution sampling and final encoding

The encoder should use the requested FPS rather than ignoring it. The first app default can be 25 FPS, because this matches the current hardware playback target better than forcing 30 before the firmware and storage path are ready.

Existing package format and upload protocol remain unchanged.

## Visual Direction

Use the reference app as the interaction model:

- black background
- restrained top status area
- large circular preview
- compact saved-animation grid below
- bottom navigation remains visible
- icon-first controls

Avoid large explanatory text. Use short labels only where needed for operation.

## Error Handling

Media import permission or decode errors show a short snackbar and keep the user in maker.

Prepare progress is shown in maker while saving. The save button is disabled while preparing or uploading.

Upload progress is shown on the main screen while a saved animation is being sent. During upload, repeated taps are ignored.

If a history entry points to a missing asset file, upload should fail with a clear message and keep the entry until the user deletes it.

## Verification

Run Flutter analysis after implementation.

Run existing app tests if the local Flutter toolchain is available.

Manually verify these flows on Android:

- open app and see center main library first
- device panel scans, connects, shows SD state, controls brightness
- maker imports a video or GIF
- drag and zoom changes the circular preview
- save returns the generated asset to the main library without upload
- tap saved asset uploads
- long press saved asset deletes after confirmation

