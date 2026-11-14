# Dev report: watch/cache-tok-temp
- Date: 2026-11-14 / fix round: 1 (первичная выдача)

## What was done

### `tpl/python/watch_tui.py`

1. **Формат счётчика кэша** — новые чистые функции рядом с `fmti`/`fmt_c`:
   - `:419` `fmt_tok(v)` — `None → '-'`; `<1000` — целое; `1000…999_999` →
     `99.1k`; `≥1_000_000` → `1.2M` (одна десятичная).
   - `:489` plain-строка: `cache: %s` + `fmti` → `cache tok: %s` + `fmt_tok`.
   - `:526` `PLAIN_FULL`: `cache: 4421` → `cache tok: 4.4k` (фикстура
     `metrics` не менялась: `4421.0` → `4.4k`).
   - `:540` `PLAIN_MIN`: метка `cache: -` → `cache tok: -` (значение `-`
     от `fmt_tok(None)`).
   - `:1172` TUI-строка блока «Движок»: `('Cache', fmti(…, '-'))` →
     `('Cache tok', fmt_tok(…))`.
   - `:801` selfcheck-фикстура `engine labels`: `'Cache'` → `'Cache tok'`.
2. **Пороги температур** — чистая функция `:431` `temp_color(deg)`:
   `None → 0`; `deg >= 90 → C_RED`; `80 <= deg < 90 → C_YELLOW`; иначе `0`
   (сравнение по сырому значению, ровно границы; новых curses-pair нет —
   штатные C_RED/C_YELLOW).
   - `:1189` `GPU temp` — получил подсветку `self.attr(temp_color(...))`
     (была без подсветки).
   - `:1190` `CPU temp` — прежний `cpu > 80 → C_RED` заменён на
     `self.attr(temp_color(cpu))`; локальная переменная `cpu_attr` удалена.
   - Подсветка `GPU load`/`RAM` не тронута.
3. **Plain-стрим — решение по цвету**: plain-режим НЕ красится вообще
   (механизма цвета в нём нет: TUI использует curses-атрибуты, а в plain
   `main()` попадает только когда `sys.stdout` НЕ TTY либо curses не
   инициализировался). По явной ветке task.md п.3 цвета в plain НЕ вводил;
   текст `cache tok: 99.1k` тот же, ANSI в pipe не печатается (был и так),
   DoD 2 закрыт («требования к цвету в pipe — их нет»). Зафиксировано в
   спеке (см. ниже).
4. **Selfcheck** — 6 новых проверок (`:606`–`:620`):
   - `fmt_tok границы` (999→`999`, 1000→`1.0k`, 99100→`99.1k`,
     1234567→`1.2M`);
   - `fmt_tok None → -`;
   - `temp_color границы` (79.9→0, 80→жёлтый, 89.9→жёлтый, 90→красный);
   - `temp_color None → 0`;
   - `plain cache tok формат` (`cache tok: 99.1k` в срезе fmt_plain);
   - `hardware temp подсветка` (GPU 91.0 → attr(C_RED), CPU 83.0 →
     attr(C_YELLOW) в rows_hardware).
5. **Доки** — `spec/hfctl.md` §watch:
   - `:60` TUI: `Cache (…)` → `Cache tok (…, compact-формат токенов:
     <1000 — целое, ≥1000 → `99.1k`, ≥1M → `1.2M`; …)`;
   - `:61` пороги: `CPU temp > 80° — красный` → `CPU temp и GPU temp —
     жёлтый 80…89 °C, красный ≥90 °C (ровно границы)`;
   - `:61` plain-срез: `кэш` → `cache tok` (тот же компактный формат;
     без цвета — в plain ANSI не печатается).

## How it was checked internally

| Команда | Результат |
|---|---|
| `python3 -m py_compile tpl/python/watch_tui.py` | OK |
| `python3 tpl/python/watch_tui.py --selfcheck` | `selfcheck: 48/48 ok`, rc=0 (было 42; +6 новых) |
| `bash -n hfctl lib/*.sh` | OK (правок .sh нет) |
| `./hfctl` без аргументов | usage, rc=1 (регрессия не затронута) |
| `git status --short` | изменены только `spec/hfctl.md`, `tpl/python/watch_tui.py` (+ untracked `flow/watch/cache-tok-temp/`) |
| `md5sum tpl/bench/merge_sort_thinking_off.txt` | `253c7ac5…` — канон цел; `tpl/bench/`, `tpl/compose/`, `lib/*.sh` не тронуты |

## Not checked internally

- Живой TUI на SSH-TTY (подсветка 80/90, строка `Cache tok`) и
  `hfctl watch | cat` без escape-кодов — нужен живой движок/машина B;
  это DoD 5 (EXP, оркестратор). Локальный прогон plain невозможен
  (нет /stats) — покрыто selfcheck-фикстурами `PLAIN_FULL`/`PLAIN_MIN`
  и новой проверкой формата.
- Границы на реальных датчиках (79.9/80.0/89.9/90.0) — только unit-уровень
  `temp_color`; машинная приёмка за оркестратором.

## Known limitations / assumptions

- `999_999` токенов печатается как `1000.0k` (ровно по формуле task.md
  `1000…999_999 → v/1000:.1f}k`; порог `≥1_000_000` переключает на M).
- `temp_color` сравнивает сырое значение датчика (task.md п.2 — пороги
  заданы на самом значении); GPU печатается через `fmti` (округление до
  целого видно в тексте, подсветка — по сырому числу).
- Сравнение «как печатается» (parenthetical в brief) не вводил отдельным
  механизмом: selfcheck-границы из task.md (79.9→0, 80→жёлтый…)
  воспроизводятся сырым сравнением точно.

## Out-of-scope proposals

- Нет. (Пороги RAM/GPU load оставлены как есть согласно brief.)
