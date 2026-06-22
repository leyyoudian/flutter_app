idf_component_register(
                        SRCS  "main.c" 
                              "Badge/BadgeDisplay.c"
                              "Badge/BadgeIndexed.c"
                              "Badge/BadgeLz4.c"
                              "Badge/BadgeProtocol.c"
                              "Badge/BadgeStream.c"
                              "Badge/BadgeStorage.c"
                              "SD_Card/SD_MMC.c"
                              "Wireless/WifiUpload.c"
                              "LCD_Driver/ST7701S.c" 
                              "Wireless/Wireless.c"

                        INCLUDE_DIRS "./Badge"
                                     "./SD_Card"
                                     "./LCD_Driver"
                                     "./Wireless"
                                     "."
                        REQUIRES esp_lcd esp_timer esp_partition heap nvs_flash spi_flash esp_wifi esp_http_server esp_netif esp_event fatfs sdmmc esp_driver_sdmmc driver esp_driver_gpio esp_driver_ledc esp_driver_spi
                        )
