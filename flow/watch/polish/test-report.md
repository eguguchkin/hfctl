# Test report: watch/polish
Verdict: BLOCKED-EXTERNAL
- Date: 2026-11-13 / round 1

## Internal checks (DoD 1–10, item | чек | результат)

Всё — в контейнере (dead-порт :19999 / fake-сервер :19998), без ssh/podman
наружу (гигиена AGENTS.md). Артефакты тестера: `/tmp/tester-polish/`
(grid_check.py, pty_check.sh, chunked_check.py, fake_server.py,
exp001_verify.py).

| DoD item | Чек (команда/метод) | Результат |
|---|---|---|
| 1 (нет пустых строк между рядами) | grid-чек: 80×24 — row 9 = нижняя рамка ряда 1, row 10 = верхняя рамка ряда 2 (примыкают, gap=0); 60×15 — 6/7; 40×10 — 3/4; 80×16 — 7/8; pty 80×24: относительный чек «над заголовком «Скорость» — рамка, над ней — рамка» | PASS (grid 0 fails; pty 0 fails) |
| 2 (высота = наполнение; «Логи» = остаток) | grid-чек: 80×24 c_e=6 → 9/7/7; c_e=8 → 11/7/5 (ВСЕ 8 строк Движка видимы — канон review #4 жив); down c_e=1 → 8/7/8; 80×30 c_e=6 → log_h=13 (контент 10); pty 80×30 (dead-порт c_e=1) → log_h=14, title@17, bot@29 | PASS |
| 3 (клип, минимумы, рост логов) | pty 80×24 / 60×15 / 40×10 / 80×30 / 80×8: Traceback=0, последняя строка = нижняя рамка; 60×15 (dead-порт): видны Model/Uptime/Queue + GPU freq/load/power + decode/prefill + RAM/Swap, «Логи» = рамка+заголовок+рамка (placeholder НЕ рисуется при log_h=3 — и grid, и pty); 40×10: только 5 заголовков; 80×16 grid: h1=7 (Движок 4: …τ avg), h2=5 (Железо 4: …GPU temp); 80×8: статус-бар + «Логи» 3 строки, рядов нет | PASS |
| 4 (капс-названия) | pty 80×24: все 5 имён «Движок»/«Железо»/«Скорость»/«Память»/«Логи» в capture; TERM=dumb: процесс жив, без Traceback (деградация — контракт task.md §10); selfcheck кейсы 6–8 (названия в строках) | PASS |
| 5 (имена метрик; дробная Tctl; KV pages) | selfcheck: `hardware labels` = GPU freq/GPU load/GPU power/GPU temp/CPU temp; `engine labels` = Model/Uptime/Queue/Errors/τ avg/Served/Retries/Cache; `KV pages dash` = ('KV pages','-'); grid: `CPU temp 39.1°C` (дробная, НЕ 39°C) | PASS |
| 6 (выравнивание) | grid-чек: на КАЖДОЙ контентной строке КАЖДОГО блока префикс = `(label+':').ljust(lw) + ' '` по render-буферу (значения стартуют с x+3+lw); проверено: Движок x+10, Железо x+13, Скорость x+17, Память x+12 (80×24 c_e=6 и c_e=8, клип 60×15) | PASS |
| 7 (статус-бар: gap, самодостаточный p) | selfcheck: «status bar 80 cols gap≥1» (строгий) + «60 cols» + «40 cols»; pty 80×24: col 0 = `●`, col 1 = `' '`, col 2 = `h`; mid 34..45, right 47..78 («логи: live, пауза: p │ q — выход»), col 79 пуст (grid); разрыв ≥1 кол перед «интервал»; pty 60×15: mid НЕ рисуется, right 27..58 без наложений; pty 40×10: только left; клавиша `p` (send-keys): row 0 → «логи: пауза, live: p │ q — выход» (live-подпись исчезает) | PASS |
| 8 (sparkline ~60 c, ширина) | selfcheck «sparkline tail kept» (30 значений, width=22, свежие не отброшены); grid: ширина = max(4, 80//2−18) = 22; окно maxlen = 60//interval — в дифе 0 строк (не тронуто) | PASS |
| 9 (нет дубля seed/live) | selfcheck кейсы «seed/live no dup» (fake-podman-шим: buf = ['A','B'], без дубля) и «seed empty: live no dedup» (buf = ['C']); механизм `_seed_tail` в `seed()`/`_spawn_once()` (read); живой прогон = EXP-001 (новый критерий: в capture нет двух абьюцианных идентичных строк в зоне) | PASS (внутреннее); живой — ждёт GO |
| 10 (usage rc=1) | `./hfctl` → usage на stdout (21 строка, watch-строка с капс-названиями), rc=1; алиасы не сломаны: `./hfctl status` rc 0 внятный вывод, ветки case up/down/mode/autostart/noautostart/_boot/_watchdog/_boot не тронуты (код); ветка `*` — отказ rc 1 (неизменна) | PASS |

## Failures (FAIL)

Нет. (Итерации 1–3 pty-грида: 39 FAIL — все дефекты МОЕГО харнесса:
bash-байтовые субстроки в C-локали, tmux `new-window` без `-x/-y`,
`${4:-default}` затыкал пустой TERM, индексы строк в ожидаемых значениях —
каждый зафиксирован и исправлен; повторный прогон — 0 fails. Продукт
изменений не требует.)

## External experiments

| EXP-id | DoD item | Статус |
|---|---|---|
| EXP-001 | 1-2, 4-7, 9 (визуальный) + 12 | **updated, ждёт GO** — скрипт переписан под новый контракт (см. анализ ниже); `bash -n` OK; анализатор локально проверен: чистый синтетический capture 80×24 (из реального `draw()`) → PASS; 5 мутаций (дубль seed/live, lowercase-названия, целая температура, gap-строка между рядами, старый статус-бар) → каждая поймана (exp001_verify.py: 0 fails) |
| EXP-002 | 11 (plain-состав), 12 | **действителен (PASS 2026-11-13)** — поимённо: (1) режим plain (isatty) — 0 строк в дифе; (2) периодичность `run_plain`/`sleep_quanta_plain` — 0 строк в дифе; (3) поля queue/served/cache/prefill/decode/mem/swap/gpu/cpu — `fmt_plain` 0 строк в дифе (PLAIN_FULL selfcheck 38/38); TUI-контракт не затрагивается |
| EXP-003 | 11, 12 | **действителен (PASS 2026-11-13)** — поимённо: (1) `watch > f` → plain (main/isatty — 0 строк в дифе); (2) «нет 0x1b в f» — plain не печатает ANSI (неизменен); (3) alt-экран — initscr-ветка не тронута; usage-rc-изменение (bare `hfctl`) сценарием EXP-003 не вызывается |

### EXP-001: поимённый анализ старых критериев (до перепуска)

Невалидны (обновлены):
- lowercase-greps названий блоков (`'движок','железо','скорость','память','логи'`) —
  контракт DoD 4: капс «Движок»…«Логи»; lowercase-подстрока в capture не
  встречается.
- `re.search(r'Tctl:\s*…')` — ярлык теперь `CPU temp` (DoD 5); добавлен
  обязательный дробный формат (`\d+\.\d`, не целое и не `?`).
- логзона-парсер `startswith('логи')` (обе формы) — заголовок теперь «Логи».
- модель-специфичные паттерны наложений «flasинтервал»/«flaинтервал» —
  модель на машине B `qwen3.8:27b-mq6-xt` (flash-паттерн мертво); заменены
  универсальным чек-ом «разрыв 1 кол перед «интервал»» (оставлен,
  валиден).
- Строковые индексы старого сабстэджа (если бы были) — заменены
  относительным чек-ом «ряды примыкают»: над заголовком «Скорость»
  (i) — верхняя рамка ряда 2 (i−1), над ней — нижняя рамка ряда 1 (i−2).

Валидны (сохранены без изменений): «hfctl watch» в row 0; «интервал N c» +
разрыв ≥1 кол перед ним (контракт fix round 2 закрытого сабстэджа); зона
логов ≥1 строка, не «(ждём логи…)» и не «логи недоступны» (D9); честные
метрики D8 (prefill avg > 0, decode (последний) — число).

Новые критерии (контракт task.md §5/§2/§4/§6): капс-названия блоков;
`CPU temp` дробный; самодостаточная подпись p в row 0 («логи: live,
пауза: p │ q — выход»); «ряды примыкают» (относительный чек); дедуп
seed/live — в capture 1 нет двух абьюцианных идентичных строк в зоне
(ложное срабатывание в первые 12 с простоя крайне маловероятно —
разбирать руками).

## Regression (полная, чек-лист AGENTS.md + test strategy task.md)

|Suite|Результат|
|---|---|
| `bash -n hfctl lib/*.sh install.sh` | ok |
| `python3 -m py_compile tpl/python/*.py` | ok |
| bare `hfctl` → usage, rc=1 | ok (21 строка) |
| `HFCTL_PORT=19998 ./hfctl status --json` (чанковый порт: /health chunked-обрыв до terminating-chunk, curl rc 18) | ok — валидный JSON, `"health": null`, ключи profile/autostart/watchdog, без Traceback (4/4) |
| `./hfctl doctor` | rc=0, внятные отказы (стек НЕ УСТАНОВЛЕН, GPU/podman нет), 0 Traceback |
| `python3 tpl/python/watch_tui.py --selfcheck` | 38/38 ok, rc=0 |
| grid-чек (fake-window + реальный `draw()`: 80×24 c_e=6/8/down, 80×30, 60×15, 40×10, 80×16, 80×8; live/paused; рамочная целостность; выравнивание; клип; placeholder-правило log_h≥4) | 0 fails |
| pty-грид (tmux sized-sessions: 80×24 + клавиша p, 60×15, 40×10, 80×30, 80×8; TERM=xterm-256color/dumb/posix/'') | 0 fails (Traceback=0 во всех; posix/'' → plain-фолбэк «сервер недоступен» без рамок; dumb → деградация без краха) |
| plain-периодичность dead-порт 64 c (interval 2) | ровно 3 строки «сервер недоступен» t=0/30/60, Δ30 c без дублей, exit=0 |
| plain-периодичность live fake-server (interval 1, D8) | 6 строк Δ=1 c, полный срез, decode = recent_tok_s (75.3), prefill avg 85.7 — 0 fails |
| скоуп diff = файлы §1 task.md | ровно README.md, hfctl, spec/hfctl.md, tpl/python/watch_tui.py (+ flow/ — артефакты); `lib/` — 0; `spec/state.md` — 0; `tpl/bench/merge_sort_thinking_off.txt` md5 `253c7ac50857fe6d0e10fb0d2c5e35c0` (канон); `fmt_plain` в дифе watch_tui.py — 0 строк; main/isatty/run_plain/initscr в дифе — 0 строк; старые константы геометрии (`(avail-1)//2`, `(H-1)//4`, gap) — 0 совпадений |

## Замечания (не блокирующие)

- Несогласованность task.md (не дефект): строка таблицы §2 «80×24
  engine_ok=False … Железо 5 + 2 пустые» противоречит собственной формуле
  `h1 = max(1,5)+3 = 8` (контент Железа ровно 5 строк, пустых 0; Движок =
  «недоступен» + 4 пустые). Реализовано по формуле — подтверждено grid
  (down: 8/7/8, все рамки целы). Неблокирующая пометка разработчика.
- `TERM=dumb` в контейнере → пустой кадр (degrade): контракта «рисовать на
  dumb» нет (task.md §10: «процесс жив, без краха») — ассерт по контракту.

## Итог

Внутреннее — полностью зелёное (0 FAIL). Внешнее (DoD 12) не закрыто:
EXP-001 обновлён и ждёт перепуска на машине B после пуша (GO пользователя);
EXP-002/003 действительны (PASS 2026-11-13), перепуск не нужен. Verdict:
**BLOCKED-EXTERNAL**.
