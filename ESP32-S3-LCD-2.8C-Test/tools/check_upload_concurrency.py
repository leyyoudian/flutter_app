from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "main" / "Wireless" / "WifiUpload.c").read_text(
    encoding="utf-8", errors="ignore"
)


def block(start: str, end: str) -> str:
    begin = SOURCE.index(start)
    finish = SOURCE.index(end, begin)
    return SOURCE[begin:finish]


begin_session = block(
    "static esp_err_t begin_upload_session",
    "static esp_err_t write_upload_session",
)
tcp_handler = block(
    "static esp_err_t handle_tcp_upload",
    "static void tcp_upload_task",
)

# A rejected concurrent session does not own the active upload or display and
# must not abort either one.
assert "upload busy; rejecting concurrent session" in begin_session
assert "ret == ESP_ERR_INVALID_STATE" in begin_session
begin_failure = tcp_handler[tcp_handler.index("ret = begin_upload_session"):]
begin_failure = begin_failure[:begin_failure.index("session.recv_us")]
assert "return ret;" in begin_failure
assert "abort_upload_session();" not in begin_failure

print("upload concurrency checks passed")
