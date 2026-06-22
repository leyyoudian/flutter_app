from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
INDEXED_H = ROOT / "main" / "Badge" / "BadgeIndexed.h"
INDEXED_C = ROOT / "main" / "Badge" / "BadgeIndexed.c"
CMAKE = ROOT / "main" / "CMakeLists.txt"

assert INDEXED_H.exists(), "BadgeIndexed.h must exist"
assert INDEXED_C.exists(), "BadgeIndexed.c must exist"

header = INDEXED_H.read_text(encoding="utf-8")
source = INDEXED_C.read_text(encoding="utf-8")
cmake = CMAKE.read_text(encoding="utf-8")

assert "badge_indexed_init" in header, "indexed decoder init API missing"
assert "badge_indexed_decode" in header, "indexed decoder decode API missing"
assert "badge_indexed_render_rgb565" in header, "indexed renderer API missing"
assert "badge_indexed_deinit" in header, "indexed decoder cleanup API missing"
assert "MALLOC_CAP_SPIRAM" in source, "indexed framebuffers must use PSRAM"
assert "BADGE_FRAME_INDEXED_KEY" in source, "key frame decoder missing"
assert "BADGE_FRAME_INDEXED_TILE" in source, "tile frame decoder missing"
assert "BADGE_FRAME_INDEXED_REPEAT" in source, "repeat frame decoder missing"
assert "apply_indexed_tile_payload" in source, "tile payload application helper missing"
assert "render_scaled_rgb565" in source, "scaled RGB565 renderer missing"
assert "Badge/BadgeIndexed.c" in cmake, "BadgeIndexed.c must be compiled"
