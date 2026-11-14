# .dev — blackboard hfctl (dev-flow)

Каталог знаний между сессиями. Любой агент, начинающий работу, читает
сначала `STATE.md`, потом хвост `history.md`, потом артефакты текущего
сабстэджа. Структура задана скилом `dev-flow`; здесь — карта и
соответствие старых путей.

```text
.dev/
├ STATE.md                  # ЕДИНСТВЕННЫЙ канонический «где мы сейчас»
├ history.md                # append-only журнал событий (кто/что/когда/артефакты)
├ SPEC.md                   # продуктовая UX-спецификация — источник «что»
├ PLAN.md                   # этапы и DoD (архив, не источник истины)
├ DECISIONS.md              # датированный журнал ратификаций («почему»)
├ FACTS.md                  # факты движка/железа (правится только прогонами)
├ tasks/
│  ├ 7.md  8.md  9.md        # логи этапов 7–9 (legacy, целые файлы)
│  └ <stage>/<stage>.<sub>/  # сабстэджи dev-flow
│      ├ SPEC.md             # спека сабстэджа (детализирует SPEC.md, не противоречит)
│      ├ brief.md            # оркестратор: цель, DoD (единственный носитель), ограничения
│      ├ task.md             # architect (или orchestrator-direct): дизайн + тест-стратегия
│      ├ dev-report.md       # developer: что сделано, как проверено
│      ├ test-report.md      # tester: вердикт, провалы, внешние EXP
│      └ review.md           # reviewer: вердикт, блокирующее
├ external/                 # очередь внешних прогонов (через пользователя)
│  ├ EXP-<NNN>-<имя>.sh     # самодостаточный скрипт для запуска на ХОСТЕ
│  ├ EXP-<NNN>-<имя>.result.txt
│  └ EXP-<NNN>.analysis.md  # разбор результата (оркестратор)
└ archive/                  # устаревшие/замороженные документы
```

## Соответствие старых путей (миграция 2026-11-14, `spec/` + `flow/` → `.dev/`)

| старый путь | новый путь |
|---|---|
| `spec/hfctl.md` | `.dev/SPEC.md` |
| `spec/plan.md` | `.dev/PLAN.md` |
| `spec/state.md` | `.dev/STATE.md` (слит с `flow/STATE.md`) |
| `spec/task-7/8/9.md` | `.dev/tasks/7.md / 8.md / 9.md` |
| `spec/review.md` | append в `.dev/tasks/9.md` |
| `flow/{SPEC,DECISIONS,FACTS,history}.md` | `.dev/{SPEC→tasks/10/10.1/SPEC.md, остальное — в корне}` |
| `flow/watch/watch-tui/` | `.dev/tasks/10/10.1/` |
| `flow/watch/polish/` | `.dev/tasks/10/10.2/` |
| `flow/watch/cache-tok-temp/` | `.dev/tasks/10/10.3/` |
| `flow/engine/0.4.6/` | `.dev/tasks/11/11.1/` |
| `flow/external/` | `.dev/external/` |

Старые ссылки в закрытых артефактах (`tasks/*.md`, отчёты ролей) не
переписывались — читать через эту таблицу.
