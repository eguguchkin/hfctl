# Review: 13.1 hardening — самолечение аномалий подъёма/остановки (5 фиксов)

Verdict: APPROVED
Round: 1
Reviewer: независимый (GLM, review-раунд 13.1); дерево /workspace/hfctl @ 90d1609 +
  незакоммиченный раунд. Машины не трогались, код не правился, коммитов нет.
  Батарея прогнана ревьюером самостоятельно: `bash tests/run_checks.sh` →
  **PASS=28 FAIL=0, rc=0** (подтверждает dev-report 28/0 и test-report).

## Against DoD

| item | met/partial | proof |
|---|---|---|
| Ф1 off-stop | met | `lib/autostart.sh` cmd_off: ровно одна строка `podman stop "$CONTAINER" >/dev/null 2>&1 \|\| true   # fix:off-stop` после `stop_with_marker … \|\| true`, до disable юнитов — байт-в-байт по контракту. `stop_with_marker` не тронут (контракт §13 жив), `down` не тронут, uninstall-safe (`\|\| true`). Позитивы f1_fail/f1_happy зелёные; мутация off-stop роняет сценарий (проверено батареей) |
| Ф2 orphan-heal | met | хелпер `hf_orphan_heal`: регэкс `already in use by [0-9a-f]{12,64}` (awk $5 = ID — верно для реального текста GOTCHAS), `containers-storage delete-container <ID>` (без флагов, по man), кап `HF_ORPHAN_HEALS < HEAL_MAX` (default 2 в шапке), guard «podman inspect ID → не сирота» до инкремента счётчика, Variant B: `command -v containers-storage` → WARN с полной ручной командой. Оба up-пути: locked — захват вывода up + heal + ровно один retry (макс. 2 up на вызов не расширен); devsafe — elif-ветка после девайс-ветки (девайс-команды идентичны, ОДНО лечение на вызов). «Занятый лок → пропуск rc 0» сохранён. rc-проброс финального up сохраняет контракт «сбой compose up убивает cmd_up по set -e» (cmd_up:84, set -euo pipefail hfctl:25 — проверено) |
| Ф3 lock-reclaim | met | `hf_lock_reclaim`: вызов только при неудаче первого `flock -n` в ОБОИХ up-субшеллах (`if ! flock -n 9; then hf_lock_reclaim; flock -n 9 \|\| skip; fi`) — happy-path без лишних процессов; предикаты: fuser на файле лока (fd-семейство) → `etimes > LOCK_STALE_SECS` (default 900 = TimeoutStartSec) → cmdline ~ `podman\|hfctl` → kill -9; нет fuser → `return 0` (тихая деградация к «пропуск»). zombie-держатели отфильтрованы cmdline-предикатом (пустой args не матчится). Позитивы stale/fresh/no-fuser на НАСТОЯЩИХ flock/ps/fuser — зелёные; pre-ассерт «лок реально держится» защищает от пустого прохождения |
| Ф4 pod-infra | met | `hf_pod_pristine`: `podman pod inspect pod_hipfire --format '{{.InfraContainerID}}'`; пусто → warn + `podman pod rm -f pod_hipfire \|\| true`; inspect отказал → no-op (`\|\| return 0`). Вызов в обоих up-субшеллах ДО первого compose up, внутри лока. Позитивы empty/full/absent зелёные (f4_empty ассертит порядок rm < up по строкам журнала) |
| Ф5 containers-conf | met | `tpl/etc/hfctl-containers.conf` — байт-в-байт контент из task.md (2 строки toml + комментарий, ничего лишнего); доставка `install -m 0644` в ДВУХ местах: `write_stack_files` (stack_files.sh) и `cmd_autostart` (строго ДО render_tpl юнитов — порядок в диффе виден); в `sync_tree` доставка НЕ встроена (по контракту); `compose()` — `if [ -f ]`-форма (set -e-безопасна), экспорт только при файле; `Environment=CONTAINERS_CONF=__STACK_DIR__/.hfctl-containers.conf` в ОБОИХ tpl-юнитах. Глобальный ~/.config/containers не упоминается/не трогается |
| Ф6 батарея | met | `tests/run_checks.sh` НОВЫЙ: AGENTS-четыре + инвентарь маркеров + 15 фикс-позитивов + 7 мутаций ×2 направления (orphan-heal на обоих путях; containers-conf — lib и tpl-Environment). Мутационный движок с защитой от дрейфа маркеров («маркер не найден» = FAIL) и bash -n мутанта (падение поведенческое, не синтаксическое). Ф3 — реальные flock/ps/fuser + pre-ассерты. FAIL=0, PASS=28 ≥ 10 |
| Ф7 spec-honesty | met | SPEC.md в том же дельта: §3 on/off дополнены (двусоставная остановка, самолечение §14); §13 lock-фраза → указатель на §14; НОВАЯ §14 с пятью контрактами, константами-крючками и EXP-хвостом. Противоречий код↔спека не найдено: «макс. 2 up», одно лечение на вызов в devsafe, HEAL_MAX=2, порог 900=TimeoutStartSec, guard, Variant B, скоупы CONTAINERS_CONF и «прямые podman-вызовы env не получают» — текст §14 совпадает с кодом |
| Границы | met | `git status/diff`: ровно 8 файлов контракта (+артефакты сабстэджа + tests/). hfctl, install.sh, lib/commands.sh, bench-фикстура, остальные lib — не тронуты. Правило 7 (нет IP/ключей/хостов) соблюдено; ORPHAN_ID в тестах — фейковый hex |

## Риски дизайна (по запросу оркестратора) — все ПРИНЯТЫ

**(а) Ф3 — ложный kill здорового holder'а.** Принято. Механика тройного
предиката: fuser находит только процессы с fd на ЭТОМ lock-файле (семейство
fd-9 up-путей), kill только при etimes > 900 И cmdline ~ podman|hfctl.
Легитимный сценарий >900 с требует, чтобы compose up (образ уже локально:
пулл делает префлайт ДО up — commands.sh:64, models.sh:48; init-pull моделей
идёт в контейнере после detach) висел >15 мин, И параллельная попытка
(up/вотчдог-тик) наткнулась на занятый лок. Вотчдог-тики в первые 900 с
holder'а безвредны (age-предикат). Альтернатива — вечный голод лока
(инцидент, прод вниз ~5 ч) — строго хуже; юнит по TimeoutStartSec=900 всё
равно мёртв, выживший держатель — SIGKILL-выживший KillMode=process. Хвост
«ручной recreate >900 с под нагрузкой» убивается concurrent-попыткой —
осознанный трейд, зафиксирован в SPEC §14 + Risks task.md + dev-report;
ручка подстройки `HFCTL_LOCK_STALE` есть. Норм.

**(б) Ф2 — регэкс против изменения текста ошибки podman.** Принято. Отказ
регэкса деградирует в точности к прежнему поведению: сигнатуры нет → хил
не зовётся → rc up идёт наверх → вызывающий решает (юнит перезапустит,
вотчдог уйдёт тихо). Нет пути, где смена текста ошибки ломает happy-path
или создаёт неверный хил (ID проверяется guard'ом + delete-container без
-f не delete'ет живое). Текст сигнатуры запина GOTCHAS + §14; эмпирическая
перепроверка после обновления пакетов podman — дешёвый EXP-хвост деплоя
(рекомендация в backlog, не блокер).

**(в) Ф5 — Environment на СУЩЕСТВУЮЩИХ стеках.** Принято. Авторитетный
механизм — экспорт в `compose()`: он скоупит env при наличии файла
НЕЗАВИСИМО от возраста юнит-файла, а создание контейнеров в _boot/_watchdog
идёт только через compose() (прямые podman-вызовы путей — inspect/ps/rm/pod
rm — netns не создают). Рендер юнитов происходит в cmd_autostart (`hfctl on`)
и в деплой-окне off→on-цикл приёмки его гарантированно делает. Голый ребут
с новым бинарем и без файла → compose() env чист → поведение байт-в-байт
прежнее (pasta) — это не регрессия, а «фикс ещё не активирован». Окно
несоответствия юнит-файлов безвредно: Environment в юнитах — belt-and-
suspenders поверх compose(), не единственный носитель.

## Blocking

Нет.

## Non-critical notes (backlog, не блокирует)

1. `hf_lock_reclaim` (lib/autostart.sh): инлайн-коммент «нет fuser — пробуем
   lsof» не соответствует коду — lsof-fallback не реализован (унаследован
   из sketch task.md; developer честно задокументировал отклонение в
   dev-report). Либо дописать fallback одной строкой, либо поправить
   коммент; формулировка §14 «нет fuser/lsof — тихая деградация» при этом
   остаётся верной как условие деградации.
2. Note 1 тестера подтверждена по коду: EXIT-trap батареи чистит $TMP, но
   не убивает фоновые holder'ы Ф3 (спят 600 с; на повторных прогонах
   накапливаются). Предложение: kill по pid в конце Ф3-сценариев или в trap.
3. hf_up_locked: угол «compose up rc 0, но контейнер не running, сигнатуры
   нет» → группа `[ inspect = running ] || { heal && …; }` падает и под
   set -e убивает субшелл с rc 1 до `return "$rc"` (на HEAD путь давал rc 0
   и падал позже в wait_health). Итог неудачи одинаков (cmd_up умирает),
   семантика лишь приходит раньше; стоит одной строкой отразить в
   док-комменте функции.
4. Мутация orphan-heal(devsafe) сидит на retry-up строке, а не на elif-ветке
   (маркер на elif ломал бы синтаксис мутанта) — отклонение задокументировано
   developer'ом, защита проверена падением «ровно 2 up». Ок.

## Questions to the spec

Нет. §14 самодостаточен: пять контрактов, константы-крючки, границы
(CONTAINERS_CONF не получает прямой podman; EXP-хвост деплоя). Единственная
натяжка — «fuser/lsof» в §14 при фактическом fuser-only (см. note 1) —
после правки коммента/кода формулировку можно не трогать.
