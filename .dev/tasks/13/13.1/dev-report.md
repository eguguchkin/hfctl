# Dev report: 13.1 hardening — самолечение аномалий подъёма/остановки (5 фиксов)
- Дата: 2026-11-21 / раунд 1
- Дерево: /workspace/hfctl @ 90d1609 (чистое на старте); контракта придержан 1:1

## Что было сделано

| Фикс | Файл | Суть |
|---|---|---|
| Ф1 off-stop | `lib/autostart.sh` (cmd_off) | после `stop_with_marker … || true` — явный `podman stop "$CONTAINER" >/dev/null 2>&1 \|\| true` (маркер `# fix:off-stop`); контракт stop_with_marker не тронут, down не тронут |
| Ф2 orphan-heal | `lib/autostart.sh` | хелпер `hf_orphan_heal` (ID из сигнатуры «already in use by <12..64-hex>», кап `HEAL_MAX`/`HF_ORPHAN_HEALS`, `command -v containers-storage` → WARN с ручной командой (Variant B), guard «libpod видит ID → не трогать», `containers-storage delete-container <ID>`); интеграция: `hf_up_locked` — захват вывода up в переменную + rc-проброс финального up (контракт «сбой compose up убивает cmd_up по set -e» сохранён), `hf_up_devsafe` — elif-ветка после девайс-ветки (девайс-ветка байт-в-байт прежняя, ОДНО лечение на вызов) |
| Ф3 lock-reclaim | `lib/autostart.sh` | хелпер `hf_lock_reclaim` (fuser → etimes > `LOCK_STALE_SECS` → cmdline ~ `podman\|hfctl` → kill -9; нет fuser — тихая деградация); вставка в ОБОИХ up-субшеллах: `if ! flock -n 9; then hf_lock_reclaim; flock -n 9 \|\| { пропуск; return 0; }; fi` — happy-path без лишних процессов |
| Ф4 pod-infra | `lib/autostart.sh` | хелпер `hf_pod_pristine` (`podman pod inspect pod_hipfire` → пустой `InfraContainerID` → warn + `podman pod rm -f pod_hipfire`; inspect отказал → no-op); вызов в обоих up-субшеллах до первого compose up, внутри лока |
| Ф5 containers-conf | `tpl/etc/hfctl-containers.conf` (НОВЫЙ, ровно EXP-013-контент), `lib/stack_files.sh` (write_stack_files), `lib/autostart.sh` (cmd_autostart, строго ДО render_tpl юнитов), `lib/stack.sh` (compose(): `if [ -f ]`-экспорт — под set -e безопасная форма if), оба `tpl/systemd/*.service.tpl` (`Environment=CONTAINERS_CONF=__STACK_DIR__/.hfctl-containers.conf`) | глобальный ~/.config/containers не трогается; в sync_tree доставка НЕ встроена (по Design) |
| Батарея | `tests/run_checks.sh` (НОВЫЙ) | каркас из gfctl-прецедента: faux-bin PATH-заглушки (podman с журнал+env-строкой CONTAINERS_CONF, containers-storage, systemctl/loginctl/sudo — ничего реального), hf-харнес (субшелл: глобалы диспетчера + source lib + faux-PATH + eval), мутационный движок (копия дерева + `sed /# fix:<имя>/d` + bash -n мутанта + «сценарий обязан упасть») |
| Спека | `.dev/SPEC.md` | §3: строки on/off дополнены (двусоставная остановка, самолечение подъёма); §13: фраза про lock скорректирована (указатель на §14); НОВАЯ §14 «Самолечение аномалий подъёма/остановки» — пять контрактов + константы-крючки + внешний EXP-хвост |

Файлы диффа — ровно перечень контракта: `lib/autostart.sh`, `lib/stack.sh`,
`lib/stack_files.sh`, `tests/run_checks.sh` (новый), `tpl/etc/hfctl-containers.conf`
(новый), оба `tpl/systemd/*.service.tpl`, `.dev/SPEC.md`. Не тронуты: hfctl,
остальные lib, install.sh, README, bench-фикстура, машины (ssh не делался).

## Как проверено внутри

- `bash tests/run_checks.sh` — **ИТОГО: PASS=28 FAIL=0, rc=0**; два прогона
  подряд — счётчик стабильный (идемпотентна). Состав: AGENTS-четыре (bash -n
  hfctl+lib+tests; py_compile с PYTHONPYCACHEPREFIX в $TMP — репо не
  засоряется; bare-вызов usage rc=1; `HFCTL_PORT=1 status --json` —
  корректный отказ, не краш), инвентарь маркеров (5 имён, счёт 1/2/2/2/3),
  по каждому фиксу позитивы (Ф1×2, Ф2×5 включая happy-up и кап и Variant B
  и guard, Ф3×3, Ф4×3, Ф5×2) и мутации ×7 (все: «сценарий упал — защита
  держит»; для Ф2 — обе up-пути на одном мутанте; для Ф5 — два мутанта:
  lib-строки и Environment в tpl-юните).
- Мутационная механика проверена на честность: мутант `lock-reclaim`
  прогнан вручную — удаление затрагивает ровно 2 строки вызова, `bash -n`
  зелёный (падение сценария поведенческое, не синтаксическое).
- Ф3 на настоящих flock/fuser/ps: holder = python3-процесс с argv0
  `podman-compose` (настоящий flock на lock-файле, настоящий etimes,
  busybox fuser контейнера находит его по fd) — семантику блокировок даёт
  ядро. Дополнительно: pre-ассерт «лок реально держится» в каждом Ф3-
  сценарии (сценарий не может пройти пусто).

## Не проверено внутри (внешний хвост, EXP при деплое)

- Живой `hfctl off` при активном pasta-баге: контейнер реально останавливается
  (Ф1) — машины не трогались по контракту.
- Живое воспроизведение storage-сироты → up самолечится (Ф2); убедиться, что
  на машинах есть `containers-storage` (в preflight пакет НЕ добавлялся —
  вне контракта; до этого самолечение = Variant B WARN, поведение прежнее).
- Реклейм на настоящих SIGKILL-выживших systemd-юнита (Ф3): контейнерная
  семантика flock покрыта ядром, юнит-топология — нет.
- Первый pull моделей под slirp4netns — скорость (Ф5 EXP-хвост, план Б —
  host-network).
- `podman pod inspect pod_hipfire` на реальном podman 5.x: имя/поле
  `InfraContainerID` не менялись с окна инцидента (проверить eyeball'ом
  при первом живом up).

## Известные ограничения / допущения

- Sketch из task.md для `hf_lock_reclaim` имел `age=$(ps …)` без `|| true`
  — под set -e исчезнувший между `kill -0` и `ps` процесс убивал бы функцию;
  добавлен `|| true` внутрь command substitution (поведенчески то же на
  happy-пути). Упомянутый в sketch lsof-fallback оставлен на уровне
  комментария (как в sketch: `fuser … || return 0`); батарея покрывает
  сценарий «нет fuser» деградацией.
- Контейнер ocbox — busybox: `flock FD command`-формы нет → holder Ф3 на
  python3 (настоящий flock, argv0-подмена); на проде (util-linux) поведение
  то же — ядро даёт блокировку.
- `hf_up_locked` теперь возвращает rc финального up через `return "$rc"`
  вместо pipe-tail: happy-path rc 0, невылеченный отказ — прежний
  «смертельный» rc (документировано в док-комментарии функции).
- Мутация `orphan-heal` в devsafe сидит на строке retry-up внутри elif-ветки
  (маркер на структурной elif-строке ломал бы синтаксис мутанта) — ассерты
  «ровно 2 up» всё равно роняют сценарий.

## Out-of-scope proposals

- preflight/stack.sh: добавить `containers-storage` в apt-строку
  (`podman podman-compose containers-storage`) — в перечне контракта нет,
  ушло бы в другой сабстэдж; до того Variant B (WARN) — штатный канал.
- Симметрия Ф1 для `hfctl down` (та же экспозиция при pasta-баге).
- `hfctl status`/`doctor`: строка «последнее самолечение» (HF_ORPHAN_HEALS
  / лог) — наблюдаемость после инцидентов.

## Риски

- Ложный kill Ф3: легитимный ручной up > 900 с будет убит (принятый в
  Design риск; образ спиннут — таких up нет).
- slirp4netns может просесть скорость pull (EXP-хвост; graphRoot общий —
  хранилище не форкается).
- Мутационная батарея копирует дерево и sed'ит — при переименовании
  маркеров батарея упадёт «маркер не найден (дрейф)» — так и задумано.
