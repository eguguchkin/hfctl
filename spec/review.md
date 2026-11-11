# Review: Этап 9 — зачистка переходного, мёртвого и дублей
Verdict: **APPROVED**
Round: 1
Дата: 2026-11-11. База: `638df18`; коммиты `71a24f5 e73bdc7 0f18526 408a017 39daa89 b5f5565 8cf7b48 c7414e2` (HEAD).
Метод: проверки реплицировались независимыми прогонами в собственной песочнице
`/tmp/hfctl-review` (`tree` = git archive c7414e2, `pre` = 336cd1f, stub'ы — снимок
этапа 8), а не по отчётам. Носители: `hflab/.local-analysis/task9-exp/{test,test9,final}/`.

## Against DoD

| item | met/partial/missing | proof/complaint |
|---|---|---|
| 1 переходное | **met** | Мой grep-гейт `migrate_state\|migrate_models\|state_dir\|MODEL_DEFAULT\|hipfire_hipfire-config` по hfctl/install.sh/lib/tpl = 0 совпадений. Осиротевших docblock'ов нет: python-скан 67 функций дерева — висячих ссылок на удалённые имена ноль; `grep -i 'миграц\|legacy-вольюм'` по hfctl/install.sh/lib/tpl/README = 0 (шапка state.sh переписана честно: каталоги создаёт podman при первом bind). Висячих присваиваний после удаления v1-ветки не осталось (write-only-локалы `set_port/set_bind/set_models` убраны тем же коммитом; флаги `--port/--bind/--models-dir` по-прежнему пишут глобалы — поведение сохранено). Doctor-WARN и `podman volume rm` из uninstall удалены; текст эха uninstall изменён осознанно (вне cli_parity-набора, в Design §1.8). |
| 2 мёртвое | **met** | `grep 'env_val HIPFIRE_BIND' lib/bench.sh` = 0 (локал `v` жив для PORT-строки); мой shellcheck-дельта-прогон подтвердил уход SC2034 bench.sh `BIND` и SC2034 commands.sh `retries` (поле теперь читается). Решение architect'а (печать при ≠0) реализовано (`commands.sh:356`) и реплицировано харнесом watch_retries: retries=2 → «ретраи: 2»; retries=0 и без поля → молчит (`isint('-')` отсекает). Обоснование в Design §2 и hfctl.md §13. |
| 3 `.env` без COMPOSE_FILE | **met** | `tpl/env/env.tpl` — строки нет; `grep COMPOSE_FILE` живого дерева: только комментарий `lib/stack.sh:13` (оставлен явно по Design §3) и README-пояснение. Мой перепрогон golden-матрицы pre(336cd1f) vs post(c7414e2), 36 файлов ×4 комбинации: после нормализации штампов песочницы отличий ровно 4 — удаление `COMPOSE_FILE=…` в `.env`; compose×4/юниты×3/прочее — байт-в-байт. |
| 4 фикстура | **met** | `benchmarks/` в репо нет; `md5sum tpl/bench/merge_sort_thinking_off.txt` = `253c7ac50857fe6d0e10fb0d2c5e35c0`; AGENTS.md/README/bench.sh-комментарий переписаны на `tpl/bench/`; `BENCH_FIXTURE_MD5`-гейт на месте; prompts-маунт (`stack_files.sh:119,158`, `compose.local.yml.tpl`) не тронут — 2 runtime-упоминания `$STACK_DIR/benchmarks/prompts` легальны по букве DoD 4 («механизм НЕ трогать»; гейт «grep=0» в Test strategy — формулировка уже триажена tester'ом как test-фикс, не код). |
| 5 форс-канал | **met** | `grep FORCE_GATE` по коду/README/hfctl.md = 0 (единственное вхождение — «Теневого FORCE_GATE больше нет» в hfctl.md §13, это констатация). Мой прогон force_gate: пул 31 GiB < 80: plain `use flash-multi` rc=1 ERROR с цифрами (правило 4 — до скачивания ✓); `HFCTL_FORCE=1` и `--force` — cmp выводов идентичен. die-строка install перечисляет `--force`. README: `--force` в таблице install + env-синоним в разделе профилей. |
| 6 дубли | **met** | (а) `route_snapshot` — единственный владелец движковых предикатов (мой grep: `fn-lanes staged`/`qwen4 lanes refused` в lib/ только в health.sh; в bench.sh:71 — сопоставление `$ROUTE_SPEC`, не повторный grep). Мой перепрогон route-матрицы на 6 фикстурах × 3 профиля: pre vs post — 6/6 cmp идентичны (тексты check_route байт-в-байт), приоритет staged→refused→нет данных подтверждён на both.log, enum bench даёт все 5 значений (`lanes/serial-fallback/multi-slot/singleton-dflash/singleton-serial`) — константа `--compare` не поехала, литерал `multi-slot` обоснован (Design §12.1). (б) `stop_with_marker` — одна реализация; мой stop_matrix-прогон: stub-compose зафиксировал `stop:marker-before` в BOTH down и off; у off — disable юнитов + disable-linger на месте; `mkdir -p STACK_DIR` переехал в helper (у cmd_down это безвредное addition, в docblock отражён). |
| 7 швы | **met** | (а) cfgset без `|| true`, rc конвейера; apply_profile: мой cfgset_fail-прогон (stub rc=1) — rc=1, warn с полным перечнем 11 ключей, ВСЕ 11 вызовов сделаны (не умирает на первом); вызывающие ровно два — `commands.sh:67,158`, оба `|| true` (grep-гейт «apply_profile вне if/|| = нет» прошёл); `if [ -n "$failed" ] … fi` при пустом failed даёт 0 — «успех = 0» корректно. (б) cmd_boot: `( flock -n 9 && compose up -d --force-recreate … || true ) 9>lock || true` — рекурсии нет (hf_up_locked держит lock только внутри своего субшелла; recreate-субшелл — следующий), `-n` → вечного ожидания нет, занятый lock → молчаливый пропуск не-ошибка, следующий `i%3` догонит; риски закрыты EXP-ребутом (DoD 10). (в) `cur_model` = `{ env_val HIPFIRE_MODEL; }`. (г) `keep` в `local purge_models=0 purge_image=0 keep=""`; «ГЛОБАЛ (забыто)» из docblock снят. (д) usage по маркерам (`hfctl:2,22`), мой cmp: вывод == `usage_new_golden.txt` байт-в-байт; `grep '2,20p'` = 0; литералы маркеров в docblock/теле не матчатся якорями `^…$` — дублей диапазона нет. |
| 8 регресс | **met** | Мои прогоны на HEAD: `bash -n` 12/12; shellcheck before(39)/after(37) — новых кодов нет, дельта = −SC2034 BIND, −SC2034 retries, −SC2005 cur_model, +SC2034 commands.sh `HFCTL_FORCE` (кросс-файльный глобал: пишется commands.sh:55,136 → читается profiles.sh:110 — тот же класс, что 13 штатных SC2034-записей базлайна; принят, как в dev/test-report); golden-матрица (см. 3); cli_parity PASS (usage==golden с обеих сторон, unknown-cmd rc+stderr идентичны, status/--json/doctor/models/bench--help — только живой дрейф MemAvailable); pure_funcs PASS; bench_py_parity PASS; ttft PASS (161 мс/null/ERR); install_sandbox PASS на свежем дереве HEAD (из дерева/замена/идемпотентность/вне дерева). |
| 9 документация | **met (с отложенным хвостом C9)** | hfctl.md §13 присутствует и покрывает все шесть контрактов + «переходного кода нет» (тексты §1–§12 не тронуты — аддendum); README: `--force`+`HFCTL_FORCE`, отсутствие `COMPOSE_FILE`, фикстура `tpl/bench/`; plan.md: DoD 1–9 [x], 10–12 [ ]. `spec/state.md` ещё показывает этап 9 «спланирован» — синхронизация штатно отнесена Design §10 на статусный коммит C9 после приёмочных EXP (и DoD 12 несёт «этап 9 принят»); не блокер, но C9 обязателен при закрытии (правило 1). |
| 10 EXP-004 (evo) | **created, пригоден** | Доказывает ровно перемённое: update из клона без остановки + греп `flock -n 9 && compose up -d --force-recreate` на машине (правка доехала), use↔use, doctor без «legacy-вольюмы», off/маркер/вотчдог-молчание 90 с/on, watch-тик без «ретраи», ребут→сам-подъём с доказательством recreate в boot (Created ≥ boot), финал 27b-single healthy. Таймауты bounded (ssh 900 с, ребут ≤10 мин, healthy ≤15 мин, всё <20 мин). Ребут — только с GO (шапка, `SKIP_REBOOT` опция). Гигиена: свой клон в /tmp + trap; чужие контейнеры (hfbox) не трогает. Блокирующая предпосылка — GO пользователя на ребут (машина в проде). |
| 11 EXP-005 (FAEX1) | **created, пригоден** | update БЕЗ остановки (assert healthy после), doctor, smoke, `fn-lanes staged` в `podman logs -t … 2>&1`, bench quick → `"route": "lanes"` + отсутствие md5-warn, `podman volume ls` без hipfire-вольюмов, финал flash-multi healthy. Профиль НЕ переключает, off/on НЕ делает, gufo-соседа не трогает; штатный bench-артефакт задекларирован побочным продуктом. `grep 'fn-lanes staged' lib/bench.sh` = 0 на машине — прямой контроль DoD 6а. |
| 12 hflab-док + «принят» | **not started (по плану)** | Пост-приёмочный шаг оркестратора (C9 + hflab AGENTS/STATE). Ожидается после EXP-004/005. |

## Blocking

Нет. Ни одного блокера.

## Non-critical notes (backlog)

1. **Переносимость харнесов этапа 9.** Фикстуры `route-fixtures/*.log` живут только
   в dev-песочнице `/tmp/hfctl-stage9` (преходящей), а stage-8-копии
   `install_sandbox.sh`/`ttft_test.sh`/`bench_py_parity.sh` в носитель `test/` — с
   захардкоженным `S=/tmp/hfctl-stage8` (я прогонял их с своим деревом через sed
   копии). Догадаться о составе route-матрицы из носителя нельзя. Мелочь, но
   «round resumable from artifacts» (skill) нарушена: скопировать фикстуры +
   параметризованные копии в `task9-exp/test9/` при закрытии.
2. **`+SC2034 HFCTL_FORCE`** — принят как штатный кросс-файльный глобал; если
   захочется нулевого шума — точечный `# shellcheck disable=SC2034` на присваивание,
   не нужно в этом этапе.
3. **`install.sh:ok()`** — единственный docblock из 67 без секции «Ограничения»
   (пре-existed с `336cd1f`, install.sh побайтово идентичен базлайну — мой скан
   подтвердил). Backlog.
4. **Хрупкость движковых grep-швов** (6 шаблонов в `route_snapshot`): консолидация
   в один helper — правильное облегчение; но при смене текстов движка отказ
   тихий (пустые поля → «данных нет»/`serial-fallback`). Если однажды понадобится
   детект «ни один шаблон не матчится на healthy-сервере» — это сигнал, что
   движок переписал лог; сейчас сознательно принято как норма.
5. **Формулировка гейта DoD 4** в Test strategy («grep по репо = 0») расходится с
   легальными runtime-упоминаниями в `stack_files.sh` — tester триажил как test-fix;
   при правке Test strategy не менять код.
6. **cli_parity не покрывает `down`/`off`/`uninstall`** тексты итоговых строк —
   изменённый эхо-текст uninstall закрыт только чтением; EXP-004 P6 покрывает
   off/on-выводы живьём. Достаточное покрытие, noting.

## Questions to the spec

- Правило 7 hfctl-AGENTS («в репо нет имён хостов») формально задевает spec-тексты
  (`spec/plan.md`, `spec/task-9.md`, `spec/state.md`: прод-машина (60 GiB)/вторая машина (128 GB)) — устоявшаяся
  практика с этапов 6–8 (IP/ключей/логов = 0 — мой grep подтвердил), но стоит
  раз и навсегда зафиксировать у оркестратора/пользователя трактовку: правило
  про код/харнеси/README или буквально про всё дерево. Если буквально — чинится
  одним токенизирующим проходом по spec-текстам (не этого этапа).

## Что реплицировано прогонами (собственная песочница, независимые прогоны)

`bash -n` ×12; shellcheck before/after мультимножеством (39→37, дельта совпала с
заявленной); route_matrix pre/post ×6 фикстур ×3 профиля — 6/6 cmp идентичны +
все 5 enum-значений; cli_parity (usage==golden cmp-пусто); golden-матрица pre/post
36 файлов — после нормализации штампов отличие ровно −COMPOSE_FILE ×4; stop_matrix
(маркер ДО stop в down и off); cfgset_fail (rc=1, warn с 11 ключами, 11 вызовов);
watch_retries (3 варианта /stats); force_gate (plain/env/flag); pure_funcs;
bench_py_parity; ttft_test; install_sandbox на свежем архиве HEAD. Плюс статические
гейты (grep-наборы DoD 1/3/4/5/6/7д, callers apply_profile/cfgset, house-style
скан 67 функций/99 групп выравнивания, правило 7: IP=0).

Вердикт: **APPROVED**. Блокеров нет; закрытие этапа — за EXP-004/005 (GO
пользователя, ребут evo) и статусным C9 + DoD 12.
