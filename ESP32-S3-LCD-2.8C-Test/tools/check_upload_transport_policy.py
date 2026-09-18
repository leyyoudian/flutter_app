from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
wifi = (ROOT / "main/Wireless/WifiUpload.c").read_text(encoding="utf-8")
kotlin = (ROOT.parent / "app_gif/android/app/src/main/kotlin/com/example/app_gif/MainActivity.kt").read_text(encoding="utf-8")
dart = (ROOT.parent / "app_gif/lib/main.dart").read_text(encoding="utf-8")

# READY must only be sent after the SD session and upload buffers are owned.
tcp = wifi.index("static esp_err_t handle_tcp_upload(int sock)")
begin = wifi.index("ret = begin_upload_session(&session, total_size, expected_crc);", tcp)
ready = wifi.index("ret = send_tcp_ready(sock);", tcp)
alloc = wifi.index("ret = alloc_upload_session_buffers(&session);", tcp)
assert ready > begin, "TCP READY is sent before the session is created"
assert ready > alloc, "TCP READY is sent before upload buffers are allocated"

# Once the TCP stream has started, fallback HTTP would create a second SD writer.
assert "class TcpUploadException" in kotlin
assert "fallbackAllowed" in kotlin
assert "!tcpError.fallbackAllowed" in kotlin

# The current release is S3-only.  Keep P4 implementation hooks in the tree,
# but never let device/status input select the P4 package until that path is
# explicitly re-enabled.
assert "return \"esp32s3\"" in kotlin[kotlin.index("private fun parseBadgeHardware"):], \
    "Android must keep S3 as the active hardware target"
assert "return \"esp32s3\"" in kotlin[kotlin.index("private fun normalizeBadgeHardware"):], \
    "Android hardware normalization must default to S3"

# User switches include a CRC32 after the Uxxx id.  The firmware must parse
# the first token, otherwise a previously uploaded user asset cannot be found.
switch = wifi.index('/* SWITCH command: "SWITCH <ID>\\n" */')
switch_end = wifi.index("/* Binary upload", switch)
switch_source = wifi[switch:switch_end]
assert "strtok" in switch_source or "strpbrk" in switch_source or "isspace" in switch_source, \
    "SWITCH parser must isolate the asset id from optional CRC32"

# Do not perform an unnecessary post-upload IDENTITY round trip on S3.
upload_fn = kotlin.index("private fun uploadAsset(assetPath: String")
upload_end = kotlin.index("private fun startUploadKeepAlive", upload_fn)
upload_source = kotlin[upload_fn:upload_end]
assert "readDeviceIdentity()" not in upload_source, \
    "S3 upload completion must not wait for a P4-only identity request"

# A failed/empty server-package download must release the UI busy state.
download_null = dart.index("if (!mounted || downloadResult == null)")
download_guard = dart[download_null:dart.index("final downloadedPath", download_null)]
assert "_uploading = false" in download_guard, \
    "empty package download must stop the upload spinner"

print("upload transport policy checks passed")
