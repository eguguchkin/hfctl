# Dev report: bench/concurrency

- Дата: 2026-11-14 / фикс-раунд: 1 (первичная сдача)
- Роль: developer (dev-flow hfctl). Контракт: `task.md` + `SPEC.md` здесь.

## What was done

Продуктовых файлов — ровно 4 из task.md; `tpl/bench/` не тронут
(md5 фикстуры в прогоне = `253c7ac5…`, канон); новый Python-файл не заводился.

### 1 · `lib/bench.sh`
- **Разбор `--parallel`** (`cmd_bench`, строки 549, 557–565): значение
  обязатель (`${2:-}`), regex `^[0-9]+(,[0-9]+)*$`, каждое число 1..8 →
  иначе `die "--parallel: целые 1..8 через запятую (получено '…')"` ДО
  обращения к серверу. Глобал-локальная `par_list` (пробелы), порядок
  пользователя сохраняется, дубли не ошибка.
- **Дефолты** (577–579): quick → пусто, full → `2 4`; явный флаг перезадает
  в любом режиме (замена, не дополнение — SPEC §1, Open question 1).
- **Вызовы**: quick — после снятия `MED_SOLO_CODE` и ttft (645–648,
  только при непустом списке, с log-строкой); full — цикл по `par_list`
  вместо двух жёстких `bench_parallel 2/4` (655). `B_FULL` не менялся.
- **`bench_parallel`** (382–450): цикл sum-валидации помечает валидность i;
  невалидные — вне суммы И вне `walls` (410–417); `walls` — `%.1f` из
  `par_wall_$i` через запятую в порядке запуска (без сортировки = позиция
  в FIFO); runs.tsv получил **колонку 7** (`${walls:--}` — 424–425);
  `B_NOTE_parallel_$n` = «per-request wall (curl, по позиции запуска): …»
  + min–max разброс одной awk-строкой при ≥2 валидных (426–436).
  Интерпретация по роуту (lanes/multi-slot/FIFO) — не тронута (SPEC §3).
- **docblock-ы** обновлены по домашнему стилю (bench_parallel 356–380,
  cmd_bench 503–505/519–520/543–545); `bench_help` — строка флага + смысл
  (30–32).

### 2 · `tpl/python/bench_report.py` (~15 строк)
- `load_runs`: колонка 7 → `walls: [float]` (21–22); строки без колонки 7
  читаются как раньше (additive, SPEC §4).
- `RE_PAR = ^parallel-\d+$` (30), `scen_order(keys)` (32–36): ORDER +
  любые `parallel-<int>` после известных по возрастанию N; применяется в
  `summary_of` (50), `do_report` (80) и `do_compare` (124, объединение
  ключей summary обеих сторон; отсутствующая сторона — пропуск прежним
  `cm is None or bm is None`).
- Юнит: `unit_of(sc)` (38–39) → `tok/s agg` для любого `parallel-N`,
  используется в `main_vals` (45) и таблице decode-колонки (96); записи
  `UNITS` parallel-2/4 сохранены.

### 3 · `hfctl` (диспетчер)
- usage между USAGE-маркерами, строка 23: добавлено `[--parallel N[,M…]]`.
  Ветка `bench)` и `*`-список не тронуты.

### 4 · `README.md`
- bench-блок: строка `hfctl bench --parallel 2,4` (56–57) + упоминание в
  списке флагов (70–71), по образцу соседних.

### 5 · Фикстуры СТАРЫХ артефактов (борд, не продукт)
- `fixture-old-quick.json` (27b-single, quick-тройка) и
  `fixture-old-full.json` (flash-multi, full-состав incl. parallel-2/4 без
  `walls` и ar-baseline-пропуск) — синтетика до-сабстэджного формата
  (`do_artifact`), обе с md5 фикстуры `253c7ac5…`.

### 6 · Отступление от «минимального диффа» (осознанное, в рамках функции)
- `mkdir -p "$OUT"` перенесён из шапки `cmd_bench` непосредственно перед
  записью артефакта (683–684): при `die «сервер не отвечает»` в песочнице
  больше не оставался пустой `bench-runs/` — DoD-строка test strategy
  «в $T ни артефактов, ни мусора» иначе не выполнялась (существовало до
  сабстэджа). Рисков нет: `--compare auto` читает каталог через
  `ls … || true` (несуществующий = «первый прогон» — штатно).

## How it was checked internally

Все команды — локально в ocbox, машины НЕ трогались (офлайн-правило).

| Проверка (из Test strategy) | Результат |
|---|---|
| `bash -n hfctl lib/bench.sh` | OK |
| `python3 -m py_compile tpl/python/*.py` | OK |
| selfcheck-watch (`watch_tui.py --selfcheck`) | rc=0 — не затронут |
| `./hfctl` без аргументов | rc=1, usage содержит `--parallel` (строка 21) |
| `--parallel 9 / 0 / a / 2,,3 / 2, / "" / без значения` | rc=1, `FATAL: --parallel: целые 1..8 через запятую (получено '…')` во всех 7 случаях |
| `--parallel 2,4 --help`, `--parallel 1,8 --help` | rc=0 (help-путь) |
| Python-харнес: fake runs.tsv с `parallel-6` + кол.7 | artifact: `walls=[3.1,…,3.3]` в порядке запуска; `summary["parallel-6"]["unit"]=="tok/s agg"`; report печатает `parallel-6`; `parallel-4` без кол.7 читается как раньше (без `walls`) |
| Порядок summary | `solo-code, solo-prose, ttft, parallel-2, parallel-4, parallel-6` (ORDER + динамические по N) |
| Фикстурный `--compare` **обе стороны** | base=`fixture-old-quick` + cur с parallel → rc=0, общие соло-сценарии сошлись, absent-side пропущен, «нет общих» НЕ печатается; base=`fixture-old-full` + cur quick-only → rc=0; base=`fixture-old-full` (parallel-2/4 без walls) + cur с parallel → rc=0, `parallel-2: +0.0%`, `parallel-4: −1.7% … хуже` напечатаны (риск «старый артефакт содержит parallel-2/4» закрыт) |
| Offline-E2E, fake-сервер :19998 (python-шим: /health ok, usage+задержка ∝ позиции, SSE для ttft), песочница `HFCTL_DIR` (`.env`: порт/профиль/модель), `bench --parallel 2,4 --runs 1` | rc=0; runs.tsv кол.7 (непустые walls в порядке запуска: p4=[0.2,0.4,0.5,0.7]); note «per-request wall (curl, по позиции запуска): 0.2с 0.4с 0.5с 0.7с (разброс 0.2–0.7 с)»; интерпретация FIFO-ветки («aggregate ≈ solo — норма для serial-роута»); stderr чист |
| Частичная неудача (шим отдаёт 500 на проза-запросы) | `parallel-4`: warn «2 из 4 не удались», `walls` = 2 значения (только валидные), агрегат по валидным |
| Битый health (`HIPFIRE_PORT=19999`) | rc=1, `сервер не отвечает`, в песочнице ни артефактов, ни `bench-runs/` (после переноса mkdir) |
| Ctrl-C | структурно: grep-чек — запись артефакта (683–686) после всех сценариев, EXIT-trap `rm -rf $BENCH_TMP` (590) не тронут; живой SIGINT в песочнице (супер-медленный шим, сигнал в фазе сценариев) → bench убит SIGINT, 0 файлов в bench-runs, temp `hfctl-bench*` пуст |
| Регресс quick без флага | artifact = прежний формат: summary без parallel-*, ни в одном runs нет `walls`, `fixture_md5=253c7ac5…` |
| Регресс full без флага | дефолтные батчи 2,4 на месте, полный ORDER + ar-baseline-пропуск, rc=0 |
| `--compare auto` в песочнице (base=quick, cur=full) | rc=0 |
| `git status` | изменены ровно `README.md hfctl lib/bench.sh tpl/python/bench_report.py` + 2 фикстуры сабстэджа (untracked); `git diff --name-only` не содержит `tpl/bench` |
| `tpl/bench/merge_sort_thinking_off.txt` md5 | `253c7ac50857fe6d0e10fb0d2c5e35c0` — канон |

## Not checked internally (EXP для tester'а, окна назначает оркестратор)

- **EXP-101-bench-parallel-lanes** (машина B, flash-multi): живой артефакт
  с parallel-2/4 + walls len==N; агрегат растёт с N (ориентир истории
  N=2≈60, N=4≈65, solo 75.8 — рамка, не порог); `--compare` по РЕАЛЬНОМУ
  старому артефакту машины без traceback.
- **EXP-102-bench-parallel-fifo** (che-evo, 27b-single): wall растёт по
  позиции, «FIFO: aggregate ≈ solo», Ctrl-C-чек на живом движке (rc 130/143,
  НОВЫХ файлов в bench-runs нет, /health ok после), compare по реальному
  старому артефакту.
- Песочные E2E не заменяют живые роуты: lanes-процент масштабирования и
  multi-slot-очередь в офлайне не воспроизводились (шим — serial).

## Known limitations / assumptions

- В песочнице ocbox busybox `date` без `%N` (wall=0) — E2E гонялись с
  PATH-шимом `date` (python `time.time()`); целевые машины — GNU date,
  поведение штатное. Шим — только для проверок, в продукт не входит.
- `--parallel N` при полностью упавших соло-прогонах: процент масштабирования
  не печатается («соло-рейт неизвестен») — существовавшая ветка, сохранена.
- Потолок нагрузки `--parallel 8` на FIFO-машине — до ~4 мин (SPEC §6);
  per-request curl-таймаут 300 с не менялся.

## Out-of-scope proposals

- median TTFT под параллельной нагрузкой — снято решением SPEC §2 (не бэклог).
- Пер-позиционные дельты wall в выводе `--compare` — upgrade-путь из task.md,
  если агрегата окажется мало (данные уже в артефакте, `runs.parallel-N[].walls`).
- `hfctl bench --parallel` + автовыбор N по числу lanes из `fn-lanes staged`
  (сейчас список задаёт пользователь) — только по явному запросу.
