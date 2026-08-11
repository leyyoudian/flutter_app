from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
INDEXED_H = ROOT / "main" / "Badge" / "BadgeIndexed.h"
INDEXED_C = ROOT / "main" / "Badge" / "BadgeIndexed.c"
CMAKE = ROOT / "main" / "CMakeLists.txt"

assert INDEXED_H.exists(), "BadgeIndexed.h must exist"
assert INDEXED_C.exists(), "BadgeIndexed.c must exist"

header = INDEXED_H.read_text(encoding="utf-8", errors="ignore")
source = INDEXED_C.read_text(encoding="utf-8", errors="ignore")
cmake = CMAKE.read_text(encoding="utf-8", errors="ignore")

assert "badge_indexed_init" in header, "indexed decoder init API missing"
assert "badge_indexed_decode" in header, "indexed decoder decode API missing"
assert "badge_indexed_render_rgb565" in header, "indexed renderer API missing"
assert "badge_indexed_blit_dirty_rgb565" in header, "indexed decoder must expose dirty-tile RGB565 blit API"
assert "badge_indexed_dirty_rgb565_is_partial" in header, "display path must be able to skip dirty blit for expensive tile frames"
assert "badge_indexed_deinit" in header, "indexed decoder cleanup API missing"
assert '#include "freertos/task.h"' in source, "indexed decoder must be able to yield during long PSRAM loops"
assert "BADGE_INDEXED_YIELD_EVERY_TILES" in source, "tile decode/blit must periodically yield"
assert "BADGE_INDEXED_YIELD_EVERY_ROWS" in source, "full-frame render must periodically yield"
assert "badge_indexed_yield_if_needed" in source, "indexed decoder needs a shared yield helper"
assert "taskYIELD()" in source, "indexed decoder/render loops should yield without adding frame delay"
assert "vTaskDelay(pdMS_TO_TICKS(1))" not in source, "indexed decoder/render loops must not add 1ms sleeps per chunk"
assert "badge_indexed_copy_payload_yielding" in source, "key frames should copy indexed payload in chunks"
assert "MALLOC_CAP_SPIRAM" in source, "indexed framebuffers must use PSRAM"
assert "BADGE_FRAME_INDEXED_KEY" in source, "key frame decoder missing"
assert "BADGE_FRAME_INDEXED_TILE" in source, "tile frame decoder missing"
assert "BADGE_FRAME_INDEXED_REPEAT" in source, "repeat frame decoder missing"
assert "apply_indexed_tile_payload" in source, "tile payload application helper missing"
assert "render_scaled_rgb565" in source, "scaled RGB565 renderer missing"
assert "render_native_rgb565" in source, "480x480 native renderer must avoid per-pixel scaling divisions"
assert "blit_native_dirty_tiles_rgb565" in source, "tile frames must update only dirty native RGB565 tiles"
assert "palette_matches" in source, "tile decoder must detect palette changes before using partial RGB blits"
assert "int next = indexed->active" in source, "tile decoder must update the active indexed buffer in place"
assert "memcpy(indexed->buffers[next], indexed->buffers[indexed->active]" not in source, (
    "tile decoder must not copy the whole indexed frame before applying dirty tiles"
)
assert "indexed->dirty_tiles[i] = tile_index" in source, (
    "tile decoder must preserve the dirty tile list for the display blit path"
)
assert "badge_indexed_yield_if_needed(&tiles_since_yield, BADGE_INDEXED_YIELD_EVERY_TILES)" in source, (
    "tile decode/blit loops should yield during large dirty frames"
)
assert "badge_indexed_yield_if_needed(&rows_since_yield, BADGE_INDEXED_YIELD_EVERY_ROWS)" in source, (
    "full-frame render loops should yield during large frames"
)
assert "indexed->dirty_tile_count > indexed->dirty_tile_capacity / 2u" in source, (
    "dirty blit should fall back to a full render only after in-place tile updates lose their advantage"
)
assert "for (; x + 7u < BADGE_EBAJ_WIDTH; x += 8u)" in source, (
    "native full-frame renderer should expand multiple indexed pixels per loop"
)
assert "indexed->width == BADGE_EBAJ_WIDTH && indexed->height == BADGE_EBAJ_HEIGHT" in source, (
    "indexed renderer must use the native fast path for full-resolution assets"
)
assert "Badge/BadgeIndexed.c" in cmake, "BadgeIndexed.c must be compiled"
