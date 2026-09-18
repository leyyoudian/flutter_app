from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
anim = (ROOT / "main/Badge/BadgeAnimMgr.c").read_text(encoding="utf-8")
stream = (ROOT / "main/Badge/BadgeStream.c").read_text(encoding="utf-8")
display = (ROOT / "main/Badge/BadgeDisplay.c").read_text(encoding="utf-8")
dart = (ROOT.parent / "app_gif/lib/main.dart").read_text(encoding="utf-8")

switch = anim.index("/* Play second_half exit animation")
direct = anim.index("/* Direct switch */", switch)
switch_source = anim[switch:direct]
assert "if (second != NULL)" in switch_source, \
    "factory-to-user transitions must retain the second_half exit animation"
assert "badge_display_play_asset_file(second->file_path" in switch_source, \
    "factory exit animation must still be played"

assert "BADGE_STREAM_FAST_LOOP_CACHE_MAX_BYTES" in stream, \
    "streamer needs an explicit fast-start cache threshold"
assert "bool fast_loop_start = loop &&" in stream, \
    "only looping assets may use the fast-start bypass"
assert "BADGE_STREAM_FAST_LOOP_MAX_FRAME_BYTES" in stream, \
    "heavy loop frames need an explicit direct-stream guard"
assert "max_payload <= BADGE_STREAM_FAST_LOOP_MAX_FRAME_BYTES" in stream, \
    "fast loop policy must be guarded by maximum frame size"
assert "bool fast_transition_start = !loop;" in stream, \
    "all non-loop transitions must avoid synchronous whole-asset loading"

assert "BADGE_SECOND_HALF_FRAME_DELAY_NUMERATOR" in display, \
    "second_half playback needs an explicit presentation-speed policy"
assert "entry_mode == BADGE_PLAY_MODE_SECOND_HALF" in display, \
    "second_half playback must use the dedicated timing policy"
assert "BADGE_SECOND_HALF_FRAME_DELAY_DENOMINATOR" in display, \
    "second_half timing policy must use a bounded delay scale"
assert "BADGE_STREAM_TRANSITION_PREFILL_FRAMES" in display, \
    "non-loop transitions need a short startup prefill"
assert "s_transition_started_ms" in anim, \
    "factory transition timing must be measured at the animation manager boundary"
assert "transition finished: elapsed=" in anim, \
    "factory transition completion must expose elapsed timing"

history_start = dart.index("Future<void> _uploadHistoryEntry")
history_end = dart.index("Future<void> _deleteHistoryEntry", history_start)
history_source = dart[history_start:history_end]
assert "unawaited(_reconcilePendingDeviceDeletes())" in history_source, \
    "pending deletion sync must not block an already-uploaded asset switch"
assert "_ensureAssetApproved" not in history_source, \
    "already-uploaded history entries must not poll backend review before switching"

print("fast asset switch checks passed")
