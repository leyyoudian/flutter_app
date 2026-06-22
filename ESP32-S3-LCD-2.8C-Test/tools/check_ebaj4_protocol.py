from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PROTOCOL_H = ROOT / "main" / "Badge" / "BadgeProtocol.h"
PROTOCOL_C = ROOT / "main" / "Badge" / "BadgeProtocol.c"

header = PROTOCOL_H.read_text(encoding="utf-8")
source = PROTOCOL_C.read_text(encoding="utf-8")

assert "BADGE_EBAJ_MAGIC_V4 0x344a4142u" in header, "protocol must define BAJ4 magic"
assert "BADGE_EBAJ_VERSION_V4 4u" in header, "protocol must define EBAJ4 version"
assert "BADGE_EBAJ_VERSION BADGE_EBAJ_VERSION_V4" in header, "default protocol must be EBAJ4"
assert "BADGE_EBAJ_FPS 20u" in header, "protocol must fix playback fps at 20"
assert "BADGE_EBAJ_FRAME_DELAY_MS 50u" in header, "protocol must use 50ms frame delay"
assert "BADGE_EBAJ_PALETTE_ENTRIES 256u" in header, "EBAJ4 must use 256 palette entries"
assert "BADGE_FRAME_INDEXED_KEY" in header, "EBAJ4 key codec missing"
assert "BADGE_FRAME_INDEXED_TILE" in header, "EBAJ4 tile codec missing"
assert "BADGE_FRAME_INDEXED_REPEAT" in header, "EBAJ4 repeat codec missing"
assert "stream_width" in header and "stream_height" in header, "header must carry stream dimensions"
assert "palette_entries" in header, "header must carry palette entry count"
assert "sizeof(badge_ebaj_header_t) == 44" in header, "EBAJ4 header must be 44 bytes"
assert "sizeof(badge_ebaj_frame_t) == 16" in header, "EBAJ4 frame entry must stay 16 bytes"

assert "BADGE_EBAJ_MAGIC_V4" in source, "validator must check BAJ4 magic"
assert "header->fps != BADGE_EBAJ_FPS" in source, "validator must reject non-20fps packages"
assert "header->palette_entries != BADGE_EBAJ_PALETTE_ENTRIES" in source, "validator must check palette count"
assert "valid_stream_size" in source, "validator must constrain stream dimensions"
assert "BADGE_EBAJ_MAGIC_V3" not in source, "runtime validator must reject old EBAJ3 packages"
