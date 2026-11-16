# Dev report: engine/0.4.7 — пин образа 0.4.6 → 0.4.7
- Date: 2026-11-16, round 1
- Исполнитель: developer (dev-flow, сабстэдж 12.1)

## Что было сделано

| Scope-пункт (task.md §Design) | Файл:строки | Изменение |
|---|---|---|
| 1. `@type`-комментарий пина | `hfctl:35` | `…hipfire:0.4.6}` → `…hipfire:0.4.7}` |
| 2. Дефолт `IMAGE=` | `hfctl:36` | `IMAGE="${HFCTL_IMAGE:-ghcr.io/warpfront/hipfire:0.4.6}"` → `…0.4.7"` |
| 3. Заголовок модуля | `lib/stack_files.sh:2` | «официальные compose-файлы hipfire 0.4.6» → «hipfire 0.4.7» |
| 4. Golden-пометка | `lib/stack_files.sh:3–6` (was 3–5) | Дополнена: compose.yml/compose.halo.yml в 0.4.7 байт-идентичны 0.4.5/0.4.6 (в 0.4.7: `git diff v0.4.6..v0.4.7` пуст, F-0.4.7.3) → golden'ы валидны и для 0.4.6/0.4.7. Источник факта — F-0.4.7.3 (не recon-файл), по требованию task.md. |
| 5. Пометка у копирования compose.yml | `lib/stack_files.sh:150–152` (was 150) | «(для 0.4.6 байт-в-байт, …)» → «(для 0.4.6 и 0.4.7 байт-в-байт, …)» |

Итого изменённых файлов: 2 (`hfctl`, `lib/stack_files.sh`) — ровно как в
прецеденте 11.1. Поведение продукта не меняется: пин — единственный
параметр; recreate/use будут тянуть тег 0.4.7, `.env`/конфиг/юниты не
зависят от версии (task.md §Design, абзац «Поведение»).

Не тронуто (проверено `git status --porcelain`): `tpl/` (включая
compose- и bench-фикстуру), `install.sh`, `README.md`, `.dev/STATE.md`,
`.dev/history.md`, `.dev/FACTS.md` (изменения этих `.dev/`-файлов —
оркестратор до кода, не моя работа), коммиты (hygiene AGENTS.md).

DoD 3 (секция «Движок 0.4.7» в FACTS.md) — подтверждена как внесённая
оркестратором до кода: `.dev/FACTS.md:92` «Движок 0.4.7 (проверено
оркестратором, 2026-11-16)», F-0.4.7.1…F-0.4.7.6 на `.dev/FACTS.md:93–110`.
Дублировать не стал.

## Как проверено внутренне

| Проверка | Команда | Результат |
|---|---|---|
| Синтаксис (DoD 4) | `bash -n hfctl lib/*.sh` | OK, ошибок нет |
| Python-шаблоны (DoD 4) | `python3 -m py_compile tpl/python/*.py` | OK |
| Usage без аргументов (DoD 4) | `./hfctl` | rc=1 (usage) |
| `status --json` с чанковым PORT (DoD 4) | `HFCTL_PORT=99999 ./hfctl status --json` | rc=0, корректный отказ без краха: `{"profile": "27b-single", "autostart": false, "watchdog": false, "health": null}` |
| Остатки пина 0.4.6 (DoD 1) | `grep -rn '0\.4\.6' hfctl lib/ install.sh README.md tpl/` | Только mandated-пометка байт-идентичности в `lib/stack_files.sh:4,5,6,151` (источник факта, не пин) — ровно ожидаемый остаток по Test strategy task.md. Дефолтного пина 0.4.6 нигде нет; в `hfctl` совпадений 0. |
| Новый пин на месте | `grep -rn '0\.4\.7' hfctl lib/ install.sh README.md tpl/` | `hfctl:35,36` (пин + `@type`) + `lib/stack_files.sh:2,4,5,6,151` (доки). В `install.sh`, `README.md`, `tpl/` пинов нет. |
| Только 2 файла | `git diff --stat` | `hfctl` 4±, `lib/stack_files.sh` 11± (остальное в `git status` — `.dev/`-изменения оркестратора, не моя работа); `tpl/` чисто |
| Bench-фикстура канон | `md5sum tpl/bench/merge_sort_thinking_off.txt` | `253c7ac50857fe6d0e10fb0d2c5e35c0` — канон не тронут (совпадает с 11.1) |
| Diff соответствует §Design | `git diff hfctl lib/stack_files.sh` | 5 точек из task.md, ничего сверх; пометка цитирует F-0.4.7.3 (DoD 2) |

## Не проверено внутренне (внешнее)

- EXP-104 (DoD 5, за оркестратором, GO пользователя): recreate стека с
  дефолтным пином 0.4.7 → healthy → smoke (dflash:true) → bench quick;
  регрессия против бейзлайнов 0.4.6 (машина B quick ≈75.8 tok/s, che-evo
  solo ≈131.0 tok/s / τ13.18; отклонение <5%). Внутренне неподъёмно: нет
  живого контейнера/хоста (hygiene: роли не делают ssh/podman наружу).
  До PASS EXP-104 пин не считается принятым (Risks task.md; 0.4.7 —
  фикс-хэви, F-0.4.7.5/6).
- Фактическая доставка/перезапуск на живых машинах (D12) — за
  оркестратором после APPROVED.

## Известные ограничения / допущения

- Пин в `tpl/env/env.tpl` отсутствует по дизайну (плейсхолдер `__IMAGE__`) —
  как в 11.1, править нечего.
- Остаточные «0.4.6» в `lib/stack_files.sh:4–6,151` — намеренные mandated-
  пометки байт-идентичности (источник факта F-0.4.7.3), не пин; исторические
  упоминания версий в `.dev/` и доках — категория «история», не трогаются
  (brief «Ограничения», прецедент 11.1 п.2).
- Откат без докачки: тег 0.4.6 жив на ghcr, digests моделей идентичны
  (F-0.4.7.2, бейзлайны 11.1) → `HFCTL_IMAGE=…0.4.6`; в коде — revert
  коммита.

## Out-of-scope proposals

- Нет. Всё вне scope (EXP-104, D12-доставка, STATE.md/history.md,
  статусный коммит) закрыто оркестратором по task.md «Вне скоупа».
