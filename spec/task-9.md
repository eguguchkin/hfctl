# Этап 9 — зачистка переходного, мёртвого и дублей

Файл — носитель этапа: Brief (оркестратор) → Design (architect) → Test strategy
→ Dev report → Test report → Review. Отдельные артефакты ролей дописываются
СЮДА же (как в `spec/task-8.md`).

## Brief (orchestrator, 2026-11-11)

### Goal (статизируемый, проверяемый)

В дереве hfctl (HEAD `336cd1f`: диспетчер + `install.sh` + `lib/*.sh` ×10 +
`tpl/`) не остаётся переходного и мёртвого кода: механизмы миграций сняты
(адресатов больше нет — см. «Предпосылки»), дублирующие реализации сведены к
одной,задокументированные швы чинятся. CLI-поверхность и генерируемый стек
**сохраняются байт-в-байт**, кроме явно перечисленных в DoD изменений
(`COMPOSE_FILE` в `.env`, исчезновение warn-строк удалённых миграционных
веток, печать `retries`, тексты отказа форс-гейта при env-синониме).

### Предпосылки (закрыты оркестратором до кода)

- Ревизия-основание: `hflab/.local-analysis/hfctl-audit-recon.md` (scout,
  HEAD `336cd1f`, живые read-only ssh-сверки обеих машин). Мёртвых функций нет;
  разделы 2–5 — адресаты этапа.
- **2026-11-11, миграции завершены на обеих машинах** (read-only аудит):
  прод-машина (60 GiB) — per-профиль state есть, legacy-вольюмов нет (чужой
  `hfbox-hipfire-config` не наш); вторая машина (128 GB) — per-профиль state есть
  (`profiles/flash-multi/config` = живой, 32 GB), legacy-вольюмы оказались
  устаревшими копиями (136K + 36K, config.toml не совпадает с живым).
- **2026-11-11, шаг 0б выполнен оркестратором с GO пользователя** (бэкап
  пользователь явно отменил): `podman volume rm hipfire_hipfire-config
  hipfire_hipfire-kernels` на FAEX1 — rc=0, ни один контейнер их не
  использовал, сервер остался healthy; `podman volume ls | grep -i hipfire` =
  пусто. На evo удалять нечего.
  → Переходных адресатов у продукта больше нет: удалять можно.

### DoD (единственный носитель чеклиста этапа; синхронизирован с `spec/plan.md` «Этап 9»)

Код (внутренние проверки, dev-контейнер):

- [ ] 1. Переходное удалено: `migrate_state`, `migrate_models`, `state_dir`
      (её последние потребители — log-строки этих миграций), v1-`.env` ветка в
      `cmd_install`/`cmd_use` (+ implicit-глобал `MODEL_DEFAULT`, если после
      удаления никто не читает), doctor-WARN про legacy-вольюмы, `podman
      volume rm` из `cmd_uninstall`. Ни одного вызова удалённых имён не остаётся
      (grep = 0).
- [ ] 2. Мёртвое удалено: write-only `BIND` в `cmd_bench`; `retries` из
      `tpl/python/watch_stats.py` — одно из двух (печать в `cmd_watch` только
      при ≠0 **или** удаление поля из python-вывода и из reader'а), решение
      architect'а + обоснование фиксируются в Design и здесь же отметкой.
- [ ] 3. `tpl/env/env.tpl`: строка `COMPOSE_FILE=` убрана (потребителя нет:
      podman-compose её не читает — задокументированная грабля; вводит юзера в
      заблуждение). Осознанное изменение генерируемого `.env`: golden-файл
      обновляется, diff печатается в dev-report.
- [ ] 4. Репозиторный дубль `benchmarks/prompts/` удалён (канон фикстуры —
      `tpl/bench/`, md5-гейт `253c7ac50857fe6d0e10fb0d2c5e35c0` остаётся на
      ней); механизм prompts-маунта (`compose.local.yml.tpl`) НЕ трогать.
      README/AGENTS-секции — без ссылки на удалённый путь.
- [ ] 5. Один канал форса RAM-гейта: флаг `--force` — канон; env-синоним
      (`HFCTL_FORCE`) остаётся единственным env-каналом и документируется в
      README; второй теневой (`FORCE_GATE` как независимый пользовательский
      вход) устраняется (внутренний механик-флаг либо убирается вовсе, либо
      становится чисто внутренним — решает architect; вовне — один смысл).
- [ ] 6. Дубли сведены к одной реализации:
      (а) предикат роута — общий helper, из которого питаются и `check_route`,
      и `bench_route`; тексты вывода `check_route` не меняются; критерии
      больше не расходятся (было: bench — бинарный grep `fn-lanes staged`,
      check — полный шаблон + refused-греп + /health);
      (б) `cmd_off` переиспользует остановку `cmd_down` (маркер
      `.hfctl-stopped` + stop — одна реализация).
- [ ] 7. Швы:
      (а) `cfgset` (`lib/engine.sh`) возвращает rc и не глотит отказ движка
      (`|| true` снят); `apply_profile` при отказе ключа — `warn` с хвостом
      stderr и продолжает (не умирает — частичное применение лучше смерти),
      итоговый rc функции отражает факт отказа;
      (б) `cmd_boot`: `--force-recreate` выполняется ВНУТРИ удерживаемого
      flock (гонка снята);
      (в) `cur_model` — недостижимый fallback удалён;
      (г) `keep` в `cmd_uninstall` — `local`;
      (д) `usage()` — извлечение справки по маркерам (awk/sed по метке), без
      жёстких номеров строк; вывод совпадает с текущим golden.
- [ ] 8. Регресс зелёный: `bash -n` по всем 12 файлам; shellcheck — новый
      базлайн-мультимножество после удалений зафиксирован в dev-report
      (новых кодов нет; уменьшение мультимножества допустимо и объясняется);
      golden-file parity (матрица этапа 8) — байт-в-байт, кроме `.env`
      (`COMPOSE_FILE`); CLI-parity (`cli_parity.sh`) — идентично, кроме
      согласованных изменений; `install_sandbox.sh` на свежем клоне — зелёный;
      `pure_funcs.sh`, `bench_py_parity.sh`, `ttft_test.sh` — зелёные
      (носители: `hflab/.local-analysis/task9-exp/test/`).
- [ ] 9. Документация контрактов: `spec/hfctl.md` — addendum (cfgset-rc,
      общий route-helper, `.env` без `COMPOSE_FILE`, форс-канал), README —
      `--force` + env-синоним и отсутствие `COMPOSE_FILE`; `spec/plan.md` +
      `spec/state.md` синхронно (статусные коммиты).

Внешние (реальные машины — только после предупреждения пользователя и его GO;
EXP-носители в `hflab/.local-analysis/task9-exp/`):

- [ ] 10. прод-машина (60 GiB): update деревом → `use` туда/обратно → `off`/`on` → `doctor`
      (WARN про legacy-вольюмы отсутствует) → smoke → **ребут → сам-подъём**
      ( менялся `cmd_boot` — boot-приёмка обязательна) → healthy + smoke, итог
      `27b-single`.
- [ ] 11. вторая машина (128 GB): update деревом без остановки → `doctor` → smoke →
      `flash-multi` healthy + `fn-lanes staged` в логе; legacy-вольюмов в
      `podman volume ls` нет.
- [ ] 12. hflab: `AGENTS.md` (hfctl-секция: переходного кода нет; `.env` без
      `COMPOSE_FILE`; форс-канал один; md5 диспетчера) + `STATE.md`; hfctl
      `spec/state.md` — «этап 9 принят».

### Спецификация (ссылки)

- `spec/hfctl.md` — UX-спецификация: команды (`install/use/off/down`, `doctor`,
  `watch`, `bench`), профили и RAM-гейты, вывод `check_route`.
- `spec/plan.md` — «Этап 8» (закрыт: дерево + дистрибуция git clone;
  golden/CLI-parity харнесы) и «Этап 9» (этот этап, DoD-зеркало).
- `AGENTS.md` hfctl — правила 1 (state.md в коммите), 3 (recreate → health →
  smoke), 4 (гейты до скачивания, отказ с цифрами), 5 (обновление только через
  install.sh/use), 6 (приёмка = полный цикл на машине), 7 (в репо нет IP/хостов/
  логов).
- `hflab/AGENTS.md` — разделы «Хост-профиль прод-машина (60 GiB)» / «вторая машина (128 GB)»
  (гостевые машины, ssh-паттерн, грабли: podman-compose не читает
  `COMPOSE_FILE`, nумерация /dev/dri, limits.d).
- `hflab/.local-analysis/hfctl-audit-recon.md` — факт-база этапа (цитаты
  файл:строка). Рекон — кэш дерева на HEAD `336cd1f`, не источник истины:
  потребитель сверяет цитаты по коду.

### Ограничения и известные грабли

- Поведение CLI сохраняется; осознанные отличия — только перечисленные в DoD
  (иначе FAIL review'ы).
- Все функции дерева размечены docblock'ами + `# @param`-нотацией
  (скилл `bash-type-annotations`, house-style: `# @` с пробелом, разделитель
  секций — строка `#`, три секции всегда, хвостовые `#` выровнены по самому
  длинному полю **в символах**, `\w`/`\d`, типов `bool`/`int`/`never` нет).
  Любая новая/изменённая функция обязана остаться в этом формате; удалённая —
  забирает свой docblock.
- `env_val` всегда возвращает 0 (`|| true`) — на этом держится часть вызовов;
  менять его сигнатуру/rc в этом этапе НЕЛЬЗЯ (иначе «чиним» не то).
- `set -euo pipefail` + `VAR=$(grep …)` без совпадения молча убивает скрипт —
  при удалении веток не оставлять «висячих» присваиваний.
- Golden-файлы и харнесы этапа 8: `hflab/.local-analysis/task9-exp/test/`
  (копия живых `/tmp/hfctl-stage8/test/`). `usage_new_golden.txt` — текущий
  golden вывода usage (DoD 7д сверяется с ним, вывод не меняется).
- Sandbox: `$S=/tmp/opencode/hfctl-stage9`, env-переопределения `HOME`,
  `HFCTL_DIR`, `HFCTL_BIN_DIR` уже есть в коде — новых не нужно.
- В hfctl-репо: 0 IP/имён хостов/ключей/логов машин (правило 7) — артифакты
  приёмки живут в hflab.
- Коммит-план: один коммит на DoD-пункт (1–7) + статусный коммит в конце;
  `spec/state.md` обновляется в том же коммите, что меняет статус (правило 1).
- Машины в проде: FAEX1 крутит `flash-multi` (4 lanes), evo — `27b-single`.
  Никаких машинных шагов без GO; read-only ssh разрешён.

## Design (architect)

Design: architect. Дата 2026-11-11, HEAD кода `336cd1f`, HEAD репо `638df18`.
Рекон `hflab/.local-analysis/hfctl-audit-recon.md` сверян по живому коду на
этой сессии; расхождения — в конце раздела «Сверка рекона с кодом».

### Scope / out-of-scope

In: DoD 1–9 (код + документы hfctl), подготовка харнесов (baseline-снапшот).
Out (в backlog, НЕ в этот этап): алиасы `mode|up|down|autostart|noautostart`
(публично не описаны, но живые скрытые алиасы — адресат есть), алиасы
`single|slots|mq6|…` в resolve_profile, бенч-кластер `ar-baseline`-заглушка
и `--fresh` (recreate в bench — заявленное поведение), SLOTS-интерполяция
«at source» в profiles.sh:10 (latent, задокументирован реконом),
27b-slots-ветки (публичный выбор), prompts-маунт-механизм
(stack_files.sh:158 + `compose.local.yml.tpl`), движковые grep-паттерны
(6 швов — принятое решение продукта), hflab-репозиторий (кроме DoD 12).

### 0 · Порядок работы и baseline (до первого кодового коммита)

1. `$S9=/tmp/opencode/hfctl-stage9`; `$S9/tree` = свежая копия репо на
   `336cd1f` (git worktree/archive — без мусора).
2. **Baseline-снапшот** `$S9/baseline/`:
   - `shellcheck hfctl install.sh lib/*.sh > $S9/baseline/sc_before.txt`
     (rc+мультимножество `SC[0-9]+` — фиксация);
   - golden-генерация post-stage-8 (харнес `golden_stack.sh`, тег `new`,
     дерево `$S9/tree`) → `$S9/baseline/golden/` (compose×4, .env×4,
     юниты×3) — НОВАЯ точка сравнения вместо old-vs-new этапа 8;
   - CLI-снимки (`cli_parity.sh`-набор команд против `$S9/tree/hfctl`) →
     `$S9/baseline/cli/`; вывод `usage` = `usage_new_golden.txt`
     (проверено: байт-в-байт = `hfctl` строки 2–20);
   - fixture-логи для route-тестов (см. §6) — тексты staged/refused/spec.
3. Далее каждый коммит — на `$S9/tree`-копии после коммита (свежий checkout).

### 1 · DoD 1 — удаление переходного (точные адресаты и порядок)

Порядок: сначала CALLER'ы, затем функции (иначе grep-гейт `=0` не сходится),
затем «висячие» ссылки в docblock'ах. Каждая удалённая функция забирает свой
docblock (house-style: удалённая — без следов).

| # | Файл:строки (HEAD) | Что | Примечание |
|---|---|---|---|
| 1.1 | `lib/commands.sh:57–68` | v1-`.env` ветка cmd_install (весь `if` с комментарием :57) | единственный писатель `MODEL_DEFAULT`; PORT/BIND/MODELS_BASE из старого .env в этой ветке больше не восстанавливаются — адресата нет (все живые .env с HFCTL_PROFILE) |
| 1.2 | `lib/commands.sh:79–80` | implicit-глобал `MODEL_DEFAULT` | после 1.1 читатели только здесь и `:175–176` → заменить в cmd_install на `local model` (`model="${HFCTL_MODEL:-$(profile_field "$prof" 1)}"`; `write_env "$prof" "$model"`); в cmd_use `:175–176` — тоже `local model` (локал уже в `local`-строке не объявлен — объявить). Глобал `MODEL_DEFAULT` исчезает (grep=0) |
| 1.3 | `lib/commands.sh:73`, `:156`, `:556` | вызовы `migrate_models` | `set_models_dir` после них остаётся (mkdir сета + маунт) |
| 1.4 | `lib/commands.sh:76`, `:173` | вызовы `migrate_state "$prof"` | |
| 1.5 | `lib/state.sh:9–55` | docblock+`state_dir`, docblock+`migrate_state` | последние потребители `state_dir` — log-строки `:48,:53` самой миграции; в `state.sh` остаются `model_set`, `set_models_dir` (+их docblock'и, шапка-комментарий сетов :57–58) |
| 1.6 | `lib/state.sh:88–113` | docblock+`migrate_models` | |
| 1.7 | `lib/commands.sh:464–466` | doctor-WARN про legacy-вольюмы (`if podman volume exists …` целиком) | |
| 1.8 | `lib/commands.sh:613` | `podman volume rm hipfire_hipfire-config …` | + строка `:605` echo «+ legacy-вольюмы,» → переписать на «state-каталоги … + юниты…» (текст uninstall-подтверждения, вне cli_parity-набора; осознанное изменение вывода — зафиксировать в dev-report) |
| 1.9 | docblock-хвосты | `commands.sh:5–7,10–13,29–36` (фазы «миграции»), `:112–135` (cmd_use), `:536` (cmd_pull), `stack_files.sh:124–125` («после migrate_state и set_models_dir» → «после set_models_dir») | ни один живой docblock не должен ссылаться на удалённые функции |

Гейт коммита: `grep -rn 'migrate_state\|migrate_models\|state_dir\|MODEL_DEFAULT\|hipfire_hipfire-config' hfctl install.sh lib/ tpl/` = 0;
`bash -n` ×12; shellcheck (коды только уменьшаться); golden-снимки — идентичны
baseline (миграции не генерируют файлов); `cli_parity` — идентично.

### 2 · DoD 2 — мёртвое

- **`BIND` в `cmd_bench`** (`lib/bench.sh:543`): удалить строку присваивания
  (`v=$(env_val HIPFIRE_BIND); …` — `v` остаётся, нужен для PORT-строки выше).
  Внутри bench `BIND` не читается (сверено: только `stack_files.sh:201`
  write_env + `cmd_install --bind` + итоговая строка install). SC2034-запись
  bench.sh:543 из базлайна уходит.
- **`retries` — решение architect'а: ПЕЧАТЬ в `cmd_watch` при ≠0** (не
  удаление поля). Обоснование: (а) данные уже в `/stats` и уже извлекаются —
  удалению сопоставима по диффу, но теряет единственную видимость
  transient-ретраев движка, которые нигде больше не видны (`/metrics` их не
  отдаёт); (б) формат повторяет существующий «ошибки»-шейдер — риск вывода
  минимален. Механика: в `tpl/python/watch_stats.py:5` поле остаётся; в
  `cmd_watch` после :373 (`ошибки`) добавить
  `if isint "$retries" && [ "$retries" -ne 0 ]; then line+=" │ ретраи: $retries"; fi`
  — строка срабатывает и на `"-"`-пропуске: `isint("-") = 1` → молчит.
  Локал `retries`, инициализация `retries="-"` и `read`-поле :350 остаются.
  Осознанное изменение вывода watch — зафиксировать в dev-report и
  spec-addendum (§9 ниже).

### 3 · DoD 3 — `.env` без `COMPOSE_FILE`

`tpl/env/env.tpl:11` — удалить строку. Иных правок шаблона нет (`render_tpl`
хвостовой `\n` — без изменений). Golden: `$S9/baseline/golden/**/.env` vs
post → diff ровно `−COMPOSE_FILE=compose.yml:compose.halo.yml:compose.local.yml`
(×4 комбинации), печатать в dev-report. Комментарий `stack.sh:11–14` остаётся
(он про `-f`-канал, он правда); `task-8`-тексты не переписываем (история).

### 4 · DoD 4 — репо-дубль фикстуры

- `git rm benchmarks/prompts/merge_sort_thinking_off.txt` (каталог пустеет).
- `lib/bench.sh:558–560` комментарий: «shipped-копия
  benchmarks/prompts/… (в tpl/bench; …)» → «канон фикстуры — tpl/bench/…»;
  md5-гейт `BENCH_FIXTURE_MD5` (:10, :562–564) НЕ трогать.
- `AGENTS.md:20` (hfctl) — буллет про `benchmarks/prompts/` убрать/переписать
  на `tpl/bench/`.
- Механизм prompts-маунта (`stack_files.sh:158`, `compose.local.yml.tpl`) —
  не трогать (живёт по наличию каталога в стеке).

**Влияние вне репо hfctl** (сверено grep'ом hflab; hflab-скрипты НЕ меняем):
- `hflab/benchmarks/prompts/merge_sort_thinking_off.txt` — своя копия,
  md5 `253c7ac5…` совпадает (проверено md5sum) — адресат фикстуры hflab
  живёт в hflab, удаление из hfctl безвредно;
- `hflab/scripts/deploy_hipfire.sh:31` и `hflab/scripts/remote/_config_prod.sh:36`
  ссылаются на каталог в hflab-стеке на хосте (не в hfctl-репо) — без изменений;
- `hflab/AGENTS.md:105,221` и `hflab/э2-bench-spec.md:15` — про hflab-копию —
  без изменений (в hfctl-секции hflab AGENTS дописать при DoD 12, что канон —
  `tpl/bench/`);
- харнес `task9-exp/test/pure_funcs.sh:71` (`md5sum benchmarks/prompts/…`) —
  требует правки харнеса (см. Test strategy), не кода.

### 5 · DoD 5 — один канал форса RAM-гейта

**Решение: `FORCE_GATE` удаляется вовсе** (не «внутренний механик»): после
слияния каналов это избыточный глобал-дубль, а `--force` — просто частный
случай env-канала. Канон вовне:
- флаг `--force` (install/use) — документированный вход;
- env `HFCTL_FORCE=1` — единственный env-синоним, документируется в README.

Механика (кто что читает после правки):
- `lib/commands.sh:70` → `[ "${force:-0}" = 1 ] && HFCTL_FORCE=1` (локал
  `force` парсера остаётся; env-глобал перезаписывается в процессе —
  `HFCTL_FORCE` и так `${HFCTL_FORCE:-}`-читающий);
- `lib/commands.sh:154` → аналогично `[ "${force:-0}" = 1 ] && HFCTL_FORCE=1`;
- `lib/profiles.sh:109` → `if [ "${HFCTL_FORCE:-}" = 1 ]; then` (одна
  проверка вместо двух; текст warn :111 не меняется);
- docblock'и: `commands.sh:32,131`, `profiles.sh:91` — «`--force` или
  `HFCTL_FORCE=1` — обход гейта»;
- README: раздел команд install/use — `--force` + `HFCTL_FORCE=1`
  (обход RAM-гейта с warn, движок может отказать в загрузке);
- сопутствующий шов того же смысла (из рекона §5, попадает в этот же коммит):
  die-строка `commands.sh:54` добавить `--force` в список флагов
  (парсер :52 его принимает — рассинхрон help/факт).

Гейт: `grep -rn FORCE_GATE hfctl lib/ tpl/ README.md spec/hfctl.md` = 0;
sandbox: на машине-разработке пул < 80 GiB → `use flash-multi` отказывает
со списком профилей; `HFCTL_FORCE=1 hfctl use flash-multi` и
`hfctl use flash-multi --force` — оба дают один и тот же warn и идут дальше
(до префлайта, который в sandbox и так die — фиксировать rc/text).

### 6 · DoD 6а — общий предикат роута (`route_snapshot`, lib/health.sh)

Критерии живут в ОДНОМ helper'е; тексты `check_route` не меняются; формат
вывода `bench_route` (5 enum-строк) сохраняется, т.к. он попадает в артефакт
bench (`B_ROUTE` → `bench_report.py` artifact/compare) и любое изменение
ломает `--compare` совместимость артефактов.

Новая функция в `lib/health.sh` (модуль «фактический роут»; bench.sh
source'ится после health.sh — зависимость легальна):

```
route_snapshot() {   # без параметров; stdout нет
  ROUTE_LOG=$(podman logs --tail 400 "$CONTAINER" 2>&1 || true)
  ROUTE_STAGED=$(printf '%s' "$ROUTE_LOG" \
    | grep -oE "fn-lanes staged: topology=[a-z]+ lanes=[0-9]+[^\"]*spec=[a-z0-9]+" \
    | tail -1) || true
  ROUTE_REFUSED=$(printf '%s' "$ROUTE_LOG" \
    | grep -oE "qwen4 lanes refused:[^-—]*" | tail -1) || true
  ROUTE_SPEC=$(printf '%s' "$ROUTE_LOG" \
    | grep -oE "spec: [a-z0-9 ]+" | tail -1 | head -c 60) || true
  ROUTE_HEALTH=$(curl -fsS -m 5 "http://127.0.0.1:$PORT/health" 2>/dev/null \
    | python3 "$TPL_DIR/python/health_mode.py" 2>/dev/null || echo '?')
  return 0
}
```

- `@returns integer` всегда 0; `@globals ROUTE_LOG ROUTE_STAGED ROUTE_REFUSED
  ROUTE_SPEC ROUTE_HEALTH` (строки, '' = нет совпадения; HEALTH — '…' или
  '?'); grep-паттерны — дословно текущие health.sh:99/102/103/116/118
  (шесть движковых швов — принятое решение, не «чинить»). `|| true`
  обязателен под set -e+pipefail (комментарий health.sh:100–101 переезжает
  в docblock helper'а).
- `check_route` после правки: `route_snapshot`, затем case по `$prof` читает
  `ROUTE_STAGED/ROUTE_REFUSED`; ветка `27b-slots` печатает `"$ROUTE_HEALTH"`;
  singleton-ветка — `"$ROUTE_SPEC"`. Все stdout/stderr-строки — байт-в-байт
  текущие.
- `bench_route` (bench.sh:58–69) после правки: `route_snapshot`; далее
  `flash-multi) [ -n "$ROUTE_STAGED" ] && echo lanes || echo serial-fallback`;
  `27b-slots) echo multi-slot` (литерал НЕ меняется — см. ниже);
  `*) case "$ROUTE_SPEC" in 'dflash '*) echo singleton-dflash ;;
  *) echo singleton-serial ;; esac`.
  Формат-совпадение с текущим выводом — с точностью до совпадения самого
  движкового текста (`spec: dflash …` против прежнегоAnywhere-grep): теперь
  обе команды смотрят на ПОСЛЕДНЕЕ совпадение — это и есть требуемая
  конвергенция критериев (кто последний сказал, тот и роут).
- Расхождение «staged vs refused vs /health» обрабатывается как сейчас и в
  том же приоритете (check_route: staged → refused → «данных нет»;
  bench: `-n staged` → serial-fallback). Новый расклад лишь устраняет
  рассогласование greps (прежде bench — подстрока «fn-lanes staged» где
  угодно в 400 строках, check — полный шаблон tail -1).
- Почему `27b-slots` в bench остаётся литералом: `multi-slot` — константа
  артефакта, а `/health`-режим в bench печатается отдельной строкой
  (`bench_slots`), и подстановка `"$ROUTE_HEALTH"` изменила бы
  `B_ROUTE`-значение/вывод. Формулировку в docblock bench_route fixing:
  «для 27b-slots роут статический (константа артефакта); live-режим —
  bench_slots по /health» (как и сейчас).

### 7 · DoD 6б — одна реализация остановки

Новая функция в `lib/autostart.sh` (рядом с cmd_down/cmd_off):

```
stop_with_marker() { mkdir -p "$STACK_DIR"; touch "$STOP_MARKER"; \
  compose stop 2>&1 | tail -2; }
```

- `cmd_down` = `stop_with_marker` + прежняя echo-итоговая строка (вывод и rc
  не меняются; маркер ДО stop — семантика cmd_down, «вотчдог оглушён даже
  при сбое остановки» — попадает в cmd_off бесплатно и строго безопаснее:
  прежде при сбое `compose stop` в cmd_off маркер не ставился вовсе).
- `cmd_off` = `stop_with_marker >/dev/null 2>&1 || true` + остальное тело
  без изменений (disable юнитов, rm юнитов, daemon-reload, linger, две
  echo-строки). Glushenie — обязанность вызывающего (`cmd_down` наружу
  печатает и терпит rc по set -e; `cmd_off` — заглушает, как и сейчас).
  Порядок внутри `stop_with_marker` (touch ДО stop) vs старый cmd_off
  (stop→touch): осознанное выравнивание на cmd_down-семантику, зафиксировать
  в dev-report. Docblock'и cmd_down/cmd_off обновить (ссылка на helper).

### 8 · DoD 7 — швы

(а) **cfgset** (`lib/engine.sh:22–24`): снять `|| true`;
`tail -1` остаётся (stdout = хвост вывода движка). `|| true` на подкоманде
НЕ нужен: `set -e` в диспетчере не убивает процесс внутри `if`-контекста, а
apply_profile вызывает через `if`. `@returns integer` = rc конвейера
(pipefail: любой отказ podman/config set nonzero; хвост stderr уже слит в
stdout через `2>&1` — он и печатается).
**apply_profile**: `local failed=""`; каждый ключ через
`if ! cfgset <ключ> <val>; then failed="$failed <ключ>"; fi` (24 вызова —
одинаковая форма; допустимо компактно построчно). После `case`:
```
if [ -n "$failed" ]; then
  warn "cfgset: отказ ключей:$failed — движок мог применить конфиг частично (продолжаем)"
  return 1
fi
```
Частичное применение лучше смерти. Вызывающие (`commands.sh:85,178`) —
`apply_profile "$prof" || true` (иначе set -e убьёт install/use на отказе
ключа — прямо противоречит «warn'ит и продолжает»; итог виден в warn).
rc функции теперь содержательный — отразить в docblock'ах (`@returns`).

(б) **cmd_boot** (`lib/autostart.sh:231`):
```
[ $((i % 3)) -eq 0 ] && ( flock -n 9 || true; \
  compose up -d --force-recreate 2>&1 | tail -1 ) 9>"$STACK_DIR/.hfctl.lock" || true
```
→
```
[ $((i % 3)) -eq 0 ] && ( flock -n 9 && compose up -d --force-recreate 2>&1 | tail -1 \
  || true ) 9>"$STACK_DIR/.hfctl.lock" || true
```
`flock -n 9 && compose …` — при занятом lock'е recreate НЕ выполняется
(прежде выполнялся всё равно — гонка HEAD-коммита 336cd1f); `|| true`
внутри субшелла сохраняет «пропуск — не ошибка»; внешний `|| true` — как
было. Точная форма фиксируется здесь; приёмка — обязательный EXP-ребут evo
(DoD 10).

(в) **cur_model** (`lib/stack.sh:91`): `cur_model() { env_val HIPFIRE_MODEL; }`
— недостижимый `|| echo "$(profile_field …)"` удалён; docblock :74–90
переписать: '' при отсутствии ключа (как и было по факту — fallback никогда
не выполнялся, поведение не меняется); `@returns` — всегда 0 (env_val).

(г) **keep** (`lib/commands.sh:616`): в `local purge_models=0 purge_image=0`
(:595) добавить `keep`; удалить пояснительный «ГЛОБАЛ (local объявить
забыто)» из docblock :586–587 → «локал».

(д) **usage()** (`hfctl:184–186`): в шапке — маркеры. Строка 1 shebang,
затем `# === USAGE-BEGIN ===`, текст, `# === USAGE-END ===` (маркеры
обрамляют текущие строки 2–20 как сейчас: BEGIN вставляется НЕМЕДЛЕННО
после строки 2? — НЕТ: текущая печать = строки 2–20 inclusive, т.е. весь
комментарий от «hfctl — деплой…» до «bench [full] …». Маркеры ставятся
ВНЕ текста: BEGIN — новой строкой перед текущей :2? Это добавило бы строку в
файл, но НЕ в вывод (sed по маркерам печатает между ними). Форма:
```
# === USAGE-BEGIN ===
# hfctl — деплой …            (бывш. :2)
…
#   bench [full] …            (бывш. :20)
# === USAGE-END ===
set -euo pipefail
```
`usage() { sed -n '/# === USAGE-BEGIN ===/,/# === USAGE-END ===/p' "$0" \
  | sed '1d;$d;s/^# \{0,1\}//'; }` — вывод байт-в-байт =
`usage_new_golden.txt` (гейт харнесом). Docblock usage :170–183:
«диапазон — маркеры, не номера строк» (грабля-предупреждение снять).
`cli_parity.sh`-ветка usage правится под «new vs golden = пусто» (см. Test
strategy).

### 9 · Артефакты и документация (DoD 3/4/9)

- `tpl/env/env.tpl` — §3; golden-снапшот baseline → post-diff в dev-report.
- `spec/hfctl.md` — addendum-секция «13 · Контракты этапа 9 (2026-11-11)»:
  cfgset rc + apply_profile «warn+продолжить+rc»; `route_snapshot` — единый
  предикат роута (тексты check_route неизменны, bench-enum сохранён);
  `.env` без `COMPOSE_FILE`; форс-гейт: `--force` + `HFCTL_FORCE` (единственный
  env-канал, FORCE_GATE удалён); watch печатает «ретраи» при ≠0;
  остановка — `stop_with_marker` (cmd_off = cmd_down-механика + снятие
  юнитов/linger).
- `README.md` — `--force`/`HFCTL_FORCE` у install/use; примечание, что `.env`
  генерируется без `COMPOSE_FILE` (podman-compose читает `-f`-тройку —
  hfctl передаёт её сам); фикстура bench — `tpl/bench/`.
- `spec/plan.md` «Этап 9» — чекбоксы по мере закрытия; `spec/state.md` — в
  каждом коммите, меняющем статус (правило 1).
- hflab (DoD 12, НЕ hfctl): AGENTS hfctl-секция + STATE.md — делает
  оркестратор после приёмки EXP (переходного нет; .env без COMPOSE_FILE;
  форс-канал один; новый md5 диспетчера).

### 10 · Коммит-план (один коммит на DoD 1–7 + статусный)

| Коммит | DoD | Содержимое | Внутренние проверки в этом коммите |
|---|---|---|---|
| C1 | 1 | §1 целиком | grep-гейт=0; `bash -n` ×12; shellcheck ⊆ baseline; golden-снимки = baseline; cli_parity = baseline |
| C2 | 2 | §2 | watch-проверка §Test; shellcheck: SC2034 BIND(bench) ушёл; golden/cli = baseline |
| C3 | 3 | env.tpl | golden .env diff = ровно −COMPOSE_FILE; `grep COMPOSE_FILE tpl/ lib/` = 0 |
| C4 | 4 | удаление дубля + bench.sh:558 + AGENTS.md:20 | md5 tpl/bench = 253c7ac5…; ls benchmarks = пусто; grep по репо на путь = 0 (кроме spec-истории) |
| C5 | 5 | §5 + die-строка :54 | grep FORCE_GATE=0; sandbox-проверка warn-текста (оба канала идентичны) |
| C6 | 6 | §6+§7 | route-таблица на fixture-логах (5 значений); тексты check_route = baseline-снапшот; bench-enum = старый вывод; `off`/`down` sandbox (stub compose) |
| C7 | 7 | §8 (а–д) | cfgset-fail sandbox (stub rc=1 → warn+rc1+продолжение); usage vs golden = пусто; cur_model sandbox; shellcheck `keep` (SC2154/2034 дельта) |
| C8 | 8+9 | docs+spec addendum'ы (если не разложены по C1–C7; addendum hfctl.md — здесь) | полный регресс: baseline-vs-post (shellcheck, golden×, cli, pure_funcs, bench_py, ttft, install_sandbox) |
| C9 | статус | `spec/state.md` (+`spec/plan.md` чекбоксы) — «этап 9 в приёмке» → после EXP «принят» | правило 1 |

Docblock'и затронутых функций правятся В ТОМ ЖЕ коммите, что правит функцию
(house-style обязателен для всех новых: `route_snapshot`,
`stop_with_marker`; изменённых: `cfgset`, `apply_profile`, `cmd_boot`,
`cur_model`, `cmd_uninstall`, `usage`, `cmd_down`, `cmd_off`, `cmd_install`,
`cmd_use`, `cmd_pull`, `cmd_watch`, `check_route`, `bench_route`).

### 11 · Риски и rollback

- Риск: удаление v1-ветки ломает гипотетическую v1-установку (иррелевантно за неимением адресатов:
  адресатов ноль, закрыто предпосылками 0а/0б). Откат — revert коммита C1.
- Риск: `flock &&` форма cmd_boot при занятом lock'е молча пропускает
  recreate (штатно: вотчдог/boot конкурентны, следующий цикл догонит) —
  покрывается EXP-ребутом evo.
- Риск: `apply_profile` перестал быть «всегда 0» → любой вызов без `|| true`
  убьёт install/use. Единственные вызовы — commands.sh:85,178 (оба правятся);
  grep-гейт `apply_profile` = только они + docblock'и.
- Риск: watch-«ретраи» — новое слово в выводе; вне cli_parity-набора;
  покрывается sandbox-проверкой.
- Каждый коммит independent-revert'ен; статусный C9 — последний.

### 12 · Сверка рекона с кодом (расхождения/уточнения)

Цитаты `файл:строка` рекона сверены на `336cd1f` — в целом точны
(state.sh:23/42/101, commands.sh:57–68/70/154/464–466/611–613, health.sh:97–120,
bench.sh:58–69/543, engine.sh:22–23, autostart.sh:231, stack.sh:91,
hfctl:184–186 — сходятся). Уточнения:
1. Рекон описывает расхождение check/bench как «полный шаблон vs бинарный
   grep»; фактическая механика шире: bench-grep ищет подстроку по всему
   логу (не tail -1), а для 27b-slots bench НЕ читает /health вовсе —
   поэтому конвергенция обязана оставить bench-литерал `multi-slot`
   (константа артефакта), иначе сломается `--compare` совместимость (§6).
2. Рекон §2.7/§5 «фикстура в репо — канон»: hflab держит СОЮ копию с тем же
   md5 (проверено md5sum) — удаление из hfctl-репо безопасно, hflab не
   требует правок (§4).
3. Рекон §3 «retries … не печатается» — верно; уточнено: `isint("-")=1`,
   поэтому печать при ≠0 молчит на отсутствующем поле (§2).
4. `usage_new_golden.txt` байт-в-байт = hfctl:2–20 (проверено sed-выделкой) —
   DoD 7д проверяется против него без изменения текста.
5. SC2034-мультимножество базлайна (recon §3) после C1/C2 уменьшается на
   `bench.sh BIND`; `state.sh`-глобалов в списке нет — расхождений нет.

## Test strategy

Носители: харнесы этапа 8 `hflab/.local-analysis/task9-exp/test/`
(копии живых `$S/test/*.sh`, `$S=/tmp/hfctl-stage8`) + НОВЫЕ проверки этапа 9
в `$S9/test9/`. Отправная точка — baseline-снапшот §0 Design (сравнение
post-vs-pre, а не old-vs-new этапа 8: «old» теперь = HEAD `336cd1f`).

**Правки харнесов (до начала кода, фиксируются отдельным snapshot-ом в
dev-report):**
- `pure_funcs.sh:71` — убрать `md5sum benchmarks/prompts/…` (путь удалён в
  C4), оставить `tpl/bench/…` = `253c7ac5…`; остальное без изменений
  (`bench_route` в набор не входил — новая проверка ниже).
- `cli_parity.sh:49–65` — usage-ветка: вместо old-vs-new diff'а «4+4 строки»
  — «вывод `usage` = `usage_new_golden.txt` байт-в-байт» (`cmp`); прочие
  команды — как были (identity vs baseline-снапшот `$S9/baseline/cli`).
- `golden_stack.sh` — параметризация тега: `pre` (checkout 336cd1f) и
  `post` (HEAD этапа); сравнение post-vs-pre c ожиданием: единственное
  отличие — `.env` ×4 (`−COMPOSE_FILE`-строка).
- `install_sandbox.sh`, `bench_py_parity.sh`, `ttft_test.sh`, `fake_sse.py` —
  без правок (не зависят от удалённого).

**Shellcheck-базлайн**: `sc_before.txt` (до кода) и `sc_after.txt` (после
C7) — `grep -oE 'SC[0-9]+' | sort | uniq -c`; новые коды = FAIL; уменьшение
разрешено и объясняется в dev-report (ожидаемо: −SC2034 bench.sh BIND;
локализация keep/retries не добавляет кодов). Мультимножество post
фиксируется в dev-report как новый базлайн этапа 9.

| DoD | Внутренняя проверка (команда) | Внешнее (что доказывает → hflab-артефакт) |
|---|---|---|
| 1 переходное | grep-гейт `migrate_state\|migrate_models\|state_dir\|MODEL_DEFAULT\|hipfire_hipfire-config` по hfctl/install.sh/lib/tpl = 0; `bash -n` ×12; shellcheck ⊆ before; golden post-vs-pre идентичны (миграции не генерируют файлов); cli_parity post = baseline | EXP-004 (evo): `doctor` — warn-строка про legacy-вольюмы отсутствует; EXP-005 (FAEX1): `podman volume ls | grep -i hipfire` пусто + `doctor` чист (адресатов удалённого кода нет натурально) |
| 2 мёртвое | `grep -n 'env_val HIPFIRE_BIND' lib/bench.sh` = 0; watch: stub `curl` (PATH) печатает `{"queue_depth":0,"requests_served":1,"recent_tok_s":5,"retries_attempted":2}` / …`:0}` / без поля → `timeout 3 hfctl watch --interval 1`: в первом — `ретраи: 2`, во втором/третьем — без слова; shellcheck: SC2034-bind ушёл | — (на машине косвенно: EXP-004 `watch`-тик в простое не меняется) |
| 3 env.tpl | `grep -c COMPOSE_FILE tpl/env/env.tpl` = 0; `golden_stack.sh pre/post` — diff `.env` ×4 = ровно удалённая строка; прочие golden-файлы cmp-identical | EXP-004/005: после update `grep COMPOSE_FILE ~/hipfire/.env` пусто; стек здоров (клиентская пара не зависел — подтверждает отсутствие потребителя) |
| 4 фикстура | `ls benchmarks 2>/dev/null` пусто; `md5sum tpl/bench/merge_sort_thinking_off.txt` = `253c7ac50857fe6d0e10fb0d2c5e35c0`; grep `benchmarks/prompts` по hfctl-репо = 0 (кроме spec-истории task-8); `grep -n LOCAL_PROMPTS tpl/compose/compose.local.yml.tpl` на месте (механизм жив) | EXP-005: `hfctl bench` quick на flash-multi — solo-code считается (фикстура из tpl/bench), md5-warn отсутствует |
| 5 форс-канал | grep `FORCE_GATE` = 0 (код+README+hfctl.md); sandbox-матрица (низкий пул dev-машины): `use flash-multi` → ERROR+exit 1; `HFCTL_FORCE=1 …` и `… --force` → идентичный warn (cmp stdout+stderr двух прогонов); die-строка install содержит `--force` | — (гейт машинный; на evo гейт и так пройден — EXP не нужен) |
| 6а route-helper | таблица на fixture-логах (`$S9/test9/route-fixtures/{staged,refused,both,none,spec-dflash,spec-none}.log`, stub `podman logs` = cat файла): `bench_route` → `lanes/serial-fallback/multi-slot/singleton-dflash/singleton-serial` (×5 enum); `check_route` ×3 профиля — stdout/stderr байт-в-байт = baseline-снапшот на тех же логах; `grep -c 'fn-lanes staged' lib/bench.sh` = 0 (greps только в health.sh) | EXP-005: flash-multi `fn-lanes staged` в логе + bench-артефакт `"route": "lanes"` (enum не поехал) |
| 6б остановка | sandbox stub-`compose`: `down` — маркер+stop+итог; `off` — то же + disable/rm/linger (stub'ы systemctl/sudo) — порядок touch→stop в обеих; rc/выводы = baseline | EXP-004: `off` → контейнер exited + вотчдог молчит; `on` → healthy (цикл обязательный) |
| 7 швы | (а) stub-`podman` rc=1 на `config set`: `apply_profile 27b-single` → warn с перечнем ключей, rc=1, все 8 cfgset-вызовов сделаны; install-путь: `apply_profile … || true` (grep :85,:178). (б) `bash -n` + review-чтение формы `flock -n 9 &&`; (в) sandbox `.env` без HIPFIRE_MODEL: `cur_model` → '' (и до, и после — идентично); (г) shellcheck-дельта по `keep` (локал); (д) `hfctl > /tmp/u` vs `usage_new_golden.txt` — cmp пусто; `grep -n '2,20p' hfctl` = 0 | EXP-004: **ребут evo → сам-подъём** (cmd_boot менялся — boot-приёмка обязательна): boot-юнит поднимает стек, healthy+smoke, в логе boot нет параллельного recreate-шторма; cfgset-rc — косвенно (после update конфиг профиля в `config.toml` = канон профиля) |
| 8 регресс | полный прогон: `bash -n` ×12; shellcheck before/after-мультимножества; golden post-vs-pre (кроме .env — осознанно); cli_parity (usage=golden, остальное = baseline); `pure_funcs.sh` (после правки :71); `install_sandbox.sh`; `bench_py_parity.sh`; `ttft_test.sh` — все зелёные | — |
| 9 документация | diff `spec/hfctl.md` (addendum 13), README (`--force`, `HFCTL_FORCE`, отсутствие COMPOSE_FILE, tpl/bench), `spec/plan.md`, `spec/state.md` — reviewer по тексту | — |
| 10 EXP evo | — | Полный цикл на прод-машина (60 GiB): update деревом → `use 27b-slots`→`use 27b-single` → `off`/`on` → `doctor` (нет warn про вольюмы) → smoke → **ребут → сам-подъём** → healthy+smoke; финал `27b-single` healthy. Доказывает: удаления не тронули живой путь, cmd_boot-правка живая, форс-канал/роут-строки не деградировали. → `hflab/.local-analysis/task9-exp/EXP-004-evo-full.txt` |
| 11 EXP FAEX1 | — | update деревом без остановки → `doctor` → smoke → flash-multi healthy + `fn-lanes staged` в логе + bench quick; `podman volume ls` без hipfire-вольюмов. Доказывает: lanes-роут пережил route-helper и удаления; legacy-адресатов нет. → `…/EXP-005-faex-light.txt` |
| 12 hflab-доки | — | AGENTS hfctl-секция + STATE.md hflab (переходного нет; .env без COMPOSE_FILE; форс-канал один; md5 диспетчера post-этапа); hfctl `spec/state.md` «этап 9 принят» |

Порядок: baseline §0 → правки харнесов → C1…C7 (каждый со своими checks) →
C8 полный регресс (tester) → reviewer → партия EXP-004/005 одной экспедицией
(предупреждение пользователя + GO обязателны: машины в проде) → C9 статус +
hflab-доки.

### Open questions

**Блокирующих вопросов пользователю нет.** Все развилки решены architect'ом и
зафиксированы в Design; переопределение пользователем допустимо до начала кода:

1. `retries` (DoD 2) — выбрана ПЕЧАТЬ при ≠0 (§2), а не удаление поля:
   данные уже извлекаются, видимость transient-ретраев бесплатна.
2. `FORCE_GATE` (DoD 5) — удалён вовсе, `--force` = `HFCTL_FORCE=1` (§5);
   альтернатива «внутренний механик-флаг» оставлена бы два имени в коде.
3. Порядок touch-маркера в `cmd_off` выравниван на `cmd_down` (маркер ДО
   stop, §7) — строго безопаснее прежнего; это незаявленное микро-отличие
   поведения cmd_off при сбое `compose stop` (раньше маркер не ставился).
4. `bench_route` для `27b-slots` остаётся литералом `multi-slot` (§6) —
   константа артефакта `--compare`; live-режим слотов и так печатается
   отдельно через `bench_slots`.

## Dev report (developer)

- Date / round: 2026-11-11, round 1. Коммиты C1–C8 на `638df18`:
  `71a24f5` (C1/DoD 1), `e73bdc7` (C2/DoD 2), `0f18526` (C3/DoD 3),
  `408a017` (C4/DoD 4), `39daa89` (C5/DoD 5), `b5f5565` (C6/DoD 6),
  `8cf7b48` (C7/DoD 7), `c7414e2` (C8/DoD 8+9). Правки architect'а в этом
  файле (Design/Test strategy) в кодовые коммиты не включались;
  `spec/state.md` не тронут (решение оркестратора).

### What was done (по DoD; file list)

- **DoD 1 (C1, `71a24f5`)** — переходное удалено: `migrate_state`/
  `migrate_models`/`state_dir` (lib/state.sh, шапка переписана: каталоги state
  создаёт podman при первом bind), v1-ветка `.env` в install + implicit-глобал
  `MODEL_DEFAULT` → локальная `model` (lib/commands.sh), doctor-WARN про
  legacy-вольюмы (lib/doctor… commands.sh), `podman volume rm` legacy из
  cmd_uninstall (текст эха «+ legacy-вольюмы» убран — осознанно). Плюс
  ставшие write-only локалы `set_port/set_bind/set_models` (читатели умерли с
  v1-веткой; behavior-neutral, amended в C1). Grep-гейт
  `migrate_state|migrate_models|state_dir|MODEL_DEFAULT|hipfire_hipfire-config`
  по hfctl/install.sh/lib/tpl = 0.
- **DoD 2 (C2, `e73bdc7`)** — write-only `BIND` в cmd_bench удалён (`v`
  остаётся для PORT-строки); `retries` — решение architect'а §2: ПЕЧАТЬ в
  cmd_watch при целом ≠0 (`if isint "$retries" && [ "$retries" -ne 0 ]`),
  tpl/python/watch_stats.py без изменений; docblock'ы обновлены.
- **DoD 3 (C3, `0f18526`)** — `tpl/env/env.tpl`: строка `COMPOSE_FILE=`
  убрана (podman-compose её не читает). Осознанное изменение генерируемого
  .env: −1 строка; diff golden post-vs-pre ×4 = ровно эта строка (см. ниже).
- **DoD 4 (C4, `408a017`)** — репо-дубль `benchmarks/prompts/` удалён
  (git-rm); канон — `tpl/bench/`, md5-гейт `BENCH_FIXTURE_MD5=253c7ac5…` на
  месте; комментарий cmd_bench и AGENTS.md обновлены; prompts-маунт-механизм
  (stack_files.sh + compose.local.yml.tpl) не тронут.
- **DoD 5 (C5, `39daa89`)** — теневой `FORCE_GATE` удалён вовсе; `--force` =
  `HFCTL_FORCE=1` (единый канал); die-строка install перечисляет `--force`;
  README обновлён.
- **DoD 6 (C6, `b5f5565`)** — (а) `route_snapshot` (lib/health.sh) — общий
  предикат роута; check_route/bench_route питаются из него, тексты check_route
  байт-в-байт прежние, enum артефакта bench сохранён (`27b-slots` остаётся
  литералом `multi-slot` — константа `--compare`); реализация singleton-кейса
  — `case "$ROUTE_SPEC" in "spec: dflash"*)` (в snippet'е Design `'dflash '*`
  не матчил бы: ROUTE_SPEC включает префикс `spec: ` — равнозначная правка,
  зафиксирована здесь как отклонение-уточнение); `grep 'fn-lanes staged'
  lib/bench.sh` = 0; (б) `stop_with_marker` (lib/autostart.sh) — одна
  реализация для cmd_down/cmd_off, маркер ДО stop в обеих.
- **DoD 7 (C7, `8cf7b48`)** — (а) `cfgset` возвращает rc конвейера (был
  `|| true`), `apply_profile` копит отказные ключи → warn+rc1 и продолжает,
  install/use вызывают через `|| true` (поведение install/use прежнее);
  (б) cmd_boot: `flock -n 9 && compose up -d --force-recreate … || true` —
  recreate внутри lock'а (гонка 336cd1f снята); (в) недостижимый fallback в
  `cur_model` удалён (`{ env_val HIPFIRE_MODEL; }`); (г) `keep` → local;
  (д) usage() извлекается по маркерам `/^# === USAGE-BEGIN ===$/,…END$/`
  (якоря по строке — строка sed сама содержит литералы маркеров), вывод
  байт-в-байт = baseline, `grep '2,20p'` = 0.
- **DoD 8+9 (C8, `c7414e2`)** — полный регресс (ниже) + документация:
  `spec/hfctl.md` addendum «§13 · Контракты этапа 9» (маркер в usage,
  route_snapshot, HFCTL_FORCE, cfgset rc, flock в boot, контракты .env /
  маркера остановки), README (путь фикстуры `tpl/bench/`, .env без
  COMPOSE_FILE; `--force` уже в C5), `spec/plan.md` — DoD 1–9 этапа 9
  отмечены (внешние 10–12 — нет).

### How it was checked internally

Песочница `$S9` ( carriers: `hflab/.local-analysis/task9-exp/`; артефакты
финального прогона — `hflab/.local-analysis/task9-exp/final/`). Все прогоны —
на дереве HEAD после `refresh_tree.sh`; хосты не трогались.

| DoD | Проверка | Результат |
|---|---|---|
| 1 | grep-гейт по hfctl/install.sh/lib/tpl | 0 совпадений |
| 1 | `bash -n` hfctl + lib/*.sh + install.sh | 12/12 ok |
| 1,8 | shellcheck before/after мультимножеством (test9/sc_multiset.sh, файл+код+переменная, без строк) | дельта ровно: −SC2034 bench.sh `BIND`, −SC2034 commands.sh `retries`, +SC2034 commands.sh `HFCTL_FORCE`, −SC2005 `cur_model` `echo "$(…)"` (мёртвый fallback удалён в DoD 7в). Новых кодов нет; HFCTL_FORCE — кросс-файльный global (пишется в commands.sh, читается в profiles.sh) — тот же класс, что 22 baseline-записи |
| 1,3 | golden_stack pre/post (4 комбинации профиль×порт/bind) | все файлы идентичны, кроме: .env — ровно −`COMPOSE_FILE=…` ×4 (`env_diff.txt`, пути pre/post — штампы песочницы); systemd-юниты — только штампы путей песочницы, после нормализации идентичны |
| 1,2,5 | test9/cli_parity.sh (usage vs golden, status/models/doctor/bench-help/unknown vs baseline) | PASS (единственная строка-дрейф в doctor — «доступно сейчас: 17→18 GiB», живой /proc dev-машины, не контракт) |
| 2 | test9/watch_retries.sh: stub-curl с retries=2 / retries=0 / без поля | PASS: «ретраи: 2» только в первом |
| 4 | md5 tpl/bench-фикстуры; grep `benchmarks/prompts` по репо; test9/pure_funcs.sh | `253c7ac50857fe6d0e10fb0d2c5e35c0`; 0 (кроме spec-истории task-8); PASS |
| 5 | test9/force_gate.sh (пул dev-машины 31 GiB < гейт 80): plain / `HFCTL_FORCE=1` / `--force` | PASS: plain rc=1 ERROR; env и flag — идентичный warn (cmp stdout+stderr), оба доходят до префлайта (die на дистрибутиве — общий путь) |
| 6а | test9/route_matrix.sh post ×6 fixture-логов vs baseline-снапшоты | 6/6 cmp идентичны (none/spec-none/spec-dflash/both/staged/refused) |
| 6б | test9/stop_matrix.sh (stub-compose: touch→stop порядок) | PASS (маркер до stop в down и off) |
| 7а | test9/cfgset_fail.sh (stub-podman rc=1 на config set) | PASS: rc=1, warn с перечнем, все 11 cfgset-вызовов сделаны |
| 7б | bash -n + чтение формы `flock -n 9 &&` | ok (живой boot-цикл — EXP-004) |
| 7д | `bash pre/hfctl` vs `bash tree/hfctl` (no-args) + unknown-cmd | usage IDENTICAL; unknown: текст+rc идентичны |
| 8 | install_sandbox.sh / bench_py_parity.sh / ttft_test.sh | PASS / PASS / PASS (ttft 162 мс, null, ERR; фикст: hardcoded stage-8 путь в fake_sse.py исправлен в копии харнеса) |

### Not checked internally (внешние приёмки, EXP из Test strategy)

- **EXP-004 (прод-машина (60 GiB)):** полный цикл update→use↔use→off/on→doctor (нет
  legacy-WARN)→smoke→**ребут → сам-подъём boot-юнитом**→healthy+smoke;
  watch-тик в простое без «ретраи». Доказывает живой путь cmd_boot,
  apply_profile-швы, отсутствия адресатов миграций.
- **EXP-005 (вторая машина (128 GB)):** update без остановки→doctor→smoke→flash-multi
  healthy + `fn-lanes staged` + bench quick (`"route": "lanes"`);
  `podman volume ls` без hipfire-вольюмов.
- На машинах не проверялось: ничего из перечисленного (нет доступа из среды
  разработки; машины в проде, GO пользователя обязателен).

### Known limitations / отклонения от Design

- `$S9` — `/tmp/hfctl-stage9` (не `/tmp/opencode/...` как в brief: каталог
  root-owned, записи нет; tmpfs 512 MB — mid-session пожёр часть baseline-файлов,
  всё переснято и продублировано в hflab-carrier `final/`).
- bench_route singleton: `case "spec: dflash"*` вместо литерала Design (эквивалент, см. DoD 6).
- `+SC2034 HFCTL_FORCE` — принят как штатный кросс-файльный global.
- State-каталоги отныне создаёт podman при первом bind (hfctl их не mkdir);
  doctor их не чинит — штатный путь подтверждён install-sandbox.
- cmd_off: маркер теперь ДО stop (строго безопаснее; микро-изменение вывода
  при сбое compose stop) — ратифицировано architect'ом (Open question 3).
- Текст эха uninstall «+ legacy-вольюмы» убран (осознанно, DoD 1).

### Out-of-scope proposals

- `hfctl install --models-dir D` — латентный no-op: сразу после разбора
  аргумента `MODELS_DIR` перезаписывается `set_models_dir` из канона профиля
  (пре-existed до этапа 9, не трогал). Если чинить — отдельной задачей с
  решением, должен ли флаг переопределять канон.

## Round 1 (2026-11-11): окно логов предиката роута (triage `impl`, внешняя приёмка EXP-005)

- Date / round: 2026-11-11, фикс-раунд 1 к DoD 6а. Дефект унаследованный (со
  старого `bench_route` на `638df18`, переехал в `route_snapshot` дословно), но
  бьёт по текущему контракту DoD 6а и по честности вывода: на долгоживущем
  контейнере строка `fn-lanes staged: …` (печатается только при загрузке
  модели) выпадает из окна `podman logs --tail 400`, и живой сервер с
  ПРИНЯТЫМИ 4 fn-lanes показывал `роут: singleton (serial)` /
  `"route": "serial-fallback"`. Коммит фикса — HEAD этого коммита (hash
  фиксирует оркестратор в history.md).

### What was done

- `lib/health.sh::route_snapshot` — предикаты читают **лог целиком потоково**
  (`podman logs "$CONTAINER" 2>&1 | grep … | tail -1`, без `--tail`), по
  полному проходу на предикат (staged/refused/spec); буфер `ROUTE_LOG` удалён
  (grep по дереву: потребителей у него не было — только внутренние грипы
  самой функции; `ROUTE_HEALTH` не тронут). Позиции staged/refused — из
  `grep -n` (префикс «NN:», снятие «${s#*:}», сравнение «${s%%:*} -lt …»):
  **свежий `refused` строкой ниже принятого `staged` обнуляет `ROUTE_STAGED`**
  (реализация «кто последний сказал в логах, тот и роут» внутри снимка);
  наоборот — lanes сохраняется. Тексты вывода `check_route` и enum
  `bench_route` — не менялись. `shortcut:`-комментарий о цене полного прохода
  (~0.4 с на 7k строк живой машины) и апгрейде (окно `--since` от старта
  контейнера / поле роута в `/health`) — в теле функции.
- Docblock'и (единственные правки комментариев): `route_snapshot` —
  «Побочные» (полный стрим, три прохода; из ПИШЕМЫХ глобалов убран
  `ROUTE_LOG`) и «Ограничения» (семантика `ROUTE_STAGED` = последнее staged-
  совпадение, ОБНУЛЁННОЕ свежим отказом ниже; механизм `grep -n`);
  `check_route` — «Ограничения»: приоритет решает снимок (staged уже снят
  свежим отказом), далее staged → refused → «данных нет»; `bench_route`
  (lib/bench.sh) — «Назначение»: flash-multi ветка читает принятый
  `ROUTE_STAGED`, а не «наличие строки».
- `spec/hfctl.md` §13 «Единый предикат роута» — контракт окна логов: полный
  стрим без `--tail` (с обоснованием), приоритет последней реплики.
- Харнес (носитель `hflab/.local-analysis/task9-exp/`): `route_matrix.sh` —
  stub podman эмулирует `--tail N` (`tail -N` фикстуры; раньше `cat` — окно не
  воспроизводилось), список фикстур +3: `staged-old.log` (7006 строк, staged
  на позиции 3553 — как на живой машине), `staged-refused.log`,
  `refused-staged.log`; копия синхронизирована в `$S9/test9/`.

### How it was checked internally

| Проверка | Результат |
|---|---|
| baseline HEAD `18a546e` (до фикса, stub с эмуляцией `--tail`) | дефект воспроизведён: `staged-old` → «данных нет»/`serial-fallback`; `staged-refused` → `lanes` (свежий отказ проигнорирован) |
| новые фикстуры после фикса | `staged-old` → `lanes: fn-lanes staged: …` / bench `lanes`; `staged-refused` → warn «vmm lanes ОТКАЗАНЫ …» (тексты прежние) / bench `serial-fallback`; `refused-staged` → `lanes` / `lanes` |
| прежние 6 фикстур этапа 8 (`staged/refused/both/none/spec-dflash/spec-none` × 3 профиля × check/bench) | `cmp` HEAD-vs-fix: **6/6 байт-в-байт идентично** (в т.ч. `both.log`: refused выше staged → остаётся lanes) |
| `bash -n` (health.sh, bench.sh) | OK |
| shellcheck-мультимножество vs базлайн этапа 9 (`sc_multiset.sh final/sc_after_final.txt`) | **идентично** (health.sh — 0 находок; дельты по файлам нет) |
| `cli_parity.sh` | PASS (usage == golden, статус/доктор/модели/bench-help без дрейфа) |
| golden-матрица `golden_stack.sh post` | дельта post-vs-pre == зафиксированная дельта этапа 9 (`final/golden_diff.txt`, 12 файлов = `.env`×4 + юниты×8, дрейфа нет); compose/фикстуры байт-в-байт |
| `pure_funcs.sh` | PASS (в т.ч. md5 фикстуры `253c7ac5…`) |
| `bench_py_parity.sh` | PASS (artifact/report побайтово, `--compare` без изменений — enum роута не тронут) |
| `ttft_test.sh` | PASS |
| `install_sandbox.sh` | PASS |
| п.3 (singleton-ветка на flash-multi spec-строке) | микропрогон на логе с `spec: qwen4 native mtp`: `ROUTE_SPEC="spec: qwen4 native mtp"` → default-ветка даёт `singleton-serial` (`case "spec: dflash"*` НЕ матчит мtp-строку → dflash не заявляет), flash-multi-ветка — `lanes`; на 27b-single-логе (`spec: dflash (draft …)`) фикстура `spec-dflash` — `singleton-dflash` байт-в-байт. Логика корректна, кода не менял |

### Not checked internally

- Повторная внешняя приёмка EXP-005 на второй машине (полный стрим живого
  лога 834 KB → `lanes`, bench-артефакт `"route": "lanes"`) — перезапускает
  оркестратор; на машины не заходил.
- Косметика вне раунда (неправка, фиксация): при НЕ-каноническом профиле
  (ручной прогон default-ветки на flash-multi-контейнере) default-ветка
  `check_route` печатает метку «singleton+DFlash» с фактической spec-строкой
  в скобках — pre-existing поведение, канон `HFCTL_PROFILE` туда не приводит.

### Known limitations / Out-of-scope proposals

- `shortcut:` в `route_snapshot`: цена — три полных прохода лога на снимок;
  при росте логов долгоживущего контейнера — апгрейд по комментарию
  (`--since` от старта / поле движка). Делать окна сейчас = вернуть дефект.
- Иное не трогал: `wait_health` (`--tail 25/30`, `--since 10m`) — другой
  контракт (хвост при отказе), `env_val` — не тронут.

## Test report (tester)

Verdict: **BLOCKED-EXTERNAL** — все внутренние проверки зелёные; внешние
приёмки DoD 10–11 подготовлены как EXP-скрипты (`created`, НЕ запускались:
машины в проде, GO оркестратора/пользователя не выдано).

- Date / round: 2026-11-11, round 1. HEAD `c7414e2` (рабочее дерево; изменён
  только этот отчёт). Носитель: `hflab/.local-analysis/task9-exp/`.
  Песочница тестера: `/tmp/hfctl-stage9-tester` (своя; чужие `$S9` не тронуты;
  `/tmp/opencode` в среде root-owned — запись нет, как уже зафиксировано
  developer'ом). Baseline сравнений: `git archive 638df18` (состояние кода =
  `336cd1f`, спеки не отличались), методы харнесов — те же, что setup_s9.sh
  (`funcs.sh`-срез, stub'ы), прогоны независимые от прогонов developer'а.

### Internal checks

| DoD | Проверка (команда) | Результат |
|---|---|---|
| 8 | `bash -n hfctl install.sh lib/*.sh` (12 файлов, рабочее дерево) | **12/12 OK** |
| 1,2,7,8 | shellcheck `638df18`-дерево vs HEAD, мультимножество (файл+код+переменная, без строк): сравнение python-контрагентами | total 39→37; **новых кодов нет**; дельта: −SC2034 bench.sh `BIND` (DoD 2), −SC2034 commands.sh `retries` (DoD 2, теперь читается), −SC2005 stack.sh `echo $(…)` (DoD 7в), +SC2034 commands.sh `HFCTL_FORCE`. Последний — код, уже-present в baseline (22 записи того же класса); проверено grep'ом: пишется в commands.sh:55,136 → читается в profiles.sh:110, легальный cross-file канал по Design §5 → **принят не как новый код** |
| 1 | grep-гейты по `hfctl install.sh lib/ tpl/`: `migrate_state`, `migrate_models`, `state_dir`, `MODEL_DEFAULT`, `FORCE_GATE`, `volume rm`, `hipfire_hipfire-config` | **каждый = 0** |
| 3 | `COMPOSE_FILE`: живое дерево — 0 употреблений; единственный hit — комментарий `lib/stack.sh:13` («podman-compose не читает COMPOSE_FILE», оставлен **явно по Design §3**, это не потребление); `tpl/env/env.tpl` = 0 | PASS |
| 4 | `ls benchmarks` — каталога нет; `md5sum tpl/bench/merge_sort_thinking_off.txt` = `253c7ac50857fe6d0e10fb0d2c5e35c0`; grep `benchmarks/prompts` по живому дереву: 0 ссылок на **репо-путь**; 2 hit'а (`stack_files.sh:119,158`) — runtime-путь `$STACK_DIR/benchmarks/prompts` механизма prompts-маунта, **сохранённого явно по DoD 4/Design §4** (`LOCAL_PROMPTS` в `compose.local.yml.tpl` на месте). Формулировка гейта в Test strategy («grep = 0 по репо») букве не следует — см. заметку ниже | PASS (гейт по интенту) |
| 1,3,8 | golden-матрица: `golden_stack.sh pre` (638df18) vs `post` (HEAD), 4 комбинации × (compose×4/.env/юниты×3/proc), сравнение post-vs-pre с нормализацией штампов песочницы | **40 файлов; различия ровно 4 = `.env`, каждое — одна удалённая строка `COMPOSE_FILE=…`**; compose/юниты/прочее байт-в-байт; placeholder-residue 0/0 |
| 2,8 | `cli_parity.sh` (patched): usage pre и post vs `usage_new_golden.txt` (`cmp`), unknown-cmd (rc+stderr), `status`, `status --json` (валидность JSON), `doctor`, `models`, `bench --help` pre-vs-post (rc+вывод с нормализацией путей) | **PASS** (usage == golden байт-в-байт с обеих сторон; дрейф единичный — живая строка MemAvailable в doctor, не контракт) |
| 6а | `route_matrix.sh pre/post` × 6 fixture-логов (`staged/refused/both/none/spec-dflash/spec-none`) × 3 профиля, `check_route`+`bench_route`, stdout+stderr склейка | **6/6 cmp идентичны** (тексты check_route = pre-HEAD байт-в-байт); enum `bench_route` даёт все 5 значений (`lanes/serial-fallback/multi-slot/singleton-dflash/singleton-serial`) |
| 6а | предикат единый: `grep -rn 'fn-lanes staged\|qwen4 lanes refused' lib/` — грепы логов только в `health.sh` (`route_snapshot`); `lib/bench.sh:71` — `case "$ROUTE_SPEC" in "spec: dflash"*)` (отображение снимка в enum, НЕ повторный grep лога); `engine.sh:65` — комментарий | PASS (дубля предиката нет) |
| 5 | `force_gate.sh` (пул dev-машины 31 GiB < гейт 80): plain `use flash-multi` → rc=1 + ERROR с цифрами; `HFCTL_FORCE=1` vs `--force` | **PASS**; плюс моя проверка: `cmp force/env.out force/flag.out` — **полные выводы идентичны**; `grep FORCE_GATE` = 0 (второго имени нет); die-строка install перечисляет `--force` (commands.sh:51) |
| 6б | `stop_matrix.sh` (stub-compose пишет момент наличия маркера): `down` и `off` | **PASS**: `stop:marker-before` в обеих, `compose stop` в обеих, маркер `.hfctl-stopped` создан, итоговые строки/`disable` юнитов/`disable-linger` на месте |
| 7а | `cfgset_fail.sh` (stub-podman rc=1 на `config set`): `apply_profile 27b-single` | **PASS**: rc=1, `WARN cfgset: отказ ключей:` с полным перечнем 11 ключей, все 11 вызовов сделаны (не умирает на первом); вызывающие `commands.sh:67,158` — `apply_profile … || true` (grep подтвердил) |
| 7б | структура: `autostart.sh:249` `( flock -n 9 && compose up -d --force-recreate 2>&1 | tail -1 || true ) 9>".hfctl.lock" || true`; микросимуляция формы: фоновый `flock ./f.lock -c 'sleep 5'` → субшелл-форма даёт **пусто, rc=0** (пропуск не ошибка); после освобождения — `RECREATE-RAN` | PASS (живой boot-цикл — EXP-004 P8) |
| 7в | `cur_model` = `{ env_val HIPFIRE_MODEL; }`; поведенчески pre vs post: `.env` без `HIPFIRE_MODEL` → ''/rc=0 в обоих; с ключом → тег идентично | PASS (поведение не изменилось) |
| 7г | `cmd_uninstall`: `local purge_models=0 purge_image=0 keep=""`; docblock без «ГЛОБАЛ» | PASS |
| 7д | usage: `grep '2,20p' hfctl` = 0; маркеры `USAGE-BEGIN/USAGE-END` строки 2/22; `hfctl` no-args == golden (`cmp` пусто); **маркер-тест**: копия дерева + строка ВНУТРЬ маркеров → появилась в выводе; строка СНАРУЖИ маркеров → не появилась (печать следует за маркерами, не за номерами) | PASS |
| 2 | `watch_retries.sh`: stub-curl retries=2 / =0 / без поля → «ретраи: 2» только в первом | PASS |
| 8 | регресс этапа 8 на HEAD: `pure_funcs.sh` (patched :71) / `bench_py_parity.sh` / `ttft_test.sh` / `install_sandbox.sh` (PATH=stub) | **PASS / PASS / PASS (ttft 160 мс, null, ERR) / PASS** (из дерева, замена, идемпотентность, вне дерева, 0 curl) |
| house-style | python-проверка 12 файлов: `#@` слитно = 0; запрещённых типов `bool/int/never` = 0; три секции (Назначение/Побочные/Ограничения) у **всех 66 функций** (включая новые `route_snapshot` в health.sh и `stop_with_marker` в autostart.sh); выравнивание хвостовых `#` по **символам**: 93/93 групп `# @`-строк с описанием выровнены (6 single-line `@typedef/@type` без описания — выравнивать нечего) | PASS (см. не-блокирующую заметку про install.sh ниже) |
| 9 | `spec/hfctl.md` §13 «Контракты этапа 9» присутствует (cfgset-rc, route_snapshot, .env без COMPOSE_FILE, форс-канал, ретраи, stop_with_marker, «переходного кода нет»); README: `--force` в таблице install, `HFCTL_FORCE`, отсутствие `COMPOSE_FILE`, фикстура `tpl/bench/`; `spec/plan.md` — DoD 1–9 отмечены [x], 10–12 нет | PASS (тексты — предмет reviewer'а) |
| гигиена | hfctl-репо: IP/ключей/логов машин = 0 (см. заметку про имена в spec-тексте); рабочее дерево чистое, кроме этого отчёта | PASS |

### Failures (FAIL)

Нет. Ни одной красной внутренней проверки.

### External experiments

| EXP-id | DoD | статус |
|---|---|---|
| `EXP-004-evo-full.sh` (прод-машина (60 GiB): read-only before → update деревом из клона → use 27b-slots↔27b-single → `.env` без COMPOSE_FILE → doctor без legacy-WARN → off/on (маркер+вотчдог-молчание 90 с) → watch-тик без «ретраи» → **reboot → сам-подъём** (`_boot`;Created контейнера ≥ boot как доказательство recreate под flock) → smoke; финал 27b-single healthy) | 10 | **created** (не запускался; `bash -n` OK; все удалённые payload-скрипты проверены токенизатором на синтаксис; диагностика при FAIL — podman logs -t + systemctl --user status, продукт не чинит) |
| `EXP-005-faex-lanes.sh` (вторая машина (128 GB): before healthy + `podman volume ls | grep -i hipfire` пусто → update деревом **без остановки** (healthy всё время) → doctor чист → smoke → `fn-lanes staged` в `podman logs -t … 2>&1` → `hfctl bench` quick: артефакт `"route": "lanes"`, md5-warn нет → финал flash-multi healthy) | 11 | **created** (то же; грабля stderr-логов учтена — `2>&1` везде) |

Оба: ssh-паттерн hflab/AGENTS.md (`ssh -i ~/.ssh/strix_halo_key -o
BatchMode=yes hipfire@<IP> 'bash -s'`), IP взяты из hflab-AGENTS, в hfctl-репо
не попали; каждый удалённый шаг под `timeout` (900 с; bench 1200 с; возврат
после ребута ≤10 мин, healthy ≤15 мин); мусор — только собственный клон
(/tmp/hfctl-exp00{4,5}-clone, удаляется trap'ом) + штатный bench-артефакт на
FAEX1. Носители: `hflab/.local-analysis/task9-exp/EXP-00{4,5}-*.sh`, вывод —
в `EXP-00{4,5}-*.result.txt` (команда запуска в шапках), финальная строка
`RESULT: PASS|FAIL|ERROR`.

### Regression (итог)

Полный регресс закрытых этапов прогнан заново на HEAD: golden-матриза
(post-vs-pre, 40 файлов), CLI-parity + usage-golden, pure_funcs,
bench_py_parity, ttft_test, install_sandbox, route-матрица 6 фикстур,
stop/cfgset/watch/force-матрицы — **все зелёные**. Shellcheck: новых кодов
нет, мультимножество уменьшилось (объяснено выше и в dev-report).

### Заметки (не блокоеры — в backlog/reviewer'у)

1. **Формулировка гейта DoD 4** в Test strategy («grep `benchmarks/prompts`
   по hfctl-репо = 0») букве не следует: 2 живых упоминания runtime-пути в
   `stack_files.sh` сохранены **по Design §4/DoD 4** («механизм prompts-маунта
   не трогать»). Триаг: `test` (формулировка), кода менять не надо.
2. **`install.sh ok()`** — docblock без секции «Ограничения» (единственная из
   66). `install.sh` побайтово идентичен baseline (diff пуст) — пре-existed со
   времени аннотационного коммита `336cd1f`, не регресс этапа 9. Backlog.
3. Имена хост-профилей `прод-машина (60 GiB)`/`вторая машина (128 GB)` встречаются в hfctl-репо только
   в spec-тексте (`spec/plan.md` DoD 10–11, `spec/task-9.md`) — текст brief'а
   оркестратора, до кодовых коммитов этапа; кодов/harness-имён хостов = 0.
   Решение за reviewer'ом/оркестратором (правило 7 трактует IP/ключи/логи).
4. Статусный коммит C9 (`spec/state.md` «этап 9 в приёмке/принят», плановые
   чекбоксы внешних DoD) — по решению оркестратора не сделан; закрытие
   внешних 10–12 возможно только после EXP.

**BLOCKED-EXTERNAL: ожидает GO на EXP-004 (прод-машина (60 GiB)) и EXP-005 (вторая машина (128 GB)).**
