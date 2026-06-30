from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
STORAGE = ROOT / "main" / "Badge" / "BadgeStorage.c"
STREAM = ROOT / "main" / "Badge" / "BadgeStream.c"


def is_83_path(path: str) -> bool:
    name = path.rsplit("/", 1)[-1]
    stem, dot, ext = name.partition(".")
    return bool(stem) and bool(dot) and 1 <= len(stem) <= 8 and 1 <= len(ext) <= 3


source = STORAGE.read_text(encoding="utf-8")
stream_source = STREAM.read_text(encoding="utf-8")
paths = {}
for line in source.splitlines():
    if line.startswith("#define BADGE_SD_") and '"/' in line:
        key = line.split()[1]
        value = line.split('"', 1)[1].rsplit('"', 1)[0]
        paths[key] = value

asset_path = paths["BADGE_SD_ASSET_PATH"].replace("BADGE_SD_MOUNT_POINT ", "").strip()
temp_path = paths["BADGE_SD_TEMP_PATH"].replace("BADGE_SD_MOUNT_POINT ", "").strip()

assert is_83_path(asset_path), f"SD asset path must be FAT 8.3 compatible: {asset_path}"
assert is_83_path(temp_path), f"SD temp path must be FAT 8.3 compatible: {temp_path}"
assert asset_path == "/badge.eb4", f"SD asset path must use EBAJ4 extension: {asset_path}"
assert "begin_flash_upload_locked" not in source, "flash upload fallback must stay disabled"
assert 'storage mode=sd-only' in source, "storage must report SD-only mode"
assert "format=ebaj4" in source, "storage status must report active EBAJ4 format"
assert "SDMMC_FREQ_HIGHSPEED" in source, "SDMMC host should request high speed mode"
assert "MALLOC_CAP_INTERNAL | MALLOC_CAP_DMA" in source, "SD reads should use an internal DMA staging buffer"
assert "BADGE_SD_READ_STAGING_BYTES (256u * 1024u)" in source, "SDIO reads should use a larger staging buffer"
assert "BADGE_SD_READ_STAGING_FALLBACK_BYTES (128u * 1024u)" in source, "SDIO read buffer should fall back when internal DMA memory is tight"
assert "BADGE_SD_READ_STAGING_MIN_BYTES (64u * 1024u)" in source, "SDIO read buffer needs a minimum fallback"
assert "BADGE_SD_WRITE_BUFFER_BYTES (128u * 1024u)" in source, "SDIO writes should use a larger stdio buffer"
assert "try_mount_sd_width_locked(4)" in source, "SD mount should try 4-bit mode first"
assert "try_mount_sd_width_locked(1)" in source, "SD mount should fall back to 1-bit mode"
assert "ftruncate(fd, (off_t)total_size)" in source, "SD temp file should be preallocated before sequential upload"
assert "sd width=%u" in source, "storage status/logs should report active SD bus width"
assert "BADGE_STREAM_SLOT_COUNT 16u" in stream_source, "display stream should keep a deep SDIO prefetch queue"
assert "badge_stream_wait_prefill" in stream_source, "display stream should support startup prefill before playback"
