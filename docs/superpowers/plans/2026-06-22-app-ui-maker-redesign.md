# App UI Maker Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rework the Android-first Flutter app so the center page is a saved-animation display library, the left page is combined device connection/control, and the right page is a maker that saves cropped/zoomed assets without uploading.

**Architecture:** Keep the current MethodChannel and native Android encoder. Refactor Flutter state so selected media is edited in the maker page and saved assets drive the main page. Extend Kotlin `prepareAsset` with crop transform and real requested FPS handling.

**Tech Stack:** Flutter/Dart Material 3, Android Kotlin, Android `Movie`, `Bitmap`, `MediaMetadataRetriever`, existing EBAJ4 encoder and TCP/HTTP upload protocol.

## Global Constraints

- Keep the three-entry bottom bar: left Device, center Main display library, right Maker.
- Main screen must not show import, scan, disconnect, or brightness controls.
- Saving a maker result adds it to history only and must not auto-upload.
- Tapping a saved animation uploads it and switches the display.
- Long pressing a saved animation asks before deleting it.
- Maker preview and native encoding must share `cropScale`, `cropOffsetX`, and `cropOffsetY`.
- Existing package format and upload protocol remain unchanged.
- Default maker FPS is 25 unless the UI later exposes a different choice.

---

### Task 1: Flutter State and Main Library Page

**Files:**
- Modify: `app_gif/lib/main.dart`

**Interfaces:**
- Produces: `_DisplayLibraryPage`, `_HistoryGridTile`, `_confirmDeleteHistoryEntry(HistoryEntry entry)`, `_selectHistoryEntry(HistoryEntry entry)`.
- Consumes: existing `_history`, `_asset`, `_uploadHistoryEntry`, `_deleteHistoryEntry`.

- [ ] Replace the center page with `_DisplayLibraryPage`.
- [ ] Keep `_pageIndex = 1` as the startup page.
- [ ] Make saved asset taps call `_uploadHistoryEntry`.
- [ ] Make saved asset long press call a delete confirmation dialog before `_deleteHistoryEntry`.
- [ ] Show upload progress on the center page while `_uploading` is true.

### Task 2: Combined Device Page

**Files:**
- Modify: `app_gif/lib/main.dart`

**Interfaces:**
- Produces: `_DevicePage`.
- Consumes: existing scan/connect/disconnect/brightness state and callbacks.

- [ ] Replace `_ConnectionPage` and `_ControlPage` usage with one `_DevicePage` on the left bottom entry.
- [ ] Show connection state, SD state, scan button, device list, disconnect button, and brightness slider.
- [ ] Keep brightness disabled when disconnected.

### Task 3: Maker Page and Crop Preview

**Files:**
- Modify: `app_gif/lib/main.dart`

**Interfaces:**
- Produces: `_MakerPage`, `_CropPreview`, `_CropTransform`.
- Consumes: `_pickMedia`, `_prepareSelectedMedia`, `_preparing`, `_prepareProgress`, `_media`.

- [ ] Split import from prepare: picking media only sets `_media` and resets crop.
- [ ] Add `_saveMakerAsset()` to call native prepare with crop params and insert history.
- [ ] Add drag and pinch crop controls using `GestureDetector`.
- [ ] Add zoom slider and reset action.
- [ ] Set default requested FPS to 25.

### Task 4: Native Crop and FPS Support

**Files:**
- Modify: `app_gif/android/app/src/main/kotlin/com/example/app_gif/MainActivity.kt`

**Interfaces:**
- Produces: `CropTransform`, `frameDelayMs(fps: Int)`, crop-aware `renderBitmapFrame`, `renderMovieFrame`, `renderVideoFrame`.
- Consumes: MethodChannel args `cropScale`, `cropOffsetX`, `cropOffsetY`.

- [ ] Read crop args in `prepareAsset`.
- [ ] Pass `CropTransform` into `prepareAsset`, `buildPreviewBytes`, and `EbajEncoder.encode`.
- [ ] Use requested FPS to compute frame delay instead of fixed `TARGET_FPS` and `FRAME_DELAY_MS`.
- [ ] Apply crop transform to still image, GIF, video sampling, and final encoding.
- [ ] Keep package format and upload protocol unchanged.

### Task 5: Verification

**Files:**
- Test: `app_gif/test/native_encoder_static_test.dart`

**Commands:**
- Run: `dart format app_gif/lib/main.dart app_gif/android/app/src/main/kotlin/com/example/app_gif/MainActivity.kt`
- Run: `flutter analyze`
- Run: `flutter test`

**Expected:**
- Dart format completes.
- Flutter analysis reports no new errors from edited Dart code.
- Existing tests pass or any toolchain failure is reported with the exact reason.

