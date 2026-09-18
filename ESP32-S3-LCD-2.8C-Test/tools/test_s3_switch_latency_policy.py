from pathlib import Path
import re


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DISPLAY_C = PROJECT_ROOT / "main" / "Badge" / "BadgeDisplay.c"


def test_switch_prefill_is_short_but_not_disabled():
    source = DISPLAY_C.read_text(encoding="utf-8")

    assert "#define BADGE_STREAM_PREFILL_FRAMES 3u" in source
    assert "#define BADGE_STREAM_PREFILL_TIMEOUT_MS 300u" in source
    assert re.search(
        r"badge_stream_wait_prefill\(\s*stream,\s*prefill_frames,\s*"
        r"BADGE_STREAM_PREFILL_TIMEOUT_MS\s*\)",
        source,
    )


def test_switch_path_does_not_clear_frame_before_new_asset_is_ready():
    source = DISPLAY_C.read_text(encoding="utf-8")
    start = source.index("static esp_err_t player_loop_asset")
    end = source.index("static void player_task", start)
    player = source[start:end]

    assert "show_waiting_screen();" not in player
    assert "memset(s_fb" not in player


def test_exit_stream_is_non_looping_and_stops_after_last_frame():
    display = DISPLAY_C.read_text(encoding="utf-8")
    stream = (PROJECT_ROOT / "main" / "Badge" / "BadgeStream.c").read_text(encoding="utf-8")
    header = (PROJECT_ROOT / "main" / "Badge" / "BadgeStream.h").read_text(encoding="utf-8")

    assert "bool loop" in stream
    assert "entry_mode == BADGE_PLAY_MODE_LOOP" in display
    assert "if (!stream->loop && stream->next_frame >= stream->frame_count)" in stream
    assert "stream->next_frame + 1u) % stream->frame_count" in stream
    assert "bool loop" in header


def test_exit_animation_trims_trailing_repeat_hold():
    source = DISPLAY_C.read_text(encoding="utf-8")

    assert "trim_trailing_repeat_frames" in source
    assert "entry_mode == BADGE_PLAY_MODE_SECOND_HALF" in source
    assert "frames[frame_count - 1u].codec == BADGE_FRAME_INDEXED_REPEAT" in source
    assert "trimmed trailing repeat frames" in source
