#pragma once

#include "esp_err.h"
#include "freertos/FreeRTOS.h"

esp_err_t badge_display_init(void);
void badge_display_request_reload(void);
esp_err_t badge_display_enter_upload_mode(TickType_t timeout_ticks);
void badge_display_exit_upload_mode(void);
esp_err_t badge_display_pause_for_upload(TickType_t timeout_ticks);
void badge_display_resume_after_upload(void);
