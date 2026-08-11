from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "main" / "Badge" / "BadgeAnimMgr.c").read_text(encoding="utf-8", errors="ignore")


def extract_function(source: str, signature: str) -> str:
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 0
    for index in range(brace, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise AssertionError(f"{signature} body not found")


switch_body = extract_function(SOURCE, "esp_err_t badge_anim_mgr_switch_to(const char *new_id)")

assert "s_play_mode == BADGE_PLAY_MODE_SECOND_HALF" in switch_body, (
    "switch requests during second_half must be coalesced instead of restarting transition playback"
)
assert "coalesced switch while transition playing" in switch_body, (
    "coalesced transition switch should be logged for diagnosing repeated app commands"
)
assert "s_transition_lands_on_current" in SOURCE, (
    "third_half F006/F007 transitions must remember that the current id is the transition landing target"
)

third_half_block = switch_body[switch_body.index("if (is_factory_six_seven_pair"):]
third_half_block = third_half_block[:third_half_block.index("if (second != NULL)")]
assert "s_transition_lands_on_current = true;" in third_half_block, (
    "F006/F007 third_half playback should mark that it lands on s_current_id"
)
assert third_half_block.index("s_transition_lands_on_current = true;") < third_half_block.index(
    "badge_display_play_asset_file(third_path, BADGE_PLAY_MODE_SECOND_HALF)"
), "third_half landing state must be set before playback starts"

normal_second_block = switch_body[switch_body.index("if (second != NULL)"):]
normal_second_block = normal_second_block[:normal_second_block.index("/* Direct switch */")]
assert "s_play_mode = BADGE_PLAY_MODE_SECOND_HALF;" in normal_second_block, (
    "starting factory second_half must mark manager state as SECOND_HALF"
)
assert "s_transition_lands_on_current = false;" in normal_second_block, (
    "normal second_half exits do not land on the already-updated current id"
)
assert normal_second_block.index("s_play_mode = BADGE_PLAY_MODE_SECOND_HALF;") < normal_second_block.index(
    "badge_display_play_asset_file(second->file_path, BADGE_PLAY_MODE_SECOND_HALF)"
), "manager state must be updated before second_half playback is started"

assert "already showing requested animation" in switch_body, (
    "duplicate switch requests to the current animation should be ignored"
)

notify_body = extract_function(SOURCE, "void badge_anim_mgr_notify_finished(void)")
assert "s_play_mode == BADGE_PLAY_MODE_SECOND_HALF" in notify_body, (
    "finished unqueued transition playback should restore a stable frozen state"
)
assert "transition_landed_on_current" in notify_body, (
    "pending switches after third_half should be processed from the landed current id"
)
assert "badge_anim_mgr_switch_to(next_id);" in notify_body, (
    "pending switches after F006/F007 third_half should re-enter switch logic so reverse third_half can play"
)
assert "s_play_mode = BADGE_PLAY_MODE_FIRST_HALF_FREEZE;" in notify_body, (
    "third_half or unqueued second_half completion should leave manager ready for future switches"
)
