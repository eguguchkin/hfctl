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
