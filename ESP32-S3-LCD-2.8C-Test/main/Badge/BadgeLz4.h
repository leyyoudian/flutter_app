#pragma once

#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"

esp_err_t badge_lz4_decompress(const uint8_t *src, size_t src_len, uint8_t *dst, size_t dst_len);
