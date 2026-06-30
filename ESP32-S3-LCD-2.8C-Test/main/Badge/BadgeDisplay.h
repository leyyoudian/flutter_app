#pragma once

#include <stdint.h>
#include "esp_err.h"
#include "freertos/FreeRTOS.h"

typedef enum {
    BADGE_PLAY_MODE_LOOP = 0,
    BADGE_PLAY_MODE_FIRST_HALF_FREEZE,
    BADGE_PLAY_MODE_SECOND_HALF,
} badge_play_mode_t;

esp_err_t badge_display_init(void);
void badge_display_request_reload(void);

/** Play an asset file directly by path with the given mode. */
esp_err_t badge_display_play_asset_file(const char *path, badge_play_mode_t mode);

esp_err_t badge_display_enter_upload_mode(TickType_t timeout_ticks);
void badge_display_exit_upload_mode(void);
esp_err_t badge_display_pause_for_upload(TickType_t timeout_ticks);
void badge_display_resume_after_upload(void);
