# defect: boot-device-mismatch — гарантированный самоподъём после ребута

## Проблема (факты 2026-11-18, живой ребут evo — STATE llm-lab, history gfctl)

1. podman при `create` фиксирует в OCI-спеке контейнера **снэпшот device-нод**
   каталога `/dev/dri` (проверено: `userdata/config.json` живого контейнера
   содержит `"/dev/dri/card0"`, `"/dev/dri/renderD128"`).
2. Нумерация DRM-нод зависит от race двух инстансов при загрузке:
   `simple-framebuffer` (EFI-fb заглушка) и `amdgpu` (PCI). На che-evo после
   ребута нумерация сменилась `card0 → card1` (by-path:
   `c5:00.0-platform-simple-framebuffer.0-card` — отвязанный fb; настоящая
   карта = `c5:00.0-card` = card1). На che-FAEX1 один инстанс — card0 стабилен.
3. Следствие: старт СТАРОГО контейнера в новом буте падает
   `cannot stat /dev/dri/card0` → `Failed to create container`.
4. `cmd_boot`/`cmd_watchdog` делают `compose up` **без recreate** — упавший
   контейнер не пересоздаётся, юнит systemd `activating → failed`, прод не
   поднимается. Лечение руками (сработало): stop юнита → `podman rm -f -a` →
   start.
5. Доп. симптом: user-юнит стартует раньше драйвера amdgpu (ранний compose up
   видит пустой/полупустой `/dev/dri`).

Слой 2 (maунт по `/dev/dri/by-path/…-render` вместо каталога) — **ОТЛОЖЕН
решением пользователя** (recreate-слой достаточен; возврат к теме — при
втором GPU или частых срабатываниях). tpl-маунты НЕ менять.

## Решение (утверждено пользователем 2026-11-18) — слой 1

В `lib/autostart.sh` (`cmd_boot`, `cmd_watchdog`, общий хелпер):

1. **GPU-ready wait** перед первым `compose up` в `_boot`: цикл опроса
   (интервал ~2 с, таймаут ~60 с — константы вверху файла) до появления
   `/dev/kfd` **и** хотя бы одной `/dev/dri/renderD*`. По таймауту —
   `die` с диагностикой (`ls /dev/dri` в сообщении). В `_watchdog` —
   короткий wait (он минутный по таймеру, дословный повтор сделает watchdog
   долгим): либо тот же хелпер с малым лимитом, либо быстрый single-check
   с отказом-тишины (watchdog просто уйдёт и придёт через минуту) — решает
   developer, зафиксировать в dev-report.
2. **recreate-on-device-mismatch**: если `compose up` завершён, но контейнер
   проекта не в `running` и журнал последнего create/start содержит
   `cannot stat` **или** `Failed to create container` → `podman rm -f`
   контейнеров проекта compose → повторный `compose up`. Максимум две
   попытки суммарно (developer фиксирует точное число в dev-report).
   Определение «падения» — по выводу `podman compose up` (stderr/stdout
   capture) и/или по статусу контейнера после up; точную механику выбирает
   developer, требование одно: мёртвый create не должен оставлять юнит
   failed без попытки recreate.
3. Штатный путь (контейнеры создаются и стартуют) — **без изменений**:
   никаких recreate при нормальном подъёме; дополнительный wait не замедляет
   healthy-подъём заметно (GPU-ready наступает раньше юнита в штатных бутах).

## Файлы

- `lib/autostart.sh` — основной (хелпер + cmd_boot + cmd_watchdog).
- Коммент-контракты функций в стиле репо (Назначение/Параметры/Побочные
  эффекты/Ограничения) — обязательны.

## DoD (код-подэтап)

1. `bash -n` всех изменённых файлов.
2. Shell-приёмки логики: стабы `podman` через PATH-фикстуру — сценарии
   (а) GPU-ready ok → up без recreate; (б) up упал с `cannot stat` → rm +f
   → повторный up → running; (в) GPU-ready таймаут → die с диагностикой;
   (г) watchdog при неготовом GPU — тихий выход. Разместить
   `.dev/tasks/defects/boot-device-mismatch/selfcheck.sh` (идемпотентный,
   exit-код = вердикт) — у hfctl нет локальной батареи tests/, этот скрипт
   и есть машинная проверка код-подэтапа.
3. Дифф минимальный; никакого изменения tpl/маунтов; никакого изменения
   `install`/`use`-путей.
4. dev-report.md: механика распознавания падения, число попыток, выбор
   watchdog-поведения, вывод selfcheck.
5. **Вне подэтапа** (отметить в dev-report): живой ребут-приём на evo —
   отдельное окно по GO пользователя (D6).

## Приёмка кода

tester: прогон selfcheck.sh + `bash -n` + дифф-обзор. reviewer: сверка с
brief (DoD 1–4) и стиль репо. Оркестратор: коммит после APPROVED; пуш —
пользователь. Живой ребут-EXP — по GO.
