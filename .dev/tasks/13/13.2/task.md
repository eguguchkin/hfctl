# Task: 13.2 host-preflight — containers-storage/psmisc в apt + GPU-подготовка хоста   Design: architect

## Scope and DoD

Цель — закрыть оба гэпа И1 («Инварианты поставки», SPEC 2026-11-21): (а)
preflight ставит `containers-storage` + `psmisc` вместе с podman-набором
(сегодня Ф2 13.1 на машине без бинаря деградирует в WARN — Variant B), (б)
GPU-подготовка хоста (группы `render,video` + limits.d memlock) —
идемпотентный шаг с гейтом по наличию GPU-устройств и честным сообщением
«нужен перелогин/ребут». Happy-path на подготовленных машинах — полный no-op.
Файлы диффа — ровно: `lib/stack.sh` (preflight), `tpl/etc/99-hipfire-memlock.conf.tpl`
(НОВЫЙ), `tests/run_checks.sh`, `.dev/SPEC.md` (spec-honesty). Машины не
трогать (живой приём — EXP-хвост деплой-окна, вне подэтапа).

DoD:
1. **apt-пятёрка**: preflight собирает недостающие пакеты одним списком —
   `podman`, `podman-compose`, `containers-storage`, `psmisc` (даёт `fuser`
   для Ф3), `curl` — и делает ровно один `sudo apt-get update -qq &&
   sudo apt-get install -y -qq <список>` при непустом списке; всё на месте →
   sudo-apt не вызывается вовсе (сегодняшние два блока apt заменяются одним).
2. **GPU-шаг — группы**: `usermod -aG render,video` — только если какой-то
   из групп нет в `id -nG`; при фактическом добавлении — честный вывод
   «группы применятся после перезахода» + exit 42 (механизм §9 SPEC, не
   меняется). Обе группы есть → no-op без sudo.
3. **GPU-шаг — limits.d**: файл `/etc/security/limits.d/99-hipfire-memlock.conf`
   рендерится из `tpl/etc/99-hipfire-memlock.conf.tpl` (`__USER__`/`__MEMLOCK__`,
   render_tpl) и пишется `sudo install -m 0644` — только если файла нет ИЛИ
   содержимое отличается (cmp); при записи и низком `ulimit -Hl` текущей
   сессии — прежний warn + exit 42. Рендер байт-в-байт равен сегодняшним
   двум строкам (`$USER soft|hard memlock $MEMLOCK`) — на прод-машинах
   перезаписи нет.
4. **Гейт GPU-шага**: применять только при наличии `/dev/kfd` ИЛИ `/dev/dri`
   (env-крючки `HFCTL_KFD`/`HFCTL_DRI` — selfcheck, прод не переопределяет);
   иначе — info-строка «GPU-подготовка пропущена» и НОЛЬ мутаций.
   Железный гейт §6.3 (`/dev/kfd` нет → die до apt/скачиваний) сохраняется —
   стоит ПОСЛЕ GPU-шага, текст байт-в-байт прежний.
5. **Батарея** `tests/run_checks.sh`: на каждый пункт 1–4 позитив-сценарий +
   мутация по маркеру `# fix:<имя>` (конвенция 13.1: faux id/usermod/
   podman-compose/fuser/curl, sudo-журнал; настоящий flock/fuser/ps — как в
   13.1 Ф3; настоящих sudo-мутаций нет — только эмуляция внутри $TMP).
   Инвентарь маркеров расширен 4 именами. Зелёная: FAIL=0, PASS ≥ 12 новых.
6. **Spec-honesty**: SPEC правится в той же дельте — «13.2 (план)» →
   фактический контракт; в «Инвариантах поставки» обновлена строка
   «Соответствие hfctl» (гэпы И1 закрыты 13.2; переформулировки самих И1/И2
   нет); свёрка §2 («Вне каталога»: фактическое имя limits-файла, группы
   render,video) / §3 / §14 (WARN-канал Variant B остаётся для старых машин
   — противоречий с 13.2 нет); §6.3 не трогается.

Вне скоупа (идеи — в dev-report Out-of-scope): preflight из `cmd_on`
(решение ниже — install-путь only; bootstrap-переезд — этап 14); doctor
(строки «группа render»/«memlock limits» не расширяются — косметика, D11);
усиление die до §6.3-буквы (`kfd` + `renderD*`); install.sh; переименование
limits-файла (ломает doctor:362/uninstall:508 паритет); тексты warn-ов
кроме слов о группах render,video.

## Design

### Где живёт GPU-шаг: preflight, install-путь only — решение

Точка входа preflight на install-пути — **не install.sh**: bootstrap
(install.sh) только кладёт дерево+симлинк и ничего не проверяет; preflight
(`lib/stack.sh:128`) зовут `cmd_install` (commands.sh:58) и `cmd_use`
(commands.sh:153). `hfctl on` = `cmd_autostart + cmd_up` (autostart.sh:135) —
preflight НЕ вызывает.

Решение: **GPU-шаг остаётся внутри `preflight()` единственным блоком, cmd_on
не трогается**. Обоснование: (1) `on` работает на установленном стеке —
GPU-prep уже сделан при install/use, и use зовёт preflight при каждом
переключении; (2) добавка preflight в `on` — новый sudo-способный путь в
повседневной команде без текущей пользы (все существующие машины
GPU-prepped, d : живой приём 13.2 на них = no-op); (3) этап 14 сам
переподключает preflight в bootstrap («первый `hfctl on`: preflight …» —
PLAN этап 14): его DoD, его дельта. Чтобы переезд был механическим, GPU-шаг
проектируется как самодостаточный сегмент внутри preflight (одна функция =
единица переезда) с env-крючками для selfcheck.

### Новый порядок preflight (lib/stack.sh:128)

```
1. root-чек (не-root)                        — без изменений
2. os-release ubuntu|debian                  — без изменений
3. GPU-шаг (гейт → группы → limits.d)        — заменяет сегодняшние блоки
   при отсутствии устройств → info-пропуск     «группа render» (:141-147) и
                                               «limits.d» (:148-158)
4. железный гейт §6.3: [ -e kfd ] || die     — строка/текст байт-в-байт
                                               сегодняшние (:133), путь —
                                               через хук
5. RAM-warn                                  — без изменений (:134-135)
6. apt-пятёрка (один need-список)            — заменяет :136-140
7. linger                                    — без изменений (:159-163)
```

Сдвиги порядка для GPU-машин не меняют наблюдаемого результата (die и apt
проходят как прежде; GPU-шаг раньше apt = меньше sudo-работы до exit 42).
Для машины без GPU: info-пропуск (ноль мутаций) → die §6.3 → никаких apt —
правило 4 (отказ до скачиваний) и «до любых изменений системы» соблюдены.
Крайний случай kfd-нет + dri-есть (полусломанный драйвер): GPU-prep
применится, затем die — мутации идемпотентны и безвредны, шаг отработал по
И1, поток отказал по §6.3.

### Код-скелет (контракт, не дословно; комментарии в домашнем стиле)

```bash
local kfd="${HFCTL_KFD:-/dev/kfd}" dri="${HFCTL_DRI:-/dev/dri}"
# GPU-подготовка хоста (И1): только при наличии устройств; не-GPU — info-пропуск
if [ -e "$kfd" ] || [ -e "$dri" ]; then
  if ! id -nG | grep -qw render || ! id -nG | grep -qw video; then
    log "добавляю $USER в группы render,video (sudo точечно)"
    sudo usermod -aG render,video "$USER"                        # fix:gpu-groups
    warn "группы применятся только после перезахода. Выйди и зайди снова, затем повтори install."
    exit 42
  fi
  local lim="${HFCTL_LIMITS:-/etc/security/limits.d/99-hipfire-memlock.conf}"
  local tmp; tmp=$(mktemp)
  render_tpl "$TPL_DIR/etc/99-hipfire-memlock.conf.tpl" "$tmp" \
    USER="$USER" MEMLOCK="$MEMLOCK"
  if ! cmp -s "$tmp" "$lim"; then
    log "пишу $lim (memlock $MEMLOCK)"
    sudo install -m 0644 "$tmp" "$lim"                           # fix:gpu-limits
    if [ "$(ulimit -Hl)" != "unlimited" ] && [ "$(ulimit -Hl)" -lt "$MEMLOCK" ]; then
      warn "текущая сессия ещё с memlock=$(ulimit -Hl). Требуется ребут (или перезаход+сервис-менеджер). Повтори install после ребута."
      rm -f "$tmp"; exit 42
    fi
  fi
  rm -f "$tmp"
else
  log "GPU-устройства не найдены ($kfd, $dri) — GPU-подготовка пропущена"   # fix:gpu-gate
fi
[ -e "$kfd" ] || die "/dev/kfd нет: AMD GPU не виден (проверь драйвер amdgpu)"
local need=""
command -v podman >/dev/null          || need+=" podman"
command -v podman-compose >/dev/null  || need+=" podman-compose"
command -v containers-storage >/dev/null || need+=" containers-storage"   # fix:preflight-pkgs
command -v fuser >/dev/null           || need+=" psmisc"                  # fix:preflight-pkgs
command -v curl >/dev/null            || need+=" curl"
if [ -n "$need" ]; then
  log "установка пакетов:$need (sudo точечно)"
  sudo apt-get update -qq && sudo apt-get install -y -qq $need
fi
```

Замечания к контракту:
- `need` — строка с пробелами, разбиение намеренное (имена пакетов без
  пробелов; `apt-get install` принимает список). Если shellcheck-базлайн
  требует — read -ra-массив, семантика та же.
- `id -nG` зовётся дважды только в ветке «одной группы нет» — hot-путь
  (обе есть) читает группы один раз… фактически `! A || ! B` вычисляет A
  всегда, B только при успехе A; на прод-машинах оба grep успешны — 2 вызова
  `id`, приемлемо; выносить в локал не обязательно.
- Нет группы `render`/`video` в системе (экзотика) → usermod умрёт по
  set -e со своим rc — громкий честный отказ, ок (Ubuntu/Debian обе группы
  имеют).
- Шаблон `tpl/etc/99-hipfire-memlock.conf.tpl` — РОВНО две строки, без
  комментариев (иначе cmp на прод-машинах разойдётся → sudo-перезапись на
  здоровой машине = не no-op):
  ```
  __USER__ soft memlock __MEMLOCK__
  __USER__ hard memlock __MEMLOCK__
  ```
- Хуки: `HFCTL_KFD`/`HFCTL_DRI` — те же имена, что у шапки autostart.sh
  (:5-6), но дефолты свои под потребность: здесь `[ -e ]`-путь (`/dev/kfd`,
  `/dev/dri`), там глоб для compgen (`/dev/dri/renderD*`). Конфликта нет:
  в батарее модули гоняются в разных сценариях, в проде env пуст. Дефолт
  `HFCTL_LIMITS` — только локальный хук preflight; doctor:362/uninstall:508
  продолжают хардкод фактического имени (прод-путь одинаков). Все три хука —
  selfcheck-only (прецедент KFD_NODE/DRI_GLOB: «продом не используются»).
- `HFCTL_LIMITS`-хук обязателен: батарея не пишет в /etc. С ним же cmp
  работает без sudo (limits.d-файлы 0644 world-readable).
- Маркеры: `preflight-pkgs` (2 строки need), `gpu-gate` (info-строка),
  `gpu-groups` (usermod), `gpu-limits` (install). Все строки самодостаточные
  — sed-удаление не ломает синтаксис (проверка батареи bash -n мутанта).
- Комментарий-шапка preflight (§ «Побочные эффекты» / «Ограничения»)
  обновляется: apt-пятёрка, render,video, limits из tpl/etc, гейт и
  info-пропуск, три хука. Комментарий cmd_install/use (commands.sh:10-12)
  упоминает «usermod -aG render» — синхронно «render,video» + пакеты.

### Что НЕ меняется (happy-path инварианты)

- Тексты die/warn, кроме «группа render» → «группы render,video» в log
  добавления; warn про перезаход и про ребут — дословно прежние.
- exit-коды: 42 (перелогин/ребут), die (1) — те же точки семантики.
- linger-блок, root/OS/RAM-чеки — без изменений.
- На FAEX/evo (группы render,video есть — llm-lab host_prep, пределы файла
  байт-равны рендеру): preflight = ноль sudo-мутаций, сквозной проход.
  Это проверяется батареей сценарием полного no-op (P-H ниже).

### tests/run_checks.sh — расширение (конвенция 13.1)

Faux-расширения (к существующим podman/containers-storage/systemctl/
loginctl/sudo-журналам):
- faux `id`: `-u` → `1000`; `-nG` → `$HFCTL_FAUX_GROUPS` (дефолт
  `tester render video`).
- faux `usermod`: журнал, rc 0.
- faux `loginctl`: при `HFCTL_FAUX_LINGER=1` печатает `Linger=yes` (ветка
  «linger уже включён»), иначе пусто (ветка enable-linger).
- faux `sudo` в 13.2-сценариях: журнал + rc 0, НО для формы
  `install -m 0644 SRC DST` дополнительно делает реальную копию `install`'ом
  в цель — ТОЛЬКО когда DST внутри $TMP (всегда, т.к. HFCTL_LIMITS хукается;
  настоящих sudo-мутаций нет). Без этого limits-ассерты нечему проверять.
- PATH-наборы: stripped (как NOFU: ln-набор базовых утилит + добавить
  `mktemp cmp install`) БЕЗ podman/podman-compose/containers-storage/fuser/
  curl — сценарий «всё отсутствует»; FAUX-набор + faux podman-compose/fuser/
  curl — сценарий «всё на месте». `command -v` в песочнице: podman/
  containers-storage реально отсутствуют (проверено 13.1), fuser/curl
  есть — поэтому stripped-набор обязателен.

Сценарии (все — с хуками; `hf`-харнесс уже source'ит stack.sh → preflight
доступен; MEMLOCK=1318060032 в харнессе):

| # | Сценарий | Ассерты |
|---|---|---|
| P-A | pkgs-missing: stripped PATH, kfd-хук существует, группы ок, limits заранее равен рендеру | в журнале ровно одна строка `apt-get install -y -qq podman podman-compose containers-storage psmisc curl` (+update перед ней); rc 0 |
| P-B | pkgs-present: FAUX-набор со всеми пятью | `apt-get` в журнале 0 раз |
| P-C | не-GPU: HFCTL_KFD/HFCTL_DRI → несуществующие | out содержит «GPU-подготовка пропущена»; в журнале НЕТ usermod/install-limits/enable-linger/apt; rc≠0 с «/dev/kfd нет» (§6.3) |
| P-D | группы свежие: kfd есть, HFCTL_FAUX_GROUPS=`tester render` (video нет) | журнал `usermod -aG render,video tester`; out «после перезахода»; rc 42; limits/linger не достигнуты |
| P-E | группы ок, limits-файла нет: HFCTL_LIMITS=$TMP/… | файл создан, байты == рендер шаблона (tester/1318060032); сессия unlimited → rc 0, linger вызван |
| P-F | limits idempotent: файл заранее равен рендеру → повторный прогон | `install` в журнале 0 раз; файл с «чужим» содержимым → переписан (журнал + байты) |
| P-G | низкий memlock сессии: файл отсутствует + субшелл `ulimit -Hl 65536` (реальный builtin) | rc 42, warn «Требуется ребут», файл записан, linger не достигнут |
| P-H | полный no-op (эмуляция FAEX/evo): всё на месте, группы ок, limits равен, HFCTL_FAUX_LINGER=1 | rc 0; в журнале нет apt/usermod/install-limits/enable-linger |

Мутации: `preflight-pkgs` → P-A падает; `gpu-gate` → P-C падает (инфо-строки
нет); `gpu-groups` → P-D падает (usermod-строки нет в журнале);
`gpu-limits` → P-E падает (файл не создан). Инвентарь check_markers: +4
имени, счётчики preflight-pkgs=2 (stack.sh), gpu-gate/gpu-groups/gpu-limits=1.
AGENTS-четыре и 13.1-сценарии не трогаются (их счётчики PASS сохраняются).

## Test strategy

| DoD | внутренний чек (tests/run_checks.sh) | внешний (EXP-хвост, не в этом сабстэдже) |
|---|---|---|
| 1 apt-пятёрка | P-A (один need-список, пять имён) + P-B (no-op) + bash -n; мутация preflight-pkgs | чистая машина: install.sh → install — apt ставит 5 одним вызовом; повтор — apt нет |
| 2 группы | P-D (usermod render,video + честный вывод + rc 42) + P-H (обе группы → no-op); мутация gpu-groups | машины FAEX/evo при деплое-окне: preflight (use) — usermod не звался |
| 3 limits.d из tpl | P-E (байты == рендер) + P-F (равен → нет записи; разница → перезапись) + P-G (exit 42 при низком ulimit — настоящий builtin); мутация gpu-limits | FAEX/evo: cat limits-файла до/после деплоя — байт-равен (перезаписи нет) |
| 4 гейт | P-C (info-пропуск, ноль мутаций, затем §6.3-die); мутация gpu-gate | не-GPU-машина (если появится): отказ «/dev/kfd нет» без sudo-мутаций |
| 5 батарея | FAIL=0, PASS ≥ 12 новых (итог ≥ 40), инвентарь 9 имён маркеров, AGENTS-четыре зелёные | — |
| 6 SPEC | grep: «13.2» раздел = факт-контракт; «Соответствие hfctl» упоминает 13.2; §2 имя limits-файла фактическое; §14 без правок | — |

## Risks and rollback

- **Контент-паритет limits**: если на какой-то машине файл писался руками
  иначе (пробелы/порядок), первый после деплоя install/use перепишет его
  sudo'м — при тех же значениях memlock поведение сервера не меняется, exit
  42 не встанет (сессия уже с лимитом или unlimited). Проверка — EXP-хвост
  (cat до/после). Риск осознанный: «писать если отличается» — контракт И1.
- **video-группы нет у юзера** на какой-то из машин → первый install/use
  даст exit 42 (перелогин) — ожидаемо по И1, деплой-окно должно это
  предвидеть (по факту обе машины уже в render,video — llm-lab host_prep).
- apt-merge (curl в общем списке): apt-get update требует сеть — install и
  так требует; на машинах с пакетными списками поведение то же.
- GPU-шаг до die: кейс kfd-нет+dri-есть получает usermod/limits до отказа —
  мутации безвредны/идемпотентны/полезны (машина подготовлена к починке
  драйвера). Остальные не-GPU кейсы — ноль мутаций.
- Хук HFCTL_KFD/HFCTL_DRI с двумя разными дефолтами (path vs glob) —
  задокументирован в комментариях обоих модулей; конфликтов нет (разные
  сценарии батареи, прод env пуст).
- Откат: `git revert` одного коммита; tpl/etc/99-…tpl — новый файл, его
  удаление безопасно (читает только preflight); существующие машины не
  затронуты до деплоя. Ни state, ни модели, ни образ не меняются.

## References

- Спека: `.dev/SPEC.md` — «Инварианты поставки» И1/И2 (:369-402, И1 —
  контракт этого сабстэджа: apt-пятёрка, GPU-шаг с гейтом, честный вывод,
  info-пропуск на не-GPU), §6.3 (die по kfd, :134), §9 (sudo-места + exit 42
  как внутренний механизм, :176-178), §14 (13.1: WARN-канал отсутствия
  containers-storage — Variant B остаётся для старых машин), §3 (install/use
  строки), §2 «Вне каталога» (фактическое имя `99-hipfire-memlock.conf`).
- План: `.dev/PLAN.md` «Этап 13.2» (:434-446, DoD-источник) и «Этап 14»
  (:448-477 — почему cmd_on не трогаем: bootstrap-переезд отдельным циклом).
- Код (проверен живьём, HEAD 91aa264): `lib/stack.sh` (preflight:128-164:
  apt :136-140, render-группа :141-147, limits :148-158, linger :159-163;
  render_tpl из stack_files.sh:38 — плейсхолдеры `__NAME__`, die на
  нераскрытых), `lib/autostart.sh` (:5-6 хуки KFD_NODE/DRI_GLOB — прецедент
  env-крючков; cmd_on:135 = cmd_autostart+cmd_up), `lib/commands.sh`
  (cmd_install preflight :58, cmd_use :153, doctor :361-363, uninstall
  limits :508-509), `install.sh` (preflight НЕ вызывает — только дерево),
  диспетчер `hfctl` (MEMLOCK=1318060032, TPL_DIR).
- Батарея-прецедент: `tests/run_checks.sh` 13.1 (faux-журналы, hf-харнесс,
  mutant_marker/mutant_sed, check_markers, «настоящие flock/fuser/ps»);
  `.dev/tasks/13/13.1/task.md` (конвенция маркеров/мутаций).
- Факты/решения: `.dev/DECISIONS.md` D11/D12 (лёгкий режим и пакетная
  приёмка — касаются EXP-хвоста, не дизайна); llm-lab `.dev/GOTCHAS.md`
  «Новый ssh всё ещё с ulimit -Hl=8192 — limits.d не применился к
  session-скоупу» (почему честный вывод «перелогин/ребут» обязателен);
  llm-lab `scripts/host_prep.sh` + AGENTS.md (GPU-prep паттерн
  render,video + limits.d, FAEX/evo группы уже есть — живой приём = no-op).

## Open questions

Нет блокирующих. Неблокирующие (решения приняты, зафиксированы в Design):
1. Гейт vs §6.3-die: И1-«info-пропуск» и §6.3-«выход» разведены по уровням —
   info-пропуск есть поведение GPU-шага (шаг не мутирует машину без GPU),
   die остаётся отказом install-потока до apt/скачиваний. Наблюдаемо:
   не-GPU машина видит обе строки (пропуск + FATAL). Альтернатива
   «die убрать/ослабить» отвергнута — правило 4 и §6.3.
2. cmd_on без preflight — обоснование в Design (этап 14 переподключит);
   если пользователь захочет preflight в `on` раньше 14-го — это +3 строки,
   отдельная дельта.
3. Doctor не показывает video/новые пакеты — косметика, кандидат на D11-
   мини-сабстэдж, сюда не входит.
4. Усиление die до §6.3-буквы (`kfd` + `renderD*`) — не в 13.2 (happy-path);
   зафиксировано как расхождение кода со спекой в пользу более раннего
   отказа по kfd (в bатарее не проверяется).
