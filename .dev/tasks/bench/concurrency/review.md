# Review: bench/concurrency
Verdict: APPROVED
Round: 1
Дата 2026-11-14. Ревьюер проверял сам (артефакты + код + повторные прогоны), машины не трогал.

## Against DoD

| item | met/partial/missing | proof/complaint |
|---|---|---|
| Разбор флага (SPEC §1) | met | Проверено ревьюером: `--parallel 0` / `9` / `abc` → rc=1, `FATAL: --parallel: целые 1..8 через запятую (получено '…')` с полученным значением; die в цикле разбора (lib/bench.sh:557–565) ДО проверки .env/health/сервера. `--parallel 2,4 --help` rc=0; `hfctl` без аргументов rc=1; usage-строка (hfctl:23) содержит флаг. |
| Дефолты/замена списка | met | diff: `par_list` пусто для quick, `2 4` для full (577–579); явный флаг перезадает в обоих режимах; порядок пользователя и дубли сохраняются (цикл `for pn in $par_list`, без дедупа/sort) — SPEC §1. |
| Колонка 7 + подписи (SPEC §2) | met | diff: колонка 7 `${walls:--}` только из валидных i в порядке запуска (без sort); note «per-request wall (curl, по позиции запуска)» + min–max при ≥2. Aggregate = Σusage/wall окна — без изменений. TTFT в параллельном блоке не заявлен: в отчёте строки parallel-N дают TTFT «—» (проверено прогоном report). |
| bench_report.py (SPEC §4) | met | Прогоны ревьюера на fake runs.tsv: `walls=[5.1,4.9]` — порядок запуска сохранён (не сортируется); «-» в кол.7 → `walls` отсутствует; динамический `parallel-6` в summary/report с юнитом `tok/s agg`; порядок ORDER + параллельные по N. |
| Совместимость --compare со старыми | met | Прогоны ревьюера обе стороны: base=`fixture-old-quick` + cur с parallel → rc=0, solo-тройка сошлась, absent-side пропущен, «нет общих» НЕ печатается; base=`fixture-old-full` (parallel-2/4 без walls) + cur с parallel → rc=0, `parallel-2/4: … tok/s agg` напечатаны; обратное (base новый, cur quick-only) → rc=0. `python3 -m py_compile` OK. |
| Прерывание/битый health (SPEC §5) | met | diff: запись артефакта остаётся после всех сценариев; EXIT-trap не тронут. Перенос `mkdir -p "$OUT"` к записи (684) проверен: единственные чтения каталога до записи — echo (634) и `ls … 2>/dev/null || true` (677, несуществующий = «первый прогон») — штатно; `cp` сразу после mkdir. Отступление обосновано в dev-report §6, в рамках функции, не блокирует. |
| UX-строки (SPEC §7) | met | bench_help (30–32), usage диспетчера, README (2 места) — по диффу. |
| tpl/bench не трогать | met | `git diff --name-only` = ровно `README.md hfctl lib/bench.sh tpl/python/bench_report.py` + 2 фикстуры сабстэджа (untracked, борд); md5 фикстуры `253c7ac50857fe6d0e10fb0d2c5e35c0`. |
| `bash -n` | met | `bash -n lib/bench.sh hfctl` — OK (проверено ревьюером). |
| EXP-101/EXP-102 (живые роуты) | BLOCKED-EXTERNAL | Ожидается от tester'а; офлайн-покрытие (шим) не подменяет живые lanes/FIFO — закрытие на усмотрение оркестратора по результатам EXP. |

## Blocking

Нет.

## Non-critical notes

1. `--parallel 01`/`08` принимаются (test-арифметика трактует как 1/8) — безвредно, можно не чинить.
2. Docblock cmd_bench (строка 511) всё ещё описывает `mkdir -p` у определения OUT; после переноса каталог создаётся только под запись — микроскопическая рассинхронизация комментария, в бэклог.
3. Строка «артефакты: $OUT» печатается до создания каталога — косметика, отражает намерение.
4. Повторный `--parallel` в одной командной строке: последний список побеждает — не специфицировано, разумно, фиксировать не требуется.

## Questions to the spec

Нет (§2 TTFT-под-параллелью закрыт решением, «Open questions» пуст).
