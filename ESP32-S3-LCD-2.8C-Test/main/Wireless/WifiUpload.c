#include "WifiUpload.h"

#include <errno.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "BadgeDisplay.h"
#include "BadgeStorage.h"
#include "ST7701S.h"

#include "esp_check.h"
#include "esp_err.h"
#include "esp_event.h"
#include "esp_http_server.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "lwip/inet.h"
#include "lwip/netdb.h"
#include "lwip/sockets.h"
#include "lwip/tcp.h"

#define BADGE_WIFI_SSID "ESP-BAJI"
#define BADGE_WIFI_CHANNEL 6
#define BADGE_WIFI_MAX_STA 1
#define BADGE_UPLOAD_TCP_PORT 3333
#define BADGE_TCP_UPLOAD_MAGIC 0x31505542u
#define BADGE_HTTP_UPLOAD_BUF (32u * 1024u)
#define BADGE_TCP_UPLOAD_BUF (32u * 1024u)
#define BADGE_UPLOAD_WRITE_COALESCE_BYTES (32u * 1024u)
#define BADGE_HTTP_CRC_HEADER "X-EBAJ-CRC32"
#define BADGE_TCP_TASK_STACK 8192u
#define BADGE_TCP_TASK_PRIORITY 7u

static const char *TAG = "WifiUpload";
static httpd_handle_t s_httpd;
static TaskHandle_t s_tcp_upload_task;

typedef struct {
    uint32_t total_size;
    uint32_t expected_crc;
    uint32_t offset;
    int64_t recv_us;
    const char *upload_buf_caps;
    uint8_t *coalesce;
    size_t coalesce_len;
} badge_upload_session_t;

static esp_err_t start_wifi_ap(void)
{
    esp_err_t ret = esp_netif_init();
    if (ret != ESP_OK && ret != ESP_ERR_INVALID_STATE) {
        return ret;
    }

    ret = esp_event_loop_create_default();
    if (ret != ESP_OK && ret != ESP_ERR_INVALID_STATE) {
        return ret;
    }

    esp_netif_create_default_wifi_ap();

    wifi_init_config_t init_cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_RETURN_ON_ERROR(esp_wifi_init(&init_cfg), TAG, "wifi init failed");

    wifi_config_t wifi_config = {0};
    snprintf((char *)wifi_config.ap.ssid, sizeof(wifi_config.ap.ssid), "%s", BADGE_WIFI_SSID);
    wifi_config.ap.ssid_len = strlen(BADGE_WIFI_SSID);
    wifi_config.ap.channel = BADGE_WIFI_CHANNEL;
    wifi_config.ap.max_connection = BADGE_WIFI_MAX_STA;
    wifi_config.ap.authmode = WIFI_AUTH_OPEN;
    wifi_config.ap.pmf_cfg.required = false;

    ESP_RETURN_ON_ERROR(esp_wifi_set_mode(WIFI_MODE_AP), TAG, "wifi mode failed");
    ESP_RETURN_ON_ERROR(esp_wifi_set_config(WIFI_IF_AP, &wifi_config), TAG, "wifi config failed");
    ESP_RETURN_ON_ERROR(esp_wifi_set_protocol(WIFI_IF_AP, WIFI_PROTOCOL_11B | WIFI_PROTOCOL_11G | WIFI_PROTOCOL_11N),
                        TAG, "wifi protocol failed");
    (void)esp_wifi_set_bandwidth(WIFI_IF_AP, WIFI_BW_HT40);
    (void)esp_wifi_set_ps(WIFI_PS_NONE);
    (void)esp_wifi_set_max_tx_power(78);
    ESP_RETURN_ON_ERROR(esp_wifi_start(), TAG, "wifi start failed");

    ESP_LOGI(TAG, "AP ready: ssid=%s http=http://192.168.4.1/upload tcp=192.168.4.1:%u",
             BADGE_WIFI_SSID, BADGE_UPLOAD_TCP_PORT);
    return ESP_OK;
}

static uint32_t read_le32(const uint8_t *data)
{
    return (uint32_t)data[0] |
           ((uint32_t)data[1] << 8) |
           ((uint32_t)data[2] << 16) |
           ((uint32_t)data[3] << 24);
}

static uint8_t *alloc_upload_buffer(size_t size)
{
    uint8_t *buffer = heap_caps_malloc(size, MALLOC_CAP_INTERNAL | MALLOC_CAP_DMA | MALLOC_CAP_8BIT);
    if (buffer != NULL) {
        return buffer;
    }

    buffer = heap_caps_malloc(size, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
    if (buffer == NULL) {
        buffer = heap_caps_malloc(size, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    }
    return buffer;
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

    esp_err_t ret = badge_display_enter_upload_mode(pdMS_TO_TICKS(5000));
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

static esp_err_t append_upload_data(badge_upload_session_t *session, const uint8_t *data, size_t len)
{
    if (session == NULL || data == NULL || len == 0) {
        return ESP_ERR_INVALID_ARG;
    }

    const uint8_t *src = data;
    size_t remaining = len;
    while (remaining > 0) {
        size_t free_len = BADGE_UPLOAD_WRITE_COALESCE_BYTES - session->coalesce_len;
        size_t chunk = remaining > free_len ? free_len : remaining;
        memcpy(session->coalesce + session->coalesce_len, src, chunk);
        session->coalesce_len += chunk;
        src += chunk;
        remaining -= chunk;

        if (session->coalesce_len == BADGE_UPLOAD_WRITE_COALESCE_BYTES) {
            esp_err_t ret = flush_upload_coalesce(session);
            if (ret != ESP_OK) {
                return ret;
            }
        }
    }
    return ESP_OK;
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

    session->coalesce = heap_caps_malloc(BADGE_UPLOAD_WRITE_COALESCE_BYTES,
                                         MALLOC_CAP_INTERNAL | MALLOC_CAP_DMA | MALLOC_CAP_8BIT);
    if (session->coalesce == NULL) {
        session->coalesce = heap_caps_malloc(BADGE_UPLOAD_WRITE_COALESCE_BYTES,
                                             MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
    }
    return session->coalesce != NULL ? ESP_OK : ESP_ERR_NO_MEM;
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
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "no coalesce memory");
        return ESP_FAIL;
    }

    uint8_t *buffer = alloc_upload_buffer(BADGE_HTTP_UPLOAD_BUF);
    if (buffer == NULL) {
        free_upload_session_buffers(&session);
        abort_upload_session();
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "no memory");
        return ESP_FAIL;
    }
    session.upload_buf_caps = upload_buffer_caps(buffer);

    size_t remaining = req->content_len;
    while (remaining > 0) {
        size_t want = remaining > BADGE_HTTP_UPLOAD_BUF ? BADGE_HTTP_UPLOAD_BUF : remaining;
        int64_t recv_start_us = esp_timer_get_time();
        int received = httpd_req_recv(req, (char *)buffer, want);
        session.recv_us += esp_timer_get_time() - recv_start_us;
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

        ret = append_upload_data(&session, buffer, (size_t)received);
        if (ret != ESP_OK) {
            ESP_LOGE(TAG, "write failed at %" PRIu32 ": %s", session.offset, esp_err_to_name(ret));
            heap_caps_free(buffer);
            free_upload_session_buffers(&session);
            abort_upload_session();
            httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, esp_err_to_name(ret));
            return ESP_FAIL;
        }

        remaining -= (size_t)received;
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

static void send_tcp_status(int sock, esp_err_t ret)
{
    char response[64] = {0};
    if (ret == ESP_OK) {
        snprintf(response, sizeof(response), "OK\n");
    } else {
        snprintf(response, sizeof(response), "ERR %s\n", esp_err_to_name(ret));
    }
    (void)send(sock, response, strlen(response), 0);
}

static esp_err_t handle_tcp_upload(int sock)
{
    int opt = 1;
    (void)setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &opt, sizeof(opt));
    struct timeval timeout = {
        .tv_sec = 120,
        .tv_usec = 0,
    };
    (void)setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    (void)setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

    uint8_t header[12] = {0};
    int64_t header_recv_us = 0;
    esp_err_t ret = recv_exact(sock, header, sizeof(header), &header_recv_us);
    if (ret != ESP_OK) {
        return ret;
    }

    uint32_t magic = read_le32(&header[0]);
    uint32_t total_size = read_le32(&header[4]);
    uint32_t expected_crc = read_le32(&header[8]);
    if (magic != BADGE_TCP_UPLOAD_MAGIC || total_size == 0) {
        return ESP_ERR_INVALID_ARG;
    }

    badge_upload_session_t session = {0};
    ret = begin_upload_session(&session, total_size, expected_crc);
    if (ret != ESP_OK) {
        return ret;
    }
    session.recv_us = header_recv_us;
    ret = alloc_upload_session_buffers(&session);
    if (ret != ESP_OK) {
        abort_upload_session();
        return ret;
    }

    uint8_t *buffer = alloc_upload_buffer(BADGE_TCP_UPLOAD_BUF);
    if (buffer == NULL) {
        free_upload_session_buffers(&session);
        abort_upload_session();
        return ESP_ERR_NO_MEM;
    }
    session.upload_buf_caps = upload_buffer_caps(buffer);

    uint32_t remaining = total_size;
    while (remaining > 0) {
        size_t want = remaining > BADGE_TCP_UPLOAD_BUF ? BADGE_TCP_UPLOAD_BUF : remaining;
        int64_t recv_start_us = esp_timer_get_time();
        int received = recv(sock, buffer, want, 0);
        session.recv_us += esp_timer_get_time() - recv_start_us;
        if (received <= 0) {
            heap_caps_free(buffer);
            free_upload_session_buffers(&session);
            abort_upload_session();
            return ESP_FAIL;
        }

        ret = append_upload_data(&session, buffer, (size_t)received);
        if (ret != ESP_OK) {
            heap_caps_free(buffer);
            free_upload_session_buffers(&session);
            abort_upload_session();
            return ret;
        }
        remaining -= (uint32_t)received;
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
    config.server_port = 80;
    config.ctrl_port = 32768;
    config.stack_size = 10240;
    config.task_priority = 6;
    config.recv_wait_timeout = 120;
    config.send_wait_timeout = 120;

    ESP_RETURN_ON_ERROR(httpd_start(&s_httpd, &config), TAG, "httpd start failed");

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

    ESP_RETURN_ON_ERROR(httpd_register_uri_handler(s_httpd, &status_uri), TAG, "status uri failed");
    ESP_RETURN_ON_ERROR(httpd_register_uri_handler(s_httpd, &upload_uri), TAG, "upload uri failed");
    ESP_RETURN_ON_ERROR(httpd_register_uri_handler(s_httpd, &brightness_uri), TAG, "brightness uri failed");
    return ESP_OK;
}

esp_err_t WifiUpload_Init(void)
{
    ESP_RETURN_ON_ERROR(start_wifi_ap(), TAG, "wifi ap failed");
    ESP_RETURN_ON_ERROR(start_http_server(), TAG, "http server failed");
    ESP_RETURN_ON_ERROR(start_tcp_upload_server(), TAG, "tcp upload server failed");
    return ESP_OK;
}
