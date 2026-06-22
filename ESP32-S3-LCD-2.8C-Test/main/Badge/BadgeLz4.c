#include "BadgeLz4.h"

#include <string.h>

esp_err_t badge_lz4_decompress(const uint8_t *src, size_t src_len, uint8_t *dst, size_t dst_len)
{
    if (src == NULL || dst == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    const uint8_t *ip = src;
    const uint8_t *iend = src + src_len;
    uint8_t *op = dst;
    uint8_t *oend = dst + dst_len;

    while (ip < iend) {
        uint8_t token = *ip++;

        size_t literal_len = token >> 4;
        if (literal_len == 15) {
            uint8_t s;
            do {
                if (ip >= iend) {
                    return ESP_ERR_INVALID_RESPONSE;
                }
                s = *ip++;
                literal_len += s;
            } while (s == 255);
        }

        if ((size_t)(iend - ip) < literal_len || (size_t)(oend - op) < literal_len) {
            return ESP_ERR_INVALID_SIZE;
        }
        memcpy(op, ip, literal_len);
        ip += literal_len;
        op += literal_len;

        if (ip == iend) {
            break;
        }
        if ((size_t)(iend - ip) < 2) {
            return ESP_ERR_INVALID_RESPONSE;
        }

        uint16_t match_offset = (uint16_t)ip[0] | ((uint16_t)ip[1] << 8);
        ip += 2;
        if (match_offset == 0 || (size_t)match_offset > (size_t)(op - dst)) {
            return ESP_ERR_INVALID_RESPONSE;
        }

        size_t match_len = token & 0x0f;
        if (match_len == 15) {
            uint8_t s;
            do {
                if (ip >= iend) {
                    return ESP_ERR_INVALID_RESPONSE;
                }
                s = *ip++;
                match_len += s;
            } while (s == 255);
        }
        match_len += 4;

        if ((size_t)(oend - op) < match_len) {
            return ESP_ERR_INVALID_SIZE;
        }

        const uint8_t *match = op - match_offset;
        if ((size_t)match_offset >= match_len) {
            memcpy(op, match, match_len);
        } else {
            uint8_t *start = op;
            memcpy(start, match, match_offset);
            size_t copied = match_offset;
            while (copied < match_len) {
                size_t chunk = copied;
                size_t remaining = match_len - copied;
                if (chunk > remaining) {
                    chunk = remaining;
                }
                memcpy(start + copied, start, chunk);
                copied += chunk;
            }
        }
        op += match_len;
    }

    return op == oend ? ESP_OK : ESP_ERR_INVALID_SIZE;
}
