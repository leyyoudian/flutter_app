#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#include "BadgeProtocol.h"

#include "esp_err.h"

#define BADGE_ASSET_SLOT_COUNT 1u

typedef struct {
    FILE *file;
    uint8_t *sd_read_buf;
    size_t sd_read_buf_size;
    uint32_t sd_file_pos;
    badge_ebaj_header_t header;
} badge_asset_t;

typedef struct {
    int64_t storage_write_us;
    int64_t crc_us;
    int64_t finish_us;
    bool used_sd;
} badge_upload_perf_t;

esp_err_t badge_storage_init(void);
esp_err_t badge_storage_begin_upload(uint32_t total_size, uint32_t expected_crc32);
esp_err_t badge_storage_write_chunk(uint32_t offset, const uint8_t *data, size_t len);
esp_err_t badge_storage_finish_upload(void);
void badge_storage_abort_upload(void);
esp_err_t badge_storage_open_active_asset(badge_asset_t *out);
void badge_storage_close_asset(badge_asset_t *asset);
esp_err_t badge_storage_read_asset(badge_asset_t *asset, uint32_t offset, void *buffer, size_t len);
esp_err_t badge_storage_read_asset_sequential(badge_asset_t *asset, void *buffer, size_t len);
bool badge_storage_sd_asset_available(void);
void badge_storage_get_last_upload_perf(badge_upload_perf_t *out);
void badge_storage_get_status(char *out, size_t out_len);
bool badge_storage_is_uploading(void);
