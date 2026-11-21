# Review: 14.1 лейаут v2 — клон = стек, bootstrap = первый `hfctl on`, uninstall v2
Verdict: **APPROVED**
Round: 1
- Ревьюер: независимая сессия, 2026-11-21. Проверено по артефактам и коду:
  git diff bc34b97 прочитан по всем 14 файлам (13 + D install.sh); батарея
  прогнана ревьюером самостоятельно ×1 (`bash tests/run_checks.sh` → rc=0,
  `ИТОГО: PASS=52 FAIL=0`); машины не трогались, код не правился, коммитов нет.

## Against DoD

| item | met/partial | proof |
|---|---|---|
| 1 STACK_DIR-механика | met | `hfctl`: `SELF` перенесён выше, `STACK_DIR="${HFCTL_DIR:-$(dirname "$SELF")}"` (:48), `DATA_DIR` :49, `MODELS_BASE=$DATA_DIR/models` :50, `STATE_BASE` :55, `STOP_MARKER=$DATA_DIR/.hfctl-stopped` :69; env-крючки HFCTL_DIR/MODELS/STATE сохранены. Локи: в autostart.sh 0 упоминаний `$STACK_DIR/.hfctl.lock`, 7 упоминаний `$DATA_DIR/.hfctl.lock` (3 кодовых: hf_lock_reclaim :352, `) 9>` в hf_up_locked :428 и hf_up_devsafe :494 — N7 ассертит оба счётчика); `stop_with_marker` = `mkdir -p "$DATA_DIR"`. Bench: `OUT="${out_dir:-$DATA_DIR/bench-runs}"` (:658) + строки-комментарии 15/33/42/571. Запуск из подкаталога — N7 (subtree-копия, doctor из `$sub/lib`) |
| 2 install упразднён | met | `install.sh` удалён (`D` в git status); роутер `install)  cmd_on "$@" ;;` (:240, в ряду скрытых алиасов); `on)` получил `"$@"`; usage-шапка: quickstart `git clone && cd hfctl && ./hfctl on`, `on` = «поднять стек (на пустом клоне — bootstrap)», uninstall v2-формулировка, install-строк нет (N9 ×2); `cmd_bootstrap` = тело `cmd_install` байт-в-байт минус хвост-развилка (сверено с `git show bc34b97:lib/commands.sh`); die-указатели ровно два поименованных: cmd_use (:131) «сначала 'hfctl on'», doctor (:355) «сначала 'hfctl on'» |
| 3 bootstrap первого on | met | `cmd_on` (autostart.sh): пустой `.env` → `cmd_bootstrap ${args[@]+"${args[@]}"}` (оригинал аргументов — повтор оборванного bootstrap теми же флагами); guard'ы мутаторов и --no-autostart на развёрнутом стеке с маркером `# fix:bootstrap-guard` ×2; юниты ПОСЛЕДНИМИ — Р1-обоснование в коде ВИДНО: докстринги cmd_bootstrap («Юниты… ставит вызывающий cmd_on после health… таймер вотчдога активируется только на здоровом стеке — Р1») и cmd_on; N1 ассертит порядок фаз ПО ЖУРНАЛУ: recreate < enable, smoke < enable, podman logs < enable + маркер снят + .env/.data/юниты(tpl-conf)/симлинк; N3 — guard с нулём действий; N2 — идемпотентность; N8 — тот же конвейер реальным диспетчером через алиас install. Фазовый порядок §Б (RAM-гейт → set_models_dir → preflight → write_stack_files → write_env → pull → up → apply_profile → force-recreate → health 900 → smoke → check_route) — без изменений, exit 42 до write_env сохранён |
| 4 uninstall v2 | met | `cmd_uninstall`: экран v2 → ask → `cmd_off \|\| true` (Ф1-двойной стоп) → `compose down` в субшелле с cd → limits.d `sudo rm -f` → purge-флаги (`rm -rf "$DATA_DIR/models"` — только models; `podman rmi`). v1-элементы (mv базы + `rm -rf "$STACK_DIR"`) удалены — в STACK_DIR ни одного rm; клон/.data/образ/симлинк не трогаются — N5 ассертит целость `.env`, compose.yml, `keep-me.bin`; N6 — purge (models удалена, profiles целы, rmi в журнале); v1-вставка `rm -rf $STACK_DIR` ловится чистой мутацией (тестер 3.4: N5+N6 по существу) |
| 5 Ф5-conf tpl-путь | met | `compose()` (stack.sh:44) — guard+export `$STACK_DIR/tpl/etc/hfctl-containers.conf` (маркер containers-conf = 1 локация, инвентарь батареи); оба юнит-tpl — `Environment=CONTAINERS_CONF=__STACK_DIR__/tpl/etc/hfctl-containers.conf`; копии conf в write_stack_files и cmd_autostart удалены вместе с дубль-маркерами; `sync_tree` удалён целиком (stack_files.sh) с обоими вызовами; `ensure_symlink` остался; residual-грепп `.hfctl-containers` по живому коду — пусто |
| 6 .gitignore | met | `git diff bc34b97 -- .gitignore` = ровно `+.data/`, `+.env`; существующие строки не тронуты (тестер 4.3 + git check-ignore на копии с .git, тестер 4.4). См. Note-1 про compose-тройку — не пункт DoD |
| 7 миграция-контракт | met | SPEC §15 (блок §М 1:1: mv-шаги, «НЕ переносить», первый on с флагами, doctor/status, rm -rf после healthy, примечания об И-инвариантах и отсутствии отката) + README «Миграция с лейаута v1»; исполнение НЕ выполнялось — по контракту (машины не трогались) |
| 8 батарея | met (отклонение 49→52 обосновано честно) | ревьюер сам: `PASS=52 FAIL=0`, rc=0. Состав (тестер 2.2, comm-сверка): 40 сохранённых (ассерты обновлены, ослаблений нет — diff run_checks.sh просмотрен; F5 переведён на tpl-путь/env, mутация containers-conf → env-сценарий, инвентарь 9→11 имён) + 9 позитивов N1–N9 + 3 мутационные строки новых гвардов. НОВАЯ батарея на HEAD честно красная (36/16 с внятными причинами; N2 зелёный по дизайну контракта). Отклонение: контракт сам требует и «49 = 40+9», и мутации новых гвардов по конвенции 13.x (каждая = отдельная строка PASS — так устроены 11 мутаций 13.x внутри тех же 40) — 49 неисполнимо одновременно с обоими требованиями; выбрана явная строка на мутацию (проверяемая по имени), не спрятанная в позитив — свёртка в позитивы была бы МЕНЕЕ честной; реверс предложен в dev-report. Не блокирует |
| 9 SPEC/README/AGENTS | met | И1 переформулирован в «Инвариантах поставки» (первый `hfctl on`, install.sh упразднён) и продублирован строкой on-bootstrap в §3; И3 дополнен («стек = клон — автоматичен»); §2 — quickstart, таблица лейаута `.data/`, «вне каталога», warnings; §3 — on-bootstrap/uninstall v2/алиас install; §4 — канон в клоне; §14 — tpl-путь обоих потребителей, инвариант «фактом клона»; §10 — абзац «исторический»; README/AGENTS — см. диффы: grep `install.sh\|hfctl install\|cmd_install` по README/AGENTS — пусто; mandated-зоны не тронуты: `git diff bc34b97 --stat` = ровно 14 файлов (13 + D), tpl/compose, tpl/etc, tpl/bench, lib/{health,models,state,profiles,engine}.sh, .dev/STATE.md — отсутствуют (F-0.4.7.3 цел) |

## Blocking

Нет.

## Non-critical notes (бэклог, не блокируют)

1. **`git clean -fd`-клейм имеет дыру: compose-тройка в корне клона.** `compose.yml`,
   `compose.halo.yml`, `compose.local.yml` в корне клона — untracked и НЕ
   gitignored (проверено: `git ls-files` пуст, `git check-ignore` rc=1);
   write_stack_files их генерит, но up/on НЕ регенерируют. `git clean -fd` на
   развёрнутом клоне снесёт все три → следующий `up`/`on`/watchdog-тик падает
   до `hfctl use <профиль>` (регенерирует). Потери данных нет, восстановление
   — одна команда; README/SPEC §2/§15 утверждают «git clean -fd безопасен» —
   точно для данных (.data/.env), не для compose-тройки. Где: README «Лейаут
   v2… Warnings», SPEC §2. Что делать (одна из двух строк, следующий касательный
   раунд): `+.gitignore` → `compose.local.yml` (и/или пара compose-файлов) —
   тогда клейм станет буквально верен, либо смягчить формулировку
   («безопасен для данных; compose-тройку регенерирует use»). Тестер-проверка
   4.4 дыру не видела закономерно: в её чистой копии write_stack_files не
   гонялся.
2. **Хвост «install»-текстов вне поимованного перечня** (dev-report п.5
   воспроизведён): bench.sh:641 и commands.sh:441 die «сначала 'hfctl
   install'», commands.sh:352 doctor-warn «(hfctl install)» — алиас работает,
   указатели ведут на живую команду; плюс докстринги stack.sh:173,
   health.sh:66, profiles.sh:92/99 упоминают `cmd_install`. Косметика,
   бэклог (согласуется с out-of-scope dev-report).
3. Комментарий роутера «install → cmd_on (лейаут v1; …)» (hfctl:226) читается
   как «нынешний лейаут» — заменить на «лейаут v1-машин» при следующем
   касании (тестер Note-4).
4. Мульти-арг `bash -n` в батарее/`check_mutation` чекает только первый файл
   (тестер Note-1, унаследовано от 13.x) — пофайловый прогон тестера зелёный;
   цикл по файлам в будущем раунде батареи.
5. N4-замена ассерта подтверждена кодом: `pull_model` (models.sh:27) всегда
   зовёт `podman run … hipfire pull` — «пустой pull-журнал» недостижим,
   буквальный ассерт контракта неисполним; замена (маунт → `.data/models/27b`,
   файлы целы, `podman pull` образа пропущен) проверяет тот же смысл
   («модели на месте — перекачки нет»). DoD не ослаблен.
6. §М не упоминает `~/hipfire/benchmarks/prompts` — каталог лабы, после окна
   миграции пересоздаётся обновлёнными лаб-скриптами (Р4-хвост контракта);
   hfctl-bench в маунте не нуждается (фикстура идёт в payload). Ок.
7. Опечатка «install.sh в клона нет» (SPEC §15, унаследована из текста
   контракта §М) — косметика.

## Questions to the spec

- Вопросов к спеке нет: И1/И3/§2/§3/§4/§14/§15/§10 согласованы с кодом,
  противоречий код↔спека не найдено (греппы по install/~/hipfire/.hfctl-
  containers в мандатных секциях чисты; исторические §9/§13/§13.2 не в счёт).
  Note-1 — кандидатом в следующий док-раунд, не правка спеки сейчас.

## Ответы на вопросы оркестратора (риски дизайна)

- **(а) Р1 на уже-мигрировавшей машине:** повторный `on` = cmd_autostart
  (перерендер юнитов из tracked-tpl — детерминированный, enable идемпотентен)
  + cmd_up — это в точности семантика v1 `hfctl on`, не новая. Идемпотентно.
  Повтор оборванного bootstrap: `.env` отсутствует → ветка bootstrap снова,
  флаги повторяются (§Б, SPEC §15) — контрактовано.
- **(б) §М и потеря данных:** безопасно и контрактовано: mv в пределах /home
  (иноды); старый `.env` сознательно не переносится — ЕДИНСТВЕННЫЕ потери
  (порт/bind/дефолт-модель) перечислены в §М/SPEC §15/README и переносятся
  флагами/env первого on; конфиг движка переезжает с profiles; откат
  существует до `rm -rf ~/hipfire` (mv-назад). Совместимости «новый код на
  старом стеке» нет — заявлено и не тестируется (корректно).
- **(в) N4:** см. Note-5 — не ослабляет DoD.
- **(г) счётчик:** свёртки в позитивы НЕТ — мутации оставлены явными
  строками PASS (+3 = 52), направление строгости в бо́льшую сторону;
  отклонение задокументировано до раунда ревью и воспроизведено.
