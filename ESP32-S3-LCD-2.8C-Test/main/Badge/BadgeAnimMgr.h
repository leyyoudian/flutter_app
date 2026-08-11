#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "BadgeDisplay.h"
#include "esp_err.h"

#define BADGE_ANIM_ID_LEN 8
#define BADGE_ANIM_FOLDER_LEN 32
#define BADGE_ANIM_MAX_COUNT 64

typedef enum {
    BADGE_ANIM_TYPE_FACTORY_FIRST = 0,
    BADGE_ANIM_TYPE_FACTORY_SECOND,
    BADGE_ANIM_TYPE_FACTORY_LOOP,
    BADGE_ANIM_TYPE_USER,
} badge_anim_type_t;

typedef struct {
    char id[BADGE_ANIM_ID_LEN];          // "F001" / "U012"
    char folder[BADGE_ANIM_FOLDER_LEN];  // "first_half" / "second_half" / "user"
    char file_path[64];                  // Full path: /sdcard/first_half/F001.eb4
    badge_anim_type_t type;
    uint16_t frame_count;
    uint16_t fps;
    uint16_t stream_width;
    uint16_t stream_height;
    uint8_t halves;                      // 0=none/user, 1=first, 2=second
} badge_anim_entry_t;

/**
 * @brief Initialize the animation manager and scan SD card.
 * Must be called after SD card is mounted.
 */
esp_err_t badge_anim_mgr_init(void);

/**
 * @brief Rescan SD card animation folders after managed files change.
 */
esp_err_t badge_anim_mgr_rescan(void);

/**
 * @brief Get the number of factory animations (pairs count as one).
 */
uint8_t badge_anim_mgr_factory_count(void);

/**
 * @brief Get the number of user animations.
 */
uint8_t badge_anim_mgr_user_count(void);

/**
 * @brief Get animation entry by ID. Returns NULL if not found.
 */
const badge_anim_entry_t *badge_anim_mgr_find(const char *id);

/**
 * @brief Get factory animation entry by index (0..N-1).
 */
const badge_anim_entry_t *badge_anim_mgr_get_factory(uint8_t index);

/**
 * @brief Get user animation entry by index (0..N-1).
 */
const badge_anim_entry_t *badge_anim_mgr_get_user(uint8_t index);

/**
 * @brief Find the paired second_half for a first_half ID.
 * Returns NULL if no pair exists.
 */
const badge_anim_entry_t *badge_anim_mgr_find_paired_second(const char *first_id);

/**
 * @brief Allocate a new user ID. Returns empty string on failure.
 */
const char *badge_anim_mgr_alloc_user_id(void);

/**
 * @brief Get current playback mode.
 */
badge_play_mode_t badge_anim_mgr_get_play_mode(void);

/**
 * @brief Start playing an animation by ID.
 * Returns ESP_OK on success, ESP_ERR_NOT_FOUND if missing.
 */
esp_err_t badge_anim_mgr_play(const char *id, badge_play_mode_t mode);

/**
 * @brief Request switch to a new animation.
 * Handles the transition: current second_half → new first_half.
 */
esp_err_t badge_anim_mgr_switch_to(const char *new_id);

/**
 * @brief Enable/disable random playback and persist the mode to NVS.
 */
esp_err_t badge_anim_mgr_set_random_enabled(bool enabled);

/**
 * @brief Get whether random playback is enabled.
 */
bool badge_anim_mgr_random_enabled(void);

/**
 * @brief Notify that current playback finished.
 * Called by the display task when an animation ends.
 */
void badge_anim_mgr_notify_finished(void);

/**
 * @brief Check if a switch is pending (waiting for current anim to finish).
 */
bool badge_anim_mgr_switch_pending(void);

/**
 * @brief Get the pending switch target ID.
 */
const char *badge_anim_mgr_pending_id(void);

/**
 * @brief Get current playing animation ID.
 */
const char *badge_anim_mgr_current_id(void);

/**
 * @brief Get current playing animation entry.
 */
const badge_anim_entry_t *badge_anim_mgr_current_entry(void);

