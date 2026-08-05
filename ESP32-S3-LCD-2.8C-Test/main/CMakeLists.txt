idf_component_register(
                        SRCS  "main.c" 
                              "Badge/BadgeDisplay.c"
                              "Badge/BadgeIndexed.c"
                              "Badge/BadgeLz4.c"
                              "Badge/BadgeProtocol.c"
                              "Badge/BadgeStream.c"
                              "Badge/BadgeAnimMgr.c"
                              "Badge/BadgeFactorySync.c"
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
                        REQUIRES esp_lcd esp_timer esp_partition heap nvs_flash spi_flash esp_wifi esp_http_server esp_netif esp_event esp_https_ota esp_http_client app_update mbedtls json fatfs sdmmc esp_driver_sdmmc driver esp_driver_gpio esp_driver_ledc esp_driver_spi
                        EMBED_FILES "assets/upload_480_rgb565.bin"
                        )

target_compile_definitions(${COMPONENT_LIB} PRIVATE BADGE_FW_VERSION=\"${PROJECT_VER}\")
