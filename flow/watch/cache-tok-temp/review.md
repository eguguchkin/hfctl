# Review: watch/cache-tok-temp
Verdict: APPROVED
Round: 1

## Against DoD
| item | met/partial/missing | proof/complaint |
|---|---|---|
| DoD 1 — TUI `Cache tok` + пороги 80/90 обеих температур | met | Диф: `('Cache tok', fmt_tok(...))` (:1172), `GPU temp`/`CPU temp` → `self.attr(temp_color(...))` (:1186–1190). Независимый python3-однострочник: `fmt_tok` 999→`999`, 1000→`1.0k`, 99100→`99.1k`, 1234567→`1.2M`; `temp_color` 79.9→0, 80→C_YELLOW, 89.9→C_YELLOW, 90→C_RED, None→0 — все ровно. |
| DoD 2 — plain: тот же текст, ANSI в pipe нет | met | `cache tok: %s` + `fmt_tok` (:489); grep по файлу: ANSI-escape-последовательностей нет вообще, plain не красится ни при каком stdout (ветка task.md п.3, решение зафиксировано в dev-report и в спеке). `PLAIN_FULL` → `cache tok: 4.4k`, `PLAIN_MIN` → `cache tok: -`. |
| DoD 3 — чистые функции + selfcheck | met | `fmt_tok`/`temp_color` — чистые, рядом с `fmti`; фактический прогон: `selfcheck: 48/48 ok`, rc=0 (было 42, +6 новых проверок, как заявлено). |
| DoD 4 — ничего лишнего | met | `git status`: изменены только `tpl/python/watch_tui.py` + `spec/hfctl.md` (+ untracked `flow/watch/cache-tok-temp/`); `lib/*.sh`, `tpl/compose/` не тронуты; md5 фикстуры `253c7ac5…` — канон цел. Диф-хоки только cache/temp/selfcheck/спека. |
| DoD 5 — внешняя приёмка (EXP, машина B) | не в зоне разработчика | Осознанно外 external (task.md: «прогон plain локально невозможен»), за оркестратором. Не блокирует APPROVED кода; сабстэдж закрывать только после EXP. |
| DoD 6 — доставка D12 | вне кода правки | Оркестратор/пользователь после пуша. |

## Прочие проверки (из мандата)
- Семантика счётчика: ключ `hipfire_cached_prompt_tokens_total` не изменён, дельт нет,
  кумулятивность не тронута (коллектор в диффе отсутствует) — изменён только способ печати.
- Регрессия DoD 1 (порядок строк блока «Движок»): selfcheck-проверка `engine labels`
  обновлена на `Cache tok` и зелёна в составе 48/48; ширины/минимум 80×24 диффом не затронуты
  (`Cache tok: 1.2M` короче прежнего — колонка не едет).
- Спека `spec/hfctl.md` §watch: `Cache tok` + формат, пороги «жёлтый 80…89, красный ≥90
  (ровно границы)» для CPU И GPU, пометка «в plain ANSI не печатается» — соответствует канону решений.
- `999_999 → 1000.0k` — ровно по формуле task.md; ограничения честно в dev-report.

## Blocking
(нет)

## Non-critical notes
1. Breve-парантешн «сравнение по факту round-то, как печатается»: реализовано сравнение
   по сырому значению (буквальный канон 80≤t<90 из решений пользователя; совпадает с task.md).
   Практический след: 79.95°C печатается «80.0» без подсветки (GPU — fmti: 79.6→«80» без
   подсветки). Если нужен ровно print-consistent режим — свернуть вход в temp_color через
   тот же fmt, что печатается; бэклог-заметка, не блок.
2. tester skipped для этого сабстэджа ещё не зафиксирован строкой в `flow/history.md`
   (правило skill — не silent). Ответственность оркестратора при закрытии.

## Questions to the spec
Нет (§watch обновлён синхронно с кодом).
