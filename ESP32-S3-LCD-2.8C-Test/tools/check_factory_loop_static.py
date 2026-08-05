from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
H = (ROOT / "main" / "Badge" / "BadgeAnimMgr.h").read_text(encoding="utf-8", errors="ignore")
C = (ROOT / "main" / "Badge" / "BadgeAnimMgr.c").read_text(encoding="utf-8", errors="ignore")

assert "BADGE_ANIM_TYPE_FACTORY_LOOP" in H
assert 'BADGE_ANIM_FOLDER_FACTORY_LOOP' in C
assert 'scan_folder(BADGE_ANIM_FOLDER_FACTORY_LOOP, "factory_loop")' in C
assert 'if (entry->type == BADGE_ANIM_TYPE_FACTORY_LOOP)' in C
assert 'BADGE_PLAY_MODE_LOOP' in C

print("factory loop static checks passed")
