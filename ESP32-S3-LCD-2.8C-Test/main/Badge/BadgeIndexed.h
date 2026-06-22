#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "BadgeProtocol.h"

#include "esp_err.h"

typedef struct {
    uint16_t width;
    uint16_t height;
    uint8_t *buffers[2];
    uint16_t palette[2][BADGE_EBAJ_PALETTE_ENTRIES];
    int active;
    bool has_frame;
} badge_indexed_t;

esp_err_t badge_indexed_init(badge_indexed_t *indexed, uint16_t width, uint16_t height);
void badge_indexed_deinit(badge_indexed_t *indexed);
esp_err_t badge_indexed_decode(badge_indexed_t *indexed,
                               const badge_ebaj_frame_t *frame,
                               const uint8_t *payload,
                               size_t payload_size);
esp_err_t badge_indexed_render_rgb565(const badge_indexed_t *indexed, uint16_t *rgb565);
