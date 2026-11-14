# Review: bench/interrupt
Verdict: APPROVED
Round: 1

## Against DoD
| item | met/partial/missing | proof/complaint |
|---|---|---|
| 1 · офлайн-репро до/после | met | Dev-таблица: ДО не прерывался кейс B (orphan_curl=4 при rc=130 — фоновые curl с INT=ignored доживают), кейс A прерывался и до. Ре-проход reviewer'ом песочницы ПОСЛЕ (harネス run_case.py, sim :19998): INT в параллельном блоке → rc=130, orphan=0, artifacts=0, temp чист; TERM → rc=143, то же. Реентерабельность (двойной INT, гэпы 0.2/0.4/1.0 с): rc=130, артефактов 0, temp чист; первоначальный «orphan=1» оказался само совпадением pgrep -f с cmdline собственного харнеса — ps-инспекция подтвердила: живых curl ноль. |
| 2 · минимальный фикс (INT/TERM trap, rc 130/143, без артефакта, temp через сущ. EXIT-trap, один файл) | met | `bench_abort` (lib/bench.sh:526–538) + трапы сразу после EXIT-трапа (636–637). Порядок убийства верный: сначала `jobs -p`→`pkill -TERM -P` (curl внутри фоновых subshell'ов, пока PPid совпадает), затем прямые дети `pkill -TERM -P $$`, затем `wait`. `pkill -P $$` корректен: `cmd_bench` вызывается в главном шелле диспетчера (`hfctl:223`), не в subshell. Реентерабельность: `trap - INT TERM` в начале обработчика — двойной сигнал не рвёт цикл убийства повторно, `exit` даёт единственный EXIT-trap rm (двойного rm / гонок нет: `wait` доубивает детей до rm). На штатном пути трапы не срабатывают (сигналов нет) — E2E без сигналов: rc=0, артефакт на месте, stderr 0 байт. |
| 3 · usage + README | met | `bench --parallel 2,4 --help` → rc=0, в usage строки «Ctrl-C (SIGINT)…» есть; README.md:74–75 — буллет про семантику Ctrl-C. |
| 4 · регресс не сломан | met | Reviewer сам: `bash -n hfctl lib/*.sh` — OK; `--parallel 9/0/a/"2,,3"/""` → rc=1 (все 5); `--compare` фикстурами bench/concurrency в обе стороны (quick↔full, B_ARTIFACT=inline JSON + B_RUNS из восстановленного runs.tsv) → rc=0, дельты печатаются; offline-E2E штатного прогона → rc=0, artifacts=1, stderr пуст; md5 tpl/bench фикстуры `253c7ac5…` — канон. |
| 5 · шов SPEC.md:79–82 | met | Перечитан хвост: «rc 130/143 допустимы; сервер не страдает (запросы dying-клиента движок обрабатывает штатно)» — фикс точно в этом: артефакт только в конце (не затронут), temp — сущ. EXIT-trap, rc 130/143, доубивка запросов (лучше минимума SPEC). `die`-пути (битый конфиг/health) не тронуты diff'ом. |
| 6 · живая проверка | n/a (за оркестратором по брифу) | Машины не трогались ( reviewer и developer). Замечание для EXP-скрипта из dev-report («не `bench &` из скрипта — INT ignored на входе») корректно и подтверждено механизмом из брифа. |

Scope: git diff = ровно `lib/bench.sh` + `README.md` (+untracked каталог сабстэджа). Правки в bench.sh: usage-heredoc (+2), docblock-комментарии, новая функция, 2 trap-строки — штатный stdout/stderr не изменён ни на байт (подтверждено E2E: stderr 0 байт). Новый Python не заводился. pkill: procps — Essential на Ubuntu/Debian (целевая платформа), зависимость приемлема и документирована в коде.

## Blocking
(нет)

## Non-critical notes
1. docblock-перенос в Побочных эффектах (строка «…см. bench_help;» / «артефакт» на отдельной строке) — косметика переноса, править не нужно.
2. Одиночный `kill -INT <pid>` без группы дождётся текущего foreground-запроса (POSIX-семантика трапа) — в docs не обещано, в Known limitations dev-репорта отражено; канон (группа/терминал) работает.
3. Режим `bench &` из неинтерактивного скрипта (INT ignored на входе) непрерываем из bash — известное платформенное ограничение, объясняет EXP-102; задокументировано в ограничениях bench_abort. При живой приёмке запускать foreground/pty.

## Questions to the spec
Нет.
