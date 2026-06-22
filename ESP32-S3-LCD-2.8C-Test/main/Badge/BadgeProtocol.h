#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"

#define BADGE_EBAJ_MAGIC_V4 0x344a4142u /* "BAJ4" little endian */
#define BADGE_EBAJ_MAGIC BADGE_EBAJ_MAGIC_V4
#define BADGE_EBAJ_VERSION_V4 4u
#define BADGE_EBAJ_VERSION BADGE_EBAJ_VERSION_V4
#define BADGE_EBAJ_WIDTH 480u
#define BADGE_EBAJ_HEIGHT 480u
#define BADGE_EBAJ_PIXELS (BADGE_EBAJ_WIDTH * BADGE_EBAJ_HEIGHT)
#define BADGE_EBAJ_FRAME_BYTES (BADGE_EBAJ_PIXELS * 2u)
#define BADGE_EBAJ_FPS 20u
#define BADGE_EBAJ_FRAME_DELAY_MS 50u
#define BADGE_EBAJ_PALETTE_ENTRIES 256u
#define BADGE_EBAJ_TILE_SIZE 16u

typedef enum {
    BADGE_BLE_CMD_START = 0x01,
    BADGE_BLE_CMD_FINISH = 0x02,
    BADGE_BLE_CMD_ABORT = 0x03,
    BADGE_BLE_CMD_STATUS = 0x04,
    BADGE_BLE_CMD_SET_BRIGHTNESS = 0x10,
} badge_ble_cmd_t;

typedef enum {
    BADGE_FRAME_INDEXED_KEY = 0x10,
    BADGE_FRAME_INDEXED_TILE = 0x11,
    BADGE_FRAME_INDEXED_REPEAT = 0x12,
} badge_frame_codec_t;

typedef struct {
    uint32_t total_size;
    uint32_t crc32;
} badge_upload_start_t;

typedef struct {
    uint32_t offset;
    const uint8_t *payload;
    size_t payload_len;
} badge_data_chunk_t;

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint16_t version;
    uint16_t header_size;
    uint16_t width;
    uint16_t height;
    uint16_t frame_count;
    uint16_t fps;
    uint32_t frame_table_offset;
    uint32_t frame_data_offset;
    uint32_t package_size;
    uint32_t package_crc32;
    uint32_t flags;
    uint16_t stream_width;
    uint16_t stream_height;
    uint16_t palette_entries;
    uint16_t reserved;
} badge_ebaj_header_t;

_Static_assert(sizeof(badge_ebaj_header_t) == 44, "EBAJ4 header size must be 44 bytes");

typedef struct __attribute__((packed)) {
    uint32_t data_offset;
    uint32_t data_size;
    uint16_t delay_ms;
    uint8_t codec;
    uint8_t flags;
    uint16_t width;
    uint16_t height;
} badge_ebaj_frame_t;

_Static_assert(sizeof(badge_ebaj_frame_t) == 16, "EBAJ4 frame entry size must be 16 bytes");

esp_err_t badge_protocol_parse_start(const uint8_t *data, size_t len, badge_upload_start_t *out);
esp_err_t badge_protocol_parse_data_chunk(const uint8_t *data, size_t len, badge_data_chunk_t *out);
bool badge_protocol_validate_header(const badge_ebaj_header_t *header, uint32_t slot_size);
uint32_t badge_crc32_update(uint32_t crc, const uint8_t *data, size_t len);
uint32_t badge_crc32_finish(uint32_t crc);
