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

---

## Dev report (developer)

Date / round: 2026-11-10, round 1. Коммит C1: `4ad0519` (состав — строго
по Design §5: `hfctl`, `lib/*.sh`×10, `tpl/**`, `install.sh`, `README.md`,
`spec/hfctl.md` §2, `spec/plan.md`, `spec/state.md`; этот отчёт — артефакт
роли, в коммит не вошёл).

### What was done (по scope-пунктам)

**Диспетчер `hfctl`** (1661 → 102 строк): `#!/usr/bin/env bash` (L1),
usage-блок L2..20 (строки 3–7 обновлены под git-clone — единственное
осознанное изменение текста usage, addendum #2; строки 8–20 — дословно),
`set -euo pipefail`, env-конфигурация L34..L54 дословно + две новые
строки `LIB_DIR`/`TPL_DIR` (без env-переопределений), хелперы
`log`/`warn`/`die`/`ASSUME_YES`/`ask`/`isint`, 10 `source`'ов в целевом
порядке, `usage()` (`sed -n '2,20p' "$0"`) и dispatch-блок дословно
(текст «неизвестная команда» byte-в-byte).

**`lib/*.sh`** — 10 модулей, по одной ответственности:
- `lib/profiles.sh` (58 строк) — константы профилей, `profile_field`,
  `resolve_profile`, `ram_pool_gib`, `profile_gate`, `profile_avail_list`;
- `lib/stack.sh` (46) — `CF`, `compose`, `env_val`, `cur_profile`,
  `cur_model`, `preflight`;
- `lib/state.sh` (40) — `state_dir`, `migrate_state`, `model_set`,
  `set_models_dir`, `migrate_models`;
- `lib/stack_files.sh` (70) — `render_tpl` (чистый bash, `${var//lit/val}`,
  die на остаточных `__X__`), `sync_tree` (маркер `$STACK_DIR/hfctl`;
  отказ при неполном дереве — текст addendum #3), `ensure_symlink`,
  `write_stack_files` (статичные compose — `install -m 0644` без
  экспансий; compose.local.yml — render), `write_env` (через render);
- `lib/engine.sh` (51) — `cfgset`, `apply_profile` («ВАЖНО»-комментарии
  дословно);
- `lib/health.sh` (64) — `wait_health` (→ `health_ok.py`), `smoke`
  (→ `smoke_resp.py`), `check_route` (→ `health_mode.py`; «ВАЖНО»-
  комментарии сохранены);
- `lib/models.sh` (17) — `pull_model`, `pull_profile_models`;
- `lib/commands.sh` (386) — `cmd_install/use/status/logs/watch/doctor/
  models/pull/uninstall` + `gpu_temp`, `cmd_mode`;
- `lib/autostart.sh` (85) — `cmd_on/off/up/down`, `cmd_autostart`
  (юниты — render из tpl; timer — статичный `install -m 0644`),
  `hf_up_locked`, `cmd_boot`, `cmd_watchdog`;
- `lib/bench.sh` (402) — весь bench; `BENCH_FIXTURE_MD5`; фикстура
  читается из `"$TPL_DIR/bench/merge_sort_thinking_off.txt"` (md5-гейт
  и WARN сохранены); `bench_med` (→ `tpl/awk/bench_med.awk`), hol-note
  (→ `tpl/awk/hol_note.awk`); `bench_write_py` УДАЛЁН.

**`tpl/`** (все шаблоны, без исключений):
- `compose/compose.yml` (54 строк) и `compose.halo.yml` (16) — статичные,
  тела heredoc старого кода (L230–285 / L287–303) дословно;
- `compose/compose.local.yml.tpl` — плейсхолдеры `__LOCAL_PROMPTS__`,
  `__LOCAL_DRAFT_ENV__`;
- `env/env.tpl` — `__PROFILE__ __MODEL__ __PORT__ __BIND__ __MODELS_DIR__
  __STATE_DIR__ __IMAGE__`;
- `systemd/` — 3 tpl (service — `__STACK_DIR__ __CF__ __PODMAN_BIN__`,
  watchdog.service — `__STACK_DIR__`, timer — без плейсхолдеров);
  «ВАЖНО: без KillMode=process…»-комментарий перенесён в watchdog tpl
  дословно;
- `python/` — 13 файлов по контрактам Design §4 (№1–14; №1/№2 — один
  общий `health_ok.py`);
- `awk/` — `bench_med.awk`, `hol_note.awk`;
- `bench/merge_sort_thinking_off.txt` — shipped-копия, md5 = эталон.

**`install.sh`** (66 → 69 строк): clone-only. `HFCTL_RAW_URL` и curl-ветка
удалены; проверка дерева рядом с собой (нет `hfctl`+`lib/`+`tpl/`) → die
с текстом addendum #3, rc 1; синхронизация ровно трёх элементов
(`hfctl`+`lib/`+`tpl/`) с `rm -rf "${STACK_DIR:?}/…"` (защита от пустого
STACK_DIR — SC2115); симлинк в bin (вкл. замена реального файла);
PATH-подсказка; идемпотентен. `HFCTL_DIR`/`HFCTL_BIN_DIR` сохранены.
Сопутствующее изменение (см. Known limitations): финальная строка
«Обновление бинаря…» переписана под git-clone-механику.

**README.md**: quickstart — только git clone (строка `curl -fsSL`
удалена); «Как это устроено» — дерево `~/hipfire/` включает `hfctl`
(диспетчер), `lib/`, `tpl/` + абзац про дистрибуцию/обновление.

**spec**: `hfctl.md` §2 (hfctl НЕ однофайловый; дистрибуция = git clone;
curl убран; install.sh-контракт), `plan.md` (этап 8 с DoD), `state.md`
(строка этапа 8 «в работе» + строки 6/7 в таблице + журнал). В новых
строках spec — 0 имён хостов (нейтральные «прод-машина (60 GiB)» /
«вторая машина (128 GB)» — см. правило 7 ниже).

**Поведение** — байт-в-байт, за двумя осознанными исключениями (usage
L3–7, текст ошибки install.sh вне дерева) — подтверждено проверками ниже.

### How it was checked internally (команды + результаты)

Среда: dev-контейнер alpine-musl (bash 5.3.9, shellcheck 0.11.0, python3),
без /dev/kfd/systemd/podman. Sandbox `$S=/tmp/hfctl-stage8` (см. Known
limitations про путь). Harness-скрипты: `$S/test/*.sh` (тексты —
`/tmp/hfctl-stage8/test/{golden_stack,cli_parity,pure_funcs,
install_sandbox,bench_py_parity,ttft_test}.sh` + `fake_sse.py`;
tester повторяет по тем же скриптам). Stubs `podman`/`systemctl`/
`loginctl`/`sudo` — идентичные заглушки для обоих прогонов (лог вызовов
— `$S/*/stub-*.log`).

**DoD 1 — раскладка** (PASS):
- `grep -c 'python3 -c' hfctl lib/*.sh` → все 0;
- grep записи heredoc в compose/.env/.service/.timer → 0 (остатшиеся
  `cat <<EOF` — только печать в stdout: `bench_help`, «как пользоваться»
  в `cmd_install`, финальный блок install.sh);
- `grep -rn 'FIXTURE_EOF' hfctl lib/` → 0;
- `wc -l hfctl` = 102 (≤ 450);
- «ВАЖНО»-комментарии: old 5 → new 5 (4 в shell-файлах + 1 в
  `tpl/systemd/hipfire-compose-watchdog.service.tpl`), дословно.

**DoD 2 — bash -n + shellcheck** (PASS, с задокументированными
исключениями):
- `bash -n` — OK для всех 12 shell-файлов (hfctl, lib/*.sh×10,
  install.sh);
- **baseline (зафиксирован до изменений; HEAD-версии)**:
  `shellcheck <HEAD>hfctl <HEAD>install.sh` → rc=1; findings (без
  footer-URL): SC2034×4 (profile_×3, retries), SC2155×3, SC1091×2
  (`. /etc/os-release`), SC2005×1, SC2086×1, SC2012×1 — всего 12;
- **after**: `shellcheck hfctl lib/*.sh install.sh` → rc=1; findings:
  SC2034×21, SC1091×12, SC2155×3, SC2005×1, SC2086×1, SC2012×1 —
  всего 39;
- **новых КОДОВ нет** (multiset-сравнение: union кодов идентичен);
- дельта **SC1091 +10** — все ровно на строках `source "$LIB_DIR/…"`
  (динамический путь; ожидаемое исключение Design §6);
- дельта **SC2034 +17** — все «appears unused» на ГЛОБАЛЬНЫХ
  переменных, пересекающих границы модулей (shellcheck анализирует
  файл в файл): IMAGE, MODELS_DIR, STATE_BASE, PORT, BIND, DRAFT_FILE,
  SLOTS, CONTAINER, UNIT_NAME, STOP_MARKER, MAX_SEQ, MEMLOCK, TPL_DIR
  (определены в диспетчере → используются в lib) + BIND (bench.sh),
  SLOTS и ASSUME_YES (commands.sh), PROFILE_DEFAULT (profiles.sh) →
  используются в других модулях. Использование доказано parity-прогонами
  ниже (функции, где переменные участвуют, работают). По классу —
  тот же cross-file-артефакт, что SC1091 (Design §6). Fix-идея — в
  Out-of-scope proposals.

**DoD 3 — golden-file parity** (PASS): `$S/test/golden_stack.sh old|new`:
«функционная часть» (sed до инвариантного маркера `^cmd="\${1:-}"`)
старого и нового; sandboxed HOME/HFCTL_DIR + stub'ы; 4 комбинации
{27b-single (draft yes) × prompts есть/нет} ∪ {flash-multi (draft −) ×
prompts есть/нет} → `write_stack_files; write_env <prof> <model>;
cmd_autostart`. `cmp` попарно `compose.yml`, `compose.local.yml`,
`compose.halo.yml`, `.env`, 3 systemd-юнита — **все идентичны**
(единственный raw-разброс — вшитые sandbox-пути `…/old/` vs `…/new/`
в `.env`/юнитах — артефакт harness; после нормализации пути diff =
пусто); `grep -rlE '__[A-Z0-9_]+__'` по всему выводу = 0 (остаточных
плейсхолдеров нет; die-guard render_tpl работает).

**DoD 4 — CLI-поверхность** (PASS): `$S/test/cli_parity.sh`: свежий
HFCTL_DIR + stub'ы; `{usage, неизвестная команда, status, status --json,
doctor, models, bench --help}` — old vs new: **все выводы и rc
идентичны** (кроме согласованного usage L3–7); `status --json` —
валидный JSON (`json.tool`); NEW-golden usage закреплён в
`$S/test/usage_new_golden.txt` и воспроизводится; old-vs-new diff usage
= ровно строки 2..6 вывода (file L3..7), строки 7..19 (карта команд)
byte-в-byte. Новый текст L3..7 (фиксируется):

```
Ubuntu/Debian. Раскладывается деревом: диспетчер hfctl + lib/*.sh + tpl/
(шаблоны compose/.env/юнитов/python/фикстуры); запускается ОТ СВОЕГО ИМЕНИ
(не root; sudo применяется точечно):
  git clone <repo> && cd hfctl && ./install.sh   # бинарь в стек + симлинк в bin
```

**DoD 5 — чистые функции + md5** (PASS): `$S/test/pure_funcs.sh`:
`profile_field` (3 профиля × поля 1–5), `resolve_profile` (все 10
алиасов + неизвестный → rc=1), `model_set` (3), `profile_avail_list`
(один /proc/meminfo), `bench_med` (9 сценариев × поля 1–6 на
зафиксированном `$S/test/runs.tsv`) — old vs new: **все идентичны**
(diff = пусто). `md5sum benchmarks/prompts/*.txt tpl/bench/*.txt` =
`253c7ac50857fe6d0e10fb0d2c5e35c0` (обе копии); доп. (addendum #4):
old-встроенная фикстура (heredoc `IFS='' read -r -d ''`) даёт тот же
md5 → путь «heredoc → cp файла» байт-нейтрален (trailing-newline
учтён).

**DoD 6 — install.sh sandbox** (PASS): `$S/test/install_sandbox.sh`:
(а) из дерева → все файлы `hfctl`/`lib/*`/`tpl/**` в стеке `cmp`-равны
источнику, `readlink bin/hfctl` = путь в стек; (б) реальный файл в bin
→ после повторного install.sh снова симлинк; (в) идемпотентность:
повтор → rc 0, md5-снапшот идентичен; (г) вне дерева (install.sh один
в каталоге) → rc 1 + «дерево hfctl неполное: рядом нет lib/ и tpl/ —
установи через git clone + ./install.sh», стек НЕ создан; (д)
`grep -cE 'HFCTL_RAW_URL|curl' install.sh` = 0.

**DoD 7 — bench-python parity + ttft** (PASS): `$S/test/bench_py_parity.sh`:
old `bench_write_py` (BENCH_TMP) извлёк ttft.py/bench_py.py; `ttft.py`
old vs new — byte-в-byte; `report`/`artifact`/`compare` (единый env:
B_RUNS=зафиксированный runs.tsv; B_TS/профиль/модель/роут/образ/md5 —
константы; B_NOTE_* — константы; compare-base = артефакт) — stdout и
stderr old `bench_py.py` vs new `bench_report.py` **идентичны**.
`$S/test/ttft_test.sh` + `fake_sse.py` (http-сервер: /a — 2 дельты без
content + пауза 150 мс + chunk с content + [DONE]; /b — только role-
дельты; /c — закрытый порт): ttft.py → `162` (150 ≤ x < 2000 ✓),
`null` ✓, `ERR <urlopen error [Errno 111] Connection refused>` ✓.

**DoD 8 — README** (PASS): `grep -c 'curl -fsSL' README.md` = 0;
раздел «Как это устроено» описывает `lib/` и `tpl/`.

**DoD 9 — spec** (PASS по составу): правки §2/plan/state.md — в diff
C1; содержание — на проверке reviewer'а.

**Доп. sanity**: запуск диспетчера прямо из «стека» (SELF =
`$STACK_DIR/hfctl`, early-return sync_tree) — `models` работает,
неизвестная команда rc=1; source'ы lib под `set -u` без top-level-
вызовов (все harness-прогоны source'ят модули и не падают до dispatch).

**Правило 7 (grep перед коммитом)**: product surface
(`hfctl`, `lib/`, `tpl/`, `install.sh`, `README.md`) — 0 имён хостов/IP/
ключей/логов; в новых строках diff C1 — 0. В spec-документах имена
машин есть и были ДО коммита (HEAD: plan.md 1, state.md 16, task-8.md 2
— в brief'е orchestrator'а они в DoD 10–12); в добавляемых этим
этапом строках — только нейтральные обозначения.

### Not checked internally (что подтверждает внешний прогон)

В контейнере нет /dev/kfd, systemd user, podman — **install и всё
GPU/systemd-зависимое ВНУТРЕННЕ не проверяется** (внешние DoD 10–12,
не моя зона — tester/orchestrator):
- DoD 10 (прод-машина 60 GiB): обновление деревом через install.sh
  поверх живого стека (models/state/конфиг целы), boot-юнит запускает
  ДИСПЕТЧЕР из стека (`_boot` source'ит lib/), полный цикл use↔use
  (27b-slots → 27b-single), off→on, ребут → сам подъём канона,
  healthy+smoke;
- DoD 11 (вторая машина 128 GB): обновление без остановки →
  flash-multi healthy + smoke, lanes-роут не пострадал;
- DoD 12: hflab AGENTS.md/STATE.md + `.local-analysis/`-артефакты.

Не проверялось внутренне также: живые `wait_health`/`smoke`/
`pull_profile_models`/`cfgset` (нужен реальный сервер), recreate-цикл,
watchdog на живом rootless-podman.

### Known limitations / assumptions

1. **shellcheck cross-file (DoD 2)**: +10 SC1091 (source-строки) и
   +17 SC2034 (глобальные переменные между модулями) — задокументиро-
   ваны выше; новых КОДОВ нет; поведение не изменилось (parity-прогоны
   зелёные). Это цена модульности, а не регресс.
2. **Sandbox-путь**: Test strategy предписывает
   `/tmp/opencode/hfctl-stage8/`, но `/tmp/opencode` в этом контейнере
   root:root и недоступен на запись uid 1000 (без sudo) → использован
   `/tmp/hfctl-stage8`. На результаты не влияет (все env-
   переопределения HFCTL_DIR/HOME/PATH те же); tester повторяет по
   тем же скриптам.
3. **`$USER` в контейнере**: в harness-прогонах `export USER=hfctltest`
   (в dev-контейнере переменная не задана, `set -u` упал бы на
   `loginctl … "$USER"`); на реальных машинах USER всегда задан — на
   парность не влияет (оба бинаря используют его одинаково).
4. **install.sh финальная строка**: «Обновление бинаря: свежий клон
   репозитория → тот же install.sh (стек и модели останутся)» —
   сопутствующее изменение формулировки (было «повтори этот же
   install.sh»); вышло за рамки двух заявленных исключений вывода —
   фиксация для reviewer'а (смысл: curl-режима больше нет).
5. **`rm -rf "${STACK_DIR:?}/…"`** в sync_tree/install.sh: при пустом
   STACK_DIR — явная ошибка вместо `rm -rf /lib` (поведение меняется
   только в невозможном на практике случае; SC2115 закрыт).
6. **addendum #3** применён и к `sync_tree` (die при неполном дереве),
   и к `install.sh` — единый текст.
7. **Двойная копия фикстуры** (benchmarks/prompts канон + tpl/bench
   shipped) — по решению (1a); рассинхронизация ловится md5-гейтом
   DoD 5 и runtime-WARN в cmd_bench.

### Out-of-scope proposals (идеи — сюда, не в код)

- Для SC2034/SC1091 cross-file-шума — `shellcheck -x`/`--source=…` или
  проектный `.shellcheckrc` с `exclude` для модулей; отдельным этапом
  (сейчас не введено — Design не требует).
- `benchmarks/prompts/` → `tpl/bench/`: генерация shipped-копии из
  канона скриптом (убрать дублирование); сейчас обе копии + md5-гейт.
- README «Как это устроено»: дерево `tpl/` списком — косметика.

---

## Test report (tester)

Date / round: 2026-11-10, round 1. Verdict: **BLOCKED-EXTERNAL** — все
внутренние проверки (DoD 1–9 + дополнительный регресс) зелёные; внешние
DoD 10–11 ждут явного GO пользователя (машины в работе) — EXP-скрипты
созданы, НЕ запускались; DoD 12 (hflab-документация) закрывается после
внешней партии.

### Internal checks

| DoD item | проверка | результат |
|---|---|---|
| 1 раскладка | `grep -c 'python3 -c' hfctl lib/*.sh` → 0×11; heredoc/редиректы в `$STACK_DIR/{compose*,.env,*.service,*.timer}` → 0 (остатшиеся `cat <<EOF` — только stdout-печать: bench_help, install-подсказка, финальный блок install.sh); `grep -rn FIXTURE_EOF hfctl lib/` → 0; `wc -l hfctl` = 102 (≤450); «ВАЖНО» old 5 → new 5 (4 в shell + 1 в tpl) дословно | PASS |
| 2 bash -n + shellcheck | `bash -n` всех 12 shell-файлов (hfctl, install.sh, lib/*.sh) → rc=0; shellcheck baseline **пересобран из git 3eb7ce7** = 12 findings (SC2034×4, SC2155×3, SC1091×2, SC2005×1, SC2086×1, SC2012×1) — совпадает с dev-report; after = 39 (SC2034×21, SC1091×12, SC2155×3, SC2005×1, SC2086×1, SC2012×1); **новых КОДОВ нет**; дельта SC1091 +10 — ровно на строках `source "$LIB_DIR/…"`; дельта SC2034 +17 — ровно на перечисленных в dev-report cross-module-глобальных (ASSUME_YES, BIND×2, CONTAINER, DRAFT_FILE, IMAGE, MAX_SEQ, MEMLOCK, MODELS_DIR, PORT, PROFILE_DEFAULT, SLOTS×2, STATE_BASE, STOP_MARKER, TPL_DIR, UNIT_NAME) | PASS |
| 3 golden-file parity | `golden_stack.sh old/new` пере-запущены: 4 комбинации (draft ×/- × prompts ×/-) × {compose.yml, compose.halo.yml, compose.local.yml, .env, 3 systemd-юнита} — `cmp` после нормализации sandbox-путей = идентичны; stub-логи (вызовы podman/systemctl/loginctl) идентичны; остаточные `__X__` = 0 | PASS |
| 4 CLI-поверхность | `cli_parity.sh`: usage / неизвестная команда / status / status --json (валидный JSON, `json.tool`) / doctor / models / bench --help — выводы и rc идентичны (кроме согласованного usage L3–7: diff = ровно 4+4 строки, текст зафиксирован в dev-report и воспроизводится из репо; NEW-golden сверен с `bash hfctl` из `/workspace/hfctl`) | PASS |
| 5 чистые функции + md5 | `pure_funcs.sh`: `profile_field` (3×5), `resolve_profile` (10 алиасов + неизвестный rc=1), `model_set` (3), `profile_avail_list`, `bench_med` (9 сценариев × 6 полей, зафиксированный runs.tsv) — old vs new идентичны; md5 фикстур = `253c7ac50857fe6d0e10fb0d2c5e35c0` (benchmarks/prompts + tpl/bench); old-встроенная heredoc-фикстура — тот же md5 | PASS |
| 6 install.sh | `install_sandbox.sh`: (а) все файлы `cmp`-равны дереву, `readlink` = путь в стек; (б) реальный файл → снова симлинк; (в) идемпотентен (md5-снапшот); (г) вне дерева rc=1 + «дерево hfctl неполное…» + стек НЕ создан; (д) `grep -cE 'HFCTL_RAW_URL\|curl' install.sh` = 0 | PASS |
| 7 bench-python + ttft | `bench_py_parity.sh`: old `ttft.py` = new байт-в-байт; report/artifact/compare — stdout+stderr идентичны (единый env, зафиксированный runs.tsv); `ttft_test.sh` (fake-SSE): `/a` → `161` (∈ [150,2000)), `/b` → `null`, `/c` → `ERR <urlopen error [Errno 111] Connection refused>` | PASS |
| 8 README | `grep -c 'curl -fsSL' README.md` = 0; «Как это устроено» — дерево с `hfctl` (диспетчер), `lib/`, `tpl/`; quickstart = git clone | PASS |
| 9 spec | в diff C1: `spec/hfctl.md` §2, `spec/plan.md` (этап 8), `spec/state.md` (строка этапа 8 «в работе» + журнал) — состав подтверждён; содержание — зона reviewer'а | PASS (по составу) |

### Дополнительный регресс (добавлен tester'ом, developer не заявлял)

| проверка | результат |
|---|---|
| «свежий clone» (путь новичка): `git clone /workspace/hfctl → clone-fresh` (HEAD = C1, чистое дерево) → `./install.sh` с sandbox `HOME/HFCTL_DIR/HFCTL_BIN_DIR`: rc=0; все файлы стека `cmp`-равны клону; симлинк в стек; запуск диспетчера ИЗ стека (early-return `sync_tree`): `models` rc=0, usage rc=0, неизвестная команда rc=1 | PASS |
| `bash -n` на ВСЕХ shell-файлах (hfctl, install.sh, lib/*.sh — 12 шт.) | PASS (rc=0) |
| правило 7 — независимый grep по **новым строкам** C1 (`git show 4ad0519`, `+`-строки): IP — только `127.0.0.1` / `${HIPFIRE_BIND:-127.0.0.1}` (localhost, не машины); имена хостов — только «Halo / Strix Halo» (платформа AMD, предсуществующая практика, в т.ч. в pre-C1 hfctl) и имя файла `compose.halo.yml`; пути ключей / ssh-команды с адресами / user@host — **0**; в spec-файлах — **0** (имена машин в spec — докоммитная практика, C1 новых не вводит) | PASS |
| «падает как надо» (action recipe): `hfctl use nosuch` → «неизвестный профиль … (доступны: …)» rc=1; `hfctl install --bogus` → «неизвестный флаг … (доступны: …)» rc=1; `hfctl use` → «использование: hfctl use <profile> (…);» rc=1; install.sh вне дерева → «дерево hfctl неполное: … git clone + ./install.sh» rc=1, стек не создан | PASS |

### Сверка Dev report с фактами (пункт B)

- Все заявленные PASS (DoD 1–8) воспроизведены по harness-скриптам
  developer'а (`/tmp/hfctl-stage8/test/`): golden, cli_parity, pure_funcs,
  install_sandbox, bench_py_parity, ttft_test — все зелёные.
- Числа DoD 2 совпадают строго (baseline 12 / after 39 / нет новых кодов).
  Первое расхождение в подсчётах — артефакт footer-URL'ов shellcheck
  (содержат SC-коды), не findings; с учётом этого — полное совпадение.
- Отклонение «sandbox-путь `/tmp/hfctl-stage8` вместо
  `/tmp/opencode/hfctl-stage8`» — **обосновано**: `/tmp/opencode` =
  root:root, uid 1000 не пишет (проверено: `touch` → Permission denied),
  sudo запрещён. На результаты не влияет (env-переопределения те же).
- Отклонение limitation #4 (финальная строка install.sh переписана под
  git-clone-механику) — подтверждена в коде; честно задекларирована в
  dev-report; не противоречит цели (curl-режим удалён), но формально
  выходит за два заявленных исключения вывода — **примечание для
  reviewer'а**, не FAIL.
- Отклонение limitation #1 (shellcheck cross-file +10/+17) —
  обосновано Design §6; дельты локализованы (проверено).
- Мелочи (не дефекты): ttft `/a` = 161 мс в моём прогоне (у developer'а
  162) — джиттер в допустимом диапазоне; точные количества имён машин в
  spec-доках до коммита зависят от grep-паттерна (dev-report:
  plan.md 1 / state.md 16 / task-8.md 2; мой подсчёт: 1 / 14 / 3,
  hfctl.md 2) — сущность (имена — докоммитные, C1 новых не вводит)
  подтверждена независимым grep.

### Failures (FAIL)

Нет.

### External experiments

| EXP-id | DoD item | статус |
|---|---|---|
| `EXP-001-evo-full.sh` — hflab `.local-analysis/task8-exp/` (полный цикл: pre → update деревом → use 27b-slots → use 27b-single → off → on → reboot → сам подъём канона + smoke → финал 27b-single) | 10 | создан, **НЕ запускался** — ожидает GO пользователя (машина в работе); `bash -n` + dry-render динамических remote-блоков — ок |
| `EXP-002-faex-light.sh` — там же (update деревом без остановки → healthy + smoke, lanes-лог info) | 11 | создан, **НЕ запускался** — ожидает GO; `bash -n` + dry-render — ок |
| — (документация, без скрипта) | 12 | закрывается после внешней партии: hflab AGENTS.md (hfctl-секция: дерево `~/hipfire/`, дистрибуция git clone, update = install.sh из клона) + STATE.md hflab; артефакты приёмки — `.local-analysis/task8-exp/*.result.txt` |

Запуск EXP — только после предупреждения пользователя и его GO
(шапки скриптов это фиксируют; профиль/модель/порт читаются из
`hfctl status --json` — не хардкодятся; SKIP-флаги на случай
недоступного `sudo -n`).

### Regression

- Свит этапа 8 (harness developer'а + повторный прогон tester'ом +
  добавленный регресс выше): **полностью зелёно** (таблицы выше).
- Инварианты закрытых этапов: md5 bench-фикстуры = эталон (обе копии +
  old-встроенная); порядок recreate → wait_health → smoke и exit-коды
  `use`/`off`/`on` — пути кода не менялись (C1 — чистый рефакторинг;
  parity DoD 3–5); state-лейаут per-профиль (этап 7) — `state_dir` /
  `migrate_state` / `model_set` покрыты parity DoD 5.
- Sandbox developer'а заснапшотирован в `/tmp/hfctl-stage8-devsnap`
  ПЕРЕД повторными прогонами (форензика); прогоны tester'а — поверх тех
  же скриптов.

### Round 1 (2026-11-10): fix-раунд по тесту (triage: `test` — дефект
harness'а tester'а; продукт НЕ менялся — HEAD `92920d5`,
`git diff 4ad0519..HEAD` = только `spec/task-8.md`; `$S/tree` = HEAD
bayt-в-байт по всем продуктовым файлам)

**Разбор FAIL'а EXP-001 (P6).** Пользователь дал GO на che-evo; EXP-001
отработал: P1–P5 зелёные (update деревом md5 `cfba2fbf → cd623950`,
use↔use 27b-slots/27b-single, off/on), P6 формально FAIL: «канон не
healthy в течение 15 мин после ребута». Причина — баг HARNESS'а
tester'а, не продукта: в цикле ожидания P6 (EXP-001 строка ~187)
`health_of` вызывался через пайп (`| health_of`) при аргументной
сигнатуре (`$1`) и `set -u` → `line 78: $1: unbound variable` → каждый
тик «ERR» → таймаут 15 мин. Remote-команда на каждом тике
(`hfctl status --json`) выполнялась штатно — баг был в парсинге ответа
tester'ом. Живая проверка оркестратора сразу после ребута подтвердила:
контейнер Up (healthy) с момента boot, boot-юнит `hfctl _boot` = exit 0,
дерево в стеке, профиль 27b-single, health ok → **P6 по существу
состоялся**.

**Исправление (только дефектное место).** EXP-001-evo-full.sh, цикл P6:
аргументная форма — `st=$(remote …); h=$(health_of "$st") || h="ERR"`.
Все остальные вызовы `health_of` сверены: EXP-001 — 6, EXP-002 — 3,
все аргументные; пройденные шаги не переписывались. `bash -n` — чисто;
pipe-вызовов `| health_of` в обоих EXP не осталось.

**Новые доказательства DoD 10 (ДОП-прогон, read-only + 1 smoke-запрос,
FAEX не трогался).** `EXP-001r1-verify.sh` →
`.local-analysis/task8-exp/EXP-001r1-verify.result.txt` (hflab),
**RESULT: PASS**:
- V1: `status --json` → профиль **27b-single**, модель
  `qwen3.8:27b-mq4-xts`, health **OK** (mode standard, multi_slot=false);
  порт из `.env` = 11435;
- V2: контейнер `hipfire_hipfire_1: Up 27 minutes (healthy)`; boot-время
  хоста (uptime -s) 17:22:27 MSK; дерево в стеке: `lib/` = 10 модулей,
  `tpl/` = 6 подкаталогов; симлинк `~/.local/bin/hfctl` →
  `/home/hipfire/hipfire/hfctl`;
- V3: boot-юнит `hipfire-compose` — **active (exited)** с 17:22:35 (8 с
  после boot), `ExecStart=bash /home/hipfire/hipfire/hfctl _boot
  (code=exited, status=0/SUCCESS)` — boot-юнит запускает ДИСПЕТЧЕР из
  стека (proof: дерево работает в прод-потоке);
- V4: smoke — один запрос → content «OK» (ttft 266 мс, prefill
  63.9 tok/s).

**Пересчёт вердикта.** DoD 10 — **ЗАКРЫТ** (P1–P5 — исходный прогон
EXP-001, P6/P7 — доп-доказательства `EXP-001r1-verify`): update
деревом на живой машине, полный цикл use↔use/off/on, reboot → сам
подъём канона (boot-юнит `hfctl _boot` exit 0), healthy + smoke, финал
27b-single healthy. DoD 11 — по-прежнему **ждёт GO пользователя на
FAEX** (EXP-002 готов, не запускался). DoD 12 — закроется при закрытии
этапа (hflab AGENTS.md/STATE.md + артефакты в `.local-analysis/`).

**Регресс (повтор, round 1).** Внутренний регресс пере-прогнан поверх
неизменного продукта (HEAD 92920d5): golden (4 комбинации × 7 файлов,
0 остаточных плейсхолдеров), cli_parity, pure_funcs (+md5 эталон),
install_sandbox, bench_py_parity, ttft_test, `bash -n` 12/12, DoD-1 grep
(`python3 -c`=0, FIXTURE_EOF=0, `hfctl`=102 строки) — **всё зелёно**.

Verdict (round 1): **BLOCKED-EXTERNAL** (сузилось: остаётся только
EXP-002/FAEX по DoD 11 + hflab-доки по DoD 12).

### Round 1a (2026-11-10, до GO): пере-проверка EXP-003-faex-full.sh — носитель
DoD 11 в РАСШИРЕННОЙ постановке (решение пользователя: полный цикл вместо
лёгкого EXP-002; EXP-002 — запасной). Продукт НЕ менялся: `git status`
чисто, HEAD `3578c5c`, `git diff 4ad0519..HEAD -- . ':!spec'` = пусто,
md5 диспетчера = `cd623950` (совпадает с `git show origin/main:hfctl` —
локальный main ahead 2 — только spec-коммиты 12e9cf5/3578c5c).

**Внутренние проверки EXP-003** (hflab `.local-analysis/task8-exp/`, 930
строк; реальный прогон НЕ выполнялся — запуски только DRYRUN, сеть не
трогалась):

| проверка | результат |
|---|---|
| сценарная сборка: шапка ЦЕЛЬ/ПРЕДРЕКВИЗИТ/ЗАПУСК/ЧТО=PASS; шаги P1/P1.5/P2/P3(P3a–P3e)/P4(P4a–P4d)/P5(P5a–P5e)/P6(gated)/P7; финальная `RESULT: …`; SKIP-флаги SKIP_OFFON/SKIP_REBOOT + HAVE_REBOOT_BOOT; DRYRUN с graceful-fallback DRY_DIR | OK |
| `bash -n EXP-003-faex-full.sh` | rc=0 |
| shellcheck (без SC1091) | только SC2016×16 — все «\$expansion → remote-пейлоад» (единый стиль quoted-remote EXP-001; ожидаемое исключение) |
| `DRYRUN=1` без ребута | rc=0, `RESULT: PASS`, no-reboot-финал «P6 SKIP», 38 rendered-блоков, bash -n каждого |
| `DRYRUN=1 HAVE_REBOOT_BOOT=1` | rc=0, `RESULT: PASS`, «с ребутом», 41 блок (реальный reboot в dry не выполняется — дословно «пропускаю») |
| `DRYRUN=1 SKIP_OFFON=1` / `SKIP_REBOOT=1` | rc=0 / rc=0, ветки проходят |
| proof `EXP-003-faex-full.dryrender.txt` | перегенерация из текущего скрипта — идентичен уже хранимому; 38 блоков; `RESULT: PASS` |
| dry не делает сеть | `grep 'ssh -i'` в dry-прогоне = 0; remote() в dry пишет только rendered-пейлоады + parsed canned-ответы (file-based state: profile/stop/m5n/bootn — переживает `$()`) |
| урок EXP-001 fix-r1 | pipeline-вызовов `health_of` = 0 во всех EXP; все вызовы аргументные (`&& аргумент || ERR`); `set -u` сверху; шаг-функция `step()` |
| «падает как надо» | каждый FAIL-эмит несёт action-recipe (P1 профиль≠flash-multi → «приведи машину к канону»; P1.5 нет lanes → «hfctl logs -n 50, приложи хвост»; P4c refused≠0 → «приклади logs+grep refused»; P6 не healthy → «systemctl status/journalctl»; P5 sudo-нет → ручной off/on + перезапуск с SKIP_OFFON=1; ERROR-ветки rc=2) |
| гигиена | trap удаляет CLONE + DRY_DIR; хост-артефакты только клон `/tmp/hfctl-stage8-faex-full` (удаляется) и /tmp-логи use (удаляются сразу); gufo не трогается (в remote-пейлоадах упоминаний нет); MemAvailable печатается и не гейтится; диск-гейт (mq6-xt докачка нужна и <25G) — по делу |
| грамматы assert'ов против кода C1 | `cfgset serve.batch_nonexact false` — engine.sh:20/33 ✓; `SMOKE: OK` — health.sh:36 ✓; `профиль X активен` — commands.sh:120 ✓; `singleton+DFlash` (check_route 27b-router) и `lanes ОТКАЗАНЫ`/`fn-lanes staged` — health.sh:54/61/46 ✓ (`grep -q` по подстрокам согласован с форматами вывода) |
| секреты/IP в EXP-003 | IP/ключ/юзер есть — ШТАТНО: lab-артефакт в hflab (правило 7 — только для hfctl-репо), как и в EXP-001; в proof-файлах (dryrender, result) IP/ключей НЕТ |

**Регресс (пере-прогон, round 2, продукт HEAD `3578c5c` = C1 + spec).**
Harness `/tmp/hfctl-stage8/test/`, tree-снапшот refreshён с HEAD (md5-агрегат
подтверждён; product-часть = C1 байт-в-байт; funcs.sh (срез диспетчера до
`cmd=`) regenerated — байт-в-байт с снапшотом C1):

| проверка | результат |
|---|---|
| `bash -n` hfctl/install.sh/lib×10 (12 файлов) | OK |
| golden_stack old + new, 4 комбо × {compose.yml, compose.halo.yml, compose.local.yml, `.env`, 3 юнита} + stub-логи (нормализация sandbox-путей) | diff = 0, плейсхолдер-residue = 0 |
| cli_parity old vs new (usage/неизвестная/status/--json/doctor/models/bench --help) | PASS; usage == NEW-golden для HEAD |
| pure_funcs (profile_field/resolve_profile/model_set/profile_avail_list/bench_med); md5 фикстур benchmarks/prompts + tpl/bench + old-встроенная = `253c7ac50857fe6d0e10fb0d2c5e35c0` ×3 | PASS |
| install_sandbox (из дерева/замена файла/идемпотентность/вне дерева/no-curl) | PASS |
| bench_py_parity (report/artifact/compare) | PASS |
| ttft_test (fake-SSE: 162 / null / ERR) | PASS |
| DoD-1 grep (`python3 -c`=0×11, FIXTURE_EOF=0, `hfctl`=102) | PASS |
| shellcheck C1-multiset: SC2034×21, SC1091×12, SC2155×3, SC2005×1, SC2086×1, SC2012×1 (footer-URL отфильтрованы) — **идентичен** C1 | PASS |
| «путь новичка»: git clone HEAD → install.sh (sandbox HOME/HFCTL_DIR/BIN + stub) → стек cmp-равен клону, симлинк, диспетчер из стека (`models` rc=0, неизвестное rc=1, usage) | PASS |
| правило 7 | продуктовая поверхность + `git show 4ad0519` «+»-строки: 0 IP/ключей/хостов (в tpl только `${HIPFIRE_BIND:-127.0.0.1}` и localhost-curl healthcheck — предсуществующая практика) |

**Сверка ожидания md5.** `git show origin/main:hfctl | md5sum` = `cd623950…`
— EXPECT_MD5-справка скрипта соответствует текущему GitHub main
(клон EXP-003 тянет origin, НЕ локальный HEAD — поэтому ahead-2-spec-коммиты
на прогон не влияют; их публикация оркестратором — до закрытия этапа,
только после реального прогона).

**Failures (FAIL)** — нет.

Вердикт (round 2): **BLOCKED-EXTERNAL** — EXP-003 полностью проверен и
готов (dry-render-режимы зелёные в обоих вариантах proof); реальный прогон
на che-FAEX1 — после GO (машина свободна с 2026-11-10; CLONE Wi-Fi
докачка mq6-xt ~21 GB учтена в скрипте: ~20–25 мин, общий прогон ≤ ~90
мин). EXP-002 остаётся запасным лёгким вариантом (готов, не запускался).
Закрытие: реальный прогон EXP-003 → result-proof → DoD 11 закрыт → DoD 12
(hflab AGENTS.md/STATE.md) → reviewer → C2 «принят».
### Round 2 (2026-11-10, вечер): fix-раунд по тесту EXP-003 (triage: `test` —
дефект HARNESS'а tester'а, продукт не менялся и машина не менялась:
live-проверка FAEX — сервер `Up 24 hours (healthy)`, update не начинался).

**Разбор дефекта (расчёт пути для раскладки этапа 7).** P1-бейслайн EXP-003
искал `$HOME/hipfire/profiles/flash/config/config.toml` — ХАРДКОД-имя `flash`.
Фактический лейаут (live, read-only): маунты `<state>/config →
/home/hipfire/.hipfire`, `<state>/kernel → /var/cache/hipfire`; канонический
каталог — `$HOME/hipfire/profiles/flash-multi/` (только он в `profiles/`);
инвентарь config/: `cache/` (2.6K verified-artifacts.json), `config.toml`,
`daemon-pci-*.pid`, `models` (вложенный bind сета, 0 B), `registry.cache.json`
(~109K), `serve.pid`, `session-cache/` (34 156 343 808 B = 32 GiB, ~106
.snap), рядом `kernel/gfx1151`. Противоречило и моему же обещанию «не
хардкодить» (профиль/модель/порт уже читаются из status). Ревизия
EXP-001/001r1/002: хардкодов profile-dir/session-cache НЕТ (grep = 0) — они
приняты (закрыты на evo), не тронуты (mtimes прежние).

**Исправление (EXP-003, только дефектное место; product — не тронут).**
1. `flash_profile="$profile"` сразу после разбора `status --json` в P1;
   все state-пути теперь `$HOME/hipfire/profiles/$flash_profile/…`.
2. Единый замер (`flash_state_monitor`/`probe_state`, используется в P1,
   P3c, P4c, P7): `cfg=<md5 config.toml>`, `du=<du -sb $STATE/config
   --exclude=models>`, `files=<find … -name models -prune -o -type f | wc>`,
   плюс наблюдаемость: state_dir, листинг profiles при отсутствии config.toml,
   построчные `top=<du><TAB><имя>` для каждого топ-уровневого entry (БЕЗ
   привязки к имени каталога кэша — orchestrator-момент «под flash виден
   cache/» учтён: замер глобальный, имя каталога НЕ сравнивается).
3. Критерии сравнения: `config.toml` — строго байт-в-байт (это
   per-профильный конфиг, движок его не ротирует); du/files — ГЛОБАЛЬНО с
   толерантностью ≥½ бейслайна: disk-тир ЛЕГИТИМНО ротируется движком
   (.snap TTL/вытеснение при 32 GiB cap — byte-монотонность создало бы
   ложный FAIL), а wipe-поцарапан даст обвал много больше половины.
   ps: `du --exclude=models` обязательно — models это вложенный bind сета
   (~70–100 GB), его активная сторона меняется при use.
4. Косметика консистентности: dry-canned (Mounts `profiles/flash-multi`,
   замер-ответ cfg/du/files/top по живым цифрам FAEX), шапка и RESULT-строка
   («session-cache» → «disk-тир …profiles/<profile>»).

**Валидация.** `bash -n` rc=0; shellcheck — только ожидаемые SC2016×16
(quoted-remote стиль); DRYRUN=1 в вариантах {базовый, `HAVE_REBOOT_BOOT=1`,
`HAVE_REBOOT_BOOT=1 SKIP_REBOOT=1`, `SKIP_OFFON=1`} — все rc=0,
`RESULT: PASS`, сеть не трогается (ssh-grep=0), FAIL/ERROR=0; proof
`EXP-003-faex-full.dryrender.txt` перегенерирован (39 rendered-блоков;
IP/ключей нет). **Живая read-only репл на FAEX ДЛЯ ВАЛИДАЦИИ ФИКСА**
(запускался только сам замерный payload, ничего не пишет/не
останавливает; сервер Up 24h healthy): вернул
`state_dir=/home/hipfire/hipfire/profiles/flash-multi`,
`cfg=d2cd5ab80bad9003d36342275e37b8c3`, `du=34156456371`,
`files=109` + top-листинг из РЕАЛЬНОГО каталога — путь и цифры корректны
(md5 = живому статусу, session-cache 32 GiB виден).

**Регресс (round 2-фикс, продукт по-прежнему HEAD `3578c5c` = C1+spec).**
Полный внутренний регресс пере-прогнан при round 1a (несколько часов
раньше) поверх того же не менявшегося продукта — здесь повторно: bash -n
12/12, golden old+new + stub-логи diff=0, cli_parity + usage-golden,
pure_funcs + md5 фикстуры `253c7ac5…`, install_sandbox, bench_py_parity,
ttft_test, DoD-1 grep'ы, shellcheck-multiset == C1, «путь новичка»
(clone→install.sh→диспетчер из стека) — всё зелёно (детали — секция
Round 1a).

Вердикт (round 2): **BLOCKED-EXTERNAL** — EXP-003 исправлен, dry-режимы
зелёные, замер валидирован live read-only реплой. Реальный прогон полным
циклом — при GO (у пользователя уже стоит; машина свободна; E2E до ~90 мин
с учётом mq6-xt докачки ~21 GB). По-прежнему остаётся только фактический
прогон → result-proof → закрытие DoD 11 → DoD 12 → reviewer → C2.
### Round 3 (2026-11-10, ночь): StartedAt-фикс + живая репетиция P1/P1.5 (triage: `test` —
дефект HARNESS'а tester'а; продукт не менялся, машина не потревожена —
сервер Up 24h healthy на всём протяжении раунда, update не начинался:
md5 диспетчера в стеке по-прежнему `cfba2fbf`).

**Разбор.** Второй прогон EXP-003 упал в P1: «StartedAt контейнера не
прочитан». Причина: `grep -oE 'StartedAt: [^ ]+$' | cut -d" " -f2` —
токен-парсер, а `podman inspect -f "{{.State.StartedAt}}"` на хосте
отдаёт МНОГОСЛОВНОЕ значение «2026-11-09 20:53:36.820919951 +0300 MSK»
— совпадений нет никогда. DRYRUN это не ловит: canned-данные были
однословными. **Правило (принимаетсяtester'ом): dry-run покрывает
разметку/render, но НЕ парсеры живых консольных выводов — парсируемые
блоки репетировать live read-only.**

**Исправление (EXP-003, product не тронут).**
1. `startedat_of()`: `sed -n 's/^StartedAt: //p' | tail -1` — вся
   строка до EOL; guard `case ''|"?"*` → FAIL с action-recipe
   (ручная проверка podman inspect / сравнение с P1-значением);
   P2-сравнение — равенство СТРОК (смена StartedAt = recreate был);
   P1-именно живой формат验证ён (см. ниже).
2. Греп-пас EXP-003 на другие «[^ ]+$»-парсеры многословных строк:
   других НЕТ (df avail — одночисловой,('/')[- -oE] у md5/count/lib_mods
   — свои известные форматы).
3. **Два НОВЫХ факта, найденных ЖИВОЙ репетицией** (это и есть окупаемость
   правила):
   - **AWK-память**: `/1048576/1024` — двойное деление килобайт
     (meminfo kB), печать «0.1 GiB» → исправлено на /1048576 → на
     живую репетицию МЕСТО исправлено: «MemTotal: 122.7 GiB /
     MemAvailable: 20.9 GiB» (печать, не гейт);
   - **podman logs → STDERR (критический)**: `podman logs
     hipfire_hipfire_1 2>/dev/null` на FAEX отдаёт ПУСТО (wc -l: 0 строк
     stdout / 3396 строк stderr!) — ВСЕ считалки логов EXP-003 вернули
     бы 0: P1.5 = ложный FAIL («lanes нет»), P4c/P7 = ложный PASS
     («refused=0» при неразличимых логах). Исправлено: 8 мест —
     `podman logs … 2>&1` (как `check_route` в lib/health.sh — там
     сделано правильно с самого начала; EXP-001 evo — принят, на evo
     окружение не проверялось, нулевой риск для него).
4. Гигиена dry: `stat_set`-инициализация dry-состояния теперь только при
   DRYRUN=1 (в real-режиме `$DRY_DIR` не создаётся и писание туда давало
   бы permission-denied-шум в result.txt); dry-canned StartedAt приведён
   к реалистичному многословному формату.

**Живая репетиция (read-only, ssh bash -s, никаких записей/остановок).**
P1+P1.5-ФРАГМЕНТ реального EXP-003 (срез строк 99..до-маркера-P2, реальный
`remote()` → ssh; в payload нет ничего установочного — проверено grep'ом;
`rm -rf` только в trap на несуществующий CLONE) ПРОВЕРЁН ЗАМЕТАНО:
- P1 ЗЕЛЁНЫЙ: профиль flash-multi, health OK, md5 `cfba2fbf` (update не
  начинался), state-замер `profiles/flash-multi` → `cfg=d2cd5ab8…`,
  `du=34156456371 B`, `files=109` + top-листинг (session-cache 32 GiB,
  cache/, registry.cache.json, serve.pid, daemon-pci-*.pid);
  models-листинги (27b: mq6-xt уже на диске — докачка НЕ ожидаема;
  flash: trunk 70.9 GB + 2 PLE — PLE-строк 2), df avail ~1.07 TiB,
  контейнер «Up 24 hours (healthy)», StartedAt строкой целиком;
- P1.5 ЗЕЛЁНЫЙ (после 2>&1): `count=1`, бейслайн-строка
  `qwen4 fn-lanes staged: topology=single lanes=4 row_budget=4 spec=mtp
  K=7 sampled=true policy=…` — фактический формат зафиксирован в отчёте;
  с продуктовым `check_route` (grep `topology=[a-z]+ lanes=[0-9]+…`)
  совместим — topology=single под паттерн попадает;
- P2-StartedAt-фрагмент (read-only payload) — живо: StartedAt P2 ==
  StartedAt P1 (строчное равенство), `lanes_p2=1` == бейслайн;
- `qwen4 lanes refused`: 0 ✓; `/stats` healthy (894 served,
  recent_tok_s 54.8 — не моего прогона, редкий живой трафик).

**Валидация EXP-003 после правок**: `bash -n` rc=0; shellcheck —
по-прежнему только SC2016×16; DRYRUN=1 ×4 варианта — все rc=0, RESULT:
PASS, FAIL/ERROR=0, сети нет; proof `.dryrender.txt` перегенерирован
(39 блоков, IP/ключей нет). Файл теперь 992 строки.

**Регресс (round 3, продукт по-прежнему HEAD `7e912d5` = C1 + spec).**
Полный внутренний набор неизменного продукта пере-прогнан в Round 1a/2
(bash -n 12/12, golden 4×7 + stub-логи, cli_parity + usage-golden,
pure_funcs + md5 фикстуры, install_sandbox, bench_py_parity, ttft_test,
DoD-1 grep'ы, shellcheck-multiset == C1, «путь новичка») — продукт
инвариантен (diff `4ad0519..HEAD -- . ':!spec'` = пусто), деградации нет.

Вердикт (round 3): **BLOCKED-EXTERNAL** — StartedAt-парсер исправлен и
проверен на ЖИВОМ многословном значении; два новых факта (stderr-логи
podman, meminfo kB) закрыты; правило «парсируемые блоки репетировать
live read-only» принято. Фактический полный прогон EXP-003 — по-прежнему
у оркестратора (GO стоит; риск повторного P1-pадения снят: P1/P1.5/
P2-StartedAt live-зелёные read-only) → DoD 11 → DoD 12 → reviewer → C2.
### Round 4 (2026-11-10, вечер): `\$CLONE`-экранирование в генерационном
heredoc (triage: `test` — дефект HARNESS'а tester'а; продукт не тронут
(`git diff 4ad0519..HEAD -- . ':!spec'` = пусто); машина мутирована
ШТАТНЫМ шагом P2: update УСПЕШНО выполнился — в стеке FAEX диспетчер
C1 `cd623950`, lib×10 + tpl×6, симлинк на месте; сервер НЕ останавливался
(live check оркестратора: контейнер Up 24h, StartedAt НЕ менялся, health
ok, flash-multi, lanes count=1) — **P2-результат первого прогона ВАЛИДЕН
и остаётся приёмочным состоянием, повтор не нужен**).

**Разбор.** Прогон 3 упал в P2 ПОСЛЕ успешного update: `bash: line 17:
CLONE: unbound variable`. Причина: в ГЕНЕРАЦИОННОМ unquoted-heredoc
(`upd_script=$(cat <<EOS …)`) grep-гейт был записан
`grep -q '…' "\$CLONE/lib/engine.sh"` — `\` перед `$CLONE` сделал
переменную БУКВАЛЬНОЙ (`"$CLONE/..."` ушла на remote как текст, где
CLONE нет; `set -u` на remote → смерть). Остальные `$CLONE`/`$REPO` в
том же heredoc были раскрыты при генерации правильно (rm/clone/cd/
md5_clone отработали — отсюда и живой upd_out в result.txt).
**Правило (принимается tester'ом): в генерационных heredoc'ах путь-
переменные локального происхождения пишутся `$X` (раскрытие при
генерации); всё, что вычисляется on-host — только `\$(…)`. Экранирования
`\$` в генерации допустимы СТРОГО для remote-переменных, а по переменным
двух контекстов надо ходить отдельным grep'ом после каждой сборки
payload (вдобавок к `bash -n` и dry-run — dry это не ловил: canned
вернул UPDATE_OK по маркеру install.sh, минуя гейт как отдельный
экран)).**

**Исправление.** Единственный по существу фикс (в версии прогон-3 —
строка 565; после шапки-урока fix-r4 — 569):
`"\$CLONE/lib/engine.sh"` → `"$CLONE/lib/engine.sh"`. Греп-пас EXP-003 на
`\$CLONE` / `\$REPO` / `\$EXPECT` и вообще путь-переменные в heredoc'ах:
живых лишних экранирований не осталось — все генерационные (rm 550,
clone 552, cd 553, md5 560, gate 565); все on-host-переменные
(`\$HOME/\$LOG/\$S/\$a/…`) — правильно экранированы. В шапку
EXP добавлен урок fix-r4.

**Валидация (без повторного update на хосте — его не нужно; он штатно
повторится при полном прогоне оркестратора).**
1. **Парсинг живого upd_out** (артефакт реального прогона 3
   `.result.txt`): экстракции PARSER-блока EXP-003 на настоящих данных —
   `clone_commit=92920d5`, `md5_after=cd623950…` (полностью
   `cd62395079f03152e07b693abe71da3c`; stack==clone),
   `lib_mods=10`, `tpl_dirs=6` — всё как требует EXP.
2. **Гейт-реплика без хоста**: `grep -q 'cfgset serve.batch_nonexact false'
   lib/engine.sh` против ЭКВИВАЛЕНТА клона FAEX: workspace
   `lib/engine.sh` md5 `077e3933` == `git show origin/main:lib/engine.sh`
   md5 (origin/main = 92920d5 — то, что клонировалось на хосте) — строка
   в дереве есть, гейт при повторном P2 пройдёт.
3. Скриптцел: `bash -n` rc=0; shellcheck — по-прежнему SC2016×16;
   `DRYRUN=1` ×2 (и `HAVE_REBOOT_BOOT=1`) — rc=0, FAIL=0, сеть не
   тронута; proof `.dryrender.txt` перегенерирован (39 блоков, IP/ключей
   нет). Файл 996 строк.

**Доп. факт (оркестратора) в базу**: GitHub main = `92920d5` (содержит
C1 `4ad0519`; md5 диспетчера хоста после update = `cd623950` =
ожиданию EXP). Локальные spec-only коммиты (12e9cf5…b5b9bce) push'у
сейчас недоступны (host key verification) — на продукт и гейты EXP НЕ
влияет: генерационная планка EXP-003 = только md5 диспетчера (из клона).
Публикация их push — при восстановлении host access.

Вердикт (round 4): **BLOCKED-EXTERNAL** — гейт-фикс внесён и валидирован
по реальному upd_out; P2-усыпь (stack C1, lanes целы) остаётся живым
состоянием, с которого штатно продолжит полный прогон оркестратора (GO
пользователя стоит; P2 при повторе идемпотентен и теперь пройдёт гейт).
Остаётся: полный прогон EXP-003 → result-proof → закрытие DoD 11 →
DoD 12 → reviewer → C2.

## DoD 11 — external run (оркестратор, 2026-11-10): EXP-003 прогон 4 → PASS
Четвёртый запуск EXP-003 (после fix-раундов 1–4) на che-FAEX1, `HAVE_REBOOT_BOOT=1`, rc=0:
P1 пред-чек (flash-multi healthy, mq6-xt уже на диске) → P1.5 lane-бейслайн → P2 update
из свежего клона GitHub main (UPDATE_OK; lib=10/tpl=6, md5 клон==стек=cd623950…; сервер не
останавливался, StartedAt не менялся) → P3 use 27b-single (singleton+DFlash, smoke OK;
disk-тир flash цел) → P4 use flash-multi (строгий идемпотентный pull без докачек;
`fn-lanes staged` вернулись; конфиг flash байт-в-байт d2cd5ab8…) → P5 off/on →
P6 ребут (sudo -n) → сам-подъём boot-юнитом из дерева, `_boot` exit 0 → health + smoke +
lanes → P7 финал: flash-multi, refused=0, прод recovered.
DoD 11 ЗАКРЫТ. Артефакт: hflab/.local-analysis/task8-exp/EXP-003-faex-full.result.txt
(260 строк). История убитых прогонов 1–3: *-p1fail-keep / *-run2-startedat-keep / git-история.
