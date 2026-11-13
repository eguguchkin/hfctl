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
