// Платформенный слой macOS для RDC: захват (ScreenCaptureKit), кодирование
// (VideoToolbox), ввод (CGEvent) и окно приложения (AppKit). Чистый C ABI —
// Zig объявляет эти функции через `extern fn` в src/platform/macos.zig.
#pragma once
#include <stddef.h>
#include <stdint.h>

#define RDC_CODEC_H264 1  // H.264 Annex B: каждый NAL с префиксом 00 00 00 01
#define RDC_CODEC_JPEG 2  // один кадр JPEG

// Готовый сжатый кадр. Вызывается из потока VideoToolbox: колбэк должен быть
// потокобезопасным и не блокироваться надолго. Данные живут только до возврата.
typedef void (*rdc_frame_cb)(void *ctx, int codec, const uint8_t *data, size_t len,
                             int keyframe, uint64_t ts_us, int width, int height);
typedef void (*rdc_ctx_cb)(void *ctx);
typedef void (*rdc_action_cb)(void *ctx, int action);

#define RDC_ACTION_DISCONNECT_ALL 1
#define RDC_ACTION_NEW_CODE 2
#define RDC_ACTION_CHECK_UPDATE 3
#define RDC_ACTION_INSTALL_UPDATE 4
#define RDC_ACTION_AUTO_UPDATE_ON 5
#define RDC_ACTION_AUTO_UPDATE_OFF 6

// Процесс: SIGPIPE игнорируется, лог пишется в stderr и ~/Library/Logs/RDC/rdc.log.
void rdc_mac_init(void);
void rdc_mac_log(const char *msg);
uint64_t rdc_mac_now_us(void);  // монотонное время

// Разрешения. 1 — есть, 0 — нет. prompt != 0 — показать системный запрос.
int rdc_mac_screen_access(int prompt);
int rdc_mac_input_access(int prompt);
void rdc_mac_open_privacy(int which);  // 0 — «Запись экрана», 1 — «Универсальный доступ»

// Захват главного дисплея. Возвращает 0 или отрицательный код ошибки.
// Вызывать не из главного потока: ждёт запуска потока захвата до 10 с.
int rdc_mac_capture_start(int max_width, int fps, rdc_frame_cb cb, void *ctx);
void rdc_mac_capture_stop(void);
void rdc_mac_set_codecs(int h264, int jpeg);
void rdc_mac_request_keyframe(void);
void rdc_mac_set_bitrate(int bits_per_second);

// Ввод. Координаты нормированы на захватываемый кадр: 0..1.
void rdc_mac_mouse_move(double nx, double ny);
void rdc_mac_mouse_button(int button, int down, double nx, double ny);  // 0 левая, 1 средняя, 2 правая
void rdc_mac_scroll(double dx, double dy);                              // пиксели, как в браузере
void rdc_mac_key(int mac_keycode, int down);
void rdc_mac_release_all(void);
void rdc_mac_cursor_pos(double *nx, double *ny);  // где курсор сейчас, 0..1

// Файл целиком в буфер malloc (освобождать free) или NULL.
void *rdc_mac_read_file(const char *path, size_t *len);

// Сеть и система.
int rdc_mac_lan_ipv4(char *buf, int buflen);
int rdc_mac_computer_name(char *buf, int buflen);

// Обновления.
// HTTP GET (блокирует поток): тело в буфере malloc (освобождать free) или NULL; *status — код HTTP или -1.
void *rdc_mac_http_get(const char *url, size_t max_len, size_t *len, int *status);
// Записать во временную папку обновлений; путь — в path_out.
int rdc_mac_write_temp(const char *name, const void *data, size_t len, char *path_out, int path_len);
// Распаковать архив, проверить, что внутри RDC.app нужной версии с целой подписью,
// заменить им запущенный бандл и перезапуститься. При успехе не возвращается.
int rdc_mac_install_update(const char *zip_path, const char *version);
int rdc_mac_bundle_path(char *buf, int buflen);  // путь к RDC.app или -1, если не из бандла
void rdc_mac_cleanup_old_bundles(void);          // убрать RDC.app.old-* после обновления
int rdc_mac_pref_bool(const char *key, int def);
void rdc_mac_set_pref_bool(const char *key, int value);
// Окно «Настройки»: версия, автообновление, состояние, можно ли обновиться, идёт ли работа.
void rdc_mac_settings_update(const char *version, int auto_update, const char *status, int can_install, int busy);

// Окно приложения. rdc_mac_app_run блокирует главный поток до выхода.
void rdc_mac_app_run(rdc_ctx_cb on_ready, rdc_action_cb on_action, void *ctx);
void rdc_mac_app_set_info(const char *code, const char *link);
void rdc_mac_app_set_status(const char *text);
void rdc_mac_app_set_permissions(int screen_ok, int input_ok);
