#include "BadgeStream.h"

#include <string.h>

#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

#define BADGE_STREAM_SLOT_COUNT 24u
#define BADGE_STREAM_TASK_STACK 4096u
#define BADGE_STREAM_TASK_PRIORITY 8u
#define BADGE_STREAM_QUEUE_POLL_MS 5u
#define BADGE_STREAM_WHOLE_ASSET_CACHE_MAX_BYTES (4u * 1024u * 1024u)
/* Small loop assets can be started directly from the 4-bit SD stream.  The
 * whole-asset PSRAM copy is useful for long/heavy clips, but for a short user
 * clip its fixed SD read dominates the transition latency. */
#define BADGE_STREAM_FAST_LOOP_CACHE_MAX_BYTES (2u * 1024u * 1024u)
/* A small package can still contain a few large JPEG frames. Those frames
 * can consume the whole SD prefetch window and starve the renderer, so only
 * use direct SD streaming when the largest frame is bounded as well. */
#define BADGE_STREAM_FAST_LOOP_MAX_FRAME_BYTES (64u * 1024u)

static const char *TAG = "BadgeStream";

typedef struct {
    uint16_t frame_index;
    uint8_t *data;
    size_t capacity;
    size_t size;
    esp_err_t status;
    int64_t read_us;
} badge_stream_slot_t;

struct badge_stream {
    badge_asset_t *asset;
    const badge_ebaj_frame_t *frames;
    uint16_t frame_count;
    uint16_t next_frame;
    bool loop;
    bool stopping;
    TaskHandle_t task;
    SemaphoreHandle_t done;
    QueueHandle_t free_slots;
    QueueHandle_t ready_slots;
    badge_stream_slot_t slots[BADGE_STREAM_SLOT_COUNT];
    uint8_t *cache_data;
    uint32_t cache_base;
    size_t cache_size;
    bool cache_active;
};

static esp_err_t try_load_whole_asset_cache(badge_stream_t *stream)
{
    const uint32_t base = stream->asset->header.frame_data_offset;
    const uint32_t package_size = stream->asset->header.package_size;
    if (package_size <= base) {
        return ESP_ERR_INVALID_SIZE;
    }

    const size_t cache_size = (size_t)(package_size - base);
    if (cache_size > BADGE_STREAM_WHOLE_ASSET_CACHE_MAX_BYTES) {
        return ESP_ERR_NOT_SUPPORTED;
    }

    uint8_t *cache = heap_caps_malloc(cache_size, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (cache == NULL) {
        return ESP_ERR_NO_MEM;
    }

    int64_t start_us = esp_timer_get_time();
    esp_err_t ret = badge_storage_read_asset(stream->asset, base, cache, cache_size);
    if (ret != ESP_OK) {
        heap_caps_free(cache);
        return ret;
    }

    stream->cache_data = cache;
    stream->cache_base = base;
    stream->cache_size = cache_size;
    stream->cache_active = true;
    ESP_LOGI(TAG, "whole-asset cache enabled: bytes=%u load=%lldms",
             (unsigned)cache_size,
             (long long)((esp_timer_get_time() - start_us) / 1000));
    return ESP_OK;
}

static size_t max_frame_payload_size(const badge_ebaj_frame_t *frames, uint16_t frame_count)
{
    size_t max_size = 1u;
    for (uint16_t i = 0; i < frame_count; ++i) {
        if (frames[i].data_size > max_size) {
            max_size = frames[i].data_size;
        }
    }
    return max_size;
}

static void stream_task(void *arg)
{
    badge_stream_t *stream = (badge_stream_t *)arg;

    while (!stream->stopping) {
        badge_stream_slot_t *slot = NULL;
        if (xQueueReceive(stream->free_slots, &slot,
                          pdMS_TO_TICKS(BADGE_STREAM_QUEUE_POLL_MS)) != pdTRUE || slot == NULL) {
            continue;
        }

        if (!stream->loop && stream->next_frame >= stream->frame_count) {
            xQueueSend(stream->free_slots, &slot, 0);
            break;
        }

        const uint16_t frame_index = stream->next_frame;
        const badge_ebaj_frame_t *frame = &stream->frames[frame_index];
        slot->frame_index = frame_index;
        slot->size = frame->data_size;
        slot->status = ESP_OK;
        slot->read_us = 0;

        if (stream->cache_active) {
            uint64_t relative = (uint64_t)frame->data_offset - stream->cache_base;
            uint64_t end = relative + frame->data_size;
            if (frame->data_offset < stream->cache_base || relative > stream->cache_size ||
                end > stream->cache_size) {
                slot->status = ESP_ERR_INVALID_SIZE;
                slot->data = NULL;
            } else {
                slot->data = stream->cache_data + (size_t)relative;
                slot->capacity = frame->data_size;
            }
        } else if (frame->data_size > slot->capacity) {
            slot->status = ESP_ERR_INVALID_SIZE;
        } else if (frame->data_size > 0) {
            int64_t start_us = esp_timer_get_time();
            esp_err_t ret = ESP_OK;
            if (stream->asset->sd_file_pos == frame->data_offset) {
                ret = badge_storage_read_asset_sequential(stream->asset, slot->data, frame->data_size);
            } else {
                ret = badge_storage_read_asset(stream->asset, frame->data_offset, slot->data, frame->data_size);
            }
            slot->read_us = esp_timer_get_time() - start_us;
            slot->status = ret;
        }

        if (stream->loop) {
            stream->next_frame = (uint16_t)((stream->next_frame + 1u) % stream->frame_count);
        } else {
            stream->next_frame = (uint16_t)(stream->next_frame + 1u);
        }

        /* Do not drop the tail of a non-looping exit animation just because
           the ready queue is temporarily full. The player must receive every
           frame before the producer exits. */
        while (!stream->stopping &&
               xQueueSend(stream->ready_slots, &slot,
                          pdMS_TO_TICKS(BADGE_STREAM_QUEUE_POLL_MS)) != pdTRUE) {
        }
        if (stream->stopping) {
            xQueueSend(stream->free_slots, &slot, 0);
            break;
        }
    }

    if (stream->done != NULL) {
        xSemaphoreGive(stream->done);
    }
    vTaskDelete(NULL);
}

esp_err_t badge_stream_start(badge_asset_t *asset,
                             const badge_ebaj_frame_t *frames,
                             uint16_t frame_count,
                             uint16_t start_index,
                             bool loop,
                             badge_stream_t **out_stream)
{
    if (asset == NULL || frames == NULL || frame_count == 0 || out_stream == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    badge_stream_t *stream = heap_caps_calloc(1, sizeof(*stream), MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
    if (stream == NULL) {
        return ESP_ERR_NO_MEM;
    }

    stream->asset = asset;
    stream->frames = frames;
    stream->frame_count = frame_count;
    stream->next_frame = start_index < frame_count ? start_index : 0;
    stream->loop = loop;
    stream->done = xSemaphoreCreateBinary();
    stream->free_slots = xQueueCreate(BADGE_STREAM_SLOT_COUNT, sizeof(badge_stream_slot_t *));
    stream->ready_slots = xQueueCreate(BADGE_STREAM_SLOT_COUNT, sizeof(badge_stream_slot_t *));
    if (stream->done == NULL || stream->free_slots == NULL || stream->ready_slots == NULL) {
        badge_stream_stop(stream);
        return ESP_ERR_NO_MEM;
    }

    size_t max_payload = max_frame_payload_size(frames, frame_count);
    bool fast_loop_start = loop &&
                           asset->header.package_size <= BADGE_STREAM_FAST_LOOP_CACHE_MAX_BYTES &&
                           max_payload <= BADGE_STREAM_FAST_LOOP_MAX_FRAME_BYTES;
    /* Any non-looping asset is a transition/entrance path.  Never block its
       first frame on a whole-package PSRAM copy; the SD producer fills the
       queue asynchronously while the player starts rendering. */
    bool fast_transition_start = !loop;
    bool fast_sd_start = fast_loop_start || fast_transition_start;
    ESP_LOGI(TAG, "stream policy: loop=%d package=%u max_frame=%u fast_sd=%d",
             loop ? 1 : 0,
             (unsigned)asset->header.package_size,
             (unsigned)max_payload,
             fast_sd_start ? 1 : 0);
    esp_err_t cache_ret = fast_sd_start ? ESP_ERR_NOT_SUPPORTED
                                        : try_load_whole_asset_cache(stream);
    if (cache_ret != ESP_OK && cache_ret != ESP_ERR_NOT_SUPPORTED && cache_ret != ESP_ERR_NO_MEM) {
        ESP_LOGW(TAG, "whole-asset cache load failed: %s; using SD stream", esp_err_to_name(cache_ret));
    } else if (cache_ret == ESP_ERR_NO_MEM) {
        ESP_LOGW(TAG, "whole-asset cache unavailable: no PSRAM; using SD stream");
    } else if (cache_ret == ESP_ERR_NOT_SUPPORTED) {
        if (fast_loop_start) {
            ESP_LOGI(TAG, "fast loop start: using SD prefetch for small asset (%u bytes)",
                     (unsigned)asset->header.package_size);
        } else if (fast_transition_start) {
            ESP_LOGI(TAG, "fast transition start: using SD prefetch for short asset (%u bytes)",
                     (unsigned)asset->header.package_size);
        } else {
            ESP_LOGD(TAG, "asset exceeds whole-asset cache limit; using SD stream");
        }
    }

    for (uint32_t i = 0; i < BADGE_STREAM_SLOT_COUNT; ++i) {
        if (!stream->cache_active) {
            stream->slots[i].data = heap_caps_malloc(max_payload, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
            if (stream->slots[i].data == NULL) {
                badge_stream_stop(stream);
                return ESP_ERR_NO_MEM;
            }
            stream->slots[i].capacity = max_payload;
        }
        badge_stream_slot_t *slot = &stream->slots[i];
        xQueueSend(stream->free_slots, &slot, 0);
    }

    if (xTaskCreatePinnedToCore(stream_task,
                                "badge_stream",
                                BADGE_STREAM_TASK_STACK,
                                stream,
                                BADGE_STREAM_TASK_PRIORITY,
                                &stream->task,
                                0) != pdPASS) {
        badge_stream_stop(stream);
        return ESP_ERR_NO_MEM;
    }

    *out_stream = stream;
    return ESP_OK;
}

esp_err_t badge_stream_read_frame(badge_stream_t *stream,
                                  badge_stream_frame_t *out_frame,
                                  uint32_t timeout_ms)
{
    if (stream == NULL || out_frame == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    badge_stream_slot_t *slot = NULL;
    if (xQueueReceive(stream->ready_slots, &slot, pdMS_TO_TICKS(timeout_ms)) != pdTRUE || slot == NULL) {
        return ESP_ERR_TIMEOUT;
    }

    out_frame->frame_index = slot->frame_index;
    out_frame->data = slot->data;
    out_frame->size = slot->size;
    out_frame->status = slot->status;
    out_frame->read_us = slot->read_us;
    out_frame->cookie = slot;
    return ESP_OK;
}

esp_err_t badge_stream_wait_prefill(badge_stream_t *stream,
                                    uint32_t min_ready_frames,
                                    uint32_t timeout_ms)
{
    if (stream == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    if (min_ready_frames == 0) {
        return ESP_OK;
    }
    if (min_ready_frames > BADGE_STREAM_SLOT_COUNT) {
        min_ready_frames = BADGE_STREAM_SLOT_COUNT;
    }

    int64_t deadline_us = esp_timer_get_time() + (int64_t)timeout_ms * 1000;
    while (!stream->stopping) {
        UBaseType_t ready = uxQueueMessagesWaiting(stream->ready_slots);
        if ((uint32_t)ready >= min_ready_frames) {
            return ESP_OK;
        }
        if (timeout_ms == 0 || esp_timer_get_time() >= deadline_us) {
            return ESP_ERR_TIMEOUT;
        }
        vTaskDelay(pdMS_TO_TICKS(5));
    }

    return ESP_ERR_INVALID_STATE;
}

void badge_stream_release_frame(badge_stream_t *stream, badge_stream_frame_t *frame)
{
    if (stream == NULL || frame == NULL) {
        return;
    }

    if (frame->cookie != NULL) {
        badge_stream_slot_t *slot = (badge_stream_slot_t *)frame->cookie;
        if (slot >= stream->slots && slot < stream->slots + BADGE_STREAM_SLOT_COUNT) {
            xQueueSend(stream->free_slots, &slot, 0);
            memset(frame, 0, sizeof(*frame));
            return;
        }
    }

    if (frame->data == NULL) {
        return;
    }
    for (uint32_t i = 0; i < BADGE_STREAM_SLOT_COUNT; ++i) {
        if (stream->slots[i].data == frame->data) {
            badge_stream_slot_t *slot = &stream->slots[i];
            xQueueSend(stream->free_slots, &slot, 0);
            memset(frame, 0, sizeof(*frame));
            return;
        }
    }
}

void badge_stream_stop(badge_stream_t *stream)
{
    if (stream == NULL) {
        return;
    }

    stream->stopping = true;
    if (stream->task != NULL) {
        if (stream->done != NULL) {
            xSemaphoreTake(stream->done, portMAX_DELAY);
        }
    }
    if (stream->done != NULL) {
        vSemaphoreDelete(stream->done);
    }
    if (stream->free_slots != NULL) {
        vQueueDelete(stream->free_slots);
    }
    if (stream->ready_slots != NULL) {
        vQueueDelete(stream->ready_slots);
    }
    for (uint32_t i = 0; i < BADGE_STREAM_SLOT_COUNT; ++i) {
        if (!stream->cache_active && stream->slots[i].data != NULL) {
            heap_caps_free(stream->slots[i].data);
        }
    }
    if (stream->cache_data != NULL) {
        heap_caps_free(stream->cache_data);
    }
    heap_caps_free(stream);
}
