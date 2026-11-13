# STATE — hfctl watch-tui (dev-flow)

- Сабстэдж: `watch/watch-tui`
- Статус: **ЗАКРЫТ (2026-11-13)** — reviewer APPROVED round 3 (scope-limited по
  блокирующему #4); tester PASS round 3 (первый чистый); EXP-001..003 PASS на
  машине B (действительность retest подтверждена поимённо)
- Следующий шаг: закрытие оркестратором — коммиты (продукт + blackboard),
  статусный коммит `spec/state.md` (строка этапа 6 под новое поведение watch,
  DoD 11), обновление доков hflab, пуш GitHub (пользователь, с хоста)
- Внешние эксперименты: EXP-001 (TUI по SSH), EXP-002 (plain-пайп),
  EXP-003 (plain не портит TTY) — **PASS (2026-11-13)**; реальные результаты —
  в hflab (D10, правило 7), в репо — заглушки.
- Бэклог (некритичные, не блокирующие): ширина sparkline (W//2−4 → max(4,
  W//2−18)), дубль-строка seed/live, целочисленное форматирование GPU
  temp/power, pre-existing usage rc=0 vs doc rc=1, «KV pages: -» вне
  slot-режима — в dev-report.md (backlog) и review.md (non-critical).
