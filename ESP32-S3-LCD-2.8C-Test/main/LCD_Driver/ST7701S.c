#include "ST7701S.h"
#include "esp_check.h"

#define SPI_WriteComm(cmd) ST7701S_WriteCommand(St7701S_handle, cmd)
#define SPI_WriteData(data) ST7701S_WriteData(St7701S_handle, data)
#define Delay(ms) vTaskDelay(ms / portTICK_PERIOD_MS)

static const char *LCD_TAG = "LCD";

#define LCD_POWER_SETTLE_DELAY_MS 400u
#define LCD_RESET_LOW_DELAY_MS 250u
#define LCD_RESET_RELEASE_DELAY_MS 300u

/**
 * @brief Example Create an ST7701S object
 * @param SDA SDA pin
 * @param SCL SCL pin
 * @param CS  CS  pin
 * @param channel_select SPI channel selection
 * @note
*/
ST7701S_handle ST7701S_newObject(int SDA, int SCL, int CS, char channel_select)
{
    // if you use `malloc()`, please set 0 in the area to be assigned.
    ST7701S_handle st7701s_handle = heap_caps_calloc(1, sizeof(ST7701S), MALLOC_CAP_DEFAULT);
    
    st7701s_handle->spi_io_config_t.miso_io_num = -1;
    st7701s_handle->spi_io_config_t.mosi_io_num = SDA;
    st7701s_handle->spi_io_config_t.sclk_io_num = SCL;
    st7701s_handle->spi_io_config_t.quadwp_io_num = -1;
    st7701s_handle->spi_io_config_t.quadhd_io_num = -1;

    st7701s_handle->spi_io_config_t.max_transfer_sz = SOC_SPI_MAXIMUM_BUFFER_SIZE;

    ESP_ERROR_CHECK(spi_bus_initialize(channel_select, &(st7701s_handle->spi_io_config_t), SPI_DMA_CH_AUTO));

    st7701s_handle->st7701s_protocol_config_t.command_bits = 1;
    st7701s_handle->st7701s_protocol_config_t.address_bits = 8;
    st7701s_handle->st7701s_protocol_config_t.clock_speed_hz = 4000000;
    st7701s_handle->st7701s_protocol_config_t.mode = 0;
#if LCD_CS_ALWAYS_LOW_AFTER_BOOT
    st7701s_handle->st7701s_protocol_config_t.spics_io_num = -1;
#else
    st7701s_handle->st7701s_protocol_config_t.spics_io_num = CS;
#endif
    st7701s_handle->st7701s_protocol_config_t.queue_size = 1;

    ESP_ERROR_CHECK(spi_bus_add_device(channel_select, &(st7701s_handle->st7701s_protocol_config_t),
                                    &(st7701s_handle->spi_device)));
        
    return st7701s_handle;
}

/**
 * @brief Screen initialization
 * @param St7701S_handle 
 * @param type 
 * @note
*/
void ST7701S_screen_init(ST7701S_handle St7701S_handle, unsigned char type)
{
    if (type == 1){
    // 2.5 inch round panel vendor initialization sequence.
    SPI_WriteComm(0xFF);
    SPI_WriteData(0x77);
    SPI_WriteData(0x01);
    SPI_WriteData(0x00);
    SPI_WriteData(0x00);
    SPI_WriteData(0x13);

    SPI_WriteComm(0xEF);
    SPI_WriteData(0x08);

    SPI_WriteComm(0xFF);
    SPI_WriteData(0x77);
    SPI_WriteData(0x01);
    SPI_WriteData(0x00);
    SPI_WriteData(0x00);
    SPI_WriteData(0x10);

    SPI_WriteComm(0xC0);
    SPI_WriteData(0x3B);
    SPI_WriteData(0x00);

    SPI_WriteComm(0xC1);
    SPI_WriteData(0x1D);
    SPI_WriteData(0x0A);

    SPI_WriteComm(0xC2);
    SPI_WriteData(0x07);
    SPI_WriteData(0x0A);

    SPI_WriteComm(0xB0);
    SPI_WriteData(0x48);
    SPI_WriteData(0x13);
    SPI_WriteData(0x16);
    SPI_WriteData(0x11);
    SPI_WriteData(0x12);
    SPI_WriteData(0x07);
    SPI_WriteData(0x06);
    SPI_WriteData(0x06);
    SPI_WriteData(0x09);
    SPI_WriteData(0x20);
    SPI_WriteData(0x03);
    SPI_WriteData(0x10);
    SPI_WriteData(0x0C);
    SPI_WriteData(0x2B);
    SPI_WriteData(0x2E);
    SPI_WriteData(0xDF);

    SPI_WriteComm(0xB1);
    SPI_WriteData(0x48);
    SPI_WriteData(0x13);
    SPI_WriteData(0x16);
    SPI_WriteData(0x11);
    SPI_WriteData(0x13);
    SPI_WriteData(0x08);
    SPI_WriteData(0x07);
    SPI_WriteData(0x08);
    SPI_WriteData(0x09);
    SPI_WriteData(0x24);
    SPI_WriteData(0x04);
    SPI_WriteData(0x10);
    SPI_WriteData(0x0C);
    SPI_WriteData(0x2F);
    SPI_WriteData(0x39);
    SPI_WriteData(0xDF);

    SPI_WriteComm(0xFF);
    SPI_WriteData(0x77);
    SPI_WriteData(0x01);
    SPI_WriteData(0x00);
    SPI_WriteData(0x00);
    SPI_WriteData(0x11);

    SPI_WriteComm(0xB0);
    SPI_WriteData(0x75);  // VOP=5.0V

    SPI_WriteComm(0xB1);
    SPI_WriteData(0x35);  // VCOM=0.7625V

    SPI_WriteComm(0xB2);
    SPI_WriteData(0x0B);  // VGH=17V

    SPI_WriteComm(0xB3);
    SPI_WriteData(0x80);

    SPI_WriteComm(0xB5);
    SPI_WriteData(0x4E);  // VGL=-12V

    SPI_WriteComm(0xB7);
    SPI_WriteData(0x87);

    SPI_WriteComm(0xB8);
    SPI_WriteData(0x23);  // AVDD=6.8V, AVCL=-5.0V

    SPI_WriteComm(0xC1);
    SPI_WriteData(0x78);

    SPI_WriteComm(0xC2);
    SPI_WriteData(0x78);

    SPI_WriteComm(0xD0);
    SPI_WriteData(0x88);

    SPI_WriteComm(0xE0);
    SPI_WriteData(0x00);
    SPI_WriteData(0x00);
    SPI_WriteData(0x00);
    SPI_WriteData(0x00);
    SPI_WriteData(0x00);
    SPI_WriteData(0x13);

    SPI_WriteComm(0xE1);
    SPI_WriteData(0x11);
    SPI_WriteData(0xA0);
    SPI_WriteData(0x13);
    SPI_WriteData(0xA0);
    SPI_WriteData(0x12);
    SPI_WriteData(0xA0);
    SPI_WriteData(0x14);
    SPI_WriteData(0xA0);
    SPI_WriteData(0x00);
    SPI_WriteData(0x44);
    SPI_WriteData(0x44);

    SPI_WriteComm(0xE2);
    SPI_WriteData(0x00);
    SPI_WriteData(0x00);
    SPI_WriteData(0x40);
    SPI_WriteData(0x40);
    SPI_WriteData(0x0D);
    SPI_WriteData(0x00);
    SPI_WriteData(0x00);
    SPI_WriteData(0x00);
    SPI_WriteData(0x0D);
    SPI_WriteData(0x00);
    SPI_WriteData(0x00);
    SPI_WriteData(0x00);
    SPI_WriteData(0x00);

    SPI_WriteComm(0xE3);
    SPI_WriteData(0x00);
    SPI_WriteData(0x00);
    SPI_WriteData(0x22);
    SPI_WriteData(0x22);

    SPI_WriteComm(0xE4);
    SPI_WriteData(0x44);
    SPI_WriteData(0x44);

    SPI_WriteComm(0xE5);
    SPI_WriteData(0x15);
    SPI_WriteData(0x01);
    SPI_WriteData(0xF0);
    SPI_WriteData(0xF0);
    SPI_WriteData(0x17);
    SPI_WriteData(0x03);
    SPI_WriteData(0xF0);
    SPI_WriteData(0xF0);
    SPI_WriteData(0x19);
    SPI_WriteData(0x05);
    SPI_WriteData(0xF0);
    SPI_WriteData(0xF0);
    SPI_WriteData(0x1B);
    SPI_WriteData(0x07);
    SPI_WriteData(0xF0);
    SPI_WriteData(0xF0);

    SPI_WriteComm(0xE6);
    SPI_WriteData(0x00);
    SPI_WriteData(0x00);
    SPI_WriteData(0x22);
    SPI_WriteData(0x22);

    SPI_WriteComm(0xE7);
    SPI_WriteData(0x44);
    SPI_WriteData(0x44);

    SPI_WriteComm(0xE8);
    SPI_WriteData(0x16);
    SPI_WriteData(0x02);
    SPI_WriteData(0xF0);
    SPI_WriteData(0xF0);
    SPI_WriteData(0x18);
    SPI_WriteData(0x04);
    SPI_WriteData(0xF0);
    SPI_WriteData(0xF0);
    SPI_WriteData(0x1A);
    SPI_WriteData(0x06);
    SPI_WriteData(0xF0);
    SPI_WriteData(0xF0);
    SPI_WriteData(0x1C);
    SPI_WriteData(0x08);
    SPI_WriteData(0xF0);
    SPI_WriteData(0xF0);

    SPI_WriteComm(0xE9);
    SPI_WriteData(0xC6);
    SPI_WriteData(0x01);

    SPI_WriteComm(0xEB);
    SPI_WriteData(0x00);
    SPI_WriteData(0x00);
    SPI_WriteData(0xE4);
    SPI_WriteData(0xE4);
    SPI_WriteData(0x44);
    SPI_WriteData(0xBB);

    SPI_WriteComm(0xED);
    SPI_WriteData(0xB2);
    SPI_WriteData(0xA1);
    SPI_WriteData(0xF3);
    SPI_WriteData(0x0F);
    SPI_WriteData(0x44);
    SPI_WriteData(0x55);
    SPI_WriteData(0x66);
    SPI_WriteData(0x77);
    SPI_WriteData(0x77);
    SPI_WriteData(0x66);
    SPI_WriteData(0x55);
    SPI_WriteData(0x44);
    SPI_WriteData(0xF0);
    SPI_WriteData(0x3F);
    SPI_WriteData(0x1A);
    SPI_WriteData(0x2B);

    SPI_WriteComm(0xFF);
    SPI_WriteData(0x77);
    SPI_WriteData(0x01);
    SPI_WriteData(0x00);
    SPI_WriteData(0x00);
    SPI_WriteData(0x00);

    SPI_WriteComm(0x3A);
    SPI_WriteData(0x66);

    SPI_WriteComm(0x11);
    Delay(120);

    SPI_WriteComm(0x36);
    SPI_WriteData(0x00);

    SPI_WriteComm(0x29);
    }
}

/**
 * @brief Example Delete the ST7701S object
 * @param St7701S_handle 
*/
void ST7701S_delObject(ST7701S_handle St7701S_handle)
{
    assert(St7701S_handle != NULL);
    free(St7701S_handle);
}

/**
 * @brief SPI write instruction
 * @param St7701S_handle 
 * @param cmd instruction
*/
void ST7701S_WriteCommand(ST7701S_handle St7701S_handle, uint8_t cmd)
{
    spi_transaction_t spi_tran = {
        .rxlength = 0,
        .length = 0,
        .cmd = 0,
        .addr = cmd,
    };
    spi_device_transmit(St7701S_handle->spi_device, &spi_tran);
}

/**
 * @brief SPI write data
 * @param St7701S_handle
 * @param data 
*/
void ST7701S_WriteData(ST7701S_handle St7701S_handle, uint8_t data)
{
    spi_transaction_t spi_tran = {
        .rxlength = 0,
        .length = 0,
        .cmd = 1,
        .addr = data,
    };
    spi_device_transmit(St7701S_handle->spi_device, &spi_tran);
}

esp_err_t ST7701S_PrepareBootCs(void)
{
    if (LCD_CS < 0) {
        return ESP_OK;
    }
    gpio_config_t io_conf = {
        .pin_bit_mask = 1ULL << LCD_CS,
        .mode = GPIO_MODE_OUTPUT_OD,
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    ESP_RETURN_ON_ERROR(gpio_set_level(LCD_CS, 1), LCD_TAG, "preload LCD CS high failed");
    ESP_RETURN_ON_ERROR(gpio_config(&io_conf), LCD_TAG, "hold LCD CS high failed");
    return ESP_OK;
}

esp_err_t ST7701S_reset(void)
{
    gpio_config_t io_conf = {
        .pin_bit_mask = 1ULL << LCD_RST,
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    ESP_RETURN_ON_ERROR(gpio_set_level(LCD_RST, 0), LCD_TAG, "set LCD reset low failed");
    ESP_RETURN_ON_ERROR(gpio_config(&io_conf), LCD_TAG, "configure LCD reset GPIO failed");
    vTaskDelay(pdMS_TO_TICKS(LCD_RESET_LOW_DELAY_MS));
    ESP_RETURN_ON_ERROR(gpio_set_level(LCD_RST, 1), LCD_TAG, "set LCD reset high failed");
    vTaskDelay(pdMS_TO_TICKS(LCD_RESET_RELEASE_DELAY_MS));
    return ESP_OK;
}

esp_err_t ST7701S_CS_EN(void)
{
    if (LCD_CS < 0) {
        return ESP_OK;
    }
    gpio_config_t io_conf = {
        .pin_bit_mask = 1ULL << LCD_CS,
        .mode = GPIO_MODE_OUTPUT_OD,
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    ESP_RETURN_ON_ERROR(gpio_set_level(LCD_CS, 0), LCD_TAG, "set LCD CS low failed");
    ESP_RETURN_ON_ERROR(gpio_config(&io_conf), LCD_TAG, "configure LCD CS GPIO failed");
    return ESP_OK;
}
esp_err_t ST7701S_CS_Dis(void)
{
    if (LCD_CS < 0) {
        return ESP_OK;
    }
    ESP_RETURN_ON_ERROR(gpio_set_level(LCD_CS, 1), LCD_TAG, "set LCD CS high failed");
    return ESP_OK;
}

esp_err_t ST7701S_PrepareForRestart(void)
{
    if (LCD_CS < 0) {
        return ESP_OK;
    }
    gpio_config_t io_conf = {
        .pin_bit_mask = 1ULL << LCD_CS,
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    ESP_RETURN_ON_ERROR(gpio_set_level(LCD_CS, 1), LCD_TAG, "preload LCD CS high before restart failed");
    ESP_RETURN_ON_ERROR(gpio_config(&io_conf), LCD_TAG, "release LCD CS GPIO before restart failed");
    return ESP_OK;
}

#if CONFIG_EXAMPLE_AVOID_TEAR_EFFECT_WITH_SEM
SemaphoreHandle_t sem_vsync_end;
SemaphoreHandle_t sem_gui_ready;
#endif
static SemaphoreHandle_t s_lcd_vsync_sem;


////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

static bool example_on_vsync_event(esp_lcd_panel_handle_t panel, const esp_lcd_rgb_panel_event_data_t *event_data, void *user_data)
{
    BaseType_t high_task_awoken = pdFALSE;
    if (s_lcd_vsync_sem != NULL) {
        xSemaphoreGiveFromISR(s_lcd_vsync_sem, &high_task_awoken);
    }
#if CONFIG_EXAMPLE_AVOID_TEAR_EFFECT_WITH_SEM
    if (xSemaphoreTakeFromISR(sem_gui_ready, &high_task_awoken) == pdTRUE) {
        xSemaphoreGiveFromISR(sem_vsync_end, &high_task_awoken);
    }
#endif
    return high_task_awoken == pdTRUE;
}

esp_lcd_panel_handle_t panel_handle = NULL;
void LCD_PrepareForVsync(void)
{
    if (s_lcd_vsync_sem == NULL) {
        return;
    }

    while (xSemaphoreTake(s_lcd_vsync_sem, 0) == pdTRUE) {
    }
}

esp_err_t LCD_WaitForPreparedVsync(TickType_t timeout_ticks)
{
    if (s_lcd_vsync_sem == NULL) {
        return ESP_ERR_INVALID_STATE;
    }
    return xSemaphoreTake(s_lcd_vsync_sem, timeout_ticks) == pdTRUE ? ESP_OK : ESP_ERR_TIMEOUT;
}

esp_err_t LCD_WaitForVsync(TickType_t timeout_ticks)
{
    LCD_PrepareForVsync();
    return LCD_WaitForPreparedVsync(timeout_ticks);
}

void LCD_Init(void)
{
    /********************* LCD *********************/
    ESP_ERROR_CHECK(ST7701S_PrepareBootCs());
    vTaskDelay(pdMS_TO_TICKS(LCD_POWER_SETTLE_DELAY_MS));
    ST7701S_reset();
    ST7701S_handle st7701s = ST7701S_newObject(LCD_MOSI, LCD_SCLK, LCD_CS, SPI2_HOST);
    ST7701S_CS_EN();
    vTaskDelay(pdMS_TO_TICKS(20));
    
    ST7701S_screen_init(st7701s, 1);
    vTaskDelay(pdMS_TO_TICKS(200));
    #if CONFIG_EXAMPLE_AVOID_TEAR_EFFECT_WITH_SEM
        ESP_LOGI(LCD_TAG, "Create semaphores");
        sem_vsync_end = xSemaphoreCreateBinary();
        assert(sem_vsync_end);
        sem_gui_ready = xSemaphoreCreateBinary();
        assert(sem_gui_ready);
    #endif
    if (s_lcd_vsync_sem == NULL) {
        s_lcd_vsync_sem = xSemaphoreCreateBinary();
        assert(s_lcd_vsync_sem);
    }

    /********************* RGB LCD panel driver *********************/
    ESP_LOGI(LCD_TAG, "Install RGB LCD panel driver");
    esp_lcd_rgb_panel_config_t panel_config = {
        .data_width = 16, // RGB565 in parallel mode, thus 16bit in width
        .psram_trans_align = 64,
        .num_fbs = EXAMPLE_LCD_NUM_FB,
        .bounce_buffer_size_px = EXAMPLE_LCD_NUM_FB > 1 ? 0 : EXAMPLE_LCD_BOUNCE_BUFFER_LINES * EXAMPLE_LCD_H_RES,
        .clk_src = LCD_CLK_SRC_DEFAULT,
        .disp_gpio_num = EXAMPLE_PIN_NUM_DISP_EN,
        .pclk_gpio_num = EXAMPLE_PIN_NUM_PCLK,
        .vsync_gpio_num = EXAMPLE_PIN_NUM_VSYNC,
        .hsync_gpio_num = EXAMPLE_PIN_NUM_HSYNC,
        .de_gpio_num = EXAMPLE_PIN_NUM_DE,
        .data_gpio_nums = {
            EXAMPLE_PIN_NUM_DATA0,
            EXAMPLE_PIN_NUM_DATA1,
            EXAMPLE_PIN_NUM_DATA2,
            EXAMPLE_PIN_NUM_DATA3,
            EXAMPLE_PIN_NUM_DATA4,
            EXAMPLE_PIN_NUM_DATA5,
            EXAMPLE_PIN_NUM_DATA6,
            EXAMPLE_PIN_NUM_DATA7,
            EXAMPLE_PIN_NUM_DATA8,
            EXAMPLE_PIN_NUM_DATA9,
            EXAMPLE_PIN_NUM_DATA10,
            EXAMPLE_PIN_NUM_DATA11,
            EXAMPLE_PIN_NUM_DATA12,
            EXAMPLE_PIN_NUM_DATA13,
            EXAMPLE_PIN_NUM_DATA14,
            EXAMPLE_PIN_NUM_DATA15,
        },
        .timings = {
            .pclk_hz = EXAMPLE_LCD_PIXEL_CLOCK_HZ,
            .h_res = EXAMPLE_LCD_H_RES,
            .v_res = EXAMPLE_LCD_V_RES, 
            .hsync_back_porch = 30,
            .hsync_front_porch = 30,
            .hsync_pulse_width = 30,
            .vsync_back_porch = 31,
            .vsync_front_porch = 22,
            .vsync_pulse_width = 6,
            .flags.pclk_active_neg = false,
        },
        .flags.fb_in_psram = true, // allocate frame buffer in PSRAM
    };
    ESP_LOGI(LCD_TAG, "Step 1: calling esp_lcd_new_rgb_panel...");
    ESP_ERROR_CHECK(esp_lcd_new_rgb_panel(&panel_config, &panel_handle));
    ESP_LOGI(LCD_TAG, "Step 1: OK");

    ESP_LOGI(LCD_TAG, "Register event callbacks");
    esp_lcd_rgb_panel_event_callbacks_t cbs = {
        .on_vsync = example_on_vsync_event,
    };
    ESP_LOGI(LCD_TAG, "Step 2: registering callbacks...");
    ESP_ERROR_CHECK(esp_lcd_rgb_panel_register_event_callbacks(panel_handle, &cbs, NULL));
    ESP_LOGI(LCD_TAG, "Step 2: OK");

    ESP_LOGI(LCD_TAG, "Initialize RGB LCD panel");
    ESP_LOGI(LCD_TAG, "Step 3: calling esp_lcd_panel_reset...");
    ESP_ERROR_CHECK(esp_lcd_panel_reset(panel_handle));
    ESP_LOGI(LCD_TAG, "Step 3: OK");
    ESP_LOGI(LCD_TAG, "Step 4: calling esp_lcd_panel_init...");
    ESP_ERROR_CHECK(esp_lcd_panel_init(panel_handle));
    ESP_LOGI(LCD_TAG, "Step 4: OK");
    vTaskDelay(pdMS_TO_TICKS(50));
    if (!LCD_CS_ALWAYS_LOW_AFTER_BOOT) {
        ST7701S_CS_Dis();
    }
    Backlight_Init();
}

/********************* BackLight *********************/
static void example_ledc_init(void)
{
    // Prepare and then apply the LEDC PWM timer configuration
    ledc_timer_config_t ledc_timer = {
        .speed_mode       = LEDC_MODE,
        .timer_num        = LEDC_TIMER,
        .duty_resolution  = LEDC_DUTY_RES,
        .freq_hz          = LEDC_FREQUENCY,  // Set output frequency at 8 kHz
        .clk_cfg          = LEDC_AUTO_CLK
    };
    ESP_ERROR_CHECK(ledc_timer_config(&ledc_timer));

    // Prepare and then apply the LEDC PWM channel configuration
    ledc_channel_config_t ledc_channel = {
        .speed_mode     = LEDC_MODE,
        .channel        = LEDC_CHANNEL,
        .timer_sel      = LEDC_TIMER,
        .intr_type      = LEDC_INTR_DISABLE,
        .gpio_num       = LEDC_OUTPUT_IO,
        .duty           = 0, // Set duty to 0%
        .hpoint         = 0
    };
    ESP_ERROR_CHECK(ledc_channel_config(&ledc_channel));
}
uint8_t LCD_Backlight = 70;
void Backlight_Init(void)
{
    example_ledc_init();
    Set_Backlight(LCD_Backlight);
}

void Set_Backlight(uint8_t Light)
{
    if(Light > Backlight_MAX) Light = Backlight_MAX;
    ESP_ERROR_CHECK(ledc_set_duty(LEDC_MODE, LEDC_CHANNEL, Light*(8192/100)));    // Set duty
    ESP_ERROR_CHECK(ledc_update_duty(LEDC_MODE, LEDC_CHANNEL));                 // Update duty to apply the new value
}
