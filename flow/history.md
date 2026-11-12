# History — hfctl flow

- 2026-11-12: blackboard открыт; блок «Development protocol: dev-flow» добавлен в AGENTS.md hfctl.
- 2026-11-12: факты по источникам данных (метрики 0.4.5, /stats, sysfs, текущий cmd_watch) сверены оркестратором по исходникам → FACTS.md; 3 решения пользователя (D1–D3) + 2 оркестратора (D4–D5) → DECISIONS.md; SPEC.md (watch-tui) создан из ТЗ пользователя.
- 2026-11-12: fork=design-heavy (новый UI-формат, два рендерера, контракт `hfctl watch`) → architect. Scout не нужен: факты уже собраны оркестратором (несколько источников, цитаты в FACTS.md).
- 2026-11-12: architect сдал task.md (Design: architect); блокирующих open questions нет (одна неблокирующая пометка: plain-строка без `recent_tok_s`, заменяется live decode Δcompletion). → developer (round 1).
- 2026-11-12: developer round 1 сдал dev-report.md (watch_tui.py новый; cmd_watch переписан; gpu_temp/watch_stats.py удалены; доки обновлены; внутренние тесты зелёные). Пометка разработчика: расхождение таблицы task.md «×35 с → 1 строка» с текстом «первая сразу + раз в 30 с» — реализовано по тексту (35 с → 2 строки); тестеру проверять периодичность. → tester (round 1).
- 2026-11-12: tester round 1 → test-report.md, verdict BLOCKED-EXTERNAL: внутреннее всё зелёное (регрессия, selfcheck 15/15, pty-чек 5 блоков/клавиши/деградация/TERM-фолбэки/недоступность, plain-периодичность Δ=30 с без дублей; расхождение task.md подтверждено как не-дефект); EXP-001..003 созданы в flow/external/ (bash -n ok), ждут GO. → оркестратор: пакетный запрос к пользователю (какая машина + путь доставки нового бинаря).
