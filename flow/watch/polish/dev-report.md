# Dev report: watch/polish
- Date: 2026-11-13 / fix round: 1

## What was done

Строго по task.md §1–§10 (контракт Design: architect). Изменены 4 файла,
`lib/` — 0 изменений (env-интерфейс `cmd_watch` не тронут).

| Файл | Что сделано (пункт task.md) |
|---|---|
| `tpl/python/watch_tui.py` | §2 `draw()` — новая наполняющая геометрия: `gap`/`(avail-1)//2`/`(H-1)//4` удалены; `h1 = max(c_e, 5) + 3`, `h2 = max(4, 3) + 3`, `LOG_MIN = 3`, `rem = H - 1 - h1 - h2`, целочисленный клип `d1 = min(c1, deficit*c1//(c1+c2))`, `d2 = min(c2, deficit - d1)`; рамки не рвутся, ряды примыкают (gap = 0). §2.1 лог-зона: контент `log_view[-(log_h-3):]`, placeholder «(ждём логи…)» только при `log_h ≥ 4`. §3 `block()`: `lw = max(len(label)+1)`, строка `(label+':').ljust(lw) + ' ' + value[:max(0, w-lw-4)]` — все значения блока стартуют с колонки `x+3+lw`, рамка `x+w−1` никогда не перезаписывается; клип хвостом в порядке `rows_*` (приоритеты §3). §4 ярлыки: Движок → Model/Uptime/Queue/Errors/τ avg/Served/Retries/Cache (порядок review #4 дословно; τ через `Glyphs.tau` → «tau avg» в ASCII); Железо → GPU freq/GPU load/GPU power/GPU temp/CPU temp; Память → RAM/Swap/KV pages (строка не прячется, `-` при kv=None); Скорость — без изменений; форматы значений НЕ тронуты (Tctl дробный `fmt_c`, GPU temp/power целые). Названия блоков — «Движок», «Железо», «Скорость», «Память», «Логи» (капс). Пороги цветами не тронуты (привязаны к строкам). §4 ширины: sparkline `max(4, W//2-18)` (`sparkline()` уже берёт `vals[-width:]` — свежие точки не отбрасываются), mem-bar `max(4, min(10, W//2-30))`, `maxlen = 60//interval` не тронут. §5 `status_bar_layout()` — 7-кортеж `(left, mid, right, mid_x, right_x, draw_mid, draw_right)`: bullet x=0, разрыв col 1, left x=2, right = самодостаточный текст `p` («логи: live, пауза: p │ q — выход» / «логи: пауза, live: p │ q — выход», 32 зн. оба); mid/right ниже минимума отбрасываются целиком (без «половинчатого» клипа). §6 `LogStreamer`: `_seed_tail` (хвост сида, ставится в `seed()`, `None` при пустом сиде) — дедуп только первой строки live-процесса в `_spawn_once()`; edge-кейсы контракта (пустой сид, ре-спавн, pathological-одна-потерянная-строка — комментарий в коде). §7 `selfcheck()` 30→38: изменён 1 («status bar 80 cols gap≥1» → строгий по 7-кортежу, обе стороны), добавлены 8 (60/40 cols; seed/live no dup + seed empty через fake-podman-шимы; sparkline tail kept; hardware labels; engine labels; KV pages dash). Header-комментарий: 37→38, капс-названия. |
| `hfctl` (диспетчер) | §8 ветка `""` роутера: `usage` → `usage; exit 1`; комментарии синхронизированы (usage(): «выход на совести вызывающего» + ветка `''` роутера); §9 usage-строка `watch` — капс-названия блоков. Алиасы не тронуты (ветка `""` срабатывает только при нуле аргументов; `*` уже `exit 1`). |
| `spec/hfctl.md` (~строка 60) | §9 синхронизация: капс-названия блоков; составы Движок/Железо/Память по таблице §4; текст деградации под новый статус-бар и пороги. D8-описания, plain-состав, клавиши — не тронуты. |
| `README.md` (~строка 38) | §9 то же сокращённо (строка `watch`). |

Out of scope соблюдён: `fmt_plain()` — 0 строк в diff (проверено
`git diff`), `tpl/bench/` не тронут, `spec/state.md` не тронут, новые
клавиши/цвета/метрики/кейсы сверх §7 — нет.

## How it was checked internally

Всё — в контейнере (dead-порт :19999), без ssh/podman наружу. Команды +
результаты (все rc=0, если не отмечено):

1. **selfcheck 38/38**: `python3 tpl/python/watch_tui.py --selfcheck` →
   `38/38 OK`, rc=0. (Новые 8 кейсов §7 + обновлённый status-bar-кейс.)
2. **bash -n**: `bash -n hfctl lib/*.sh install.sh` — чисто.
3. **py_compile**: `python3 -m py_compile tpl/python/*.py` — чисто.
4. **bare usage**: `./hfctl` → usage на stdout, rc=1.
5. **чанковый порт**: fake-сервер (127.0.0.1:19998) отвечает /health
   `Transfer-Encoding: chunked`, обрыв до terminating-chunk (curl rc=18,
   body пустой); `HFCTL_PORT=19998 ./hfctl status --json` → валидный JSON,
   `"health": null`, ключи profile/autostart/watchdog, без Traceback
   (harness `/tmp/polish_checks/chunked_check.py`: 4 OK / 0 fails).
6. **doctor**: `./hfctl doctor` → rc=0 (в контейнере штатно: «стек:
   НЕ УСТАНОВЛЕН», GPU/podman нет — корректные отказы, не краш).
7. **grid-чек** (fake curses-window + реальный `Watch.draw()`,
   `/tmp/polish_checks/grid_check.py`): fixture snap в обоих состояниях
   (engine_ok True c_e=6/8, False), размеры 80×24 / 80×30 / 60×15 / 40×10 /
   80×16 / 80×8 — геометрия §2 точная (h1/h2/log_h по таблице; примыкание
   рамка-рамка; клип 60×15: 3/3/2/2; 40×10: заголовки только), выравнивание
   §3 (значения — колонка `x+3+lw` по render-буферу), ярлыки §4, дробная
   `CPU temp 39.1C`, KV pages dash. **0 fails.**
8. **pty-грид** (tmux как ground-truth терминал, ded. socket,
   `/tmp/polish_checks/pty_check.py`; live-состояние — grid-чек, т.к. порт
   мёртв — методика test strategy task.md): 80×24 (status-bar col 0 `●`,
   col 1 space, col 2 `h`; mid 34..45 / right 47..78, примыкание рядов, 5
   капс-имён, «недоступен», рамки целы), 60×15 (клип: Model/Uptime/Queue +
   GPU freq/load/power + decode/prefill + RAM/Swap; mid не рисуется,
   right 27..58), 40×10 (только заголовки 5 блоков), 80×30 (log_h=14 при
   c_e=1; live-логика 13 — grid-чек), 80×8 (ряды не рисуются, «Логи» есть),
   TERM-фолбэки: dumb (процесс жив, без Traceback), posix / '' / unset
   (plain-фолбэк, «недоступен», без рамok) — **0 fails.**
9. **plain-периодичность** (тот же harness, `--plain`): dead-порт — ровно
   3 строки «сервер недоступен» за 64 с (t=0/30/60), Δ30 с без дублей;
   live fake-server Δ1 с — полный срез каждую секунду (queue/served/
   prefill/decode), decode = recent_tok_s (D8). **0 fails** (прогон 64 с +
   5 с, 2026-11-13).
10. **md5 bench-фикстуры**: `tpl/bench/merge_sort_thinking_off.txt` →
    `253c7ac50857fe6d0e10fb0d2c5e35c0` (канон).
11. **скоуп diff**: `git status` — изменены ровно README.md, hfctl,
    spec/hfctl.md, tpl/python/watch_tui.py (+ flow/ — артефакты
    оркестратора); `git diff -U0 tpl/python/watch_tui.py | grep -c fmt_plain`
    = 0 (plain-состав не тронут).
12. Коммитов НЕ сделано (коммиты — оркестратор).

## Not checked internally

- **Реальный рендер на машине B (EXP-001 перепуск)**: TUI на живом
  SSH-TTY/live-движке/реальном `podman logs` — внешняя приёмка (DoD 12);
  критерии EXP-001 тестер обновляет ДО перепуска (капс-имена,
  `Tctl`→`CPU temp`, logzone-парсер, row 0, «ряды примыкают»).
- **Дедуп seed/live на живом podman** (DoD 9 «лента»): механизм покрыт
  selfcheck-кейсами 3–4 (fake-podman-шимы, включая пустой сид); живая
  верификация дубля на границе сид/live — EXP-001.
- **ASCII-глифы / кириллица на реальных dumb-терминалах**: в контейнере
  `TERM=dumb` — валидный terminfo без cursor-addressing → pane пуст,
  процесс жив, без Traceback (деградация, не краш); ASCII-путь
  (глифы `. -:*#%@`, `tau`, кириллица в UTF-8 locale) покрыт
  selfcheck-кейсами и grid-чеком, но не живым рендером.
- **Визуальная оценка** (выравнивание, ширина sparkline/mem-bar,
  читаемость ярлыков) — глазами на машине B (DoD 3–8 в EXP-001).

## Known limitations / assumptions

- `TERM=dumb` в этом контейнере даёт деградацию (пустой кадр): контракта
  «рисовать на dumb» нет (task.md §10 — «процесс жив, без краха»).
- Неблокирующая несогласованность task.md (не мешала реализации): строка
  таблицы §2 «80×24 engine_ok=False … Железо 5 + 2 пустые» противоречит
  же собственной формуле `h1 = max(1,5)+3 = 8` (контент Железа ровно
  5 строк, пустых 0; «+2 пустые» было бы при h1=10). Реализовано по
  формуле (канон §2-формулы + §10: «h1 = max(1,5)+3 = 8»). Проверено
  grid-чеком (down: 8/7/8).
- pty-методика: `pty.fork()` + самодельный эмулятор терминала не
  эмулирует относительные перемещения курсора ncurses (`\x1b[2d`, `\r`)
  достоверно — ground truth = tmux (тот же метод, что EXP-001 на
  машине B).
- Pathological-кейс дедупа (§6): потеря одной идентичной строки при
  старте — осознано допустимо (комментарий в коде).

## Out-of-scope proposals

- «Разделяемая рамка» между рядами (htop-стиль, −1 строка) — task.md
  open question #1, design-уровневое решение, в этом сабстэдже НЕ сделано.
- GPU temp дробным (`fmti` → `fmt_c`) — open question #2, НЕ тронут.
- Русские ярлыки метрик вместо английских — open question #3, НЕ тронут.
  (Все три — единые точки правки, доступны как design-уровневые fix
  rounds при явном желании пользователя.)
