#include "BadgeFactorySync.h"

#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "BadgeAnimMgr.h"
#include "BadgeProtocol.h"

#include "cJSON.h"
#include "esp_check.h"
#include "esp_err.h"
#include "esp_http_client.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "mbedtls/sha256.h"

static const char *TAG = "BadgeFactorySync";

#ifndef BADGE_FACTORY_BASE_URL
#define BADGE_FACTORY_BASE_URL "http://60.205.122.153"
#endif

#ifndef BADGE_FACTORY_CATALOG_URL
#define BADGE_FACTORY_CATALOG_URL BADGE_FACTORY_BASE_URL "/api/factory-catalog"
#endif

#define BADGE_FACTORY_TASK_STACK 12288u
#define BADGE_FACTORY_CATALOG_MAX 32768u
#define BADGE_FACTORY_MAX_FILES 96u
#define BADGE_FACTORY_HTTP_TIMEOUT_MS 12000u
#define BADGE_FACTORY_HTTP_BUFFER_SIZE 4096u
#define BADGE_FACTORY_DIR "/sdcard/.factory"
#define BADGE_FACTORY_SYNC_DIR "/sdcard/.factory_sync"
#define BADGE_FACTORY_CATALOG_FILE "/sdcard/.factory/catalog.json"
#define BADGE_FACTORY_INSTALL_FILE "/sdcard/.factory/install.json"

typedef struct {
    char id[8];
    char path[80];
    char url[256];
    char sha256[65];
    size_t size;
} factory_file_t;

static bool s_sync_started;
static bool s_sync_running;

static bool starts_with(const char *value, const char *prefix)
{
    return strncmp(value, prefix, strlen(prefix)) == 0;
}

static bool is_digit3(const char *p)
{
    return p[0] >= '0' && p[0] <= '9' &&
           p[1] >= '0' && p[1] <= '9' &&
           p[2] >= '0' && p[2] <= '9';
}

static bool valid_fnnn_eb4(const char *name)
{
    return name[0] == 'F' && is_digit3(name + 1) && strcmp(name + 4, ".eb4") == 0;
}

static bool valid_device_path(const char *path)
{
    /* Allowed examples: first_half/F001.eb4, second_half/F001.eb4, third_half/F007.eb4, factory_loop/F022.eb4. */
    if (path == NULL || strstr(path, "..") != NULL || strchr(path, '\\') != NULL || path[0] == '/') {
        return false;
    }
    const char *name = strrchr(path, '/');
    name = name ? name + 1 : path;
    if (starts_with(path, "first_half/") ||
        starts_with(path, "second_half/") ||
        starts_with(path, "factory_loop/")) {
        return valid_fnnn_eb4(name);
    }
    if (starts_with(path, "third_half/")) {
        return strlen(name) >= 8 && name[0] == 'F' && strstr(name, ".eb4") != NULL;
    }
    return false;
}

static esp_err_t mkdir_recursive(const char *dir)
{
    char path[128];
    snprintf(path, sizeof(path), "%s", dir);
    for (char *p = path + 1; *p != '\0'; ++p) {
        if (*p == '/') {
            *p = '\0';
            if (mkdir(path, 0755) != 0 && errno != EEXIST) {
                return ESP_FAIL;
            }
            *p = '/';
        }
    }
    if (mkdir(path, 0755) != 0 && errno != EEXIST) {
        return ESP_FAIL;
    }
    return ESP_OK;
}

static esp_err_t mkdir_parent_for_file(const char *file_path)
{
    char dir[128];
    snprintf(dir, sizeof(dir), "%s", file_path);
    char *slash = strrchr(dir, '/');
    if (slash == NULL) {
        return ESP_OK;
    }
    *slash = '\0';
    return mkdir_recursive(dir);
}

static esp_err_t read_text_file(const char *path, char *buffer, size_t buffer_size)
{
    FILE *f = fopen(path, "rb");
    if (f == NULL) {
        return ESP_ERR_NOT_FOUND;
    }
    size_t n = fread(buffer, 1, buffer_size - 1, f);
    fclose(f);
    buffer[n] = '\0';
    return n > 0 ? ESP_OK : ESP_FAIL;
}

static esp_err_t write_text_atomic(const char *path, const char *text)
{
    char tmp[128];
    snprintf(tmp, sizeof(tmp), "%s.tmp", path);
    ESP_RETURN_ON_ERROR(mkdir_parent_for_file(path), TAG, "mkdir parent failed");
    FILE *f = fopen(tmp, "wb");
    if (f == NULL) {
        return ESP_FAIL;
    }
    size_t len = strlen(text);
    bool ok = fwrite(text, 1, len, f) == len;
    fclose(f);
    if (!ok) {
        unlink(tmp);
        return ESP_FAIL;
    }
    unlink(path);
    return rename(tmp, path) == 0 ? ESP_OK : ESP_FAIL;
}

static esp_err_t build_url(const char *catalog_url, char *out, size_t out_size)
{
    if (catalog_url == NULL || catalog_url[0] == '\0') {
        return ESP_ERR_INVALID_ARG;
    }
    if (starts_with(catalog_url, "http://") || starts_with(catalog_url, "https://")) {
        snprintf(out, out_size, "%s", catalog_url);
        return ESP_OK;
    }
    if (catalog_url[0] == '/') {
        snprintf(out, out_size, "%s%s", BADGE_FACTORY_BASE_URL, catalog_url);
        return ESP_OK;
    }
    return ESP_ERR_INVALID_ARG;
}

static esp_err_t fetch_catalog(char *buffer, size_t buffer_size)
{
    esp_http_client_config_t config = {
        .url = BADGE_FACTORY_CATALOG_URL,
        .timeout_ms = BADGE_FACTORY_HTTP_TIMEOUT_MS,
        .keep_alive_enable = false,
        .buffer_size = BADGE_FACTORY_HTTP_BUFFER_SIZE,
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
        esp_http_client_close(client);
        esp_http_client_cleanup(client);
        return ESP_FAIL;
    }
    int total = 0;
    while (total < (int)buffer_size - 1) {
        int n = esp_http_client_read(client, buffer + total, (int)buffer_size - 1 - total);
        if (n < 0) {
            ret = ESP_FAIL;
            break;
        }
        if (n == 0) {
            break;
        }
        total += n;
    }
    buffer[total] = '\0';
    esp_http_client_close(client);
    esp_http_client_cleanup(client);
    return (ret == ESP_OK && total > 0) ? ESP_OK : ESP_FAIL;
}

static bool sha256_hex_file(const char *path, char out_hex[65])
{
    FILE *f = fopen(path, "rb");
    if (f == NULL) {
        return false;
    }
    mbedtls_sha256_context ctx;
    unsigned char digest[32];
    unsigned char buf[1024];
    mbedtls_sha256_init(&ctx);
    mbedtls_sha256_starts(&ctx, 0);
    while (1) {
        size_t n = fread(buf, 1, sizeof(buf), f);
        if (n > 0) {
            mbedtls_sha256_update(&ctx, buf, n);
        }
        if (n < sizeof(buf)) {
            break;
        }
    }
    fclose(f);
    mbedtls_sha256_finish(&ctx, digest);
    mbedtls_sha256_free(&ctx);
    for (int i = 0; i < 32; ++i) {
        snprintf(out_hex + (i * 2), 3, "%02x", digest[i]);
    }
    out_hex[64] = '\0';
    return true;
}

static bool file_matches(const char *path, size_t expected_size, const char *expected_sha)
{
    struct stat st;
    if (stat(path, &st) != 0 || (size_t)st.st_size != expected_size) {
        return false;
    }
    char hex[65];
    return sha256_hex_file(path, hex) && strcasecmp(hex, expected_sha) == 0;
}

static bool eb4_header_valid(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (f == NULL) {
        return false;
    }
    badge_ebaj_header_t header;
    bool ok = fread(&header, 1, sizeof(header), f) == sizeof(header) &&
              header.magic == BADGE_EBAJ_MAGIC &&
              header.frame_count > 0 &&
              header.stream_width == 480 &&
              header.stream_height == 480;
    fclose(f);
    return ok;
}

static esp_err_t download_file(const char *url, const char *out_path, size_t expected_size, const char *expected_sha)
{
    ESP_RETURN_ON_ERROR(mkdir_parent_for_file(out_path), TAG, "mkdir download parent failed");
    FILE *f = fopen(out_path, "wb");
    if (f == NULL) {
        return ESP_FAIL;
    }
    esp_http_client_config_t config = {
        .url = url,
        .timeout_ms = BADGE_FACTORY_HTTP_TIMEOUT_MS,
        .keep_alive_enable = false,
        .buffer_size = BADGE_FACTORY_HTTP_BUFFER_SIZE,
    };
    esp_http_client_handle_t client = esp_http_client_init(&config);
    if (client == NULL) {
        fclose(f);
        return ESP_ERR_NO_MEM;
    }
    esp_err_t ret = esp_http_client_open(client, 0);
    if (ret != ESP_OK) {
        esp_http_client_cleanup(client);
        fclose(f);
        return ret;
    }
    (void)esp_http_client_fetch_headers(client);
    int status = esp_http_client_get_status_code(client);
    if (status != 200) {
        ret = ESP_FAIL;
    }
    int total = 0;
    char buf[BADGE_FACTORY_HTTP_BUFFER_SIZE];
    while (ret == ESP_OK) {
        int n = esp_http_client_read(client, buf, sizeof(buf));
        if (n < 0) {
            ret = ESP_FAIL;
            break;
        }
        if (n == 0) {
            break;
        }
        if (fwrite(buf, 1, n, f) != (size_t)n) {
            ret = ESP_FAIL;
            break;
        }
        total += n;
        vTaskDelay(pdMS_TO_TICKS(1));
    }
    esp_http_client_close(client);
    esp_http_client_cleanup(client);
    fclose(f);
    if (ret != ESP_OK || (size_t)total != expected_size || !file_matches(out_path, expected_size, expected_sha)) {
        unlink(out_path);
        return ESP_FAIL;
    }
    if (!eb4_header_valid(out_path)) {
        unlink(out_path);
        return ESP_FAIL;
    }
    return ESP_OK;
}

static int installed_revision(void)
{
    char text[512];
    if (read_text_file(BADGE_FACTORY_INSTALL_FILE, text, sizeof(text)) != ESP_OK) {
        return -1;
    }
    cJSON *root = cJSON_Parse(text);
    if (root == NULL) {
        return -1;
    }
    const cJSON *rev = cJSON_GetObjectItem(root, "catalogRevision");
    int value = cJSON_IsNumber(rev) ? rev->valueint : -1;
    cJSON_Delete(root);
    return value;
}

static bool path_in_remote(const char *path, const factory_file_t *files, size_t file_count)
{
    for (size_t i = 0; i < file_count; ++i) {
        if (strcmp(path, files[i].path) == 0) {
            return true;
        }
    }
    return false;
}

static void delete_removed_managed_files(const factory_file_t *files, size_t file_count)
{
    char text[4096];
    if (read_text_file(BADGE_FACTORY_INSTALL_FILE, text, sizeof(text)) != ESP_OK) {
        return;
    }
    cJSON *root = cJSON_Parse(text);
    if (root == NULL) {
        return;
    }
    const cJSON *old_files = cJSON_GetObjectItem(root, "files");
    const cJSON *old_file = NULL;
    cJSON_ArrayForEach(old_file, old_files) {
        const cJSON *path_item = cJSON_GetObjectItem(old_file, "path");
        if (!cJSON_IsString(path_item) || path_item->valuestring == NULL) {
            continue;
        }
        if (path_in_remote(path_item->valuestring, files, file_count)) {
            continue;
        }
        char full_path[128];
        snprintf(full_path, sizeof(full_path), "/sdcard/%s", path_item->valuestring);
        unlink(full_path);
        ESP_LOGI(TAG, "removed deleted managed factory file: %s", full_path);
    }
    cJSON_Delete(root);
}

static esp_err_t parse_remote_files(cJSON *root, factory_file_t *files, size_t *file_count, int *revision)
{
    const cJSON *schema = cJSON_GetObjectItem(root, "schemaVersion");
    const cJSON *rev = cJSON_GetObjectItem(root, "catalogRevision");
    const cJSON *items = cJSON_GetObjectItem(root, "items");
    if (!cJSON_IsNumber(schema) || schema->valueint != 1 || !cJSON_IsNumber(rev) || !cJSON_IsArray(items)) {
        return ESP_ERR_INVALID_RESPONSE;
    }
    *revision = rev->valueint;
    *file_count = 0;
    const cJSON *item = NULL;
    cJSON_ArrayForEach(item, items) {
        const cJSON *id_item = cJSON_GetObjectItem(item, "id");
        const cJSON *device_files = cJSON_GetObjectItem(item, "deviceFiles");
        if (!cJSON_IsString(id_item) || !cJSON_IsArray(device_files)) {
            continue;
        }
        const cJSON *file = NULL;
        cJSON_ArrayForEach(file, device_files) {
            if (*file_count >= BADGE_FACTORY_MAX_FILES) {
                return ESP_ERR_NO_MEM;
            }
            const cJSON *path_item = cJSON_GetObjectItem(file, "path");
            const cJSON *url_item = cJSON_GetObjectItem(file, "url");
            const cJSON *size_item = cJSON_GetObjectItem(file, "size");
            const cJSON *sha_item = cJSON_GetObjectItem(file, "sha256");
            if (!cJSON_IsString(path_item) || !cJSON_IsString(url_item) ||
                !cJSON_IsNumber(size_item) || !cJSON_IsString(sha_item)) {
                return ESP_ERR_INVALID_RESPONSE;
            }
            if (!valid_device_path(path_item->valuestring) || strlen(sha_item->valuestring) != 64) {
                return ESP_ERR_INVALID_RESPONSE;
            }
            factory_file_t *out = &files[*file_count];
            memset(out, 0, sizeof(*out));
            snprintf(out->id, sizeof(out->id), "%s", id_item->valuestring);
            snprintf(out->path, sizeof(out->path), "%s", path_item->valuestring);
            snprintf(out->sha256, sizeof(out->sha256), "%s", sha_item->valuestring);
            out->size = (size_t)size_item->valuedouble;
            ESP_RETURN_ON_ERROR(build_url(url_item->valuestring, out->url, sizeof(out->url)), TAG, "bad file url");
            (*file_count)++;
        }
    }
    return ESP_OK;
}

static esp_err_t write_install_manifest(int revision, const factory_file_t *files, size_t file_count)
{
    cJSON *root = cJSON_CreateObject();
    cJSON_AddNumberToObject(root, "catalogRevision", revision);
    cJSON *arr = cJSON_AddArrayToObject(root, "files");
    for (size_t i = 0; i < file_count; ++i) {
        cJSON *item = cJSON_CreateObject();
        cJSON_AddStringToObject(item, "id", files[i].id);
        cJSON_AddStringToObject(item, "path", files[i].path);
        cJSON_AddNumberToObject(item, "size", (double)files[i].size);
        cJSON_AddStringToObject(item, "sha256", files[i].sha256);
        cJSON_AddItemToArray(arr, item);
    }
    char *text = cJSON_PrintUnformatted(root);
    cJSON_Delete(root);
    if (text == NULL) {
        return ESP_ERR_NO_MEM;
    }
    esp_err_t ret = write_text_atomic(BADGE_FACTORY_INSTALL_FILE, text);
    cJSON_free(text);
    return ret;
}

static esp_err_t commit_downloads(int revision, const factory_file_t *files, size_t file_count)
{
    for (size_t i = 0; i < file_count; ++i) {
        char tmp_path[160];
        char final_path[128];
        snprintf(tmp_path, sizeof(tmp_path), BADGE_FACTORY_SYNC_DIR "/%d/%s", revision, files[i].path);
        snprintf(final_path, sizeof(final_path), "/sdcard/%s", files[i].path);
        if (!file_matches(final_path, files[i].size, files[i].sha256)) {
            ESP_RETURN_ON_ERROR(mkdir_parent_for_file(final_path), TAG, "mkdir final parent failed");
            unlink(final_path);
            if (rename(tmp_path, final_path) != 0) {
                return ESP_FAIL;
            }
        }
    }
    delete_removed_managed_files(files, file_count);
    ESP_RETURN_ON_ERROR(write_install_manifest(revision, files, file_count), TAG, "write install manifest failed");
    return ESP_OK;
}

static void factory_sync_task(void *arg)
{
    (void)arg;
    s_sync_running = true;
    char *catalog = calloc(1, BADGE_FACTORY_CATALOG_MAX);
    if (catalog == NULL) {
        s_sync_running = false;
        vTaskDelete(NULL);
        return;
    }

    ESP_LOGI(TAG, "checking factory catalog: %s", BADGE_FACTORY_CATALOG_URL);
    esp_err_t ret = fetch_catalog(catalog, BADGE_FACTORY_CATALOG_MAX);
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "factory catalog fetch failed: %s", esp_err_to_name(ret));
        free(catalog);
        s_sync_running = false;
        vTaskDelete(NULL);
        return;
    }

    cJSON *root = cJSON_Parse(catalog);
    if (root == NULL) {
        ESP_LOGW(TAG, "factory catalog parse failed");
        free(catalog);
        s_sync_running = false;
        vTaskDelete(NULL);
        return;
    }

    factory_file_t *files = calloc(BADGE_FACTORY_MAX_FILES, sizeof(*files));
    if (files == NULL) {
        ESP_LOGW(TAG, "no memory for factory file list");
        cJSON_Delete(root);
        free(catalog);
        s_sync_running = false;
        vTaskDelete(NULL);
        return;
    }
    size_t file_count = 0;
    int revision = 0;
    ret = parse_remote_files(root, files, &file_count, &revision);
    cJSON_Delete(root);
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "factory catalog validation failed: %s", esp_err_to_name(ret));
        free(files);
        free(catalog);
        s_sync_running = false;
        vTaskDelete(NULL);
        return;
    }

    int installed = installed_revision();
    if (installed >= revision) {
        ESP_LOGI(TAG, "factory catalog up to date: installed=%d remote=%d", installed, revision);
        free(files);
        free(catalog);
        s_sync_running = false;
        vTaskDelete(NULL);
        return;
    }

    char sync_dir[96];
    snprintf(sync_dir, sizeof(sync_dir), BADGE_FACTORY_SYNC_DIR "/%d", revision);
    (void)mkdir_recursive(sync_dir);

    const char *current = badge_anim_mgr_current_id();
    for (size_t i = 0; i < file_count; ++i) {
        if (current != NULL && strcmp(current, files[i].id) == 0) {
            (void)badge_anim_mgr_switch_to("F001");
            break;
        }
    }

    for (size_t i = 0; i < file_count; ++i) {
        char final_path[128];
        char tmp_path[160];
        snprintf(final_path, sizeof(final_path), "/sdcard/%s", files[i].path);
        snprintf(tmp_path, sizeof(tmp_path), BADGE_FACTORY_SYNC_DIR "/%d/%s", revision, files[i].path);
        if (file_matches(final_path, files[i].size, files[i].sha256)) {
            continue;
        }
        ESP_LOGI(TAG, "downloading factory file: %s", files[i].path);
        ret = download_file(files[i].url, tmp_path, files[i].size, files[i].sha256);
        if (ret != ESP_OK) {
            ESP_LOGW(TAG, "factory file download failed: %s %s", files[i].path, esp_err_to_name(ret));
            free(files);
            free(catalog);
            s_sync_running = false;
            vTaskDelete(NULL);
            return;
        }
    }

    ret = commit_downloads(revision, files, file_count);
    if (ret == ESP_OK) {
        (void)write_text_atomic(BADGE_FACTORY_CATALOG_FILE, catalog);
        (void)badge_anim_mgr_rescan();
        ESP_LOGI(TAG, "factory catalog synced: revision=%d files=%u", revision, (unsigned)file_count);
    } else {
        ESP_LOGW(TAG, "factory catalog commit failed: %s", esp_err_to_name(ret));
    }

    free(files);
    free(catalog);
    s_sync_running = false;
    vTaskDelete(NULL);
}

void badge_factory_sync_start_once(void)
{
    if (s_sync_started || s_sync_running || BADGE_FACTORY_CATALOG_URL[0] == '\0') {
        return;
    }
    s_sync_started = true;
    if (xTaskCreate(factory_sync_task,
                    "factory_sync",
                    BADGE_FACTORY_TASK_STACK,
                    NULL,
                    3,
                    NULL) != pdPASS) {
        ESP_LOGW(TAG, "create factory sync task failed");
        s_sync_running = false;
    }
}

bool badge_factory_sync_is_running(void)
{
    return s_sync_running;
}
