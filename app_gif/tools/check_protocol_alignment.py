from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parent

firmware_protocol = (
    REPO / "ESP32-S3-LCD-2.8C-Test" / "main" / "Badge" / "BadgeProtocol.h"
).read_text(encoding="utf-8")
flutter_main = (ROOT / "lib" / "main.dart").read_text(encoding="utf-8")
android_main = (
    ROOT / "android" / "app" / "src" / "main" / "kotlin" / "com" / "example" / "app_gif" / "MainActivity.kt"
).read_text(encoding="utf-8")
ios_delegate = (ROOT / "ios" / "Runner" / "AppDelegate.swift").read_text(encoding="utf-8")

assert "#define BADGE_EBAJ_MIN_FPS 25u" in firmware_protocol, "firmware protocol must reject packages below 25fps"
assert "#define BADGE_EBAJ_DEFAULT_FPS 25u" in firmware_protocol, "firmware protocol must default to 25fps"
assert "#define BADGE_EBAJ_MAX_FPS 30u" in firmware_protocol, "firmware protocol must accept up to 30fps"
assert "'fps': 25" in flutter_main, "Flutter must request the default 25fps package"
assert "private const val DEVICE_FPS = 25" in android_main, "Android encoder must create 25fps EBAJ4 packages"
assert "static let deviceFps = 25" in ios_delegate, "iOS encoder must create 25fps EBAJ4 packages"
assert "preparePackageForUpload(file)" in android_main, "Android upload must validate and checksum the EBAJ4 package before sending"
assert "fps < MIN_DEVICE_FPS || fps > MAX_DEVICE_FPS" in android_main, "Android upload validation must reject unsupported fps packages"
assert "packageSize != packageLength" in android_main, "Android upload validation must reject stale package_size headers"
assert "isValidStreamSize(streamWidth, streamHeight)" in android_main, "Android upload validation must mirror firmware stream sizes"
assert "private const val MAX_DEVICE_FPS = 30" in android_main, "Android upload validation must allow up to 30fps packages"
assert "QUALITY_STREAM_BYTES_PER_SECOND = 7 * 512 * 1024" in android_main, "Android quality budget should preserve stable 25fps SD playback"
assert "actualQualityBytesPerSecond(selected)" in android_main, "Android encoder must verify actual package throughput after crop encoding"
assert "candidateStreamResolutions(selectedStreamSize)" in android_main, "Android encoder must retry lower stream sizes only when actual throughput exceeds the 3.5MB/s target"
assert "UPLOAD_PROGRESS_STEP_BYTES = 512 * 1024L" in android_main, "Android upload progress should be coalesced to avoid main-thread churn during slow uploads"
assert "preparePackageForUpload(fileURL:" in ios_delegate, "iOS upload must validate and checksum the EBAJ4 package before sending"
assert "fps < BadgeConstants.minDeviceFps || fps > BadgeConstants.maxDeviceFps" in ios_delegate, "iOS upload validation must reject unsupported fps packages"
assert "packageSize != packageLength" in ios_delegate, "iOS upload validation must reject stale package_size headers"
assert "isValidStreamSize(streamWidth, streamHeight)" in ios_delegate, "iOS upload validation must mirror firmware stream sizes"
assert "maxDeviceFps = 30" in ios_delegate, "iOS upload validation must allow up to 30fps packages"
assert "qualityStreamBytesPerSecond = 7 * 512 * 1024" in ios_delegate, "iOS quality budget should preserve stable 25fps SD playback"
assert "actualQualityBytesPerSecond(selected)" in ios_delegate, "iOS encoder must verify actual package throughput after crop encoding"
assert "candidateStreamResolutions(selectedStreamSize)" in ios_delegate, "iOS encoder must retry lower stream sizes only when actual throughput exceeds the 3.5MB/s target"
assert "uploadProgressStepBytes = 512 * 1024" in ios_delegate, "iOS upload progress should be coalesced to avoid main-thread churn during slow uploads"
assert "DevicePreview(" not in flutter_main, "release/debug app must not force DevicePreview; it causes heavy UI work"
assert "device_preview" not in (ROOT / "pubspec.yaml").read_text(encoding="utf-8"), "DevicePreview dependency should stay out of runtime builds"
assert "WidgetsBindingObserver" in flutter_main, "Flutter app must observe lifecycle to pause previews in background"

print("app/device protocol alignment checks passed")
