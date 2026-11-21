# Task: 13.1 hardening — самолечение аномалий подъёма/остановки (5 фиксов)   Design: architect

## Scope and DoD

Цель — инцидент 2026-11-21 (evo, прод вниз ~5 ч) не должен повторяться
молча: каждый класс «аномалия → самолечение → retry», поведение сервера и
happy-path не меняются. Файлы диффа — ровно: `lib/autostart.sh`,
`lib/stack.sh`, `lib/stack_files.sh`, `tests/run_checks.sh` (НОВЫЙ),
`tpl/etc/hfctl-containers.conf` (НОВЫЙ), оба `tpl/systemd/*.service.tpl`,
`.dev/SPEC.md` (spec-honesty). Машины не трогать (деплой — отдельное окно).

DoD:
1. **Ф1 off**: после compose stop в `cmd_off` — явный останов основного
   контейнера (глобал `CONTAINER`), отказоустойчиво и тихо; compose stop
   упал → контейнер всё равно stopped; `hfctl off` доходит до своих
   финальных строк при любом rc остановки.
2. **Ф2 storage-сирота**: оба up-пути (`hf_up_locked`, `hf_up_devsafe`)
   распознают `…already in use by <ID> … external entity` → удаляют сироту
   `containers-storage delete-container <ID>` (ID только если libpod его
   НЕ видит) → retry up; кап самолечений за процесс; бинаря нет → WARN с
   ручной командой, поведение как прежде.
3. **Ф3 lock**: при занятом `$STACK_DIR/.hfctl.lock` — идентификация
   держателей (fuser/lsof), `kill -9` только если держатель старше
   `LOCK_STALE_SECS` И его cmdline ~ `podman|hfctl`; свежий (здоровый
   параллельный boot/watchdog/up) — не тронут; нет fuser/lsof — тихая
   деградация к прежнему поведению.
4. **Ф4 pod**: перед up в обоих путях — `podman pod inspect pod_hipfire`;
   `InfraContainerID` пуст → `podman pod rm -f pod_hipfire` → штатный up
   пересоздаст; pod нет/inspect отказал → no-op.
5. **Ф5 CONTAINERS_CONF**: файл `[network] default_rootless_network_cmd =
   "slirp4netns"` поставляется в `$STACK_DIR/.hfctl-containers.conf`
   (write_stack_files + cmd_autostart), `Environment=CONTAINERS_CONF=…`
   в обоих юнит-шаблонах, экспорт в `compose()` (только при наличии
   файла). Глобальный `~/.config/containers` не трогается.
6. **Батарея** `tests/run_checks.sh`: AGENTS-четыре (bash -n, py_compile,
   usage rc=1, status --json на чанковом порту) + на КАЖДЫЙ фикс
   позитив-сценарий и мутационная проверка («вырежи фикс → ассерт падает»);
   зелёная: FAIL=0, PASS ≥ 10 (счётчик в dev-report).
7. **Spec-honesty**: SPEC.md правится в том же дельта (§3 строки off/up +
   новая §14 «Самолечение аномалий», текст ниже в Design).

Вне скоупа (идеи — в dev-report Out-of-scope): фикс 1 для `hfctl down`
(та же экспозиция, но в перечне оркестратора нет — отдельным пунктом);
замер скорости pull под slirp4netns (EXP-хвост при деплое); AppArmor-
профиль pasta (дистрибутивный фикс, решение пользователя); сценарий
«хвост попытки до дедлайна» в cmd_boot.

## Design

Все константы-крючки — в шапке `lib/autostart.sh` рядом с
`GPU_WAIT_TIMEOUT` (домашний паттерн env-оверрайдов для selfcheck, продом
не используются):

```bash
LOCK_STALE_SECS="${HFCTL_LOCK_STALE:-900}"   # порог «зависший держатель лока»
HEAL_MAX="${HFCTL_HEAL_MAX:-2}"              # кап storage-самолечений за процесс
HF_ORPHAN_HEALS=0                            # счётчик самолечений (глобал)
```

Порог 900 = `TimeoutStartSec=900` юнита: легитимный держатель лока живёт
≤ ~7 мин бюджета `_boot` (+хвост), юнит по таймауту мёртв, а его
`KillMode=process`-дети (podman/podman-compose, унаследовавшие fd 9) —
выживают и держат лок. Ручной `hfctl up` > 15 мин легитимно невозможен
(образ спиннут 0.4.7; init-pull моделей идёт ВНУТРИ контейнера после
detach). Приянтый риск зафиксирован в Risks.

Каждая защита помечается маркер-комментарием `# fix:<имя>` на своей
строке(ах) — по нему мутационная батарея находит и вырезает фикс
(см. Test strategy). Имена: `off-stop`, `orphan-heal`, `lock-reclaim`,
`pod-infra`, `containers-conf` (в stack_files.sh/cmd_autostart — строка
доставки; в unit-tpl маркер не нужен — мутация целим по
`Environment=CONTAINERS_CONF`).

### Ф1 — cmd_off: явный останов основного контейнера

`lib/autostart.sh`, `cmd_off` — сразу после `stop_with_marker … || true`,
до disable юнитов, строка с маркером `# fix:off-stop`:

```bash
podman stop "$CONTAINER" >/dev/null 2>&1 || true
```

Почему так: compose stop при rootless-netns баге (AppArmor pasta denied
signal) падает на init-контейнере до основного → молчаливо неполный stop;
прямой `podman stop` netns-тенидауна проекта не делает и работал всегда
(факт окна 2026-11-21). Контракт `stop_with_marker` (маркер ДО stop,
§13 SPEC «Остановка — одна реализация») не трогается; `down` остаётся как
есть (вне скоупа). Вызов из uninstall (`cmd_off || true`) не ломается —
строка отказоустойчива. Порядок внутри cmd_off прежний: маркер → compose
stop → podman stop → disable/удаление юнитов → daemon-reload → linger.

### Ф2 — storage-сирота «already in use by an external entity»

Хелпер в `lib/autostart.sh`:

```bash
# hf_orphan_heal <up-вывод> — 0 если сирота найдена и удалена; 1 иначе
hf_orphan_heal() {
  local id
  id=$(printf '%s' "$1" | grep -oE 'already in use by [0-9a-f]{12,64}' | head -1 | awk '{print $5}') || return 1
  [ -n "$id" ] || return 1
  [ "$HF_ORPHAN_HEALS" -lt "$HEAL_MAX" ] || return 1        # кап за процесс
  command -v containers-storage >/dev/null || { warn "…containers-storage нет: sudo apt install containers-storage; вручную: containers-storage delete-container $id"; return 1; }
  podman inspect -f '{{.State.Status}}' "$id" >/dev/null 2>&1 && { warn "…ID $id видит libpod — не сирота, самолечение отменено"; return 1; }
  HF_ORPHAN_HEALS=$((HF_ORPHAN_HEALS + 1))
  containers-storage delete-container "$id" && log/storage-warn-строка
}
```

Текст ошибки (GOTCHAS, strace-диагноз): `Error: creating container
storage: the container name "hipfire_hipfire-init_1" is already in use by
<64-hex> … external entity`. Синтаксис хила — по man
`containers-storage-delete-container(1)`: `containers-storage delete-container
containerNameOrID` (флагов -f нет; отказ — WARN, поведение = прежнее).
Guard «libpod видит ID → не трогать» — страховка от удаления живого
контейнера при рассинхроне в другую сторону.

Интеграция:
- `hf_up_devsafe` (boot/watchdog): структура «up → диагноз → один фикс →
  up → inspect» сохраняется, контракт «максимум ДВЕ попытки up на вызов»
  не расширяется: после первого up, если контейнер не running, диагноз
  выбирает ОДНО лечение — либо прежняя девайс-ветка (сигнатура
  `cannot stat|Failed to create container` → `podman rm -f` по лейблу),
  либо новая `hf_orphan_heal` (маркер `# fix:orphan-heal`). Девайс-ветка
  байт-в-байт прежняя.
- `hf_up_locked` (ручной up/on): `compose up -d 2>&1 | tail -2` → захват
  вывода в переменную; при сигнатуре сироты → heal → один retry up.
  Семантика «занятый лок → пропуск, rc 0» сохранена.

### Ф3 — flock: реклейм зависших держателей

Хелпер `hf_lock_reclaim` в `lib/autostart.sh` (вызывается в ОБОИХ
up-субшеллах только при НЕУДАЧЕ первого `flock -n` — happy-path без
аномалий не порождает ни одного лишнего процесса):

```bash
hf_lock_reclaim() {
  local pids p age args
  pids=$(fuser "$STACK_DIR/.hfctl.lock" 2>/dev/null) || return 0
  # нет fuser — пробуем lsof; нет ни того ни другого → тихая деградация
  for p in $pids; do
    kill -0 "$p" 2>/dev/null || continue
    age=$(ps -o etimes= -p "$p" 2>/dev/null) ; [ -n "$age" ] || continue
    [ "$age" -gt "$LOCK_STALE_SECS" ] || continue            # свежий — не трогать
    args=$(ps -o args= -p "$p" 2>/dev/null)
    printf '%s' "$args" | grep -qE 'podman|hfctl' || continue # чужой процесс — не трогать
    kill -9 "$p" 2>/dev/null || true                          # ядро отпустит flock
  done
}
```

Механика: fd 9 открывает субшелл hfctl, дети podman/podman-compose его
наследуют → fuser возвращает всё семейство; zombie/Sl-процессы, пережившие
TimeoutStartSec из-за KillMode=process, убиваются — лок освобождается
ядром. Шаблон вставки (в `hf_up_locked` и `hf_up_devsafe`, маркер
`# fix:lock-reclaim`):

```bash
( if ! flock -n 9; then
    hf_lock_reclaim            # fix:lock-reclaim
    flock -n 9 || { echo "up уже выполняется — пропуск"; return 0; }
  fi
  …
```

Предохранители от убийства здорового параллельного вотчдога/boot: (а)
порог 900 с (тик вотчдога держит лок секунды), (б) cmdline-предикат
(`less`/редактор, открывшие файл, не матчатся), (в) реклейм не вызывается,
пока лок вообще свободен. Реальные бинарники flock/ps/fuser не фейкаются
продуктом; батарея гонит их настоящими (см. Test strategy).

### Ф4 — битый pod проекта (пустой INFRA ID)

Хелпер `hf_pod_pristine` в `lib/autostart.sh`, вызывается в ОБОИХ
up-субшеллах ПЕРЕД первым `compose up` (внутри лока, чтобы не гоняться с
вотчдогом), маркер `# fix:pod-infra`:

```bash
hf_pod_pristine() {
  local infra
  infra=$(podman pod inspect pod_hipfire --format '{{.InfraContainerID}}' 2>/dev/null) || return 0
  [ -n "$infra" ] || { warn "pod_hipfire с пустым INFRA ID — пересоздаю"; podman pod rm -f pod_hipfire >/dev/null 2>&1 || true; }
}
```

Имя `pod_hipfire`: проект compose = имени каталога стека `hipfire`
(так же захардкожены `CONTAINER=hipfire_hipfire_1` и лейбл
`io.podman.compose.project=hipfire` в devsafe); naming `pod_<project>`
подтверждён GOTCHAS («podman pod ps показывает pod с пустым INFRA ID»,
`podman pod rm -f pod_hipfire … создастся заново при подъёме`). inspect
отказал (pod нет — свежий стек) → no-op, up создаёт pod сам.

### Ф5 — CONTAINERS_CONF-скоуп slirp4netns (EXP-013-validated)

- Новый статичный файл `tpl/etc/hfctl-containers.conf` (ровно то, что
  проверен EXP-013, ничего лишнего):

  ```toml
  # hfctl: скоуп containers.conf только для стека (CONTAINERS_CONF) —
  # обход AppArmor pasta-бага teardown netns; глобальный конфиг не трогается.
  [network]
  default_rootless_network_cmd = "slirp4netns"
  ```

- Доставка в `$STACK_DIR/.hfctl-containers.conf` — `install -m 0644` из
  `$TPL_DIR/etc/hfctl-containers.conf` в ДВУХ местах, каждое с маркером
  `# fix:containers-conf`: `write_stack_files` (stack_files.sh; install/use
  — путь обновления существующих машин) и `cmd_autostart` (autostart.sh,
  строго ДО render_tpl юнитов — инвариант «юниты рендерятся только при
  наличии файла»). Сама перевозка дерева — уже существующий механизм:
  install.sh/sync_tree копируют tpl/ целиком, новый подкаталог едет без
  правок install.sh. ВАЖНО: в sync_tree доставку НЕ встраивать — sync_tree
  no-op на существующих стеках (защита от отката бинаря), там файла бы
  вечность не было.
- `compose()` (stack.sh, маркер `# fix:containers-conf`): экспорт только
  при наличии файла (старый стек без файла → поведение как прежде):

  ```bash
  compose() { ( cd "$STACK_DIR" && [ -f "$STACK_DIR/.hfctl-containers.conf" ] && export CONTAINERS_CONF="$STACK_DIR/.hfctl-containers.conf"; podman compose "${CF[@]}" "$@" ); }
  ```

  ([ -f ] без || true запрещён под set -e — либо `if`, либо `|| true`;
  финальная механика на совести developer, контракт: файл есть → env
  выставлен, файла нет → env чист.) Радиус: все compose-вызовы hfctl
  (up/stop/down/run bench) — единственное место создания контейнеров.
  Прямые podman-вызовы hfctl (inspect/stop/rm) env не получают — сетевой
  бэкенд значим только при create/netns, storage общий (EXP-013:
  graphRoot идентичен с env и без).
- Юниты: `Environment=CONTAINERS_CONF=__STACK_DIR__/.hfctl-containers.conf`
  в `hipfire-compose.service.tpl` и `hipfire-compose-watchdog.service.tpl`
  (покрывает процессы `_boot`/`_watchdog` целиком; `[ -f ]`-гвард не нужен
  — инвариант доставки выше).

### tests/run_checks.sh (новая батарея)

Каркас — перенос прецедентов: gfctl `tests/run_checks.sh` (ок/bad-счётчик
PASS/FAIL, rc=батарея, faux-bin PATH-заглушки с env-сценариями и журналом
вызовов, `gf`-харнесс: субшелл с глобалами диспетчера + source lib в
порядке диспетчера + faux-PATH + `eval` сценария; `TMP=mktemp -d
/tmp/opencode/...`, trap rm по EXIT) + local-опыт
`.dev/tasks/defects/boot-device-mismatch/selfcheck.sh` (фейк GPU-гейта
через HFCTL_KFD/HFCTL_DRI). Домашний стиль комментариев (№ Назначение/
Побочные эффекты/…) — как в lib.

- faux `podman`: журналирует все вызовы в лог; сценарии env'ами:
  compose up печатает ошибку сироты с заданным ID (`…already in use by
  <ID> … external entity`, rc 1 / со 2-го раза rc 0), inspect контейнера
  (missing/created/running), `pod inspect` → InfraContainerID пуст/непуст
  (rc 1 = pod нет), pod rm / rm -f / stop — rc 0 с журналированием.
- faux `containers-storage`: журналирует `delete-container <ID>`, rc 0
  (сценарий отказа — rc 1); отсутствие бинаря = не класть в PATH.
- `systemctl`/`loginctl`/`sudo` — журналирование, rc 0, ничего реального
  (hygiene AGENTS).
- Ф3 гоняется НАСТОЯЩИМИ flock/ps/fuser: holder = реальный фоновый процесс
  `bash -c 'exec -a podman-compose flock 9 sleep 600' 9>lock` (argv
  матчит предикат; etimes настоящий); сценарии через
  `HFCTL_LOCK_STALE=1` (stale, holder спит 2 c) и дефолт 900 (свежий).
- Мутационные проверки: батарея копирует дерево в $TMP/tree, sed-ом
  удаляет строку с `# fix:<имя>` (маркера нет → FAIL «мутация не
  применилась» — защита от дрейфа маркеров; для Ф5 — дополнительно
  удалить `Environment=CONTAINERS_CONF` из tpl-юнита), прогоняет
  сценарий по мутанту и asserts, что ОН ПАДАЕТ (защита реально держит).

## Test strategy

| DoD | внутренний чек (tests/run_checks.sh) | внешний (не в этом сабстэдже) |
|---|---|---|
| Ф1 | сценарий: faux compose stop rc 1 → assert в журнале есть `podman stop hipfire_hipfire_1`, off дошёл до «ВЫКЛ…» rc 0; happy: compose stop rc 0 → podman stop тоже вызван (безвреден); мутация `off-stop` → сценарий падает | EXP окна деплоя: off при живом pasta-баге останавливает контейнер |
| Ф2 | faux podman: up#1 печатает «already in use by <ID>», up#2 ок, inspect running → assert `containers-storage delete-container <ID>` в журнале + ровно 2 up; кап: обе ошибки → вторая НЕ лечится; бинаря нет → WARN-строка, delete-container НЕ вызван; guard: faux inspect ID = running → delete НЕ вызван; мутация `orphan-heal` → падает | EXP: воспроизведение сироты вручную → up самолечится (окно деплоя) |
| Ф3 | stale-holder: HFCTL_LOCK_STALE=1, holder 2 c → assert holder убит (`kill -0` failing), up прошёл, «пропуск» нет; fresh-holder: порог 900 → assert holder жив, «up уже выполняется — пропуск», kill нет; нет fuser в PATH → тихий прежний skip; мутация `lock-reclaim` → stale-сценарий падает | — (семантика flock проверена настоящим ядром) |
| Ф4 | faux pod inspect: InfraContainerID пуст → assert `podman pod rm -f pod_hipfire` в журнале ДО compose up, up прошёл; непуст → rm нет; inspect rc 1 → rm нет, up прошёл; мутация `pod-infra` → падает | EXP: битый pod вручную → up пересоздаёт |
| Ф5 | assert: `$STACK_DIR/.hfctl-containers.conf` создан write_stack_files и cmd_autostart; render юнита содержит Environment=CONTAINERS_CONF; faux podman печатает `echo $CONTAINERS_CONF` → env выставлен при файле и чист при отсутствии; мутации (`containers-conf`-строка, Environment в tpl) → падают | EXP-хвост деплоя: первый pull под slirp4netns замеряет скорость; compose up/stop → 0 netns-ошибок |
| батарея | bash -n hfctl lib/*.sh tests/run_checks.sh; py_compile tpl/python; bare-вызов usage rc=1; HFCTL_PORT=1 status --json — корректный отказ; итого FAIL=0, PASS ≥ 10 | — |
| спека | SPEC.md содержит §14 с пятью контрактами; строки §3 off/up согласованы; grep маркеров: 5 имён присутствуют в коде | — |

## Risks and rollback

- Откат кода: `git revert` одного коммита; на машинах (после деплоя):
  убрать Environment-строку = перерендер юнитов старым бинарем (off→on),
  удалить `$STACK_DIR/.hfctl-containers.conf`. Ни один фикс не меняет
  state/модели/образ.
- slirp4netns может просесть скорость закачки моделей (EXP-хвост; план Б —
  host-network, отдельное решение). graphRoot общий — хранилище не форкается
  (EXP-013).
- Ложный kill при Ф3: ручной up > 900 c будет убит (принятый риск; образ
  спиннут, легитимных >15-минутных up нет); чужой процесс с «podman» в
  argv теоретически убиваем — предикат etimes это окно сужает до
  зависших.
- containers-storage отсутствует на СУЩЕСТВУЮЩИХ машинах до следующего
  install (в preflight докидывается в apt-строку: `podman podman-compose
  containers-storage` — одно слово, stack.sh). До того самолечение
  деградирует до WARN с ручной командой —Variant B, поведение = прежнее.
  Вариант-B (пакет недоступен в релизе) — тот же WARN-канал, хирургия
  storage остаётся ручной.
- Ф2 в hf_up_locked меняет структуру функции (захват вывода) — риск
  регрессии ручного up закрывается позитив-сценарием батареи (happy up
  без ошибок: ровно 1 вызов compose up, rc 0).

## References

- Факты окна 2026-11-21: llm-lab `.dev/GOTCHAS.md` — записи «compose up
  виснет навечно…» (сирота external entity, pod с пустым INFRA ID,
  SIGKILL-выжившие держатели лока) и «После ребута контейнер вечно падает
  /dev/dri…» (обновление EXP-012/013: AppArmor pasta denied signal).
- EXP-013-механика и границы скоупа: llm-lab
  `.dev/experiments/EXP-012-rootless-netns.md` (матрица pasta/slirp;
  graphRoot идентичен).
- Backlog и контекст: `.dev/STATE.md` «Долг-инцидент 2026-11-21» (4 пункта
  фикс-листа + CONF-скоуп из брифа).
- Синтаксис хила: man `containers-storage-delete-container(1)`
  (`delete-container containerNameOrID`); пакет `containers-storage` —
  Ubuntu universe (noble/jammy, как podman).
- Тест-прецеденты: `/workspace/gfctl/tests/run_checks.sh` §17–18 (faux-bin,
  gf-харнесс, wants-артефакты, is-enabled-предикат);
  `.dev/tasks/defects/boot-device-mismatch/selfcheck.sh` (GPU-гейт фейк).
- Код (проверен живьём, HEAD 90d1609): `lib/autostart.sh` (hf_up_locked:252,
  hf_up_devsafe:290, cmd_boot:341, cmd_watchdog:391, cmd_off:156,
  stop_with_marker:94), `lib/stack.sh` (compose:32), `lib/stack_files.sh`
  (write_stack_files:142, sync_tree:76), `tpl/systemd/*.service.tpl`,
  `hfctl:54` (CONTAINER), `lib/commands.sh:497` (uninstall → cmd_off).
- Спека: `.dev/SPEC.md` §3 (карта команд), §13 («Остановка — одна
  реализация», boot-самолечение device-mismatch).

## Open questions

Нет блокирующих. Неблокирующие (решения приняты, зафиксированы в Design):
1. Хил в ОБОИХ up-путях vs только devsafe — выбраны оба (один класс
   аномалии — одна защита; ручной up на битом storage упирался бы в ту же
   стену). Рекомендация оркестратору согласна.
2. Ф1 только для `off`, `down` остаётся — строго по перечню брифа;
   down-симметрия в Out-of-scope.
3. Порог Ф3 900 с (≈ TimeoutStartSec) вместо 420 — юнит по таймауту мёртв,
   а дети живут; 420 резал бы легитимный хвост попытки. Env-крючок
   покрывает selfcheck.
