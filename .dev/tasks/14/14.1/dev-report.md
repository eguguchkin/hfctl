# Dev report: 14.1 лейаут v2 — клон = стек, bootstrap = первый `hfctl on`, uninstall v2
- Дата: 2026-11-21 / fix round 1 (developed)
- Контракт: `.dev/tasks/14/14.1/task.md` (Design: architect), репо HEAD bc34b97

## What was done (per scope item; порядок фаз и STACK_DIR-механика — 1:1)

1. **STACK_DIR-механика** (`hfctl`): `SELF="$(readlink -f "$0")"` перенесён
   выше; `STACK_DIR="${HFCTL_DIR:-$(dirname "$SELF")}"` — клон = стек,
   запуск из любого подкаталога клона; новые дефолты `MODELS_BASE=$DATA_DIR/models`,
   `STATE_BASE=$DATA_DIR/profiles`, `STOP_MARKER=$DATA_DIR/.hfctl-stopped`,
   новый глобал `DATA_DIR="$STACK_DIR/.data"`; env-крючки HFCTL_DIR/HFCTL_MODELS/HFCTL_STATE
   сохранены. Лок-файл: все 3 упоминания `$STACK_DIR/.hfctl.lock` →
   `$DATA_DIR/.hfctl.lock` (autostart.sh: реклейм + оба up-субшелла);
   `stop_with_marker` теперь `mkdir -p "$DATA_DIR"` (маркер живёт в .data).
   Bench: OUT-дефолт → `$DATA_DIR/bench-runs` + строки-комментарии 15/33/42/571.
2. **install упразднён**: `install.sh` удалён из репо (в `git status` —
   ` D install.sh`, это дельта контракта); роутер: `install)` → `cmd_on "$@"`
   (скрытый алиас в ряду up|down|autostart/noautostart), `on)` теперь тоже
   с `"$@"`; usage-шапка: quickstart `git clone … && cd hfctl && ./hfctl on`,
   install-строки сняты, `on` = «поднять стек (на пустом клоне — bootstrap)»,
   uninstall — v2-формулировка; `cmd_install` → `cmd_bootstrap`
   (переименование тела, хвост-развилка юнитов удалена из функции);
   die-указатели: cmd_use и cmd_doctor («НЕ УСТАНОВЛЕН …») → «сначала
   'hfctl on'».
3. **Bootstrap первого `on`** (`lib/autostart.sh` cmd_on + `lib/commands.sh`
   cmd_bootstrap): при отсутствии `.env` — полный конвейер §Б (RAM-гейт →
   set_models_dir → preflight (apt-пятёрка + gpu_prep 13.2) →
   write_stack_files (каркас `.data` + compose-тройка) → write_env → pull →
   up → apply_profile → force-recreate → health 900 → smoke → check_route),
   **юниты последними** (cmd_on зовёт cmd_autostart после успешного
   bootstrap — Р1: таймер вотчдога не тикает до первого здорового up);
   `--no-autostart` → печать подсказки и возврат (юнитов и подъёма нет);
   на развёрнутом стеке флаги-мутаторы и --no-autostart → die с подсказкой
   (`use` / `hfctl up`), маркер `# fix:bootstrap-guard`. Повтор оборванного
   bootstrap идемпотентен (`.env` = маркер «развернут»; cmd_on передаёт
   bootstrap ОРИГИНАЛ аргументов — парс cmd_on его съедает, флаги надо
   повторять, как в контракте). Маркер STOP_MARKER ветка bootstrap не
   трогает (снимают cmd_autostart/cmd_up).
4. **Uninstall v2** (`lib/commands.sh` cmd_uninstall): экран подтверждения
   v2 → ask → `cmd_off || true` (Ф1-двойной стоп сохранён) → `compose down`
   в субшелле → limits.d `sudo rm -f` (если есть) → purge-флаги:
   `--purge-models` → `rm -rf "$DATA_DIR/models"` (profiles целы),
   `--purge-image` → `podman rmi`. v1-элементы (mv базы моделей во
   временный каталог + `rm -rf "$STACK_DIR"`) удалены — клон не сносится
   никогда; маркер `# fix:uninstall-v2`.
5. **Ф5-conf** (`lib/stack.sh`, `lib/autostart.sh`, оба юнит-tpl):
   `compose()` и `Environment=` юнитов читают tracked-файл клона
   `$STACK_DIR/tpl/etc/hfctl-containers.conf` (условный export сохранён);
   копирование в write_stack_files и cmd_autostart удалено; `sync_tree`
   удалён целиком (stack_files.sh) вместе с вызовами; `ensure_symlink`
   остался (PATH-точка).
6. **.gitignore**: +`.data/`, +`.env` (существующие строки не тронуты).
7. **Миграция** — зафиксирована как документ (SPEC §15 + README-раздел
   «Миграция с лейаута v1»); исполнение на машинах — НЕ выполнялось
   (отдельное окно по GO).
8. **Батарея** (`tests/run_checks.sh`): 40 сохранённых тестов с обновлёнными
   ассертами (harness-глобалы в `.data`; F5 — tpl-путь conf + env-контракт
   по новому месту; мутация containers-conf переведена на env-сценарий —
   копий-conf больше нет) + 9 новых позитивов N1–N9 + 3 мутационные проверки
   новых гвардов (bootstrap-guard → N3, uninstall-v2 → N6,
   uninstall-v1-clone-rm через mutant_sed-вставку `rm -rf $STACK_DIR` → N5).
   FAUX_FULL curl получил живые ответы /health и /v1/chat/completions —
   N-сценарии гоняют полный bootstrap без сети.
9. **SPEC/README/AGENTS той же дельтой**: И1 переформулирован (первый
   `hfctl on`; install.sh упразднён), И3 дополнен («стек = клон —
   автоматичен»), §2 (quickstart, таблица лейаута .data, «вне каталога»,
   warnings), §3 (on-bootstrap, uninstall v2, алиас install), §4 (.env в
   клоне), §14 (conf — tpl-путь клона, производных копий нет), §10 (абзац
   «исторический»), новый §15 «Лейаут v2 и миграция» (контракт процедуры
   §М); README (quickstart, таблица команд, лейаут-таблица, warnings
   `git clean -fdx`/«одна инсталляция на юзера», миграция, bench-runs в
   `.data/bench-runs`, бэкап-путь); AGENTS.md (шапка v2, «Что в репо» без
   install.sh + .gitignore-пункт, правило 5 = git pull + use/off/on).

**Файлы диффа (git status = ровно контракт + артефакты сабстэджа):**
`hfctl`, `install.sh` (удалён), `lib/commands.sh`, `lib/autostart.sh`,
`lib/stack.sh`, `lib/stack_files.sh`, `lib/bench.sh`,
`tpl/systemd/hipfire-compose{,-watchdog}.service.tpl`, `.gitignore`,
`tests/run_checks.sh`, `README.md`, `AGENTS.md`, `.dev/SPEC.md`;
нетронуты mandated-зоны: `tpl/compose/compose.yml|compose.halo.yml`
(F-0.4.7.3), `tpl/etc/*`, `tpl/bench/*`, `lib/{health,models,state,profiles,engine}.sh`,
`.dev/STATE.md`. Машины не трогались. Коммитов нет.

## How it was checked internally

- `bash tests/run_checks.sh` → **`ИТОГО: PASS=52 FAIL=0`**, прогон ×2
  подряд — оба 52/0 (стабильность DoD).
- Состав счёта: 4 AGENTS-четыре + 1 инвентарь маркеров (11 имён, счёт по
  локациям: containers-conf теперь = 1 — export в stack.sh; новые
  bootstrap-guard=2 в autostart.sh, uninstall-v2=1 в commands.sh) + 16 Ф1–Ф5
  + 8 P-A…P-H + 11 мутаций 13.x + **9 новых N1–N9 + 3 новых мутации 14.1**.
- Внутри батареи: `bash -n hfctl lib/*.sh tests/run_checks.sh`;
  `python3 -m py_compile tpl/python/*.py`; bare-вызов → usage rc=1;
  `status --json` на чанковом порту; N1 = happy-path «первый on на faux»
  (конвейер §Б, порядок фаз по журналу: recreate < smoke < check_route <
  systemctl enable < финальный up; юниты с tpl-conf; .env с .data-путями;
  симлинк; маркер снят); N8 = тот же happy-path через алиас `install`
  реальным диспетчером; N7 = запуск из подкаталога клона
  (`cd $TMP/subtree/lib && bash …/hfctl doctor` → STACK_DIR = dirname).
- grep-чистота: README и AGENTS.md не содержат `install` вовсе; SPEC §1–10 —
  только намеренные упоминания (§2 «упразднён», §10 «исторический»,
  §15 алиас); mandated-файлы не менялись (git status).

## Not checked internally (внешний хвост, EXP-окно по GO)

- Живой bootstrap на чистой машине / no-op `on` на FAEX/evo (реальный apt,
  pull 34 GB, health 900, smoke на движке) — EXP-хвост деплой-окна.
- Исполнение миграции §М + reboot-приёмка — отдельное окно по GO
  пользователя (в этом раунде машины не трогались вовсе).
- `git clean -fd` после прогона на живом клоне; `git status --porcelain`
  на свежем клоне с .data — EXP-окно (батарея проверила статику файла).
- Живой up под AppArmor pasta-багом с conf на tpl-пути (§14-EXP прежний).

## Known limitations / assumptions / отклонения от буквы контракта

1. **Счётчик: 52, а не 49** (= 40 сохранённых + 9 новых позитивов N1–N9 +
   3 мутационные проверки новых гвардов). Контракт фиксирует 49 = 40+9
   (девять поименованных позитивов собраны ровно), но DoD одновременно
   требует «мутации новых гвардов ловятся на копиях (bash -n мутанта)»,
   а мутационная конвенция 13.x делает каждую мутацию отдельной строкой
   PASS. Сложить оба требования в 49 нельзя; выбраны явные строки мутаций
   (проверяемые ревью/тестером по имени гварда), а не спрятанные внутрь
   позитивов. Если ревью настаивает на ровно 49 — мутации 14.1 сворачиваются
   в позитив-сценарии (механика готова), реверс тривиален.
2. **N4 «pull-журнал пуст» заменён**: `pull_profile_models` всегда зовёт
   `podman run … hipfire pull` (пропуск существующих файлов делает сам
   pull ВНУТРИ контейнера) — журнал пустым быть не может. Ассерт заменён
   на мигра-механику: maунт `podman run -v` указывает в
   `.data/models/27b`, pre-created файлы целы, `podman pull` (образ)
   пропущен (`podman image exists`).
3. **Watchdog-лог перенесён в `.data`** (`$DATA_DIR/.hfctl-watchdog.log`):
   в перечне путей контракта его нет, но инвариант §М «всё машинное —
   внутри `.data/`» требует: в корне клона он был бы untracked и гибли от
   `git clean -fd`, загрязняя git status. Отмечено как исполнение
   инварианта, а не расширение скоупа.
4. **Парсер cmd_on** — не дословный перенос (в контракте «без изменений»):
   добавлен локал `mut` (факт передачи флага-мутатора) и массив `args`
   (оригинал аргументов для cmd_bootstrap). Причина: guard по семантике
   контракта — «флаги ЗАДАНЫ» (срабатывает и при явном значении = дефолту,
   что сравнение снимков не ловит), а парс cmd_on съедает "$@" — без
   сохранения оригинала повтор оборванного bootstrap не получил бы флаги.
   Тексты die парсера сохранены дословно (включая слово «install» — как в
   контракте).
5. **Die-указатели**: заменены ровно два поименованных (cmd_use, doctor
   «НЕ УСТАНОВЛЕН»). Аналогичные тексты в `cmd_pull` (commands.sh:444) и
   `cmd_bench` (bench.sh:641) сознательно не тронуты — вне перечня
   контракта, `hfctl install` остаётся рабочим скрытым алиасом (текст
   «сначала 'hfctl install'» ведёт на работающую команду). Если ревью
   сочтёт — меняется одной строкой каждое.
6. Мутация `containers-conf` (13.x) переведена на env-сценарий: копий conf
   больше нет, маркер живёт только в export-строке compose() — старая
   пара «маркер → scen_f5_deliver» стала бы пустой проверкой.
7. `cmd_bootstrap` сохраняет ветку разбора `--no-autostart` с неиспользуемым
   локалом — требование «тело cmd_install с ровно тремя изменениями»
   (флаг должен приниматься, юниты ставит cmd_on).

## Out-of-scope proposals (идеи, не код)

- `doctor`: обновить оставшиеся подсказки «install поставит/напишет» →
  «on (bootstrap) поставит»; второй-клон-детект (D11-косметика).
- `cmd_bootstrap`: убрать мёртвый парс `--no-autostart` после стабилизации
  (косметика, ломает «ровно три изменения»).
- llm-lab-хвост окна миграции: bench_arms/slot_ab/prompts-маунт на
  `.data/benchmarks/prompts` (Р4 — оркестратору llm-lab).
- Каркас `.data/logs` — только при появлении файлового логера (В1).
