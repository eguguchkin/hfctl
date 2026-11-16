# Task: engine/0.4.7 — пин образа 0.4.6 → 0.4.7 (механический)   Design: orchestrator-direct

## Scope and DoD

Цель и DoD 1–4 — из `brief.md` (DoD 5–6 за оркестратором: EXP-104 и
статусный коммит). Вне скоупа: `tpl/` (включая compose- и bench-фикстуру),
`install.sh`, `README.md` (пинов нет — проверить grep'ом и не трогать),
исторические упоминания версий в `.dev/` и доках, llm-lab.

## Design

Точки правки — ровно те, что правились в 11.1 (engine/0.4.6):

1. `hfctl:35` — `@type`-комментарий: `…hipfire:0.4.6}` → `…hipfire:0.4.7}`
2. `hfctl:36` — `IMAGE="${HFCTL_IMAGE:-ghcr.io/warpfront/hipfire:0.4.6}"`
   → `…0.4.7"`
3. `lib/stack_files.sh:2` — заголовок модуля: «официальные compose-файлы
   hipfire 0.4.6» → «hipfire 0.4.7»
4. `lib/stack_files.sh:3–5` — golden-пометка: дополнить — compose.yml /
   compose.halo.yml в 0.4.7 байт-идентичны 0.4.5/0.4.6 (`git diff
   v0.4.6..v0.4.7` пуст, F-0.4.7.3) → golden'ы валидны и для 0.4.7
   (источник факта — F-0.4.7.3, не recon-файл: в этой ревизии блобы
   совпали в git).
5. `lib/stack_files.sh:150` (пометка у места копирования compose.yml):
   «дословно из репозитория hipfire 0.4.5 (для 0.4.6 байт-в-байт, …)» →
   «…для 0.4.6 и 0.4.7 байт-в-байт…».

Поведение продукта не меняется: пин — единственный параметр; recreate/use
тянут новый тег, `.env`/конфиг/юниты не зависят от версии.

## Test strategy

| DoD item | внутренний чек | внешний |
|---|---|---|
| 1 (пин) | `grep -rn '0\.4\.6' hfctl lib/ install.sh README.md tpl/` → только mandated-пометка в stack_files.sh (источник, не пин) + исторические; дефолтного пина 0.4.6 нигде нет | EXP-104: recreate тянет 0.4.7 (`podman images`/`docker images` digest) |
| 2 (доки/пометка) | git diff: ровно 2 файла; текст пометки цитирует F-0.4.7.3 | — |
| 4 (внутренние) | `bash -n hfctl lib/*.sh`; `python3 -m py_compile tpl/python/*.py`; `hfctl` без аргументов → usage, rc=1; `HFCTL_PORT=<чанковый> hfctl status --json` → корректный отказ | — |
| 5 (машинная) | — | EXP-104: healthy + smoke (dflash:true) + bench quick, бейзлайны brief DoD 5 |

## Risks and rollback

- Риск не в коде (один пин), а в образе: 0.4.7 — фикс-хэви (F-0.4.7.5),
  живая проверка только в EXP-104; до её PASS пин не считается принятым.
- Откат: `git revert`; на живых машинах — `HFCTL_IMAGE=…0.4.6` (тег жив на
  ghcr, digests моделей идентичны, F-0.4.7.2/бейзлайны 11.1).

## References

- F-0.4.7.1…F-0.4.7.6 — `.dev/FACTS.md` (секция «Движок 0.4.7»)
- D11, D12 — `.dev/DECISIONS.md`
- Прецедент: `.dev/tasks/11/11.1/{task.md,dev-report.md,review.md}`
- `.dev/SPEC.md` (install/use)

## Open questions

Нет (механический пин; режим — D11). EXP-104 — окно машины, GO у
оркестратора после APPROVED.
