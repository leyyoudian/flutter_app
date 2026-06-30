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

static bool palette_matches(const uint16_t *palette, const uint8_t *payload)
{
    for (uint16_t i = 0; i < BADGE_EBAJ_PALETTE_ENTRIES; ++i) {
        if (palette[i] != read_le16(payload + i * 2u)) {
            return false;
        }
    }
    return true;
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

    indexed->dirty_tile_capacity = (uint16_t)((width / BADGE_EBAJ_TILE_SIZE) * (height / BADGE_EBAJ_TILE_SIZE));
    indexed->dirty_tiles = heap_caps_malloc((size_t)indexed->dirty_tile_capacity * sizeof(uint16_t),
                                            MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (indexed->dirty_tiles == NULL) {
        badge_indexed_deinit(indexed);
        return ESP_ERR_NO_MEM;
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
    if (indexed->dirty_tiles != NULL) {
        heap_caps_free(indexed->dirty_tiles);
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
    indexed->full_dirty = true;
    indexed->dirty_tile_count = 0;
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
    if (tile_count > indexed->dirty_tile_capacity) {
        return ESP_ERR_INVALID_SIZE;
    }

    int next = indexed->active;
    bool palette_changed = !palette_matches(indexed->palette[next], payload);
    load_palette(indexed->palette[next], payload);
    indexed->dirty_tile_count = tile_count;

    const uint8_t *src = payload + BADGE_INDEXED_PALETTE_BYTES + 2u;
    for (uint16_t i = 0; i < tile_count; ++i) {
        uint16_t tile_index = read_le16(src);
        src += 2u;
        if (tile_index >= max_tiles) {
            return ESP_ERR_INVALID_RESPONSE;
        }
        indexed->dirty_tiles[i] = tile_index;

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
    indexed->full_dirty = palette_changed;
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

/* Bilinear-interpolate four RGB565 pixels.  fx, fy are 0..255 fractional weights. */
static inline uint16_t bilinear_rgb565(uint16_t p00, uint16_t p01,
                                       uint16_t p10, uint16_t p11,
                                       uint32_t fx, uint32_t fy)
{
    /* Unpack each 5-6-5 pixel into 8-bit channels (left-aligned for precision). */
    uint32_t r00 = (p00 >> 8) & 0xF8; /* R: high 5 bits ¡ú top of 8 */
    uint32_t g00 = (p00 >> 3) & 0xFC; /* G: high 6 bits ¡ú top of 8 */
    uint32_t b00 = (p00 << 3) & 0xF8; /* B: low 5 bits ¡ú top of 8 */

    uint32_t r01 = (p01 >> 8) & 0xF8;
    uint32_t g01 = (p01 >> 3) & 0xFC;
    uint32_t b01 = (p01 << 3) & 0xF8;

    uint32_t r10 = (p10 >> 8) & 0xF8;
    uint32_t g10 = (p10 >> 3) & 0xFC;
    uint32_t b10 = (p10 << 3) & 0xF8;

    uint32_t r11 = (p11 >> 8) & 0xF8;
    uint32_t g11 = (p11 >> 3) & 0xFC;
    uint32_t b11 = (p11 << 3) & 0xF8;

    uint32_t ifx = 256u - fx;
    uint32_t ify = 256u - fy;

    /* Horizontal blend first. */
    uint32_t r0 = (r00 * ifx + r01 * fx) >> 8;
    uint32_t g0 = (g00 * ifx + g01 * fx) >> 8;
    uint32_t b0 = (b00 * ifx + b01 * fx) >> 8;
    uint32_t r1 = (r10 * ifx + r11 * fx) >> 8;
    uint32_t g1 = (g10 * ifx + g11 * fx) >> 8;
    uint32_t b1 = (b10 * ifx + b11 * fx) >> 8;

    /* Vertical blend. */
    uint32_t r = (r0 * ify + r1 * fy) >> 8;
    uint32_t g = (g0 * ify + g1 * fy) >> 8;
    uint32_t b = (b0 * ify + b1 * fy) >> 8;

    /* Repack to RGB565. */
    return (uint16_t)(((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3));
}

static esp_err_t render_scaled_rgb565(const badge_indexed_t *indexed, uint16_t *rgb565)
{
    if (indexed == NULL || rgb565 == NULL || !indexed->has_frame) {
        return ESP_ERR_INVALID_STATE;
    }

    const uint8_t *src = indexed->buffers[indexed->active];
    const uint16_t *palette = indexed->palette[indexed->active];
    const uint32_t scale_mul_x = ((uint32_t)indexed->width << 16) / BADGE_EBAJ_WIDTH;
    const uint32_t scale_mul_y = ((uint32_t)indexed->height << 16) / BADGE_EBAJ_HEIGHT;

    /* Pre-compute source-X integer + fractional parts (8-bit fraction). */
    uint16_t src_x_int[BADGE_EBAJ_WIDTH];
    uint8_t  src_x_frac[BADGE_EBAJ_WIDTH];
    for (uint16_t x = 0; x < BADGE_EBAJ_WIDTH; ++x) {
        uint32_t v = x * scale_mul_x;
        src_x_int[x]  = (uint16_t)(v >> 16);
        src_x_frac[x] = (uint8_t)((v >> 8) & 0xFF);
    }

    uint16_t src_w = indexed->width;
    uint16_t src_h = indexed->height;

    for (uint16_t y = 0; y < BADGE_EBAJ_HEIGHT; ++y) {
        uint32_t vy = y * scale_mul_y;
        uint16_t src_y      = (uint16_t)(vy >> 16);
        uint8_t  src_y_frac = (uint8_t)((vy >> 8) & 0xFF);
        uint16_t src_y_next = (src_y + 1u < src_h) ? src_y + 1u : src_y;

        const uint8_t *src_row0 = src + (size_t)src_y * src_w;
        const uint8_t *src_row1 = src + (size_t)src_y_next * src_w;
        uint16_t *dst_row = rgb565 + (size_t)y * BADGE_EBAJ_WIDTH;

        for (uint16_t x = 0; x < BADGE_EBAJ_WIDTH; ++x) {
            uint16_t sx      = src_x_int[x];
            uint8_t  sx_frac = src_x_frac[x];
            uint16_t sx_next = (sx + 1u < src_w) ? sx + 1u : sx;

            uint16_t p00 = palette[src_row0[sx]];
            uint16_t p01 = palette[src_row0[sx_next]];
            uint16_t p10 = palette[src_row1[sx]];
            uint16_t p11 = palette[src_row1[sx_next]];

            dst_row[x] = bilinear_rgb565(p00, p01, p10, p11, sx_frac, src_y_frac);
        }
    }

    return ESP_OK;
}

static esp_err_t render_native_rgb565(const badge_indexed_t *indexed, uint16_t *rgb565)
{
    if (indexed == NULL || rgb565 == NULL || !indexed->has_frame) {
        return ESP_ERR_INVALID_STATE;
    }

    const uint8_t *src = indexed->buffers[indexed->active];
    const uint16_t *palette = indexed->palette[indexed->active];
    for (uint16_t y = 0; y < BADGE_EBAJ_HEIGHT; ++y) {
        const uint8_t *src_row = src + (size_t)y * BADGE_EBAJ_WIDTH;
        uint16_t *dst_row = rgb565 + (size_t)y * BADGE_EBAJ_WIDTH;
        uint16_t x = 0;
        /* Write 8 pixels (four 32-bit stores) per iteration for throughput. */
        for (; x + 7u < BADGE_EBAJ_WIDTH; x += 8u) {
            uint32_t p01 = ((uint32_t)palette[src_row[x + 1u]] << 16) | palette[src_row[x]];
            uint32_t p23 = ((uint32_t)palette[src_row[x + 3u]] << 16) | palette[src_row[x + 2u]];
            uint32_t p45 = ((uint32_t)palette[src_row[x + 5u]] << 16) | palette[src_row[x + 4u]];
            uint32_t p67 = ((uint32_t)palette[src_row[x + 7u]] << 16) | palette[src_row[x + 6u]];
            uint32_t *dst32 = (uint32_t *)(dst_row + x);
            dst32[0] = p01;
            dst32[1] = p23;
            dst32[2] = p45;
            dst32[3] = p67;
        }
        for (; x < BADGE_EBAJ_WIDTH; ++x) {
            dst_row[x] = palette[src_row[x]];
        }
    }

    return ESP_OK;
}

static esp_err_t blit_native_dirty_tiles_rgb565(const badge_indexed_t *indexed, uint16_t *rgb565)
{
    if (indexed == NULL || rgb565 == NULL || !indexed->has_frame) {
        return ESP_ERR_INVALID_STATE;
    }
    if (indexed->full_dirty) {
        return render_native_rgb565(indexed, rgb565);
    }
    if (indexed->dirty_tile_count > indexed->dirty_tile_capacity / 2u) {
        return render_native_rgb565(indexed, rgb565);
    }

    const uint8_t *src = indexed->buffers[indexed->active];
    const uint16_t *palette = indexed->palette[indexed->active];
    const uint16_t tile_cols = indexed->width / BADGE_EBAJ_TILE_SIZE;

    for (uint16_t i = 0; i < indexed->dirty_tile_count; ++i) {
        uint16_t tile_index = indexed->dirty_tiles[i];
        uint16_t tile_x = (tile_index % tile_cols) * BADGE_EBAJ_TILE_SIZE;
        uint16_t tile_y = (tile_index / tile_cols) * BADGE_EBAJ_TILE_SIZE;
        for (uint16_t row = 0; row < BADGE_EBAJ_TILE_SIZE; ++row) {
            const uint8_t *src_row = src + (size_t)(tile_y + row) * BADGE_EBAJ_WIDTH + tile_x;
            uint16_t *dst_row = rgb565 + (size_t)(tile_y + row) * BADGE_EBAJ_WIDTH + tile_x;
            for (uint16_t x = 0; x < BADGE_EBAJ_TILE_SIZE; ++x) {
                dst_row[x] = palette[src_row[x]];
            }
        }
    }

    return ESP_OK;
}

esp_err_t badge_indexed_render_rgb565(const badge_indexed_t *indexed, uint16_t *rgb565)
{
    if (indexed != NULL && indexed->width == BADGE_EBAJ_WIDTH && indexed->height == BADGE_EBAJ_HEIGHT) {
        return render_native_rgb565(indexed, rgb565);
    }
    return render_scaled_rgb565(indexed, rgb565);
}

bool badge_indexed_dirty_rgb565_is_partial(const badge_indexed_t *indexed)
{
    return indexed != NULL &&
           indexed->has_frame &&
           !indexed->full_dirty &&
           indexed->width == BADGE_EBAJ_WIDTH &&
           indexed->height == BADGE_EBAJ_HEIGHT &&
           indexed->dirty_tile_count <= indexed->dirty_tile_capacity / 2u;
}

esp_err_t badge_indexed_blit_dirty_rgb565(const badge_indexed_t *indexed, uint16_t *rgb565)
{
    if (indexed != NULL && indexed->width == BADGE_EBAJ_WIDTH && indexed->height == BADGE_EBAJ_HEIGHT) {
        return blit_native_dirty_tiles_rgb565(indexed, rgb565);
    }
    return badge_indexed_render_rgb565(indexed, rgb565);
}
