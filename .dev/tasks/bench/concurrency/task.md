# Task: bench/concurrency          Design: architect
Дата 2026-11-14. Вход: `brief.md`, спека сабстэджа `SPEC.md` (здесь),
`../../SPEC.md` §13, `../../FACTS.md`, D8/D10/D11/D12 (`../../DECISIONS.md`).

## Scope and DoD

**Цель (из brief):** `hfctl bench --parallel N[,M…]` даёт параллельную картину
(N клиентов: агрегат + разброс + per-request wall по позициям) поверх quick/full,
артефакт JSON расширяется параллельными записями, `--compare` корректно
сравнивает и со СТАРЫМИ артефактами; прерывание — без мусора.

**In scope:**
1. Флаг `--parallel N[,M…]` в `cmd_bench` (валидация 1..8, замена списка
   full-дефолта 2,4; SPEC §1).
2. `bench_parallel`: колонка 7 runs.tsv (per-request wall по позиции, только
   валидные usage), подписи источника в выводе, сортировка не нужна
   (порядок = порядок запуска = позиция в FIFO) (SPEC §2,5).
3. `bench_report.py`: `walls` в артефакте; динамические `parallel-<int>`
   в report/summary/compare с юнитом `tok/s agg` (SPEC §4).
4. usage-строка диспетчера + `bench_help` + README — по одному упоминанию
   (SPEC §7).
5. Фикстуры СТАРЫХ артефактов (борд, не продукт):
   `fixture-old-quick.json`, `fixture-old-full.json` в этом каталоге —
   синтетические артефакты текущего (до-сабстэджного) формата, руки —
   по `bench_report.py do_artifact`.
6. Внутренние проверки (таблица Test strategy) + EXP-скрипты для tester'а.

**Out of scope (в dev-report «Out-of-scope proposals», не в код):**
- median TTFT по гистограмме под параллельной нагрузкой (решение снято — SPEC §2);
- пер-позиционные дельты wall в выводе `--compare` ( Upgrade-путь, если
  агрегата окажется мало);
- распараллеливание solo-прогонов, `--runs`-умножение батчей;
- проброс движкового `hipfire bench --concurrency`;
- любые правки движка/конфига сервера/`tpl/bench/`.

## Design

Файлы и ответственности (единственные изменяемые файлы продукта):

### `lib/bench.sh`
- `cmd_bench`:
  - разбор: `--parallel)` — значение обязатель (`${2:-}`), regex
    `^[0-9]+(,[0-9]+)*$`, каждое число 1..8 → глобал-локальная строка
    `PAR_LIST="2 4"` (пробелы); иначе `die "--parallel: целые 1..8 через
    запятую (получено '…')"`. Дефолт: quick → пусто, full → `2 4`; явный флаг
    перезадает в любом режиме (порядок пользователя сохраняется).
  - вызовы: после quick-тройки (когда `MED_SOLO_CODE` уже снят) —
    `if [ "$mode" = quick ]` и PAR_LIST непуст → цикл `for n in $PAR_LIST; do
    bench_parallel "$n"; done`; в full-ветке — цикл по PAR_LIST вместо двух
    жёстких вызовов. `B_FULL` не меняется (parallel без ar-baseline/HOL —
    норма).
  - doc-комментарий (Назначение/Побочные/@param) — дополнить по домашнему стилю.
- `bench_parallel` (рефакт минимальный, поведение прежнему кругу сохраняем):
  - цикл sum-валидации помечает валидность i (массив/строка `ok_i`);
    неудачные i — вне суммы (как сейчас) И вне walls;
  - после суммы собрать `walls="` через запятую `%.1f` из `par_wall_$i`
    только валидных i (`sort -n` НЕ применять — позиция запуска);
  - строка runs.tsv: `printf 'parallel-%s\t%s\t%s\t%s\t-\t-\t%s\n' … "${walls:--}"`;
  - `B_NOTE_parallel_$n` = `per-request wall (curl, по позиции запуска): …`
    (бывший текст + подпись источника + min–max разброс одной awk-строкой,
    если валидных ≥2); строка интерпретации по роуту — не трогать (SPEC §3).
- `bench_help`: строка флага + одна строка смысла («параллельные батчи поверх
  quick/full; 1..8; each — один прогон»).

### `tpl/python/bench_report.py` (stdlib, правки ~12 строк)
- `load_runs`: `if len(p) > 6 and p[6] not in ("", "-"): e["walls"] =
  [float(x) for x in p[6].split(",")]`.
- порядок: helper `def scen_order(keys): return ORDER + sorted((k for k in
  keys if RE_PAR.match(k) and k not in ORDER), key=lambda k: int(k.split("-")[1]))`,
  `RE_PAR = ^parallel-\d+$`; применять: `summary_of`/`do_report` — по
  `scen_order(runs)`, `do_compare` — по `scen_order(объединение ключей обоих
  summary)` (отсутствующая сторона → пропуск, как сейчас: `cm is None or
  bm is None`).
- юнит: в `main_vals` — `"tok/s agg" if RE_PAR.match(sc) else UNITS.get(sc,
  "tok/s")` (записи UNITS parallel-2/4 остаются, ложатся в тот же префикс).
- Совместимость (контракт SPEC §4): новые ключи только additive; при reading
  старых summary/base — ничего не требовать.

### `hfctl` (диспетчер)
- usage между маркерами USAGE: строка `bench …` дополняется
  `[--parallel N[,M…]]`. Ветка `bench)` и `*`-список — не трогать.

### `README.md`
- bench-блок: одна строка `hfctl bench --parallel 2,4  # параллельная картина
  …` + в таблице флагов упоминание (по образцу соседних строк).

### Данные/потоки (для ролей, чтобы не угадывали)
- runs.tsv `parallel-N`: кол.2=wall окна, 3=Σ completion, 4=aggregate
  (tok/s agg — главная метрика summary/compare), 7=walls по позиции.
- артефакт: `runs["parallel-N"][0]["walls"] = [w1,…,wN]`;
  `summary["parallel-N"] = {median,min,max,unit:"tok/s agg"}`.
- `--json`/`--fresh`/`--out`/`--compare` пути — без изменений семантики.

### Edge cases
- все запросы батча неудачны → warn + сценарий отсутствует (не пустая строка);
- частично неудачны → aggregate по валидным, warn, walls короче N;
- `--parallel 1` — разрешён (одиночный «параллельный» замер = sanity);
- quick+`--parallel` без мед. соло (все соло-прогоны упали) → `MED_SOLO_CODE`
  пуст → ветка «соло-рейт неизвестен» (уже обработано);
- Ctrl-C: артефакт пишется после сценариев → файла нет; trap EXIT чистит
  BENCH_TMP; фоновые curl умирают с SIGINT группы.

## Test strategy

| DoD item (brief) | внутренняя проверка | внешняя (что доказать) |
|---|---|---|
| разбор флага | `bash -n hfctl lib/bench.sh`; `./hfctl bench --parallel 9` / `0` / `a` / `2,,3` / `--parallel` без значения → die rc≠0 с текстом; `--parallel 2,4 --help`/`--parallel 1,8` rc=0 help-путь; usage-строка содержит флаг | — |
| парсер артефакта / стены | python-харнес (девелопер, /tmp): fake runs.tsv с parallel-6 + кол.7 → artifact: `walls`, `summary["parallel-6"]["unit"]=="tok/s agg"`; report содержит строку `parallel-6`; строки без кол.7 читаются как раньше | EXP-1: живой артефакт содержит parallel-2/4 + walls |
| совместимость --compare со старыми | фикстуры `fixture-old-quick.json` / `fixture-old-full.json` (этот каталог): `B_ARTIFACT=<новый с parallel>` compare по каждой → rc=0, общие сценарии сошлись, absent-side пропущен, «нет общих» НЕ печатается; обратное (base новый, cur quick-only) — тоже; `python3 -m py_compile tpl/python/*.py` | EXP-1/EXP-2: `--compare` по РЕАЛЬНОму старому артефакту машины (свежайший в bench-runs до апдейта) |
| агрегат/стены по роутам | offline E2E (рекомендовано tester'у, приём 10.2 — fake-сервер): python-шим :19998 (`/health` ok c loading_model null; `/v1/chat/completions` — usage c фиктивным ct и задержкой ∝ позиции) + песочница `HFCTL_DIR=$T` с `.env` (`HIPFIRE_PORT=19998`, профиль) → `./hfctl bench --parallel 2 --runs 1` в дереве репо: runs.tsv кол.7, note с min–max и подписью curl, интерпретация по ROUTE-ветке | EXP-1 (машина B, lanes): агрегат растёт с N, per-request wall ровные по позициям, % масштабирования печатается; порядок цифр сопоставим с историей (N=2≈60, N=4≈65 aggregate, solo 75.8 — рамка ориентир, не жёсткий порог) |
| соло не деградировал / FIFO-картина | — | EXP-2 (che-evo, 27b-single): wall растёт по позиции, строка «FIFO: aggregate ≈ solo», quick-соло в норме |
| прерывание/битый health | grep-чек: artifact-write остаётся после всех сценариев; EXIT-trap не сломан. Битый health — ВНУТРИ (песочница, машину не трогать): `T=$(mktemp -d); printf 'HIPFIRE_PORT=19999\nHFCTL_PROFILE=27b-single\n' > "$T/.env"; HFCTL_DIR=$T ./hfctl bench --parallel 2` → die «сервер не отвечает» rc=1, в $T ни артефактов, ни мусора | EXP-2: Ctrl-C посреди параллельного блока → rc∈{130,143}, НОВЫХ файлов в bench-runs нет, temp чист, /health ok после (движок живёт с dying-клиентами) |
| DoD brief «tpl/bench не трогать», md5 канон | `git diff --name-only` не содержит tpl/bench; md5 фикстуры в выводе прогона = `253c7ac5…` | EXP печать md5 в артефакте `fixture_md5` |
| регресс существующего bench | quick без флага: артефакт = прежний формат (ключи summary те же, parallel отсутствует); `bash -n`, py_compile, usage rc=1 без аргументов | EXP-1 прогон без `--parallel` = прежний quick (одна сверка артефакта) |

Внешние EXP (создаёт tester в `.dev/external/`, формат скила; правило
одной машины + предупреждение/GO пользователя заранее; реальные результаты —
hflab `.local-analysis/`, в репо — заглушки (D10); пакетная доставка D12):
- **EXP-101-bench-parallel-lanes** — машина B (flash-multi, healthy):
  `hfctl bench --parallel 2,4 --runs 1`; PASS = rc=0; строки lanes-%;
  walls в артефакте (jq/python-чек len==N); повторный
  `hfctl bench --compare <артефакт>` по прежнему реальному артефакту — дельты
  без traceback.
- **EXP-102-bench-parallel-fifo** — che-evo (27b-single, прод; короткое окно,
  предупреждение о нагрузке): `--parallel 2,4 --runs 1` (FIFO-картина +
  compare по реальному старому артефакту) + Ctrl-C-чек + мёртвый-health-чек.
  Порядок: строго ПОСЛЕ EXP-101 (одна машина за раз).

## Risks and rollback

- Риск: `--compare` по реальному старому артефакту содержит `parallel-2/4`
  summary — новый код обязан их напечатать (ORDER-фикстура это покрывает).
- Риск: нагрузка на прод-evo (FIFO 4×300 tok ≈ десятки секунд solo-простоя
  соседей) — EXP-102 коротким `--runs 1`, окно по GO.
- Риск: старый runs.tsv/чтение колонки 7 отсутствующей — покрыто внутренним
  чек-парой.
- Откат: один коммит сабстэджа, revert без миграций (артефакты additive,
  колонка 7 старым кодом игнорируется).

## References

brief.md; SPEC.md (сабстэдж); `../../SPEC.md` §13; `../../FACTS.md`
(счётчики done-only, per-request сводки в логе); `lib/bench.sh`
(bench_parallel/cmd_bench), `tpl/python/bench_report.py`, `par_usage.py`;
hflab AGENTS.md (FIFO/lanes цифры, грабля par_test №4 — очистка resp_*
уже сделана в bench_parallel); D8 (честные метрики), D12 (пакетная приёмка).

## Open questions

Неблокирующие (решения приняты architect, зафиксированы в SPEC):
1. `--parallel` в full ЗАМЕНЯЕТ список 2,4 (дополнение — нет: YAGNI, порядок
   пользователя и так свободен).
2. TTFT-под параллелью снят (загрязнение гистограммы; SPEC §2) — если
   пользователю понадобится, это отдельный сабстэдж с done-дельтами /metrics.
