#pragma once

#include <stddef.h>
#include <stdint.h>

#include "BadgeProtocol.h"
#include "BadgeStorage.h"

#include "esp_err.h"

typedef struct {
    uint16_t frame_index;
    uint8_t *data;
    size_t size;
    esp_err_t status;
    int64_t read_us;
} badge_stream_frame_t;

typedef struct badge_stream badge_stream_t;

esp_err_t badge_stream_start(badge_asset_t *asset,
                             const badge_ebaj_frame_t *frames,
                             uint16_t frame_count,
                             uint16_t start_index,
                             badge_stream_t **out_stream);
esp_err_t badge_stream_read_frame(badge_stream_t *stream,
                                  badge_stream_frame_t *out_frame,
                                  uint32_t timeout_ms);
void badge_stream_release_frame(badge_stream_t *stream, badge_stream_frame_t *frame);
void badge_stream_stop(badge_stream_t *stream);
