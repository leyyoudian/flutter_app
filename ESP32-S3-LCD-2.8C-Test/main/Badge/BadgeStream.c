#include "BadgeStream.h"

#include <string.h>

#include "esp_heap_caps.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

#define BADGE_STREAM_SLOT_COUNT 3u
#define BADGE_STREAM_TASK_STACK 4096u
#define BADGE_STREAM_TASK_PRIORITY 5u

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
    bool stopping;
    TaskHandle_t task;
    SemaphoreHandle_t done;
    QueueHandle_t free_slots;
    QueueHandle_t ready_slots;
    badge_stream_slot_t slots[BADGE_STREAM_SLOT_COUNT];
};

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
        if (xQueueReceive(stream->free_slots, &slot, pdMS_TO_TICKS(50)) != pdTRUE || slot == NULL) {
            continue;
        }

        const uint16_t frame_index = stream->next_frame;
        const badge_ebaj_frame_t *frame = &stream->frames[frame_index];
        slot->frame_index = frame_index;
        slot->size = frame->data_size;
        slot->status = ESP_OK;
        slot->read_us = 0;

        if (frame->data_size > slot->capacity) {
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

        stream->next_frame = (uint16_t)((stream->next_frame + 1u) % stream->frame_count);
        if (xQueueSend(stream->ready_slots, &slot, pdMS_TO_TICKS(50)) != pdTRUE) {
            xQueueSend(stream->free_slots, &slot, 0);
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
    stream->done = xSemaphoreCreateBinary();
    stream->free_slots = xQueueCreate(BADGE_STREAM_SLOT_COUNT, sizeof(badge_stream_slot_t *));
    stream->ready_slots = xQueueCreate(BADGE_STREAM_SLOT_COUNT, sizeof(badge_stream_slot_t *));
    if (stream->done == NULL || stream->free_slots == NULL || stream->ready_slots == NULL) {
        badge_stream_stop(stream);
        return ESP_ERR_NO_MEM;
    }

    size_t max_payload = max_frame_payload_size(frames, frame_count);
    for (uint32_t i = 0; i < BADGE_STREAM_SLOT_COUNT; ++i) {
        stream->slots[i].data = heap_caps_malloc(max_payload, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
        if (stream->slots[i].data == NULL) {
            badge_stream_stop(stream);
            return ESP_ERR_NO_MEM;
        }
        stream->slots[i].capacity = max_payload;
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
    return ESP_OK;
}

void badge_stream_release_frame(badge_stream_t *stream, badge_stream_frame_t *frame)
{
    if (stream == NULL || frame == NULL || frame->data == NULL) {
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
        if (stream->slots[i].data != NULL) {
            heap_caps_free(stream->slots[i].data);
        }
    }
    heap_caps_free(stream);
}
