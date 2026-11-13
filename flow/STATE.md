# STATE — hfctl watch-tui (dev-flow)

- Сабстэдж: `watch/watch-tui`
- Статус: **BLOCKED-EXTERNAL (fix-цикл 2, round 2/3)** — парсер EXP-001
  исправлен (самодиагностика ERROR-ветка); ждёт пуш → pull FAEX1 → перепуск
  EXP-001 (002/003 действительны, продукт не менялся) → reviewer
- Тестер: обязателен; verdict round 1 = BLOCKED-EXTERNAL (внутреннее всё зелёное)
- Следующий шаг: GO пользователя → прогон EXP-001..003 на реальной машине →
  тестер закрывает verdict → reviewer
- Открытые внешние эксперименты: EXP-001 (TUI по SSH), EXP-002 (plain-пайп),
  EXP-003 (plain в файл не портит TTY) — `flow/external/`, ждём GO.
- Пометка: для EXP нужен НОВЫЙ hfctl на машине (текущий — без watch_tui.py);
  доставка — через нормальный путь (commit → clone+install.sh) либо bundle,
  решение за пользователем (какая машина, допустим ли краткий recreate).
