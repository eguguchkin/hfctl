# Task: watch-tui — дашборд для `hfctl watch`            Design: architect

## Scope and DoD

Goal/DoD — из `flow/watch/watch-tui/brief.md` (единственный носитель DoD),
повторяю здесь без доработки. Ключевые решения D1–D5 — `flow/FACTS.md`,
`flow/DECISIONS.md`; метрики/пути — только из `flow/FACTS.md`.

**Out of scope** (не делать «по пути»):
- дублировать функционал движкового `hipfire tui` (это зона host-железа + пода,
  а не замена);
- добавлять в репо тест-файлы (проверки — команды ролей + `--selfcheck`,
  см. Design);
- флаг `--plain` на CLI: режим выбирается `sys.stdout.isatty()` (D1/DoD 6
  определяют поведение по TTY, в пайпе/лог-файле plain срабатывает сам;
  флаг добавил бы вторую поверхность разбора без нового поведения из DoD);
- новые метрики движка, конфиги, цвета сверх порогов из SPEC.md;
- отслеживание нескольких GPU-карт (логика `gpu_temp()`: max по датчикам
  одной первой AMD-карты переносится как есть);
- `spec/state.md` (статусный коммит — оркестратор).

## Design

### 1. Файлы и их судьба

| Файл | Действие | Ответственность |
|---|---|---|
| `tpl/python/watch_tui.py` | **новый** | всё живое поведение `hfctl watch`: коллектор данных, два рендерера (TUI / plain), лог-стример. stdlib: `curses`, `urllib.request`, `subprocess`, `threading`, `deque`, `signal`, `pty`-не-нужно. Только stdlib, синтаксис 3.8+ (dataclasses ок; без walrus-зависимости не критично — walrus 3.8 есть, но `functools.cached_property`-подобных новшеств не использовать) |
| `lib/commands.sh` — `cmd_watch()` | **переписать** (297–376 → ~20 строк) | разбор `--interval N`/`--interval=N` (как сейчас: `isint`, ≥1, обе формы, die при ошибке), чтение модели из `.env`, `exec python3` |
| `lib/commands.sh` — `gpu_temp()` (258–271) | **удалить** | логика (max temp1_input по hwmon первой AMD-карты vendor 0x1002) переносится в python; единственный вызывающий — `cmd_watch` |
| `tpl/python/watch_stats.py` | **удалить** | единственный вызывающий — `cmd_watch`; поля, которые он давал (`queue_depth`, `requests_served`, `retries_attempted`), python читает из `/stats` сам. `recent_tok_s` в новый срез D2 не входит — мёртвое поле, вместе с файлом |
| `hfctl` (диспетчер) | правка комментов | строка usage-блока `watch` (15–17) и комментарий-описание команды: TUI на TTY + стрим в не-TTY. Поведение разбора — в `cmd_watch`, диспетчер не тронут |
| `spec/hfctl.md` (строка `watch`, 60–61), `README.md` (38) | **дописать** под новое поведение (DoD 11) | TUI-блоки, клавиши, стрим-режим раз в N с, «недоступен» раз в 30 с |

Мёртвый код удаляется, не закомментируется (DoD 7).

### 2. Интерфейс bash → python (точный)

```bash
cmd_watch() {
  # разбор --interval как в текущей версии (die при ошибке)
  local model=""
  model=$(sed -n 's/^HIPFIRE_MODEL=//p' "$STACK_DIR/.env" 2>/dev/null | head -n 1 || true)
  HFCTL_WATCH_PORT="$PORT" HFCTL_WATCH_INTERVAL="$interval" \
  HFCTL_WATCH_CONTAINER="$CONTAINER" HFCTL_WATCH_MODEL="$model" \
  exec python3 "$TPL_DIR/python/watch_tui.py"
}
```

- Передача — **только env, без argv** (house-style: диспетчер уже живёт на
  `HFCTL_*`; argv не нужен — режим python сам решает по `isatty()`).
- Python читает env с дефолтами: `HFCTL_WATCH_PORT` (def `11435`),
  `HFCTL_WATCH_INTERVAL` (def `2`), `HFCTL_WATCH_CONTAINER`
  (def `hipfire_hipfire_1`), `HFCTL_WATCH_MODEL` (def `-`). Любое отсутствие —
  дефолт, не краш (python может запускаться ролями напрямую).
- `sed … || true` — защита от `set -euo pipefail` (грабля из hflab: grep/sed
  без совпадения убивал бы диспетчер; здесь model просто пустой → в блоке `-`).
- `exec` — rc python = rc `hfctl watch`; SIGINT/SIGTERM уходят в python.
- ТTY-флаг НЕ передаётся: python — `sys.stdout.isatty()` → TUI, иначе plain.
- `STACK_DIR`, `PORT`, `CONTAINER`, `TPL_DIR` — уже есть в диспетчере (35/43/52/60).

### 3. Коллектор (один, для обоих режимов)

Один тик = один срез (snap), структура — dict:

- `engine_ok: bool` — успешен ли GET `/stats`.
- `stats: dict|None` — JSON `/stats` (ключи `queue_depth`, `requests_served`,
  `retries_attempted`; `recent_tok_s` не используется).
- `metrics: dict|None` — скаляры из `/metrics`: парсер — строка вида
  `name[{labels}] value`, строки `# …` и `*_bucket{…}` пропускаются;
  `hipfire_…_sum` / `hipfire_…_count` (гистограммы prefill/decode/τ)
  остаются в dict под своими именами. Числа float.
- `gpu: dict|None` — по первой `/sys/class/drm/card*/device/vendor == 0x1002`:
  `temp_c` (max `temp1_input`/1000 по всем её `hwmon*/` — логика `gpu_temp`),
  `sclk_mhz` (`freq1_input`/1000), `power_w` (`power1_input`/1e6),
  `busy_pct` (`gpu_busy_percent`), `vram_used`/`gtt_used` (байты).
  Полю нет → `None` в поле, не в dict целиком.
- `cpu_temp_c: float|None` — `/sys/class/hwmon/hwmon*/name == "k10temp"`,
  `temp1_input`/1e6.
- `mem: dict` — `/proc/meminfo`: `available_gib`, `total_gib`,
  `swap_used_gib`, `swap_total_gib` (KiB → GiB, 1 знак).
- `kv_free`, `kv_total` — gauges `hipfire_kv_pages_free`/`hipfire_kv_pages_total`
  (`None` при недоступности).
- `uptime_s` — counter `hipfire_uptime_seconds` (`None` при недоступности).

Правила:
- HTTP: `urllib.request`, timeout 3 с на каждый GET (как `curl -m 3`),
  каждый эндпоинт в своём try/except: `/stats` упал → `engine_ok=False`,
  `/metrics` упал → скорости/avg `'-'`, всё остальное строки печатается.
  «Сервер недоступен» в обоих режимах определяется **только** по `/stats`.
- sysfs/`/proc` читаются **каждый тик независимо от engine_ok** (DoD 4:
  RAM/датчики живут при упавшем сервере). Файла нет → поле `None` → рендер `'?'`.
- Дельты: live prefill tok/s = Δ`hipfire_prompt_tokens_total`/Δt,
  live decode tok/s = Δ`hipfire_completion_tokens_total`/Δt; Δt — реальное
  время между успешными чтениями `/metrics`, не interval. Отрицательное Δ
  (рестарт сервера, счётчики сброшены) → значения `'-'` на этом тике, база
  обновляется (без ложных «−1000 tok/s»).
- avg (только для строк «avg», не для live):
  prefill avg = `hipfire_prefill_tokens_per_second_sum`/`_count`,
  decode avg — аналогично, τ = `hipfire_spec_tau_sum`/`_count`;
  `_count == 0`/`None` → `'-'`.

### 4. Лог-стример

- `threading.Thread` (daemon), стартован в `main()`; команда
  `podman logs -t --tail 200 -f "$CONTAINER"` через `subprocess.Popen`,
  stdout построчно → `deque(maxlen=500)` (append/popleft у deque thread-safe —
  lock не нужен; поток **никогда** не дёргает curses и HTTP — DoD 8).
- Пауза: рендерер хранит «вид» логов (список); каждый тик при непоаузе
  `вид = list(deque)`, при паузе вид заморожен. Пауза не останавливает
  буферизацию.
- podman нет/контейнер нет → в зоне логов `логи недоступны: <rc podman>`,
  тики продолжают (DoD 4); при повторном появлении контейнера — видно само
  (строка процесса при следующем тике).

### 5. TUI-рендерер (TTY)

Вход: `curses.wrapper(main_loop)`; `curs_set(0)`, `nodelay(True)`,
`noecho`. Один цикл тиков: каждый тик — drain всех нажатых клавиш
(`getch()` в нонблок), snap, расчёт дельт, перерисовка, сон интервала
квантами ≤100 мс (клавиши обрабатываются между квантами — `+/-` действует
со следующего тика, `q` — сразу).

Раскладка (минимум 80×24; цифры — ориентир, разрешено двигать ±1 строку):
- строка 0 — **статус-бар**: `hfctl watch │ модель <model>` слева,
  `интервал N c` по центру, `логи: live|пауза (p) │ q — выход` справа,
  маркер состояния сервера (`●` зелёный / `●` красный при engine_ok=False).
- содержимое: **2 колонки × 2 ряда блоков**: ряд 1 — «движок» | «железо»,
  ряд 2 — «скорость» | «память». Блоки с рамкой, заголовок внутри вверху.
- нижняя зона на всю ширину — **логи** (ring-вид, последняя строка внизу),
  высота = max(6, (H−1)//4) при H≥24.
- содержимое блоков (эскиз-контракт SPEC.md, блоки обязательны):
  - «движок»: модель, uptime (d/h/m), очередь, обслужено, ошибки
    (`hipfire_requests_failed_total`, строка только когда >0 — house-правило),
    ретраи (только ≠0), τ avg, кэш (`hipfire_cached_prompt_tokens_total`).
    При engine_ok=False — блок целиком `недоступен`.
  - «железо»: sclk, busy%, power, GPU temp, Tctl.
  - «скорость»: live prefill tok/s, live decode tok/s, avg prefill, avg decode,
    две строки **sparkline** (prefill и decode live за ~60 с).
  - «память»: MemAvailable/Total GiB + bar, swap used/total, KV pages
    free/total.
- **Sparkline**: по одному deque на скорость; значение тика — live tok/s
  (`'-'` при недоступности → пропуск, тик не добавляется); `maxlen =
  max(1, 60 // interval)`; смена `+/-` → maxlen пересчитывается, deque
  усекает с левого края (самое старое), **история переживает смену
  интервала** (brief: не пересоздаётся). Шкала — autoscale к максимуму ряда
  (≥1); глифы 8 ступеней: Unicode `▁▂▃▄▅▆▇█`, ASCII-fallback `. - : * # % @`
  (последний — max).
- **Клавиши** (D3, минимум): `q`/`Q` — выход (wrapper восстанавливает
  терминал); `+`/`=` — интервал+1; `-`/`_` — интервал−1 (клавишами только
  clamp 1..10; стартовый `--interval N >10` из bash уважается, как сейчас);
  `p` — пауза/продолжить логи (состояние — в статус-баре). Других клавиш нет.
- **Пороги цветом** (SPEC.md, при `has_colors()`; без цветов — просто без
  подсветки, не краш): MemAvailable < 10 GiB — красный; Tctl > 80°C —
  красный; `busy < 5%` при `queue_depth > 0` — подсветка (жёлтый/bold,
  подозрение на зависание). Больше цветов нет.
- **Деградация** (DoD 3): все рисующие вызовы через одну защищённую
  `put(win, y, x, s)` — строка обрезается по `cols`, ячейка за пределами окна
  пропускается (никаких `addstr`-исключений на узком/низком терминале);
  при W<80 колонки сжимаются пропорционально, значения trunc-ятся
  (не переносятся); при H<24 зона логов сжимается до min 3 строки, блоки —
  до min 3 (рамка+1 строка данных). Терминал 40×10 должен отрисовать
  минимальную сетку без трейса.
- **TERM без UTF-8 / кривой TERM**: выбор глиф-сета по
  `locale.getpreferredencoding(False)` (и `TERM` пустой/`dumb`): не-UTF-8 →
  ASCII-глифы, рамки `+---|`, `°C` → `C`, `τ` → `tau`; `curses.initscr()`
  упал (TERM unset/неизвестный) → **фолбэк в plain-режим** независимо от
  TTY (print-строки), не краш и не трейс.
- **Выход**: `q` — обычное завершение (rc 0); SIGINT/SIGTERM — перехват:
  в TUI — выход из цикла до `endwin` (альт-экран снимаётся wrapper'ом);
  в plain — `KeyboardInterrupt` → exit 0 («Выход Ctrl-C», spec/hfctl.md:61).
- Один процесс, один curses-экран; HTTP/sysfs только в главном потоке
  (DoD 8).

### 6. Plain-рендерер (не-TTY)

Строка **безусловно раз в N секунд** (первая сразу, t=0; D2 — отказ от
«только при изменении»). Формат (один ряд, разделитель ` │ `, время `HH:MM:SS`):

```
HH:MM:SS  очередь: 0 │ обслужено: 123 (+1) │ кэш: 4421 │ ошибки: 2 │ ретраи: 1 │ prefill: 84.2 tok/s │ decode: 75.3 tok/s │ mem: 45.2/60.4 GiB │ swap: 0.2/8.0 GiB │ gpu: 62C 1500MHz 18W 87% │ cpu: 54C
```

Состав по D2 (всё, что укладывается; порядок зафиксирован):
- `очередь`, `обслужено` (дельта `(+)` только когда >0 — как сейчас),
  `кэш`, `ошибки` (только когда >0), `ретраи` (только когда ≠0),
  `prefill`/`decode` (1 знак, `'-'` при недоступности `/metrics`),
  `mem: avail/total GiB`, `swap: used/total GiB`,
  `gpu: <temp>C <sclk>MHz <power>W <busy>%` (поле без датчика — `?`),
  `cpu: <tctl>C`.
- Не-UTF-8 stdout (пайп в файл всегда ASCII-безопасен — `°` не используем,
  в строке уже `C` без градуса; это канон plain-режима, не фолбэк).
- **Сервер недоступен** (`engine_ok=False`): full-срез невозможен —
  строка `HH:MM:SS сервер недоступен (нет /stats на :PORT); жду…`
  **первая сразу, далее раз в 30 с, без дублей** (поведение текущей
  реализации переносится; RAM/датчики в plain-строке при недоступности
  не печатаются — SPEC: стрим-режим завязан на /stats).
- rc: Ctrl-C → 0; аргументы разбирает bash (python argv не принимает,
  кроме `--selfcheck`, см. ниже).

### 7. `--selfcheck` (скрытый режим python-файла)

`python3 tpl/python/watch_tui.py --selfcheck` — assert-самопроверка без
сервера и TTY (exit 0/1): парсер `/metrics` по встроенной fixture
(счётчики, gauge, `_sum`/`_count`, `_bucket`-отсев, `# HELP`-отсев),
форматер plain-строки по фикст. snap (состав и `'-'`/`'?'`-замещения),
обе глиф-команды sparkline (UTF-8/ASCII) по фикст. истории, выбор глиф-сета
по заданной кодировке. Это и есть «один маленький тест» новой логики —
ролевые команды ниже его же используют. В usage не печатается.

## Test strategy

| DoD item | Внутренняя проверка (роли запускают) | Внешняя (EXP, что доказывает) |
|---|---|---|
| 1 (блоки TUI) | pty-спавн (см. ниже) 80×24: выход нет-трейса, в захвате есть заголовки блоков | EXP-001 |
| 2 (клавиши, статус-бар) | pty-спавн: после `+` в статус-баре «интервал 3 c»; после `p` — «пауза» (pty-ввод через запись в master) | EXP-001 (визуально) |
| 3 (80×24 мин, деградация, TERM не-UTF-8) | pty-спавн 60×15 → нет трейса; pty с `TERM=posix` → нет трейса, ASCII-глифы; `TERM=` (пусто) → фолбэк plain, нет трейса | — |
| 4 (server down: TUI жив) | TUI-pty на `HFCTL_WATCH_PORT=<мёртвый порт>`: цикл жив, блок «движок» = «недоступен», RAM/датчики рисуются | — |
| 5 (пороги цветом) | `--selfcheck` + код-ревью (has_colors в контейнере может быть 0); визуально — на машине | EXP-001 (визуально) |
| 6 (plain раз в N, full-срез, недоступен раз в 30 без дублей) | `HFCTL_WATCH_PORT=<мёртвый> hfctl watch --interval 1` × 35 с → ровно 1 строка «недоступен»; × 65 с → ровно 2 | EXP-002 (интервалы на живом сервере) |
| 7 (общий коллектор, bash только exec, мёртвый код удалён) | `grep -c 'while :' lib/commands.sh` (0 в cmd_watch), `bash -n`, отсутствие `gpu_temp`/`watch_stats.py`, `--selfcheck` (общая структура snap) | — |
| 8 (stdlib, 3.8+, поток не дёргает HTTP/curses) | `python3 -m py_compile`; `grep -E '^\s*(import|from)' watch_tui.py` — только stdlib; `--selfcheck`; код-ревью потока | — |
| 9 (регрессия) | `bash -n hfctl lib/*.sh install.sh`; `py_compile tpl/python/*.py`; `hfctl` → usage rc=1; `HFCTL_PORT=<чанковый> hfctl status --json` → корректный отказ | — |
| 10 (внешняя приёмка) | — | EXP-001…003 (см. ниже) |
| 11 (доки) | `grep` в `spec/hfctl.md`/`README.md`: новые описания watch (TUI/plain/клавиши), старые («только при изменении», «heartbeat») удалены | — |

**pty-внутренний чек** (для TUI-строк 1–5): python-одноразовый спавн через
`pty.fork()` (stdlib, доступен в контейнере), winsize ioctl: 80×24, 60×15,
`TERM` заданный; процесс = `HFCTL_WATCH_PORT=19999 HFCTL_WATCH_INTERVAL=1
python3 tpl/python/watch_tui.py`; ждать 3–5 с, SIGTERM, собрать вывод,
assert: нет `Traceback`, есть заголовки блоков. Контейнер dev-окружения
без podman — это штатно: зона логов покажет «недоступно» (часть проверки DoD 4).

**EXP (внешняя приёмка, реальные машины, GO пользователя; скрипты в
`flow/external/`):**
- **EXP-001-tui-ssh** (DoD 1, 2, 5): ssh с TTY, tmux-панель 80×24,
  `hfctl watch` ~40 с; `tmux capture-pane`: все 5 блоков + статус-бар;
  зона логов содержит ≥1 строку живых логов контейнера; цифра Tctl
  присутствует; затем фоновый long-запрос к `:11435` (генерация) →
  capture-pane в окне генерации: live prefill > 0. PASS = всё выше.
- **EXP-002-plain-pipe** (DoD 6, 10): `hfctl watch | tee f` ~12 с на
  живом сервере: в `f` строки каждые ~2 с (±0.5 с по timestamp'ам),
  каждая содержит полный срез (mem/gpu/cpu/prefill/decode-поля).
  PASS = интервалы + состав.
- **EXP-003-plain-tty-safe** (DoD 10): в ssh-TTY `hfctl watch > f`
  (stdout = файл → plain) ~8 с; потом в той же сессии: в `f` нет байта
  ESC (0x1b), `echo ok` печатается чисто, терминал не в alt-экране.
  PASS = терминал не порван.

Каждый EXP: самодостаточный скрипт, header с PASS-критерием, вывод в
`EXP-NNN-<name>.result.txt`, финальная строка `RESULT: …`.

## Risks and rollback

- **TERM unset/экзотический** → `initscr` крашнет до наших защит: ловится
  в `main()` (`try/except` вокруг wrapper) → plain-фолбэк (Design §5).
- **`podman logs -f` держит fd и не завершается** после выхода:
  поток daemon + `proc.terminate()` в finally → процесс завершён.
- **HTTP-таймаут (3 с ×2) длиннее интервала 1 с**: тик растягивается,
  дельты считают реальное Δt — цифры не врут; TUI «подтормаживает» при
  упавшем сервере (ожидаемо, блок «недоступен» всё равно рисуется).
- **Счётчики сброшены (recreate)**: отрицательные дельты отброшены
  (Design §3) — нет «−N tok/s».
- **Ролбэк**: сабстэдж не трогает state/конфиги/модели; откат = revert
  коммита (диспетчер-комменты, `lib/commands.sh`, python-файлы, доки).
  Живые машины на момент правки не требуют миграции (behavior-only).

## References

- `flow/watch/watch-tui/brief.md` (DoD 1–11), `flow/SPEC.md` (D1–D3 +
  эскиз-контракт UI + пороги), `flow/FACTS.md` (метрики 0.4.5, `/stats`,
  sysfs, текущий `cmd_watch`), `flow/DECISIONS.md` (D1–D5).
- Код: `lib/commands.sh:228-376` (`cmd_logs`, `gpu_temp`, `cmd_watch`),
  `hfctl:15-17,42-60` (usage, `PORT`/`CONTAINER`/`TPL_DIR`/`STACK_DIR`,
  `set -euo pipefail`), `tpl/python/watch_stats.py`, `spec/hfctl.md:60-61`,
  `README.md:38`.

## Open questions

Блокирующих нет (все ветки D1–D3 закрыты пользователем; решения по
`--plain`, глифам, форматированию строки и env-интерфейсу — выше, с
обоснованием). Неблокирующее уточнение для пользователя (не стопит
кодинг): plain-строка **не включает** `done: <recent_tok_s> tok/s`
(его нет в составе D2) — если «скорость последнего done» в строке нужна,
это строка в составе D2, решать после EXP-002.
