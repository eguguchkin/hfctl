# Dev report: watch-tui

- Дата: 2026-11-12 / fix round 1

## What was done (per scope item; file list)

1. **`tpl/python/watch_tui.py` — новый** (stdlib, синтаксис 3.8+, ~700 строк):
   - **Один коллектор** `collect()` для обоих режимов: GET `/stats` + `/metrics`
     (urllib, по 3 с таймаут, каждый в своём try/except; `engine_ok`
     определяется **только** по `/stats`), host `/sys` (AMD-карта vendor 0x1002:
     max `temp1_input`, `freq1_input`, `power1_input`, `gpu_busy_percent`,
     `mem_info_vram/gtt_used`; k10temp Tctl) и `/proc/meminfo` — **каждый тик
     независимо от доступности сервера**; файла нет → поле `None` → рендер `'?'`.
   - **Дельты**: live prefill/decode = Δ`prompt/completion_tokens_total` / Δt
     (реальное время между успешными чтениями `/metrics`, не interval);
     отрицательный Δ → `'-'` на тике, база обновляется; `reset()` после простоя
     сервера (перенос bash-поведения: без ложных дельт после поднятия).
     avg — `_sum`/`_count` гистограмм (prefill, decode, τ), `_count==0` → `'-'`.
   - **Лог-стример**: daemon-`threading.Thread`, `podman logs -t --tail 200 -f`
     через `Popen`, построчно → `deque(500)`; поток НЕ дёргает curses и HTTP;
     podman/контейнер нет → `err`-строка + повторная попытка ~1/с (появление
     контейнера видно само); `stop()` в finally → `proc.terminate()` (fd не
     дёргает). Пауза (`p`): «вид» заморожен, буферизация живёт.
   - **TUI-рендерер**: `curses.initscr()`/`endwin()` (alt-экран снимается на
     любом выходе); все рисующие вызовы через одну защищённую `put()`
     (обрезка по краю окна, пропуск вне окна, catch curses.error +
     UnicodeEncodeError — узкий/низкий/не-UTF-8 терминал без трейса); раскладка
     2×2 (движок/железо/скорость/память) + нижняя зона логов на всю ширину
     (max(6,(H−1)//4), min 3 при H<24); статус-бар (модель, «интервал N c»,
     «логи: live|пауза», `●` зелёный/красный); клавиши `q/Q`, `+/-`/`=_`
     (клавишами clamp 1..10; стартовое из bash >10 уважается), `p`; сон
     интервала квантами ≤100 мс (клавиши между квантами, `q` — сразу,
     `+/-` — со следующего тика); sparkline: 2 deque (maxlen = 60//interval,
     ≥1), глифы Unicode `▁▂▃▄▅▆▇█` / ASCII `. -:*#%@` (последняя — max),
     autoscale к максимуму (≥1), `'-'`-тики не добавляются; история переживает
     смену интервала (усечение с левого края); пороги цветом при `has_colors()`:
     MemAvailable < 10 GiB — красный, Tctl > 80° — красный, busy < 5% при
     queue>0 — жёлтый/bold; выбор глиф-сета `choose_utf8()` по
     `locale.getpreferredencoding(False)` + TERM (пустой/`dumb`/`posix` →
     ASCII-глифы, рамки `+---|`, `°C`→`C`, `τ`→`tau`); `initscr`-краш
     (TERM неизвестен) → **фолбэк в plain** без трейса; SIGINT/SIGTERM →
     чистый выход (rc 0).
   - **Plain-рендерер**: строка БЕСУСЛОВНО раз в N с (первая сразу, t=0);
     состав D2 (порядок фиксирован): очередь / обслужено (+delta когда >0) /
     кэш / ошибки (только >0) / ретраи (только ≠0) / prefill+decode tok/s
     (1 знак, `'-'` без `/metrics`) / mem avail/total GiB / swap used/total /
     `gpu: <T>C <sclk>MHz <P>W <B>%` (поле без датчика — `?`) / `cpu: <Tctl>C`;
     «сервер недоступен (нет /stats на :PORT); жду…» — первая сразу, дальше
     раз в 30 с, без дублей (полный срез при недоступности не печатается);
     SIGINT/SIGTERM → «Выход Ctrl-C», rc 0.
   - **`--selfcheck`** (скрытый, не в usage): 15 assert — парсер `/metrics`
     (счётчики, gauge, `_sum`/`_count`, `_bucket`-отсев, `# HELP`-отсев,
     labels-снять), форматер plain по фикст. snap (полный срез и `'-'`/`'?'`),
     обе глиф-команды sparkline, выбор глиф-сета по заданной кодировке/TERM.
   - Env-интерфейс (без argv): `HFCTL_WATCH_PORT` (def 11435),
     `HFCTL_WATCH_INTERVAL` (def 2), `HFCTL_WATCH_CONTAINER`
     (def `hipfire_hipfire_1`), `HFCTL_WATCH_MODEL` (def `-`); любое отсутствие
     — дефолт, не краш.
2. **`lib/commands.sh`**: `cmd_watch()` переписан (разбор `--interval` как
   раньше — `isint`, ≥1, обе формы, die; чтение `HIPFIRE_MODEL` из
   `$STACK_DIR/.env` через `sed … || true`; `exec python3` — rc python = rc
   команды) + аннотации домашним стилем; **`gpu_temp()` удалён**
   (логика перенесена в python `read_gpu()`).
3. **`tpl/python/watch_stats.py` — удалён** (единственный вызывающий был
   `cmd_watch`; `recent_tok_s` — мёртвое поле, из среза D2).
4. **`hfctl`** (диспетчер): строка usage `watch` переписана под новое
   поведение (TUI на TTY / стрим в не-TTY). Поведение разбора не тронуто.
5. **`spec/hfctl.md`** (строка `watch`): полное новое описание (TUI-блоки,
   клавиши, мин. терминал, деградация, пороги, стрим-режим, недоступность,
   выход); старые формулировки («только на ИЗМЕНЕНИИ», «heartbeat»,
   «обменов нет/обработка идёт») удалены.
6. **`README.md`** (строка `watch`): новое описание (TUI/блоки/клавиши/стрим).

## How it was checked internally (commands + results)

- `bash -n hfctl lib/*.sh install.sh` — **ok**.
- `python3 -m py_compile tpl/python/*.py` — **ok**.
- `python3 tpl/python/watch_tui.py --selfcheck` — **15/15 ok, rc 0**
  (в т.ч. точная строка plain = примеру task.md: `… cache: 4421 │ ошибки: 2
  │ ретраи: 1 │ prefill: 84.2 tok/s … gpu: 62C 1500MHz 18W 87% │ cpu: 54C`).
- **pty-чек** (script `/tmp/pty_check.py`, не в репо; `pty.fork` + TIOCSWINSZ
  в дочернем до exec + ввод через master + SIGTERM; **21/21 PASS**):
  - 80×24 xterm-256color, мёртвый порт: нет Traceback; все 5 заголовков
    блоков (движок/железо/скорость/память/логи); статус-бар
    (`hfctl watch`); после `+` → «интервал 3 c» (curses шлёт диф-рендер —
    проверка через resize/SIGWINCH на 5-й с, полный редraw; заодно
    обработан resize); блок «движок» = «недоступен»; строка `mem:` жива
    (DoD 4); зона логов = «логи недоступны: podman не найден» (в контейнере
    нет podman — штатная ветка).
  - 60×15 — нет Traceback (деградация, DoD 3).
  - TERM=dumb — ASCII-рамки `+---|`, нет `┌` (путь ASCII-глифов; дубль
    TERM=posix — см. «Ограничения» 3).
  - TERM=posix (нет terminfo в контейнере) — plain-фолбэк, нет Traceback.
  - TERM='' — plain-фолбэк: строка «сервер недоступен», нет TUI-глифов,
    нет Traceback.
  - `p` — «пауза» в статус-баре.
- **Plain-тайминги** (мёртвый порт, interval=1, пайп): 35 с → **2 строки**
  (t=0, t=30); 65 с → **3 строки** (t=0/30/60, интервал ровно 30 с по
  timestamp'ам, дублей нет); SIGTERM → «Выход Ctrl-C», rc 0. (См.
  «Ограничения» 1 про расхождение с таблицей task.md.)
- **Plain без ESC-байтов**: `watch | cat` → 0 байтов 0x1b (DoD 10, внутренняя
  часть; полная приёмка — EXP-003).
- **Bash-разбор**: `hfctl watch --interval abc|0|0.5|--bogus` → die, rc 1
  (сообщения прежние); `HFCTL_PORT=19999 hfctl watch --interval 1` в пайпе —
  первая строка «недоступен» сразу, «Выход Ctrl-C» на SIGTERM (exec-ветка
  работает, модель из .env — нет .env → `-`).
- **Мёртвый код**: `grep -c 'while :' lib/commands.sh` → 0; `gpu_temp`/
  `watch_stats` — 0 ссылок в `lib/ hfctl tpl/`; `tpl/python/watch_stats.py`
  удалён.
- **stdlib-only**: `grep -E '^(import|from)' tpl/python/watch_tui.py` →
  curses, json, locale, os, signal, subprocess, sys, threading, time,
  urllib.request, collections.deque, glob (всё stdlib).
- **Регрессия** (DoD 9): `bash -n` все sh — ok; `py_compile` все python — ok;
  `HFCTL_PORT=19999 hfctl status --json` → корректный JSON (`health: null`),
  rc 0, не краш; `cmd_status`/`cmd_logs`/`cmd_doctor` в дифе не тронуты.
  `hfctl` без аргументов → usage, **rc=0** (в AGENTS.md-проверке заявлен rc=1
  — pre-existing, см. «Ограничения» 2).

## Not checked internally (внешние прогоны / на машине)

- **Живой сервер**: реальные `/stats`/`/metrics`, live prefill/decode-цифры,
  avg, заполнение sparkline порожним ходом, дельта «обслужено (+N)» на живых
  запросах, пороги цветом на реальных значениях (красный mem < 10 GiB,
  Tctl > 80°, busy<5%+queue>0) — **EXP-001** (визуально) + **EXP-002**.
- **Реальные датчики**: в контейнере нет `/sys/class/drm`/k10temp —
  gpu/cpu-поля были `None` → `?` (ветка проверена), реальные значения —
  **EXP-001** (цифра Tctl обязательна по его PASS-критерию).
- **`podman logs -f` на живом контейнере**: контейнер dev-окружения без
  podman — проверена только ветка «недоступны: podman не найден»; течение
  логов, пауза на живом потоке, «появление контейнера видно само» — **EXP-001**.
- **TUI на реальной SSH-TTY**, терминальный resize на реальной машине,
  alt-экран не просачивается в файл (`hfctl watch > f` в ssh-сессии) —
  **EXP-001 / EXP-003**.
- TERM=posix на машине, где terminfo для `posix` есть (Ubuntu): ожидается
  ASCII-TUI (глифы+рамки), не plain — внутренне воспроизвести нельзя
  (нет terminfo), визуально — **EXP-001** (или отдельная проверка).

## Known limitations / assumptions

1. **Расхождение с таблицей Test strategy task.md (DoD 6)**: таблица ждёт
   «×35 с → ровно 1 строка; ×65 с → ровно 2», но текст §6 task.md («первая
   сразу, далее раз в 30 с»), SPEC.md, brief DoD 6 («как сейчас») и старая
   bash-реализация (`last_down=-999` → печать на первом тике) дают
   **первая строка в t=0 + следующие каждые 30 с** → 35 с = 2 строки,
   65 с = 3 строки (измерено: интервал ровно 30 с, дублей нет). Реализовано
   по тексту/старому поведению (перенос без изменения семантики). Таблица,
   видимо, не считала первую мгновенную строку. **Тестеру: проверять
   периодичность (первая сразу, далее каждые ≥30 с, без дублей), а не
   абсолютное число строк.**
2. **`hfctl` без аргументов → rc=0**, а в AGENTS.md-проверке заявлен rc=1 —
   pre-existing (роутер диспетчера `"" → usage;;` не менял rc); вне scope
   сабстэджа, не тронуто; фикс = одна строка в роутере (см. out-of-scope).
3. **TERM=posix**: в контейнере нет terminfo для `posix` → `initscr` падает →
   штатный plain-фолбэк (проверено: без трейса). Ожидаемое на машине
   «ASCII-глифы при TERM=posix» (task-строка) воспроизведено внутренне
   эквивалентным путём TERM=dumb + `choose_utf8(term='posix')` в selfcheck.
4. **`posix` добавлен в набор не-UTF8 TERM** в `choose_utf8()` (помимо
   `''`/`dumb`) — интерпретация заголовка Design §5 «TERM без UTF-8»
   (иначе строка 3 Test strategy — «TERM=posix → ASCII-глифы» — не
   выполнима на машинах с terminfo).
5. **plain-режим не поднимает лог-поток** (`podman logs -f`) — в составе
   D2-строки логов нет; «логи» — только TUI-блок (DoD 1). Поток стартует
   только в TUI-ветке.
6. **Sparkline при смене интервала**: `deque.maxlen` read-only в Python —
   история переносится пересозданием `deque(list(d), maxlen=ml)` (держит
   последние ml значений = усекает с левого края, старые теряются). Смысл
   task §5 («история переживает смену интервала») сохранён; объект пере-
   привязывается, но не очищается.
7. При W<80 правая часть статус-бара может перезаписать левую (деградация,
   не краш); контрактный минимум — 80×24.

## Out-of-scope proposals

- **`recent_tok_s` в D2-строке** — открытое неблокирующее уточнение task.md;
  решить после EXP-002 (строка в составе D2, не код).
- **`--plain`-флаг** — отвергнут task.md; если появится запрос на явный
  режим, добавляется в `cmd_watch` (python argv уже принимает `--selfcheck`,
  поверхность есть).
- **rc=1 для usage** (pre-existing, «Ограничения» 2) — одна строка в роутере
  диспетчера; отдельная механическая правка, не mix'ить с этим сабстэйджем.
- **pty-чек в репо**: `/tmp/pty_check.py` (21 assert, эфемерный /tmp). Если
  тестеру нужен стабильный носитель — перенос в `flow/external/` или
  отдельный сабстэдж; task.md запрещает тест-файлы в репо, поэтому оставлено
  в /tmp и описано в «How it was checked».
- **Наблюдаемость**: при желании апстрим-логирование жизненного цикла запроса
  (hflab fact «движок не логирует»); к этому сабстэджу отношения не имеет.

## Round 1 (2026-11-12): fix по внешней приёмке (EXP-001 capture, che-FAEX1)

Файл: только `tpl/python/watch_tui.py` (110+/25-). Всё остальное не тронуто;
исправления строго по нумерованному списку review, без переделки остального.

1. **`read_cpu_temp()`: слеш + масштаб.**
   - Было: `_read(hw + 'temp1_input')` (пропущен слеш → путь
     `hwmon3temp1_input`, Tctl всегда `?`) и деление на 1e6.
   - Стало: `_read(hw + '/temp1_input')`, `/1000.0` (миллиградусы) +
     `round(…, 1)`. Отображение Tctl — 1 знак: новый `fmt_c()` (1 знак,
     `None → '?'`), `rows_hardware` `('Tctl', fmt_c(cpu) + g.deg, …)` и plain
     `cpu: %sC` — оба через `fmt_c`. Ожидаемо на FAEX1: `Tctl: 35.9°C`
     (35875 → 35.9).
   - Проверено: selfcheck-кейс `cpu Tctl 35875→35.9` на фейковом дереве
     `/sys/class/hwmon` (hwmon0=coretemp — поиск идёт мимо, hwmon3=k10temp) +
     `cpu fmt 35.9/?`. Реальное отображение только на FAEX1 (EXP).
2. **`read_gpu()` sclk: Гц, не кГц.** Масштаб `freq1_input` 1000 → **1e6**.
   - Проверено: selfcheck-кейс `gpu sclk 600000000→600` (фейковое дерево
     `/sys/class/drm`; `read_gpu(base=…)` теперь принимает каталог — дефолт
     `/sys/class/drm`, selfcheck живой /sys не трогает).
3. **`read_gpu()` busy: путь `card*/device/gpu_busy_percent`.** Чтение вынесено
   из hwmon-цикла (там файла нет — FACTS «Датчики на che-FAEX1») в отдельное
   `_read(card + '/device/gpu_busy_percent')`; `busy_pct` удалён из
   specs-таблицы (таблица стала константой `GPU_SPEC`).
   - Проверено: selfcheck-кейс `gpu busy path card/device` (busy=0 читается).
   - Не проверено: живой idle=0 → `busy: 0%` на FAEX1 — EXP-001.
4. **Статус-бар: наложение «модель»/«интервал».** Геометрия вынесена в
   `status_bar_layout(W, interval, model, paused)` (возвращает поля + x-коорды;
   x_left=1 фиксирован): mid центрируется как раньше, но не далее
   `right_x - len(mid) - 1` (на узком W сдвиг влево от права); **модель
   усечается** до `mid_x - len(prefix) - 1` знаков — на 80 колонках
   `qwen3.8:flash-next-mq4-xts` → `qwen3.8:flas` (12 зн.); поля
   «интервал N c», «логи: live (p)», «q — выход» целы, наложений нет.
   Минимально: перенос интервала на отдельное поле не делался.
   - Проверено: selfcheck-кейс `status bar 80 cols no overlap`
     (`1+len(left) ≤ mid_x`, `mid_x+len(mid) ≤ right_x`, правое поле влезает
     в 80) + **pty-чек 80×24** (`/tmp/pty_statusbar.py`, не в репо): в capture
     строка 0 = `●hfctl watch │ модель qwen3.8:flasинтервал 1 c … q — выход`,
     хвоста модели (`ts`) после mid нет, Traceback=0, все 6 assert PASS.
5. **Docstring'и.** `read_gpu`: `sclk_mhz — freq1_input/1e6 (Гц→MHz)`,
   `power_w — power1_input/1e6 (мкВт→W)`, `busy_pct — card*/device/… (НЕ в
   hwmon)`; `GPU_SPEC` — комментарий с живыми цифрами FAEX1. `read_cpu_temp`:
   `temp1_input/1000 (миллиградусы, 1 знак)`. `power1_input` = **мкВт (µW)** —
   текущий `/1e6` был правильный, код не тронут; docstring указывает мкВт.
6. **`--selfcheck`: 8 новых кейсов по 1–4** (15 → **23**, счётчик
   динамический): `cpu Tctl 35875→35.9`, `cpu fmt 35.9/?`,
   `gpu busy path card/device`, `gpu sclk 600000000→600`,
   `gpu power 5453000→5.453`, `gpu temp mK→C`, `gpu non-AMD skip`
   (карта 0x8086 не читается), `status bar 80 cols no overlap`.
   Фейковые деревья — `tempfile.mkdtemp`, rmtree в finally.

### Внутренние проверки (round 1)

- `bash -n hfctl install.sh lib/*.sh` — ok.
- `python3 -m py_compile tpl/python/*.py` — ok.
- `python3 tpl/python/watch_tui.py --selfcheck` — **23/23 ok, rc 0**.
- pty-чек статус-бара 80×24 (мёртвый порт, interval 1, модель из capture):
  **6/6 PASS**, Traceback=0.
- Регрессия полная, как в round 1: `hfctl` без аргументов → usage (rc=0 —
  pre-existing, «Ограничения» 2); `HFCTL_PORT=19999 hfctl status --json` →
  корректный отказ `{"… "health": null}`, rc 0; stdlib-импорты — только
  stdlib (добавлены `shutil`, `tempfile` — оба stdlib); `tpl/bench/`,
  `spec/state.md` не тронуты; в дифе только `tpl/python/watch_tui.py`.
- **Не проверено внутренне** (только FAEX1): реальные цифры Tctl/sclk/busy
  в TUI-рендере и plain-строке (`sclk: 600 MHz`, `Tctl: 35.9°C`, `busy: 0%`),
  живые логи — EXP-001..003 (EXP-перепуск — оркестратор + тестер после GO).

### Out-of-scope proposals (round 1)

- **FACTS.md (hfctl flow)**: в разделе «Host sysfs» зафиксировано
  `freq1_input (кГц)`, `power1_input (мВт)` — живые цифры из «Датчики на
  che-FAEX1» (Гц, µW) с ним противоречат. Факты правит оркестратор — сюда
  не трогал.
- **GPU temp — целые градусы** (`fmti`): Tctl теперь 1 знак (требование),
  GPU temp в обоих рендерах остался integer (54.375 → «54C»). Если нужен
  тот же 1 знак — отдельная правка (не в нумерованном списке, не делал).
