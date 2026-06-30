#include <inttypes.h>

#include "sdkconfig.h"
#include "esp_flash.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "ST7701S.h"
#include "Wireless.h"
#include "BadgeAnimMgr.h"
#include "BadgeDisplay.h"
#include "BadgeStorage.h"

static const char *TAG = "main";
#define BADGE_FW_BUILD_ID "new-board-sdio-lcdgpio-20260619"

static void Log_Flash_Size(void)
{
    uint32_t flash_size = 0;
    esp_err_t ret = esp_flash_get_size(NULL, &flash_size);
    if (ret == ESP_OK) {
        ESP_LOGI(TAG, "Flash size: %" PRIu32 " MB", flash_size / (1024u * 1024u));
    } else {
        ESP_LOGW(TAG, "Failed to read flash size: %s", esp_err_to_name(ret));
    }
}

void Driver_Init(void)
{
    Log_Flash_Size();
}
void app_main(void)
{   
    ESP_LOGI(TAG, "Badge firmware build: %s", BADGE_FW_BUILD_ID);
    Driver_Init();
    ESP_ERROR_CHECK(badge_storage_init());
    ESP_ERROR_CHECK(Wireless_Init());
    vTaskDelay(pdMS_TO_TICKS(1000));
    LCD_Init();   

    vTaskDelay(pdMS_TO_TICKS(500));
    /* Ensure SD is mounted before display init (player task needs SD) */
    badge_storage_ensure_mounted();
    ESP_ERROR_CHECK(badge_display_init());
    ESP_ERROR_CHECK(badge_anim_mgr_init());
    while (1) {
        vTaskDelay(pdMS_TO_TICKS(100));
    }
}
