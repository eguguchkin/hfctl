# Test report: watch-tui

- Дата: 2026-11-12 / round 1 (round 1/3)
- Verdict: **BLOCKED-EXTERNAL** (все внутренние проверки зелёные; EXP-001…003
  созданы, ждёт GO пользователя — живых машин у тестера нет, ssh/podman
  наружу запрещены)

## Internal checks

| DoD item | check | result |
|---|---|---|
| 1 (блоки TUI) | pty-спавн 80×24 (`pty.fork` + TIOCSWINSZ, `TERM=xterm-256color`, мёртвый порт, интервал 1 c, SIGTERM через 10 с, полный редraw через resize на 81×25): в capture заголовки «движок», «железо», «скорость», «память», «логи» + статус-бар «hfctl watch»; строки «live prefill/decode», «avg», «spark», «mem», «KV pages»; Traceback=0 | **OK** |
| 2 (клавиши, статус-бар) | тот же pty-спавн: после `+` в статус-баре «интервал 2 c» (старт interval=1; при дефолте 2 стало бы 3 — логика инкремента одна), после `p` — «пауза»; `live`/`пауза`-переключатель жив | **OK** |
| 3 (80×24 мин, деградация, TERM) | pty 60×15 → Traceback=0 (блоки рисуются); pty 40×10 → Traceback=0; `TERM=dumb` → ASCII-рамки `+---`, без `┌`, Traceback=0 (curses при dumb-terminfo не адресует курсор — часть строк не доходит, процесс жив, SIGTERM → чистый выход = деградация без краш); `TERM=posix` (нет terminfo в контейнере) → plain-фолбэк, Traceback=0; `TERM=''` → plain-фолбэк, Traceback=0 | **OK** (asm: TERM=posix на машине с terminfo → ASCII-TUI, не plain — только внешняя приёмка, см. «Не проверено» dev-report) |
| 4 (server down: TUI жив) | TUI-pty на мёртвом порту: цикл жив 10 с, блок «движок» = «недоступен», строка `mem:` живёт (RAM читается независимо), зона логов = «логи недоступны: podman не найден» (штатная ветка без podman), Traceback=0 | **OK** (реальные датчики/живые логи — EXP-001) |
| 5 (пороги цветом) | `--selfcheck` (15/15, rc 0) + код-ревью: `rows_memory` — red при avail<10 GiB; `rows_hardware` — red при Tctl>80, yellow+bold при busy<5% и queue>0; всё под `has_colors()` (без цветов — без подсветки, не краш) | **OK** (визуально с реальными цифрами — EXP-001) |
| 6 (plain раз в N; недоступен раз в 30 без дублей) | `HFCTL_PORT=19999 ./hfctl watch --interval 1` (пайп): 36 c → строки «сервер недоступен» в t=0 и t=30 (Δ ровно 30 c, дублей нет — уникальные секунды); 66 c → t=0/30/60 (Δ 30 c ×2); SIGTERM → «Выход Ctrl-C», rc 0. **Расхождение с таблицей task.md** («×35 с → ровно 1 строка») подтверждено и разрешено по тексту §6 task.md / brief DoD 6 / SPEC («первая сразу, далее раз в 30 с») — периодичность (Δ≈30 c, без дублей) проверена и зелёная; абсолютное число строк (2 за 35 c) — штатно. ESC-байты (0x1b) в выводе plain: 0 | **OK** (интервалы ~2 c на живом сервере — EXP-002) |
| 7 (общий коллектор, bash только exec, мёртвый код) | `grep -c 'while :' lib/commands.sh` → 0; `gpu_temp`/`watch_stats` — 0 ссылок в `lib/ hfctl tpl/`; `tpl/python/watch_stats.py` удалён (git D); `cmd_watch` = только разбор `--interval` + `sed .env` + `exec python3` (commands.sh:265-283) — просмотрено | **OK** |
| 8 (stdlib, один процесс, поток инертен) | `py_compile` — ok; импорты: curses/json/locale/os/signal/subprocess/sys/threading/time/urllib/deque/glob — только stdlib; `LogStreamer.run` — только subprocess + `buf.append` (deque thread-safe), curses/HTTP не дёргает — код-ревью | **OK** |
| 9 (регрессия) | см. «Regression» ниже | **OK** |
| 11 (доки) | `spec/hfctl.md:60` и `README.md:38` — новые описания (TUI/блоки/клавиши/plain-стрим/30 c/выход); старые формулировки («heartbeat», «только при изменении», «в простое молчит») — 0 совпадений grep в spec/README/hfctl/lib | **OK** |
| — (bash-разбор) | `hfctl watch --interval abc|0|0.5|--bogus` и лишний аргумент → die, rc=1, прежние сообщения | **OK** |
| — (selfcheck) | `python3 tpl/python/watch_tui.py --selfcheck` → 15/15, rc 0 | **OK** |

## Failures (FAIL)

НЕТ — внутренних FAIL-ов нет. Две неблокирующие пометки (не дефекты сабстэджа):

1. `hfctl` без аргументов → **rc=0**, а в AGENTS.md-проверке заявлен rc=1.
   Подтверждено pre-existing: запуск HEAD-копии (`git archive HEAD`) даёт тот
   же rc=0 (роутер `"" → usage;;` не менял rc). Не регрессия сабстэджа;
   у разработчика — в out-of-scope (одна строка в роутере).
2. Таблица Test strategy task.md (DoD 6) «×35 с → ровно 1 строка» против
   текста «первая сразу + далее раз в 30 с» — реализовано по тексту
   (совпадает с brief DoD 6 «как сейчас» и старой bash-семантикой).
   Периодичность зелёная; число строк — следствие, не дефект.

## External experiments

| EXP-id | DoD item | status |
|---|---|---|
| EXP-001-tui-ssh.sh | 1, 2, 5, 10 (TUI 80×24 по SSH: блоки, статус-бар, живые логи, Tctl-цифра, live prefill>0 при генерации) | **created, ждёт GO** (внутренний прогон: `RESULT: BLOCKED — podman не найден` — штатно) |
| EXP-002-plain-pipe.sh | 6, 10 (`hfctl watch --interval 2 \| tee f` 12 c: Δ≈2 c ±0.5, полный срез в каждой строке) | **created, ждёт GO** (внутренний прогон: `RESULT: BLOCKED — hfctl не найден` — штатно) |
| EXP-003-plain-tty-safe.sh | 10 (`hfctl watch > f` в ssh-TTY: 0 байт 0x1b в f, терминал не в alt-экране; визуальное подтверждение — пользователь) | **created, ждёт GO** (внутренний прогон: `RESULT: BLOCKED — stdin не TTY` — штатно) |

Скрипты: `flow/external/EXP-001-tui-ssh.sh`, `EXP-002-plain-pipe.sh`,
`EXP-003-plain-tty-safe.sh` (bash -n ok, +x; самодостаточные: шапка с
целью/prerequisites/командой запуска/PASS-критерием, preflight-проверки с
`RESULT: BLOCKED`, весь вывод + captures в `.result.txt`, финальная строка
`RESULT:`). Запуск — на целевой машине: `ssh -t <host> 'bash -s' < <script>`.

## Regression

| suite | result |
|---|---|
| `bash -n hfctl install.sh lib/*.sh` | green |
| `python3 -m py_compile tpl/python/*.py` | green |
| `hfctl` без аргументов → usage | green (rc=0 — pre-existing, см. пометку 1; HEAD идентичен) |
| `HFCTL_PORT=19999 hfctl status --json` → корректный отказ без краша | green: `{"profile": "27b-single", … "health": null}`, rc=0 |
| `cmd_status`/`cmd_logs`/`cmd_doctor` не тронуты | green: в дифе `lib/commands.sh` 0 изменённых строк внутри этих функций (только `cmd_watch` + удаление `gpu_temp`); `hfctl status` (rc=127 из-за отсутствия podman в контейнере — идентично HEAD-копии, экологично), `hfctl doctor` — rc 0, полная диагностика без краша |
| bench-фикстура не тронута | green: `tpl/bench/` в дифе отсутствует |

## Round 1 (2026-11-12): retest после fix round 1 developer

- Verdict: **FAIL** — один внутренний дефект (пункт 4 нумерованного fix-списка:
  статус-бар — поля прижаты без разрыва). Остальные 4 пункта списка закрыты;
  полная внутренняя регрессия — зелёная; внешние EXP-001…003 созданы
  (EXP-001 скрипт исправлен — см. ниже), ждём GO + перепуск оркестратором.
- Среда: dev-контейнер (без podman/GPU; `/sys/class/hwmon` с k10temp жив —
  Tctl читался реальным), mёртвый порт 19999; pty-спавн через `pty.fork` +
  TIOCSWINSZ, реконструкция экрана — минимальный эмулятор терминала
  (полный UTF-8, CUP/ACH/ERP/SGR/ED/EL, grid), финальный кадр после SIGTERM.
  Скрипты не в репо: `/tmp/tuiretest/` (tui_retest.py, plain_period.sh,
  emulate.py) — эфемерные, как в round 1.

### Закрытие нумерованного списка fix round 1 (dev-report «Round 1» + FACTS)

| # | пункт | проверка | статус |
|---|---|---|---|
| 1 | Tctl 35875→35.9 (слеш + /1000, 1 знак) | selfcheck-кейсы `cpu Tctl 35875→35.9`, `cpu fmt 35.9/?` (в 23/23); код: `_read(hw + '/temp1_input')`, `/1000.0`, `round(…,1)` (watch_tui.py:207-215); **pty-grid: «Tctl: 51.0°C»** — реальный k10temp dev-контейнера, 1 знак, не `?` | **закрыт** |
| 2 | sclk 600000000→600 MHz (Гц, /1e6) | selfcheck `gpu sclk 600000000→600`; масштаб `1e6` в `GPU_SPEC` (watch_tui.py:168); plain-формат `<sclk>MHz` не тронут | **закрыт** |
| 3 | busy из `card*/device/gpu_busy_percent` (не в hwmon) | selfcheck `gpu busy path card/device` (busy=0.0 читается из фейкового `card0/device/`); код: `_read(card + '/device/gpu_busy_percent')` (watch_tui.py:188), busy из specs-таблицы вынесен (таблица = константа `GPU_SPEC`) | **закрыт** |
| 4 | статус-бар 80 кол без наложений | selfcheck `status bar 80 cols no overlap` — зелёный, НО pty-чек 80×24 (модель `qwen3.8:flash-next-mq4-xts`): **row 0 = `●hfctl watch │ модель qwen3.8:flasинтервал 2 c      логи: пауза (p) │ q — выход`** — хвост модели прижат к «интервал» БЕЗ разрыва. Критерий закрытия (задача retest): строка 0 не содержит зацепки вида «flasинтервал» — содержит. Модель усечена (переписывания нет — хвоста `…xts` после mid нет), но поля выглядят слитно; raw-байты подтверждают: после `qwen3.8:flas` идёт `интервал` напрямую (ни пробела, ни прыжка курсора). Selfcheck-ассерт `1+len(left) ≤ mid_x` допускает касание (равенство 34≤34) — поэтому зелёный при дефекте. Внешний дефект «модель и «интервал» наезжают друг на друга» визуально НЕ снят (в capture dev-report round 1 тот же вид: `qwen3.8:flasинтервал 1 c`) | **НЕ закрыт — FAIL** |
| 5 | power 5453000→5.5 W (мкВт, /1e6) | selfcheck `gpu power 5453000→5.453` (коллектор); docstring `мкВт (µW)` (watch_tui.py:165); код не тронут (масштаб был верный). Отображение — целое (`5 W`, `fmti`) — дом-выбор, единый с GPU temp `54C`/sclk `600 MHz` (не пунктом списка не оспаривался; «≈5.5 W» в FACTS — физическое значение, не формат) | **закрыт** (масштаб верен) |

### Internal checks (полная регрессия + ре-чек TUI)

| DoD item | check | result |
|---|---|---|
| 1 (блоки TUI) | pty 80×24 xterm-256color, мёртвый порт, интервал 1, `+` t=2 c, `p` t=4 c, SIGTERM t=9 c, grid: заголовки «движок»/«железо»/«скорость»/«память»/«логи» + «hfctl watch»; Traceback=0 | **OK** |
| 2 (клавиши, статус-бар) | тот же запуск: после `+` → «интервал 2 c», после `p` → «пауза»; статус-бар строка 0 — см. пункт 4 списка выше | **FAIL** (зацепка «flasинтервал», см. Failures) |
| 3 (80×24 мин, деградация, TERM) | pty 60×15 → Traceback=0, блоки рисуются; pty 40×10 → Traceback=0; `TERM=dumb` → ASCII-рамки `+---`, без `┌`, Traceback=0; `TERM=posix` (нет terminfo в контейнере) → plain-фолбэк «сервер недоступен», без TUI-глифов, Traceback=0; `TERM=''` → plain-фолбэк, Traceback=0 | **OK** |
| 4 (server down: TUI жив) | TUI-pty на мёртвом порту: цикл жив 9 c, блок «движок» = «недоступен», `mem: ` живёт (RAM независимо; grid: bar + `14.0/31…`), зона логов = «логи недоступны: podman не найден» (штатная ветка без podman) | **OK** (реальные датчики/логи — EXP-001) |
| 5 (пороги цветом) | `--selfcheck` 23/23 + код-ревью (без изменений против round 1): red avail<10 GiB / Tctl>80 / yellow+bold busy<5%+queue>0, всё под `has_colors()` | **OK** (визуально с реальными цифрами — EXP-001) |
| 6 (plain раз в N; недоступен раз в 30) | `HFCTL_WATCH_PORT=19999 … --interval 1` пайп, 66 c: строки «сервер недоступен» t=0/30/60 (23:19:24→23:19:54→23:20:24, Δ ровно 30 c ×2, дублей нет — уникальные секунды); SIGTERM → «Выход Ctrl-C», rc 0 (расхождение с таблицей task.md «×35 с → 1 строка» — разрешено в round 1 по тексту §6/brief DoD 6) | **OK** (интервалы на живом сервере — EXP-002) |
| 7 (общий коллектор, bash только exec, мёртвый код) | `grep -c 'while :' lib/commands.sh` → 0; `gpu_temp`/`watch_stats` — 0 ссылок в `lib/ hfctl tpl/`; `tpl/python/watch_stats.py` удалён | **OK** |
| 8 (stdlib, поток инертен) | импорты: curses/json/locale/os/shutil/signal/subprocess/sys/tempfile/threading/time/urllib/deque/glob — только stdlib (shutil/tempfile добавлены fix round 1 — оба stdlib); `py_compile` ok | **OK** |
| 9 (регрессия) | см. Regression ниже | **OK** |
| 11 (доки) | `spec/hfctl.md:60` + `README.md:38` — новые описания; старые формулировки («heartbeat», «только при изменении», «в простое молчит», «обменов нет») — 0 совпадений в `spec/hfctl.md`, `README.md`, `hfctl`, `lib/*.sh` (остатки — только в `spec/state.md`/`spec/plan.md`: историка и статусный трекер оркестратора) | **OK** |
| — (bash-разбор) | `hfctl watch --interval abc|0|0.5|--bogus` и лишний аргумент → FATAL-die, rc=1, прежние сообщения (rc проверен без пайпа) | **OK** |
| — (selfcheck) | `python3 tpl/python/watch_tui.py --selfcheck` → **23/23 ok**, rc 0 (8 новых кейсов fix round 1: cpu Tctl/fmt, gpu busy-path/sclk/power/temp/non-AMD, status bar 80 cols) | **OK** |
| — (diff-скоуп) | в рабочем дереве против HEAD только `flow/FACTS.md` (факты оркестратора); продукт — commit `fadb6a0`; `tpl/bench/`, `spec/state.md` не тронуты | **OK** |

### Failures (FAIL)

1. **Статус-бар 80×24: «qwen3.8:flasинтервал» — поля прижаты без разрыва**
   (нумерованный пункт 4 fix round 1 не закрыт).
   - Команда: pty 80×24, `TERM=xterm-256color`,
     `HFCTL_WATCH_PORT=19999 HFCTL_WATCH_INTERVAL=1
     HFCTL_WATCH_MODEL=qwen3.8:flash-next-mq4-xts python3
     tpl/python/watch_tui.py`, после клавиши `+`, реконструкция финального
     кадра (grid), строка 0.
   - Ожидаемо (критерий закрытия retest): строка 0 НЕ содержит «flasинтервал»
     (между полем модели и «интервал N c» — хотя бы 1 колонка разрыва).
   - Факт: `●hfctl watch │ модель qwen3.8:flasинтервал 2 c      логи: пауза
     (p) │ q — выход`.
   - Где подозреваемый: `status_bar_layout()` (watch_tui.py:479-492):
     `model_w = mid_x - len(prefix) - 1` → `1+len(left) == mid_x` ровно
     (касание, разрыва нет); selfcheck (watch_tui.py:571-574) проверяет
     `1+len(left) ≤ mid_x` — равенство проходит. Поправка: гарантировать
     разрыв (`model_w = mid_x - len(prefix) - 2`, при `model_w < 0` — пусто,
     как сейчас) + ужесточить selfcheck до `1+len(left) < mid_x`.
     Визуально: при любой модели длиннее 12 знаков (обе прод-модели: 18 и
     26 зн.) «модель …flasинтервал 2 c» читается как одно слитное слово —
     как и во внешней приёмке round 1 (корень дефекта (б)).
   - Triage: impl → developer. Остальные пункты списка (1, 2, 3, 5) —
     закрыты, не переделывать.

### External experiments (round 2)

| EXP-id | DoD item | status |
|---|---|---|
| EXP-001-tui-ssh.sh | 1, 2, 5, 10 (TUI 80×24 по SSH: блоки, статус-бар, живые логи, Tctl-цифра, live prefill>0 при генерации) | **created, ждёт GO (round 2)** — скрипт исправлен (пункт 3 задачи retest, разрешённая правка артефакта): корень FAIL round 1 (rc=127) — tmux-окно = не интерактивный shell без `.bashrc`, `~/.local/bin` вне PATH → голое `hfctl watch` мгновенно умирало. Команда окна теперь: `export PATH="$HOME/.local/bin:$PATH"; exec '$HFCTL_BIN' watch` (полный путь, который скрипт уже вычисляет в preflight + явный PATH; `bash -n` ok, построение строки проверено). Перепуск — после fix round 2 developer (иначе в capture снова «flasинтервал») |
| EXP-002-plain-pipe.sh | 6, 10 (`hfctl watch --interval 2 \| tee f` ~12 c: ≥5 строк, Δ∈[1.5;2.5] c, полный срез) | **created, ждёт GO (round 2)** — `bash -n` ok; критерии сверены с реальным форматом `fmt_plain` (поля `queue:/served:/cache:/prefill:/decode:/mem:/swap:/gpu:/cpu:` — те же, что в selfcheck-фикстуре; полный путь `$HFCTL_BIN` уже используется) |
| EXP-003-plain-tty-safe.sh | 10 (`hfctl watch > f` в ssh-TTY: 0 байт 0x1b, терминал не в alt-экране) | **created, ждёт GO (round 2)** — `bash -n` ok; критерий (счётчик 0x1b + `echo ok`) не менялся, PASS-логика цела; полный путь `$HFCTL_BIN` уже используется |

### Regression

| suite | result |
|---|---|
| `bash -n hfctl install.sh lib/*.sh` | green |
| `python3 -m py_compile tpl/python/*.py` | green |
| `hfctl` без аргументов → usage | green (rc=0 — pre-existing, пометка round 1; не регрессия) |
| `HFCTL_PORT=19999 hfctl status --json` → корректный отказ без краша | green: `{"profile": "27b-single", "autostart": false, "watchdog": false, "health": null}`, rc=0 |
| `cmd_status`/`cmd_logs`/`cmd_doctor` не тронуты | green: диф против `812b6a0^` — 0 изменённых строк в этих функциях; `hfctl doctor` — rc 0, полная диагностика до «health» без краша |
| bench-фикстура, `spec/state.md` не тронуты | green: в рабочем дифе только `flow/FACTS.md` |

Next (по протоколу): tester FAIL → fix round developer (triage: impl; пункт 1
Failures), затем retest + перепуск EXP-001…003 по GO пользователя.

## Round 2 (2026-11-13): retest после fix round 2 developer

- Verdict: **BLOCKED-EXTERNAL** — все внутренние проверки зелёные, в т.ч.
  закрытие единственного blocking-пункта retest round 1; EXP-001…003 без
  изменений с моего retest, ждут GO + перепуска оркестратором (ssh/podman
  наружу запрещены гигиеной).
- Среда: та же что в retest round 1 (dev-контейнер, мёртвый порт 19999,
  k10temp жив); pty-скрипт — мой же эмулятор `/tmp/tuiretest/` (Grid/run_pty
  переиспользованы без изменений), round-2-версия сценариев
  `/tmp/tuiretest/r2_check.py` + прямой чек геометрии `r2_layout.py`;
  capture финального кадра — `/tmp/tuiretest/r2_A_grid.txt`.

### Закрытие blocking-пункта round 1 (Failures #1: «flasинтервал»)

| # | критерий retest | проверка | статус |
|---|---|---|---|
| a | capture не содержит «flasинтервал»/«flaинтервал» | pty 80×24 xterm-256color, мёртвый порт, interval 1, модель `qwen3.8:flash-next-mq4-xts`, `+` t=2 c, `p` t=4 c, SIGTERM t=9 c: row0 = `●hfctl watch │ модель qwen3.8:fla интервал 2 c      логи: пауза (p) │ q — выход`; «flasинтервал»/«flaинтервал» в capture — **0 совпадений** | **закрыто** |
| b | гарантированный разрыв ≥1 колонка до «интервал» | колонка перед «интервал» в row0 = пробел (проверено по позиции); прямой чек `status_bar_layout(80, 2, модель, False)`: left=32, mid_x=34, gap=+1 (до правки gap=0 — касание); код: `model_w = mid_x - len(prefix) - 2` (watch_tui.py:491), docstring «ни наложений, ни касания» | **закрыто** |
| c | selfcheck-ассерт строго `<` | watch_tui.py:574-575: `1 + len(left) < mid_x` (кейс переименован в `status bar 80 cols gap≥1`, ровно 80 кол с прод-моделью); равенство-касание теперь провал; `--selfcheck` → **23/23 ok, rc 0** | **закрыто** |
| d | узкие W (60×15, 40×10) — не хуже доправки | pty 60×15: Traceback=0, блоки «движок»/«железо» рисуются; pty 40×10: Traceback=0; прямой чек геометрии по W=80/60/40/30/20/12/8: при W≤60 поля left/mid_x **байто-идентичны старой формуле** (`model_w<0` → модель пуста в обеих) — деградация не изменилась, ухудшения нет. (Оверлэп mid/right при W<80 — pre-existing деградация, dev-report «Ограничения» 7, контрактный минимум 80×24; идентичен доправки) | **закрыто** |

pty-прогон round 2: **25/25 PASS** (сценарии A 80×24 / B 60×15 / C 40×10 /
D TERM=dumb / E TERM=posix / F TERM=''; Traceback=0 во всех).

### Internal checks (полная регрессия)

| DoD item | check | result |
|---|---|---|
| 1 (блоки TUI) | pty 80×24: заголовки «движок»/«железо»/«скорость»/«память»/«логи» + «hfctl watch», Traceback=0 | **OK** |
| 2 (клавиши, статус-бар) | `+` → «интервал 2 c», `p` → «пауза»; статус-бар — см. таблицу выше (закрыто) | **OK** |
| 3 (мин. терм, деградация, TERM) | 60×15, 40×10 — Traceback=0; TERM=dumb → ASCII-рамки `+---` без `┌`; TERM=posix, TERM='' → plain-фолбэк «сервер недоступен», без TUI-глифов; все Traceback=0 | **OK** |
| 4 (server down: TUI жив) | mёртвый порт: «недоступен», `mem: ` живёт, цикл 9 c без краха | **OK** (реальные датчики/логи — EXP-001) |
| 5 (пороги цветом) | selfcheck 23/23; код-ревью порогов без изменений против round 1 (red avail<10 GiB / Tctl>80 / yellow+bold, всё под `has_colors()`) | **OK** (визуально — EXP-001) |
| 6 (plain раз в N; недоступен раз в 30) | `HFCTL_PORT=19999 ./hfctl watch --interval 1` (через диспетчер, пайп) 66 c: «сервер недоступен» t=00:27:19/00:27:50/00:28:20 — Δ 31/30 c (тик-квант 1 c + усечение до секунд, паттерн round 1), дублей нет (уникальные секунды); SIGTERM → «Выход Ctrl-C», rc 0; ESC-байты (0x1b) в plain-выводе: 0 | **OK** (интервалы на живом сервере — EXP-002) |
| 7 (общий коллектор, bash только exec, мёртвый код) | `grep -c 'while :' lib/commands.sh` → 0; `gpu_temp`/`watch_stats` — 0 ссылок; `tpl/python/watch_stats.py` отсутствует | **OK** |
| 8 (stdlib, один процесс, поток) | импорты: curses/json/locale/os/shutil/signal/subprocess/sys/tempfile/threading/time/urllib/deque/glob — только stdlib; `py_compile` ok | **OK** |
| 9 (регрессия) | см. Regression ниже | **OK** |
| 11 (доки) | не тронуты этой правкой (диф-скоуп = только `watch_tui.py`); round-1-проверка описаний действительна | **OK** |
| — (bash-разбор) | `watch --interval abc/0/0.5/--bogus` + лишний аргумент → FATAL-die, rc=1, прежние сообщения (5/5) | **OK** |
| — (selfcheck) | `--selfcheck` → 23/23, rc 0 (кейс `status bar 80 cols gap≥1` строгий) | **OK** |
| — (diff-скоуп) | продукт против HEAD: только `tpl/python/watch_tui.py` (2 правки: формула + selfcheck; 11+/4-); `tpl/bench/`, `spec/state.md`, `hfctl`, `lib/`, `install.sh`, `README.md` — 0 изменений | **OK** |

### Failures (FAIL)

НЕТ.

### External experiments (round 2)

| EXP-id | DoD item | status |
|---|---|---|
| EXP-001-tui-ssh.sh | 1, 2, 5, 10 (TUI 80×24 по SSH: блоки, статус-бар gap≥1, живые логи, Tctl-цифра, live prefill>0) | **created, ждёт GO (round 2)** — без изменений с моего retest (fix: полный путь `$HFCTL_BIN` + `export PATH` в tmux-команде, строка 57); `bash -n` ok, +x; перепуск после перепуска оркестратором (новый бинарь на машине) |
| EXP-002-plain-pipe.sh | 6, 10 (plain-стрим `\| tee f` ~12 c: Δ∈[1.5;2.5] c, полный срез) | **created, ждёт GO (round 2)** — в дифе против HEAD отсутствует (не тронут); `bash -n` ok, +x |
| EXP-003-plain-tty-safe.sh | 10 (plain в ssh-TTY: 0 байт 0x1b, не alt-экран) | **created, ждёт GO (round 2)** — в дифе против HEAD отсутствует (не тронут); `bash -n` ok, +x |

### Regression

| suite | result |
|---|---|
| `bash -n hfctl install.sh lib/*.sh` | green |
| `python3 -m py_compile tpl/python/*.py` | green |
| `hfctl` без аргументов → usage | green (rc=0 — pre-existing, пометка round 1; не регрессия) |
| `HFCTL_PORT=19999 hfctl status --json` → корректный отказ без краша | green: `{"profile": "27b-single", "autostart": false, "watchdog": false, "health": null}`, rc=0 |
| `hfctl status` (без podman в контейнере) | green: rc=127 «podman: command not found» — идентично HEAD, экологично |
| `hfctl doctor` | green: rc 0, полная диагностика до «(сервер не отвечает)» без краша |
| `cmd_status`/`cmd_logs`/`cmd_doctor` не тронуты | green: продукт-диф против HEAD = только `tpl/python/watch_tui.py` |
| bench-фикстура, `spec/state.md` не тронуты | green: md5 `253c7ac5…` (канон), в дифе отсутствуют |
| EXP-скрипты без изменений с retest | green: в дифе только `EXP-001` (мой fix, 9+/1-); `bash -n` 3/3 ok, +x |

Next (по протоколу): BLOCKED-EXTERNAL → оркестратор накапливает EXP-001…003;
после пуша коммита fix round 2 и GO пользователя — перепуск EXP на живой
машине, вердикт обновляется на PASS/FAIL по `.result.txt`.

## Round 3 (2026-11-13): retest после fix round 3 developer (D8 честные метрики + D9 сид логов)

- Verdict: **BLOCKED-EXTERNAL** — все внутренние проверки зелёные, в т.ч.
  D8-семантика (подписи TUI + plain-срез, грейп «live»-обещаний = 0) и D9
  (сид/живой поток верифицированы fake-podman симом, «без podman» — молча,
  без трейса); EXP-001 переписан под реальность движка (D8/D9-критерии),
  ждёт GO + перепуска на машине B (ssh/podman наружу запрещены гигиеной).
- Среда: та же, что retest round 2 (dev-контейнер без podman/GPU, мёртвый
  порт 19999, k10temp жив — Tctl читался реальным); эмулятор `/tmp/tuiretest/`
  (Grid/run_pty переиспользованы как есть), новые артефакты: fake podman-шим
  `/tmp/tuiretest/r3podman/podman` (ветка по наличию `-f`: seed =
  `STARTUP-A/STARTUP-B/SEED-LAST`, live = `SEED-LAST` + `LIVE-1/LIVE-2`
  через 1 с) и fake-server `/tmp/tuiretest/r3_fake_server.py` (:19998,
  prefill-гистограмма 900/12 → avg 75.0, `recent_tok_s` 61.5 — свои цифры,
  не фикстуры разработчика).
- pty-прогон round 3 (`/tmp/tuiretest/r3_check.py`, сценарии A–H): **45/45
  PASS**. Кадр: `/tmp/tuiretest/r3_A_grid.txt` (+ r3_B_grid.txt, r3_C_grid.txt).

### D8 — честные метрики (decode = recent_tok_s, prefill = avg гистограммы)

| проверка | результат |
|---|---|
| grep «live prefill / live decode / live tok / live-скорость» по `spec/hfctl.md`, `README.md`, `hfctl`, `lib/*.sh`, `watch_tui.py` | **0 совпадений** (rc=1); так же «avg prefill»/«avg decode» — 0 |
| grep старых формулировок («heartbeat», «только при изменении», «в простое молчит», «обменов нет») там же | **0 совпадений** |
| TUI-подписи (pty A, 80×24, мёртвый порт): `decode: - tok/s (последний)`, `prefill: - tok/s (avg)` в блоке «скорость»; «spark prefill»/«spark decode» на месте; старые подписи `live prefill`/`live decode`/`avg prefill`/`avg decode` — 0 совпадений в capture | **OK** |
| plain-срез на живом fake-server (interval 1, 5 с): `… prefill: 75.0 tok/s (avg) │ decode: 61.5 tok/s (последний) …` — decode из `recent_tok_s`, prefill = _sum/_count (900/12=75.0) | **OK** (каждая из 5 строк; `/tmp/tuiretest/r3_plain_live.out`) |
| дельты счётчиков — только sparkline/активность, не tok/s | код: `Deltas.update` — Δprompt/Δcompletion **токенов за тик** (int), `prev_time`/Δ-Δt удалены; потребители — `push_spark` (deque → sparkline) и `served_delta` (в plain `served (+N)`); ни в `fmt_plain`, ни в `rows_speed` Δ не форматится как tok/s — просмотрено | **OK** |

### D9 — сид лог-зоны (`--tail 50` + live `--tail 1 -f`)

| проверка | результат |
|---|---|
| код: `seed()` = `podman logs -t --tail 50` (без -f, таймаут 10 с), вызывается синхронно в `run_tui()` ДО первой рамки; live = `podman logs -t --tail 1 -f`; err-ветка `draw()` удалена — «(ждём логи…)» только пока buf пуст | просмотрено (watch_tui.py:320-333, 341, 778, 863-873) | **OK** |
| без podman (pty A): «(ждём логи…)» в зоне, «логи недоступны» — 0 совпадений, Traceback=0 (молча, без трейса) | **OK** |
| fake podman, seed-режим (pty B): сид-строки `STARTUP-A`, `STARTUP-B`, `SEED-LAST` в финальной рамке; «(ждём логи…)» и «логи недоступны» — отсутствуют | **OK** (шим вызывается именно БЕЗ `-f` — сид-ветка) |
| fake podman, live-режим (pty C): `SEED-LAST`, `LIVE-1`, `LIVE-2` в финальной рамке (live-поток течёт), «(ждём логи…)» — отсутствует | **OK** (шим вызывается с `-f` — live-ветка; точный argv сверён по коду) |

### Plain-срез (DoD 6)

| проверка | результат |
|---|---|
| live fake-server, interval 1, 5 с: 5 строк, Δ ровно 1 с; полный срез D2 в каждой: `queue: 2 │ served: 55 │ cache: 300 │ prefill: 75.0 tok/s (avg) │ decode: 61.5 tok/s (последний) │ mem: 16.5/31.3 GiB │ swap: 0.0/0.0 GiB │ gpu: ?C ?MHz ?W ?% │ cpu: 58.6–59.6C` (cpu — реальный k10temp; gpu — `?`, датчика в контейнере нет — штатно) | **OK**, ESC-байты (0x1b): 0 |
| мёртвый порт, interval 1, 66 с: «сервер недоступен» t=01:35:41/36:11/36:41 — Δ ровно 30 с ×2, без дублей (уникальные секунды); SIGTERM → «Выход Ctrl-C», **rc=0** | **OK** (расхождение с таблицей task.md «×35 с → 1 строка» — разрешено в round 1 по тексту §6/brief DoD 6), ESC: 0 |

### Полная регрессия

| suite | result |
|---|---|
| `bash -n hfctl install.sh lib/*.sh` | green |
| `python3 -m py_compile tpl/python/*.py` | green |
| `--selfcheck` | **28/28 ok**, rc 0 (5 новых кейсов round 3: decode=recent_tok_s, decode no data → -, prefill avg 1200/14, prefill avg no samples → None, seed без podman не падает) |
| pty 80×24 (A): 5 заголовков + статус-бар; «недоступен» (мёртвый порт); `mem: ` живёт; `+` → «интервал 2 c», `p` → «пауза»; разрыв ≥1 кол перед «интервал» (контракт round 2 сохранён); D8-подписи; D9 «без podman» — см. выше | **OK**, Traceback=0 |
| pty 60×15 / 40×10 (D/E) | Traceback=0, блоки рисуются | **OK** |
| TERM=dumb (F): ASCII-рамки `+---`, без `┌`; TERM=posix (G), TERM='' (H): plain-фолбэк «сервер недоступен», без TUI-глифов | все Traceback=0 | **OK** |
| bash-разбор: `watch --interval abc/0/0.5/--bogus` + лишний аргумент | die, rc=1, прежние сообщения (5/5) | **OK** |
| `hfctl` без аргументов | usage, rc=0 (pre-existing, пометка round 1; не регрессия) | **OK** |
| `HFCTL_PORT=19999 hfctl status --json` | корректный отказ `{"profile": "27b-single", "autostart": false, "watchdog": false, "health": null}`, rc=0 | **OK** |
| `hfctl doctor` | rc 0, полная диагностика до «(сервер не отвечает)» без краша | **OK** |
| `cmd_status`/`cmd_logs`/`cmd_doctor` не тронуты | green: продукт-диф = только `tpl/python/watch_tui.py`, `spec/hfctl.md`, `README.md` (по 1 строке — строка `watch`); `hfctl`, `lib/`, `install.sh` — 0 изменений | **OK** |
| bench-фикстура, `spec/state.md` не тронуты | green: md5 `253c7ac50857fe6d0e10fb0d2c5e35c0` (канон); в дифе отсутствуют | **OK** |
| доки (DoD 11): `spec/hfctl.md:60` + `README.md:38` | честные метрики (decode=recent_tok_s «(последний)» / prefill=avg гистограммы «(avg)» / sparkline=Δсчётчиков за тик — активность, не скорость); сид `--tail 50` + live, условие «(ждём логи…)»; plain-срез с новыми суффиксами — сверено с поведением | **OK** |

### Failures (FAIL)

НЕТ.

### External experiments (round 3)

| EXP-id | DoD item | status |
|---|---|---|
| EXP-001-tui-ssh.sh | 1, 2, 5, 10 (TUI 80×24 по SSH: 5 блоков, статус-бар без наложений, сид-строки логов, Tctl-число, D8-метрики после запроса) | **created (round 3), ждёт GO** — скрипт переписан под реальность движка (правка разрешена задачей retest): (а) «live prefill > 0» заменено — capture 3 (после завершения фонового запроса; скрипт теперь ждёт его до 180 с и снимает отдельный capture) содержит `prefill: N tok/s (avg)` с N > 0 и `decode: N tok/s (последний)` — число; (б) «(ждём логи…)» — НЕ критерий FAIL: критерий — в зоне логов capture 1 ≥1 строка, не «(ждём логи…)» и не «логи недоступны» (парсер зоны: строка «  логи» → контент до нижней рамки); (в) остальное как было: 5 блоков, статус-бар (1 кол. разрыва перед «интервал», нет «…flasинтервал»), Tctl-число. `bash -n` ok, +x; логика анализа проверена на синтетических captures: PASS-кейс (все критерии) + 2 FAIL-кейса (пустая зона + decode '-'; наложение «flasинтервал») — детект корректный |
| EXP-002-plain-pipe.sh | 6, 10 (plain-стрим `\| tee f` ~12 c: Δ∈[1.5;2.5] c, полный срез) | **created (round 3), ждёт GO** — без изменений; критерии остаются валидными для нового формата: проверка по именам полей (`queue:/served:/cache:/prefill:/decode:/mem:/swap:/gpu:/cpu:`) — суффиксы значений `(avg)`/`(последний)` на неё не влияют |
| EXP-003-plain-tty-safe.sh | 10 (plain в ssh-TTY: 0 байт 0x1b, не alt-экран) | **created (round 3), ждёт GO** — без изменений; критерий (счётчик 0x1b + `echo ok`) не зависит от формата строки |

Замечание к EXP-001: дубль последней строки сида при старте live-потока
(`--tail 1 -f` ре-эмитит) — штатно, задокументировано (dev-report round 3,
«Ограничения» 1); на критерии не влияет (зона содержит ≥1 реальную строку),
визуальный вид — в capture'ах `.result.txt`.

### Next

BLOCKED-EXTERNAL (как round 2): оркестратор накапливает EXP-001…003; на
реальной машине (машина B) нужен НОВЫЙ бинарь с round 3 (текущий — до D8/D9):
доставка commit → clone + install.sh (решение за пользователем, см. STATE.md).
После GO — перепуск EXP-001..003, вердикт обновляется на PASS/FAIL по
`.result.txt`; при внутренне-зелёном и внешнем PASS → reviewer.

## Round 1 (2026-11-13, fix-цикл 2): retest после fix-цикл 2 round 1 developer (stderr-фикс лог-потока)

- Verdict: **BLOCKED-EXTERNAL** — все внутренние проверки зелёные, в т.ч.
  замыкание дефекта (ERRNULL→STDOUT в обоих podman-вызовах, воспроизведение
  до-фикс копия 28/30 rc 1, fake-podman-в-STDERR-pty-сценарий: строка в
  лог-зоне); EXP-001…003 без изменений, ждём GO + перепуск оркестратором
  (ssh/podman наружу запрещены гигиеной).
- Среда: та же, что retest round 3 (dev-контейнер без podman/GPU, мёртвый
  порт 19999, k10temp жив — Tctl читался реальным); эмулятор `/tmp/tuiretest/`
  (Grid/run_pty переиспользованы без изменений), новые артефакты:
  `/tmp/tuiretest/r1f2_check.py` (pty-прогон), `/tmp/tuiretest/r1f2podman/podman`
  (fake-podman-шим, **все логи в STDERR** — точное воспроизведение FACTS.md),
  `/tmp/tuiretest/r1f2_plain_down.sh` (plain-периодичность),
  `/tmp/tuiretest/r1f2/prefix_watch_tui.py` (до-фикс копия для воспроизведения).
  Показательное: при первом прогоне сценарий G упал на правах 644 у СВОЕГО
  шима (не +x) — артефакт тест-харнеса, не продукт; после `chmod 755` — 33/33.

### Замыкание дефекта (корень FAIL EXP-001 round 3: `stderr=DEVNULL`)

| # | критерий | проверка | статус |
|---|---|---|---|
| 1 | оба podman-вызова — `stderr=STDOUT` | код: `seed()` (watch_tui.py:331) и `_spawn_once()` (watch_tui.py:346) — `stdout=subprocess.PIPE, stderr=subprocess.STDOUT`; grep `subprocess.DEVNULL` по файлу — **0 совпадений** (DEVNULL остался только в docstring как историческая пометка) | **закрыто** |
| 2 | selfcheck: fake-podman в STDERR → строка в ring-buffer | `--selfcheck` → **30/30 ok, rc 0**; два новых кейса `seed: stderr→stdout` и `live: stderr→stdout`: shim `#!/bin/sh; echo fake-log-line >&2` (mkdtemp, chmod 755, в начало PATH) → `list(buf) == ['fake-log-line']` в обоих (seed и live) | **закрыто** |
| 3 | воспроизведение: до-фикс копия падает ровно на этих кейсах | `sed 's/stderr=subprocess.STDOUT/stderr=subprocess.DEVNULL/'` (2 замены) → `--selfcheck`: **28/30, rc 1**, FAIL = ровно `seed: stderr→stdout` и `live: stderr→stdout` — идентично артефакту разработчика (dev-report fix-цикл 2 round 1) | **закрыто** |
| 4 | pty-сценарий G (80×24 + fake-podman В STDERR): строка в лог-зоне, дефект EXP-001 снят | `fake-log-line` в финальном кадре, «(ждём логи…)» — 0 совпадений, «логи недоступны» — 0, Traceback=0 (кадр `/tmp/tuiretest/r1f2_G_grid.txt`); контраст со сценарием A (без podman) — «(ждём логи…)» на месте | **закрыто** |

### Internal checks (полная регрессия)

| DoD item | check | result |
|---|---|---|
| 1 (блоки TUI) | pty 80×24 xterm-256color, мёртвый порт, `+` t=2, `p` t=4, SIGTERM t=9: заголовки «движок»/«железо»/«скорость»/«память»/«логи» + «hfctl watch»; D8-подписи `decode: - tok/s (последний)`, `prefill: - tok/s (avg)`; Traceback=0 | **OK** |
| 2 (клавиши, статус-бар) | `+` → «интервал 2 c», `p` → «пауза»; контракт round 2 сохранён: «flasинтервал»/«flaинтервал» — 0 совпадений, `qwen3.8:fla` + разрыв ≥1 кол перед «интервал» (row0 = `●hfctl watch │ модель qwen3.8:fla интервал 2 c      логи: пауза (p) │ q — выход`) | **OK** |
| 3 (мин. терм, деградация, TERM) | pty 60×15: Traceback=0, блоки рисуются; pty 40×10: Traceback=0; TERM=dumb: ASCII-рамки `+---`, без `┌`; TERM=posix / TERM='': plain-фолбэк «сервер недоступен», без TUI-глифов — все Traceback=0 | **OK** |
| 4 (server down: TUI жив) | мёртвый порт: «недоступен», `mem: ` живёт (RAM независимо), цикл 9 c без краха | **OK** (реальные датчики/логи — EXP-001) |
| 5 (пороги цветом) | selfcheck 30/30; код-ревью порогов без изменений против round 3 | **OK** (визуально — EXP-001) |
| 6 (plain раз в N; недоступен раз в 30) | `HFCTL_PORT=19999 ./hfctl watch --interval 1` (пайп, мёртвый порт, 66 c): «сервер недоступен» t=08:20:44/21:14/21:45 — Δ ровно 30/31 c (тик-квант, паттерн round 1–3), дублей нет (3 уникальные секунды); SIGTERM → «Выход Ctrl-C», rc 0; ESC-байты (0x1b): 0 | **OK** (интервалы на живом сервере — EXP-002) |
| 7 (общий коллектор, bash только exec, мёртвый код) | без изменений против round 3 (diff-скоуп = только `watch_tui.py`): `grep -c 'while :' lib/commands.sh` → 0; `gpu_temp`/`watch_stats` — 0 ссылок; `cmd_watch` = разбор + `exec python3` | **OK** |
| 8 (stdlib, один процесс, поток) | импорты без изменений против round 3 (только stdlib); `py_compile` ok | **OK** |
| 9 (регрессия) | см. Regression ниже | **OK** |
| 11 (доки) | `spec/hfctl.md`/`README.md` этой правкой НЕ тронуты (diff-скоуп = `watch_tui.py`); round-3 проверка описаний действительна; grep «live prefill/live decode/heartbeat/только при изменении/в простое молчит» по spec/README/hfctl/lib/watch_tui.py — **0 совпадений** | **OK** |
| — (bash-разбор) | `watch --interval abc/0/0.5/--bogus` + лишний аргумент → FATAL-die, rc=1, прежние сообщения (5/5) | **OK** |
| — (selfcheck) | `--selfcheck` → **30/30 ok**, rc 0 (2 новых кейса fix-цикл 2) | **OK** |
| — (diff-скоуп) | продукт против HEAD: только `tpl/python/watch_tui.py` (10+/5-: docstring'и + 2 `STDERR→STDOUT` + 2 selfcheck-кейса); `tpl/bench/`, `spec/state.md`, `spec/hfctl.md`, `README.md`, `hfctl`, `lib/`, `install.sh` — 0 изменений | **OK** |

### Failures (FAIL)

НЕТ.

### External experiments (round 1, fix-цикл 2)

| EXP-id | DoD item | status |
|---|---|---|
| EXP-001-tui-ssh.sh | 1, 2, 5, 10 (TUI 80×24 по SSH: 5 блоков, статус-бар, сид-строки логов, Tctl-число, D8-метрики после запроса) | **created (round 2-cycle-2), ждёт GO** — без изменений (в дифе отсутствует; `bash -n` ok, +x); критерии round 3 (зона логов ≥1 строка, не «(ждём логи…)»/«логи недоступны»; prefill>0 + decode-число после done) — именно их закрывает stderr-фикс; перепуск на машине B — оркестратором после GO (нужен НОВЫЙ бинарь с fix-цикл 2: текущий на машине — `9265176`, до фикса) |
| EXP-002-plain-pipe.sh | 6, 10 (plain-стрим `\| tee f` ~12 c: Δ∈[1.5;2.5] c, полный срез) | **created (round 2-cycle-2), ждёт GO** — без изменений; `bash -n` ok, +x |
| EXP-003-plain-tty-safe.sh | 10 (plain в ssh-TTY: 0 байт 0x1b, не alt-экран) | **created (round 2-cycle-2), ждёт GO** — без изменений; `bash -n` ok, +x |

### Regression

| suite | result |
|---|---|
| `bash -n hfctl install.sh lib/*.sh` | green |
| `python3 -m py_compile tpl/python/*.py` | green |
| `--selfcheck` | **30/30 ok**, rc 0 |
| pty-прогон round 1 (A–G): 80×24 / 60×15 / 40×10 / TERM=dumb / TERM=posix / TERM='' / fake-podman-в-STDERR | **33/33 PASS**, Traceback=0 во всех |
| `hfctl` без аргументов | usage, rc=0 (pre-existing, пометка round 1; не регрессия) |
| `HFCTL_PORT=19999 hfctl status --json` | корректный отказ `{"profile": "27b-single", "autostart": false, "watchdog": false, "health": null}`, rc=0 |
| `hfctl doctor` | rc 0, полная диагностика до «(сервер не отвечает)» без краша |
| `cmd_status`/`cmd_logs`/`cmd_doctor` не тронуты | green: продукт-диф = только `tpl/python/watch_tui.py` (`lib/commands.sh` — 0 изменений) |
| bench-фикстура, `spec/state.md` не тронуты | green: md5 `253c7ac50857fe6d0e10fb0d2c5e35c0` (канон); в дифе отсутствуют |
| EXP-скрипты | green: 3/3 в дифе отсутствуют, `bash -n` ok, +x |

### Next

BLOCKED-EXTERNAL (как round 3): внутреннее — всё зелёное; оркестратор
накапливает EXP-001…003. На машина B нужен НОВЫЙ бинарь с fix-цикл 2 (текущий —
`9265176`, до stderr-фикса): доставка — решение пользователя (STATE.md).
После GO — перепуск EXP-001..003, вердикт обновляется на PASS/FAIL по
`.result.txt`; при внешнем PASS → reviewer.

## Round 2 (2026-11-13, fix-цикл 2): parcer fix

- Verdict: **BLOCKED-EXTERNAL** — ложный FAIL EXP-001 подтверждён как баг
  парсера лог-зоны в МОЁМ скрипте (не продукта); парсер исправлен
  (EXP-001-артефакт), продукт НЕ тронут (diff-скоуп: только
  `flow/external/EXP-001-tui-ssh.sh` + мои артефакты); внутренняя
  перепроверка по локальной реконструкции capture в реальной форме
  `│ логи … │` — PASS на обеих формах; ждёт перепуск EXP-001 на машине B
  оркестратором (бинарь там УЖЕ актуальный — `7ccee44`, recreate не нужен).
- Triage оркестратора (строка history.md 2026-11-13): **test** — баг в
  EXP-001; диагностика: реальная строка-заголовок лог-зоны в tmux-capture
  80×24 — `│ логи<пробелы>│` (полная 80-колоночная строка рамки, правая
  граница есть); старое старт-условие `s.lstrip().startswith('логи')` его не
  распознаёт (первый символ — `│`) → зона `[]` → ложный FAIL при живых
  per-request-строках, Tctl=77.2, prefill avg=889.1, decode=48.4 в capture.

### Замыкание (правка парсера EXP-001)

| # | требование fix | что сделано | статус |
|---|---|---|---|
| 1 | `logzone_lines()` распознаёт заголовок И в рамочном `│ логи…`, И в упрощённом виде; стоп «нижняя рамка» сохранён; контент — срез левой рамки/2 пробелов, правая «│» strip | новый парсер: заголовок — `логи` после lstip либо после одной левой рамки `│`; режим `framed` запоминается по форме заголовка; стоп-условие `└`/`+--` не тронуто; контент: framed — `core[1:].lstrip()`, plain — `s[2:]`/lstrip (как было), в обоих `rstrip('│+')` — правая рамка отбрасывается; форма подтверждена по продукту: `box(win, 0, log_top, W, log_h)` + `put(log_top+1, 2, 'логи')` (watch_tui.py:892-893) — рамка на всю ширину, правая `│` в col 79 | **закрыто** |
| 2 | самопроверка парсера: 2 варианта capture (рамка/без) → assert ≥1 строки; провал → `RESULT: ERROR — парсер`, не FAIL | в анализ-блок EXP-001 перед анализом добавлены mini-фикстуры `FIX_FRAMED` (`│ логи…│` + 2 строки + `└…┘`) и `FIX_PLAIN` (`  логи` + 2 строки + `+--…+`): assert ≥1 строки на обоих И правая рамка отброшена; провал — `АНАЛИЗ: ERROR — парсер: самопроверка не прошла` + `sys.exit(1)`; bash-tail — новая ветка `elif grep -q '^АНАЛИЗ: ERROR'` → `RESULT: ERROR — парсер лог-зоны: … (продукт не виноват)`; `|| true` у python3-вызова снят (rc честный, set -e нет) | **закрыто** |
| 3 | перепроверка по локальному capture-подобному тексту в реальной форме `│ логи…│` (машина B у меня нет — без ssh, по гигиене) | локальная реконструкция 80×24 экрана (`/tmp/parcertest/gen_fixtures.py`: row0 со статус-баром, 4 блока, лог-зона `│ логи<73 sp>│` + per-request-строки + `└…┘`, цифры из диагностики оркестратора); python-блок анализа извлечён из скрипта дословно (`awk` между маркерами — исполняется ТОТ ЖЕ код, что будет на машине B); CASE 1 (framed, cap1+cap3): **`АНАЛИЗ: все критерии выполнены (Tctl=77.2C, prefill avg=889.1 tok/s, decode=48.4 tok/s, строк в зоне логов: 2)`** — ровно цифры из result-файла машина B; CASE 2 (пустая зона `(ждём логи…)`): `АНАЛИЗ: FAIL — зона логов без стартовых строк` — FAIL-семантика цела (fails-as-should); CASE 3: парсер на mini-фикстурах рамки/упрощённой — 2 строки на обоих, правая рамка отброшена; воспроизведение корня: СТАРЫЙ парсер на той же рамочной форме → `[]` (ложный FAIL) | **закрыто** |

### Failures (FAIL)

НЕТ.

### External experiments (round 2, fix-цикл 2)

| EXP-id | DoD item | status |
|---|---|---|
| EXP-001-tui-ssh.sh | 1, 2, 5, 10 (TUI 80×24 по SSH: 5 блоков, статус-бар gap≥1, сид-строки логов, Tctl-число, D8-метрики после запроса) | **исправлен (round 2): ждёт перепуска** — правка = только парсер лог-зоны + самопроверка + ERROR-ветка (50+/6-); `bash -n` ok, +x; бинарь на машине B уже `7ccee44` — recreate не нужен, перепуск — оркестратором (ssh/podman наружу запрещены гигиеной); при внешнем PASS → reviewer |
| EXP-002-plain-pipe.sh | 6, 10 (plain-стрим `\| tee f` ~12 c: Δ∈[1.5;2.5] c, полный срез) | **без изменений** — в дифе отсутствует; `bash -n` ok, +x; результат предыдущего перепуска (PASS, 2026-11-13) действителен — продукт не менялся |
| EXP-003-plain-tty-safe.sh | 10 (plain в ssh-TTY: 0 байт 0x1b, не alt-экран) | **без изменений** — в дифе отсутствует; `bash -n` ok, +x; результат предыдущего перепуска (PASS, 2026-11-13) действителен |

### Regression (скоуп по triage: продукт не менялся)

| suite | result |
|---|---|
| `bash -n flow/external/EXP-001..003` | green 3/3 |
| `bash -n hfctl install.sh lib/*.sh` | green |
| `python3 -m py_compile tpl/python/*.py` | green |
| `--selfcheck` | **30/30 ok**, rc 0 |
| `hfctl` без аргументов | usage, rc=0 (pre-existing, пометка round 1) |
| `HFCTL_PORT=19999 hfctl status --json` | корректный отказ `{"profile": "27b-single", "autostart": false, "watchdog": false, "health": null}`, rc=0 |
| diff-скоуп | продукт против HEAD: **0 изменений**; в рабочем дифе только `flow/external/EXP-001-tui-ssh.sh` (мой fix) + blackboard оркестратора (`flow/STATE.md`, `flow/history.md`); `tpl/bench/`, `spec/state.md` — 0 изменений |

### Next

BLOCKED-EXTERNAL: оркестратору — перепуск EXP-001 на машине B (бинарь
`7ccee44` уже на месте; команда та же: `ssh -t <host> 'bash -s' <
flow/external/EXP-001-tui-ssh.sh`). Ожидаемый исход при живом продукте:
`RESULT: PASS` (числа из round-1-диагностики уже воспроизведены внутренне:
Tctl=77.2, prefill avg=889.1, decode=48.4). При внешнем PASS — reviewer;
при `RESULT: ERROR — парсер` — новый triage (значит, форма capture ещё
иначе — с capture-артефактом в `EXP-001-tui-ssh.result.txt`).

## Round 1 (2026-11-13, review round 2): retest фикса по blocking 1–3 reviewer

- Verdict: **BLOCKED-EXTERNAL** — все внутренние проверки зелёные;
  Блокирующие 1–3 review.md round 1 закрыты; EXP-001..003 — «created,
  действителен (PASS от 2026-11-13)», перепуск на машине B НЕ требуется
  (проверка поимённо — см. «Внешние эксперименты»). Единственный мой
  артефакт: комментарий `flow/external/EXP-001-tui-ssh.sh:25`
  («на машине B avg» → «на 128 GiB-машине gfx1151 avg»), `bash -n` ok;
  продукт не тронут (ssh/podman наружу запрещены гигиеной).
- Среда: та же, что в предыдущих retest'ах (dev-контейнер без podman/GPU,
  мёртвый порт 19999, k10temp жив); grid-хенарн — мой новый
  `/tmp/tuiretest/rv2_grid_check.py` (fake curses-window + реальный
  `draw()`), pty — эмулятор `/tmp/tuiretest/` без изменений, fake-server
  `/tmp/fake_hipfire.py`.

### Закрытие Блокирующих 1–3 (review.md round 1)

| # | критерий | проверка | статус |
|---|---|---|---|
| 1 | rule 7: имена хостов/IP в `tpl/python/` = 0 | `grep -rniE 'faex|машина A (прод)|che_evo|192\.168|10\.\d+\.\d+\.\d+' tpl/python/` → **0 совпадений** (rc=1); в diffe watch_tui.py — 4 комментария переведены на «128 GiB-машина gfx1151» (GPU_SPEC, docstring LogStreamer, selfcheck-комменты), поведение не тронуто | **закрыто** |
| 2 | блок «движок» 80×24 при ошибок>0/ретраи≠0: 5 обязательных строк (модель/uptime/очередь/обслужено/τ avg) ВСЕ видны, τ не отброшен | grid-рендер (fake window 80×24, реальный `draw()`, snap: `failed=2`, `retries=1`): все 5 обязательных в capture, необязательные (ошибки/ретраи/кэш) отброшены хвостом; порядок `rows_engine` = обязательные первыми → хвост (watch_tui.py:939-958); 9/9 assert | **закрыто** |
| 3 | mem-строка «45.2/60.4 GiB» и «45.2/128.0 GiB» целиком внутри рамки блока на 80×24, рамка не перезаписана | grid: value кончается на local col 12 (60.4) / 13 (128.0) из 39; col 0/39 = `│`; после «GiB» ≥1 пробел перед рамкой; bar 15 глиф (`W//2−25`), клип `block()` (`value[:w−5−len(label)]`) на 80×24 не срабатывает (value короче границы) — штатно; 8/8 assert | **закрыто** |

Blackboard rule-7: `flow/STATE.md`, `flow/history.md`, `flow/SPEC.md`,
`flow/FACTS.md`, `flow/DECISIONS.md` — grep = 0 совпадений (rc=1); легенда
«машина A/B» на месте (history.md:3); `flow/external/*.result.txt` — только
BLOCKED-заглушки (реальные captures в репо не кладутся — политика
«реальные EXP-результаты — только в hflab»). Имена хостов остались только в
исторических append-секциях отчётов сабстэджа (dev-report/review/test —
протокольные артефакты, developer явно вынес их за scope пункта 4;
оркестратору — решение, не дефект этого retest).

### Internal checks (полная регрессия)

| DoD item | check | result |
|---|---|---|
| — (lint) | `bash -n hfctl install.sh lib/*.sh` + `py_compile tpl/python/*.py` | **OK** |
| — (selfcheck) | `--selfcheck` (TERM задан) — **30/30**, rc 0; `env -u TERM` → 29/30, rc 1 (кейс `glyphs utf8` читает ambient-TERM — задокументированный артефакт, dev-report round 1, пункт 5) | **OK** |
| 1 (блоки TUI) | pty 80×24 xterm-256color, мёртвый порт, `+`/`p`: 5 заголовков + статус-бар, D8-подписи, «недоступен», mem жив, «(ждём логи…)» без podman, Traceback=0 (A) | **OK** |
| 2 (клавиши, статус-бар) | тот же запуск: «интервал 2 c», «пауза», разрыв ≥1 кол перед «интервал», «flasинтервал»=0 (A) | **OK** |
| 3 (80×24 мин, деградация, TERM) | pty 60×15 (B) / 40×10 (C) — Traceback=0; grid 60×15/40×10: mem-value не склеен с рамкой («GiB│»=0), не выходит за её границу; TERM=dumb — ASCII-рамки `+` без `┌`; TERM=posix / TERM='' — plain-фолбэк «сервер недоступен», без TUI-глифов (D/E/F) | **OK** |
| 4 (server down: TUI жив) | мёртвый порт: «недоступен», `mem: ` живёт, цикл без краха (A) | **OK** |
| 5 (пороги цветом) | selfcheck 30/30 + код-ревью порогов без изменений против предыдущего retest (визуально — EXP-001) | **OK** |
| 6 (plain раз в N; недоступен 30 c) | live fake-server :19999, interval 1, 5 c: 5 строк, Δ ровно 1 c, D8-срез полный (prefill 85.7 (avg) / decode 75.3 (последний)), ESC=0; мёртвый порт 33 c: «недоступен» t=11:46:50/11:47:20 (Δ ровно 30 c, без дублей); SIGTERM → «Выход Ctrl-C», **rc=0** (python-subprocess-замер); ESC=0 | **OK** |
| 7 (bash-разбор) | `watch --interval abc/0/0.5/--bogus` + лишний аргумент → FATAL-die, rc=1, прежние сообщения (5/5) | **OK** |
| 9 (регрессия) | `hfctl` без аргументов → usage rc=0 (pre-existing, пометка round 1); `HFCTL_PORT=199999 status --json` → корректный отказ `{"profile": "27b-single", … "health": null}`, rc=0; `doctor` rc=0 до «(сервер не отвечает)» без краша; `cmd_status`/`cmd_logs`/`cmd_doctor` — 0 изменений в diffe | **OK** |
| 10 (артефакт тестера) | `flow/external/EXP-001-tui-ssh.sh:25`: «на машине B avg уже ненулевой» → «на 128 GiB-машине gfx1151 avg уже ненулевой» (комментарий, код скрипта 0 изменений); `bash -n` ok, +x; `grep -rniE 'faex|…' flow/external/` → 0 | **OK** |
| — (diff-скоуп) | продукт против HEAD: только `tpl/python/watch_tui.py` (rule-7-комментарии + порядок строк `rows_engine` + bar `W//2−25` + клип `block()`; 37+/26−); blackboard: `flow/{DECISIONS,FACTS,STATE,history}.md` + dev-report append; мой артефакт: `flow/external/EXP-001-tui-ssh.sh` (комментарий, 5+/2−); `tpl/bench/` (md5 `253c7ac50857fe6d0e10fb0d2c5e35c0`), `spec/state.md`, `spec/hfctl.md`, `README.md`, `hfctl`, `lib/`, `install.sh` — **0 изменений** | **OK** |

pty-прогон: **33/33 PASS** (`/tmp/tuiretest/r1f2_check.py`, без изменений);
grid-прогон: **21/21 PASS** (`/tmp/tuiretest/rv2_grid_check.py`).

### Failures (FAIL)

НЕТ.

### Внешние эксперименты

| EXP-id | DoD item | status |
|---|---|---|
| EXP-001-tui-ssh.sh | 1, 2, 5, 10 | **created, действителен (PASS от 2026-11-13)** — мой артефакт (комментарий :25) не меняет поведение; критерии не тронуты; перепуск не требуется — см. проверку ниже |
| EXP-002-plain-pipe.sh | 6, 10 | **created, действителен (PASS от 2026-11-13)** — без изменений (в diffe отсутствует); plain-рендерер этим фиксом не тронут |
| EXP-003-plain-tty-safe.sh | 10 | **created, действителен (PASS от 2026-11-13)** — без изменений (в diffe отсутствует); критерий (счётчик 0x1b) не зависит от формата |

**Проверка «перепуск не требуется» — поимённо.** Изменения продукта с
последнего внешнего прогона (HEAD `6a35446`, EXP-001 PASS) — только
комментарии / порядок строк / клип:

1. rule-7-комментарии (4 шт.) — комментарии, поведение 0.
2. `rows_engine`: перестановка «τ avg» (5-й → после «обслужено») и
   необязательных в хвост. На 80×24 (размер capture EXP-001) при
   errors=0/retries=0 (состояние машины B) список строк байто-идентичен
   старому (τ и так на позиции 5; кэш отбрасывался и отбрасывается хвостом)
   → capture-вид блока «движок» не меняется.
3. mem-bar: `W//2−12` → `W//2−25` (24→15 глиф) — косметика; mem-строка НЕ
   входит в PASS-критерии EXP-001 (блоки, статус-бар, лог-зона, Tctl,
   prefill-avg, decode-число).
4. `block()`: клип value по границе блока — на 80×24 не срабатывает
   (все value короче границы: проверено, «GiB│»=0, value кончается на
   local col ≤13 из 39); эффект только на терминалах <80 (деградация) —
   внешний прогон EXP-001 не покрывает.
5. Док-пометка selfcheck (header-комментарий) — комментарии.

Вывод: поведение по критериям EXP-001 (и поимённо EXP-002/003) **не
меняется** → результаты PASS от 2026-11-13 действительны, перепуск на
машина B не требуется.

### Regression

| suite | result |
|---|---|
| `bash -n hfctl install.sh lib/*.sh` + `py_compile tpl/python/*.py` | green |
| `--selfcheck` | **30/30 ok**, rc 0 (TERM задан) |
| pty-прогон A–G (80×24 / 60×15 / 40×10 / dumb / posix / '' / fake-podman-STDERR) | **33/33 PASS** |
| grid-прогон (Блокирующие #2/#3 + каркас + деградация) | **21/21 PASS** |
| `hfctl` без аргументов → usage | rc=0 (pre-existing, пометка round 1) |
| `HFCTL_PORT=199999 hfctl status --json` → чанковый отказ | green, rc=0 |
| `hfctl doctor` | green, rc=0 |
| `cmd_status`/`cmd_logs`/`cmd_doctor` не тронуты | green (дифе 0) |
| `tpl/bench/merge_sort_thinking_off.txt` | md5 `253c7ac50857fe6d0e10fb0d2c5e35c0` (канон), в дифе отсутствует |
| `spec/state.md` | в дифе отсутствует |
| EXP-скрипты `bash -n` 3/3, +x | green (EXP-001 — только мой комментарий) |

### Next

BLOCKED-EXTERNAL (внутреннее всё зелёное, блокирующие 1–3 закрыты,
EXP-результаты действительны): оркестратору — закрыть внешние
BLOCKED-ITEM'ы (PASS от 2026-11-13 поимённо подтверждены как
действительные — перепуск не нужен) → reviewer. При желании
подтверждающего перепуска EXP-001 на машине B — решение пользователя
(GO); продукт на машине B не меняется, recreate не нужен (watch
host-side).

## Round 2 (2026-11-13, review round 3): retest фикса по блокирующему #4 (контракт rows_engine) + полная регрессия

Verdict: **PASS** (внутреннее всё зелёное; внешние EXP-001..003 закрыты
результатами 2026-11-13 — поимённый анализ «перепуск не нужен» ниже)

### Закрытие блокирующего #4 (review.md round 2, точный контракт)

Контракт: порядок — модель, uptime, очередь, [ошибки при >0], τ avg,
[обслужено], [ретраи при ≠0], [кэш]; на 80×24 все строки канона DoD 1
(модель/uptime/очередь/ошибки/τ) видимы в ОБОИХ состояниях; комментарий в
коде совпадает с brief. Своё воспроизведение (новый grid-скрипт
`/tmp/tuiretest/rv3_grid_check.py` — ассерты по контракту #4; старый rv2-grid
ассертит неверный набор «обслужено» ∈ обязательных — заменён):

| # | чек | result |
|---|---|---|
| 1 | точный порядок `rows_engine`, ошибок=0 | **PASS**: [модель, uptime, очередь, τ avg, обслужено, кэш] |
| 2 | точный порядок `rows_engine`, ошибок=2/ретраи=1 | **PASS**: [модель, uptime, очередь, ошибки, τ avg, обслужено, ретраи, кэш] — дословно по контракту |
| 3 | экран 80×24, ошибок=0 | **PASS**: модель/uptime/очередь/τ avg видимы + необязательное «обслужено» влезает; «кэш» отброшена ХВОСТОМ; «ошибки» не рисуется (=0); порядок модель<uptime<очередь<τ<обслужено |
| 4 | экран 80×24, ошибок=2/ретраи=1 | **PASS**: ВСЕ строки канона (модель/uptime/очередь/ошибки/τ avg) видимы, порядок модель<uptime<очередь<ошибки<τ; необязательные «обслужено»/«ретраи»/«кэш» отброшены ПОСЛЕДНИМИ (5 из 8 data-строк) |
| 5 | комментарий в коде | **PASS**: «Обязательные по DoD 1 (модель/uptime/очередь/ошибки/τ) … бьёт только необязательные (обслужено/ретраи/кэш)» (watch_tui.py:941-943) — совпадает с brief.md:12 («движок» (модель/uptime/очередь/ошибки/τ)) и SPEC.md:29 дословно по составу |
| 6 | регрессия блокирующего #3 (mem-клип) | **PASS**: «45.2/60.4 GiB» / «45.2/128.0 GiB» — полное значение внутри рамки (кол 39 = `│`), разрыв ≥1 кол после «GiB», «GiB│»=0; 60×15/40×10 — рамка цела, краха нет |

grid-прогон: **31/31 PASS** (рисунок каркаса 80×24, frame-строки, 5
заголовков + статус-бар без наложений — в составе).

### Internal checks (полная регрессия)

| DoD item | check | result |
|---|---|---|
| — (lint) | `bash -n hfctl install.sh lib/*.sh` + `py_compile tpl/python/*.py` | **OK** |
| — (selfcheck) | `--selfcheck` (TERM задан) — **30/30**, rc 0; `env -u TERM` → 29/30, rc 1 (кейс `glyphs utf8` читает ambient-TERM — известный задокументированный артефакт, review round 1 некритичные #1, в этом фиксе не меняется) | **OK** |
| 1 (блоки TUI) | pty 80×24 xterm-256color, мёртвый порт, `+`/`p`: 6 заголовков, D8-подписи, «недоступен», mem жив, «(ждём логи…)» без podman, Traceback=0 (A) | **OK** |
| 2 (клавиши, статус-бар) | тот же запуск: «интервал 2 c», «пауза», разрыв ≥1 кол, «flasинтервал»=0 (A) | **OK** |
| 3 (80×24 мин, деградация, TERM) | pty 60×15 (B) / 40×10 (C) — Traceback=0; TERM=dumb — ASCII-рамки (D); TERM=posix / TERM='' — plain-фолбэк «сервер недоступен» (E/F); grid-регрессия деградации 60×15/40×10 (rv3) | **OK** |
| 4 (server down: TUI жив) | мёртвый порт: «недоступен», `mem: ` живёт, цикл без краха (A) | **OK** |
| 5 (пороги цветом) | selfcheck 30/30 + код-ревью порогов (в дифе не тронуты) | **OK** |
| 6 (plain раз в N; недоступен 30 c) | live fake-server :19998, interval 1, 5 c: 5 строк, Δ ровно 1 c, D8-срез полный (prefill 75.0 (avg) / decode 61.5 (последний)), ESC=0; мёртвый порт 66 c: «недоступен» 13:19:03/13:19:33/13:20:03 (Δ ровно 30 c, без дублей); SIGTERM → «Выход Ctrl-C», rc=0, ESC=0 (`/tmp/tuiretest/rv3_plain_live.out`, `rv3_plain_down.out`) | **OK** |
| 7 (bash-разбор) | `watch --interval abc/0/0.5/--bogus` + лишний аргумент → FATAL-die, rc=1, прежние сообщения (5/5) | **OK** |
| 9 (регрессия) | `hfctl` без аргументов → usage rc=0 (pre-existing, пометка round 1); `HFCTL_PORT=199999 status --json` → корректный отказ `{"profile": "27b-single", … "health": null}`, rc=0; `doctor` rc=0 до «(сервер не отвечает)»; `cmd_status`/`cmd_logs`/`cmd_doctor` — 0 изменений в diffe (`lib/commands.sh` в дифе отсутствует) | **OK** |
| — (diff-скоуп) | продукт против HEAD: **только `tpl/python/watch_tui.py`** (14 строк: порядок `rows_engine` + комментарий + комментарий `rows_memory` 9→11 знаков); blackboard: `flow/{STATE,history}.md` + dev-report append; `tpl/bench/` md5 `253c7ac50857fe6d0e10fb0d2c5e35c0`, `spec/state.md`, `spec/hfctl.md`, `README.md`, `hfctl`, `lib/`, `install.sh` — **0 изменений** | **OK** |

pty-прогон: **33/33 PASS** (`/tmp/tuiretest/r1f2_check.py`, без изменений);
grid-прогон (контракт #4 + #3-регрессия + каркас): **31/31 PASS**.

### Failures (FAIL)

НЕТ.

### Внешние эксперименты — «перепуск не нужен», поимённо (фикс round 3)

Продуктовые изменения С ПОСЛЕДНЕГО внешнего прогона (PASS 2026-11-13, пуш
`6a35446`): (a) rule-7-комментарии, mem-bar `W//2−25`, клип `block()` —
анализ «нейтрально по критериям» уже проведён в моей секции «Round 1
(review round 2)» пунктов 1–5 и в review.md round 2; (b) **новое в этом
раунде: порядок `rows_engine`** (ошибки>0: канон-пятёрка вперёд; ошибки=0:
τ avg и «обслужено» поменялись местами) + 2 комментария. Поимённо по
критериям EXP-001 (`EXP-001-tui-ssh.sh`, python-анализ :106–183):

1. **5 заголовков блоков + «hfctl watch» (c1)** — проверка присутствия
   ТОЛЬКО заголовков; токенов содержания блока «движок» («модель:»,
   «uptime:», «очередь:», «ошибки:», «τ avg:», «обслужено:», «кэш:») в
   анализе НЕТ → перестановка строк блока нейтральна.
2. **Статус-бар: «интервал» в row0, разрыв 1 кол, нет «…flasинтервал»** —
   статус-бар в дифе не тронут; pty A подтверждает (разрыв ≥1).
3. **Зона логов ≥1 строка (не «(ждём логи…)»/«логи недоступны»)** —
   `LogStreamer`/seed/live в дифе не тронули.
4. **Tctl — число (c1)** — блок «железо» в дифе не тронут.
5. **prefill avg > 0 / decode — число (c3)** — блок «скорость»
   (`rows_speed`/D8-подписи) в дифе не тронут.
6. **Порядок строк внутри блока «движок»** — capture-критериям НЕ
   противоречит: ни одно критерий не содержит состав блока кроме
   заголовка, и не содержит порядка строк; при ошибок=0 (состояние
   машины в EXP-001) видимый набор строк тот же — {модель, uptime,
   очередь, τ avg, обслужено} — только строки 4–5 поменялись местами.

EXP-002/003 — plain-режим; `rows_engine` — TUI-только (plain рендерится
`fmt_plain`), в дифе plain-код не тронут.

Вывод: **результаты PASS от 2026-11-13 действительны, перепуск на машину B
не требуется** — сомнений нет (никакое критерий не покрывает изменённые
строки). При желании подтверждающего перепуска — решение пользователя (GO);
watch host-side, recreate не нужен.

### Regression

| suite | result |
|---|---|
| `bash -n hfctl install.sh lib/*.sh` + `py_compile tpl/python/*.py` | green |
| `--selfcheck` | **30/30 ok**, rc 0 (TERM задан); `env -u TERM` → 29/30 rc 1 (известный артефакт, задокументирован) |
| pty-прогон A–G (80×24 / 60×15 / 40×10 / dumb / posix / '' / fake-podman-STDERR) | **33/33 PASS** |
| grid-прогон (контракт #4 оба состояния + #3-регрессия + каркас + деградация) | **31/31 PASS** (`rv3_grid_check.py`) |
| plain live (fake-server :19998, interval 1) | 5 строк, Δ=1 c, D8-срез, ESC=0 |
| plain down (мёртвый порт, 66 c) | «недоступен» Δ=30 c ×2, без дублей, SIGTERM rc=0, ESC=0 |
| `hfctl` без аргументов → usage | rc=0 (pre-existing) |
| `HFCTL_PORT=199999 hfctl status --json` → чанковый отказ | green, rc=0 |
| `hfctl doctor` | green, rc=0 |
| `cmd_status`/`cmd_logs`/`cmd_doctor` не тронуты | green (дифе 0) |
| `tpl/bench/merge_sort_thinking_off.txt` | md5 `253c7ac50857fe6d0e10fb0d2c5e35c0` (канон), в дифе отсутствует |
| `spec/state.md` | в дифе отсутствует |
| diff-скоуп продукта | **только `tpl/python/watch_tui.py`** |

### Verdict

**PASS.** Все внутренние чек-и зелёные (блокирующий #4 закрыт в обоих
состояниях, регрессия полная); внешние EXP-001..003 закрыты результатами
2026-11-13 (PASS), поимённый анализ подтверждает их действительность после
фикса round 3 — перепуск не нужен. Оркестратору: закрыть сабстэдж →
reviewer (round 3, scope-limited: контракт #4 + регрессия).
