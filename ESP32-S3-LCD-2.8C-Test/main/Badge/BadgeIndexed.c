#include "BadgeIndexed.h"

#include <string.h>

#include "esp_heap_caps.h"

#define BADGE_INDEXED_PALETTE_BYTES (BADGE_EBAJ_PALETTE_ENTRIES * 2u)

static uint16_t read_le16(const uint8_t *data)
{
    return (uint16_t)data[0] | ((uint16_t)data[1] << 8);
}

static bool valid_stream_size(uint16_t width, uint16_t height)
{
    return (width == height) && (width == 480u || width == 320u || width == 240u);
}

static void load_palette(uint16_t *palette, const uint8_t *payload)
{
    for (uint16_t i = 0; i < BADGE_EBAJ_PALETTE_ENTRIES; ++i) {
        palette[i] = read_le16(payload + i * 2u);
    }
}

esp_err_t badge_indexed_init(badge_indexed_t *indexed, uint16_t width, uint16_t height)
{
    if (indexed == NULL || !valid_stream_size(width, height)) {
        return ESP_ERR_INVALID_ARG;
    }

    memset(indexed, 0, sizeof(*indexed));
    indexed->width = width;
    indexed->height = height;
    indexed->active = 0;

    size_t frame_bytes = (size_t)width * height;
    for (int i = 0; i < 2; ++i) {
        indexed->buffers[i] = heap_caps_malloc(frame_bytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
        if (indexed->buffers[i] == NULL) {
            badge_indexed_deinit(indexed);
            return ESP_ERR_NO_MEM;
        }
    }

    return ESP_OK;
}

void badge_indexed_deinit(badge_indexed_t *indexed)
{
    if (indexed == NULL) {
        return;
    }

    for (int i = 0; i < 2; ++i) {
        if (indexed->buffers[i] != NULL) {
            heap_caps_free(indexed->buffers[i]);
        }
    }
    memset(indexed, 0, sizeof(*indexed));
}

static esp_err_t decode_indexed_key(badge_indexed_t *indexed, const uint8_t *payload, size_t payload_size)
{
    size_t frame_bytes = (size_t)indexed->width * indexed->height;
    size_t expected = BADGE_INDEXED_PALETTE_BYTES + frame_bytes;
    if (payload == NULL || payload_size != expected) {
        return ESP_ERR_INVALID_SIZE;
    }

    int next = indexed->has_frame ? 1 - indexed->active : indexed->active;
    load_palette(indexed->palette[next], payload);
    memcpy(indexed->buffers[next], payload + BADGE_INDEXED_PALETTE_BYTES, frame_bytes);
    indexed->active = next;
    indexed->has_frame = true;
    return ESP_OK;
}

static esp_err_t apply_indexed_tile_payload(badge_indexed_t *indexed, const uint8_t *payload, size_t payload_size)
{
    if (payload == NULL || payload_size < BADGE_INDEXED_PALETTE_BYTES + 2u || !indexed->has_frame) {
        return ESP_ERR_INVALID_RESPONSE;
    }

    uint16_t tile_count = read_le16(payload + BADGE_INDEXED_PALETTE_BYTES);
    size_t tile_record_bytes = 2u + BADGE_EBAJ_TILE_SIZE * BADGE_EBAJ_TILE_SIZE;
    size_t expected = BADGE_INDEXED_PALETTE_BYTES + 2u + (size_t)tile_count * tile_record_bytes;
    if (payload_size != expected) {
        return ESP_ERR_INVALID_SIZE;
    }

    uint16_t tile_cols = indexed->width / BADGE_EBAJ_TILE_SIZE;
    uint16_t tile_rows = indexed->height / BADGE_EBAJ_TILE_SIZE;
    uint16_t max_tiles = tile_cols * tile_rows;
    if (tile_count > max_tiles) {
        return ESP_ERR_INVALID_SIZE;
    }

    int next = 1 - indexed->active;
    size_t frame_bytes = (size_t)indexed->width * indexed->height;
    memcpy(indexed->buffers[next], indexed->buffers[indexed->active], frame_bytes);
    load_palette(indexed->palette[next], payload);

    const uint8_t *src = payload + BADGE_INDEXED_PALETTE_BYTES + 2u;
    for (uint16_t i = 0; i < tile_count; ++i) {
        uint16_t tile_index = read_le16(src);
        src += 2u;
        if (tile_index >= max_tiles) {
            return ESP_ERR_INVALID_RESPONSE;
        }

        uint16_t tile_x = (tile_index % tile_cols) * BADGE_EBAJ_TILE_SIZE;
        uint16_t tile_y = (tile_index / tile_cols) * BADGE_EBAJ_TILE_SIZE;
        for (uint16_t row = 0; row < BADGE_EBAJ_TILE_SIZE; ++row) {
            uint8_t *dst = indexed->buffers[next] + (size_t)(tile_y + row) * indexed->width + tile_x;
            memcpy(dst, src, BADGE_EBAJ_TILE_SIZE);
            src += BADGE_EBAJ_TILE_SIZE;
        }
    }

    indexed->active = next;
    indexed->has_frame = true;
    return ESP_OK;
}

static esp_err_t decode_indexed_repeat(badge_indexed_t *indexed, size_t payload_size)
{
    if (!indexed->has_frame || payload_size != 0) {
        return ESP_ERR_INVALID_RESPONSE;
    }
    return ESP_OK;
}

esp_err_t badge_indexed_decode(badge_indexed_t *indexed,
                               const badge_ebaj_frame_t *frame,
                               const uint8_t *payload,
                               size_t payload_size)
{
    if (indexed == NULL || frame == NULL || frame->width != indexed->width || frame->height != indexed->height) {
        return ESP_ERR_INVALID_ARG;
    }

    switch (frame->codec) {
    case BADGE_FRAME_INDEXED_KEY:
        return decode_indexed_key(indexed, payload, payload_size);
    case BADGE_FRAME_INDEXED_TILE:
        return apply_indexed_tile_payload(indexed, payload, payload_size);
    case BADGE_FRAME_INDEXED_REPEAT:
        return decode_indexed_repeat(indexed, payload_size);
    default:
        return ESP_ERR_INVALID_ARG;
    }
}

static esp_err_t render_scaled_rgb565(const badge_indexed_t *indexed, uint16_t *rgb565)
{
    if (indexed == NULL || rgb565 == NULL || !indexed->has_frame) {
        return ESP_ERR_INVALID_STATE;
    }

    const uint8_t *src = indexed->buffers[indexed->active];
    const uint16_t *palette = indexed->palette[indexed->active];
    for (uint16_t y = 0; y < BADGE_EBAJ_HEIGHT; ++y) {
        uint16_t src_y = (uint32_t)y * indexed->height / BADGE_EBAJ_HEIGHT;
        const uint8_t *src_row = src + (size_t)src_y * indexed->width;
        uint16_t *dst_row = rgb565 + (size_t)y * BADGE_EBAJ_WIDTH;
        for (uint16_t x = 0; x < BADGE_EBAJ_WIDTH; ++x) {
            uint16_t src_x = (uint32_t)x * indexed->width / BADGE_EBAJ_WIDTH;
            dst_row[x] = palette[src_row[src_x]];
        }
    }

    return ESP_OK;
}

esp_err_t badge_indexed_render_rgb565(const badge_indexed_t *indexed, uint16_t *rgb565)
{
    return render_scaled_rgb565(indexed, rgb565);
}
