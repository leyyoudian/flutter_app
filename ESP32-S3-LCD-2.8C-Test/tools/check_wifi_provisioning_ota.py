from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8", errors="ignore")


def require(text: str, needle: str, label: str) -> None:
    if needle not in text:
        raise AssertionError(f"missing {label}: {needle}")


def extract_function(source: str, signature: str) -> str:
    search_from = 0
    while True:
        start = source.index(signature, search_from)
        brace = source.index("{", start + len(signature))
        semicolon = source.find(";", start + len(signature), brace)
        if semicolon == -1:
            break
        search_from = semicolon + 1
    depth = 0
    for index in range(brace, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise AssertionError(f"function body not found: {signature}")


def main() -> None:
    partitions = read("partitions.csv")
    wifi_c = read("main/Wireless/WifiUpload.c")
    wifi_h = read("main/Wireless/WifiUpload.h")
    main_c = read("main/main.c")
    cmake = read("main/CMakeLists.txt")
    root_cmake = read("CMakeLists.txt")
    display_c = read("main/Badge/BadgeDisplay.c")
    display_h = read("main/Badge/BadgeDisplay.h")
    sdkdefaults = read("sdkconfig.defaults")
    sdkconfig = read("sdkconfig")

    for needle in ("otadata", "ota_0", "ota_1", "asset"):
        require(partitions, needle, "OTA partition layout")

    require(sdkdefaults, "CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE=y", "OTA rollback")
    require(sdkdefaults, "CONFIG_ESP_INT_WDT_TIMEOUT_MS=10000", "interrupt watchdog timeout for Wi-Fi beacon-timeout recovery")
    require(sdkdefaults, "CONFIG_INT_WDT_TIMEOUT_MS=10000", "legacy interrupt watchdog timeout alias")
    require(sdkdefaults, "CONFIG_ESP_TASK_WDT_TIMEOUT_S=15", "task watchdog timeout for Wi-Fi PHY timers during static display")
    require(sdkdefaults, "CONFIG_TASK_WDT_TIMEOUT_S=15", "legacy task watchdog timeout alias")
    require(sdkdefaults, "# CONFIG_ESP_TASK_WDT_CHECK_IDLE_TASK_CPU0 is not set", "CPU0 idle task is not watched during Wi-Fi PHY timer bursts")
    require(sdkdefaults, "# CONFIG_ESP_TASK_WDT_CHECK_IDLE_TASK_CPU1 is not set", "CPU1 idle task is not watched during frozen single-frame display")
    require(sdkdefaults, "# CONFIG_TASK_WDT_CHECK_IDLE_TASK_CPU0 is not set", "legacy CPU0 idle task watchdog alias is disabled")
    require(sdkdefaults, "# CONFIG_TASK_WDT_CHECK_IDLE_TASK_CPU1 is not set", "legacy CPU1 idle task watchdog alias is disabled")
    require(sdkdefaults, "CONFIG_ESP_SYSTEM_EVENT_QUEUE_SIZE=64", "larger system event queue for captive portal bursts")
    require(sdkdefaults, "CONFIG_SYSTEM_EVENT_QUEUE_SIZE=64", "legacy system event queue alias")
    require(sdkdefaults, "CONFIG_HTTPD_SERVER_EVENT_POST_TIMEOUT=200", "short HTTPD event post timeout during captive storms")
    require(sdkconfig, "# CONFIG_ESP_TASK_WDT_CHECK_IDLE_TASK_CPU0 is not set", "active sdkconfig does not watch CPU0 idle task")
    require(sdkconfig, "# CONFIG_ESP_TASK_WDT_CHECK_IDLE_TASK_CPU1 is not set", "active sdkconfig does not watch CPU1 idle task")
    require(sdkconfig, "# CONFIG_TASK_WDT_CHECK_IDLE_TASK_CPU0 is not set", "active legacy CPU0 idle task watchdog alias is disabled")
    require(sdkconfig, "# CONFIG_TASK_WDT_CHECK_IDLE_TASK_CPU1 is not set", "active legacy CPU1 idle task watchdog alias is disabled")
    require(sdkconfig, "CONFIG_ESP_SYSTEM_EVENT_QUEUE_SIZE=64", "active sdkconfig system event queue size")
    require(sdkconfig, "CONFIG_SYSTEM_EVENT_QUEUE_SIZE=64", "active sdkconfig legacy event queue size")
    require(sdkconfig, "CONFIG_HTTPD_SERVER_EVENT_POST_TIMEOUT=200", "active sdkconfig HTTPD event post timeout")
    require(cmake, "esp_https_ota", "OTA component dependency")
    require(cmake, "app_update", "app update component dependency")
    require(cmake, "json", "JSON component dependency for OTA manifest")
    require(cmake, 'EMBED_FILES "assets/upload_480_rgb565.bin"', "OTA upload image embedded in firmware")
    require(root_cmake, 'set(PROJECT_VER "0.1.47")', "firmware project version")
    require(cmake, 'BADGE_FW_VERSION=\\"${PROJECT_VER}\\"', "firmware version comes from project version")
    if "Button_Driver/Button_Driver.c" in cmake or "Button_Driver/multi_button.c" in cmake:
        raise AssertionError("GPIO0 button driver must not be compiled for provisioning reset")
    if main_c.index("ESP_ERROR_CHECK(Wireless_Init());") > main_c.index("ESP_ERROR_CHECK(badge_storage_init());"):
        raise AssertionError("Wi-Fi must start before SD/storage/display initialization so saved STA connects immediately at boot")

    require(wifi_c, "ProvisioningHTML.h", "provisioning HTML include")
    require(wifi_c, "WIFI_MODE_AP", "AP-only mode when no saved Wi-Fi")
    require(wifi_c, "WIFI_MODE_STA", "STA mode")
    require(wifi_c, "WIFI_MODE_APSTA", "APSTA provisioning mode")
    require(wifi_c, "wifi_event_handler", "Wi-Fi event handler")
    require(wifi_c, "safe_restart_after_releasing_lcd_cs", "safe restart wrapper")
    safe_restart = extract_function(wifi_c, "static void safe_restart_after_releasing_lcd_cs(void)")
    require(safe_restart, "ST7701S_PrepareForRestart()", "LCD CS release before software reset")
    require(safe_restart, "esp_restart()", "safe restart performs software reset")
    if wifi_c.count("esp_restart()") != 1:
        raise AssertionError("all software resets must go through safe_restart_after_releasing_lcd_cs")
    require(wifi_c, "start_provisioning_ap", "provisioning AP startup")
    require(wifi_c, "start_saved_sta_fallback_task", "saved Wi-Fi STA+AP fallback")
    require(wifi_c, "start_provisioning_ap(true)", "APSTA fallback for unavailable saved Wi-Fi")
    require(wifi_c, "start_provisioning_ap(false)", "AP-only mode without saved Wi-Fi")
    require(wifi_c, "handle_set_config", "set_config provisioning endpoint")
    require(wifi_c, "clear_saved_wifi_credentials", "web-triggered Wi-Fi credential erase")
    require(wifi_c, "handle_clear_config", "clear_config provisioning endpoint")
    require(wifi_c, '"/clear_config"', "clear_config endpoint")
    require(wifi_c, '"/wifi_status"', "Wi-Fi provisioning status endpoint")
    require(wifi_c, "BADGE_PROVISIONING_RESTART_DELAY_MS", "provisioning success restart delay")
    require(wifi_c, "s_restart_after_provisioning_success", "only web-submitted Wi-Fi success restarts")
    require(wifi_c, "s_provisioning_restart_pending", "provisioning restart is scheduled once")
    require(wifi_c, "s_provisioning_started_by_fallback", "fallback AP is tracked separately from web provisioning")
    require(wifi_c, "delayed_restart_after_provisioning_task", "provisioning success restart task")
    require(wifi_c, "delayed_sta_connect_after_config_task", "web config starts STA after HTTP response")
    require(wifi_c, "schedule_provisioning_restart_if_connected", "already-connected provisioning schedules restart")
    require(wifi_c, "schedule_disable_provisioning_ap", "provisioning AP shutdown delay is selected by context")
    require(wifi_c, "s_sta_connected_ssid", "connected STA SSID is tracked")
    require(wifi_c, "s_sta_connecting_ssid", "connecting STA SSID is tracked")
    require(wifi_c, "s_sta_reconfiguring", "STA SSID switch suppresses old reconnect handling")
    require(wifi_c, "STA already connected to ssid=%s; skip reconnect", "same SSID reconnect is idempotent")
    require(wifi_c, "STA connect already in progress for ssid=%s; skip duplicate connect", "duplicate in-flight connect is idempotent")
    require(wifi_c, "STA switching from ssid=%s to ssid=%s", "different SSID switch disconnects before connecting")
    require(wifi_c, "STA disconnected for Wi-Fi reconfiguration", "manual SSID switch ignores old disconnect retry")
    require(wifi_c, "provisioning complete; restarting", "provisioning restart log")
    require(wifi_c, "s_sta_connecting", "STA connection progress state")
    require(wifi_c, "delayed_disable_provisioning_ap", "delayed AP shutdown after STA success")
    require(wifi_c, "captive_dns_task", "captive portal DNS task")
    require(wifi_c, "BADGE_CAPTIVE_PORTAL_URL", "captive portal redirect URL")
    require(wifi_c, "BADGE_CAPTIVE_PORTAL_API_URL", "RFC captive portal API URL")
    require(wifi_c, "BADGE_CAPTIVE_DNS_CAPTURE_ALL_MS", "short DNS capture-all window for unknown phone probes")
    require(wifi_c, "s_captive_capture_all_until_us", "DNS capture-all expiry state")
    require(wifi_c, "WIFI_EVENT_AP_STACONNECTED", "DNS capture-all refreshes when phone joins AP")
    require(wifi_c, "WIFI_EVENT_AP_STADISCONNECTED", "AP client tracking clears fallback retry guard")
    require(wifi_c, "s_ap_client_count", "AP client count is tracked before pausing fallback AP")
    require(wifi_c, "pause_fallback_ap_for_sta_retry", "fallback AP is paused before saved STA retry to avoid channel adjust")
    require(wifi_c, "s_lcd_resync_after_sta_success", "STA success after APSTA fallback schedules LCD resync")
    require(wifi_c, "schedule_lcd_resync_after_wireless", "LCD resync runs outside Wi-Fi event handler")
    require(wifi_c, "badge_display_resync_after_wireless", "Wi-Fi channel/mode changes can resync RGB LCD")
    require(wifi_c, "captive_dns_capture_all_active", "DNS capture-all helper")
    require(wifi_c, "stop_captive_dns_capture_window", "DNS capture-all stops after portal is open")
    require(wifi_c, "request_targets_captive_host", "wildcard traffic does not prematurely stop capture-all")
    require(wifi_c, "BADGE_PROVISIONING_SUCCESS_AP_HOLD_MS 30000u", "AP stays open long enough for success polling")
    require(wifi_c, "BADGE_PROVISIONING_FALLBACK_AP_HOLD_MS 2000u", "fallback AP closes quickly once saved Wi-Fi gets IP")
    require(wifi_c, "BADGE_PROVISIONING_CONNECT_START_DELAY_MS", "web config response is sent before STA connect can disrupt SoftAP fetch")
    require(wifi_c, "configure_provisioning_dhcp_options", "SoftAP DHCP captive portal setup")
    require(wifi_c, "esp_netif_dhcps_stop", "SoftAP DHCP options can be changed")
    require(wifi_c, "esp_netif_dhcps_option", "SoftAP DHCP options are advertised")
    require(wifi_c, "ESP_NETIF_DOMAIN_NAME_SERVER", "SoftAP advertises ESP as DNS server")
    require(wifi_c, "ESP_NETIF_CAPTIVEPORTAL_URI", "SoftAP advertises captive portal URI")
    require(wifi_c, "static char captive_uri[] = BADGE_CAPTIVE_PORTAL_API_URL", "DHCP captive portal option points to JSON API")
    require(wifi_c, "esp_netif_set_dns_info", "SoftAP DNS points at captive DNS server")
    require(wifi_c, "esp_netif_dhcps_start", "SoftAP DHCP restarts after option changes")
    require(wifi_c, "httpd_uri_match_wildcard", "captive portal wildcard route")
    require(wifi_c, "config.max_uri_handlers", "enough captive portal URI slots")
    require(wifi_c, "config.max_open_sockets = 4", "HTTP sockets leave room for DNS/upload sockets")
    require(wifi_c, "config.lru_purge_enable = true", "captive portal socket LRU purge")
    require(wifi_c, "config.task_priority = 5", "HTTP server priority must not starve Wi-Fi/LCD during captive storms")
    require(wifi_c, "ensure_wifi_scan_mode", "scan endpoint enables STA radio before scanning")
    require(wifi_c, "esp_wifi_get_mode", "scan endpoint checks current Wi-Fi mode")
    require(wifi_c, "esp_wifi_set_mode(WIFI_MODE_APSTA)", "AP-only provisioning can scan Wi-Fi")
    require(wifi_c, "captive_dns_should_reply", "captive DNS must not hijack every domain")
    require(wifi_c, "connectivitycheck.gstatic.com", "Android captive DNS allow-list")
    require(wifi_c, "www.google.cn", "China Android captive DNS allow-list")
    require(wifi_c, "connectivitycheck.gstatic.cn", "China Android captive DNS allow-list")
    require(wifi_c, "connectivitycheck.vivo.com.cn", "Vivo captive DNS allow-list")
    require(wifi_c, "vbw.vivo.com.cn", "Vivo browser captive DNS allow-list")
    require(wifi_c, "kernelapi.vivo.com", "Vivo kernel captive DNS allow-list")
    require(wifi_c, "wap.cmpassport.com", "China Mobile captive DNS allow-list")
    require(wifi_c, "www.baidu.com", "China Android captive DNS fallback")
    require(wifi_c, "captive.apple.com", "iOS captive DNS allow-list")
    require(wifi_c, "www.msftconnecttest.com", "Windows captive DNS allow-list")
    require(wifi_c, "BADGE_CAPTIVE_DNS_CAPTURE_ALL_MS 180000u", "longer captive DNS capture window for OEM probes")
    require(wifi_c, "s_captive_http_log_budget", "captive HTTP diagnostics budget")
    require(wifi_c, "log_captive_http_request", "captive HTTP diagnostics")
    require(wifi_c, "captive HTTP hit uri=%s host=%s", "HTTP portal hit logging")
    require(wifi_c, '"/generate_204*"', "Android captive portal probe with query support")
    require(wifi_c, '"/gen_204*"', "Android alternate captive portal probe with query support")
    require(wifi_c, '"/hotspot-detect.html"', "iOS captive portal probe")
    require(wifi_c, '"/connecttest.txt"', "Windows captive portal probe")
    require(wifi_c, "BADGE_CAPTIVE_PROBE_HTML", "small captive probe response")
    require(wifi_c, "BADGE_CAPTIVE_API_JSON", "RFC captive portal JSON response")
    require(wifi_c, "application/captive+json", "RFC captive portal JSON MIME type")
    require(wifi_c, '\\"user-portal-url\\"', "RFC captive portal JSON user portal URL")
    require(wifi_c, "captive_portal_api_handler", "RFC captive portal API handler")
    require(wifi_c, '"/captive-portal/api"', "RFC captive portal API route")
    require(wifi_c, "captive_probe_send_response", "captive probe send helper")
    require(wifi_c, "send_provisioning_page", "full provisioning page send helper")
    require(wifi_c, "captive_wildcard_get_handler", "wildcard captive GET handler")
    require(wifi_c, "location.replace", "captive probe page opens provisioning root")
    require(wifi_c, "return ESP_OK", "captive probe ignores early client close")
    require(wifi_c, "captive_post_handler", "POST captive traffic is handled without 405")
    require(wifi_c, ".method = HTTP_POST", "POST wildcard captive handler")
    if '"302 Found"' in wifi_c:
        raise AssertionError("captive portal probes must not depend on HTTP redirect")
    probe_body = extract_function(wifi_c, "static esp_err_t captive_probe_handler(httpd_req_t *req)")
    require(probe_body, "captive_probe_send_response(req)", "captive probes use small response")
    if "WIFI_PROVISIONING_HTML" in probe_body:
        raise AssertionError("captive probes must not send the full provisioning page")
    if "stop_captive_dns_capture_window" in probe_body:
        raise AssertionError("captive probes must keep DNS capture active until the portal root opens")
    if 'ESP_LOGI(TAG, "captive probe' in probe_body:
        raise AssertionError("captive probe logging must be rate-limited, not unconditional")
    root_body = extract_function(wifi_c, "static esp_err_t provisioning_root_handler(httpd_req_t *req)")
    require(root_body, "!request_targets_captive_host(req)", "root handler sends small probe for non-portal hosts")
    require(root_body, "captive_probe_send_response(req)", "non-portal root requests use small response")
    require(root_body, "send_provisioning_page(req)", "portal root serves full provisioning page")
    wildcard_body = extract_function(wifi_c, "static esp_err_t captive_wildcard_get_handler(httpd_req_t *req)")
    require(wildcard_body, "request_targets_captive_host(req)", "wildcard handler distinguishes portal host")
    require(wildcard_body, "send_provisioning_page(req)", "portal wildcard requests serve full page")
    require(wildcard_body, "captive_probe_send_response(req)", "probe wildcard requests use small response")
    if ".handler = provisioning_root_handler" in extract_function(wifi_c, "static esp_err_t start_http_server(void)").split("const httpd_uri_t captive_wildcard_uri")[1]:
        raise AssertionError("wildcard GET must not directly serve the full provisioning page")
    set_config_body = extract_function(wifi_c, "static esp_err_t handle_set_config(httpd_req_t *req)")
    require(set_config_body, "schedule_provisioning_restart_if_connected()", "repeated successful config schedules restart")
    require(set_config_body, "schedule_sta_connect_after_config()", "set_config sends HTTP success before starting STA connect")
    require(set_config_body, "already_connected", "set_config reports already-connected duplicates")
    if "ret = start_sta_connect()" in set_config_body:
        raise AssertionError("set_config must not start STA before the HTTP success response can reach the phone")
    if "s_provisioning_restart_pending = false" in set_config_body:
        raise AssertionError("set_config must not clear an already scheduled provisioning restart")
    require(wifi_c, '"/scan"', "scan endpoint")
    require(wifi_c, '"/set_config"', "set_config endpoint")
    require(wifi_c, '"/ota"', "OTA endpoint")
    require(wifi_c, "esp_https_ota", "HTTPS OTA call")
    require(wifi_c, "BADGE_FW_VERSION", "firmware version constant")
    require(wifi_c, "BADGE_OTA_MANIFEST_URL", "automatic OTA manifest URL")
    require(wifi_c, "http://60.205.122.153/api/ota/manifest?hardware=esp32s3", "public OTA manifest URL")
    require(wifi_c, "BADGE_WIFI_RECONNECT_MIN_DELAY_MS 3000u", "Wi-Fi reconnect minimum backoff is short enough for boot-time STA retry")
    require(wifi_c, "BADGE_WIFI_RECONNECT_MAX_DELAY_MS", "Wi-Fi reconnect maximum backoff")
    require(wifi_c, "wifi_reconnect_delay_ms", "Wi-Fi reconnect uses backoff instead of a fixed loop")
    require(wifi_c, "is_missing_or_bad_saved_wifi_reason", "missing saved Wi-Fi enables provisioning AP")
    require(wifi_c, "should_start_provisioning_fallback", "provisioning AP fallback distinguishes missing Wi-Fi from transient auth timeouts")
    require(wifi_c, "BADGE_PROVISIONING_AUTH_FALLBACK_RETRIES 3u", "auth timeout fallback waits for repeated failures")
    require(wifi_c, "start_provisioning_fallback_task", "provisioning AP starts promptly when saved Wi-Fi is unavailable")
    require(wifi_c, "saved STA unavailable; enabling provisioning AP", "clear fallback AP log for no surrounding Wi-Fi")
    missing_body = extract_function(wifi_c, "static bool is_missing_or_bad_saved_wifi_reason(uint8_t reason)")
    if "WIFI_REASON_HANDSHAKE_TIMEOUT" in missing_body or "WIFI_REASON_4WAY_HANDSHAKE_TIMEOUT" in missing_body:
        raise AssertionError("single handshake timeout must not immediately open provisioning AP")
    fallback_body = extract_function(wifi_c, "static bool should_start_provisioning_fallback(uint8_t reason)")
    auth_body = extract_function(wifi_c, "static bool is_auth_retry_saved_wifi_reason(uint8_t reason)")
    require(fallback_body, "is_missing_or_bad_saved_wifi_reason(reason)", "missing SSID still opens AP fallback promptly")
    require(fallback_body, "s_sta_retry_count >= BADGE_PROVISIONING_AUTH_FALLBACK_RETRIES", "auth failures open AP only after repeated retries")
    require(auth_body, "WIFI_REASON_HANDSHAKE_TIMEOUT", "auth timeout is handled as repeated-failure fallback")
    require(wifi_c, "BADGE_DISCOVERY_UDP_PORT", "hotspot discovery UDP port")
    require(wifi_c, "discovery_announce_task", "ESP announces itself for phone hotspot discovery")
    require(wifi_c, "espbaji_hello", "ESP discovery hello payload")
    require(wifi_c, "start_discovery_announce_task", "STA IP starts discovery announcements")
    require(wifi_c, "listen(listen_sock, 4)", "TCP upload server keeps a small backlog for app retry bursts")
    require(wifi_c, "badge_display_pause_for_ota", "OTA pauses display playback and shows OTA UI")
    require(wifi_c, "badge_display_resume_after_ota", "OTA resumes display if update fails")
    require(wifi_c, "BADGE_OTA_HTTP_TIMEOUT_MS", "OTA HTTP timeout constant")
    require(wifi_c, "BADGE_OTA_TASK_STACK 12288u", "larger OTA task stack for sequential firmware download")
    require(wifi_c, "BADGE_OTA_HTTP_BUFFER_SIZE 8192u", "larger OTA stream buffer for sequential firmware download")
    require(wifi_c, ".keep_alive_enable = false", "OTA disables HTTP keep-alive for firmware download")
    if ".partial_http_download = true" in wifi_c:
        raise AssertionError("OTA must not use HTTP range partial download; nginx disables ranges for firmware compatibility")
    if ".max_http_request_size" in wifi_c or "BADGE_OTA_MAX_HTTP_REQUEST_SIZE" in wifi_c:
        raise AssertionError("OTA sequential download must not configure range request sizing")
    require(wifi_c, ".bulk_flash_erase = true", "OTA erases the target app partition before writing")
    require(wifi_c, ".buffer_caps = MALLOC_CAP_INTERNAL", "OTA download buffer stays in internal RAM")
    require(wifi_c, "esp_https_ota_begin", "OTA uses manual loop so display can be refreshed")
    require(wifi_c, "esp_https_ota_perform", "OTA performs chunked loop")
    require(wifi_c, "esp_https_ota_finish", "OTA finalizes manual update")
    require(wifi_c, "esp_https_ota_abort", "OTA aborts manual update on failure")
    ota_perform_body = extract_function(wifi_c, "static esp_err_t perform_ota_with_display_refresh")
    if "badge_display_refresh_ota_screen" in ota_perform_body:
        raise AssertionError("OTA must not refresh the LCD while flash is being written")
    require(wifi_c, "auto_ota_check_task", "automatic OTA check task")
    require(wifi_c, "start_auto_ota_check", "STA connected automatic OTA trigger")
    require(wifi_c, "BADGE_OTA_CHECK_DELAY_MS 15000u", "automatic OTA checks soon after Wi-Fi has settled")
    require(wifi_c, "BADGE_OTA_WIFI_STABLE_MS 10000u", "automatic OTA requires a short stable STA window")
    require(wifi_c, "BADGE_OTA_LOCAL_IDLE_MS 30000u", "automatic OTA avoids app control/upload windows without waiting minutes")
    require(wifi_c, "s_auto_ota_check_done", "automatic OTA runs at most once per boot")
    require(wifi_c, "s_sta_got_ip_us", "automatic OTA measures STA stability from got-IP time")
    require(wifi_c, "s_last_local_activity_us", "automatic OTA tracks app/local activity")
    require(wifi_c, "mark_local_activity", "HTTP/TCP app activity updates OTA idle timer")
    require(wifi_c, "ota_wifi_stable", "OTA checks STA stability before using public network")
    require(wifi_c, "ota_local_activity_recent", "OTA skips while the app is actively using the badge")
    require(wifi_c, "cJSON_Parse", "OTA manifest JSON parsing")
    require(wifi_c, "xTaskCreate", "non-blocking Wi-Fi or OTA task")
    ap_close_body = extract_function(wifi_c, "static void delayed_disable_provisioning_ap(void *arg)")
    require(ap_close_body, "start_auto_ota_check()", "automatic OTA starts after fallback provisioning AP closes")
    auto_body = extract_function(wifi_c, "static void auto_ota_check_task(void *arg)")
    local_activity_block = auto_body[auto_body.index("if (ota_local_activity_recent())"):]
    local_activity_block = local_activity_block[:local_activity_block.index("s_auto_ota_check_done = true;")]
    require(local_activity_block, "start_auto_ota_check()", "automatic OTA retries after local app activity instead of stopping for this boot")
    if "s_auto_ota_check_done = true" in local_activity_block:
        raise AssertionError("recent local app activity must not mark automatic OTA done")
    manifest_fail_block = auto_body[auto_body.index('ESP_LOGW(TAG, "OTA manifest fetch failed'):]
    manifest_fail_block = manifest_fail_block[:manifest_fail_block.index("return;") + len("return;")]
    require(manifest_fail_block, "start_auto_ota_check()", "automatic OTA retries after transient manifest fetch failure")

    if "WifiUpload_ClearProvisioning" in wifi_h or "WifiUpload_ClearProvisioning" in wifi_c:
        raise AssertionError("GPIO0 clear provisioning API must be removed")
    require(display_h, "badge_display_pause_for_ota", "OTA display pause API")
    require(display_h, "badge_display_resume_after_ota", "OTA display resume API")
    require(display_h, "badge_display_resync_after_wireless", "wireless mode changes can resync LCD RGB scan")
    require(display_c, "badge_display_pause_for_ota", "OTA display pause implementation")
    require(display_c, "badge_display_resume_after_ota", "OTA display resume implementation")
    require(display_c, "show_ota_screen", "OTA upgrade screen renderer")
    require(display_c, "_binary_upload_480_rgb565_bin_start", "embedded OTA image start symbol")
    require(display_c, "_binary_upload_480_rgb565_bin_end", "embedded OTA image end symbol")
    require(display_c, "BADGE_OTA_IMAGE_BYTES", "OTA image byte size constant")
    require(display_c, "s_ota_screen_visible", "OTA screen is pinned instead of redrawn every chunk")
    require(display_c, "s_ota_fb", "OTA screen framebuffer is stable")
    require(display_c, "choose_static_screen_fb", "OTA screen chooses a non-scanned framebuffer")
    require(display_c, "BADGE_PLAYER_YIELD_EVERY_FRAMES", "player periodically sleeps to avoid task watchdog")
    require(display_c, "badge_player_yield_if_needed", "badge player yield helper")
    require(display_c, "vTaskDelay(pdMS_TO_TICKS(1))", "badge player yields long enough for idle task")
    require(display_c, "BADGE_STATIC_FRAME_HOLD_POLL_MS", "single-frame static asset hold poll interval")
    require(display_c, "BADGE_STATIC_FRAME_HOLD_POLL_MS 20u", "single-frame static asset hold wakes often enough for scheduler health")
    require(display_c, "BADGE_LCD_SWAP_VSYNC_TIMEOUT_MS", "framebuffer swaps wait for vertical sync")
    require(display_c, "BADGE_LCD_STARTUP_SYNC_VSYNCS", "startup LCD sync waits for stable RGB scan")
    if "esp_freertos_hooks.h" in display_c:
        raise AssertionError("frozen single-frame display must not install FreeRTOS idle hooks")
    if "esp_register_freertos_idle_hook" in display_c:
        raise AssertionError("frozen display must not alter esp_vApplicationIdleHook behavior")
    if "static_hold_prevent_waiti" in display_c or "badge_display_set_static_hold_prevent_waiti" in display_c:
        raise AssertionError("static hold waiti guard must be removed; it can trip interrupt WDT")
    require(display_c, "wait_for_reload_while_frozen", "frozen display waits in timed slices")
    require(display_c, "BADGE_STATIC_FRAME_HOLD_POLL_MS", "frozen display wait interval")
    require(display_c, "badge_display_sync_lcd_after_init", "display startup clears framebuffers and resyncs RGB timing")
    require(display_c, "badge_display_resync_after_wireless", "display exposes non-clearing RGB resync after Wi-Fi mode changes")
    require(display_c, "memset(s_fb[i], 0, BADGE_EBAJ_FRAME_BYTES)", "startup sync clears every framebuffer")
    require(display_c, "badge_display_request_refresh", "display explicitly refreshes RGB panel in on-demand mode")
    require(display_c, "esp_lcd_rgb_panel_refresh(panel_handle)", "RGB panel refreshes are one-shot instead of continuous during OTA")
    init_body = extract_function(display_c, "esp_err_t badge_display_init(void)")
    require(init_body, "badge_display_sync_lcd_after_init()", "display init performs LCD startup sync before player task")
    wireless_resync_body = extract_function(display_c, "esp_err_t badge_display_resync_after_wireless(void)")
    require(wireless_resync_body, "s_fb[fb_index]", "wireless LCD resync redraws the current framebuffer")
    require(wireless_resync_body, "LCD wireless resync completed", "wireless LCD resync logs completion")
    if "esp_lcd_rgb_panel_restart(panel_handle)" in wireless_resync_body:
        raise AssertionError("wireless LCD resync must not restart RGB panel during Wi-Fi recovery")
    if "memset" in wireless_resync_body:
        raise AssertionError("wireless LCD resync must not clear framebuffers")
    switch_body = extract_function(display_c, "static void switch_panel_to_fb(int fb_index, int64_t *out_display_us, int64_t *out_vsync_us)\n")
    require(switch_body, "badge_display_request_refresh()", "framebuffer swap requests one RGB refresh")
    if "LCD_WaitForPreparedVsync" in switch_body:
        raise AssertionError("normal playback must not block every frame waiting for VSYNC")
    require(switch_body, "(void)out_vsync_us", "normal playback keeps VSYNC perf at zero because it does not block")
    if "*out_vsync_us += vsync_done_us - vsync_start_us" in switch_body:
        raise AssertionError("normal playback VSYNC perf must not accumulate blocking wait time")
    if "display_static_hold_idle_hook" in display_c or "badge_display_set_static_hold_active" in display_c or "s_static_hold_active" in display_c:
        raise AssertionError("old static hold idle hook names must not remain")
    player_body = extract_function(display_c, "static esp_err_t player_loop_asset(badge_asset_t *asset)")
    require(player_body, "asset->header.frame_count == 1", "single-frame assets are detected")
    require(player_body, "single-frame asset rendered once; holding framebuffer", "single-frame assets are not loop-rendered")
    require(player_body, "xEventGroupWaitBits(s_events, BADGE_RELOAD_BIT", "single-frame assets hold until reload")
    hold_body = extract_function(display_c, "static void wait_for_reload_while_frozen(void)")
    require(hold_body, "BADGE_STATIC_FRAME_HOLD_POLL_MS", "frozen waits poll instead of blocking forever")
    require(hold_body, "xEventGroupSetBits(s_events, BADGE_STOPPED_BIT)", "frozen single-frame display reports stopped state for OTA pause")
    require(hold_body, "badge_display_request_refresh()", "frozen first-half frame keeps RGB panel refreshed")
    require(hold_body, "vTaskDelay(pdMS_TO_TICKS(1))", "frozen wait yields CPU time every poll")
    if "badge_display_set_static_hold_prevent_waiti" in hold_body:
        raise AssertionError("frozen wait must not change idle hook behavior")
    if "portMAX_DELAY" in hold_body:
        raise AssertionError("frozen display wait must not use portMAX_DELAY")
    first_half_block = player_body[player_body.index("first_half finished, freezing"):]
    first_half_block = first_half_block[:first_half_block.index("/* Second-half")]
    require(first_half_block, "wait_for_reload_while_frozen()", "first half freeze uses timed wait helper")
    second_half_block = player_body[player_body.index("second_half finished, no pending switch, freezing"):]
    second_half_block = second_half_block[:second_half_block.index("return ret")]
    require(second_half_block, "wait_for_reload_while_frozen()", "second half freeze uses timed wait helper")
    require(display_c, "badge_display_enter_ota_static_mode", "OTA enters a low-bandwidth static LCD mode before flash writes")
    require(display_c, "badge_display_restore_after_ota_static_mode", "OTA failure restores normal LCD timing before playback")
    require(display_c, "BADGE_OTA_LCD_PIXEL_CLOCK_HZ", "OTA has a dedicated lower RGB PCLK")
    ota_static_body = extract_function(display_c, "static void badge_display_enter_ota_static_mode")
    require(ota_static_body, "esp_lcd_rgb_panel_set_pclk(panel_handle, BADGE_OTA_LCD_PIXEL_CLOCK_HZ)", "OTA lowers RGB PCLK before flash writes")
    require(ota_static_body, "esp_lcd_rgb_panel_restart(panel_handle)", "OTA restarts RGB DMA after lowering PCLK")
    restore_static_body = extract_function(display_c, "static void badge_display_restore_after_ota_static_mode")
    require(restore_static_body, "esp_lcd_rgb_panel_set_pclk(panel_handle, EXAMPLE_LCD_PIXEL_CLOCK_HZ)", "OTA failure restores normal RGB PCLK")
    require(restore_static_body, "esp_lcd_rgb_panel_restart(panel_handle)", "OTA failure restarts RGB DMA after restoring PCLK")
    ota_screen_body = extract_function(display_c, "static void show_ota_screen(void)")
    require(ota_screen_body, "if (s_ota_screen_visible)", "OTA screen draw is idempotent")
    require(ota_screen_body, "int ota_fb = choose_static_screen_fb()", "OTA screen renders to a safe framebuffer")
    require(ota_screen_body, "for (size_t i = 0; i < BADGE_FB_COUNT; ++i)", "OTA screen pins every framebuffer to upload.png")
    require(ota_screen_body, "memcpy(s_fb[i], upload_480_rgb565_bin_start, BADGE_OTA_IMAGE_BYTES)", "OTA screen copies embedded upload image into every framebuffer")
    require(ota_screen_body, "switch_panel_to_fb(ota_fb", "OTA screen switches to the selected framebuffer")
    require(ota_screen_body, "s_ota_fb = ota_fb", "OTA framebuffer is remembered")
    require(ota_screen_body, "s_ota_screen_visible = true", "OTA screen is marked visible after first draw")
    require(ota_screen_body, 'ESP_LOGI(TAG, "OTA screen displayed', "OTA screen logs successful image display")
    if "draw_ui_text_centered" in ota_screen_body or "draw_rect_rgb565" in ota_screen_body:
        raise AssertionError("OTA screen should show upload.png, not draw the old text UI")
    pause_body = display_c[display_c.index("esp_err_t badge_display_pause_for_ota"):]
    pause_body = pause_body[:pause_body.index("void badge_display_resume_after_ota")]
    require(pause_body, "pause_player_task(timeout_ticks)", "OTA pause waits for player stop")
    require(pause_body, "badge_display_enter_ota_static_mode()", "OTA pause pins stable upload image without retiming LCD")
    require(pause_body, "show_ota_screen()", "OTA pause draws upgrade screen")
    if pause_body.index("badge_display_enter_ota_static_mode()") > pause_body.index("show_ota_screen()"):
        raise AssertionError("OTA must enter static mode before drawing upload.png and writing flash")
    resume_body = extract_function(display_c, "void badge_display_resume_after_ota(void)")
    require(resume_body, "badge_display_restore_after_ota_static_mode()", "OTA failure exits static mode before playback")
    st7701s_h = read("main/LCD_Driver/ST7701S.h")
    st7701s_c = read("main/LCD_Driver/ST7701S.c")
    require(st7701s_h, "EXAMPLE_LCD_PIXEL_CLOCK_HZ     (10 * 1000 * 1000)", "local display-first RGB LCD pixel clock")
    require(st7701s_h, "#define EXAMPLE_LCD_REFRESH_ON_DEMAND 0", "local display-first build uses continuous RGB refresh")
    if ".flags.refresh_on_demand = true" in st7701s_c:
        raise AssertionError("local display-first build must not enable RGB refresh-on-demand")
    require(st7701s_c, "esp_lcd_panel_reset(panel_handle)", "RGB panel reset before init prevents shifted scan timing")
    html = read("ProvisioningHTML.h")
    require(html, "pollConnectionStatus", "provisioning page polls actual Wi-Fi status")
    require(html, "/wifi_status", "provisioning page status endpoint")
    require(html, "clearProvisioning", "provisioning page clear button handler")
    require(html, "/clear_config", "provisioning page clear endpoint")
    require(html, "清除已保存 Wi-Fi", "provisioning page clear saved Wi-Fi button")
    if "showStatus('配网成功')" in html:
        raise AssertionError("provisioning page must not show success from fetch failure")
    if "连接成功！设备即将重启" in html:
        raise AssertionError("provisioning page must not claim success before STA gets IP")
    require(html, "设备即将重启", "provisioning success page tells user the device will restart")
    require(html, "请求已发送，正在等待设备连接路由器", "failed set_config fetch is treated as in-flight provisioning")
    if "保存配置失败，请保持连接 ESP-DotLoop-Setup 后重试" in html:
        raise AssertionError("set_config fetch can be interrupted by Wi-Fi mode changes, so the page must poll status instead of showing save failure")
    if "button_Init()" in main_c:
        raise AssertionError("GPIO0 button init must be removed")
    if "BOOT_KEY_State" in main_c:
        raise AssertionError("GPIO0 button state must not be read by main loop")
    if "WifiUpload_ClearProvisioning()" in main_c:
        raise AssertionError("main loop must not clear Wi-Fi provisioning")


if __name__ == "__main__":
    main()
