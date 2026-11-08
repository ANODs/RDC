# RDC — Remote Desktop Control

Кроссплатформенный удалённый рабочий стол на Zig: macOS, Windows, Linux, затем Android, iOS и веб. С пользователем говорить по-русски.

## Где что
- `docs/PLAN.md` — цели, архитектура, протокол, стабильность и этапы с критериями готовности.
- Текущая веха — M1 «Первый показ» (`docs/PLAN.md`, раздел 16): хост на macOS, зритель в браузере.

## Сборка
`ZIG=~/Applications/zig-0.17.1/zig`, команды из корня проекта:
- `"$ZIG" build test` — тесты чистых модулей (`src/tests.zig`)
- `"$ZIG" build app -Doptimize=ReleaseSafe` — `zig-out/RDC.app`; `run-app` — собрать и открыть
- `zig-out/bin/rdc host --no-ui` — хост без окна, код и ссылка в журнале `~/Library/Logs/RDC/rdc.log`
- `open -n zig-out/RDC.app --args --web-dir "$PWD/web"` — зритель берётся из `web/` без пересборки; `--update-url URL` — обновления из URL вместо GitHub (для проверки)
- Подпись ad-hoc с требованием `identifier "com.anods.rdc"`: права macOS («Запись экрана», «Универсальный доступ») переживают пересборки и обновления. Если права «застряли» — `tccutil reset ScreenCapture com.anods.rdc` и `tccutil reset Accessibility com.anods.rdc` (запускает пользователь).
- Установленный RDC — `~/Applications/RDC.app`, он обновляется сам; сборки из `zig-out` сами не обновляются.

## Релизы
- Версия — только в `build.zig.zon`, заметки — `docs/releases/<версия>.md`.
- GitHub Actions (`.github/workflows/release.yml`): по тегу `v<версия>` или кнопкой Run workflow — тесты на macOS, Linux и Windows, архивы по ОС (пока macOS; Windows и Linux — с вехой M3), подписанный `latest.json`, релиз. Нужен секрет `RDC_UPDATE_KEY`.
- Локально: `"$ZIG" build release -Doptimize=ReleaseSafe` → `zig-out/release/` (архив, `latest.json`, `latest.json.sig`).
- Ключ подписи обновлений — `~/.config/rdc/update-signing.key` (в git его нет), открытый — `src/core/update_key.zig`. Новый ключ: `zig run tools/release.zig -- keygen <файл>`.

## Как работаем
- Цель — веха из раздела 16: идём к ней без остановок на подтверждение шагов и показываем работающий результат. Перед тем как что-то создавать, проверить, что этого ещё нет.
- Решения пользователя фиксировать одной строкой, без рисков и оговорок.
- Zig 0.17.1, версия закреплена в `build.zig.zon`; на Mac ставится в `~/Applications/zig-0.17.1/`. API `std` (с 0.16 — `std.Io`) и систему сборки 0.17 сверять по исходникам установленного Zig, а не по памяти; проверенные заметки — `docs/zig-0.17-api.md`.
- Репозиторий публичный — `github.com/ANODs/RDC`, ветка `main`. Коммитить — по просьбе пользователя, перечисляя пути, без `git add -A`; пушит пользователь через GitHub Desktop.
- Окончания строк — LF (`.gitattributes`).
