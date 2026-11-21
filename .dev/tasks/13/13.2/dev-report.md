# Dev report: 13.2 host-preflight — apt-пятёрка + GPU-подготовка хоста
- Дата / раунд: 2026-11-21 / round 1 (developer)
- Контракт: `.dev/tasks/13/13.2/task.md` (HEAD 91aa264 + незакоммиченный task.md)

## What was done

Реализовано 1:1 по контракту (порядок, имена, тексты — по скелету Дизайна;
два намеренных отклонения от букв скелета — см. «Известные ограничения»).

По пунктам DoD:

1. **apt-пятёрка** — `lib/stack.sh`, preflight: один need-список
   (`podman podman-compose containers-storage psmisc curl`; psmisc даёт
   fuser для Ф3, containers-storage — inspect сироты Ф2 13.1), при непустом
   списке ровно один `sudo apt-get update -qq && sudo apt-get install -y
   -qq $need`; всё на месте → apt не вызывается вовсе. Прежние два блока
   apt заменены одним.
2. **GPU-шаг — группы** — `gpu_prep` (новая функция в `lib/stack.sh`,
   самодостаточная = единица переезда этапа 14): `usermod -aG render,video`
   только когда какой-то из групп нет в `id -nG`; при добавлении —
   log «добавляю … в группы render,video», warn «группы применятся только
   после перезахода…», exit 42. Обе группы есть → no-op без sudo.
3. **GPU-шаг — limits.d** — рендер `tpl/etc/99-hipfire-memlock.conf.tpl`
   (НОВЫЙ файл, ровно две строки `__USER__ soft|hard memlock __MEMLOCK__`)
   через render_tpl (kv-порядок MEMLOCK перед USER — по конвенции
   render_tpl «убывание длины»), запись `sudo install -m 0644` только если
   файла нет ИЛИ `cmp` расходится; при записи и низком `ulimit -Hl` —
   прежний warn + exit 42. Байт-паритет рендера прежним двум строкам
   echo проверен напрямую (cmp) — на прод-машинах перезаписи нет.
4. **Гейт** — `[ -e kfd ] || [ -e dri ]` с хуками `HFCTL_KFD`/`HFCTL_DRI`
   (дефолты /dev/kfd, /dev/dri); иначе info «GPU-устройства не найдены
   (…) — GPU-подготовка пропущена» и ноль мутаций. Железный гейт §6.3 стоит
   ПОСЛЕ gpu_prep, текст die байт-в-байт прежний, путь через хук.
   preflight живёт на install-пути (cmd_install/cmd_use); `cmd_on` не
   тронут (этап 14). Хук `HFCTL_LIMITS` — путь limits-файла для selfcheck.
5. **Батарея** — `tests/run_checks.sh`: faux `id` (`-u`→1000, `-nG`→
   HFCTL_FAUX_GROUPS, дефолт «tester render video»), faux `usermod`,
   faux `loginctl` (HFCTL_FAUX_LINGER → Linger=yes), faux `sudo` (форма
   `install -m 0644 SRC DST` → реальная копия install'ом, только DST внутри
   $TMP), PATH-наборы STRIPPED (база + mktemp/cmp/install, без пятерых) и
   FAUX_FULL (FAUX + faux podman-compose/fuser/curl). Сценарии P-A…P-H по
   таблице контракта. Мутации по 4 маркерам: preflight-pkgs (2 строки),
   gpu-gate/gpu-groups/gpu-limits (по 1) — sed-вырезание на КОПИИ дерева,
   bash -n мутанта, сценарий обязан упасть. Инвентарь check_markers: 9 имён,
   счёт …/2/1/1/1.
6. **Spec-honesty** — `.dev/SPEC.md`: раздел «13.2 (план)» заменён
   фактическим контрактом («## 13.2: host-preflight — apt-пятёрка +
   GPU-подготовка хоста»); строка «Соответствие hfctl» — И1 закрыт кодом
   13.2 (ссылка на живой приём EXP-хвостом), формулировки самих И1/И2 не
   тронуты; §2 «Вне каталога» — фактическое имя
   `limits.d/99-hipfire-memlock.conf` (рендер tpl/etc) + группы
   render,video; §3/§14 сверены без правок (doctor-строки — вне скоупа,
   Variant-B WARN в §14 остаётся честным для старых машин); §6.3 не
   тронут. spec_validate не требуется (SPEC hfctl — плоский md без
   frontmatter-графа, структурных правок нет).

Файлы дельты: `lib/stack.sh`, `lib/commands.sh` (только комментарий
cmd_install :10-14 — синхрон «render,video» + apt-пятёрка, прямая строка
Дизайна: «Комментарий cmd_install/use … синхронно render,video + пакеты»),
`tests/run_checks.sh`, `tpl/etc/99-hipfire-memlock.conf.tpl` (новый),
`.dev/SPEC.md`. Машины не трогались, коммитов нет.

## How it was checked internally

- `bash tests/run_checks.sh` — **PASS=40 FAIL=0** (было 28/0; +12 новых:
  8 P-сценариев + 4 мутации — ровно DoD «PASS ≥ 12 новых, итог ≥ 40»).
  Прогон повторён дважды — стабильно. AGENTS-четыре внутри секции 0 —
  зелёные.
- 4 мутации ловятся на копиях: PASS «preflight-pkgs/gpu-gate/gpu-groups/
  gpu-limits: сценарий упал — защита держит»; bash -n мутанта выполняется
  check_mutation до прогона (мутант не парсится = FAIL).
- `bash -n hfctl lib/*.sh tests/run_checks.sh` — ok.
- Инвентарь маркеров: «9 имён маркеров на месте, счёт 1/2/2/2/3/2/1/1/1».
- Байт-паритет: render_tpl(tpl/etc/…tpl) == прежние две echo-строки
  (cmp, вручную) + независимый printf-ассерт в P-E/P-F.
- Спец-свёрка: grep «13.2» = факт-раздел :406; «Соответствие hfctl»
  упоминает 13.2 :392; §2 имя limits-файла :50; git diff показывает §14
  нетронутым.

## Not checked internally

- Живые машины (правило hygiene): FAEX/evo — preflight = нулевой no-op
  (группы render,video есть, limits-файл байт-равен рендеру) и чистая
  машина — apt ставит 5 одним вызовом, 2×exit 42 (перелогин, ребут).
  Подтверждение — EXP-хвост деплой-окна (cat limits-файла до/после,
  журнал sudo), вне подэтапа.
- Поведение apt на машине с частично установленными пакетами (список
  из подмножества) — покрыто батареей только по краям (все/никакой).

## Known limitations / assumptions

- **Два отклонения от букв скелета контракта** (оба — адаптация к среде
  песочницы, продукт не меняет наблюдаемого контракта):
  1. render_tpl kv-порядок `MEMLOCK=` перед `USER=` (скелет: USER,
     MEMLOCK) — по doc-конвенции render_tpl «имена в порядке убывания
     длины»; семантики не меняет (вложенных плейсхолдеров нет).
  2. Тексты: warn про перезаход — «группы применятся…» (мн.ч., как в
     скелете; в «Что НЕ меняется» написано «дословно прежние» — принят
     скелет как «точные строки», единственное словесное отличие группы
     render → группы render,video согласовано по числу).
- **Среда батареи** (задокументировано в шапке run_checks.sh): контейнер
  песочницы — Alpine, а preflight требует ubuntu|debian из /etc/os-release
  (абсолютный путь, хука в контракте нет). Батарея перезапускает себя под
  `unshare -rm` с bind-подменой /etc/os-release (ID=ubuntu) — только
  внутри своего namespace, реальный /etc не трогается; userns недоступен →
  P-сценарии честно падают на os-чеке (в этой среде userns есть).
- **ulimit-адаптации**: hard-лимит memlock песочницы 4097452 kB не
  поднимается (даже в userns) → «сессия с достаточным лимитом» в P-E/P-F
  эмулируется хуком `HF_MEMLOCK=2097152` в харнессе (дефолт 1318060032
  не тронут); P-G понижает лимит реальным builtin `ulimit -l 65536`
  (одиночный `ulimit -Hl` в песочнице даёт EINVAL: cur>max; hard после
  понижения = 65536, что и читает продукт). Обе ветки реального чека
  (достаточно/недостаточно) покрыты настоящим builtin.
- Хук `HFCTL_KFD`/`HFCTL_DRI` в lib/stack.sh — те же имена, что шапка
  autostart.sh, дефолты свои ([ -e ]-путь vs glob renderD*) — как в
  контракте, конфликтов нет (в проде env пуст).
- HFCTL_LIMITS-хук обязателен батареи (не пишет /etc) — по контракту;
  doctor:362/uninstall:508 продолжают хардкод фактического имени.

## Out-of-scope proposals

- preflight в `cmd_on` — этап 14 (gpu_prep уже самодостаточен, переезд
  механический); раньше 14-го = +1 строка вызова, отдельная дельта.
- Doctor: строки «группа render» → «группы render,video», пакеты
  containers-storage/psmisc, показ HFCTL_LIMITS-файла — кандидат на
  D11-мини-сабстэдж (косметика, контракт 13.2 это исключил).
- Усиление die §6.3 до буквы спецификации (`kfd` + `renderD*`) — не в
  13.2; зафиксировано в контракте как осознанное расхождение (раньше
  отказывается, но только по kfd).
- Если у пользователя появятся не-GPU машины с podman-стеком — info-гейт
  gpu_prep уже готов, но linger/apt всё равно требуются (как и прежде).
