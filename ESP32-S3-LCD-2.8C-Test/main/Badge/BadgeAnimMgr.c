#include "BadgeAnimMgr.h"

#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <dirent.h>

#include "BadgeDisplay.h"
#include "BadgeProtocol.h"
#include "BadgeStorage.h"

#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "nvs.h"
#include "nvs_flash.h"

static const char *TAG = "BadgeAnimMgr";
#define BADGE_NVS_NAMESPACE "badge"
#define BADGE_NVS_LAST_ID_KEY "last_id"

#define BADGE_SD_MOUNT_POINT "/sdcard"
#define BADGE_ANIM_FOLDER_FIRST  "/sdcard/first_half"
#define BADGE_ANIM_FOLDER_SECOND "/sdcard/second_half"
#define BADGE_ANIM_FOLDER_THIRD  "/sdcard/third_half"
#define BADGE_ANIM_FOLDER_USER   "/sdcard/user"

static badge_anim_entry_t s_entries[BADGE_ANIM_MAX_COUNT];
static uint8_t s_entry_count;
static uint8_t s_factory_count;
static uint8_t s_user_count;

static char s_current_id[BADGE_ANIM_ID_LEN];
static badge_play_mode_t s_play_mode;
static const badge_anim_entry_t *s_current_entry;

static char s_pending_id[BADGE_ANIM_ID_LEN];
static bool s_switch_pending;
static SemaphoreHandle_t s_lock;

/* Save / load last animation ID to NVS for persistence across reboots */
static void save_last_anim_id(const char *id)
{
    nvs_handle_t handle;
    if (nvs_open("badge", NVS_READWRITE, &handle) == ESP_OK) {
        nvs_set_str(handle, "last_id", id);
        nvs_commit(handle);
        nvs_close(handle);
    }
}

static esp_err_t load_last_anim_id(char *out_id, size_t size)
{
    nvs_handle_t handle;
    esp_err_t ret = nvs_open("badge", NVS_READONLY, &handle);
    if (ret != ESP_OK) return ret;
    size_t len = size;
    ret = nvs_get_str(handle, "last_id", out_id, &len);
    nvs_close(handle);
    return ret;
}

static bool is_eb4_file(const char *name)
{
    size_t len = strlen(name);
    return len > 4 && strcasecmp(name + len - 4, ".eb4") == 0;
}

static void extract_id_from_filename(const char *name, char *id_out, size_t id_size)
{
    const char *dot = strrchr(name, '.');
    size_t len = dot ? (size_t)(dot - name) : strlen(name);
    if (len >= id_size) len = id_size - 1;
    memcpy(id_out, name, len);
    id_out[len] = '\0';
}

static badge_anim_type_t folder_to_type(const char *folder)
{
    if (strstr(folder, "first_half"))  return BADGE_ANIM_TYPE_FACTORY_FIRST;
    if (strstr(folder, "second_half")) return BADGE_ANIM_TYPE_FACTORY_SECOND;
    return BADGE_ANIM_TYPE_USER;
}

static uint8_t folder_to_halves(const char *folder)
{
    if (strstr(folder, "first_half"))  return 1;
    if (strstr(folder, "second_half")) return 2;
    return 0;
}

static void read_header_from_path(const char *path, badge_anim_entry_t *entry)
{
    FILE *f = fopen(path, "rb");
    if (f == NULL) return;

    badge_ebaj_header_t header;
    if (fread(&header, 1, sizeof(header), f) == sizeof(header)) {
        if (header.magic == BADGE_EBAJ_MAGIC) {
            entry->frame_count = header.frame_count;
            entry->fps = header.fps;
            entry->stream_width = header.stream_width;
            entry->stream_height = header.stream_height;
        }
    }
    fclose(f);
}

static esp_err_t scan_folder(const char *folder_path, const char *folder_name)
{
    DIR *dir = opendir(folder_path);
    if (dir == NULL) {
        ESP_LOGW(TAG, "folder not found: %s", folder_path);
        return ESP_ERR_NOT_FOUND;
    }

    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL && s_entry_count < BADGE_ANIM_MAX_COUNT) {
        if (entry->d_type != DT_REG) continue;
        if (!is_eb4_file(entry->d_name)) continue;

        badge_anim_entry_t *anim = &s_entries[s_entry_count];
        memset(anim, 0, sizeof(*anim));
        extract_id_from_filename(entry->d_name, anim->id, sizeof(anim->id));
        snprintf(anim->folder, sizeof(anim->folder), "%s", folder_name);
        snprintf(anim->file_path, sizeof(anim->file_path), "%s/%s", folder_path, entry->d_name);
        anim->type = folder_to_type(folder_name);
        anim->halves = folder_to_halves(folder_name);

        read_header_from_path(anim->file_path, anim);

        ESP_LOGI(TAG, "found: %s/%s frames=%u fps=%u stream=%ux%u",
                 folder_name, anim->id,
                 anim->frame_count, anim->fps,
                 anim->stream_width, anim->stream_height);

        if (anim->type == BADGE_ANIM_TYPE_USER) {
            s_user_count++;
        } else {
            s_factory_count++;
        }
        s_entry_count++;
    }
    closedir(dir);
    return ESP_OK;
}

static const badge_anim_entry_t *find_by_id(const char *id, badge_anim_type_t type)
{
    for (uint8_t i = 0; i < s_entry_count; ++i) {
        if (strcmp(s_entries[i].id, id) == 0 && s_entries[i].type == type) {
            return &s_entries[i];
        }
    }
    return NULL;
}

static const badge_anim_entry_t *find_any(const char *id)
{
    for (uint8_t i = 0; i < s_entry_count; ++i) {
        if (strcmp(s_entries[i].id, id) == 0) {
            return &s_entries[i];
        }
    }
    return NULL;
}

/* ©¤©¤ Public API ©¤©¤©¤©¤©¤©¤©¤©¤©¤©¤©¤©¤©¤©¤©¤©¤©¤©¤©¤©¤©¤©¤©¤©¤©¤©¤©¤©¤©¤©¤©¤©¤©¤©¤©¤©¤©¤©¤©¤©¤©¤ */

esp_err_t badge_anim_mgr_init(void)
{
    if (s_lock == NULL) {
        s_lock = xSemaphoreCreateMutex();
        if (s_lock == NULL) return ESP_ERR_NO_MEM;
    }

    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_entry_count = 0;
    s_factory_count = 0;
    s_user_count = 0;
    memset(s_entries, 0, sizeof(s_entries));
    memset(s_current_id, 0, sizeof(s_current_id));
    memset(s_pending_id, 0, sizeof(s_pending_id));
    s_current_entry = NULL;
    s_switch_pending = false;
    s_play_mode = BADGE_PLAY_MODE_LOOP;

    /* Create folders if they don't exist */
    int mkdir_ret;
    mkdir_ret = mkdir(BADGE_ANIM_FOLDER_FIRST, 0755);
    if (mkdir_ret != 0 && errno != EEXIST) {
        ESP_LOGW(TAG, "mkdir %s failed: errno=%d", BADGE_ANIM_FOLDER_FIRST, errno);
    }
    mkdir_ret = mkdir(BADGE_ANIM_FOLDER_SECOND, 0755);
    if (mkdir_ret != 0 && errno != EEXIST) {
        ESP_LOGW(TAG, "mkdir %s failed: errno=%d", BADGE_ANIM_FOLDER_SECOND, errno);
    }
    mkdir_ret = mkdir(BADGE_ANIM_FOLDER_THIRD, 0755);
    if (mkdir_ret != 0 && errno != EEXIST) {
        ESP_LOGW(TAG, "mkdir %s failed: errno=%d", BADGE_ANIM_FOLDER_THIRD, errno);
    }
    mkdir_ret = mkdir(BADGE_ANIM_FOLDER_USER, 0755);
    if (mkdir_ret != 0 && errno != EEXIST) {
        ESP_LOGW(TAG, "mkdir %s failed: errno=%d", BADGE_ANIM_FOLDER_USER, errno);
    }

    scan_folder(BADGE_ANIM_FOLDER_FIRST, "first_half");
    scan_folder(BADGE_ANIM_FOLDER_SECOND, "second_half");
    scan_folder(BADGE_ANIM_FOLDER_USER, "user");

    ESP_LOGI(TAG, "scanned %u animations: %u factory, %u user",
             s_entry_count, s_factory_count, s_user_count);

    /* Try to resume last-played animation from NVS */
    char last_id[BADGE_ANIM_ID_LEN] = {0};
    const badge_anim_entry_t *resume_entry = NULL;
    if (load_last_anim_id(last_id, sizeof(last_id)) == ESP_OK && last_id[0] != '\0') {
        resume_entry = find_any(last_id);
        /* User files may not be in scanned list; check filesystem */
        if (resume_entry == NULL && last_id[0] == 'U') {
            char user_path[72];
            snprintf(user_path, sizeof(user_path), "/sdcard/user/%s.eb4", last_id);
            FILE *f = fopen(user_path, "rb");
            if (f != NULL) {
                fclose(f);
                /* File exists – we'll play it by path below */
            }
        }
    }

    if (resume_entry != NULL) {
        strncpy(s_current_id, resume_entry->id, sizeof(s_current_id) - 1);
        s_current_entry = resume_entry;
        s_play_mode = (resume_entry->type == BADGE_ANIM_TYPE_FACTORY_FIRST)
                          ? BADGE_PLAY_MODE_FIRST_HALF_FREEZE
                          : BADGE_PLAY_MODE_LOOP;
        ESP_LOGI(TAG, "resuming last animation: %s", resume_entry->id);
    } else if (last_id[0] == 'U') {
        /* User file not in scanned entries */
        strncpy(s_current_id, last_id, sizeof(s_current_id) - 1);
        s_current_entry = NULL;
        s_play_mode = BADGE_PLAY_MODE_LOOP;
        ESP_LOGI(TAG, "resuming last user animation: %s", last_id);
    } else if (s_factory_count > 0) {
        /* Default: play first factory animation */
        for (uint8_t i = 0; i < s_entry_count; ++i) {
            if (s_entries[i].type == BADGE_ANIM_TYPE_FACTORY_FIRST) {
                strncpy(s_current_id, s_entries[i].id, sizeof(s_current_id) - 1);
                s_current_entry = &s_entries[i];
                s_play_mode = BADGE_PLAY_MODE_FIRST_HALF_FREEZE;
                break;
            }
        }
    }

    /* Trigger initial playback */
    const badge_anim_entry_t *init_entry = s_current_entry;
    badge_play_mode_t init_mode = s_play_mode;
    char init_user_path[72] = {0};
    if (init_entry == NULL && s_current_id[0] == 'U') {
        snprintf(init_user_path, sizeof(init_user_path), "/sdcard/user/%s.eb4", s_current_id);
    }
    xSemaphoreGive(s_lock);

    if (init_entry != NULL) {
        ESP_LOGI(TAG, "starting default animation: %s from %s",
                 init_entry->id, init_entry->file_path);
        esp_err_t play_ret = badge_display_play_asset_file(init_entry->file_path, init_mode);
        if (play_ret != ESP_OK) {
            ESP_LOGW(TAG, "failed to start default animation: %s", esp_err_to_name(play_ret));
        }
    } else if (init_user_path[0] != '\0') {
        ESP_LOGI(TAG, "starting user animation: %s", init_user_path);
        esp_err_t play_ret = badge_display_play_asset_file(init_user_path, BADGE_PLAY_MODE_LOOP);
        if (play_ret != ESP_OK) {
            ESP_LOGW(TAG, "failed to start user animation: %s", esp_err_to_name(play_ret));
        }
    }
    return ESP_OK;
}

uint8_t badge_anim_mgr_factory_count(void)
{
    return s_factory_count / 2;  // Pairs count
}

uint8_t badge_anim_mgr_user_count(void)
{
    return s_user_count;
}

const badge_anim_entry_t *badge_anim_mgr_find(const char *id)
{
    return find_any(id);
}

const badge_anim_entry_t *badge_anim_mgr_get_factory(uint8_t index)
{
    uint8_t count = 0;
    for (uint8_t i = 0; i < s_entry_count; ++i) {
        if (s_entries[i].type == BADGE_ANIM_TYPE_FACTORY_FIRST) {
            if (count == index) return &s_entries[i];
            count++;
        }
    }
    return NULL;
}

const badge_anim_entry_t *badge_anim_mgr_get_user(uint8_t index)
{
    uint8_t count = 0;
    for (uint8_t i = 0; i < s_entry_count; ++i) {
        if (s_entries[i].type == BADGE_ANIM_TYPE_USER) {
            if (count == index) return &s_entries[i];
            count++;
        }
    }
    return NULL;
}

const badge_anim_entry_t *badge_anim_mgr_find_paired_second(const char *first_id)
{
    return find_by_id(first_id, BADGE_ANIM_TYPE_FACTORY_SECOND);
}

const char *badge_anim_mgr_alloc_user_id(void)
{
    static char new_id[BADGE_ANIM_ID_LEN];
    uint8_t max_num = 0;
    for (uint8_t i = 0; i < s_entry_count; ++i) {
        if (s_entries[i].type == BADGE_ANIM_TYPE_USER && s_entries[i].id[0] == 'U') {
            uint8_t num = (uint8_t)atoi(s_entries[i].id + 1);
            if (num > max_num) max_num = num;
        }
    }
    /* Also check filesystem for user files not yet scanned */
    DIR *dir = opendir("/sdcard/user");
    if (dir != NULL) {
        struct dirent *entry;
        while ((entry = readdir(dir)) != NULL) {
            if (entry->d_type == DT_REG && entry->d_name[0] == 'U') {
                uint8_t num = (uint8_t)atoi(entry->d_name + 1);
                if (num > max_num) max_num = num;
            }
        }
        closedir(dir);
    }
    snprintf(new_id, sizeof(new_id), "U%03u", max_num + 1);
    return new_id;
}

badge_play_mode_t badge_anim_mgr_get_play_mode(void)
{
    return s_play_mode;
}

esp_err_t badge_anim_mgr_play(const char *id, badge_play_mode_t mode)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);

    const badge_anim_entry_t *entry = find_any(id);
    if (entry == NULL) {
        /* User files may not be in scanned list */
        if (id[0] == 'U') {
            char user_path[72];
            snprintf(user_path, sizeof(user_path), "/sdcard/user/%s.eb4", id);
            strncpy(s_current_id, id, sizeof(s_current_id) - 1);
            s_play_mode = mode;
            save_last_anim_id(id);
            xSemaphoreGive(s_lock);
            ESP_LOGI(TAG, "play user file: %s mode=%d", user_path, mode);
            return badge_display_play_asset_file(user_path, mode);
        }
        xSemaphoreGive(s_lock);
        return ESP_ERR_NOT_FOUND;
    }

    strncpy(s_current_id, id, sizeof(s_current_id) - 1);
    s_current_entry = entry;
    s_play_mode = mode;

    ESP_LOGI(TAG, "play: %s from %s mode=%d", id, entry->file_path, mode);
    save_last_anim_id(id);

    esp_err_t ret = badge_display_play_asset_file(entry->file_path, mode);
    xSemaphoreGive(s_lock);
    return ret;
}

esp_err_t badge_anim_mgr_switch_to(const char *new_id)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);

    const badge_anim_entry_t *new_entry = find_any(new_id);
    bool is_user = (new_entry == NULL && new_id[0] == 'U') ||
                   (new_entry != NULL && new_entry->type == BADGE_ANIM_TYPE_USER);
    if (new_entry == NULL && !is_user) {
        xSemaphoreGive(s_lock);
        return ESP_ERR_NOT_FOUND;
    }

    ESP_LOGI(TAG, "switch requested: %s (current=%s mode=%d)",
             new_id, s_current_id, s_play_mode);

    /* Play second_half exit animation only when leaving a factory animation.
       User content switches directly without exit animation. */
    bool current_is_factory = (s_current_entry != NULL &&
                               s_current_entry->type != BADGE_ANIM_TYPE_USER);
    if (current_is_factory &&
        s_play_mode == BADGE_PLAY_MODE_FIRST_HALF_FREEZE &&
        s_current_entry != NULL &&
        s_current_entry->type == BADGE_ANIM_TYPE_FACTORY_FIRST) {

        const badge_anim_entry_t *second = find_by_id(s_current_id, BADGE_ANIM_TYPE_FACTORY_SECOND);
        /* Check for directional third_half transition: <source>_<dest>.eb4 */
        char third_path[80];
        snprintf(third_path, sizeof(third_path), "/sdcard/third_half/%s_%s.eb4", s_current_id, new_id);
        FILE *tf = fopen(third_path, "rb");
        if (tf != NULL) {
            fclose(tf);
            /* Update state to reflect the target animation */
            const char *old_id = s_current_id;
            strncpy(s_current_id, new_id, sizeof(s_current_id) - 1);
            s_current_entry = new_entry;
            s_play_mode = BADGE_PLAY_MODE_FIRST_HALF_FREEZE;
            save_last_anim_id(new_id);
            ESP_LOGI(TAG, "playing third_half %s->%s (skip target first_half)", old_id, new_id);
            esp_err_t ret = badge_display_play_asset_file(third_path, BADGE_PLAY_MODE_SECOND_HALF);
            xSemaphoreGive(s_lock);
            return ret;
        }
        if (second != NULL) {
            strncpy(s_pending_id, new_id, sizeof(s_pending_id) - 1);
            s_switch_pending = true;
            ESP_LOGI(TAG, "playing second_half of %s before switch to %s", s_current_id, new_id);
            esp_err_t ret = badge_display_play_asset_file(second->file_path, BADGE_PLAY_MODE_SECOND_HALF);
            xSemaphoreGive(s_lock);
            return ret;
        }
    }

    /* Direct switch */
    if (is_user && new_entry == NULL) {
        char user_path[72];
        snprintf(user_path, sizeof(user_path), "/sdcard/user/%s.eb4", new_id);
        strncpy(s_current_id, new_id, sizeof(s_current_id) - 1);
        s_play_mode = BADGE_PLAY_MODE_LOOP;
        save_last_anim_id(new_id);
        xSemaphoreGive(s_lock);
        ESP_LOGI(TAG, "switch to user file: %s", user_path);
        return badge_display_play_asset_file(user_path, BADGE_PLAY_MODE_LOOP);
    }

    badge_play_mode_t mode;
    if (new_entry->type == BADGE_ANIM_TYPE_FACTORY_FIRST) {
        mode = BADGE_PLAY_MODE_FIRST_HALF_FREEZE;
    } else {
        mode = BADGE_PLAY_MODE_LOOP;
    }

    strncpy(s_current_id, new_id, sizeof(s_current_id) - 1);
    s_current_entry = new_entry;
    s_play_mode = mode;
    save_last_anim_id(new_id);
    xSemaphoreGive(s_lock);

    ESP_LOGI(TAG, "play: %s from %s mode=%d", new_id, new_entry->file_path, mode);
    return badge_display_play_asset_file(new_entry->file_path, mode);
}

void badge_anim_mgr_notify_finished(void)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);

    ESP_LOGI(TAG, "animation finished, pending=%d", s_switch_pending);

    if (s_switch_pending) {
        /* Second_half finished, now play the pending new animation */
        char next_id[BADGE_ANIM_ID_LEN];
        strncpy(next_id, s_pending_id, sizeof(next_id) - 1);
        memset(s_pending_id, 0, sizeof(s_pending_id));
        s_switch_pending = false;

        /* Release lock before calling play() which re-acquires it */
        xSemaphoreGive(s_lock);

        const badge_anim_entry_t *next = find_any(next_id);
        badge_play_mode_t mode = BADGE_PLAY_MODE_LOOP;
        if (next != NULL && next->type == BADGE_ANIM_TYPE_FACTORY_FIRST) {
            mode = BADGE_PLAY_MODE_FIRST_HALF_FREEZE;
        }

        ESP_LOGI(TAG, "switching to %s mode=%d", next_id, mode);
        badge_anim_mgr_play(next_id, mode);
        return;
    }

    if (s_play_mode == BADGE_PLAY_MODE_FIRST_HALF_FREEZE) {
        /* First_half finished, freeze. Don't loop. */
        ESP_LOGI(TAG, "first_half done, frozen at last frame");
        /* Already frozen – badge_display handles this */
    }

    xSemaphoreGive(s_lock);
}

bool badge_anim_mgr_switch_pending(void)
{
    return s_switch_pending;
}

const char *badge_anim_mgr_pending_id(void)
{
    return s_pending_id;
}

const char *badge_anim_mgr_current_id(void)
{
    return s_current_id;
}

const badge_anim_entry_t *badge_anim_mgr_current_entry(void)
{
    return s_current_entry;
}
