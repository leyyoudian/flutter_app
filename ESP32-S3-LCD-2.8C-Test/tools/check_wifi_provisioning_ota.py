from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8", errors="ignore")


def require(text: str, needle: str, label: str) -> None:
    if needle not in text:
        raise AssertionError(f"missing {label}: {needle}")


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

    for needle in ("otadata", "ota_0", "ota_1", "asset"):
        require(partitions, needle, "OTA partition layout")

    require(sdkdefaults, "CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE=y", "OTA rollback")
    require(cmake, "esp_https_ota", "OTA component dependency")
    require(cmake, "app_update", "app update component dependency")
    require(cmake, "json", "JSON component dependency for OTA manifest")
    require(root_cmake, 'set(PROJECT_VER "0.1.4")', "firmware project version")
    require(cmake, 'BADGE_FW_VERSION=\\"${PROJECT_VER}\\"', "firmware version comes from project version")
    if "Button_Driver/Button_Driver.c" in cmake or "Button_Driver/multi_button.c" in cmake:
        raise AssertionError("GPIO0 button driver must not be compiled for provisioning reset")

    require(wifi_c, "ProvisioningHTML.h", "provisioning HTML include")
    require(wifi_c, "WIFI_MODE_AP", "AP-only mode when no saved Wi-Fi")
    require(wifi_c, "WIFI_MODE_STA", "STA mode")
    require(wifi_c, "WIFI_MODE_APSTA", "APSTA provisioning mode")
    require(wifi_c, "wifi_event_handler", "Wi-Fi event handler")
    require(wifi_c, "start_provisioning_ap", "provisioning AP startup")
    require(wifi_c, "start_saved_sta_fallback_task", "saved Wi-Fi STA+AP fallback")
    require(wifi_c, "start_provisioning_ap(true)", "APSTA fallback for unavailable saved Wi-Fi")
    require(wifi_c, "start_provisioning_ap(false)", "AP-only mode without saved Wi-Fi")
    require(wifi_c, "handle_set_config", "set_config provisioning endpoint")
    require(wifi_c, "clear_saved_wifi_credentials", "web-triggered Wi-Fi credential erase")
    require(wifi_c, "handle_clear_config", "clear_config provisioning endpoint")
    require(wifi_c, '"/clear_config"', "clear_config endpoint")
    require(wifi_c, '"/wifi_status"', "Wi-Fi provisioning status endpoint")
    require(wifi_c, "s_sta_connecting", "STA connection progress state")
    require(wifi_c, "delayed_disable_provisioning_ap", "delayed AP shutdown after STA success")
    require(wifi_c, "captive_dns_task", "captive portal DNS task")
    require(wifi_c, "BADGE_CAPTIVE_PORTAL_URL", "captive portal redirect URL")
    require(wifi_c, "BADGE_CAPTIVE_DNS_CAPTURE_ALL_MS", "short DNS capture-all window for unknown phone probes")
    require(wifi_c, "s_captive_capture_all_until_us", "DNS capture-all expiry state")
    require(wifi_c, "WIFI_EVENT_AP_STACONNECTED", "DNS capture-all refreshes when phone joins AP")
    require(wifi_c, "captive_dns_capture_all_active", "DNS capture-all helper")
    require(wifi_c, "stop_captive_dns_capture_window", "DNS capture-all stops after portal is open")
    require(wifi_c, "request_targets_captive_host", "wildcard traffic does not prematurely stop capture-all")
    require(wifi_c, "BADGE_PROVISIONING_SUCCESS_AP_HOLD_MS 30000u", "AP stays open long enough for success polling")
    require(wifi_c, "configure_provisioning_dhcp_options", "SoftAP DHCP captive portal setup")
    require(wifi_c, "esp_netif_dhcps_stop", "SoftAP DHCP options can be changed")
    require(wifi_c, "esp_netif_dhcps_option", "SoftAP DHCP options are advertised")
    require(wifi_c, "ESP_NETIF_DOMAIN_NAME_SERVER", "SoftAP advertises ESP as DNS server")
    require(wifi_c, "ESP_NETIF_CAPTIVEPORTAL_URI", "SoftAP advertises captive portal URI")
    require(wifi_c, "esp_netif_set_dns_info", "SoftAP DNS points at captive DNS server")
    require(wifi_c, "esp_netif_dhcps_start", "SoftAP DHCP restarts after option changes")
    require(wifi_c, "httpd_uri_match_wildcard", "captive portal wildcard route")
    require(wifi_c, "config.max_uri_handlers", "enough captive portal URI slots")
    require(wifi_c, "config.max_open_sockets = 4", "HTTP sockets leave room for DNS/upload sockets")
    require(wifi_c, "config.lru_purge_enable = true", "captive portal socket LRU purge")
    require(wifi_c, "ensure_wifi_scan_mode", "scan endpoint enables STA radio before scanning")
    require(wifi_c, "esp_wifi_get_mode", "scan endpoint checks current Wi-Fi mode")
    require(wifi_c, "esp_wifi_set_mode(WIFI_MODE_APSTA)", "AP-only provisioning can scan Wi-Fi")
    require(wifi_c, "captive_dns_should_reply", "captive DNS must not hijack every domain")
    require(wifi_c, "connectivitycheck.gstatic.com", "Android captive DNS allow-list")
    require(wifi_c, "www.google.cn", "China Android captive DNS allow-list")
    require(wifi_c, "connectivitycheck.gstatic.cn", "China Android captive DNS allow-list")
    require(wifi_c, "captive.apple.com", "iOS captive DNS allow-list")
    require(wifi_c, "www.msftconnecttest.com", "Windows captive DNS allow-list")
    require(wifi_c, '"/generate_204"', "Android captive portal probe")
    require(wifi_c, '"/hotspot-detect.html"', "iOS captive portal probe")
    require(wifi_c, '"/connecttest.txt"', "Windows captive portal probe")
    require(wifi_c, "captive_probe_handler", "captive probes serve provisioning page directly")
    if '"302 Found"' in wifi_c:
        raise AssertionError("captive portal probes must not depend on HTTP redirect")
    require(wifi_c, '"/scan"', "scan endpoint")
    require(wifi_c, '"/set_config"', "set_config endpoint")
    require(wifi_c, '"/ota"', "OTA endpoint")
    require(wifi_c, "esp_https_ota", "HTTPS OTA call")
    require(wifi_c, "BADGE_FW_VERSION", "firmware version constant")
    require(wifi_c, "BADGE_OTA_MANIFEST_URL", "automatic OTA manifest URL")
    require(wifi_c, "http://60.205.122.153/api/ota/manifest?hardware=esp32s3", "public OTA manifest URL")
    require(wifi_c, "badge_display_pause_for_ota", "OTA pauses display playback without drawing upload UI")
    require(wifi_c, "badge_display_resume_after_ota", "OTA resumes display if update fails")
    require(wifi_c, "auto_ota_check_task", "automatic OTA check task")
    require(wifi_c, "start_auto_ota_check", "STA connected automatic OTA trigger")
    require(wifi_c, "cJSON_Parse", "OTA manifest JSON parsing")
    require(wifi_c, "xTaskCreate", "non-blocking Wi-Fi or OTA task")

    if "WifiUpload_ClearProvisioning" in wifi_h or "WifiUpload_ClearProvisioning" in wifi_c:
        raise AssertionError("GPIO0 clear provisioning API must be removed")
    require(display_h, "badge_display_pause_for_ota", "OTA display pause API")
    require(display_h, "badge_display_resume_after_ota", "OTA display resume API")
    require(display_c, "badge_display_pause_for_ota", "OTA display pause implementation")
    require(display_c, "badge_display_resume_after_ota", "OTA display resume implementation")
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
    if "button_Init()" in main_c:
        raise AssertionError("GPIO0 button init must be removed")
    if "BOOT_KEY_State" in main_c:
        raise AssertionError("GPIO0 button state must not be read by main loop")
    if "WifiUpload_ClearProvisioning()" in main_c:
        raise AssertionError("main loop must not clear Wi-Fi provisioning")


if __name__ == "__main__":
    main()
