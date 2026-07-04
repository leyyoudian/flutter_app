#include "WifiUpload.h"

#include <errno.h>
#include <ctype.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "BadgeAnimMgr.h"
#include "BadgeDisplay.h"
#include "BadgeStorage.h"
#include "ST7701S.h"

#include "esp_check.h"
#include "esp_err.h"
#include "esp_event.h"
#include "esp_crt_bundle.h"
#include "esp_http_client.h"
#include "esp_http_server.h"
#include "esp_https_ota.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_ota_ops.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "cJSON.h"
#include "nvs.h"
#include "nvs_flash.h"
#ifndef PROGMEM
#define PROGMEM
#endif
#include "../../ProvisioningHTML.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "lwip/inet.h"
#include "lwip/netdb.h"
#include "lwip/sockets.h"
#include "lwip/tcp.h"

#define BADGE_WIFI_SSID "ESP-DotLoop"
#define BADGE_PROVISIONING_SSID "ESP-DotLoop-Setup"
#define BADGE_WIFI_CHANNEL 6
#define BADGE_WIFI_MAX_STA 1
#define BADGE_WIFI_INACTIVE_TIME_SEC 600u
#define BADGE_WIFI_RECONNECT_DELAY_MS 5000u
#define BADGE_WIFI_NVS_NAMESPACE "wifi_cfg"
#define BADGE_WIFI_NVS_SSID "ssid"
#define BADGE_WIFI_NVS_PASS "pass"
#define BADGE_PROVISIONING_SUCCESS_AP_HOLD_MS 30000u
#define BADGE_CAPTIVE_DNS_PORT 53
#define BADGE_DNS_TASK_STACK 4096u
#define BADGE_CAPTIVE_DNS_CAPTURE_ALL_MS 90000u
#define BADGE_CAPTIVE_PORTAL_URL "http://192.168.4.1/"
#define BADGE_UPLOAD_TCP_PORT 3333
#define BADGE_TCP_UPLOAD_MAGIC 0x31505542u
#define BADGE_HTTP_UPLOAD_BUF (64u * 1024u)
#define BADGE_TCP_UPLOAD_BUF (64u * 1024u)
#define BADGE_TCP_RCVBUF_BYTES (128u * 1024u)
#define BADGE_UPLOAD_BUF_FALLBACK_BYTES (32u * 1024u)
#define BADGE_UPLOAD_BUF_MIN_BYTES (16u * 1024u)
#define BADGE_UPLOAD_WRITE_COALESCE_BYTES (64u * 1024u)
#define BADGE_UPLOAD_WRITE_COALESCE_FALLBACK_BYTES (32u * 1024u)
#define BADGE_UPLOAD_WRITE_COALESCE_MIN_BYTES (16u * 1024u)
#define BADGE_UPLOAD_DIAG_STEP_BYTES (64u * 1024u)
#define BADGE_UPLOAD_DISPLAY_STOP_TIMEOUT_MS 1500u
#define BADGE_HTTP_CRC_HEADER "X-EBAJ-CRC32"
#define BADGE_TCP_TASK_STACK 6144u
#define BADGE_TCP_TASK_PRIORITY 7u
#define BADGE_OTA_TASK_STACK 8192u
#define BADGE_OTA_URL_MAX 512u
#define BADGE_OTA_MANIFEST_MAX 2048u
#define BADGE_OTA_CHECK_DELAY_MS 5000u
#define BADGE_OTA_DISPLAY_STOP_TIMEOUT_MS 1500u
#ifndef BADGE_FW_VERSION
#define BADGE_FW_VERSION "0.0.0"
#endif
#ifndef BADGE_OTA_MANIFEST_URL
#define BADGE_OTA_MANIFEST_URL "http://60.205.122.153/api/ota/manifest?hardware=esp32s3"
#endif

static const char *TAG = "WifiUpload";
static httpd_handle_t s_httpd;
static TaskHandle_t s_tcp_upload_task;
static TaskHandle_t s_dns_task;
static esp_netif_t *s_sta_netif;
static esp_netif_t *s_ap_netif;
static bool s_wifi_started;
static bool s_sta_connected;
static bool s_sta_connecting;
static bool s_provisioning_active;
static bool s_reconnect_pending;
static bool s_ap_shutdown_pending;
static bool s_auto_ota_check_running;
static uint8_t s_last_disconnect_reason;
static char s_saved_ssid[33];
static char s_saved_pass[65];
static char s_sta_ip_text[16];
static int64_t s_captive_capture_all_until_us;
static uint32_t s_captive_dns_log_budget;

typedef struct {
    char url[BADGE_OTA_URL_MAX];
} badge_ota_request_t;

typedef struct {
    uint32_t total_size;
    uint32_t expected_crc;
    uint32_t offset;
    int64_t recv_us;
    int64_t started_us;
    const char *upload_buf_caps;
    uint8_t *coalesce;
    size_t coalesce_len;
    size_t coalesce_size;
    uint32_t next_diag_at;
} badge_upload_session_t;

static esp_err_t load_saved_wifi_credentials(void)
{
    memset(s_saved_ssid, 0, sizeof(s_saved_ssid));
    memset(s_saved_pass, 0, sizeof(s_saved_pass));

    nvs_handle_t handle = 0;
    esp_err_t ret = nvs_open(BADGE_WIFI_NVS_NAMESPACE, NVS_READONLY, &handle);
    if (ret != ESP_OK) {
        return ret;
    }

    size_t ssid_len = sizeof(s_saved_ssid);
    size_t pass_len = sizeof(s_saved_pass);
    ret = nvs_get_str(handle, BADGE_WIFI_NVS_SSID, s_saved_ssid, &ssid_len);
    if (ret == ESP_OK) {
        esp_err_t pass_ret = nvs_get_str(handle, BADGE_WIFI_NVS_PASS, s_saved_pass, &pass_len);
        if (pass_ret != ESP_OK && pass_ret != ESP_ERR_NVS_NOT_FOUND) {
            ret = pass_ret;
        }
    }
    nvs_close(handle);

    if (ret == ESP_OK && s_saved_ssid[0] == '\0') {
        ret = ESP_ERR_NVS_NOT_FOUND;
    }
    return ret;
}

static esp_err_t save_wifi_credentials(const char *ssid, const char *password)
{
    if (ssid == NULL || ssid[0] == '\0') {
        return ESP_ERR_INVALID_ARG;
    }

    nvs_handle_t handle = 0;
    esp_err_t ret = nvs_open(BADGE_WIFI_NVS_NAMESPACE, NVS_READWRITE, &handle);
    if (ret != ESP_OK) {
        return ret;
    }

    ESP_GOTO_ON_ERROR(nvs_set_str(handle, BADGE_WIFI_NVS_SSID, ssid), cleanup, TAG, "save ssid failed");
    ESP_GOTO_ON_ERROR(nvs_set_str(handle, BADGE_WIFI_NVS_PASS, password != NULL ? password : ""), cleanup, TAG, "save pass failed");
    ESP_GOTO_ON_ERROR(nvs_commit(handle), cleanup, TAG, "commit wifi credentials failed");
    snprintf(s_saved_ssid, sizeof(s_saved_ssid), "%s", ssid);
    snprintf(s_saved_pass, sizeof(s_saved_pass), "%s", password != NULL ? password : "");

cleanup:
    nvs_close(handle);
    return ret;
}

static esp_err_t clear_saved_wifi_credentials(void)
{
    nvs_handle_t handle = 0;
    esp_err_t ret = nvs_open(BADGE_WIFI_NVS_NAMESPACE, NVS_READWRITE, &handle);
    if (ret == ESP_ERR_NVS_NOT_FOUND) {
        ret = ESP_OK;
    }
    if (ret != ESP_OK) {
        return ret;
    }

    esp_err_t ssid_ret = nvs_erase_key(handle, BADGE_WIFI_NVS_SSID);
    if (ssid_ret != ESP_OK && ssid_ret != ESP_ERR_NVS_NOT_FOUND) {
        ret = ssid_ret;
    }
    esp_err_t pass_ret = nvs_erase_key(handle, BADGE_WIFI_NVS_PASS);
    if (ret == ESP_OK && pass_ret != ESP_OK && pass_ret != ESP_ERR_NVS_NOT_FOUND) {
        ret = pass_ret;
    }
    if (ret == ESP_OK) {
        ret = nvs_commit(handle);
    }
    nvs_close(handle);

    if (ret == ESP_OK) {
        memset(s_saved_ssid, 0, sizeof(s_saved_ssid));
        memset(s_saved_pass, 0, sizeof(s_saved_pass));
        s_sta_connected = false;
        s_sta_connecting = false;
        s_reconnect_pending = false;
        s_last_disconnect_reason = 0;
        s_sta_ip_text[0] = '\0';
        ESP_LOGI(TAG, "saved Wi-Fi credentials cleared from web");
    }
    return ret;
}

static esp_err_t start_sta_connect(void);
static esp_err_t start_provisioning_ap(bool with_sta);
static void start_auto_ota_check(void);

static void refresh_captive_dns_capture_window(const char *reason)
{
    s_captive_capture_all_until_us =
        esp_timer_get_time() + ((int64_t)BADGE_CAPTIVE_DNS_CAPTURE_ALL_MS * 1000);
    s_captive_dns_log_budget = 24;
    ESP_LOGI(TAG, "captive DNS capture-all enabled for %ums (%s)",
             (unsigned)BADGE_CAPTIVE_DNS_CAPTURE_ALL_MS,
             reason != NULL ? reason : "provisioning");
}

static void stop_captive_dns_capture_window(const char *reason)
{
    if (s_captive_capture_all_until_us == 0) {
        return;
    }
    s_captive_capture_all_until_us = 0;
    s_captive_dns_log_budget = 8;
    ESP_LOGI(TAG, "captive DNS capture-all stopped (%s)",
             reason != NULL ? reason : "portal active");
}

static void delayed_disable_provisioning_ap(void *arg)
{
    (void)arg;
    vTaskDelay(pdMS_TO_TICKS(BADGE_PROVISIONING_SUCCESS_AP_HOLD_MS));
    if (s_sta_connected && s_provisioning_active) {
        s_provisioning_active = false;
        (void)esp_wifi_set_mode(WIFI_MODE_STA);
        ESP_LOGI(TAG, "STA got IP; provisioning AP disabled");
    }
    s_ap_shutdown_pending = false;
    vTaskDelete(NULL);
}

static void start_saved_sta_fallback_task(void *arg)
{
    (void)arg;
    vTaskDelay(pdMS_TO_TICKS(BADGE_WIFI_RECONNECT_DELAY_MS));
    s_reconnect_pending = false;
    if (s_saved_ssid[0] != '\0') {
        if (!s_sta_connected && !s_provisioning_active) {
            ESP_LOGW(TAG, "saved STA not connected; enabling provisioning AP while STA keeps retrying");
            (void)start_provisioning_ap(true);
        }
        (void)start_sta_connect();
    }
    vTaskDelete(NULL);
}

static void delayed_restart_provisioning_ap_task(void *arg)
{
    (void)arg;
    vTaskDelay(pdMS_TO_TICKS(400));
    (void)esp_wifi_disconnect();
    esp_err_t ret = start_provisioning_ap(false);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "restart provisioning AP after clear failed: %s", esp_err_to_name(ret));
    }
    vTaskDelete(NULL);
}

static void wifi_event_handler(void *arg, esp_event_base_t event_base, int32_t event_id, void *event_data)
{
    (void)arg;

    if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_START) {
        if (s_saved_ssid[0] != '\0') {
            (void)esp_wifi_connect();
        }
    } else if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_AP_STACONNECTED) {
        refresh_captive_dns_capture_window("phone joined AP");
    } else if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_DISCONNECTED) {
        const wifi_event_sta_disconnected_t *event = (const wifi_event_sta_disconnected_t *)event_data;
        s_sta_connected = false;
        s_sta_connecting = false;
        s_sta_ip_text[0] = '\0';
        s_last_disconnect_reason = event != NULL ? event->reason : 0;
        if (s_saved_ssid[0] != '\0' && !s_reconnect_pending) {
            ESP_LOGW(TAG, "STA disconnected; reason=%u retry scheduled", (unsigned)s_last_disconnect_reason);
            if (xTaskCreate(start_saved_sta_fallback_task, "wifi_retry", 3072, NULL, 4, NULL) == pdPASS) {
                s_reconnect_pending = true;
            }
        }
    } else if (event_base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP) {
        const ip_event_got_ip_t *event = (const ip_event_got_ip_t *)event_data;
        s_sta_connected = true;
        s_sta_connecting = false;
        s_reconnect_pending = false;
        s_last_disconnect_reason = 0;
        stop_captive_dns_capture_window("STA got IP");
        if (event != NULL) {
            snprintf(s_sta_ip_text, sizeof(s_sta_ip_text), IPSTR, IP2STR(&event->ip_info.ip));
        }
        start_auto_ota_check();
        if (s_provisioning_active) {
            ESP_LOGI(TAG, "STA got IP: %s; provisioning AP will close after status page can update",
                     s_sta_ip_text);
            if (!s_ap_shutdown_pending &&
                xTaskCreate(delayed_disable_provisioning_ap, "ap_close_delay", 3072, NULL, 4, NULL) == pdPASS) {
                s_ap_shutdown_pending = true;
            }
        }
    }
}

static esp_err_t ensure_wifi_stack(void)
{
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_RETURN_ON_ERROR(nvs_flash_erase(), TAG, "nvs erase failed");
        ret = nvs_flash_init();
    }
    ESP_RETURN_ON_ERROR(ret, TAG, "nvs init failed");

    ret = esp_netif_init();
    if (ret != ESP_OK && ret != ESP_ERR_INVALID_STATE) {
        return ret;
    }

    ret = esp_event_loop_create_default();
    if (ret != ESP_OK && ret != ESP_ERR_INVALID_STATE) {
        return ret;
    }

    if (s_sta_netif == NULL) {
        s_sta_netif = esp_netif_create_default_wifi_sta();
    }
    if (s_ap_netif == NULL) {
        s_ap_netif = esp_netif_create_default_wifi_ap();
    }

    wifi_init_config_t init_cfg = WIFI_INIT_CONFIG_DEFAULT();
    ret = esp_wifi_init(&init_cfg);
    if (ret != ESP_OK && ret != ESP_ERR_INVALID_STATE) {
        return ret;
    }

    (void)esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID, &wifi_event_handler, NULL, NULL);
    (void)esp_event_handler_instance_register(IP_EVENT, IP_EVENT_STA_GOT_IP, &wifi_event_handler, NULL, NULL);

    wifi_country_t country = {
        .cc = "CN",
        .schan = 1,
        .nchan = 13,
        .policy = WIFI_COUNTRY_POLICY_MANUAL,
    };
    ESP_RETURN_ON_ERROR(esp_wifi_set_country(&country), TAG, "wifi set country failed");
    (void)esp_wifi_set_ps(WIFI_PS_NONE);
    return ESP_OK;
}

static uint16_t dns_read_u16(const uint8_t *data)
{
    return ((uint16_t)data[0] << 8) | data[1];
}

static void dns_write_u16(uint8_t *data, uint16_t value)
{
    data[0] = (uint8_t)(value >> 8);
    data[1] = (uint8_t)value;
}

static void dns_write_u32(uint8_t *data, uint32_t value)
{
    data[0] = (uint8_t)(value >> 24);
    data[1] = (uint8_t)(value >> 16);
    data[2] = (uint8_t)(value >> 8);
    data[3] = (uint8_t)value;
}

static uint32_t captive_portal_ap_addr(void)
{
    esp_netif_ip_info_t ip_info = {0};
    if (s_ap_netif != NULL &&
        esp_netif_get_ip_info(s_ap_netif, &ip_info) == ESP_OK &&
        ip_info.ip.addr != 0) {
        return ip_info.ip.addr;
    }
    return inet_addr("192.168.4.1");
}

static bool dns_name_matches_or_is_subdomain(const char *name, const char *domain)
{
    size_t name_len = strlen(name);
    size_t domain_len = strlen(domain);
    if (name_len < domain_len) {
        return false;
    }
    const char *suffix = name + name_len - domain_len;
    if (strcmp(suffix, domain) != 0) {
        return false;
    }
    return name_len == domain_len || suffix[-1] == '.';
}

static bool captive_dns_capture_all_active(void)
{
    return s_captive_capture_all_until_us > 0 &&
           esp_timer_get_time() < s_captive_capture_all_until_us;
}

static bool captive_dns_should_reply(const char *qname)
{
    static const char *const captive_domains[] = {
        "connectivitycheck.gstatic.com",
        "connectivitycheck.gstatic.cn",
        "connectivitycheck.android.com",
        "connectivitycheck.google.cn",
        "clients3.google.com",
        "www.google.com",
        "www.google.cn",
        "www.gstatic.com",
        "connect.rom.miui.com",
        "connectivitycheck.platform.hicloud.com",
        "wifi.vivo.com.cn",
        "conn1.oppomobile.com",
        "wifi.flyme.cn",
        "connectivitycheck.samsung.com",
        "captive.apple.com",
        "www.apple.com",
        "www.msftconnecttest.com",
        "msftconnecttest.com",
        "dns.msftncsi.com",
        "www.msftncsi.com",
    };

    if (qname == NULL || qname[0] == '\0') {
        return false;
    }
    if (captive_dns_capture_all_active()) {
        return true;
    }
    for (size_t i = 0; i < sizeof(captive_domains) / sizeof(captive_domains[0]); ++i) {
        if (dns_name_matches_or_is_subdomain(qname, captive_domains[i])) {
            return true;
        }
    }
    return false;
}

static size_t captive_dns_build_response(const uint8_t *request,
                                         size_t request_len,
                                         uint8_t *response,
                                         size_t response_size)
{
    if (request == NULL || response == NULL || request_len < 17 || response_size < 32) {
        return 0;
    }

    uint16_t qdcount = dns_read_u16(request + 4);
    if (qdcount == 0) {
        return 0;
    }

    size_t pos = 12;
    char qname[128] = {0};
    size_t qname_len = 0;
    while (pos < request_len && request[pos] != 0) {
        uint8_t label_len = request[pos++];
        if ((label_len & 0xc0) != 0 || label_len > 63) {
            return 0;
        }
        if (pos + label_len > request_len) {
            return 0;
        }
        if (qname_len != 0) {
            if (qname_len + 1 >= sizeof(qname)) {
                return 0;
            }
            qname[qname_len++] = '.';
        }
        for (uint8_t i = 0; i < label_len; ++i) {
            if (qname_len + 1 >= sizeof(qname)) {
                return 0;
            }
            qname[qname_len++] = (char)tolower((unsigned char)request[pos + i]);
        }
        pos += label_len;
    }
    if (pos >= request_len) {
        return 0;
    }
    qname[qname_len] = '\0';
    pos++;
    if (pos + 4 > request_len) {
        return 0;
    }

    uint16_t qtype = dns_read_u16(request + pos);
    size_t question_len = pos + 4 - 12;
    size_t response_len = 12 + question_len;
    if (response_len > response_size) {
        return 0;
    }
    bool capture_all = captive_dns_capture_all_active();
    bool should_reply = captive_dns_should_reply(qname);
    if (s_captive_dns_log_budget > 0) {
        ESP_LOGI(TAG, "captive DNS %s %s%s",
                 should_reply ? "reply" : "ignore",
                 qname,
                 capture_all ? " (capture-all)" : "");
        s_captive_dns_log_budget--;
    }
    if (!should_reply) {
        return 0;
    }
    ESP_LOGD(TAG, "captive DNS reply for %s", qname);

    memcpy(response, request, 2);
    dns_write_u16(response + 2, 0x8180);
    dns_write_u16(response + 4, 1);
    dns_write_u16(response + 6, 0);
    dns_write_u16(response + 8, 0);
    dns_write_u16(response + 10, 0);
    memcpy(response + 12, request + 12, question_len);

    if (qtype != 1 && qtype != 255) {
        return response_len;
    }
    if (response_len + 16 > response_size) {
        return 0;
    }

    dns_write_u16(response + 6, 1);
    response[response_len++] = 0xc0;
    response[response_len++] = 0x0c;
    dns_write_u16(response + response_len, 1);
    response_len += 2;
    dns_write_u16(response + response_len, 1);
    response_len += 2;
    dns_write_u32(response + response_len, 30);
    response_len += 4;
    dns_write_u16(response + response_len, 4);
    response_len += 2;
    uint32_t ap_addr = captive_portal_ap_addr();
    memcpy(response + response_len, &ap_addr, sizeof(ap_addr));
    response_len += sizeof(ap_addr);
    return response_len;
}

static void captive_dns_task(void *arg)
{
    (void)arg;

    int sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_IP);
    if (sock < 0) {
        ESP_LOGE(TAG, "captive DNS socket failed: errno=%d", errno);
        s_dns_task = NULL;
        vTaskDelete(NULL);
        return;
    }

    int reuse = 1;
    (void)setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    struct sockaddr_in listen_addr = {
        .sin_family = AF_INET,
        .sin_port = htons(BADGE_CAPTIVE_DNS_PORT),
        .sin_addr.s_addr = htonl(INADDR_ANY),
    };
    if (bind(sock, (struct sockaddr *)&listen_addr, sizeof(listen_addr)) != 0) {
        ESP_LOGE(TAG, "captive DNS bind failed: errno=%d", errno);
        close(sock);
        s_dns_task = NULL;
        vTaskDelete(NULL);
        return;
    }

    ESP_LOGI(TAG, "captive DNS listening on udp/%u", BADGE_CAPTIVE_DNS_PORT);
    uint8_t request[512];
    uint8_t response[576];
    while (1) {
        struct sockaddr_storage source_addr = {0};
        socklen_t addr_len = sizeof(source_addr);
        int received = recvfrom(sock, request, sizeof(request), 0,
                                (struct sockaddr *)&source_addr, &addr_len);
        if (received <= 0) {
            continue;
        }
        if (!s_provisioning_active) {
            continue;
        }

        size_t response_len = captive_dns_build_response(request,
                                                         (size_t)received,
                                                         response,
                                                         sizeof(response));
        if (response_len == 0) {
            continue;
        }
        (void)sendto(sock, response, response_len, 0,
                     (struct sockaddr *)&source_addr, addr_len);
    }
}

static esp_err_t start_captive_dns_server(void)
{
    if (s_dns_task != NULL) {
        return ESP_OK;
    }
    if (xTaskCreate(captive_dns_task, "captive_dns", BADGE_DNS_TASK_STACK, NULL, 4, &s_dns_task) != pdPASS) {
        return ESP_ERR_NO_MEM;
    }
    return ESP_OK;
}

static esp_err_t configure_provisioning_dhcp_options(void)
{
    if (s_ap_netif == NULL) {
        return ESP_ERR_INVALID_STATE;
    }

    esp_netif_ip_info_t ip_info = {0};
    esp_err_t ret = esp_netif_get_ip_info(s_ap_netif, &ip_info);
    if (ret != ESP_OK || ip_info.ip.addr == 0) {
        ip_info.ip.addr = inet_addr("192.168.4.1");
    }

    ret = esp_netif_dhcps_stop(s_ap_netif);
    if (ret != ESP_OK && ret != ESP_ERR_ESP_NETIF_DHCP_ALREADY_STOPPED) {
        return ret;
    }

    uint8_t offer_dns = 1;
    esp_netif_dns_info_t dns = {
        .ip = {
            .u_addr = {
                .ip4 = {
                    .addr = ip_info.ip.addr,
                },
            },
            .type = ESP_IPADDR_TYPE_V4,
        },
    };
    ESP_RETURN_ON_ERROR(esp_netif_dhcps_option(s_ap_netif,
                                               ESP_NETIF_OP_SET,
                                               ESP_NETIF_DOMAIN_NAME_SERVER,
                                               &offer_dns,
                                               sizeof(offer_dns)),
                        TAG, "set DHCP DNS offer failed");
    ESP_RETURN_ON_ERROR(esp_netif_set_dns_info(s_ap_netif, ESP_NETIF_DNS_MAIN, &dns),
                        TAG, "set AP DNS failed");

    static char captive_uri[] = BADGE_CAPTIVE_PORTAL_URL;
    ESP_RETURN_ON_ERROR(esp_netif_dhcps_option(s_ap_netif,
                                               ESP_NETIF_OP_SET,
                                               ESP_NETIF_CAPTIVEPORTAL_URI,
                                               captive_uri,
                                               strlen(captive_uri)),
                        TAG, "set DHCP captive portal URI failed");

    ret = esp_netif_dhcps_start(s_ap_netif);
    if (ret != ESP_OK && ret != ESP_ERR_ESP_NETIF_DHCP_ALREADY_STARTED) {
        return ret;
    }

    ESP_LOGI(TAG, "Provisioning DHCP advertises DNS/captive portal at " IPSTR,
             IP2STR(&ip_info.ip));
    return ESP_OK;
}

static esp_err_t start_provisioning_ap(bool with_sta)
{
    wifi_config_t wifi_config = {0};
    snprintf((char *)wifi_config.ap.ssid, sizeof(wifi_config.ap.ssid), "%s", BADGE_PROVISIONING_SSID);
    wifi_config.ap.ssid_len = strlen(BADGE_PROVISIONING_SSID);
    wifi_config.ap.channel = BADGE_WIFI_CHANNEL;
    wifi_config.ap.max_connection = BADGE_WIFI_MAX_STA;
    wifi_config.ap.authmode = WIFI_AUTH_OPEN;
    wifi_config.ap.ssid_hidden = 0;
    wifi_config.ap.beacon_interval = 100;
    wifi_config.ap.pmf_cfg.required = false;

    ESP_RETURN_ON_ERROR(esp_wifi_set_mode(with_sta ? WIFI_MODE_APSTA : WIFI_MODE_AP),
                        TAG, "wifi AP mode failed");
    ESP_RETURN_ON_ERROR(esp_wifi_set_config(WIFI_IF_AP, &wifi_config), TAG, "wifi AP config failed");
    ESP_RETURN_ON_ERROR(esp_wifi_set_protocol(WIFI_IF_AP, WIFI_PROTOCOL_11B | WIFI_PROTOCOL_11G | WIFI_PROTOCOL_11N),
                        TAG, "wifi AP protocol failed");

    (void)esp_wifi_set_bandwidth(WIFI_IF_AP, WIFI_BW_HT20);
    (void)esp_wifi_set_max_tx_power(78);
    if (!s_wifi_started) {
        ESP_RETURN_ON_ERROR(esp_wifi_start(), TAG, "wifi start failed");
        s_wifi_started = true;
    }
    esp_err_t ret = esp_wifi_set_inactive_time(WIFI_IF_AP, BADGE_WIFI_INACTIVE_TIME_SEC);
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "wifi inactive time config failed: %s", esp_err_to_name(ret));
    }

    ESP_RETURN_ON_ERROR(configure_provisioning_dhcp_options(), TAG, "DHCP captive options failed");
    s_provisioning_active = true;
    refresh_captive_dns_capture_window("provisioning AP started");
    esp_err_t dns_ret = start_captive_dns_server();
    if (dns_ret != ESP_OK) {
        ESP_LOGW(TAG, "captive DNS start failed: %s", esp_err_to_name(dns_ret));
    }
    ESP_LOGI(TAG, "Provisioning AP ready: ssid=%s mode=%s http://192.168.4.1/",
             BADGE_PROVISIONING_SSID,
             with_sta ? "APSTA" : "AP");
    return ESP_OK;
}

static esp_err_t start_sta_connect(void)
{
    if (s_saved_ssid[0] == '\0') {
        return ESP_ERR_INVALID_STATE;
    }

    wifi_config_t sta_config = {0};
    size_t ssid_len = strnlen(s_saved_ssid, sizeof(s_saved_ssid));
    if (ssid_len > sizeof(sta_config.sta.ssid)) {
        ssid_len = sizeof(sta_config.sta.ssid);
    }
    memcpy(sta_config.sta.ssid, s_saved_ssid, ssid_len);
    size_t pass_len = strnlen(s_saved_pass, sizeof(s_saved_pass));
    if (pass_len > sizeof(sta_config.sta.password)) {
        pass_len = sizeof(sta_config.sta.password);
    }
    memcpy(sta_config.sta.password, s_saved_pass, pass_len);
    sta_config.sta.threshold.authmode = WIFI_AUTH_OPEN;

    s_sta_connected = false;
    s_sta_connecting = true;
    s_last_disconnect_reason = 0;
    s_sta_ip_text[0] = '\0';
    ESP_RETURN_ON_ERROR(esp_wifi_set_mode(s_provisioning_active ? WIFI_MODE_APSTA : WIFI_MODE_STA), TAG, "STA mode failed");
    ESP_RETURN_ON_ERROR(esp_wifi_set_config(WIFI_IF_STA, &sta_config), TAG, "STA config failed");
    if (!s_wifi_started) {
        ESP_RETURN_ON_ERROR(esp_wifi_start(), TAG, "wifi start failed");
        s_wifi_started = true;
    }
    (void)esp_wifi_connect();
    ESP_LOGI(TAG, "STA connect started: ssid=%s", s_saved_ssid);
    return ESP_OK;
}

static esp_err_t start_wifi_service(void)
{
    ESP_RETURN_ON_ERROR(ensure_wifi_stack(), TAG, "wifi stack failed");

    if (load_saved_wifi_credentials() == ESP_OK) {
        ESP_LOGI(TAG, "saved STA credentials found; connecting without blocking display");
        esp_err_t ret = start_sta_connect();
        if (ret == ESP_OK) {
            return ESP_OK;
        }
        ESP_LOGW(TAG, "saved STA connect start failed; falling back to APSTA provisioning: %s", esp_err_to_name(ret));
        return start_provisioning_ap(true);
    }

    ESP_LOGI(TAG, "no saved STA credentials; starting AP-only provisioning");
    return start_provisioning_ap(false);
}

static uint32_t read_le32(const uint8_t *data)
{
    return (uint32_t)data[0] |
           ((uint32_t)data[1] << 8) |
           ((uint32_t)data[2] << 16) |
           ((uint32_t)data[3] << 24);
}

static uint8_t *alloc_upload_buffer_exact(size_t size, bool try_spiram)
{
    uint8_t *buffer = heap_caps_malloc(size, MALLOC_CAP_INTERNAL | MALLOC_CAP_DMA | MALLOC_CAP_8BIT);
    if (buffer != NULL) {
        return buffer;
    }

    buffer = heap_caps_malloc(size, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
    if (buffer == NULL && try_spiram) {
        buffer = heap_caps_malloc(size, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    }
    return buffer;
}

static uint8_t *alloc_upload_buffer(size_t preferred_size, size_t *out_size)
{
    const size_t candidates[] = {
        preferred_size,
        BADGE_UPLOAD_BUF_FALLBACK_BYTES,
        BADGE_UPLOAD_BUF_MIN_BYTES,
    };

    for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); ++i) {
        size_t size = candidates[i];
        if (i > 0 && size >= preferred_size) {
            continue;
        }

        uint8_t *buffer = alloc_upload_buffer_exact(size, false);
        if (buffer != NULL) {
            if (out_size != NULL) {
                *out_size = size;
            }
            return buffer;
        }
    }

    for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); ++i) {
        size_t size = candidates[i];
        if (i > 0 && size >= preferred_size) {
            continue;
        }

        uint8_t *buffer = alloc_upload_buffer_exact(size, true);
        if (buffer != NULL) {
            if (out_size != NULL) {
                *out_size = size;
            }
            return buffer;
        }
    }

    if (out_size != NULL) {
        *out_size = 0;
    }
    return NULL;
}

static const char *upload_buffer_caps(const void *buffer)
{
    if (buffer == NULL) {
        return "none";
    }
    if (esp_ptr_internal(buffer) && esp_ptr_dma_capable(buffer)) {
        return "internal_dma";
    }
    if (esp_ptr_internal(buffer)) {
        return "internal";
    }
    return "spiram";
}

static uint32_t upload_speed_mbps_x100(uint32_t total_size, int64_t elapsed_us)
{
    uint32_t mbps_x100 = 0;
    if (elapsed_us > 0) {
        mbps_x100 = (uint32_t)(((uint64_t)total_size * 100u * 1000000u) /
                               ((uint64_t)elapsed_us * 1024u * 1024u));
    }
    return mbps_x100;
}

static esp_err_t begin_upload_session(badge_upload_session_t *session,
                                      uint32_t total_size,
                                      uint32_t expected_crc)
{
    if (session == NULL || total_size == 0) {
        return ESP_ERR_INVALID_ARG;
    }

    memset(session, 0, sizeof(*session));
    session->total_size = total_size;
    session->expected_crc = expected_crc;
    session->started_us = esp_timer_get_time();
    session->next_diag_at = BADGE_UPLOAD_DIAG_STEP_BYTES;

    esp_err_t ret = badge_display_enter_upload_mode(pdMS_TO_TICKS(BADGE_UPLOAD_DISPLAY_STOP_TIMEOUT_MS));
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "display upload mode timeout: %s", esp_err_to_name(ret));
    }

    ret = badge_storage_begin_upload(total_size, expected_crc);
    if (ret != ESP_OK) {
        badge_display_exit_upload_mode();
    }
    return ret;
}

static esp_err_t write_upload_session(badge_upload_session_t *session, const uint8_t *data, size_t len)
{
    if (session == NULL || data == NULL || len == 0) {
        return ESP_ERR_INVALID_ARG;
    }

    esp_err_t ret = badge_storage_write_chunk(session->offset, data, len);
    if (ret == ESP_OK) {
        session->offset += (uint32_t)len;
    }
    return ret;
}

static esp_err_t flush_upload_coalesce(badge_upload_session_t *session)
{
    if (session == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    if (session->coalesce_len == 0) {
        return ESP_OK;
    }

    esp_err_t ret = write_upload_session(session, session->coalesce, session->coalesce_len);
    if (ret == ESP_OK) {
        session->coalesce_len = 0;
    }
    return ret;
}

static esp_err_t write_upload_direct(badge_upload_session_t *session, const uint8_t *data, size_t len)
{
    const uint8_t *src = data;
    size_t remaining = len;

    while (remaining > 0) {
        size_t chunk = remaining;
        if (chunk > BADGE_UPLOAD_WRITE_COALESCE_MIN_BYTES) {
            chunk = BADGE_UPLOAD_WRITE_COALESCE_MIN_BYTES;
        }

        esp_err_t ret = write_upload_session(session, src, chunk);
        if (ret != ESP_OK) {
            return ret;
        }
        src += chunk;
        remaining -= chunk;
    }
    return ESP_OK;
}

static esp_err_t append_upload_data(badge_upload_session_t *session, const uint8_t *data, size_t len)
{
    if (session == NULL || data == NULL || len == 0) {
        return ESP_ERR_INVALID_ARG;
    }

    const uint8_t *src = data;
    size_t remaining = len;
    while (remaining > 0) {
        if (session->coalesce == NULL || session->coalesce_size == 0) {
            return write_upload_direct(session, src, remaining);
        }

        size_t free_len = session->coalesce_size - session->coalesce_len;
        size_t chunk = remaining > free_len ? free_len : remaining;
        memcpy(session->coalesce + session->coalesce_len, src, chunk);
        session->coalesce_len += chunk;
        src += chunk;
        remaining -= chunk;

        if (session->coalesce_len == session->coalesce_size) {
            esp_err_t ret = flush_upload_coalesce(session);
            if (ret != ESP_OK) {
                return ret;
            }
        }
    }
    return ESP_OK;
}

static void log_upload_chunk_diag(badge_upload_session_t *session,
                                  const char *transport,
                                  int received,
                                  int64_t chunk_recv_us,
                                  int64_t chunk_append_us,
                                  uint32_t remaining)
{
    if (session == NULL || transport == NULL) {
        return;
    }
    if (session->offset < session->next_diag_at && remaining != 0) {
        return;
    }

    badge_upload_perf_t perf = {0};
    badge_storage_get_last_upload_perf(&perf);
    int64_t elapsed_us = esp_timer_get_time() - session->started_us;
    uint32_t mbps_x100 = upload_speed_mbps_x100(session->offset, elapsed_us);
    ESP_LOGI(TAG,
             "%s upload chunk offset=%" PRIu32 "/%" PRIu32 " recv_len=%d recv=%lldms append=%lldms total_recv=%lldms total_write=%lldms elapsed=%lldms mbps_x100=%" PRIu32,
             transport,
             session->offset,
             session->total_size,
             received,
             (long long)(chunk_recv_us / 1000),
             (long long)(chunk_append_us / 1000),
             (long long)(session->recv_us / 1000),
             (long long)(perf.storage_write_us / 1000),
             (long long)(elapsed_us / 1000),
             mbps_x100);
    while (session->next_diag_at <= session->offset) {
        session->next_diag_at += BADGE_UPLOAD_DIAG_STEP_BYTES;
    }
}

static esp_err_t finish_upload_session(badge_upload_session_t *session, const char *transport)
{
    esp_err_t ret = badge_storage_finish_upload();
    if (ret != ESP_OK) {
        badge_storage_abort_upload();
        badge_display_exit_upload_mode();
        return ret;
    }

    badge_display_exit_upload_mode();
    /* Give the player task a chance to start before we block on recv. */
    vTaskDelay(pdMS_TO_TICKS(10));
    badge_upload_perf_t perf = {0};
    badge_storage_get_last_upload_perf(&perf);
    int64_t total_us = session->recv_us + perf.storage_write_us + perf.crc_us + perf.finish_us;
    uint32_t mbps_x100 = upload_speed_mbps_x100(session->total_size, total_us);
    ESP_LOGI(TAG,
             "%s upload complete, size=%" PRIu32 " storage=sd recv=%lldms write=%lldms crc=%lldms finish=%lldms speed=%" PRIu32 ".%02" PRIu32 "MB/s mbps_x100=%" PRIu32,
             transport,
             session->total_size,
             (long long)(session->recv_us / 1000),
             (long long)(perf.storage_write_us / 1000),
             (long long)(perf.crc_us / 1000),
             (long long)(perf.finish_us / 1000),
             mbps_x100 / 100u,
             mbps_x100 % 100u,
             mbps_x100);
    ESP_LOGI(TAG, "%s upload_buf_caps=%s",
             transport,
             session->upload_buf_caps != NULL ? session->upload_buf_caps : "unknown");
    ESP_LOGI(TAG, "%s coalesce=%u",
             transport,
             (unsigned)session->coalesce_size);
    return ESP_OK;
}

static void abort_upload_session(void)
{
    badge_storage_abort_upload();
    badge_display_exit_upload_mode();
}

static esp_err_t alloc_upload_session_buffers(badge_upload_session_t *session)
{
    if (session == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    const size_t candidates[] = {
        BADGE_UPLOAD_WRITE_COALESCE_BYTES,
        BADGE_UPLOAD_WRITE_COALESCE_FALLBACK_BYTES,
        BADGE_UPLOAD_WRITE_COALESCE_MIN_BYTES,
    };

    for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); ++i) {
        size_t size = candidates[i];
        session->coalesce = heap_caps_malloc(size, MALLOC_CAP_INTERNAL | MALLOC_CAP_DMA | MALLOC_CAP_8BIT);
        if (session->coalesce == NULL) {
            session->coalesce = heap_caps_malloc(size, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
        }
        if (session->coalesce != NULL) {
            session->coalesce_size = size;
            ESP_LOGI(TAG, "upload coalesce=%u caps=%s", (unsigned)size, upload_buffer_caps(session->coalesce));
            return ESP_OK;
        }
    }

    session->coalesce_size = 0;
    ESP_LOGW(TAG, "upload coalesce disabled, writing chunks directly");
    return ESP_OK;
}

static void free_upload_session_buffers(badge_upload_session_t *session)
{
    if (session == NULL) {
        return;
    }
    if (session->coalesce != NULL) {
        heap_caps_free(session->coalesce);
        session->coalesce = NULL;
    }
    session->coalesce_len = 0;
    session->coalesce_size = 0;
}

static esp_err_t parse_crc_header(httpd_req_t *req, uint32_t *out_crc)
{
    char value[16] = {0};
    if (httpd_req_get_hdr_value_str(req, BADGE_HTTP_CRC_HEADER, value, sizeof(value)) != ESP_OK) {
        return ESP_ERR_NOT_FOUND;
    }

    errno = 0;
    char *end = NULL;
    unsigned long parsed = strtoul(value, &end, 16);
    if (errno != 0 || end == value || *end != '\0' || parsed > UINT32_MAX) {
        return ESP_ERR_INVALID_ARG;
    }

    *out_crc = (uint32_t)parsed;
    return ESP_OK;
}

static esp_err_t status_handler(httpd_req_t *req)
{
    char status[96] = {0};
    badge_storage_get_status(status, sizeof(status));
    httpd_resp_set_type(req, "text/plain");
    return httpd_resp_send(req, status, HTTPD_RESP_USE_STRLEN);
}

static esp_err_t brightness_handler(httpd_req_t *req)
{
    char query[64] = {0};
    char value_text[8] = {0};
    esp_err_t ret = httpd_req_get_url_query_str(req, query, sizeof(query));
    if (ret != ESP_OK ||
        httpd_query_key_value(query, "value", value_text, sizeof(value_text)) != ESP_OK) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "missing value");
        return ESP_FAIL;
    }

    char *end = NULL;
    errno = 0;
    long value = strtol(value_text, &end, 10);
    if (errno != 0 || end == value_text || *end != '\0') {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "invalid value");
        return ESP_FAIL;
    }

    if (value < 0) {
        value = 0;
    } else if (value > 100) {
        value = 100;
    }

    Set_Backlight((uint8_t)value);

    char response[32] = {0};
    snprintf(response, sizeof(response), "OK brightness %ld", value);
    httpd_resp_set_type(req, "text/plain");
    return httpd_resp_send(req, response, HTTPD_RESP_USE_STRLEN);
}

static bool request_targets_captive_host(httpd_req_t *req)
{
    char host[96] = {0};
    if (httpd_req_get_hdr_value_str(req, "Host", host, sizeof(host)) != ESP_OK || host[0] == '\0') {
        return true;
    }
    return strncmp(host, "192.168.4.1", strlen("192.168.4.1")) == 0 ||
           strncmp(host, "esp-dotloop", strlen("esp-dotloop")) == 0 ||
           strncmp(host, "ESP-DotLoop", strlen("ESP-DotLoop")) == 0;
}

static esp_err_t provisioning_root_handler(httpd_req_t *req)
{
    if (request_targets_captive_host(req)) {
        stop_captive_dns_capture_window("portal page opened");
    }
    httpd_resp_set_hdr(req, "Cache-Control", "no-store");
    httpd_resp_set_type(req, "text/html; charset=utf-8");
    return httpd_resp_send(req, WIFI_PROVISIONING_HTML, HTTPD_RESP_USE_STRLEN);
}

static esp_err_t captive_probe_handler(httpd_req_t *req)
{
    char host[96] = {0};
    (void)httpd_req_get_hdr_value_str(req, "Host", host, sizeof(host));
    ESP_LOGI(TAG, "captive probe uri=%s host=%s", req->uri, host[0] != '\0' ? host : "-");
    stop_captive_dns_capture_window("captive probe served");

    httpd_resp_set_status(req, "200 OK");
    httpd_resp_set_hdr(req, "Cache-Control", "no-store");
    httpd_resp_set_hdr(req, "Pragma", "no-cache");
    httpd_resp_set_type(req, "text/html; charset=utf-8");
    return httpd_resp_send(req, WIFI_PROVISIONING_HTML, HTTPD_RESP_USE_STRLEN);
}

static int hex_digit_value(char ch)
{
    if (ch >= '0' && ch <= '9') {
        return ch - '0';
    }
    ch = (char)tolower((unsigned char)ch);
    if (ch >= 'a' && ch <= 'f') {
        return ch - 'a' + 10;
    }
    return -1;
}

static void url_decode_in_place(char *value)
{
    if (value == NULL) {
        return;
    }

    char *src = value;
    char *dst = value;
    while (*src != '\0') {
        if (*src == '+') {
            *dst++ = ' ';
            src++;
        } else if (*src == '%' && src[1] != '\0' && src[2] != '\0') {
            int high = hex_digit_value(src[1]);
            int low = hex_digit_value(src[2]);
            if (high >= 0 && low >= 0) {
                *dst++ = (char)((high << 4) | low);
                src += 3;
            } else {
                *dst++ = *src++;
            }
        } else {
            *dst++ = *src++;
        }
    }
    *dst = '\0';
}

static size_t append_json_escaped(char *dst, size_t dst_size, size_t used, const char *src)
{
    if (dst == NULL || dst_size == 0 || used >= dst_size) {
        return used;
    }
    for (const unsigned char *p = (const unsigned char *)src; p != NULL && *p != '\0'; ++p) {
        if (used + 2 >= dst_size) {
            break;
        }
        if (*p == '"' || *p == '\\') {
            dst[used++] = '\\';
            dst[used++] = (char)*p;
        } else if (*p >= 0x20) {
            dst[used++] = (char)*p;
        }
    }
    dst[used] = '\0';
    return used;
}

static esp_err_t ensure_wifi_scan_mode(void)
{
    wifi_mode_t mode = WIFI_MODE_NULL;
    esp_err_t ret = esp_wifi_get_mode(&mode);
    if (ret != ESP_OK) {
        return ret;
    }
    if (mode == WIFI_MODE_AP) {
        ESP_LOGI(TAG, "scan requested in AP mode; enabling APSTA for scan");
        return esp_wifi_set_mode(WIFI_MODE_APSTA);
    }
    return ESP_OK;
}

static esp_err_t scan_handler(httpd_req_t *req)
{
    (void)req;

    wifi_scan_config_t scan_config = {
        .ssid = NULL,
        .bssid = NULL,
        .channel = 0,
        .show_hidden = false,
        .scan_type = WIFI_SCAN_TYPE_ACTIVE,
    };

    esp_err_t ret = ensure_wifi_scan_mode();
    if (ret == ESP_OK) {
        ret = esp_wifi_scan_start(&scan_config, true);
    }
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "wifi scan failed: %s", esp_err_to_name(ret));
        httpd_resp_set_type(req, "application/json");
        return httpd_resp_sendstr(req, "{\"success\":false,\"message\":\"scan failed\"}");
    }

    wifi_ap_record_t records[16] = {0};
    uint16_t count = sizeof(records) / sizeof(records[0]);
    ESP_RETURN_ON_ERROR(esp_wifi_scan_get_ap_records(&count, records), TAG, "wifi scan records failed");

    char response[2048] = {0};
    size_t used = snprintf(response, sizeof(response),
                           "{\"success\":true,\"status\":\"completed\",\"data\":[");
    bool first = true;
    for (uint16_t i = 0; i < count; ++i) {
        if (records[i].ssid[0] == '\0') {
            continue;
        }
        int wrote = snprintf(response + used, sizeof(response) - used,
                             "%s{\"ssid\":\"",
                             first ? "" : ",");
        if (wrote < 0 || (size_t)wrote >= sizeof(response) - used) {
            break;
        }
        used += (size_t)wrote;
        used = append_json_escaped(response, sizeof(response), used, (const char *)records[i].ssid);
        wrote = snprintf(response + used, sizeof(response) - used,
                         "\",\"rssi\":%d,\"channel\":%u}",
                         records[i].rssi,
                         records[i].primary);
        if (wrote < 0 || (size_t)wrote >= sizeof(response) - used) {
            break;
        }
        used += (size_t)wrote;
        first = false;
    }
    snprintf(response + used, sizeof(response) - used, "]}");

    httpd_resp_set_type(req, "application/json");
    return httpd_resp_send(req, response, HTTPD_RESP_USE_STRLEN);
}

static esp_err_t handle_set_config(httpd_req_t *req)
{
    char query[256] = {0};
    char ssid[33] = {0};
    char password[65] = {0};

    esp_err_t ret = httpd_req_get_url_query_str(req, query, sizeof(query));
    if (ret != ESP_OK ||
        httpd_query_key_value(query, "wifi_name", ssid, sizeof(ssid)) != ESP_OK) {
        httpd_resp_set_type(req, "application/json");
        httpd_resp_sendstr(req, "{\"success\":false,\"message\":\"missing wifi_name\"}");
        return ESP_FAIL;
    }
    (void)httpd_query_key_value(query, "wifi_pwd", password, sizeof(password));
    url_decode_in_place(ssid);
    url_decode_in_place(password);

    stop_captive_dns_capture_window("Wi-Fi config submitted");
    ret = save_wifi_credentials(ssid, password);
    if (ret == ESP_OK) {
        ret = start_sta_connect();
    }
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "set wifi credentials failed: %s", esp_err_to_name(ret));
        httpd_resp_set_type(req, "application/json");
        httpd_resp_sendstr(req, "{\"success\":false,\"message\":\"connect start failed\"}");
        return ESP_FAIL;
    }

    httpd_resp_set_type(req, "application/json");
    return httpd_resp_sendstr(req, "{\"success\":true,\"message\":\"connect_started\"}");
}

static esp_err_t handle_clear_config(httpd_req_t *req)
{
    esp_err_t ret = clear_saved_wifi_credentials();
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "clear wifi credentials failed: %s", esp_err_to_name(ret));
        httpd_resp_set_type(req, "application/json");
        httpd_resp_sendstr(req, "{\"success\":false,\"message\":\"clear failed\"}");
        return ESP_FAIL;
    }

    if (xTaskCreate(delayed_restart_provisioning_ap_task,
                    "wifi_clear_ap",
                    3072,
                    NULL,
                    4,
                    NULL) != pdPASS) {
        httpd_resp_set_type(req, "application/json");
        httpd_resp_sendstr(req, "{\"success\":false,\"message\":\"restart ap failed\"}");
        return ESP_FAIL;
    }

    httpd_resp_set_type(req, "application/json");
    return httpd_resp_sendstr(req, "{\"success\":true,\"message\":\"cleared\"}");
}

static esp_err_t wifi_status_handler(httpd_req_t *req)
{
    char response[256] = {0};
    char escaped_ssid[80] = {0};
    (void)append_json_escaped(escaped_ssid, sizeof(escaped_ssid), 0, s_saved_ssid);
    snprintf(response,
             sizeof(response),
             "{\"success\":true,\"connected\":%s,\"connecting\":%s,\"provisioning\":%s,\"ssid\":\"%s\",\"ip\":\"%s\",\"reason\":%u}",
             s_sta_connected ? "true" : "false",
             (s_sta_connecting || s_reconnect_pending) ? "true" : "false",
             s_provisioning_active ? "true" : "false",
             escaped_ssid,
             s_sta_ip_text,
             (unsigned)s_last_disconnect_reason);
    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Cache-Control", "no-store");
    return httpd_resp_send(req, response, HTTPD_RESP_USE_STRLEN);
}

static int ota_parse_version_part(const char **cursor)
{
    int value = 0;
    const char *p = *cursor;
    while (*p != '\0' && !isdigit((unsigned char)*p)) {
        p++;
    }
    while (*p != '\0' && isdigit((unsigned char)*p)) {
        value = (value * 10) + (*p - '0');
        p++;
    }
    if (*p == '.') {
        p++;
    }
    *cursor = p;
    return value;
}

static bool ota_version_is_newer(const char *remote, const char *current)
{
    if (remote == NULL || current == NULL || remote[0] == '\0') {
        return false;
    }
    const char *left = remote;
    const char *right = current;
    for (int i = 0; i < 4; i++) {
        int l = ota_parse_version_part(&left);
        int r = ota_parse_version_part(&right);
        if (l != r) {
            return l > r;
        }
    }
    return false;
}

static esp_err_t fetch_ota_manifest(char *buffer, size_t buffer_size)
{
    if (buffer == NULL || buffer_size < 2) {
        return ESP_ERR_INVALID_ARG;
    }

    esp_http_client_config_t config = {
        .url = BADGE_OTA_MANIFEST_URL,
        .timeout_ms = 10000,
        .keep_alive_enable = true,
        .crt_bundle_attach = esp_crt_bundle_attach,
    };
    esp_http_client_handle_t client = esp_http_client_init(&config);
    if (client == NULL) {
        return ESP_ERR_NO_MEM;
    }

    esp_err_t ret = esp_http_client_open(client, 0);
    if (ret != ESP_OK) {
        esp_http_client_cleanup(client);
        return ret;
    }

    (void)esp_http_client_fetch_headers(client);
    int status = esp_http_client_get_status_code(client);
    if (status != 200) {
        ESP_LOGW(TAG, "OTA manifest HTTP status=%d", status);
        esp_http_client_close(client);
        esp_http_client_cleanup(client);
        return ESP_FAIL;
    }

    int total = 0;
    while (total < (int)buffer_size - 1) {
        int read_len = esp_http_client_read(client, buffer + total, (int)buffer_size - 1 - total);
        if (read_len < 0) {
            ret = ESP_FAIL;
            break;
        }
        if (read_len == 0) {
            break;
        }
        total += read_len;
    }
    buffer[total] = '\0';
    esp_http_client_close(client);
    esp_http_client_cleanup(client);
    return (ret == ESP_OK && total > 0) ? ESP_OK : ESP_FAIL;
}

static bool parse_ota_manifest(const char *json_text,
                               char *version,
                               size_t version_size,
                               char *url,
                               size_t url_size)
{
    cJSON *root = cJSON_Parse(json_text);
    if (root == NULL) {
        return false;
    }
    const cJSON *version_item = cJSON_GetObjectItem(root, "version");
    const cJSON *url_item = cJSON_GetObjectItem(root, "url");
    bool ok = cJSON_IsString(version_item) &&
              version_item->valuestring != NULL &&
              cJSON_IsString(url_item) &&
              url_item->valuestring != NULL &&
              (strncmp(url_item->valuestring, "https://", 8) == 0 ||
               strncmp(url_item->valuestring, "http://", 7) == 0);
    if (ok) {
        snprintf(version, version_size, "%s", version_item->valuestring);
        snprintf(url, url_size, "%s", url_item->valuestring);
    }
    cJSON_Delete(root);
    return ok;
}

static void ota_update_task(void *arg)
{
    badge_ota_request_t *request = (badge_ota_request_t *)arg;
    ESP_LOGI(TAG, "OTA update starting: %s", request->url);

    bool display_paused = false;
    esp_err_t display_ret = badge_display_pause_for_ota(pdMS_TO_TICKS(BADGE_OTA_DISPLAY_STOP_TIMEOUT_MS));
    if (display_ret == ESP_OK) {
        display_paused = true;
        ESP_LOGI(TAG, "display playback paused for OTA");
    } else {
        ESP_LOGW(TAG, "display pause for OTA failed: %s", esp_err_to_name(display_ret));
    }

    esp_http_client_config_t http_config = {
        .url = request->url,
        .timeout_ms = 15000,
        .keep_alive_enable = true,
        .crt_bundle_attach = esp_crt_bundle_attach,
    };
    esp_https_ota_config_t ota_config = {
        .http_config = &http_config,
    };

    esp_err_t ret = esp_https_ota(&ota_config);
    if (ret == ESP_OK) {
        ESP_LOGI(TAG, "OTA update complete; restarting");
        free(request);
        esp_restart();
    }

    ESP_LOGE(TAG, "OTA update failed: %s", esp_err_to_name(ret));
    if (display_paused) {
        badge_display_resume_after_ota();
    }
    free(request);
    vTaskDelete(NULL);
}

static void auto_ota_check_task(void *arg)
{
    (void)arg;
    vTaskDelay(pdMS_TO_TICKS(BADGE_OTA_CHECK_DELAY_MS));
    if (!s_sta_connected) {
        s_auto_ota_check_running = false;
        vTaskDelete(NULL);
        return;
    }

    char *manifest = calloc(1, BADGE_OTA_MANIFEST_MAX);
    if (manifest == NULL) {
        s_auto_ota_check_running = false;
        vTaskDelete(NULL);
        return;
    }

    ESP_LOGI(TAG, "checking OTA manifest: %s", BADGE_OTA_MANIFEST_URL);
    esp_err_t ret = fetch_ota_manifest(manifest, BADGE_OTA_MANIFEST_MAX);
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "OTA manifest fetch failed: %s", esp_err_to_name(ret));
        free(manifest);
        s_auto_ota_check_running = false;
        vTaskDelete(NULL);
        return;
    }

    char remote_version[32] = {0};
    char firmware_url[BADGE_OTA_URL_MAX] = {0};
    if (!parse_ota_manifest(manifest, remote_version, sizeof(remote_version), firmware_url, sizeof(firmware_url))) {
        ESP_LOGW(TAG, "OTA manifest parse failed");
        free(manifest);
        s_auto_ota_check_running = false;
        vTaskDelete(NULL);
        return;
    }
    free(manifest);

    if (!ota_version_is_newer(remote_version, BADGE_FW_VERSION)) {
        ESP_LOGI(TAG, "firmware up to date: current=%s remote=%s", BADGE_FW_VERSION, remote_version);
        s_auto_ota_check_running = false;
        vTaskDelete(NULL);
        return;
    }

    badge_ota_request_t *request = calloc(1, sizeof(*request));
    if (request == NULL) {
        ESP_LOGE(TAG, "no memory for OTA request");
        s_auto_ota_check_running = false;
        vTaskDelete(NULL);
        return;
    }
    snprintf(request->url, sizeof(request->url), "%s", firmware_url);
    ESP_LOGI(TAG, "new firmware available: current=%s remote=%s", BADGE_FW_VERSION, remote_version);
    s_auto_ota_check_running = false;
    ota_update_task(request);
}

static void start_auto_ota_check(void)
{
    if (s_auto_ota_check_running || BADGE_OTA_MANIFEST_URL[0] == '\0') {
        return;
    }
    if (xTaskCreate(auto_ota_check_task, "badge_ota_check", BADGE_OTA_TASK_STACK, NULL, 4, NULL) == pdPASS) {
        s_auto_ota_check_running = true;
    } else {
        ESP_LOGW(TAG, "create OTA check task failed");
    }
}

static esp_err_t ota_handler(httpd_req_t *req)
{
    if (!s_sta_connected) {
        httpd_resp_set_status(req, "409 Conflict");
        httpd_resp_sendstr(req, "STA Wi-Fi not connected");
        return ESP_FAIL;
    }

    char query[BADGE_OTA_URL_MAX + 16] = {0};
    char url[BADGE_OTA_URL_MAX] = {0};
    esp_err_t ret = httpd_req_get_url_query_str(req, query, sizeof(query));
    if (ret != ESP_OK || httpd_query_key_value(query, "url", url, sizeof(url)) != ESP_OK) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "missing url");
        return ESP_FAIL;
    }
    url_decode_in_place(url);
    if (strncmp(url, "https://", 8) != 0 && strncmp(url, "http://", 7) != 0) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "invalid url");
        return ESP_FAIL;
    }

    badge_ota_request_t *request = calloc(1, sizeof(*request));
    if (request == NULL) {
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "no memory");
        return ESP_FAIL;
    }
    snprintf(request->url, sizeof(request->url), "%s", url);

    if (xTaskCreate(ota_update_task, "badge_ota", BADGE_OTA_TASK_STACK, request, 5, NULL) != pdPASS) {
        free(request);
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "ota task failed");
        return ESP_FAIL;
    }

    httpd_resp_set_type(req, "application/json");
    return httpd_resp_sendstr(req, "{\"ok\":true,\"message\":\"ota started\"}");
}

static esp_err_t upload_handler(httpd_req_t *req)
{
    if (req->content_len == 0) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "missing body");
        return ESP_FAIL;
    }
    if (req->content_len > UINT32_MAX) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "body too large");
        return ESP_FAIL;
    }

    uint32_t expected_crc = 0;
    esp_err_t ret = parse_crc_header(req, &expected_crc);
    if (ret != ESP_OK) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "missing or invalid X-EBAJ-CRC32");
        return ESP_FAIL;
    }

    const uint32_t total_size = (uint32_t)req->content_len;
    badge_upload_session_t session = {0};
    ret = begin_upload_session(&session, total_size, expected_crc);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "begin upload failed: %s", esp_err_to_name(ret));
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, esp_err_to_name(ret));
        return ESP_FAIL;
    }
    ret = alloc_upload_session_buffers(&session);
    if (ret != ESP_OK) {
        abort_upload_session();
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, esp_err_to_name(ret));
        return ESP_FAIL;
    }

    size_t buffer_size = 0;
    uint8_t *buffer = alloc_upload_buffer(BADGE_HTTP_UPLOAD_BUF, &buffer_size);
    if (buffer == NULL) {
        free_upload_session_buffers(&session);
        abort_upload_session();
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "no memory");
        return ESP_FAIL;
    }
    session.upload_buf_caps = upload_buffer_caps(buffer);

    size_t remaining = req->content_len;
    while (remaining > 0) {
        size_t want = remaining > buffer_size ? buffer_size : remaining;
        int64_t recv_start_us = esp_timer_get_time();
        int received = httpd_req_recv(req, (char *)buffer, want);
        int64_t chunk_recv_us = esp_timer_get_time() - recv_start_us;
        session.recv_us += chunk_recv_us;
        if (received == HTTPD_SOCK_ERR_TIMEOUT) {
            continue;
        }
        if (received <= 0) {
            ESP_LOGE(TAG, "http recv failed: %d", received);
            heap_caps_free(buffer);
            free_upload_session_buffers(&session);
            abort_upload_session();
            httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "receive failed");
            return ESP_FAIL;
        }

        int64_t append_start_us = esp_timer_get_time();
        ret = append_upload_data(&session, buffer, (size_t)received);
        int64_t chunk_append_us = esp_timer_get_time() - append_start_us;
        if (ret != ESP_OK) {
            ESP_LOGE(TAG, "write failed at %" PRIu32 ": %s", session.offset, esp_err_to_name(ret));
            heap_caps_free(buffer);
            free_upload_session_buffers(&session);
            abort_upload_session();
            httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, esp_err_to_name(ret));
            return ESP_FAIL;
        }

        remaining -= (size_t)received;
        log_upload_chunk_diag(&session, "HTTP", received, chunk_recv_us, chunk_append_us, (uint32_t)remaining);
    }

    heap_caps_free(buffer);

    ret = flush_upload_coalesce(&session);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "final write failed at %" PRIu32 ": %s", session.offset, esp_err_to_name(ret));
        free_upload_session_buffers(&session);
        abort_upload_session();
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, esp_err_to_name(ret));
        return ESP_FAIL;
    }

    ret = finish_upload_session(&session, "HTTP");
    free_upload_session_buffers(&session);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "finish upload failed: %s", esp_err_to_name(ret));
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, esp_err_to_name(ret));
        return ESP_FAIL;
    }

    httpd_resp_set_type(req, "application/json");
    httpd_resp_sendstr(req, "{\"ok\":true}");
    return ESP_OK;
}

static esp_err_t recv_exact(int sock, void *buffer, size_t len, int64_t *recv_us)
{
    uint8_t *dst = (uint8_t *)buffer;
    size_t remaining = len;
    while (remaining > 0) {
        int64_t recv_start_us = esp_timer_get_time();
        int received = recv(sock, dst, remaining, 0);
        if (recv_us != NULL) {
            *recv_us += esp_timer_get_time() - recv_start_us;
        }
        if (received <= 0) {
            return ESP_FAIL;
        }
        dst += received;
        remaining -= (size_t)received;
    }
    return ESP_OK;
}

static esp_err_t send_tcp_line(int sock, const char *line)
{
    if (line == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    const char *src = line;
    size_t remaining = strlen(line);
    while (remaining > 0) {
        int sent = send(sock, src, remaining, 0);
        if (sent <= 0) {
            return ESP_FAIL;
        }
        src += sent;
        remaining -= (size_t)sent;
    }
    return ESP_OK;
}

static esp_err_t send_tcp_ready(int sock)
{
    return send_tcp_line(sock, "READY\n");
}

static void send_tcp_status(int sock, esp_err_t ret)
{
    char response[64] = {0};
    if (ret == ESP_OK) {
        snprintf(response, sizeof(response), "OK\n");
    } else {
        snprintf(response, sizeof(response), "ERR %s\n", esp_err_to_name(ret));
    }
    (void)send_tcp_line(sock, response);
}

static esp_err_t handle_tcp_upload(int sock)
{
    int opt = 1;
    (void)setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &opt, sizeof(opt));
    int rcvbuf = BADGE_TCP_RCVBUF_BYTES;
    (void)setsockopt(sock, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
    struct timeval timeout = {
        .tv_sec = 120,
        .tv_usec = 0,
    };
    (void)setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    (void)setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

    /* Peek the first 6 bytes to detect SWITCH command vs upload. */
    uint8_t peek[6] = {0};
    int64_t header_recv_us = 0;
    esp_err_t ret = recv_exact(sock, peek, sizeof(peek), &header_recv_us);
    if (ret != ESP_OK) {
        return ret;
    }

    /* SWITCH command: "SWITCH <ID>\n" */
    if (memcmp(peek, "SWITCH", 6) == 0) {
        char cmd[32] = {0};
        int total = 0;
        while (total < (int)sizeof(cmd) - 1) {
            int r = recv(sock, cmd + total, 1, 0);
            if (r <= 0) break;
            total += r;
            if (cmd[total - 1] == '\n') break;
        }
        cmd[total] = '\0';
        /* Parse ID after "SWITCH " � note: "SWITCH" already consumed by peek above */
        const char *id = cmd;
        while (*id == ' ' || *id == '\t') id++;
        /* Strip trailing whitespace/newline */
        char clean_id[BADGE_ANIM_ID_LEN] = {0};
        strncpy(clean_id, id, sizeof(clean_id) - 1);
        size_t len = strlen(clean_id);
        while (len > 0 && (clean_id[len - 1] == '\n' || clean_id[len - 1] == '\r' || clean_id[len - 1] == ' ')) {
            clean_id[--len] = '\0';
        }
        ESP_LOGI(TAG, "SWITCH command: %s", clean_id);
        if (strcmp(clean_id, "NEWID") == 0) {
            const char *new_id = badge_anim_mgr_alloc_user_id();
            char response[32];
            snprintf(response, sizeof(response), "OK %s\n", new_id);
            send_tcp_line(sock, response);
            return ESP_OK;
        }
        ret = badge_anim_mgr_switch_to(clean_id);
        if (ret == ESP_ERR_NOT_FOUND) {
            send_tcp_line(sock, "NEED_UPLOAD ");
            send_tcp_line(sock, clean_id);
            send_tcp_line(sock, "\n");
            return ESP_OK;
        }
        send_tcp_status(sock, ret);
        return ret;
    }

    /* Binary upload: read remaining 6 bytes of the 12-byte header */
    uint8_t header[12];
    memcpy(header, peek, 6);
    ret = recv_exact(sock, header + 6, 6, &header_recv_us);
    if (ret != ESP_OK) {
        return ret;
    }

    uint32_t magic = read_le32(&header[0]);
    uint32_t total_size = read_le32(&header[4]);
    uint32_t expected_crc = read_le32(&header[8]);
    if (magic != BADGE_TCP_UPLOAD_MAGIC || total_size == 0) {
        return ESP_ERR_INVALID_ARG;
    }

    /* Send READY immediately �C the Android starts streaming data while we
     * set up SD and allocate buffers.  The TCP receive window fills with
     * in-flight data, keeping ACKs flowing and preventing congestion-window
     * collapse once our recv() loop starts. */
    ret = send_tcp_ready(sock);
    if (ret != ESP_OK) {
        return ret;
    }

    badge_upload_session_t session = {0};
    ret = begin_upload_session(&session, total_size, expected_crc);
    if (ret != ESP_OK) {
        abort_upload_session();
        return ret;
    }
    session.recv_us = header_recv_us;
    ret = alloc_upload_session_buffers(&session);
    if (ret != ESP_OK) {
        abort_upload_session();
        return ret;
    }

    size_t buffer_size = 0;
    uint8_t *buffer = alloc_upload_buffer(BADGE_TCP_UPLOAD_BUF, &buffer_size);
    if (buffer == NULL) {
        free_upload_session_buffers(&session);
        abort_upload_session();
        return ESP_ERR_NO_MEM;
    }
    session.upload_buf_caps = upload_buffer_caps(buffer);

    uint32_t remaining = total_size;
    while (remaining > 0) {
        size_t want = remaining > buffer_size ? buffer_size : remaining;
        int64_t recv_start_us = esp_timer_get_time();
        int received = recv(sock, buffer, want, 0);
        int64_t chunk_recv_us = esp_timer_get_time() - recv_start_us;
        session.recv_us += chunk_recv_us;
        if (received <= 0) {
            heap_caps_free(buffer);
            free_upload_session_buffers(&session);
            abort_upload_session();
            return ESP_FAIL;
        }

        int64_t append_start_us = esp_timer_get_time();
        ret = append_upload_data(&session, buffer, (size_t)received);
        int64_t chunk_append_us = esp_timer_get_time() - append_start_us;
        if (ret != ESP_OK) {
            heap_caps_free(buffer);
            free_upload_session_buffers(&session);
            abort_upload_session();
            return ret;
        }
        remaining -= (uint32_t)received;
        log_upload_chunk_diag(&session, "TCP", received, chunk_recv_us, chunk_append_us, remaining);
    }

    heap_caps_free(buffer);
    ret = flush_upload_coalesce(&session);
    if (ret != ESP_OK) {
        free_upload_session_buffers(&session);
        abort_upload_session();
        return ret;
    }
    if (session.offset != total_size) {
        free_upload_session_buffers(&session);
        abort_upload_session();
        return ESP_ERR_INVALID_SIZE;
    }

    ret = finish_upload_session(&session, "TCP");
    free_upload_session_buffers(&session);
    if (ret == ESP_OK) {
        const char *user_id = badge_anim_mgr_alloc_user_id();
        char user_path[72];
        snprintf(user_path, sizeof(user_path), "/sdcard/user/%s.eb4", user_id);
        unlink(user_path);
        if (rename("/sdcard/badge.eb4", user_path) == 0) {
            ESP_LOGI(TAG, "User upload saved as %s", user_path);
            /* Let anim mgr handle it so NVS persistence + state update works */
            badge_anim_mgr_play(user_id, BADGE_PLAY_MODE_LOOP);
            char response[64];
            snprintf(response, sizeof(response), "OK %s\n", user_id);
            send_tcp_line(sock, response);
            return ESP_OK;
        }
        ESP_LOGW(TAG, "Failed to rename upload to user folder: errno=%d", errno);
    }
    return ret;
}

static void tcp_upload_task(void *arg)
{
    (void)arg;

    int listen_sock = socket(AF_INET, SOCK_STREAM, IPPROTO_IP);
    if (listen_sock < 0) {
        ESP_LOGE(TAG, "TCP socket create failed: errno=%d", errno);
        vTaskDelete(NULL);
        return;
    }

    int opt = 1;
    (void)setsockopt(listen_sock, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    struct sockaddr_in listen_addr = {
        .sin_family = AF_INET,
        .sin_port = htons(BADGE_UPLOAD_TCP_PORT),
        .sin_addr.s_addr = htonl(INADDR_ANY),
    };
    if (bind(listen_sock, (struct sockaddr *)&listen_addr, sizeof(listen_addr)) != 0) {
        ESP_LOGE(TAG, "TCP bind failed: errno=%d", errno);
        close(listen_sock);
        vTaskDelete(NULL);
        return;
    }
    if (listen(listen_sock, 1) != 0) {
        ESP_LOGE(TAG, "TCP listen failed: errno=%d", errno);
        close(listen_sock);
        vTaskDelete(NULL);
        return;
    }

    ESP_LOGI(TAG, "TCP upload server listening on port %u", BADGE_UPLOAD_TCP_PORT);
    while (1) {
        struct sockaddr_storage source_addr = {0};
        socklen_t addr_len = sizeof(source_addr);
        int sock = accept(listen_sock, (struct sockaddr *)&source_addr, &addr_len);
        if (sock < 0) {
            ESP_LOGW(TAG, "TCP accept failed: errno=%d", errno);
            continue;
        }

        esp_err_t ret = handle_tcp_upload(sock);
        send_tcp_status(sock, ret);
        if (ret != ESP_OK) {
            ESP_LOGE(TAG, "TCP upload failed: %s", esp_err_to_name(ret));
        }
        shutdown(sock, SHUT_RDWR);
        close(sock);
    }
}

static esp_err_t start_tcp_upload_server(void)
{
    if (s_tcp_upload_task != NULL) {
        return ESP_OK;
    }
    if (xTaskCreatePinnedToCore(tcp_upload_task, "tcp_upload", BADGE_TCP_TASK_STACK, NULL,
                                BADGE_TCP_TASK_PRIORITY, &s_tcp_upload_task, 0) != pdPASS) {
        return ESP_ERR_NO_MEM;
    }
    return ESP_OK;
}

static esp_err_t start_http_server(void)
{
    httpd_config_t config = HTTPD_DEFAULT_CONFIG();
    config.max_uri_handlers = 16;
    config.max_open_sockets = 4;
    config.lru_purge_enable = true;
    config.server_port = 80;
    config.ctrl_port = 32768;
    config.stack_size = 12288;
    config.task_priority = 10;
    config.recv_wait_timeout = 10;
    config.send_wait_timeout = 10;
    config.uri_match_fn = httpd_uri_match_wildcard;

    ESP_RETURN_ON_ERROR(httpd_start(&s_httpd, &config), TAG, "httpd start failed");

    const httpd_uri_t root_uri = {
        .uri = "/",
        .method = HTTP_GET,
        .handler = provisioning_root_handler,
        .user_ctx = NULL,
    };
    const httpd_uri_t status_uri = {
        .uri = "/status",
        .method = HTTP_GET,
        .handler = status_handler,
        .user_ctx = NULL,
    };
    const httpd_uri_t upload_uri = {
        .uri = "/upload",
        .method = HTTP_POST,
        .handler = upload_handler,
        .user_ctx = NULL,
    };
    const httpd_uri_t brightness_uri = {
        .uri = "/brightness",
        .method = HTTP_GET,
        .handler = brightness_handler,
        .user_ctx = NULL,
    };
    const httpd_uri_t scan_uri = {
        .uri = "/scan",
        .method = HTTP_GET,
        .handler = scan_handler,
        .user_ctx = NULL,
    };
    const httpd_uri_t set_config_uri = {
        .uri = "/set_config",
        .method = HTTP_GET,
        .handler = handle_set_config,
        .user_ctx = NULL,
    };
    const httpd_uri_t wifi_status_uri = {
        .uri = "/wifi_status",
        .method = HTTP_GET,
        .handler = wifi_status_handler,
        .user_ctx = NULL,
    };
    const httpd_uri_t clear_config_uri = {
        .uri = "/clear_config",
        .method = HTTP_GET,
        .handler = handle_clear_config,
        .user_ctx = NULL,
    };
    const httpd_uri_t ota_uri = {
        .uri = "/ota",
        .method = HTTP_GET,
        .handler = ota_handler,
        .user_ctx = NULL,
    };
    const httpd_uri_t captive_android_uri = {
        .uri = "/generate_204",
        .method = HTTP_GET,
        .handler = captive_probe_handler,
        .user_ctx = NULL,
    };
    const httpd_uri_t captive_android_alt_uri = {
        .uri = "/gen_204",
        .method = HTTP_GET,
        .handler = captive_probe_handler,
        .user_ctx = NULL,
    };
    const httpd_uri_t captive_ios_uri = {
        .uri = "/hotspot-detect.html",
        .method = HTTP_GET,
        .handler = captive_probe_handler,
        .user_ctx = NULL,
    };
    const httpd_uri_t captive_ios_alt_uri = {
        .uri = "/library/test/success.html",
        .method = HTTP_GET,
        .handler = captive_probe_handler,
        .user_ctx = NULL,
    };
    const httpd_uri_t captive_windows_uri = {
        .uri = "/connecttest.txt",
        .method = HTTP_GET,
        .handler = captive_probe_handler,
        .user_ctx = NULL,
    };
    const httpd_uri_t captive_ncsi_uri = {
        .uri = "/ncsi.txt",
        .method = HTTP_GET,
        .handler = captive_probe_handler,
        .user_ctx = NULL,
    };
    const httpd_uri_t captive_wildcard_uri = {
        .uri = "/*",
        .method = HTTP_GET,
        .handler = provisioning_root_handler,
        .user_ctx = NULL,
    };

    ESP_RETURN_ON_ERROR(httpd_register_uri_handler(s_httpd, &root_uri), TAG, "root uri failed");
    ESP_RETURN_ON_ERROR(httpd_register_uri_handler(s_httpd, &status_uri), TAG, "status uri failed");
    ESP_RETURN_ON_ERROR(httpd_register_uri_handler(s_httpd, &upload_uri), TAG, "upload uri failed");
    ESP_RETURN_ON_ERROR(httpd_register_uri_handler(s_httpd, &brightness_uri), TAG, "brightness uri failed");
    ESP_RETURN_ON_ERROR(httpd_register_uri_handler(s_httpd, &scan_uri), TAG, "scan uri failed");
    ESP_RETURN_ON_ERROR(httpd_register_uri_handler(s_httpd, &set_config_uri), TAG, "set config uri failed");
    ESP_RETURN_ON_ERROR(httpd_register_uri_handler(s_httpd, &wifi_status_uri), TAG, "wifi status uri failed");
    ESP_RETURN_ON_ERROR(httpd_register_uri_handler(s_httpd, &clear_config_uri), TAG, "clear config uri failed");
    ESP_RETURN_ON_ERROR(httpd_register_uri_handler(s_httpd, &ota_uri), TAG, "ota uri failed");
    ESP_RETURN_ON_ERROR(httpd_register_uri_handler(s_httpd, &captive_android_uri), TAG, "android captive uri failed");
    ESP_RETURN_ON_ERROR(httpd_register_uri_handler(s_httpd, &captive_android_alt_uri), TAG, "android captive alt uri failed");
    ESP_RETURN_ON_ERROR(httpd_register_uri_handler(s_httpd, &captive_ios_uri), TAG, "ios captive uri failed");
    ESP_RETURN_ON_ERROR(httpd_register_uri_handler(s_httpd, &captive_ios_alt_uri), TAG, "ios captive alt uri failed");
    ESP_RETURN_ON_ERROR(httpd_register_uri_handler(s_httpd, &captive_windows_uri), TAG, "windows captive uri failed");
    ESP_RETURN_ON_ERROR(httpd_register_uri_handler(s_httpd, &captive_ncsi_uri), TAG, "ncsi captive uri failed");
    ESP_RETURN_ON_ERROR(httpd_register_uri_handler(s_httpd, &captive_wildcard_uri), TAG, "captive wildcard uri failed");
    return ESP_OK;
}

esp_err_t WifiUpload_Init(void)
{
    (void)esp_ota_mark_app_valid_cancel_rollback();
    ESP_RETURN_ON_ERROR(start_wifi_service(), TAG, "wifi service failed");
    ESP_RETURN_ON_ERROR(start_http_server(), TAG, "http server failed");
    ESP_RETURN_ON_ERROR(start_tcp_upload_server(), TAG, "tcp upload server failed");
    return ESP_OK;
}
