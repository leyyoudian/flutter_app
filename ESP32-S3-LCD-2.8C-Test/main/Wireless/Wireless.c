#include "Wireless.h"

#include "WifiUpload.h"

#include "esp_check.h"
#include "esp_err.h"
#include "esp_log.h"

static const char *TAG = "Wireless";

esp_err_t Wireless_Init(void)
{
    ESP_RETURN_ON_ERROR(WifiUpload_Init(), TAG, "wifi upload init failed");
    ESP_LOGI(TAG, "Wi-Fi AP control/upload ready");
    return ESP_OK;
}
