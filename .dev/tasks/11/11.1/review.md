# Review: engine/0.4.6
Verdict: APPROVED
Round: 1
Ревьюер: GLM-5.3-Flash (subagent). Диф перечитан фактически; claims разработчика
воспроизведены командами в репо.

## Against DoD
| DoD (brief) | item | met/partial | proof |
|---|---|---|---|
| 1. Приёмка машины B (flash-multi) | met | ЗАКРЫТО ДО КОДА (task.md шапка): fn-lanes lanes=4 spec=mtp K=7, smoke, bench solo-code 75.8 tok/s τ=5.00 против бейслайна 75.22 (без регрессии), init «Already downloaded» ×2, doctor rc=0. Канал HFCTL_IMAGE = лабораторный, как в brief. |
| 2. Приёмка che-evo (27b-single, прод) | met | decode 131.0 tok/s τ=13.18 ×3, промпт md5 253c7ac5 — против эталона mq4-xts 130.5/13.18 (±10% запас). Расхождение формулировки brief (75.3/τ11.83 — цифры mq6-xt) честно задокументировано в task.md: фактическая прод-модель mq4-xts, сравнение против её эталона корректнее — критерий «без регрессии» выполнен в обеих интерпретациях. Не moving goalposts: criterion жёстче, а не мягче. |
| 3. Код: пин + док-строки + golden-пометка | met | git diff: ровно 2 файла. hfctl:35–36 (0.4.5→0.4.6 в @type-комментарии и в IMAGE-дефолте) — больше в диспетчере ничего. lib/stack_files.sh: заголовок модуля (0.4.6) + пометка :3–5 (байт-идентичность, recon в.10) + дубль у копирования :147–150. Ни одной правки вне этих зон. |
| 4. Внутренние проверки | met | Воспроизведено ревьюером: `bash -n hfctl lib/stack_files.sh` OK; `./hfctl` без аргументов → rc=1 (usage); `PORT=1 ./hfctl status --json` → rc=0 без краша; md5 `tpl/bench/merge_sort_thinking_off.txt` = 253c7ac5… — канон цел; tpl/env/env.tpl — плейсхолдер `__IMAGE__`, пина нет (править нечего, подтверждено grep'ом). spec/state.md — статусный коммит оркестратора после ревью (правильно, hygiene AGENTS.md). |
| 5. Регрессия | met (достаточно) | Изменение = константа + комментарии; поведение диспетчера проверено usage/status; tpl/ не тронут (`git status --porcelain`: только `M hfctl`, `M lib/stack_files.sh` + артефакты flow/). Рефакторинга/логики нет. |
| 6. hflab (scripts/*, AGENTS.md, STATE.md) | met (вне репо) | По task.md «Вне scope (закрыто оркестратором)» — не в этом дифе, не блокирует. |

## Scope-контроль
- Диф = ровно scope п.1–3 task.md: `hfctl` 2 строки, `lib/stack_files.sh` только
  комментарии (+6/−2). Скрытых правок нет, scope creep нет.
- Факт recon в.10 (байты golden'ов валидны для 0.4.6) перепроверен ревьюером
  на апстрим-клоне /workspace/hipfire: `git rev-parse v0.4.5:compose.yml
  v0.4.6:compose.yml` → оба `01512a9a4…`; compose.halo.yml → оба
  `b67a00b85…`. Пометка в коде соответствует факту.
- Остаточные «0.4.5» в spec/* (hfctl.md:5,125; plan.md:203; state.md:113;
  task-7.md:40) и tpl/compose (mark provenance «upstream hipfire 0.4.5»)
  проверены по контексту — это история/фактология (где сняты цифры, статус
  роута эпохи, происхождение golden'ов), НЕ пин образа. Категория
  «НЕ-трогать» task.md п.2. Пина дефолта 0.4.5 в продукте не осталось
  (grep hfctl lib/ install.sh README.md — чисто, кроме mandated-пометки
  байт-идентичности в stack_files.sh, где 0.4.5 — упоминание источника, легитимно).

## Blocking
(нет)

## Non-critical notes
1. task.md п.4 назначает «строку статуса в spec/status.md» разработчику,
   но файла нет, а формат — spec/state.md, который роли не правят
   (AGENTS.md hygiene). Developer разрешил противоречие правильно в пользу
   hygiene; оркестратору — не забыть статус-коммит spec/state.md + history.
2. В history.md нет записи `tester skipped: <reason>` для этого сабстэджа —
   оркестраторская bookkeeping (D11/DECISIONS.md:45), до закрытия добавить.
3. Комментарий stack_files.sh:150 теперь объединяет байт-идентичность и
   «без monitoring-профилей» в одной скобке — читается с небольшой натяжкой,
   смысл не искажён (вкус, не блокирует).

## Questions to the spec
(нет)
