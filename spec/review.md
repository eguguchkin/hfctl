# Review: этап 8 — рефакторинг hfctl в дерево (диспетчер + lib/ + tpl/)

Verdict: **APPROVED**
Round: 1
Дата: 2026-11-10. Ревьюер провёл собственную выборочную проверку по коду и
артефактам (не по отчётам): часть проверок пере-запущена независимо.

## Checked

### DoD-комплаенс (по убеждению, с независимой репликой)

| Пункт | Статус | Доказательство (проверено ревьюером) |
|---|---|---|
| 1 раскладка | met | `wc -l hfctl` = 102 (≤450); `grep -c 'python3 -c'` = 0 по всем 11 shell-файлам; heredoc-редиректов в стековый state = 0; `FIXTURE_EOF` = 0; статичные файлы уходят через `install -m 0644` без экспансий (`lib/stack_files.sh`) |
| 2 bash -n / shellcheck | met | `bash -n` всех 12 файлов — rc=0 (пере-запуще­но); shellcheck пере-снят независимо: мультимножество кодов идентично бейслайну, дельты SC1091 **+10** (ровно строки `source "$LIB_DIR/…"`) и SC2034 **+17** (перечисленные cross-module глобалы: IMAGE, PORT, SLOTS×2, BIND×2, TPL_DIR, PROFILE_DEFAULT, ASSUME_YES, UNIT_NAME, STOP_MARKER, CONTAINER, DRAFT_FILE, MAX_SEQ, MEMLOCK, MODELS_DIR, STATE_BASE) — локализовано грепом по сырым findings, соответствует Design §6 и dev-report |
| 3 golden-file parity | met | Независимый пере-запуск `golden_stack.sh old`/`new` (дев-снапшот /tmp/hfctl-stage8, tree свежий = repo C1 — проверено cmp): compose.yml, compose.halo.yml, compose.local.yml ×4, .env ×4, 3 юнита ×4 — идентичны после нормализации sandbox-путей (единственный разброс = `/golden/old/` vs `/golden/new/` в .env/юнитах — артефакт харнеса, задокументирован); stub-логи ×4 идентичны; placeholder-residue = 0 |
| 4 CLI-поверхность | met | `cli_parity.sh` пере-запущен: usage diff = ровно строки 2..6 вывода (файл L3–7 — узаконенное отклонение, текст совпадает с зафиксированным в dev-report); unknown/status/status --json/doctor/models/bench --help — byte-identical, все rc совпадают (проверено по .rc-файлам) |
| 5 чистые функции + md5 | met | `pure_funcs.sh` пере-запущен — PASS; md5 обеих копий фикстуры (benchmarks/prompts + tpl/bench) и old-встроенной heredoc = `253c7ac50857fe6d0e10fb0d2c5e35c0` (гейт BENCH_FIXTURE_MD5 в lib/bench.sh + WARN — в коде) |
| 6 install.sh | met | Код прочитан: clone-only, `grep HFCTL_RAW_URL|curl` = 0; неполное дерево → die с текстом addendum #3, rc 1; замена реального файла симлинком явная (L44–45); `rm -rf "${STACK_DIR:?}/…"`; `install_sandbox.sh` пере-запущен — PASS (из дерева cmp-равно, замена файла, идемпотентность, вне дерева, no-curl) |
| 7 bench-python + ttft | met | `bench_py_parity.sh` пере-запущен — PASS (report/artifact/compare идентичны); `ttft_test.sh` пере-запущен — PASS (162 / null / ERR Connection refused); `tpl/python/` = 13 файлов; `bench_write_py` отсутствует |
| 8 README | met | `grep 'curl -fsSL'` = 0; «Как это устроено» описывает диспетчер + lib/ + tpl/ + clone-дистрибуцию |
| 9 spec | met | В C1 `4ad0519`: spec/hfctl.md §2 переписан (НЕ однофайловый; git clone; curl убран; вне дерева — отказ), spec/plan.md + этап 8, spec/state.md — статус этапа; нейтральные формулировки машин |
| 10 evo полный цикл | met | Продукт IDENTITY: `git diff 4ad0519..HEAD -- . ':!spec'` = пусто; диспетчер в снапшоте md5 `cd623950` == репо (`cmp` подтверждён). EXP-001 (полный цикл, P2–P6a OK: use↔use роуты `multi_slot`/`singleton+DFlash`, off/on, ребут) — сырой result честно завершается `RESULT: FAIL` по P6 (баг харнеса `| health_of` при `set -u`, документирован в Round 1); суть действия P6 доказана независимо `EXP-001r1-verify.sh` **RESULT: PASS**: boot 17:22:27 → юнит active (exited) с 17:22:35, `ExecStart=bash …/hfctl _boot` × status=0, канон 27b-single + mq4-xts health OK, контейнер Up (healthy), smoke OK. Цикл DoD 10 по существу закрыт |
| 11 FAEX полный цикл | met | `EXP-003-faex-full.result.txt` (4-й прогон, rc=0, ровно 260 строк, единственный `RESULT: PASS` в конце): P1 пред-чек → P1.5 lane-бейслайн → P2 update из свежего клона GitHub (UPDATE_OK, lib=10/tpl=6, md5 клон==стек=`cd623950…`, сервер не остановлен, StartedAt не менялся) → P3 use 27b-single (singleton+DFlash, smoke OK) → P4 use flash-multi (strict-pull без докачки; `fn-lanes staged` вернулись; конфиг flash `d2cd5ab8…` байт-в-байт) → P5 off/on → P6 ребут (Result=success, `_boot` exit 0, healthy за 40 c) → P6b smoke → P7 финал flash-multi healthy, lanes=3 refused=0, прод recovered. История прогонов 1–3 (`*-p1fail-keep`, `*-run2-startedat-keep`) — честные артефакты fix-раундов 1–4, продукт не менялся (грепами проверено) |
| 12 hflab-док | pending (по замыслу) | Закрывается ПОСЛЕ ревью — ревью-секвенция задана orchestrator'ом заранее (док не может зависеть от своего собственного вердикта). Известное pending, НЕ провал DoD. Обязательство оркестратора при закрытии: hflab AGENTS.md (hfctl-секция: дерево/дистрибуция), hflab STATE.md, артефакты уже лежат в `.local-analysis/task8-exp/`; финальный C2-статусный коммит (state.md «этап 8 принят») — после DoD 12 |

### Specification compliance
- Design §1–§5 воплощён: 10 lib-модулей в целевом порядке source'ов
  (проверено в диспетчере L63–72); `render_tpl` — чистый bash без
  sed/awk/envsubst + die на остаточных `__X__` (кроме открытого текста —
  grep-гейт точный, перекрывающихся наборов плейсхолдеров нет, ложных
  срабатываний нет); `sync_tree` — маркер `$STACK_DIR/hfctl` + второй early-return
  `SELF == $STACK_DIR/hfctl` + die при неполном дереве (addendum #3).
- Addendum #1–#4 выполнены: обе копии фикстуры + md5-гейт (включая
  c_code.txt-путь через heredoc→cp — md5-идентичность подтверждена);
  usage L3–7 заменены под git-clone, NEW-golden зафиксирован; текст-отказ
  сохранён в sync_tree + install.sh.
- CLI-грамматика (спек §3), exit-коды 42, порядок recreate→wait_health→smoke,
  RAM-гейты, exit-тексты — пути кода не менялись (чистый рефакторинг,
  подтверждено golden/CLI/pure parity).

### Code quality
- Правила AGENTS соблюдены: «ВАЖНО»-комментарии old 5 → new 5 дословно
  (все set -e/pipefail/grep-грабли перенесены); отступов/стиля нарушений на
  основных путях не вижу; ошибочные die-гварды на неполных деревьях и STACK_DIR
  (`:?`) присутствуют в sync_tree и install.sh.
- Правило 7 (ничего хостового в репо): независимый grep «+»-строк C1 и всей
  продуктовой поверхности hfctl/lib/tpl/install.sh/README — 0 IP/ключей/
  user@host/команд ssh; встречающиеся `127.0.0.1`/`${HIPFIRE_BIND:-127.0.0.1}` —
  предсуществующие localhost-практики; «Strix Halo» — платформа AMD
  (предсуществующая). EXP-скрипты и result-артефакты лежат в hflab
  (`.local-analysis/task8-exp/`) — хосты/IP/команды ssh там ШТАТНЫ для лабы,
  приватных ключей (grep BEGIN/PRIVATE KEY) — ноль.
- Секретов в продукте/артефактах не обнаружено.

### Test quality / регрессия
- Тесты меряют DoD-критерии (байт-парность, rc, md5-гейты), а не имплементацию;
  не ослаблены: все развилки проверяются старым и новым кодом на одних
  фикстурах (runs.tsv, fake-SSE, stub'ы).
- Полный внутренний регресс многократно пере-запущен в rounds 1a/2/3/4 поверх
  неизменного продукта (независимо подтверждено: tree==repo по cmp; diff
  продуктовой части с C1 пуст); чужой прогресс не сломан: этап-7 state-функции
  (state_dir/migrate_state/model_set) покрыты pure_funcs parity; этап-5
  модели-сеты и этап-4 lanes-роут — покрыты EXP-003 P4 (strict-pull, lanes
  staged вернулись, refused=0).
- Fix-раунды 1–4 не ввели новых продуктовых изменений (грепы и diff проверены
  независимо — только spec/task-8.md хвост и EXP-скрипты в лабе).

## Findings

### Блокер стадии
Нет.

### Не блокирующие (backlog)
1. shellcheck-шум модульности: SC1091 +10 (source-строки), SC2034 +17
   (cross-module глобалы). Коды не новые, дельты локализованы и объяснены;
   поведение доказано parity. Идея уже в out-of-scope: `shellcheck -x` или
   `.shellcheckrc` с exclude / export-аннотации — отдельным этапом.
2. Финальная строка install.sh («Обновление бинаря: свежий клон …») переписана
   вне двух заявленных исключений вывода — честно задекларировано девелопером
   (dev-report limitation #4), смысл соответствует цели (curl-вывод удалён).
   Не блокер. Следующему факт-писарю: изменения вывода дальше задекларированных
   — формально против правила «байт-в-байт», в такой же ситуации — в
   dev-report FIRST, потом код.
3. Сырой `EXP-001-evo-full.result.txt` оканчивается `RESULT: FAIL` (баг харнеса
   P6), а закрытие DoD 10 опирается на `EXP-001r1-verify.result.txt`
   (RESULT: PASS). Честная append-only история fix-раунда, не переписывалась —
   правильно. Для читателя: итог в Round 1 test-отчёта, детали разнесены —
   при экспорте/кросс-линковке в hflab-док (DoD 12) сослаться на оба
   артефакта рядом, чтобы результат не интерпретировался по последней строке
   первого файла.
4. Расхождение state.md с фактом (говорило «DoD 11 ждёт GO» при закрытом DoD 11)
   — исправлено при ревью (трекер приведён к факту; журнал дополнен).
   C2-коммит ("этап 8 принят") остаётся за оркестратором после DoD 12.

## Questions to the spec
Нет (блокирующих эскалаций не требуется; решения пользователя по формату 3–7
и clone-only-дистрибуции уже ратифицированы в addendum).
