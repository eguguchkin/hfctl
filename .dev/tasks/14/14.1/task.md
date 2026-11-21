# Task: 14.1 лейаут v2 по идеологии gfctl — клон = стек, bootstrap = первый `hfctl on`, uninstall v2   Design: architect

## Scope and DoD

Цель — лейаут gfctl (решение 4.4, `.dev/tasks/4/4.4-layout-python-decision.md`,
РЕШЕНО 2026-11-19/20, апрув пользователя по PLAN «Этап 14 (ПОСЛЕ АПРУВА)»):
одна папка = git-клон = STACK_DIR = место запуска; всё состояние машины —
внутри `.data/` (вне git); фаза install (install.sh + `hfctl install`)
упраздняется, bootstrap — первый `hfctl on`; uninstall — v2-семантика
(снимает привязки, не трогает данные). Наработки 13.1/13.2 (Ф1–Ф5, gpu_prep,
батарея-каркас) переиспользуются, не выбрасываются. Машины не трогать —
миграция (Design §М) — отдельное деплой-окно по GO пользователя. Не коммитить.

Файлы диффа — ровно: `hfctl` (диспетчер: глобалы, usage-шапка, роутер),
`install.sh` (УДАЛИТЬ), `lib/commands.sh` (cmd_bootstrap ← cmd_install, use,
doctor-строка, uninstall v2), `lib/autostart.sh` (cmd_on, лок-пути,
cmd_autostart — минус sync_tree/копия conf), `lib/stack.sh` (compose() — путь
conf), `lib/stack_files.sh` (sync_tree — УДАЛИТЬ, write_stack_files — каркас
.data, минус копия conf, prompt_vol-путь), `lib/bench.sh` (OUT-дефолт +
комментарии), `tpl/systemd/hipfire-compose.service.tpl` +
`tpl/systemd/hipfire-compose-watchdog.service.tpl` (Environment-путь conf),
`.gitignore` (+`.data/`, +`.env`), `tests/run_checks.sh`, `README.md`,
`AGENTS.md`, `.dev/SPEC.md` (spec-honesty). **НЕ трогать**:
`tpl/compose/compose.yml` и `tpl/compose/compose.halo.yml` (mandated
byte-identity 0.4.5/0.4.6/0.4.7, F-0.4.7.3), `tpl/etc/hfctl-containers.conf`,
`tpl/etc/99-hipfire-memlock.conf.tpl`, `tpl/bench/*` (md5-канон),
`lib/health.sh` / `lib/models.sh` / `lib/state.sh` / `lib/profiles.sh` /
`lib/engine.sh` (глобал-консьюмеры — путей не содержат), `.dev/STATE.md`
(оркестратор).

DoD:
1. **STACK_DIR-механика** (диспетчер): `STACK_DIR="${HFCTL_DIR:-$(dirname
   "$SELF")}"` — клон = стек, запуск работает из любого подкаталога клона;
   env-крючок `HFCTL_DIR` сохраняется (selfcheck/миграция, прод не задаёт).
   Новые дефолты: `MODELS_BASE=$STACK_DIR/.data/models`,
   `STATE_BASE=$STACK_DIR/.data/profiles`, `STOP_MARKER=$STACK_DIR/.data/.hfctl-stopped`;
   новый глобал `DATA_DIR="$STACK_DIR/.data"`. Лок-файл: все три упоминания
   `$STACK_DIR/.hfctl.lock` (autostart.sh:309/385/451) → `$DATA_DIR/.hfctl.lock`.
   Bench: OUT-дефолт `$STACK_DIR/bench-runs` → `$DATA_DIR/bench-runs`
   (bench.sh:658 + три строки-комментария 33/42/571).
2. **install упразднён**: `install.sh` удалён из репо; роутер: `install)`
   → `cmd_on` (скрытый алиас, строка в ряду с up|down|autostart); usage-шапка:
   quickstart = `git clone … && cd hfctl && ./hfctl on`, строки про install.sh
   и `hfctl install` сняты, `on` описан как «поднять стек (на пустом —
   bootstrap)»; `cmd_install` → `cmd_bootstrap` (переименование тела, Design §Б);
   die-тексты-указатели: cmd_use:134 и cmd_doctor («НЕ УСТАНОВЛЕН …») —
   «сначала 'hfctl on'».
3. **Bootstrap первого `on`** (Design §Б): при отсутствии `.env` — полный
   путь: RAM-гейт → set_models_dir → preflight (apt-пятёрка + gpu_prep 13.2)
   → write_stack_files (каркас `.data` + compose-тройка) → write_env → pull
   образа/моделей → up → apply_profile → force-recreate → health 900 → smoke
   → check_route → юниты ПОСЛЕДНИМИ (cmd_autostart). Юниты-последними —
   сознательное отклонение от наброска PLAN («юниты до контейнера»):
   обоснование — Риск Р1. На установленном стеке `on` ведёт себя как сегодня
   (cmd_autostart + cmd_up); флаги-мутаторы (--profile/--port/--bind/
   --models-dir) и --no-autostart на установленном стеке → die с подсказкой
   (`use` / «on = автозапуск»).
4. **Uninstall v2** (Design §У): снимает юниты+таймер, контейнер/сеть
   (compose down), linger, limits.d (13.2-файл) — и ВСЁ; НЕ трогает: клон
   (ни одного rm в STACK_DIR!), `.data/`, образ, симлинк `~/.local/bin/hfctl`.
   Флаги --purge-models (→ rm -rf `.data/models`) / --purge-image /
   --yes сохранены; экран подтверждения переписан под v2.
5. **Ф5-conf — производная копия упраздняется** (Design §Ф): `compose()`
   (stack.sh:41) и `Environment=` обоих юнит-tpl ссылаются на
   `$STACK_DIR/tpl/etc/hfctl-containers.conf` (tracked-файл клона — существует
   всегда, §14-инвариант «conf до подъёма» выполняется фактом клона);
   копирование в write_stack_files (stack_files.sh:161) и cmd_autostart
   (autostart.sh:232) удалено. `sync_tree` удалён целиком (stack_files.sh:76-88)
   вместе с вызовами (write_stack_files:148, cmd_autostart:229); `ensure_symlink`
   остаётся (PATH-точка, зовётся из write_stack_files).
6. **.gitignore**: + `.data/`, + `.env` (существующие строки не трогать).
   `git clean -fd` безопасен (всё машинное — игнор); `git clean -fdx`
   удаляет `.data/` — запрещённая команда, README-warning. «Одна инсталляция
   на юзера» (имя контейнера `hipfire_hipfire_1`, порт 11435, имена юнитов
   `hipfire-compose*` — глобальны) — README-документация, кодом не решается.
7. **Миграция** (Design §М): процедура одношагового переезда ~/hipfire →
   ~/hfctl-клон зафиксирована как раздел контракта (SPEC §15 + README);
   ИСПОЛНЕНИЕ — отдельное окно по GO, в этом раунде не выполняется.
8. **Батарея**: 40 сохранённых тестов с обновлёнными путями/ассертами (F5 —
   новый tpl-путь conf; P-сценарии зовут preflight напрямую — не меняются;
   сценарии off/boot/watchdog — пути через глобалы — не меняются) + 9 новых
   (Test strategy §Т). Счётчик зафиксирован: **PASS = 49, FAIL = 0**;
   отклонение от 49 — обосновать в dev-report.
9. **SPEC в той же дельте** (spec-honesty): И1 переформулирован («первый
   `hfctl on` из клона; install.sh упразднён»), И3 дополнен («после миграции
   этапа 14 стек = клон — автоматичен»); §2 (дистрибуция: новый quickstart,
   лейаут с `.data/`, таблица «вне каталога»), §3 (карта команд: on-bootstrap,
   uninstall v2), §4 (.env в клоне, install→on формулировки), §14 (механизм
   conf — tpl-путь клона), новый §15 «Лейаут v2 и миграция», §10 — дополнен
   абзацем этапа 14. README (quickstart, команды, лейаут, warnings) и
   AGENTS.md («Что в репо» без install.sh, правило 5: обновление = git pull +
   recreate через use/off/on) — той же дельтой.

Вне скоупа (идеи — в dev-report Out-of-scope, не в код): каркас `.data/logs`
(писателя нет — логи живут в journalctl/`podman logs`; В1); исполнение
миграции на машинах и обновление llm-lab-скриптов под новые пути
(bench_arms/prompts-маунт — лабораторный хвост, Р4); `doctor`-расширения
(второй-клон-детект и пр. — D11-косметика); новое имя для uninstall;
watch-переделка; python-переезд (триггеры 4.4 не сработали).

## Design

### Лейаут v2 (целевой)

```
~/hfctl/                          # git-клон = STACK_DIR = запуск (./hfctl из корня)
├── hfctl                         # диспетчер; STACK_DIR = dirname(файла)
├── lib/, tpl/, tests/, .dev/     # tracked: код/шаблоны/батарея/борд
├── .gitignore                    # tracked: + .data/, + .env
├── .env                          # канон профиля (write_env; gitignored)
└── .data/                        # ВСЁ машинное состояние (gitignored)
    ├── models/{27b,flash}/       # сеты + draft (mv-переезд с инодами)
    ├── profiles/<профиль>/{config,kernel}/   # движок-хоум: конфиг, disk-тир, pid
    ├── bench-runs/<timestamp>.json           # артефакты bench
    ├── benchmarks/prompts/       # /prompts-маунт (лаба создаёт сама; опционально)
    ├── .hfctl-stopped            # маркер явной остановки (был в корне стека)
    └── .hfctl.lock               # flock up/boot/watchdog (был в корне стека)
```

Инвариант: всё машинное — внутри `.data/`; вне клона остаются только
осознанные исключения (как gfctl 4.4): systemd-user юниты `~/.config/systemd/user/`
(снимают on/off/uninstall), linger, limits.d `99-hipfire-memlock.conf`
(безвредный хвост после uninstall), podman-storage (образ/слои — `podman rmi`
руками), симлинк `~/.local/bin/hfctl`. Каркас `.data/logs` НЕ создаётся —
писателя в hfctl нет (В1).

`hfctl on` из любого каталога клона работает: SELF/STACK_DIR от
`readlink -f "$0"`, cwd не читается (уже так — LIB_DIR/TPL_DIR:61-62; STACK_DIR
присоединяется к той же схеме).

### Б. Bootstrap первого `on` (cmd_on = единая точка)

Разбор: сегодня `cmd_on` (autostart.sh:135) = `cmd_autostart; cmd_up`, а
весь установочный конвейер живёт в `cmd_install` (commands.sh:42-93). v2:

```
cmd_on [--profile P] [--port N] [--bind A] [--models-dir D]
       [--no-autostart] [--force] [--yes]
  parse флагов (парсер переносится из cmd_install:44-55 без изменений)
  if [ ! -f "$STACK_DIR/.env" ]; then
    cmd_bootstrap "$@"        # см. ниже — конвейер сегодняшнего install
  else
    # guard: стек уже установлен
    [ флаги --profile/--port/--bind/--models-dir заданы ] →
      die "стек уже развёрнут; профиль/параметры меняет 'hfctl use <профиль>'"
    [ --no-autostart ] → die "'on' — это автозапуск; поднять без него: 'hfctl up'"
  fi
  [ no_autostart = 1 ] && { echo "(автозапуск не включён — '--no-autostart'; включить: hfctl on)"; return 0; }
  cmd_autostart               # юниты+таймер+linger (юнит-tpl рендерятся с путями клона)
  cmd_up                      # rm маркера + hf_up_locked + wait_health 600
```

`cmd_bootstrap` = тело сегодняшнего `cmd_install` (commands.sh:42-79) с
ровно тремя изменениями: (а) хвост-развилка `if no_autostart…else
cmd_autostart` (commands.sh:74-78) удаляется из функции — юниты ставит
вызывающий cmd_on после health (см. Р1); (б) переименование; (в) write_stack_files
внутри изменилась (каркас .data, без sync_tree/копии conf). Порядок фаз,
таймауты (900/600), тексты, exit 42-механика (preflight умирает ДО write_env
— commands.sh:35) — байт-в-байт сегодняшние. `hfctl use`: die-текст меняется,
логика не трогается (в т.ч. откат канона, «уважение» старой базы моделей).

Повторный `on` после оборванного bootstrap (pull умер, exit 42 и т.п.):
`.env` не записан → ветка bootstrap снова; идемпотентно (preflight no-op,
файлы перезаписываются, pull доносит). Флаги (--profile/--port/…) надо
повторить — инструкция в сообщении об ошибке не дублируется (как сегодня).

### Р1. Watchdog при bootstrap — почему юниты последними

Набросок PLAN («юниты до контейнера») отклонён сознательно. Если enable
юнитов и старт watchdog-таймера (OnBootSec=2min) случится ДО первого up, то
на машине с долгим bootstrap (pull образа+моделей, 15–40 мин) первый тик
`_watchdog` увидит: контейнера нет, маркера нет → полезет поднимать → встанет
в flock → через `LOCK_STALE_SECS` (900 c, 13.1-Ф3) `hf_lock_reclaim`
убьёт `hfctl`-держателя — то есть сам bootstrap — и начнёт параллельный up.
Это ровно класс «ручные корректировки», который запрещает И2. Сегодняшний
порядок install (cmd_autostart последним, после health/smoke) гонку исключает:
таймер активируется на здоровом стеке. v2 сохраняет порядок — cmd_on зовёт
cmd_autostart только после cmd_bootstrap (успешного). STOP_MARKER при
bootstrap: ветка маркер не создаёт и не снимает (снимет cmd_autostart:246 /
cmd_up); юнитов до health нет — взойти само нечему.

### Ф. Ф5-conf (CONTAINERS_CONF) — третья опция: производной копии нет вовсе

Варианты «.data/…» или «корень+gitignore» оба сохраняют производный файл —
двойную истину с `tpl/etc/hfctl-containers.conf`. В v2 клон = стек, поэтому
оба потребителя читают tracked-файл клона напрямую:
- `compose()` (stack.sh:41): guard и export — путь
  `$STACK_DIR/tpl/etc/hfctl-containers.conf` (условный export сохраняется —
  дёшево и честно для кривого дерева);
- оба юнит-tpl: `Environment=CONTAINERS_CONF=__STACK_DIR__/tpl/etc/hfctl-containers.conf`
  (`__STACK_DIR__` рендерится в путь клона — плейсхолдеры не меняются);
- строки `install -m 0644 … hfctl-containers.conf` в write_stack_files
  (stack_files.sh:161) и cmd_autostart (autostart.sh:232) удалены вместе с
  комментариями-маркерами `# fix:containers-conf`.

§14-инвариант «conf существует до подъёма/рендера юнитов» выполняется тем,
что оба пути — внутрь tracked-клона (`git clean -fd` untracked не трогает).
Экспорт в субшелл compose, «глобальный ~/.config не трогается» — без изменений.

### У. Uninstall v2 (cmd_uninstall, commands.sh:482)

Новый состав (порядок): экран подтверждения (v2-текст: «снимет юниты+
таймер, контейнер и сеть проекта, linger, limits.d; ОСТАВИТ клон, `.data/`
(модели/профили/bench-runs), образ, симлинк»; перечень purge-флагов) →
ask/--yes → `cmd_off || true` (стоп + юниты + linger; Ф1-двойной стоп
сохранён) → `compose down` в субшелле с cd (сеть проекта; `|| true`) →
limits.d `sudo rm -f` → purge-флаги: `--purge-models` → `rm -rf
"$DATA_DIR/models"` (только models-сет-база; profiles целы),
`--purge-image` → `podman rmi` (как сегодня). **Удалены** v1-элементы:
перенос `$MODELS_BASE` в `$STACK_DIR.hfctl-models-$$` и `rm -rf
"$STACK_DIR"` (commands.sh:503-509) — клон не сносится никогда (это git-репо
с бордом). `.hfctl-stopped`/`.hfctl.lock` в `.data/` переживают uninstall —
безвредные пустые файлы. Скрытых новых алиасов нет (up|down|mode|autostart|
noautostart — как есть; `down` = stop_with_marker, семантика не меняется).

### М. Миграция FAEX/evo (контракт процедуры; исполнение — отдельное окно по GO)

Предусловия: ~/hfctl-клон на машине есть (И3-факт 2026-11-21), ~/hipfire-стек
с models/profiles/.env, старый бинарь жив. Порядок (один заход, даунтайм):

```
hfctl off                                # старый бинарь: стоп, юниты, linger
cd ~/hfctl && git pull                   # код v2 (И3; install.sh в клона нет)
mkdir -p .data
mv ~/hipfire/models   .data/models       # mv в пределах /home — иноды целы
mv ~/hipfire/profiles .data/profiles
[ -d ~/hipfire/bench-runs ] && mv ~/hipfire/bench-runs .data/bench-runs
#   НЕ переносить: .env, compose*.yml, .hfctl-containers.conf, бинарь+lib+tpl,
#   маркеры (.hfctl-stopped/.hfctl.lock — мусор старого стека)
./hfctl on --profile <id из старого .env> [--port N --bind A]   # если не дефолт
#   bootstrap: preflight = no-op (машина готова) → compose-тройка в клона
#   → .env заново (пути .data) → pull пропущен (всё локально) → up →
#   healthy ~20 c → smoke → юниты. Симлинк ~/.local/bin/hfctl → ~/hfctl/hfctl
#   ставит ensure_symlink. Конфиг движка (config.toml, cfgset-ключи) переехал
#   с profiles mv — apply_profile переподтверждает канон.
./hfctl doctor && ./hfctl status         # healthy; затем reboot-приёмка окна
rm -rf ~/hipfire                         # старый стек — после healthy
```

Примечания к И-инвариантам: mv-шаги — часть задокументированной процедуры
(плановые, не «внеплановые ручные»); приёмка ПОСЛЕ миграции — чистая
последовательность обвязки (off/on/status/doctor + reboot), И2 соблюдён.
Потерянные кастомизации ограничены портом/bind/дефолтной моделью (их несли
старые .env) — передаются флагами/env первого on; конфиг движка не теряется
(переезжает с profiles). И3 после миграции автоматичен: git pull = обновление
кода; пересборка мира не нужна — use/off-on делает recreate. Процедура
двусторонняя симметрия не требует: отката нет (mv не удаляет иноды; до
`rm -rf ~/hipfire` всё обратимо mv-назад).

### Доки (та же дельта)

- README: quickstart (`git clone && cd hfctl && ./hfctl on [--profile …]`),
  таблица команд (install → on; uninstall v2-формулировка), раздел «Лейаут»
  (таблица выше + «вне каталога»), warnings: `git clean -fdx` удаляет
  `.data/` — запрещён; одна инсталляция на юзера (контейнер/порт/юниты
  глобальны; второй клон = конфликт при up); bench-runs в `.data/bench-runs`.
- AGENTS.md: «Что в репо» — без install.sh; бинарь живёт в клоне
  (`~/hfctl/hfctl`, симлинк в bin); правило 5 → «обновление дерева: git pull
  в клоне; recreate — use (или off/on); ручной cp не нужен и вреден»;
  шапка-quickstart.
- SPEC — список в DoD 9. `tpl/compose/compose.yml` fallback
  `${HIPFIRE_STATE_DIR:-$HOME/hipfire/profiles/27b-single}` — мёртвая ветка
  в v2 (write_env всегда пишет ключ), golden не трогается (Р3).

## Test strategy

Вся батарея — faux-PATH harness 13.x (никаких podman/systemctl/sudo/машин;
HOME/USER в $TMP; unshare-обёртка os-release). Пути-глобалы harness инжектит
(`STACK_DIR=$HF_STACK…`) — при новых дефолтах harness-присвоения обновить:
`STATE_BASE="$HF_STACK/.data/profiles"`, `STOP_MARKER="$HF_STACK/.data/.hfctl-stopped"`
(run_checks.sh:235-237) и пути-ассерты F5.

| DoD | внутренний чек | внешнее (EXP-хвост деплой-окна, вне раунда) |
|---|---|---|
| 1 STACK_DIR | N7; запуск из подкаталога клона (копия дерева в $TMP, вызов `$TMP/x/sub/hfctl`-аналог через harness-глобалы) | миграция-окно: `./hfctl on` из клона на машине |
| 2 install упразднён | N8, N9 (файл install.sh отсутствует; usage без него) | — |
| 3 bootstrap-first-on | N1 (happy: журнал фаз в порядке Б, файлы/юниты/маркер), N2 (идемпотент: .env есть → preflight-журнал пуст), N3 (guard мутаторов), N4 (модели на месте → pull-журнал пуст) | EXP: чистая машина / no-op на FAEX/evo |
| 4 uninstall v2 | N5 (юниты/linger/limits/down; .data и образ целы), N6 (purge-флаги) | EXP: uninstall на машине без сноса .data |
| 5 Ф5-conf tpl-путь | F5-ассерты обновлены (scen_f5_deliver/f5_env: env CONTAINERS_CONF = tpl-путь), мутация containers-conf по новым местам | живой up под AppArmor-багом (§14-EXP прежний) |
| 6 gitignore/чистота | N7 (+ проверка `git status --porcelain` пуст на свежем клоне с .data — в EXP-окне; батарея — статика файла) | EXP: `git clean -fd` после прогона не трогает .data |
| 7 миграция | батарея N4 (pre-populated .data) — механика «модели на месте»; сама процедура — контракт | деплой-окно по GO: полный §М + reboot |
| 8 счётчик | `bash tests/run_checks.sh` → `ИТОГО: PASS=49 FAIL=0` | — |
| 9 доки/SPEC | ревью: сверка списка DoD 9 против файлов; противоречий grep'ом (install.sh, ~/hipfire-пути в README/AGENTS/SPEC §2-4) быть не должно (исторические секции §9/§13/§13.2 не считать) | — |

Новые тесты (мутационная конвенция 13.x сохраняется: на новую логику —
позитив + `# fix:<имя>`-мутация на копии дерева → сценарий обязан падать):
N1 bootstrap-happy; N2 bootstrap-idempotent (второй on); N3 on-мутаторы-guard;
N4 bootstrap с готовым `.data/models` (мигра-сценарий); N5 uninstall-v2-щадящий;
N6 uninstall purge-флаги; N7 gitignore-статика + глобалы в .data
(STOP_MARKER/lock/MODELS_BASE/STATE_BASE/OUT); N8 роутер `install`→cmd_on
(статика строки роутера + поведение: код через «install»-путь даёт журнал N1);
N9 install.sh-отсутствие + usage-ассерты. Мутационные маркеры новых защит —
по схеме 13.1 (`# fix:bootstrap-guard`, `# fix:uninstall-v2` и т.п. — точные
имена за developer'ом, инвентарь маркеров в шапке батареи пополняется).

## Risks and rollback

- **Р1 watchdog-гонка при bootstrap** — снят порядком «юниты последними» (§Р1);
  тест N1 ассертит: cmd_autostart-журнал ПОСЛЕ smoke/check_route.
- **Р2 STOP_MARKER/лок переезжают в .data** — читаются только через глобалы
  диспетчера (autostart.sh 309/385/451 + STOP_MARKER), разрыва старых машин
  нет: старый стек до миграции работает старым бинарем со старыми путями.
- **Р3 compose.yml fallback `$HOME/hipfire/…`** — мёртвая ветка (write_env
  пишет HIPFIRE_STATE_DIR всегда); golden не трогаем (F-0.4.7.3
  byte-identity) — иначе сломается mandated-проверка и приёмка образа.
- **Р4 bench-prompts-маунт** — путь в compose.local.yml меняется на
  `./.data/benchmarks/prompts`; лабораторные скрипты (llm-lab bench_arms/
  slot_ab) создают каталог в старом месте — обновление лабы = хвост окна
  миграции (out-of-sub-stage, оркестратору в llm-lab).
- **Р5 mv через ФС-границу** — процедура §М запрещает (иноды); ~/hipfire и
  ~/hfctl — одна /home, контроль — `df`-строка в чек-листе окна.
- **Р6 слепые ссылки на install** — README/AGENTS/SPEC/usage обновляются
  той же дельтой; EXP-скрипты старых окон (EXP-104…) устаревают естественно
  — при следующих окнах перегенерировать (не в этом раунде).
- **Откат** — git: ветка/коммит этапа 14 не пушится до приёмки; на машинах
  ничего не меняется, откат = `git checkout` в клона разработки. Прод-машины
  до окна миграции живут v1-лейаутом на старом бинаре — совместимости
  «новый код на старом стеке» не требуется (и не тестируется): первая
  команда нового кода на машине = первый шаг §М после `hfctl off`.

## References

- PLAN «Этап 14 — лейаут v2 (идеология gfctl) (ПОСЛЕ АПРУВА)»
  (.dev/PLAN.md:448-478) — исходный список, открытые вопросы закрыты этим
  файлом (install → скрытый алиас on; models-дефолт `.data/models`;
  conf — tpl-путь клона; bench-runs → .data; второй-клон — README).
- gfctl `.dev/tasks/4/4.4-layout-python-decision.md` (РЕШЕНО 2026-11-19/20) —
  принцип-источник: инвариант «всё в клоне» + таблица исключений; упразднение
  install.sh; юниты при первом запуске; `git clean -fd`-безопасность;
  uninstall-объём; одна инсталляция на юзера; mv-миграция с инодами.
- SPEC: «Инварианты поставки» (И1/И2/И3, :369) — И1-переформулировка и И3-
  дополнение в этой дельте; §2 (:19) дистрибуция; §3 (:52) карта команд;
  §4 (:79) модель состояний; §14 (:303) — conf-инвариант; §6.3/§9 — без
  изменений.
- Код (проверено 2026-11-21, HEAD bc34b97): hfctl:37-43,57-62 (STACK_DIR/
  MODELS_BASE/STATE_BASE/STOP_MARKER/SELF), commands.sh:42-93 (cmd_install),
  :124-172 (cmd_use), :332-398 (doctor-строка), :482-516 (cmd_uninstall),
  autostart.sh:84/103/119/135/167-184/224-249/309/385/451 (on/off/up/локи/
  autostart), stack.sh:39-42 (compose-conf), :135-162 (gpu_prep), :195-222
  (preflight), stack_files.sh:76-88 (sync_tree), :104-108 (ensure_symlink),
  :142-172 (write_stack_files), :206-211 (write_env), bench.sh:658 (OUT),
  run_checks.sh (harness :225-249, счётчик 40).
- FACTS: F-0.4.7.3 (byte-identity compose-голденов — граница «tpl/compose
  не трогать»). DECISIONS 2026-11-13 (D11-объём) — не расширяется.

## Open questions

Блокирующих нет (апрув пользователя по PLAN есть). Не-блокирующие
фиксации:
- **В1 `.data/logs`**: PLAN называет `logs` в составе `.data/` — писателя в
  hfctl нет (логи сервера = journalctl/`podman logs`; watch читает HTTP).
  Решение: каркас не создаётся; появится файловый логер — отдельный шаг.
  Если пользователь на приёмке захочет каталог «на будущее» — mkdir пустышка,
  одна строка в write_stack_files.
- **В2 имя `install`**: оставлен скрытым алиасом `cmd_on` (1 строка роутера)
  вместо полного удаления — старые EXP-скрипты/заметки не ломаются, помощи
  команда не занимает. Альтернатива «удалить вовсе» — тривиальный реверс.
- **В3 `--models-dir`/`HFCTL_MODELS`** — сохраняются (нестандартная база);
  v2-дефолт — `.data/models`. «Уважение старой базы» в use (commands.sh:146-154)
  не трогается — мигрированные машины проходят через свежий write_env и в
  legacy-ветку не попадают.
