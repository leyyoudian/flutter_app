#include "BadgeDisplay.h"

#include <inttypes.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include "BadgeIndexed.h"
#include "BadgeProtocol.h"
#include "BadgeStorage.h"
#include "BadgeStream.h"
#include "ST7701S.h"

#include "esp_check.h"
#include "esp_heap_caps.h"
#include "esp_lcd_panel_rgb.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"
#include "freertos/task.h"

#define BADGE_RELOAD_BIT BIT0
#define BADGE_STOPPED_BIT BIT1
#define BADGE_PAUSE_BIT BIT2
#define BADGE_PLAYER_STACK 8192u
#define BADGE_PLAYER_PRIORITY 4u
#define BADGE_STATUS_PERIOD_MS 250u
#define BADGE_FB_COUNT 3u
#define BADGE_FPS_OVERLAY_ENABLED 0u
#define BADGE_TARGET_FRAME_US 50000

static const char *TAG = "BadgeDisplay";
static EventGroupHandle_t s_events;
static TaskHandle_t s_player_task;
static void *s_fb[BADGE_FB_COUNT];
static int s_display_fb;
static int s_next_render_fb = 1;
static int64_t s_perf_window_us;
static uint32_t s_perf_frames;
static uint32_t s_perf_source_frames;
static uint32_t s_perf_underrun;
static uint32_t s_perf_repeat;
static int64_t s_perf_read_us;
static int64_t s_perf_decode_us;
static int64_t s_perf_render_us;
static int64_t s_perf_display_us;
static int64_t s_perf_vsync_us;

static void switch_panel_to_fb(int fb_index, int64_t *out_display_us, int64_t *out_vsync_us);

static esp_err_t timed_asset_read(badge_asset_t *asset, uint32_t offset, void *buffer, size_t len)
{
    return badge_storage_read_asset(asset, offset, buffer, len);
}

static esp_err_t load_frame_table(badge_asset_t *asset, badge_ebaj_frame_t **out_frames)
{
    size_t table_bytes = (size_t)asset->header.frame_count * sizeof(badge_ebaj_frame_t);
    badge_ebaj_frame_t *frames = heap_caps_malloc(table_bytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (frames == NULL) {
        return ESP_ERR_NO_MEM;
    }

    esp_err_t ret = timed_asset_read(asset, asset->header.frame_table_offset, frames, table_bytes);
    if (ret != ESP_OK) {
        heap_caps_free(frames);
        return ret;
    }

    for (uint16_t i = 0; i < asset->header.frame_count; ++i) {
        const badge_ebaj_frame_t *frame = &frames[i];
        uint64_t frame_end = (uint64_t)frame->data_offset + frame->data_size;
        bool valid_codec = frame->codec == BADGE_FRAME_INDEXED_KEY ||
                           frame->codec == BADGE_FRAME_INDEXED_TILE ||
                           frame->codec == BADGE_FRAME_INDEXED_REPEAT;
        if (!valid_codec ||
            frame->delay_ms != BADGE_EBAJ_FRAME_DELAY_MS ||
            frame->width != asset->header.stream_width ||
            frame->height != asset->header.stream_height ||
            frame_end > asset->header.package_size) {
            heap_caps_free(frames);
            return ESP_ERR_INVALID_RESPONSE;
        }
        if (i == 0 && frame->codec != BADGE_FRAME_INDEXED_KEY) {
            heap_caps_free(frames);
            return ESP_ERR_INVALID_RESPONSE;
        }
    }

    *out_frames = frames;
    return ESP_OK;
}

static void log_frame_codec_summary(const badge_asset_t *asset, const badge_ebaj_frame_t *frames)
{
    uint32_t key = 0;
    uint32_t tile = 0;
    uint32_t repeat = 0;
    uint32_t other = 0;

    for (uint16_t i = 0; i < asset->header.frame_count; ++i) {
        switch (frames[i].codec) {
        case BADGE_FRAME_INDEXED_KEY:
            ++key;
            break;
        case BADGE_FRAME_INDEXED_TILE:
            ++tile;
            break;
        case BADGE_FRAME_INDEXED_REPEAT:
            ++repeat;
            break;
        default:
            ++other;
            break;
        }
    }

    ESP_LOGI(TAG,
             "asset format magic=%08" PRIx32 " version=%u frames=%u fps=%u stream=%ux%u key=%" PRIu32
             " tile=%" PRIu32 " repeat=%" PRIu32 " other=%" PRIu32,
             asset->header.magic,
             asset->header.version,
             asset->header.frame_count,
             asset->header.fps,
             asset->header.stream_width,
             asset->header.stream_height,
             key,
             tile,
             repeat,
             other);
}

static void reset_playback_perf_counter(void)
{
    s_perf_window_us = 0;
    s_perf_frames = 0;
    s_perf_source_frames = 0;
    s_perf_underrun = 0;
    s_perf_repeat = 0;
    s_perf_read_us = 0;
    s_perf_decode_us = 0;
    s_perf_render_us = 0;
    s_perf_display_us = 0;
    s_perf_vsync_us = 0;
}

static void update_playback_perf_counter(const badge_asset_t *asset)
{
    int64_t now = esp_timer_get_time();
    if (s_perf_window_us == 0) {
        s_perf_window_us = now;
    }

    ++s_perf_frames;
    int64_t elapsed_us = now - s_perf_window_us;
    if (elapsed_us < 1000000) {
        return;
    }

    ESP_LOGI(TAG,
             "play perf storage=sd format=ebaj4 frames=%" PRIu32 " source=%" PRIu32
             " stream=%ux%u read=%lldms decode=%lldms render=%lldms display=%lldms vsync=%lldms underrun=%" PRIu32
             " repeat=%" PRIu32,
             s_perf_frames,
             s_perf_source_frames,
             asset->header.stream_width,
             asset->header.stream_height,
             (long long)(s_perf_read_us / 1000),
             (long long)(s_perf_decode_us / 1000),
             (long long)(s_perf_render_us / 1000),
             (long long)(s_perf_display_us / 1000),
             (long long)(s_perf_vsync_us / 1000),
             s_perf_underrun,
             s_perf_repeat);
    reset_playback_perf_counter();
    s_perf_window_us = now;
}

static int choose_render_fb(void)
{
    s_next_render_fb = (s_next_render_fb + 1) % (int)BADGE_FB_COUNT;
    return s_next_render_fb;
}

static void show_waiting_screen(void)
{
    if (s_fb[0] == NULL || s_fb[1] == NULL || s_fb[2] == NULL) {
        return;
    }

    for (size_t i = 0; i < BADGE_FB_COUNT; ++i) {
        memset(s_fb[i], 0x00, BADGE_EBAJ_FRAME_BYTES);
    }
    switch_panel_to_fb(0, NULL, NULL);
    s_next_render_fb = 0;
}

static void show_upload_screen(void)
{
    if (s_fb[0] == NULL || s_fb[1] == NULL || s_fb[2] == NULL) {
        return;
    }

    for (size_t i = 0; i < BADGE_FB_COUNT; ++i) {
        memset(s_fb[i], 0x00, BADGE_EBAJ_FRAME_BYTES);
    }
    switch_panel_to_fb(0, NULL, NULL);
    s_next_render_fb = 0;
    s_display_fb = 0;
}

static void render_status_if_needed(esp_err_t err)
{
    static bool shown_waiting;
    static int64_t last_ms;
    int64_t now_ms = esp_timer_get_time() / 1000;
    if (now_ms - last_ms < BADGE_STATUS_PERIOD_MS) {
        return;
    }
    last_ms = now_ms;

    if (err == ESP_ERR_NOT_FOUND && !shown_waiting) {
        show_waiting_screen();
        shown_waiting = true;
    }
}

static void switch_panel_to_fb(int fb_index, int64_t *out_display_us, int64_t *out_vsync_us)
{
    uint8_t *fb = (uint8_t *)s_fb[fb_index];
    int64_t display_start_us = esp_timer_get_time();
    esp_err_t draw_ret = esp_lcd_panel_draw_bitmap(panel_handle, 0, 0, BADGE_EBAJ_WIDTH, BADGE_EBAJ_HEIGHT, fb);
    int64_t vsync_start_us = esp_timer_get_time();
    esp_err_t vsync_ret = LCD_WaitForVsync(pdMS_TO_TICKS(20));
    int64_t done_us = esp_timer_get_time();
    if (draw_ret != ESP_OK) {
        ESP_LOGW(TAG, "draw_bitmap failed: %s", esp_err_to_name(draw_ret));
    }
    if (vsync_ret != ESP_OK) {
        ESP_LOGW(TAG, "vsync wait failed: %s", esp_err_to_name(vsync_ret));
    }
    if (out_display_us != NULL) {
        *out_display_us += vsync_start_us - display_start_us;
    }
    if (out_vsync_us != NULL) {
        *out_vsync_us += done_us - vsync_start_us;
    }
    s_display_fb = fb_index;
}

static esp_err_t render_stream_frame(badge_indexed_t *indexed,
                                     const badge_ebaj_frame_t *frame,
                                     const badge_stream_frame_t *stream_frame,
                                     int render_fb)
{
    int64_t decode_start_us = esp_timer_get_time();
    esp_err_t ret = badge_indexed_decode(indexed, frame, stream_frame->data, stream_frame->size);
    s_perf_decode_us += esp_timer_get_time() - decode_start_us;
    if (ret != ESP_OK) {
        return ret;
    }

    int64_t render_start_us = esp_timer_get_time();
    ret = badge_indexed_render_rgb565(indexed, (uint16_t *)s_fb[render_fb]);
    s_perf_render_us += esp_timer_get_time() - render_start_us;
    return ret;
}

static esp_err_t player_loop_asset(badge_asset_t *asset)
{
    badge_ebaj_frame_t *frames = NULL;
    esp_err_t ret = load_frame_table(asset, &frames);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "frame table load failed: %s", esp_err_to_name(ret));
        render_status_if_needed(ret);
        return ret;
    }

    xEventGroupClearBits(s_events, BADGE_STOPPED_BIT);
    log_frame_codec_summary(asset, frames);

    badge_indexed_t indexed = {0};
    ret = badge_indexed_init(&indexed, asset->header.stream_width, asset->header.stream_height);
    if (ret != ESP_OK) {
        heap_caps_free(frames);
        return ret;
    }

    badge_stream_t *stream = NULL;
    ret = badge_stream_start(asset, frames, asset->header.frame_count, 0, &stream);
    if (ret != ESP_OK) {
        badge_indexed_deinit(&indexed);
        heap_caps_free(frames);
        return ret;
    }

    ESP_LOGI(TAG, "playing storage=sd format=ebaj4 frames=%u fps=%u stream=%ux%u",
             asset->header.frame_count,
             asset->header.fps,
             asset->header.stream_width,
             asset->header.stream_height);
    reset_playback_perf_counter();

    int64_t next_tick_us = esp_timer_get_time();
    int last_render_fb = s_display_fb;

    while ((xEventGroupGetBits(s_events) & BADGE_RELOAD_BIT) == 0) {
        int64_t now = esp_timer_get_time();
        if (next_tick_us > now) {
            uint32_t wait_ms = (uint32_t)((next_tick_us - now) / 1000);
            EventBits_t bits = xEventGroupWaitBits(s_events, BADGE_RELOAD_BIT, pdFALSE, pdFALSE,
                                                   pdMS_TO_TICKS(wait_ms));
            if ((bits & BADGE_RELOAD_BIT) != 0) {
                break;
            }
        }

        bool rendered_new_frame = false;
        badge_stream_frame_t stream_frame = {0};
        ret = badge_stream_read_frame(stream, &stream_frame, 0);
        if (ret == ESP_OK) {
            s_perf_read_us += stream_frame.read_us;
            if (stream_frame.status == ESP_OK && stream_frame.frame_index < asset->header.frame_count) {
                const badge_ebaj_frame_t *frame = &frames[stream_frame.frame_index];
                int render_fb = choose_render_fb();
                ret = render_stream_frame(&indexed, frame, &stream_frame, render_fb);
                if (ret == ESP_OK) {
                    switch_panel_to_fb(render_fb, &s_perf_display_us, &s_perf_vsync_us);
                    last_render_fb = render_fb;
                    rendered_new_frame = true;
                    ++s_perf_source_frames;
                    if (frame->codec == BADGE_FRAME_INDEXED_REPEAT) {
                        ++s_perf_repeat;
                    }
                } else {
                    ESP_LOGE(TAG, "frame %u decode/render failed: %s",
                             stream_frame.frame_index, esp_err_to_name(ret));
                }
            } else {
                ESP_LOGE(TAG, "frame %u read failed: %s",
                         stream_frame.frame_index, esp_err_to_name(stream_frame.status));
                ret = stream_frame.status;
            }
            badge_stream_release_frame(stream, &stream_frame);
            if (ret != ESP_OK) {
                break;
            }
        }

        if (!rendered_new_frame) {
            ++s_perf_underrun;
            if (last_render_fb >= 0) {
                switch_panel_to_fb(last_render_fb, &s_perf_display_us, &s_perf_vsync_us);
            }
        }

        update_playback_perf_counter(asset);
        next_tick_us += BADGE_TARGET_FRAME_US;
        now = esp_timer_get_time();
        if (now - next_tick_us > BADGE_TARGET_FRAME_US * 4) {
            next_tick_us = now;
        }
    }

    badge_stream_stop(stream);
    badge_indexed_deinit(&indexed);
    heap_caps_free(frames);
    return ret == ESP_ERR_TIMEOUT ? ESP_OK : ret;
}

static void player_task(void *arg)
{
    (void)arg;

    show_waiting_screen();

    while (1) {
        while ((xEventGroupGetBits(s_events) & BADGE_PAUSE_BIT) != 0) {
            xEventGroupSetBits(s_events, BADGE_STOPPED_BIT);
            vTaskDelay(pdMS_TO_TICKS(20));
        }

        xEventGroupClearBits(s_events, BADGE_RELOAD_BIT | BADGE_STOPPED_BIT);

        badge_asset_t asset = {0};
        esp_err_t ret = badge_storage_open_active_asset(&asset);
        if (ret == ESP_OK) {
            ret = player_loop_asset(&asset);
            badge_storage_close_asset(&asset);
            xEventGroupSetBits(s_events, BADGE_STOPPED_BIT);
            if (ret != ESP_OK && (xEventGroupGetBits(s_events) & BADGE_RELOAD_BIT) == 0) {
                xEventGroupWaitBits(s_events, BADGE_RELOAD_BIT, pdTRUE, pdFALSE, pdMS_TO_TICKS(1000));
            }
        } else {
            render_status_if_needed(ret);
            xEventGroupWaitBits(s_events, BADGE_RELOAD_BIT, pdTRUE, pdFALSE, pdMS_TO_TICKS(500));
        }
    }
}

esp_err_t badge_display_init(void)
{
    if (s_events == NULL) {
        s_events = xEventGroupCreate();
        if (s_events == NULL) {
            return ESP_ERR_NO_MEM;
        }
    }

    ESP_RETURN_ON_ERROR(esp_lcd_rgb_panel_get_frame_buffer(panel_handle, BADGE_FB_COUNT, &s_fb[0], &s_fb[1], &s_fb[2]),
                        TAG, "failed to get RGB frame buffers");

    if (xTaskCreatePinnedToCore(player_task, "badge_player", BADGE_PLAYER_STACK, NULL,
                                BADGE_PLAYER_PRIORITY, &s_player_task, 1) != pdPASS) {
        return ESP_ERR_NO_MEM;
    }

    return ESP_OK;
}

void badge_display_request_reload(void)
{
    if (s_events != NULL) {
        xEventGroupSetBits(s_events, BADGE_RELOAD_BIT);
    }
}

esp_err_t badge_display_enter_upload_mode(TickType_t timeout_ticks)
{
    if (s_events == NULL) {
        return ESP_ERR_INVALID_STATE;
    }

    xEventGroupSetBits(s_events, BADGE_PAUSE_BIT | BADGE_RELOAD_BIT);
    EventBits_t bits = xEventGroupWaitBits(s_events, BADGE_STOPPED_BIT, pdFALSE, pdTRUE, timeout_ticks);
    if ((bits & BADGE_STOPPED_BIT) == 0) {
        return ESP_ERR_TIMEOUT;
    }

    show_upload_screen();
    return ESP_OK;
}

void badge_display_exit_upload_mode(void)
{
    if (s_events != NULL) {
        xEventGroupClearBits(s_events, BADGE_PAUSE_BIT | BADGE_STOPPED_BIT);
        xEventGroupSetBits(s_events, BADGE_RELOAD_BIT);
    }
}

esp_err_t badge_display_pause_for_upload(TickType_t timeout_ticks)
{
    return badge_display_enter_upload_mode(timeout_ticks);
}

void badge_display_resume_after_upload(void)
{
    badge_display_exit_upload_mode();
}
