#include "BadgeAnimMgr.h"

#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <unistd.h>
#include <dirent.h>

#include "BadgeDisplay.h"
#include "BadgeProtocol.h"
#include "BadgeStorage.h"

#include "esp_log.h"
#include "esp_random.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "nvs.h"
#include "nvs_flash.h"

static const char *TAG = "BadgeAnimMgr";
#define BADGE_NVS_NAMESPACE "badge"
#define BADGE_NVS_LAST_ID_KEY "last_id"
#define BADGE_NVS_RANDOM_KEY "random"
#define BADGE_RANDOM_DWELL_MS 1500u
#define BADGE_RANDOM_MIN_LOOP_MS 3000u
#define BADGE_RANDOM_TASK_STACK 3072
#define BADGE_RANDOM_TASK_PRIORITY 4

#define BADGE_SD_MOUNT_POINT "/sdcard"
#define BADGE_ANIM_FOLDER_FIRST  "/sdcard/first_half"
#define BADGE_ANIM_FOLDER_SECOND "/sdcard/second_half"
#define BADGE_ANIM_FOLDER_THIRD  "/sdcard/third_half"
#define BADGE_ANIM_FOLDER_FACTORY_LOOP "/sdcard/factory_loop"
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
static bool s_transition_lands_on_current;
static bool s_random_enabled;
static uint32_t s_random_next_switch_ms;
static TaskHandle_t s_random_task;
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

static void save_random_enabled(bool enabled)
{
    nvs_handle_t handle;
    if (nvs_open(BADGE_NVS_NAMESPACE, NVS_READWRITE, &handle) == ESP_OK) {
        nvs_set_u8(handle, BADGE_NVS_RANDOM_KEY, enabled ? 1 : 0);
        nvs_commit(handle);
        nvs_close(handle);
    }
}

static bool load_random_enabled(void)
{
    nvs_handle_t handle;
    uint8_t value = 0;
    if (nvs_open(BADGE_NVS_NAMESPACE, NVS_READONLY, &handle) == ESP_OK) {
        (void)nvs_get_u8(handle, BADGE_NVS_RANDOM_KEY, &value);
        nvs_close(handle);
    }
    return value != 0;
}

static uint32_t now_ms(void)
{
    return (uint32_t)pdTICKS_TO_MS(xTaskGetTickCount());
}

static uint32_t entry_duration_ms(const badge_anim_entry_t *entry)
{
    if (entry == NULL || entry->frame_count == 0 || entry->fps == 0) {
        return BADGE_RANDOM_MIN_LOOP_MS;
    }
    uint32_t duration = ((uint32_t)entry->frame_count * 1000u + (uint32_t)entry->fps - 1u) /
                        (uint32_t)entry->fps;
    if (duration < BADGE_RANDOM_MIN_LOOP_MS &&
        (entry->type == BADGE_ANIM_TYPE_USER || entry->type == BADGE_ANIM_TYPE_FACTORY_LOOP)) {
        duration = BADGE_RANDOM_MIN_LOOP_MS;
    }
    return duration;
}

static void schedule_random_for_entry_locked(const badge_anim_entry_t *entry, badge_play_mode_t mode)
{
    if (!s_random_enabled || mode == BADGE_PLAY_MODE_SECOND_HALF) {
        return;
    }
    uint32_t delay_ms = entry_duration_ms(entry);
    if (mode == BADGE_PLAY_MODE_FIRST_HALF_FREEZE) {
        delay_ms += BADGE_RANDOM_DWELL_MS;
    }
    s_random_next_switch_ms = now_ms() + delay_ms;
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
    if (strstr(folder, "factory_loop")) return BADGE_ANIM_TYPE_FACTORY_LOOP;
    return BADGE_ANIM_TYPE_USER;
}

static uint8_t folder_to_halves(const char *folder)
{
    if (strstr(folder, "first_half"))  return 1;
    if (strstr(folder, "second_half")) return 2;
    return 0;
}

static badge_play_mode_t entry_default_mode(const badge_anim_entry_t *entry)
{
    if (entry == NULL) {
        return BADGE_PLAY_MODE_LOOP;
    }
    if (entry->type == BADGE_ANIM_TYPE_FACTORY_FIRST) {
        return BADGE_PLAY_MODE_FIRST_HALF_FREEZE;
    }
    if (entry->type == BADGE_ANIM_TYPE_FACTORY_LOOP) {
        return BADGE_PLAY_MODE_LOOP;
    }
    return BADGE_PLAY_MODE_LOOP;
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
        } else if (anim->type == BADGE_ANIM_TYPE_FACTORY_FIRST ||
                   anim->type == BADGE_ANIM_TYPE_FACTORY_LOOP) {
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

static uint8_t collect_random_candidates(char ids[][BADGE_ANIM_ID_LEN], uint8_t max_count)
{
    uint8_t count = 0;
    for (uint8_t i = 0; i < s_entry_count && count < max_count; ++i) {
        const badge_anim_entry_t *entry = &s_entries[i];
        if (entry->type != BADGE_ANIM_TYPE_FACTORY_FIRST &&
            entry->type != BADGE_ANIM_TYPE_FACTORY_LOOP &&
            entry->type != BADGE_ANIM_TYPE_USER) {
            continue;
        }
        strncpy(ids[count], entry->id, BADGE_ANIM_ID_LEN - 1);
        ids[count][BADGE_ANIM_ID_LEN - 1] = '\0';
        ++count;
    }
    return count;
}

static uint32_t random_bounded(uint32_t count)
{
    if (count <= 1) {
        return 0;
    }
    uint32_t limit = UINT32_MAX - (UINT32_MAX % count);
    uint32_t value;
    do {
        value = esp_random();
    } while (value >= limit);
    return value % count;
}

static bool pick_random_id_locked(char *out_id, size_t out_size)
{
    char ids[BADGE_ANIM_MAX_COUNT][BADGE_ANIM_ID_LEN];
    uint8_t count = collect_random_candidates(ids, BADGE_ANIM_MAX_COUNT);
    if (count == 0) {
        return false;
    }

    uint8_t picked = (uint8_t)random_bounded(count);
    if (count > 1 && s_current_id[0] != '\0') {
        for (uint8_t tries = 0; tries < 8 && strcmp(ids[picked], s_current_id) == 0; ++tries) {
            picked = (uint8_t)random_bounded(count);
        }
        if (strcmp(ids[picked], s_current_id) == 0) {
            picked = (uint8_t)((picked + 1) % count);
        }
    }

    strncpy(out_id, ids[picked], out_size - 1);
    out_id[out_size - 1] = '\0';
    return true;
}

static void random_task(void *arg)
{
    (void)arg;
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(500));

        char next_id[BADGE_ANIM_ID_LEN] = {0};
        bool should_switch = false;

        xSemaphoreTake(s_lock, portMAX_DELAY);
        if (s_random_enabled &&
            s_random_next_switch_ms != 0 &&
            !s_switch_pending &&
            s_play_mode != BADGE_PLAY_MODE_SECOND_HALF) {
            uint32_t now = now_ms();
            if ((int32_t)(now - s_random_next_switch_ms) >= 0) {
                should_switch = pick_random_id_locked(next_id, sizeof(next_id));
                if (should_switch) {
                    s_random_next_switch_ms = 0;
                } else {
                    s_random_next_switch_ms = now + BADGE_RANDOM_MIN_LOOP_MS;
                }
            }
        }
        xSemaphoreGive(s_lock);

        if (should_switch) {
            ESP_LOGI(TAG, "random switching to %s", next_id);
            (void)badge_anim_mgr_switch_to(next_id);
        }
    }
}

static void ensure_random_task_started(void)
{
    if (s_random_task != NULL) {
        return;
    }
    if (xTaskCreate(random_task, "badge_random", BADGE_RANDOM_TASK_STACK, NULL,
                    BADGE_RANDOM_TASK_PRIORITY, &s_random_task) != pdPASS) {
        ESP_LOGW(TAG, "failed to start random task");
    }
}
static bool is_factory_six_seven_pair(const char *source_id, const char *target_id)
{
    return (strcmp(source_id, "F006") == 0 && strcmp(target_id, "F007") == 0) ||
           (strcmp(source_id, "F007") == 0 && strcmp(target_id, "F006") == 0);
}

/* ���� Public API ���������������������������������������������������������������������������������� */

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
    s_transition_lands_on_current = false;
    s_random_enabled = load_random_enabled();
    s_random_next_switch_ms = 0;
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
    mkdir_ret = mkdir(BADGE_ANIM_FOLDER_FACTORY_LOOP, 0755);
    if (mkdir_ret != 0 && errno != EEXIST) {
        ESP_LOGW(TAG, "mkdir %s failed: errno=%d", BADGE_ANIM_FOLDER_FACTORY_LOOP, errno);
    }
    mkdir_ret = mkdir(BADGE_ANIM_FOLDER_USER, 0755);
    if (mkdir_ret != 0 && errno != EEXIST) {
        ESP_LOGW(TAG, "mkdir %s failed: errno=%d", BADGE_ANIM_FOLDER_USER, errno);
    }

    scan_folder(BADGE_ANIM_FOLDER_FIRST, "first_half");
    scan_folder(BADGE_ANIM_FOLDER_SECOND, "second_half");
    scan_folder(BADGE_ANIM_FOLDER_FACTORY_LOOP, "factory_loop");
    scan_folder(BADGE_ANIM_FOLDER_USER, "user");

    ESP_LOGI(TAG, "scanned %u animations: %u factory, %u user",
             s_entry_count, s_factory_count, s_user_count);

    const badge_anim_entry_t *resume_entry = NULL;
    bool random_start = false;
    if (s_random_enabled) {
        char random_id[BADGE_ANIM_ID_LEN] = {0};
        if (pick_random_id_locked(random_id, sizeof(random_id))) {
            resume_entry = find_any(random_id);
            if (resume_entry != NULL) {
                strncpy(s_current_id, resume_entry->id, sizeof(s_current_id) - 1);
                s_current_entry = resume_entry;
                s_play_mode = entry_default_mode(resume_entry);
                random_start = true;
                ESP_LOGI(TAG, "starting random animation: %s", resume_entry->id);
            }
        }
    }

    /* Try to resume last-played animation from NVS */
    char last_id[BADGE_ANIM_ID_LEN] = {0};
    if (!s_random_enabled &&
        load_last_anim_id(last_id, sizeof(last_id)) == ESP_OK && last_id[0] != '\0') {
        resume_entry = find_any(last_id);
        /* User files may not be in scanned list; check filesystem */
        if (resume_entry == NULL && last_id[0] == 'U') {
            char user_path[72];
            snprintf(user_path, sizeof(user_path), "/sdcard/user/%s.eb4", last_id);
            FILE *f = fopen(user_path, "rb");
            if (f != NULL) {
                fclose(f);
                /* File exists � we'll play it by path below */
            }
        }
    }

    if (resume_entry != NULL) {
        strncpy(s_current_id, resume_entry->id, sizeof(s_current_id) - 1);
        s_current_entry = resume_entry;
        s_play_mode = entry_default_mode(resume_entry);
        ESP_LOGI(TAG, "%s animation: %s",
                 random_start ? "random start" : "resuming last",
                 resume_entry->id);
    } else if (last_id[0] == 'U') {
        /* User file not in scanned entries */
        strncpy(s_current_id, last_id, sizeof(s_current_id) - 1);
        s_current_entry = NULL;
        s_play_mode = BADGE_PLAY_MODE_LOOP;
        ESP_LOGI(TAG, "resuming last user animation: %s", last_id);
    } else if (s_factory_count > 0) {
        /* Default: play first factory animation */
        for (uint8_t i = 0; i < s_entry_count; ++i) {
            if (s_entries[i].type == BADGE_ANIM_TYPE_FACTORY_FIRST ||
                s_entries[i].type == BADGE_ANIM_TYPE_FACTORY_LOOP) {
                strncpy(s_current_id, s_entries[i].id, sizeof(s_current_id) - 1);
                s_current_entry = &s_entries[i];
                s_play_mode = entry_default_mode(&s_entries[i]);
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
    schedule_random_for_entry_locked(init_entry, init_mode);
    ensure_random_task_started();
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

esp_err_t badge_anim_mgr_rescan(void)
{
    return badge_anim_mgr_init();
}

uint8_t badge_anim_mgr_factory_count(void)
{
    return s_factory_count;
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
        if (s_entries[i].type == BADGE_ANIM_TYPE_FACTORY_FIRST ||
            s_entries[i].type == BADGE_ANIM_TYPE_FACTORY_LOOP) {
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
            s_current_entry = NULL;
            s_transition_lands_on_current = false;
            schedule_random_for_entry_locked(NULL, mode);
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
    s_transition_lands_on_current = false;
    schedule_random_for_entry_locked(entry, mode);

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

    if (!s_switch_pending && strcmp(new_id, s_current_id) == 0) {
        ESP_LOGI(TAG, "already showing requested animation: %s", new_id);
        xSemaphoreGive(s_lock);
        return ESP_OK;
    }

    if (s_switch_pending || s_play_mode == BADGE_PLAY_MODE_SECOND_HALF) {
        if (strcmp(s_pending_id, new_id) != 0) {
            strncpy(s_pending_id, new_id, sizeof(s_pending_id) - 1);
            s_pending_id[sizeof(s_pending_id) - 1] = '\0';
        }
        s_switch_pending = true;
        ESP_LOGI(TAG, "coalesced switch while transition playing: pending=%s", s_pending_id);
        xSemaphoreGive(s_lock);
        return ESP_OK;
    }

    /* Play second_half exit animation only when leaving a factory animation.
       User content switches directly without exit animation. */
    bool current_is_factory = (s_current_entry != NULL &&
                               s_current_entry->type != BADGE_ANIM_TYPE_USER);
    if (current_is_factory &&
        s_play_mode == BADGE_PLAY_MODE_FIRST_HALF_FREEZE &&
        s_current_entry != NULL &&
        s_current_entry->type == BADGE_ANIM_TYPE_FACTORY_FIRST) {

        const badge_anim_entry_t *second = find_by_id(s_current_id, BADGE_ANIM_TYPE_FACTORY_SECOND);
        if (is_factory_six_seven_pair(s_current_id, new_id)) {
            char third_path[80];
            snprintf(third_path, sizeof(third_path), BADGE_ANIM_FOLDER_THIRD "/%s.eb4", new_id);
            FILE *tf = fopen(third_path, "rb");
            if (tf != NULL) {
                fclose(tf);
                char old_id[BADGE_ANIM_ID_LEN];
                snprintf(old_id, sizeof(old_id), "%s", s_current_id);
                snprintf(s_current_id, sizeof(s_current_id), "%s", new_id);
                s_current_entry = new_entry;
                s_play_mode = BADGE_PLAY_MODE_SECOND_HALF;
                s_transition_lands_on_current = true;
                save_last_anim_id(new_id);
                ESP_LOGI(TAG, "playing F006/F007 third_half %s->%s: %s", old_id, new_id, third_path);
                esp_err_t ret = badge_display_play_asset_file(third_path, BADGE_PLAY_MODE_SECOND_HALF);
                xSemaphoreGive(s_lock);
                return ret;
            }
            ESP_LOGW(TAG, "F006/F007 third_half missing for %s->%s: %s", s_current_id, new_id, third_path);
        }
        if (second != NULL) {
            strncpy(s_pending_id, new_id, sizeof(s_pending_id) - 1);
            s_pending_id[sizeof(s_pending_id) - 1] = '\0';
            s_switch_pending = true;
            s_play_mode = BADGE_PLAY_MODE_SECOND_HALF;
            s_transition_lands_on_current = false;
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
        s_current_entry = NULL;
        s_transition_lands_on_current = false;
        schedule_random_for_entry_locked(NULL, BADGE_PLAY_MODE_LOOP);
        save_last_anim_id(new_id);
        xSemaphoreGive(s_lock);
        ESP_LOGI(TAG, "switch to user file: %s", user_path);
        return badge_display_play_asset_file(user_path, BADGE_PLAY_MODE_LOOP);
    }

    badge_play_mode_t mode = entry_default_mode(new_entry);

    strncpy(s_current_id, new_id, sizeof(s_current_id) - 1);
    s_current_entry = new_entry;
    s_play_mode = mode;
    s_transition_lands_on_current = false;
    schedule_random_for_entry_locked(new_entry, mode);
    save_last_anim_id(new_id);
    xSemaphoreGive(s_lock);

    ESP_LOGI(TAG, "play: %s from %s mode=%d", new_id, new_entry->file_path, mode);
    return badge_display_play_asset_file(new_entry->file_path, mode);
}

esp_err_t badge_anim_mgr_set_random_enabled(bool enabled)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_random_enabled = enabled;
    save_random_enabled(enabled);
    ensure_random_task_started();

    if (enabled) {
        s_random_next_switch_ms = now_ms() + 500u;
        ESP_LOGI(TAG, "random playback enabled");
    } else {
        s_random_next_switch_ms = 0;
        ESP_LOGI(TAG, "random playback disabled");
    }

    xSemaphoreGive(s_lock);
    return ESP_OK;
}

bool badge_anim_mgr_random_enabled(void)
{
    bool enabled;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    enabled = s_random_enabled;
    xSemaphoreGive(s_lock);
    return enabled;
}

void badge_anim_mgr_notify_finished(void)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);

    ESP_LOGI(TAG, "animation finished, pending=%d", s_switch_pending);

    bool transition_landed_on_current = (s_play_mode == BADGE_PLAY_MODE_SECOND_HALF &&
                                         s_transition_lands_on_current);

    if (s_switch_pending) {
        /* Second_half finished, now play the pending new animation */
        char next_id[BADGE_ANIM_ID_LEN];
        strncpy(next_id, s_pending_id, sizeof(next_id) - 1);
        memset(s_pending_id, 0, sizeof(s_pending_id));
        s_switch_pending = false;

        if (transition_landed_on_current) {
            s_transition_lands_on_current = false;
            s_play_mode = BADGE_PLAY_MODE_FIRST_HALF_FREEZE;
            ESP_LOGI(TAG, "transition landed on %s; processing pending switch to %s",
                     s_current_id, next_id);
            xSemaphoreGive(s_lock);
            badge_anim_mgr_switch_to(next_id);
            return;
        }

        s_transition_lands_on_current = false;

        /* Release lock before calling play() which re-acquires it */
        xSemaphoreGive(s_lock);

        const badge_anim_entry_t *next = find_any(next_id);
        badge_play_mode_t mode = entry_default_mode(next);

        ESP_LOGI(TAG, "switching to %s mode=%d", next_id, mode);
        badge_anim_mgr_play(next_id, mode);
        return;
    }

    if (s_play_mode == BADGE_PLAY_MODE_SECOND_HALF) {
        s_transition_lands_on_current = false;
        s_play_mode = BADGE_PLAY_MODE_FIRST_HALF_FREEZE;
        schedule_random_for_entry_locked(s_current_entry, s_play_mode);
        ESP_LOGI(TAG, "transition finished, frozen at last frame");
    } else if (s_play_mode == BADGE_PLAY_MODE_FIRST_HALF_FREEZE) {
        /* First_half finished, freeze. Don't loop. */
        ESP_LOGI(TAG, "first_half done, frozen at last frame");
        /* Already frozen - badge_display handles this */
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
