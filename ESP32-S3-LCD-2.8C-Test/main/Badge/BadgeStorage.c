#include "BadgeStorage.h"

#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "esp_check.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "esp_system.h"
#include "esp_vfs_fat.h"
#include "sdmmc_cmd.h"
#include "driver/sdmmc_host.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "nvs.h"
#include "nvs_flash.h"
#include "SD_MMC.h"

#define BADGE_NVS_NAMESPACE "badge"
#define BADGE_NVS_SIZE_KEY "size"
#define BADGE_NVS_CRC_KEY "crc"
#define BADGE_SD_MOUNT_POINT "/sdcard"
#define BADGE_SD_ASSET_PATH BADGE_SD_MOUNT_POINT "/badge.eb4"
#define BADGE_SD_TEMP_PATH BADGE_SD_MOUNT_POINT "/badge.tmp"
#define BADGE_UPLOAD_LOG_STEP (512u * 1024u)
#define BADGE_SD_READ_STAGING_BYTES (64u * 1024u)
#define BADGE_SD_WRITE_BUFFER_BYTES (64u * 1024u)

typedef struct {
    bool active;
    uint32_t expected_size;
    uint32_t expected_crc32;
    uint32_t received_size;
    uint32_t next_log_at;
    uint32_t crc;
    FILE *sd_file;
} badge_upload_ctx_t;

static const char *TAG = "BadgeStorage";
static nvs_handle_t s_nvs;
static SemaphoreHandle_t s_lock;
static badge_upload_ctx_t s_upload;
static badge_upload_perf_t s_last_upload_perf;
static bool s_sd_mounted;
static uint8_t s_sd_width;
static sdmmc_card_t *s_sd_card;

static esp_err_t ensure_nvs(void)
{
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    return ret;
}

static esp_err_t try_mount_sd_width_locked(uint8_t width)
{
    esp_vfs_fat_sdmmc_mount_config_t mount_config = {
        .format_if_mount_failed = false,
        .max_files = 4,
        .allocation_unit_size = 32 * 1024,
    };
    sdmmc_host_t host = SDMMC_HOST_DEFAULT();
    host.max_freq_khz = SDMMC_FREQ_HIGHSPEED;
    sdmmc_slot_config_t slot_config = SDMMC_SLOT_CONFIG_DEFAULT();
    slot_config.width = width;
    slot_config.clk = CONFIG_EXAMPLE_PIN_CLK;
    slot_config.cmd = CONFIG_EXAMPLE_PIN_CMD;
    slot_config.d0 = CONFIG_EXAMPLE_PIN_D0;
    slot_config.d1 = CONFIG_EXAMPLE_PIN_D1;
    slot_config.d2 = CONFIG_EXAMPLE_PIN_D2;
    slot_config.d3 = CONFIG_EXAMPLE_PIN_D3;
    slot_config.flags |= SDMMC_SLOT_FLAG_INTERNAL_PULLUP;

    esp_err_t ret = esp_vfs_fat_sdmmc_mount(BADGE_SD_MOUNT_POINT, &host, &slot_config, &mount_config, &s_sd_card);
    if (ret != ESP_OK) {
        s_sd_card = NULL;
        s_sd_mounted = false;
        return ret;
    }

    s_sd_mounted = true;
    s_sd_width = width;
    ESP_LOGI(TAG, "SD mounted, width=%u asset path=%s", s_sd_width, BADGE_SD_ASSET_PATH);
    return ESP_OK;
}

static esp_err_t ensure_sd_mounted_locked(void)
{
    if (s_sd_mounted) {
        return ESP_OK;
    }

    esp_err_t ret = try_mount_sd_width_locked(4);
    if (ret == ESP_OK) {
        return ESP_OK;
    }

    ESP_LOGW(TAG, "SD 4-bit mount failed: %s, fallback to 1-bit", esp_err_to_name(ret));
    return try_mount_sd_width_locked(1);
}

static void mark_sd_failed_locked(void)
{
    if (s_sd_mounted) {
        esp_vfs_fat_sdcard_unmount(BADGE_SD_MOUNT_POINT, s_sd_card);
    }
    s_sd_card = NULL;
    s_sd_mounted = false;
    s_sd_width = 0;
}

static bool read_header_from_sd_locked(badge_ebaj_header_t *header)
{
    if (ensure_sd_mounted_locked() != ESP_OK) {
        return false;
    }

    FILE *file = fopen(BADGE_SD_ASSET_PATH, "rb");
    if (file == NULL) {
        return false;
    }
    size_t read_len = fread(header, 1, sizeof(*header), file);
    fclose(file);
    if (read_len != sizeof(*header)) {
        return false;
    }
    return badge_protocol_validate_header(header, UINT32_MAX);
}

static esp_err_t begin_sd_upload_locked(uint32_t total_size)
{
    esp_err_t ret = ensure_sd_mounted_locked();
    if (ret != ESP_OK) {
        return ret;
    }

    unlink(BADGE_SD_TEMP_PATH);
    FILE *file = fopen(BADGE_SD_TEMP_PATH, "wb");
    if (file == NULL) {
        ESP_LOGW(TAG, "open SD temp failed");
        mark_sd_failed_locked();
        return ESP_FAIL;
    }
    setvbuf(file, NULL, _IOFBF, BADGE_SD_WRITE_BUFFER_BYTES);
    int fd = fileno(file);
    if (fd >= 0 && ftruncate(fd, (off_t)total_size) == 0) {
        rewind(file);
    }

    s_upload.sd_file = file;
    ESP_LOGI(TAG, "begin upload to SD temp, size=%" PRIu32 " sd width=%u", total_size, s_sd_width);
    return ESP_OK;
}

static esp_err_t write_sd_chunk_locked(const uint8_t *data, size_t len)
{
    if (s_upload.sd_file == NULL) {
        return ESP_ERR_INVALID_STATE;
    }

    size_t written = fwrite(data, 1, len, s_upload.sd_file);
    if (written != len) {
        ESP_LOGW(TAG, "SD write failed at %" PRIu32, s_upload.received_size);
        mark_sd_failed_locked();
        return ESP_FAIL;
    }
    return ESP_OK;
}

static esp_err_t read_header_from_file(FILE *file, badge_ebaj_header_t *header)
{
    if (file == NULL || header == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    if (fseek(file, 0, SEEK_SET) != 0) {
        return ESP_FAIL;
    }
    size_t read_len = fread(header, 1, sizeof(*header), file);
    if (read_len != sizeof(*header)) {
        return ESP_ERR_INVALID_SIZE;
    }
    return ESP_OK;
}

esp_err_t badge_storage_init(void)
{
    if (s_lock == NULL) {
        s_lock = xSemaphoreCreateMutex();
        if (s_lock == NULL) {
            return ESP_ERR_NO_MEM;
        }
    }

    ESP_RETURN_ON_ERROR(ensure_nvs(), TAG, "NVS init failed");

    esp_err_t ret = nvs_open(BADGE_NVS_NAMESPACE, NVS_READWRITE, &s_nvs);
    if (ret != ESP_OK) {
        return ret;
    }

    ESP_LOGI(TAG, "storage mode=sd-only");
    return ESP_OK;
}

esp_err_t badge_storage_begin_upload(uint32_t total_size, uint32_t expected_crc32)
{
    if (total_size < sizeof(badge_ebaj_header_t)) {
        return ESP_ERR_INVALID_SIZE;
    }

    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (s_upload.active) {
        xSemaphoreGive(s_lock);
        return ESP_ERR_INVALID_STATE;
    }

    memset(&s_upload, 0, sizeof(s_upload));
    memset(&s_last_upload_perf, 0, sizeof(s_last_upload_perf));
    s_upload.active = true;
    s_upload.expected_size = total_size;
    s_upload.expected_crc32 = expected_crc32;
    s_upload.crc = 0xffffffffu;
    s_upload.next_log_at = BADGE_UPLOAD_LOG_STEP;

    esp_err_t ret = begin_sd_upload_locked(total_size);
    if (ret != ESP_OK) {
        memset(&s_upload, 0, sizeof(s_upload));
        xSemaphoreGive(s_lock);
        return ret;
    }

    xSemaphoreGive(s_lock);
    return ESP_OK;
}

esp_err_t badge_storage_write_chunk(uint32_t offset, const uint8_t *data, size_t len)
{
    if (data == NULL || len == 0) {
        return ESP_ERR_INVALID_ARG;
    }

    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (!s_upload.active || offset != s_upload.received_size ||
        (uint64_t)s_upload.received_size + len > s_upload.expected_size) {
        xSemaphoreGive(s_lock);
        return ESP_ERR_INVALID_STATE;
    }

    int64_t storage_start_us = esp_timer_get_time();
    esp_err_t ret = write_sd_chunk_locked(data, len);
    s_last_upload_perf.storage_write_us += esp_timer_get_time() - storage_start_us;
    if (ret == ESP_OK) {
        int64_t crc_start_us = esp_timer_get_time();
        s_upload.crc = badge_crc32_update(s_upload.crc, data, len);
        s_last_upload_perf.crc_us += esp_timer_get_time() - crc_start_us;
        s_upload.received_size += len;
        if (s_upload.received_size >= s_upload.next_log_at || s_upload.received_size == s_upload.expected_size) {
            ESP_LOGI(TAG, "upload progress %" PRIu32 "/%" PRIu32,
                     s_upload.received_size, s_upload.expected_size);
            while (s_upload.next_log_at <= s_upload.received_size) {
                s_upload.next_log_at += BADGE_UPLOAD_LOG_STEP;
            }
        }
    }

    xSemaphoreGive(s_lock);
    return ret;
}

esp_err_t badge_storage_finish_upload(void)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (!s_upload.active || s_upload.received_size != s_upload.expected_size) {
        xSemaphoreGive(s_lock);
        return ESP_ERR_INVALID_STATE;
    }

    int64_t finish_start_us = esp_timer_get_time();
    FILE *file = s_upload.sd_file;
    s_upload.sd_file = NULL;
    if (file == NULL) {
        unlink(BADGE_SD_TEMP_PATH);
        s_upload.active = false;
        s_last_upload_perf.finish_us += esp_timer_get_time() - finish_start_us;
        xSemaphoreGive(s_lock);
        return ESP_ERR_INVALID_STATE;
    }
    int fd = fileno(file);
    bool flush_failed = fflush(file) != 0;
    bool fsync_failed = fd >= 0 && fsync(fd) != 0;
    bool close_failed = fclose(file) != 0;
    if (flush_failed || fsync_failed || close_failed) {
        unlink(BADGE_SD_TEMP_PATH);
        s_upload.active = false;
        s_last_upload_perf.finish_us += esp_timer_get_time() - finish_start_us;
        xSemaphoreGive(s_lock);
        return ESP_FAIL;
    }

    uint32_t transfer_crc = badge_crc32_finish(s_upload.crc);
    if (transfer_crc != s_upload.expected_crc32) {
        ESP_LOGE(TAG, "upload crc mismatch: got=%08" PRIx32 " expected=%08" PRIx32,
                 transfer_crc, s_upload.expected_crc32);
        unlink(BADGE_SD_TEMP_PATH);
        s_upload.active = false;
        s_last_upload_perf.finish_us += esp_timer_get_time() - finish_start_us;
        xSemaphoreGive(s_lock);
        return ESP_ERR_INVALID_CRC;
    }

    badge_ebaj_header_t header = {0};
    file = fopen(BADGE_SD_TEMP_PATH, "rb");
    esp_err_t ret = read_header_from_file(file, &header);
    if (file != NULL) {
        fclose(file);
    }
    if (ret == ESP_OK && !badge_protocol_validate_header(&header, UINT32_MAX)) {
        ret = ESP_ERR_INVALID_RESPONSE;
    }
    if (ret != ESP_OK || header.package_size != s_upload.expected_size) {
        ESP_LOGE(TAG, "uploaded asset header is invalid");
        unlink(BADGE_SD_TEMP_PATH);
        s_upload.active = false;
        s_last_upload_perf.finish_us += esp_timer_get_time() - finish_start_us;
        xSemaphoreGive(s_lock);
        return ESP_ERR_INVALID_RESPONSE;
    }

    errno = 0;
    int unlink_ret = unlink(BADGE_SD_ASSET_PATH);
    int unlink_errno = errno;
    if (unlink_ret != 0 && unlink_errno != ENOENT) {
        ESP_LOGW(TAG, "unlink old SD asset failed: errno=%d", unlink_errno);
    }
    errno = 0;
    if (rename(BADGE_SD_TEMP_PATH, BADGE_SD_ASSET_PATH) != 0) {
        int rename_errno = errno;
        ESP_LOGE(TAG, "rename SD temp asset failed: errno=%d unlink_ret=%d unlink_errno=%d",
                 rename_errno, unlink_ret, unlink_errno);
        unlink(BADGE_SD_TEMP_PATH);
        s_upload.active = false;
        s_last_upload_perf.finish_us += esp_timer_get_time() - finish_start_us;
        xSemaphoreGive(s_lock);
        return ESP_FAIL;
    }
    nvs_set_u32(s_nvs, BADGE_NVS_SIZE_KEY, s_upload.expected_size);
    nvs_set_u32(s_nvs, BADGE_NVS_CRC_KEY, s_upload.expected_crc32);
    nvs_commit(s_nvs);

    s_last_upload_perf.used_sd = true;
    s_last_upload_perf.finish_us += esp_timer_get_time() - finish_start_us;
    ESP_LOGI(TAG, "activated SD asset, frames=%u fps=%u size=%" PRIu32,
             header.frame_count, header.fps, header.package_size);
    memset(&s_upload, 0, sizeof(s_upload));
    xSemaphoreGive(s_lock);
    return ESP_OK;
}

void badge_storage_abort_upload(void)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (s_upload.sd_file != NULL) {
        fclose(s_upload.sd_file);
        s_upload.sd_file = NULL;
    }
    unlink(BADGE_SD_TEMP_PATH);
    memset(&s_upload, 0, sizeof(s_upload));
    xSemaphoreGive(s_lock);
}

esp_err_t badge_storage_open_active_asset(badge_asset_t *out)
{
    if (out == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    memset(out, 0, sizeof(*out));

    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (s_upload.active) {
        xSemaphoreGive(s_lock);
        return ESP_ERR_INVALID_STATE;
    }

    esp_err_t ret = ensure_sd_mounted_locked();
    if (ret != ESP_OK) {
        xSemaphoreGive(s_lock);
        return ret;
    }

    FILE *file = fopen(BADGE_SD_ASSET_PATH, "rb");
    if (file == NULL) {
        xSemaphoreGive(s_lock);
        return ESP_ERR_NOT_FOUND;
    }

    badge_ebaj_header_t header = {0};
    ret = read_header_from_file(file, &header);
    if (ret != ESP_OK || !badge_protocol_validate_header(&header, UINT32_MAX)) {
        fclose(file);
        xSemaphoreGive(s_lock);
        return ESP_ERR_INVALID_RESPONSE;
    }

    uint8_t *read_buf = heap_caps_malloc(BADGE_SD_READ_STAGING_BYTES, MALLOC_CAP_INTERNAL | MALLOC_CAP_DMA | MALLOC_CAP_8BIT);
    if (read_buf == NULL) {
        fclose(file);
        xSemaphoreGive(s_lock);
        return ESP_ERR_NO_MEM;
    }

    out->file = file;
    out->sd_read_buf = read_buf;
    out->sd_read_buf_size = BADGE_SD_READ_STAGING_BYTES;
    out->sd_file_pos = 0;
    out->header = header;
    xSemaphoreGive(s_lock);
    return ESP_OK;
}

void badge_storage_close_asset(badge_asset_t *asset)
{
    if (asset == NULL) {
        return;
    }
    if (asset->file != NULL) {
        fclose(asset->file);
    }
    if (asset->sd_read_buf != NULL) {
        heap_caps_free(asset->sd_read_buf);
    }
    memset(asset, 0, sizeof(*asset));
}

esp_err_t badge_storage_read_asset(badge_asset_t *asset, uint32_t offset, void *buffer, size_t len)
{
    if (asset == NULL || buffer == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    if (asset->file == NULL || asset->sd_read_buf == NULL || asset->sd_read_buf_size == 0) {
        return ESP_ERR_INVALID_STATE;
    }

    if (asset->sd_file_pos != offset) {
        if (fseek(asset->file, (long)offset, SEEK_SET) != 0) {
            return ESP_FAIL;
        }
        asset->sd_file_pos = offset;
    }

    uint8_t *dst = (uint8_t *)buffer;
    size_t remaining = len;
    while (remaining > 0) {
        size_t chunk = remaining > asset->sd_read_buf_size ? asset->sd_read_buf_size : remaining;
        size_t read_len = fread(asset->sd_read_buf, 1, chunk, asset->file);
        if (read_len != chunk) {
            return ESP_ERR_INVALID_SIZE;
        }
        memcpy(dst, asset->sd_read_buf, chunk);
        dst += chunk;
        remaining -= chunk;
        asset->sd_file_pos += chunk;
    }

    return ESP_OK;
}

esp_err_t badge_storage_read_asset_sequential(badge_asset_t *asset, void *buffer, size_t len)
{
    if (asset == NULL || buffer == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    if (asset->file == NULL || asset->sd_read_buf == NULL || asset->sd_read_buf_size == 0) {
        return ESP_ERR_INVALID_STATE;
    }

    uint8_t *dst = (uint8_t *)buffer;
    size_t remaining = len;
    while (remaining > 0) {
        size_t chunk = remaining > asset->sd_read_buf_size ? asset->sd_read_buf_size : remaining;
        size_t read_len = fread(asset->sd_read_buf, 1, chunk, asset->file);
        if (read_len != chunk) {
            return ESP_ERR_INVALID_SIZE;
        }
        memcpy(dst, asset->sd_read_buf, chunk);
        dst += chunk;
        remaining -= chunk;
        asset->sd_file_pos += chunk;
    }

    return ESP_OK;
}

bool badge_storage_sd_asset_available(void)
{
    bool available = false;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    badge_ebaj_header_t header = {0};
    available = read_header_from_sd_locked(&header);
    xSemaphoreGive(s_lock);
    return available;
}

void badge_storage_get_last_upload_perf(badge_upload_perf_t *out)
{
    if (out == NULL) {
        return;
    }
    xSemaphoreTake(s_lock, portMAX_DELAY);
    *out = s_last_upload_perf;
    xSemaphoreGive(s_lock);
}

void badge_storage_get_status(char *out, size_t out_len)
{
    if (out == NULL || out_len == 0) {
        return;
    }

    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (s_upload.active) {
        snprintf(out, out_len, "upload storage=sd sd=%d sd width=%u format=ebaj4 %" PRIu32 "/%" PRIu32,
                 s_sd_mounted ? 1 : 0,
                 s_sd_width,
                 s_upload.received_size, s_upload.expected_size);
    } else {
        badge_ebaj_header_t header = {0};
        bool sd_valid = read_header_from_sd_locked(&header);
        snprintf(out, out_len, "idle storage=%s sd=%d width=%u asset=%u format=%s fps=%u frames=%u",
                 sd_valid ? "sd" : "none",
                 s_sd_mounted ? 1 : 0,
                 s_sd_width,
                 sd_valid ? 1u : 0u,
                 sd_valid ? "ebaj4" : "none",
                 sd_valid ? header.fps : 0u,
                 sd_valid ? header.frame_count : 0u);
    }
    xSemaphoreGive(s_lock);
}

bool badge_storage_is_uploading(void)
{
    bool uploading;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    uploading = s_upload.active;
    xSemaphoreGive(s_lock);
    return uploading;
}
