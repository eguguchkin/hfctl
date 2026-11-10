# Этап 8 — рефакторинг: разложение hfctl на `lib/` + шаблоны в `tpl/` + дистрибуция

Статус: **brief (orchestrator), 2026-11-10**. Design/Test strategy — architect;
далее в этом же файле append-only секции: Dev report → Test report → Review.
Принцип этапа: **поведение сохраняется байт-в-байт**; меняется только
раскладка файлов и способ установки.

## Brief (orchestrator)

### Goal (статизируемый, проверяемый)

Разложить однофайловый `hfctl` (1661 строк) на дерево:
- `hfctl` — диспетчер: header/usage, env-конфигурация, `source`'ы lib, dispatch;
- `lib/*.sh` — логические части (профили, state, модели, файлы стека, конфиг
  движка, health/smoke, команды, bench, автозапуск);
- `tpl/` — ВСЕ инлайн-шаблоны без исключений: compose-yaml, systemd-юниты,
  `.env`, **весь** python (включая однострочники), bench-фикстура;
- `install.sh` — дистрибуция целого дерева; curl-режим и «одной строкой»
  УДАЛЕНЫ (решение пользователя 2026-11-10); единственный путь —
  `git clone` + `./install.sh`.

### DoD

Внутренние (контейнер разработки):

- [ ] 1. Раскладка: `hfctl` — только диспетчер (config + source + dispatch,
      ≤ ~450 строк); `lib/*.sh` — по одной ответственности на файл; `tpl/` —
      все шаблоны. В `hfctl` и `lib/`: **0** вхождений `python3 -c`,
      **0** heredoc с compose/unit/.env, **0** инлайн-фикстуры.
      (awk-однострочники-выражения могут оставаться в коде; многострочный
      awk — в `tpl/awk/`.)
- [ ] 2. `bash -n` — чисто для всех shell-файлов. `shellcheck`: нет НОВЫХ
      предупреждений против базлайна старым скриптом (базлайн зафиксирован
      в dev-report до рефакторинга).
- [ ] 3. **Golden-file parity**: файлы стека, которые генерируют старый и
      новый hfctl в sandboxed HOME (HFCTL_DIR), — байт-в-байт идентичны:
      `compose.yml`, `compose.halo.yml`, `compose.local.yml` (все 4
      комбинации: draft ×/- × prompts-каталог ×/×), `.env`, 3 systemd-юнита.
- [ ] 4. CLI-поверхность байт-в-байт: `usage` (запуск без аргументов),
      неизвестная команда (rc=1 + текст), `status`/`doctor`/`models`
      в состоянии «стек не установлен» — diff старый vs новый = пусто.
- [ ] 5. Парность чистых функций: `profile_field`, `resolve_profile`,
      `model_set`, `profile_avail_list`, `bench_med` (на фиксированном
      runs.tsv), md5 bench-фикстуры = `253c7ac50857fe6d0e10fb0d2c5e35c0`
      (репо-копия `benchmarks/prompts/` И tpl-копия).
- [ ] 6. `install.sh`: единственный источник — дерево рядом с собой
      (git clone); копирует `hfctl` + `lib/` + `tpl/` в `~/hipfire/`;
      симлинк в `~/.local/bin` (включая замену реального файла); PATH-подсказка;
      идемпотентен; запуск вне дерева — внятная ошибка. `HFCTL_RAW_URL`
      и curl-ветка — удалены.
- [ ] 7. Bench-python вынесен: `ttft.py` + bench-отчёт — parity вывода
      (report/artifact/compare) против закреплённого runs.tsv; `ttft.py`
      прогонен против локального fake-SSE (тест-скрипт в dev-report).
- [ ] 8. README: quickstart только git clone (строчка curl удалена),
      «Как это устроено» — дерево `~/hipfire/` теперь включает `lib/`, `tpl/`.
- [ ] 9. Спецификация: `spec/hfctl.md` §2 поправлен (hfctl — НЕ однофайловый;
      дистрибуция = git clone; curl убран), `spec/plan.md` — этап 8,
      `spec/state.md` — статус этапа 8.

Внешние (реальные машины; **запуск — только после предупреждения
пользователя**, машины используются — пользователь переключит модели):

- [ ] 10. che-evo: обновление деревом через `install.sh` (сервер healthy до
      и после) → **полный цикл**: `use 27b-slots` → `use 27b-single`
      (use↔use), `off` → `on`, ребут → канонический профиль поднялся сам,
      healthy + smoke. Итог: 27b-single healthy.
- [ ] 11. che-FAEX1 (лёгкое): обновление деревом через `install.sh` →
      flash-multi healthy + smoke. Без остановки.
- [ ] 12. hflab: AGENTS.md (hfctl-секция: дерево, дистрибуция) и STATE.md
      обновлены; логи/артефакты приёмки — в hflab `.local-analysis/`
      (в hfctl-репо — никаких имён хостов/IP/логов, правило 7).

### Спецификация (ссылки)

- `spec/hfctl.md` §2 (дистрибуция — правится этим этапом), §3 (карта команд —
  НЕ меняется), §5 (профили — не трогаем).
- `spec/plan.md` — этап 8 (добавляется).
- `AGENTS.md` правила: 1 (state.md), 5 (обновление на живой машине — только
  install.sh — теперь синхронизация дерева), 6 (полный цикл), 7 (ничего
  хостового в репо).

### Ограничения и известные грабли

- `set -euo pipefail` + `grep -q` без совпадения убивает скрипт — все
  `|| true`-комментарии («ВАЖНО») сохранять при переносе (check_route,
  bench_route, watchdog).
- `compose.yml` содержит СОБСТВЕННЫЕ переменные compose
  (`${HIPFIRE_MODEL:-...}`) — статичный файл, копировать цело, НЕ
  прогонять через shell-экспансию/envsubst.
- Динамика compose.local.yml/.env/юнитов сейчас — bash-экспансия heredoc
  (EOF без кавычек). После выноса в tpl — результат обязан совпасть
  байт-в-байт во всех комбинациях (см. DoD 3). Механизм подстановки —
  решает architect (ограничение: без внешних зависимостей, которых нет на
  голой машине; envsubst в дефолтном Ubuntu нет).
- `usage()` = `sed -n '2,20p' "$0"` — строки 2..20 диспетчера остаются
  usage-текстом, вывод идентичен.
- Self-copy `write_stack_files`/`cmd_autostart`: семантика «копируем только
  при отсутствии» (AGENTS правило 5 — install.sh = путь обновления,
  повторная установка из старого клона НЕ должна откатить свежий стек) —
  теперь это дерево, не файл.
- Юниты ссылаются на `$STACK_DIR/hfctl` — путь НЕ меняется.
- Контейнер разработки: alpine-musl, без `/dev/kfd`, без systemd user —
  sandbox-тесты идут через doctor/status/чистые функции/golden-файлы,
  не через install.
- bench-фикстура: байты не менять (md5-гейт); «НЕ редактировать» — сохранить.
- «Без исключений» (решение пользователя): весь python — в `tpl/python/`;
  дублирующаяся логика (health-проверка в wait_health и cmd_bench) — общий
  файл.
- Машины в работе: внешний шаг 10–11 — ТОЛЬКО после предупреждения
  пользователя (он переключит модели) и его подтверждения.

### Открытые вопросы

Блокирующих нет (решения пользователя получены 2026-11-10). Architect может
добавить — эскалируются пользователю до начала кода.

---

## Design (architect)

Design: architect, 2026-11-10. Числа строк — текущего `hfctl` в репо (1661
строк). Повторный источник истины: brief выше + `spec/hfctl.md` §2 (правится).

### Scope / out-of-scope

В объёме: раскладка `hfctl` → dispatcher + `lib/*.sh` + `tpl/`; дистрибуция
через `install.sh` (только git-клон); README; spec §2 + план + state.md.
**Не трогаем** (поведение байт-в-байт): конфиг-наборы профилей и их значения,
CLI-грамматику (spec §3), RAM-гейты, сеты моделей, state-каталоги (этап 7),
bench-сценарии и формат артефакта, smoke-промпты, тег образа, байты
`benchmarks/prompts/`, порядок «recreate → wait_health → smoke», exit-коды 42.

### 1 · Раскладка файлов

#### Диспетчер `hfctl` (цель ≤ ~450 строк)

Остается в диспетчере и только это:
- `#!/usr/bin/env bash` (L1);
- usage-блок = текущие **L2..20** (текст `usage()` обязан остаться
  идентичным; допустима только правка формулировок «как получить» в строках
  3–7 — она видна в выводе и проверяется DoD 4; всё остальное L2..20
  — дословно);
- `set -euo pipefail` (L32);
- env-конфигурация **L34..L54** дословно (IMAGE, STACK_DIR, MODELS_BASE,
  MODELS_DIR, STATE_BASE, PORT, BIND, DRAFT_FILE, SLOTS, CONTAINER,
  UNIT_NAME, STOP_MARKER, SELF, MAX_SEQ, MEMLOCK) + **одна новая строка**:
  `LIB_DIR="$(cd "$(dirname "$SELF")" && pwd)/lib"` и
  `TPL_DIR="$(cd "$(dirname "$SELF")" && pwd)/tpl"` (дерево = рядом с
  диспетчером; env-переопределений для LIB_DIR/TPL_DIR не вводить —
  sandbox покрывается HFCTL_DIR/HOME, см. Test strategy);
- общие хелперы: `log`/`warn`/`die` (L154–156), `ASSUME_YES`/`ask`
  (L203–209), `isint` (L678);
- блок `source` (порядок ниже), затем `usage()` (L1633–1635, без изменений —
  `sed -n '2,20p' "$0"` продолжает работать на диспетчере) и dispatch-блок
  `cmd="${1:-}"` + `case` **L1637..1661** дословно (текст «неизвестная
  команда» — byte-в-byte).

#### `lib/*.sh` — 10 файлов, по одной ответственности

| Файл | Что переезжает (строки текущего hfctl) |
|---|---|
| `lib/profiles.sh` | константы профилей L56–63; `profile_field`, `resolve_profile` L67–80; `ram_pool_gib`, `profile_gate`, `profile_avail_list` L82–112 |
| `lib/stack.sh` | `CF`, `compose`, `env_val`, `cur_profile`, `cur_model` L158–162; `preflight` L164–201 |
| `lib/state.sh` | `state_dir`, `migrate_state` L114–134; `model_set`, `set_models_dir`, `migrate_models` L136–152 |
| `lib/stack_files.sh` | `ensure_symlink` L212–216; `write_stack_files` L217–321 (перезаписан: копирование статичных tpl + render, п. 2); `write_env` L324–339 (через render); новая функция `render_tpl` (п. 2); новая функция `sync_tree` (п. 3) |
| `lib/engine.sh` | `cfgset` L342–344; `apply_profile` L345–390 (комментарии «ВАЖНО» дословно) |
| `lib/health.sh` | `wait_health` L392–415 (python → `tpl/python/health_ok.py`); `smoke` L417–429 (python → `smoke_resp.py`); `check_route` L431–456 (python → `health_mode.py`, «ВАЖНО»-комментарии сохранить) |
| `lib/models.sh` | `pull_model` L458–463; `pull_profile_models` L465–473 |
| `lib/commands.sh` | `cmd_install` L476–542; `cmd_use` L544–594; `cmd_status` L617–648 (python → `status_json.py`/`status_hline.py`); `cmd_logs` L650–662; `gpu_temp` L664–677; `cmd_watch` L680–762 (python → `watch_stats.py`); `cmd_mode` L765–769; `cmd_doctor` L872–924; `cmd_models` L926–946; `cmd_pull` L948–962; `cmd_uninstall` L1595–1631 |
| `lib/autostart.sh` | `cmd_on` L599; `cmd_off` L600–615; `cmd_up`, `cmd_down` L596–597; `cmd_autostart` L771–831 (юниты → render из tpl, self-copy → `sync_tree` п. 3); `hf_up_locked` L835–839; `cmd_boot` L843–859; `cmd_watchdog` L862–870 |
| `lib/bench.sh` | всё bench L964–1002, L1004–1262, L1447–1593: `BENCH_FIXTURE_MD5`, `bench_help`, `bench_route`, `bench_slots` (→ python), `bench_payload` (→ python), `bench_req` (→ python), `bench_tau`, `bench_med` (→ `tpl/awk/bench_med.awk`), `bench_solo`, `bench_ttft`, `bench_prefill` (→ python), `bench_longgen`, `bench_parallel` (→ python), `bench_hol`, `cmd_bench` (hol-note awk → `tpl/awk/hol_note.awk`; фикстура читается из `"$TPL_DIR/bench/merge_sort_thinking_off.txt"`, md5-гейт и текст WARN сохраняются); `bench_write_py` L1264–1445 **удаляется** (python живёт в `tpl/python/` всегда, а не «пишется в BENCH_TMP») |

Правила для всех lib-файлов:
- только определения функций + инициализации переменных, использующих
  переменные диспетчера; **никаких вызовов функций на верхнем уровне**
  (иначе `set -u` упадёт до source всех зависимостей);
- все «ВАЖНО»-комментарии (set -e/pipefail/grep) переносить дословно —
  грабли из brief;
- вызовы python: единый стиль `python3 "$TPL_DIR/python/<имя>.py" …`
  (arg/stdin/rc-контракты — п. 4).

#### Целевой порядок source'ов (зависимости)

```bash
source "$LIB_DIR/profiles.sh"     # table+resolve+gates (нужны только env-константы)
source "$LIB_DIR/stack.sh"        # CF/compose/env_val/cur_profile/preflight (нужны log/warn/die)
source "$LIB_DIR/state.sh"        # state-каталоги + сеты моделей
source "$LIB_DIR/stack_files.sh"  # render_tpl, sync_tree, write_stack_files, write_env
source "$LIB_DIR/engine.sh"       # cfgset/apply_profile
source "$LIB_DIR/health.sh"       # wait_health/smoke/check_route
source "$LIB_DIR/models.sh"       # pull*
source "$LIB_DIR/commands.sh"     # install/use/status/…/uninstall
source "$LIB_DIR/autostart.sh"    # on/off/up/down/_boot/_watchdog
source "$LIB_DIR/bench.sh"        # bench (использует всё выше)
```

Зависимости между функциями выполняются в рантайме (lazy), порядок source
фактически свободен; приведённый порядок = «от данных к командам» и
используется в dispatch-беспрепятственно. Любое нарушение порядка
(функция, вызываемая при source) — дефект, ловится `bash -n` + sandbox.

#### Дерево `tpl/`

```
tpl/
├── compose/
│   ├── compose.yml                    # СТАТИЧНЫЙ: тело heredoc COMPOSE, L230–285, дословно
│   ├── compose.halo.yml               # СТАТИЧНЫЙ: тело heredoc HALO, L287–303, дословно
│   └── compose.local.yml.tpl          # плейсхолдеры __LOCAL_PROMPTS__, __LOCAL_DRAFT_ENV__
├── env/
│   └── env.tpl                        # __PROFILE__ __MODEL__ __PORT__ __BIND__
│                                      # __MODELS_DIR__ __STATE_DIR__ __IMAGE__
├── systemd/
│   ├── hipfire-compose.service.tpl            # __STACK_DIR__ __CF__ __PODMAN_BIN__
│   ├── hipfire-compose-watchdog.service.tpl   # __STACK_DIR__
│   └── hipfire-compose-watchdog.timer.tpl     # без плейсхолдеров (однородность схемы)
├── python/                            # контракты — п. 4; имена:
│   ├── health_ok.py  smoke_resp.py  health_mode.py  status_json.py
│   ├── status_hline.py  watch_stats.py  bench_slots.py  bench_payload.py
│   ├── bench_req.py  prefill_gen.py  par_usage.py  ttft.py  bench_report.py
├── awk/
│   ├── bench_med.awk                  # медианная часть bench_med (L1176)
│   └── hol_note.awk                   # note для HOL (L1546–1548)
└── bench/
    └── merge_sort_thinking_off.txt    # БЫТ-В-БЫТ = benchmarks/prompts/… (md5 253c7ac50857fe6d0e10fb0d2c5e35c0)
```

`benchmarks/prompts/` в репо остаётся (канон для hflab-скриптов);
`tpl/bench/` — shipped-копия. Тест DoD 5 проверяет md5 обеих копий и
с их эталона (гарантия, что дубли не рассинхронизировались).

Требование к всем `.tpl`: ровно один trailing newline в конце файла
(heredoc-вывод текущего кода и `printf '%s\n'` дают ровно один —
байт-парность зависит от этого).

### 2 · Механизм рендера tpl

**Формат плейсхолдеров**: `__NAME__` (заглавные, латиница/цифры/подчёрки-
вания, двойное подчёркивание с двух сторон). Обоснование: никогда не
пересекается с `${VAR:-def}` compose и с `$VAR` bash; литерально
поискается grep'ом; легко отличить от контента юнитов.

**Реализация — чистый bash, без sed/awk/envsubst** (выбор сознательный:
значение-замена может быть многострочным — блок `volumes:` в
compose.local.yml — и содержит `/`; bash-подстановка `${var//lit/val}`
обрабатывает литеральный паттерн без regex-специалов, newlines в значении
работают как есть, и поведение идентично на busybox/GNU — dev-контейнер
alpine-musl, цель Ubuntu):

```bash
render_tpl() {  # render_tpl <file.tpl> <out> <NAME=value> ...
  local tpl out; tpl="$(cat "$1")"; out="$2"; shift 2
  local kv name value
  # имена передавать в порядке убывания длины (длинное раньше короткого —
  # защита от вложенных совпадений; наборы фиксированы на вызывающем)
  for kv in "$@"; do
    name="${kv%%=*}"; value="${kv#*=}"
    tpl="${tpl//__${name}__/${value}}"
  done
  if printf '%s' "$tpl" | grep -qE '__[A-Z0-9_]+__'; then
    die "нераскрытые плейсхолдеры в шаблоне $1"
  fi
  printf '%s\n' "$tpl" > "$out"
}
```

- `tpl="$(cat …)"` срезает trailing newline; `printf '%s\n'` возвращает
  ровно один — вместе с требованием к `.tpl` это даёт byte-парность.
- grep в `if`-условии — безопасен под `set -e` (графля из brief не
  применима, но форму `if …; then` сохранить).
- Вызовы (значения берутся из уже рассчитанных переменных, как сейчас):
  - `.env`: `render_tpl "$TPL_DIR/env/env.tpl" "$STACK_DIR/.env"
    PROFILE="$prof" MODEL="$model" PORT="$PORT" BIND="$BIND"
    MODELS_DIR="$MODELS_DIR" STATE_DIR="$STATE_BASE/$prof" IMAGE="$IMAGE"`
    (текущий write_env L326–338; строки `HIPFIRE_UI=0`, `HIPFIRE_SERVE_ARGS=`,
    `COMPOSE_FILE=…` — литерально в env.tpl);
  - `compose.local.yml`: `LOCAL_PROMPTS` ∈ {`""`, `\n    volumes:\n      - ./benchmarks/prompts:/prompts:ro`}
    и `LOCAL_DRAFT_ENV` ∈ {`""`, `      HIPFIRE_DFLASH_DRAFT: $DRAFT_FILE`}
    — точные текущие значения из L309–314; шаблон:
    ```
    services:
      hipfire:__LOCAL_PROMPTS__
        environment:
    __LOCAL_DRAFT_ENV__
    ```
    (п. о последнем плейсхолдеру — инлайн в конце строки; при `""` строка
    `    hipfire:` остаётся как есть, при не-`""` значение начинается с
    `\n` и даёт две строки — идентично текущей bash-экспансии L317);
  - юниты: `STACK_DIR="$STACK_DIR" CF="${CF[*]}" PODMAN_BIN="$bin"`
    (service), `STACK_DIR="$STACK_DIR"` (watchdog service), timer —
    `install -m 0644` как статичный (плейсхолдеров нет).
- **Статичные** `compose.yml`/`compose.halo.yml`: `install -m 0644
  "$TPL_DIR/compose/<file>" "$STACK_DIR/<file>"` — обычная копия, никаких
  подстановок и экспансий: `${HIPFIRE_MODEL:-…}` и пр. — это переменные
  compose, они должны дожить до `podman compose` (графля из brief №2).
- **Гарантия байт-парности** — не «надежда», а проверка: golden-file diff
  (DoD 3) по всем 4 комбинациям compose.local.yml + .env + 3 юнита,
  плюс автоматический «остаточный плейсхолдер»-проверка в render_tpl
  (die при `__X__` в выводе) и grep `__` в golden-скрипте.

### 3 · Self-copy в мире дерева

- Новая функция `sync_tree` в `lib/stack_files.sh` (используется
  `write_stack_files` и `cmd_autostart` — два текущих места, L223–225 и
  L776–778):

```
sync_tree():
  [ -f "$STACK_DIR/hfctl" ] && return 0      # в стеке уже есть — НЕ трогать
  [ "$SELF" = "$STACK_DIR/hfctl" ] && return 0   # запускаемся прямо из стека (юниты)
  mkdir -p "$STACK_DIR"
  install -m 0755 "$SELF" "$STACK_DIR/hfctl"
  rm -rf "$STACK_DIR/lib" "$STACK_DIR/tpl"
  cp -a "$(dirname "$SELF")/lib"  "$STACK_DIR/lib"
  cp -a "$(dirname "$SELF")/tpl"  "$STACK_DIR/tpl"
```

- Семантика «копируем только при отсутствии» (AGENTS правило 5) расширяется
  на дерево маркером-файлом `$STACK_DIR/hfctl`: **повторная установка из
  старого клона не откатывает свежий стек** — диспетчер в стеке есть →
  дерево не синхронизируется. Обновление = только `install.sh` из
  свежего клона.
- `install.sh` синхронизирует в стек ровно три элемента: `hfctl`, `lib/`,
  `tpl/` (механика: `rm -rf "$STACK_DIR/{hfctl,lib,tpl}"` + `cp -a` из
  каталога скрипта + `chmod 0755` диспетчера). Всё остальное в `$STACK_DIR`
  (models/, profiles/, .env, compose*, benchmarks/) install.sh НЕ трогает.
  Повторный `install.sh` из того же клона = идемпотентная перезапись
  тех же трёх элементов (md5-равные). Повторный из СВЕЖЕГО клона =
  обновление (реализация AGENTS правила 5 для дерева).
- Запуск `install.sh` вне дерева (рядом нет `hfctl` + `lib/` + `tpl/`):
  внятная ошибка «запускай из клона репозитория hfctl: cd hfctl &&
  ./install.sh», rc 1. Curl-ветка и `HFCTL_RAW_URL` — удалены. Env-пере-
  определения `HFCTL_DIR`/`HFCTL_BIN_DIR` сохраняются (sandbox-тесты).
- Путь юнитов `$STACK_DIR/hfctl` не меняется (brief); `SELF ==
  $STACK_DIR/hfctl` при запуске из юнита — второй early-return в sync_tree.

### 4 · Python: выносы и контракты

Все `python3 -c` (12 вхождений) и оба «пишущихся в BENCH_TMP» скрипта
переезжают в `tpl/python/`. Единый стиль вызова:
`python3 "$TPL_DIR/python/<имя>.py"`, stdin/argv/rc ниже. Контракт =
поведение текущего инлайн-кода (включая rc и вывод в stderr).

| # | Место сейчас | Файл | Контракт (argv / stdin / stdout / rc) |
|---|---|---|---|
| 1 | wait_health L398–400 | `health_ok.py` | stdin = JSON `/health`; stdout: пусто; rc 0 ⇔ status=="ok" и model не пусто и loading_model не задан; иначе rc 1. **Дубль** с #8 — один общий файл (brief) |
| 2 | cmd_bench health L1498–1500 | (то же) `health_ok.py` | идентично #1 |
| 3 | smoke L425 | `smoke_resp.py` | stdin = JSON ответа /v1; stdout: `ответ: <первые 60 символов>` или `ответ: (ПУСТО)`; rc 0 ⇔ content непуст |
| 4 | check_route 27b-slots L452 | `health_mode.py` | stdin = JSON `/health`; stdout: `capabilities.mode`; rc 0; при parse-ошибке rc≠0 (вызывающий сохраняет `|| echo '?'`) |
| 5 | status --json L625–634 | `status_json.py` | env: PROFILE/AUTO/WDOG (проход по env сохранить); stdin = body `/health`; stdout: JSON-объект как сейчас; rc 0 |
| 6 | status hline L638–642 | `status_hline.py` | stdin = body `/health`; stdout: строка `health: … | модель: … | режим: …`; rc 0; parse-ошибка → rc≠0 (вызывающий `|| echo "health: сервер не отвечает"`) |
| 7 | watch /stats L716–721 | `watch_stats.py` | stdin = JSON `/stats`; stdout: `q served recent retries` (пробелом; None → `-`); rc 0; parse-ошибка → rc 0 с `-` (текущий `except: d={}`); вызывающий `|| true` сохранить |
| 8 | bench_slots L1019–1023 | `bench_slots.py` | stdin = JSON `/health`; stdout: `capabilities.multi_slot_slots` (пусто если нет); rc 0/≠0; вызывающий `${s:-$SLOTS}` |
| 9 | bench_payload L1028–1036 | `bench_payload.py` | argv: out.json, content_file, max_tokens, stream(0\|1), model; создаёт payload; rc 0 |
| 10 | bench_req L1051–1062 | `bench_req.py` | argv: resp_file; stdin: wall (строка `%.3f` от awk); stdout: `wall prompt_tokens completion_tokens` (pt=0 если None); rc 0, 3 = JSON не распарсился, 4 = usage/completion отсутствует — вызывающий логику `rc` сохранить дословно (L1041–1063) |
| 11 | prefill-генератор L1116–1121 | `prefill_gen.py` | argv: src_content, out_content; пишет `(c+"\n")×n`, `n=(100000*4+len(c)-1)//len(c)`; rc 0 |
| 12 | parallel usage L1199–1205 | `par_usage.py` | argv: resp_file; stdout: completion_tokens или пусто; rc 0; parse-ошибка → rc 3, stdout пусто (вызывающий `|| true`) |
| 13 | ttft.py L1265–1306 | `ttft.py` | argv: url, payload_file; stdout: `null` \| `ERR <reason>` \| `%.0f` (мс до первого non-empty content chunk); rc 0 во всех случаях (текущий sys.exit(0) даже при connection error — сохранить); timeout=120 |
| 14 | bench_py.py L1308–1444 | `bench_report.py` | argv: `report`\|`artifact`\|`compare [basefile]`; env: B_RUNS, B_TS, B_PROFILE, B_MODEL, B_ROUTE, B_IMAGE, B_MD5, B_FULL, B_NOTE_* (report), B_ARTIFACT (compare); stdout как сейчас; rc 0; ошибки open/json — как сейчас (необработанные → rc≠0, bash под set -e упадёт — идентично текущему) |

После выноса `bench_write_py` исчезает; `bench_ttft` вызывает
`python3 "$TPL_DIR/python/ttft.py"` напрямую (BENCH_TMP несёт только
runs/ответы); `cmd_bench` вызывает `bench_report.py` по трём subcommand'ам
(L1570–1585). В `hfctl` и `lib/` вхождений `python3 -c` = 0 (DoD 1).

**awk — правило подтверждено с уточнением**: однострочные выражения
(`awk … 'BEGIN{…}'`, однострочные фильтры, напр. L84, L1174-фильтр,
L1086, L1130–1133, L1189, L1194, L1215, L1223–1224, L876) — остаются в
коде: это самозамыкающие `BEGIN`-вычисления по одним–двум переменным,
вынос в файл добавил бы `-f`+`-v`-обвязку без выигрыша, а DoD 1 их
разрешает. Многострочные программы (2 штуки) — в `tpl/awk/`:
- `bench_med.awk` — только медианная часть (L1176, программа с `END`;
  однострочный фильтр-предварительник L1174 остаётся в коде, пайп
  `| sort -g | awk -F'\t' -v s -v c -f "$TPL_DIR/awk/bench_med.awk"
  "$BENCH_TMP/runs.tsv"`);
- `hol_note.awk` — L1546–1548 (`awk -v m -v r -f "$TPL_DIR/awk/hol_note.awk"`).
Обоснование критерия: «многострочность» = программа, где читаемость
теряется в одной строке; обе — с блочной логикой (END/мульти-printf),
и только они не входят в DoD-проверку «awk-однострочники в коде».

### 5 · Коммит-план этапа

Серия из 2 коммитов (план.md допускает «серия коммитов одного этапа»):

1. **C1 (код)**: `hfctl` (диспетчер) + `lib/*.sh` + `tpl/**` + `install.sh`
   (clone-only, без curl) + `README.md` (quickstart без curl-строки,
   «Как это устроено» с lib/, tpl/) + `spec/hfctl.md` §2 + `spec/plan.md`
   (этап 8) + `spec/state.md` (строка этапа 8 «в работе» + строка
   журнала) — закрываются внутренние DoD 1–9. В этом же коммите —
   baseline shellcheck и результаты golden/CLI-парности фиксируются
   в dev-report (артефакт роли, не коммит).
2. **C2 (статус после внешней приёмки DoD 10–12)**: `spec/state.md`
   «этап 8 принят» + журнал; доказательства (логи) — в hflab
   `.local-analysis/`, в репо не попадают (правило 7).

Статус state.md меняется дважды — оба изменения внутри коммитов
этапа (правило 1: коммит, меняющий статус, обновляет state.md в себе).

### 6 · Риски и rollback

- **Rollback = git revert C1(+C2)** → однофайловый hfctl прежнего
  коммита. На живой машине: клон/выкачка репо на pre-этап 8 →
  `./install.sh` (старый bootstrap перезапишет `$STACK_DIR/hfctl`
  однофайловым). Новые `lib/`/`tpl/` в стеке окажутся осиротевшими,
  но инертными (старый бинарь их не читает) — оставляем (зачистка —
  `hfctl uninstall` или руками). Контейнер/модели/state не затрагивает
  этап по содержимому → recreate после rollback НЕ обязателен для
  корректности; однако по AGENTS правилу 5 обновление бинаря проходит
  install.sh + полный цикл (use↔use) — выполняем как приёмку rollback.
- **Риск: байт-парность render** — покрывается golden-матрицей DoD 3
  (8+2 файла) + die на остаточных плейсхолдерах + CLI-parity DoD 4.
- **Риск: busybox (dev) vs GNU (цель)** — генерирующий путь не
  использует sed/awk-семантику (render = чистый bash; статичные —
  cp); внешние утилиты на этом пути: install/cp, md5sum. Зависимости
  от окружения сводятся к bash 5 (и на alpine, и на Ubuntu).
- **Риск: shellcheck baseline** — старый файл vs набор файлов:
  сравнивать мультимножество кодов SC (не номера строк); новые
  findings = FAIL (DoD 2). Если появятся findings только на строках
  `source "$LIB_DIR/…"` (динамический путь) — зафиксировать в
  dev-report как ожидаемое исключение с обоснованием.
- **Риск: расхождение дублей фикстуры** (benchmarks/prompts vs tpl/bench)
  — md5-гейт в тесте DoD 5 + WARN в bench на живой машине (существующий).
- **Риск: установленный стек «до этапа 8»** — после C1+update install.sh
  tpl/ появляется; обратная несовместимость отсутствует (старый стек
  продолжает работать старым бинарем, пока install.sh не перезапишет).

---

## Test strategy

**Sandbox** (dev-контейнер alpine-musl, без /dev/kfd, systemd, podman):
корень `/tmp/opencode/hfctl-stage8/` (далее `$S`): `$S/home` (HOME),
`$S/bin` (BIN), `$S/hipfire` (HFCTL_DIR), `$S/tree` (копия репо-дерева).
Env-переопределения для sandbox: `HOME=$S/home HFCTL_DIR=$S/hipfire
HFCTL_BIN_DIR=$S/bin` — уже существуют в install.sh (L13–14) и в
hfctl (L36–37); новые не нужны. **Все команды, не требующие GPU/systemd,
проверяются внутри; install и GPU-зависимое — только внешний шаг
(DoD 10–11).**

Общее: harness-скрипты живут в `$S/test/*.sh`, их текст + вывод — в
dev-report (артефакт роли). Старый бинарь для сравнения: `git show
HEAD:hfctl > $S/old-hfctl` (HEAD = pre-рефакторинг).

| DoD | Внутренняя проверка (команда / скрипт) | Внешний (что доказывает → hflab-артефакт) |
|---|---|---|
| 1 раскладка, 0 python3 -c, 0 compose/unit/.env-heredoc, 0 фикстур | `grep -c 'python3 -c' hfctl lib/*.sh` (все 0); `grep -nE 'cat *> *(\"\$?STACK_DIR/(compose|\.env)\|.*\.(service|timer)\"' hfctl lib/*.sh` (0); `grep -rn 'FIXTURE_EOF' hfctl lib/` (0); `wc -l hfctl` (≤ ~450) | — (внешне проявляется в DoD 10: install из дерева работает) |
| 2 bash -n + shellcheck baseline | **До** рефакторинга (в dev-report, фиксация baseline): `shellcheck hfctl install.sh > $S/sc_baseline.txt; echo rc=$?` (rc и список SC-кодов); `bash -n hfctl install.sh`. **После**: `for f in hfctl lib/*.sh install.sh; do bash -n $f; done`; `shellcheck hfctl lib/*.sh install.sh > $S/sc_after.txt`; сравнение: `grep -oE 'SC[0-9]+' $S/sc_baseline.txt \| sort \| uniq -c` vs аналогично для after — новые коды/рост = FAIL (исключения — см. Design п. 6) | — |
| 3 golden-file parity | `$S/test/golden_stack.sh`: для старого и нового: извлечь функцию-часть (`sed` до строки `^cmd="\${1:-}"` — инвариантный маркер обеих версий) в `$S/{old,new}-funcs.sh`; в bash-сессии с `HOME=$S/g/{old,new}/home HFCTL_DIR=$S/g/{old,new}/hipfire PATH=$S/stub:$PATH` (stub'ы `podman`, `systemctl`, `loginctl`, `sudo` — скрипты-заглушки, идентичные для обоих): `source funcs.sh; mkdir -p $STACK_DIR; touch $STACK_DIR/hfctl` (обход self-copy); 4 комбинации: {профиль 27b-single (draft yes) × каталог prompts создан/нет} ∪ {flash-multi (draft −) × prompts создан/нет} → `write_stack_files; write_env <prof> <model>`; для юнитов — `cmd_autostart`. `cmp` попарно: `compose.yml`, `compose.halo.yml`, `compose.local.yml` (×4), `.env` (×2), 3 юнита. Плюс `grep -rE '__[A-Z0-9_]+__'` по всем = 0 | — (на живых машинах генерация тех же файлов — косвенная проверка: DoD 10 recreate не меняет compose) |
| 4 CLI-поверхность | `$S/test/cli_parity.sh`: для `{old-hfctl, tree/hfctl}` при «стек не установлен» (свежий HFCTL_DIR, stub'ы в PATH): `hfctl` (usage), `hfctl неттакойкоманды` (rc + stderr), `hfctl status`, `hfctl status --json` (валидность json.tool), `hfctl doctor`, `hfctl models` — каждый вывод `diff` старый vs новый = пусто, rc идентичны | — |
| 5 парность чистых функций + md5 | `$S/test/pure_funcs.sh`: old-vs-new вызовы `profile_field` (3 профиля × полей 1–5), `resolve_profile` (все алиасы + неизвестный → rc 1), `model_set` (3), `profile_avail_list` (один /proc/meminfo → идентично), `bench_med` (зафиксированный runs.tsv-фикстура `$S/test/runs.tsv`, все сценарии × полей 1–6); `md5sum benchmarks/prompts/*.txt tpl/bench/*.txt` = `253c7ac50857fe6d0e10fb0d2c5e35c0` (обе копии) | — |
| 6 install.sh | `$S/test/install_sandbox.sh`: (а) из дерева: `HFCTL_DIR=$S/inst/hipfire HFCTL_BIN_DIR=$S/inst/bin bash $S/tree/install.sh` → `cmp` каждого `hfctl`, `lib/*`, `tpl/**` с источником; `readlink $S/inst/bin/hfctl` = путь в стек; (б) замена реального файла: `echo x > $S/inst/bin/hfctl` + повтор → снова симлинк; (в) идемпотентность: повтор → rc 0, файлы md5-равны; (г) вне дерева: `mkdir $S/lone && cp install.sh $S/lone/ && (cd $S/lone && bash install.sh)` → rc 1 + внятный текст; (д) `grep -cE 'HFCTL_RAW_URL|curl' install.sh` = 0 | — (реальная установка из клона = DoD 10/11) |
| 7 bench-python parity + ttft | `$S/test/bench_py_parity.sh`: из старого извлечь ttft.py/bench_py.py (`bench_write_py` с BENCH_TMP), запустить old `bench_py.py report\|artifact\|compare` и new `tpl/python/bench_report.py` с одинаковым env (B_RUNS=зафиксированный runs.tsv, B_TS/профиль/модель/роут/образ/md5 — константы; compare-base = старый artifact) — `cmp` stdout всех трёх subcommand'ов. `$S/test/ttft_test.sh`: `$S/test/fake_sse.py` (http-сервер: 2 дельта-события без content → пауза 150 мс → chunk с content → [DONE]; второй URL — только role-дельты → `null`; третий — сервер не запущен → `ERR …`): `python3 tpl/python/ttft.py <url> <payload>` — ожидания: целое мс (150 ≤ x < 2000), `null`, `ERR *` | — |
| 8 README | `grep -c 'curl -fsSL' README.md` = 0; `grep -n 'lib/\|tpl/' README.md` (раздел «Как это устроено» описывает дерево); quickstart читается по букве (внутренний: clone-копия = $S/tree → install.sh из неё, DoD 6) | — |
| 9 spec | правки §2/план/state.md — по diff (`git diff --stat`); содержание проверяет reviewer | — |
| 10 evo: полный цикл | — (внутренне недоступно: нет /dev/kfd/systemd/podman) | До: предупреждение пользователя (машины в работе) + подтверждение. Обнаружение: tree-установка поверх живого стека сохраняет модели/state/конфиг; boot-юнит запускает ДИСПЕТЧЕР из стека (`_boot` source'ит lib/ — доказательство, что дерево работает в прод-потоке); watchdog жив; поведение идентично (health/smoke/roут-строки те же). Цикл: `use 27b-slots` → `use 27b-single` → `off` → `on` → ребут → сам подъём канона, healthy + smoke; финал 27b-single healthy. → hflab `.local-analysis/task8_evo_full.txt` |
| 11 FAEX: лёгкое | — | Обновление деревом через install.sh (без остановки) → flash-multi healthy + smoke, lanes заново приняты (`fn-lanes staged` в логе). Обнаружение: update на flash-профиле + lanes-роут не пострадал. → hflab `.local-analysis/task8_faex_light.txt` |
| 12 hflab-документация | — | AGENTS.md hflab (hfctl-секция: дерево ~/hipfire, дистрибуция git clone, обновление = install.sh из клона) + STATE.md hflab; артефакты приёмки — в `.local-analysis/` (в hfctl-репо: 0 имён хостов/IP/логов — правило 7, проверяется reviewer'ом grep'ом) |

Порядок: baseline (shellcheck) → рефакторинг → DoD 1–7 внутренние →
dev-report → tester (полный регресс = все скрипты выше + повтор baseline-
сравнения) → внешняя партия DoD 10–12 одной экспедицией (машины в работе,
предупреждение пользователя — обязательное).

### Open questions

Блокирующих нет. Неблокирующие (решение architect'а уже зафиксировано в
Design, перечислены для прозрачности — переопределение пользователем
допустимо до начала кода):

1. Двойная копия bench-фикстуры в репо (`benchmarks/prompts/` +
   `tpl/bench/`). Варианты: (a) оставить обе, md5-гейт в DoD 5 —
   **рекомендация (a)**: benchmarks/prompts = канон для hflab-скриптов,
   tpl/bench = shipped; (b) оставить только tpl/bench.
2. Коммит-план: 2 коммита (код + статус) — рекомендация; альтернатива
   «1 коммит всего» не принята: state.md «принят» должен быть отдельным
   статусным коммитом после внешней приёмки (правило 1).

### Addendum (orchestrator, 2026-11-10) — решения после чтения Design

1. **Open questions — РАСТЕРИФОВАНЫ рекомендациями architect'а**:
   (1a) двойная копия фикстуры — обе (`benchmarks/prompts/` канон +
   `tpl/bench/` shipped) + md5-гейт в DoD 5; (2) коммит-план — 2 коммита.
   Дальнейших вопросов до внешней приёмки не ожидается.
2. **Уточнение DoD 4 (usage)**: строки 2..7 usage-текста (header L3..7
   «как получить/запустить») ОБНОВЛЯЮТСЯ под дистрибуцию git clone (текст
   `scp hfctl user@host:` больше не верен); новые формулировки фиксирует
   developer в dev-report. Строки 8..20 (карта команд) — байт-в-байт как
   было. Вывод `usage` сравнивается с закреплённым NEW-golden (не с
   старым), golden фиксируется в dev-report.
3. **Неполное дерево — внятный отказ**: `sync_tree` (и install.sh) при
   отсутствии `lib/`/`tpl/` рядом с диспетчером/скриптом — die с текстом
   «дерево hfctl неполное: рядом нет lib/ и tpl/ — установи через
   git clone + ./install.sh» (rc 1), не cp-ошибка.
4. **md5-гейт фикстуры через tpl**: тест DoD 5 дополнительно проверяет,
   что файл, который `cmd_bench` создаёт из `tpl/bench/` (c_code.txt),
   имеет md5 `253c7ac50857fe6d0e10fb0d2c5e35c0` (покрывает путь
   «heredoc → cat файла» на предмет trailing-newline).
