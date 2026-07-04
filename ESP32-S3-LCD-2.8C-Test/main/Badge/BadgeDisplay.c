#include "BadgeDisplay.h"

#include <inttypes.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include "BadgeAnimMgr.h"
#include "BadgeIndexed.h"
#include "BadgeLz4.h"
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
#define BADGE_PLAYER_STACK 10240u
#define BADGE_PLAYER_PRIORITY 6u
#define BADGE_STATUS_PERIOD_MS 250u
#define BADGE_FB_COUNT 3u
#define BADGE_STREAM_PREFILL_FRAMES 8u
#define BADGE_FPS_OVERLAY_ENABLED 0u
#define BADGE_STATIC_LCD_TEST 0u
#define BADGE_FRAME_FLAG_LZ4 0x80u

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
static badge_play_mode_t s_play_mode = BADGE_PLAY_MODE_LOOP;
static char s_asset_path[64];

static void switch_panel_to_fb(int fb_index, int64_t *out_display_us, int64_t *out_vsync_us);

#if BADGE_STATIC_LCD_TEST
static uint16_t rgb565(uint8_t red, uint8_t green, uint8_t blue)
{
    return ((uint16_t)(red & 0xF8) << 8) |
           ((uint16_t)(green & 0xFC) << 3) |
           ((uint16_t)blue >> 3);
}

static esp_err_t draw_static_lcd_test_pattern(void)
{
    static const uint16_t colors[] = {
        0xFFFF,
        0xF800,
        0x07E0,
        0x001F,
        0xFFE0,
        0xF81F,
        0x07FF,
        0x0000,
    };

    for (size_t fb_index = 0; fb_index < BADGE_FB_COUNT; ++fb_index) {
        uint16_t *pixels = (uint16_t *)s_fb[fb_index];
        for (uint16_t y = 0; y < BADGE_EBAJ_HEIGHT; ++y) {
            for (uint16_t x = 0; x < BADGE_EBAJ_WIDTH; ++x) {
                uint16_t color = colors[(x / 60u) % (sizeof(colors) / sizeof(colors[0]))];
                if (((x / 30u) + (y / 30u)) & 1u) {
                    uint8_t gray = (uint8_t)((uint32_t)(x + y) * 255u / (BADGE_EBAJ_WIDTH + BADGE_EBAJ_HEIGHT - 2u));
                    color = rgb565(gray, gray, gray);
                }
                if (x == y || x + y == BADGE_EBAJ_WIDTH - 1u || x == BADGE_EBAJ_WIDTH / 2u || y == BADGE_EBAJ_HEIGHT / 2u) {
                    color = 0xFFFF;
                }
                pixels[(size_t)y * BADGE_EBAJ_WIDTH + x] = color;
            }
        }
    }

    ESP_LOGW(TAG, "static LCD test mode active; badge playback disabled");
    return esp_lcd_panel_draw_bitmap(panel_handle, 0, 0, BADGE_EBAJ_WIDTH, BADGE_EBAJ_HEIGHT, s_fb[0]);
}
#endif

static esp_err_t timed_asset_read(badge_asset_t *asset, uint32_t offset, void *buffer, size_t len)
{
    return badge_storage_read_asset(asset, offset, buffer, len);
}

static esp_err_t load_frame_table(badge_asset_t *asset, badge_ebaj_frame_t **out_frames)
{
    uint16_t expected_delay_ms = badge_protocol_frame_delay_ms(asset->header.fps);
    if (expected_delay_ms == 0) {
        return ESP_ERR_INVALID_RESPONSE;
    }

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
            frame->delay_ms != expected_delay_ms ||
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
    int64_t done_us = esp_timer_get_time();
    if (draw_ret != ESP_OK) {
        ESP_LOGW(TAG, "draw_bitmap failed: %s", esp_err_to_name(draw_ret));
    }
    if (out_display_us != NULL) {
        *out_display_us += done_us - display_start_us;
    }
    if (out_vsync_us != NULL) {
        (void)out_vsync_us;
    }
    s_display_fb = fb_index;
}

static esp_err_t render_stream_frame(badge_indexed_t *indexed,
                                     const badge_ebaj_frame_t *frame,
                                     const badge_stream_frame_t *stream_frame,
                                     int *render_fb,
                                     int last_render_fb)
{
    const uint8_t *payload = stream_frame->data;
    size_t payload_size = stream_frame->size;

    /* LZ4 decompression wrapper ¨C reduces SD read bandwidth. */
    static uint8_t *s_lz4_buf = NULL;
    static size_t s_lz4_cap = 0;
    if ((frame->flags & BADGE_FRAME_FLAG_LZ4) && payload_size >= 4) {
        uint32_t uncomp_len = (uint32_t)payload[0]
                            | ((uint32_t)payload[1] << 8)
                            | ((uint32_t)payload[2] << 16)
                            | ((uint32_t)payload[3] << 24);
        if (uncomp_len > s_lz4_cap) {
            if (s_lz4_buf != NULL) {
                heap_caps_free(s_lz4_buf);
            }
            s_lz4_cap = uncomp_len + 256;
            s_lz4_buf = heap_caps_malloc(s_lz4_cap, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
            if (s_lz4_buf == NULL) {
                s_lz4_cap = 0;
                return ESP_ERR_NO_MEM;
            }
        }
        esp_err_t lz4_ret = badge_lz4_decompress(
            payload + 4, payload_size - 4, s_lz4_buf, uncomp_len);
        if (lz4_ret != ESP_OK) {
            return lz4_ret;
        }
        payload = s_lz4_buf;
        payload_size = uncomp_len;
    }

    int64_t decode_start_us = esp_timer_get_time();
    esp_err_t ret = badge_indexed_decode(indexed, frame, payload, payload_size);
    s_perf_decode_us += esp_timer_get_time() - decode_start_us;
    if (ret != ESP_OK) {
        return ret;
    }

    int64_t render_start_us = esp_timer_get_time();
    if (frame->codec == BADGE_FRAME_INDEXED_TILE && badge_indexed_dirty_rgb565_is_partial(indexed)) {
        /* Copy the last displayed frame into the new render buffer as baseline,
         * then apply tile deltas.  This avoids tearing that would occur when
         * writing tile updates directly into the buffer the LCD is scanning from. */
        if (last_render_fb >= 0 && last_render_fb < (int)BADGE_FB_COUNT && s_fb[last_render_fb] != NULL) {
            memcpy(s_fb[*render_fb], s_fb[last_render_fb], BADGE_EBAJ_FRAME_BYTES);
        }
        ret = badge_indexed_blit_dirty_rgb565(indexed, (uint16_t *)s_fb[*render_fb]);
    } else {
        ret = badge_indexed_render_rgb565(indexed, (uint16_t *)s_fb[*render_fb]);
    }
    s_perf_render_us += esp_timer_get_time() - render_start_us;
    return ret;
}

static esp_err_t player_loop_asset(badge_asset_t *asset)
{
    /* Snapshot play mode to prevent race with WiFi task changing s_play_mode */
    badge_play_mode_t entry_mode = s_play_mode;

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

    esp_err_t prefill_ret = badge_stream_wait_prefill(stream, BADGE_STREAM_PREFILL_FRAMES, 1200);
    if (prefill_ret != ESP_OK) {
        ESP_LOGW(TAG, "stream prefill partial: %s", esp_err_to_name(prefill_ret));
    }

    ESP_LOGI(TAG, "playing storage=sd format=ebaj4 frames=%u fps=%u stream=%ux%u",
             asset->header.frame_count,
             asset->header.fps,
             asset->header.stream_width,
             asset->header.stream_height);
    reset_playback_perf_counter();

    int64_t frame_delay_us = (int64_t)badge_protocol_frame_delay_ms(asset->header.fps) * 1000;
    if (frame_delay_us <= 0) {
        badge_stream_stop(stream);
        badge_indexed_deinit(&indexed);
        heap_caps_free(frames);
        return ESP_ERR_INVALID_RESPONSE;
    }

    int64_t next_tick_us = esp_timer_get_time();
    int last_render_fb = s_display_fb;
    uint16_t frames_consumed = 0;

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
            ++frames_consumed;
            s_perf_read_us += stream_frame.read_us;
            if (stream_frame.status == ESP_OK && stream_frame.frame_index < asset->header.frame_count) {
                const badge_ebaj_frame_t *frame = &frames[stream_frame.frame_index];
                if (frame->codec == BADGE_FRAME_INDEXED_REPEAT) {
                    int64_t decode_start_us = esp_timer_get_time();
                    ret = badge_indexed_decode(&indexed, frame, stream_frame.data, stream_frame.size);
                    s_perf_decode_us += esp_timer_get_time() - decode_start_us;
                    if (ret == ESP_OK) {
                        rendered_new_frame = true;
                        ++s_perf_source_frames;
                        ++s_perf_repeat;
                    }
                } else {
                    int render_fb = choose_render_fb();
                    ret = render_stream_frame(&indexed, frame, &stream_frame, &render_fb, last_render_fb);
                    if (ret == ESP_OK) {
                        switch_panel_to_fb(render_fb, &s_perf_display_us, &s_perf_vsync_us);
                        last_render_fb = render_fb;
                        rendered_new_frame = true;
                        ++s_perf_source_frames;
                    }
                }
                if (ret != ESP_OK) {
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
            (void)last_render_fb;
        }

        update_playback_perf_counter(asset);
        next_tick_us += frame_delay_us;

        /* Break after one full play-through for non-loop modes */
        if (entry_mode != BADGE_PLAY_MODE_LOOP && frames_consumed >= asset->header.frame_count) {
            break;
        }

        now = esp_timer_get_time();
        if (now - next_tick_us > frame_delay_us * 4) {
            next_tick_us = now;
        }
    }

    badge_stream_stop(stream);
    badge_indexed_deinit(&indexed);
    heap_caps_free(frames);

    /* First-half-freeze: stop after last frame */
    if (entry_mode == BADGE_PLAY_MODE_FIRST_HALF_FREEZE) {
        ESP_LOGI(TAG, "first_half finished, freezing");
        xEventGroupSetBits(s_events, BADGE_STOPPED_BIT);
        /* Stay frozen until RELOAD (next switch) */
        xEventGroupWaitBits(s_events, BADGE_RELOAD_BIT, pdTRUE, pdFALSE, portMAX_DELAY);
    }

    /* Second-half: notify anim mgr to trigger pending switch */
    if (entry_mode == BADGE_PLAY_MODE_SECOND_HALF) {
        ESP_LOGI(TAG, "second_half finished, notifying anim mgr");
        badge_anim_mgr_notify_finished();
        /* If notify didn't queue a new animation AND no interrupt switch occurred, freeze. */
        if ((xEventGroupGetBits(s_events) & BADGE_RELOAD_BIT) == 0) {
            ESP_LOGI(TAG, "second_half finished, no pending switch, freezing");
            xEventGroupSetBits(s_events, BADGE_STOPPED_BIT);
            xEventGroupWaitBits(s_events, BADGE_RELOAD_BIT, pdTRUE, pdFALSE, portMAX_DELAY);
        }
    }

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

        ESP_LOGI(TAG, "player resuming, opening asset");
        xEventGroupClearBits(s_events, BADGE_RELOAD_BIT | BADGE_STOPPED_BIT);

        badge_asset_t asset = {0};
        esp_err_t ret;
        if (s_asset_path[0] != '\0') {
            ret = badge_storage_open_asset_path(s_asset_path, &asset);
        } else {
            ret = badge_storage_open_active_asset(&asset);
        }
        if (ret == ESP_OK) {
            ret = player_loop_asset(&asset);
            badge_storage_close_asset(&asset);
            xEventGroupSetBits(s_events, BADGE_STOPPED_BIT);
            if (ret != ESP_OK && (xEventGroupGetBits(s_events) & BADGE_RELOAD_BIT) == 0) {
                xEventGroupWaitBits(s_events, BADGE_RELOAD_BIT, pdTRUE, pdFALSE, pdMS_TO_TICKS(1000));
            }
        } else {
            ESP_LOGE(TAG, "open asset failed: %s", esp_err_to_name(ret));
            render_status_if_needed(ret);
            xEventGroupWaitBits(s_events, BADGE_RELOAD_BIT, pdTRUE, pdFALSE, pdMS_TO_TICKS(500));
        }
    }
}

esp_err_t badge_display_play_asset_file(const char *path, badge_play_mode_t mode)
{
    if (path == NULL || s_events == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    s_play_mode = mode;
    strncpy(s_asset_path, path, sizeof(s_asset_path) - 1);
    ESP_LOGI(TAG, "play_asset_file: %s mode=%d", path, mode);

    badge_display_request_reload();
    return ESP_OK;
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

#if BADGE_STATIC_LCD_TEST
    ESP_RETURN_ON_ERROR(draw_static_lcd_test_pattern(), TAG, "static LCD test draw failed");
    return ESP_OK;
#endif

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

static esp_err_t pause_player_task(TickType_t timeout_ticks)
{
    if (s_events == NULL) {
        return ESP_ERR_INVALID_STATE;
    }

    xEventGroupSetBits(s_events, BADGE_PAUSE_BIT | BADGE_RELOAD_BIT);
    EventBits_t bits = xEventGroupWaitBits(s_events, BADGE_STOPPED_BIT, pdFALSE, pdTRUE, timeout_ticks);
    if ((bits & BADGE_STOPPED_BIT) == 0) {
        return ESP_ERR_TIMEOUT;
    }

    return ESP_OK;
}

esp_err_t badge_display_enter_upload_mode(TickType_t timeout_ticks)
{
    esp_err_t ret = pause_player_task(timeout_ticks);
    if (ret != ESP_OK) {
        return ret;
    }

    show_upload_screen();
    return ESP_OK;
}

void badge_display_exit_upload_mode(void)
{
    if (s_events != NULL) {
        xEventGroupClearBits(s_events, BADGE_PAUSE_BIT | BADGE_STOPPED_BIT);
        xEventGroupSetBits(s_events, BADGE_RELOAD_BIT);
        ESP_LOGI(TAG, "exit upload mode, player released");
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

esp_err_t badge_display_pause_for_ota(TickType_t timeout_ticks)
{
    return pause_player_task(timeout_ticks);
}

void badge_display_resume_after_ota(void)
{
    badge_display_exit_upload_mode();
}