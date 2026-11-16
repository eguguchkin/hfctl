# Review: engine/0.4.7
Verdict: APPROVED
Round: 1
Ревьюер: reviewer (subagent). Диф перечитан фактически; claims разработчика
воспроизведены командами в репо, F-0.4.7.3 — перепроверена на апстрим-клоне.

## Against DoD
| DoD (brief) | item | met/partial/missing | proof/complaint |
|---|---|---|---|
| 1. Пин `hfctl:35–36` → 0.4.7; пина 0.4.6 в продукте нигде | met | Воспроизведено ревьюером: `grep -rn '0\.4\.6' hfctl lib/ install.sh README.md tpl/` → только mandated-пометки байт-идентичности `lib/stack_files.sh:4,5,6,151` (источник факта F-0.4.7.3, не пин — легитимно по прецеденту 11.1 п.2); в `hfctl` совпадений 0. `grep -rn '0\.4\.7'` → пин ровно в `hfctl:35,36` (+ доки `stack_files.sh:2,4,5,6,151`); в `install.sh`, `README.md`, `tpl/` пинов нет. |
| 2. Заголовок + golden-пометка `stack_files.sh` → 0.4.7 + mandated-пометка (F-0.4.7.3); `tpl/` не меняется | met | `stack_files.sh:2` — «официальные compose-файлы hipfire 0.4.7»; :3–6 — пометка «в 0.4.6 и 0.4.7 байт-идентичны 0.4.5 (… git diff v0.4.6..v0.4.7 пуст, F-0.4.7.3)» — цитирует факт, источник не recon-файл (как требовал task.md); :151 — «для 0.4.6 и 0.4.7 байт-в-байт». `git diff --stat tpl/` — пусто (golden'ы не тронуты). F-0.4.7.3 независимо подтверждена на `/workspace/hipfire`: `git rev-parse v0.4.5:compose.yml v0.4.6:compose.yml v0.4.7:compose.yml` → все `01512a9a4ffc…`; `compose.halo.yml` → все `b67a00b85215…`; `git diff v0.4.6..v0.4.7 -- compose*` — пусто. Golden'ы валидны для 0.4.7. |
| 3. FACTS.md: секция «Движок 0.4.7» (F-0.4.7.1…6), внесена оркестратором до кода | met | `.dev/FACTS.md:92` «Движок 0.4.7 (проверено оркестратором, 2026-11-16)», F-0.4.7.1…6 на :93–110. В дифе FACTS.md — отдельное изменение оркестратора (разработчик его не дублирует — dev-report п. «Что было сделано», AGENTS.md hygiene); дата совпадает с записью начала сабстэджа в history.md. |
| 4. Внутренние проверки зелёные | met | Перепущено ревьюером независимо: `bash -n hfctl lib/*.sh` OK; `python3 -m py_compile tpl/python/*.py` OK; `./hfctl` без аргументов → usage, rc=1; `HFCTL_PORT=99999 ./hfctl status --json` → rc=0, корректный отказ без краха `{"profile": "27b-single", "autostart": false, "watchdog": false, "health": null}`. `git status --porcelain`: кодовый диф = ровно `hfctl` + `lib/stack_files.sh`, `tpl/` не тронут; md5 `tpl/bench/merge_sort_thinking_off.txt` = `253c7ac50857fe6d0e10fb0d2c5e35c0` = канон `BENCH_FIXTURE_MD5` (lib/bench.sh:10). |
| 5. EXP-104 (машинная приёмка) | open (BLOCKED-EXTERNAL, за оркестратором) | По task.md DoD 5–6 — за оркестратором (D11). Dev-report честно помечает «не проверено внутренне», ничего не выдаёт за сделанное. EXP-104 в очереди, ждёт GO пользователя. Субстэдж остаётся открытым до PASS EXP-104 (F-0.4.7.6). |
| 6. Ревью APPROVED; статусный коммит (STATE.md + history.md) | in progress | Настоящее ревью (APPROVED). STATE.md и history.md уже обновлены оркестратором (статус IN DEV + запись начала сабстэджа); статусный коммит — оркестратором после EXP-104 (hygiene AGENTS.md: роли не коммитят). |

## Scope-контроль
- Кодовый диф = ровно 2 файла, 5 точек из §Design task.md (`hfctl:35,36`;
  `stack_files.sh:2`, :3–6, :151), ничего сверх. Изменение = константа-пин +
  комментарии; логики, рефакторинга, scope creep нет.
- `.dev/` в `git status` — журнал оркестратора (FACTS.md, STATE.md, history.md,
  `tasks/12/`): допустимо по hygiene (developer не правит STATE.md, не коммитит).
- Правило 7: в дифе нет IP, путей ключей, имён хостов.
- Доки: никаких новых упоминаний пина 0.4.6/0.4.7 вне mandated-зон;
  `SPEC.md:5,125`, `PLAN.md:203,393–402` — исторические (статус роута эпохи
  0.4.5, закрытый этап 11), категория «НЕ трогать» — не тронуты.

## Blocking
(нет)

## Non-critical notes
1. В `PLAN.md` нет записи «Этап 12» (запись «Этап 11» есть, :393). В DoD 6
   brief перечислены только STATE.md + history.md, так что не блокирует —
   оркестратору добавить запись этапа при статусном коммите закрытия (по
   прецеденту 11.1).
2. `tester skipped` для 12.1 зафиксировано в history.md (запись 2026-11-16:
   «tester пропустим с записью, reviewer обязателен») — bookkeeping в порядке,
   в отличие от 11.1.

## Questions to the spec
(нет) — граница «образ тянется с пином из шапки диспетчера»
(`.dev/SPEC.md`, install/use) соответствует дифу; других контрактов
сабстэдж не затрагивает (tpl/ цел, goldens подтверждены байт-идентичностью).
