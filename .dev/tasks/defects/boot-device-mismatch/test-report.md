# Test report: defects/boot-device-mismatch

Verdict: **PASS**
- Дата: 2026-11-18, round 0 (первая приёмка). Машины не трогались, ничего не закоммичено.

## Internal checks

| DoD | проверка | результат |
|---|---|---|
| DoD 2 (selfcheck) | `bash .dev/tasks/defects/boot-device-mismatch/selfcheck.sh` → **`selfcheck: 21/21 ok`, rc=0**; повторный прогон — снова 21/21, rc=0 (идемпотентен: mktemp+trap EXIT, поверх не оставляет следов). Скрипт гоняет НАСТОЯЩИЙ диспетчер (`bash hfctl _boot/_watchdog`) через PATH-стабы podman/sleep/date и env-фейк GPU-нод — логика не дублируется | PASS |
| DoD 1 | `bash -n` по всем .sh репо: `hfctl`, `install.sh`, все 11 `lib/*.sh`, selfcheck.sh — чисто | PASS |
| DoD реш.1 (GPU-ready wait) | код `lib/autostart.sh`: константы вверху файла `GPU_WAIT_TIMEOUT=60` / `GPU_WAIT_INTERVAL=2` (:7–8); гейт «kfd И renderD*» (`gpu_present` :22, card* намеренно не смотрится); `gpu_ready_or_die` (:42–52) — по таймауту `die` с диагностикой (kfd есть/нет + `ls /dev/dri`) и подсказкой «amdgpu не поднялся?». Selfcheck (в): rc 1, 0 вызовов up, в stderr FATAL + «GPU-ноды» + «/dev/dri» — «падает как надо», сообщение несёт рецепт разбора | PASS |
| DoD реш.2 (recreate) | `hf_up_devsafe` (:290–303): распознавание = «`inspect` ≠ running И вывод `compose up` содержит `cannot stat` ИЛИ `Failed to create container`» → `podman rm -f` по лейблу проекта → ровно один retry. Максимум **2 попытки up на вызов** (первичный + 1 retry; третьего up в хелпере нет) — сверено с dev-report («ровно ДВЕ попытки») — совпадает. Selfcheck (б): 2 up, 1 rm, rc 0; (е): отказ БЕЗ сигнатуры (pull) — rm НЕ звался (не-девайсное не лечится), цикл `_boot` поднял повторным up | PASS |
| DoD реш.3 (watchdog тихий) | `cmd_watchdog` :391–393: маркер `.hfctl-stopped` проверяется первым, затем `gpu_present \|\| return 0` — тихий уход без записи в лог. Выбор поведения (single-check вместо короткого wait) зафиксирован в dev-report — совпадает с кодом. Selfcheck (г): rc 0, ноль вызовов podman, лог не создан; (д): при готовом GPU и девайс-отказе — rm+retry+строка в логе | PASS |
| DoD реш.4 (штатный путь) | Selfcheck (а): GPU готова + up ok → **1 up, 0 rm**, rc 0; (ж): watchdog при running → 0 up, 0 rm, без лога. Ни rm, ни второго up при нормальном подъёме | PASS |
| DoD 4 (dev-report) | механика распознавания (inspect+сигнатура, не rc), число попыток (2), watchdog-выбор (тихий тик), вывод selfcheck (21/21) — всё присутствует и совпадает с кодом | PASS |
| Спека (владелец границы) | `.dev/SPEC.md`: секция boot-механизма переписана под новый трёхслойный механизм, старый «force-recreate со 2-й попытки под flock -w 120» удалён из текста — дельта закрыла спеку, которую трогала | PASS |
| Констрейнты (дифф) | `git diff HEAD --stat`: ровно `.dev/SPEC.md` (30+/11−) + `lib/autostart.sh` (156+/66−); `git status`: + неконтрастный каталог задач. Гунки autostart.sh: шапка (константы+2 хелпера), коммент `hf_up_locked`, новый `hf_up_devsafe`, переписанные `cmd_boot`/`cmd_watchdog` — тела `cmd_up`/`hf_up_locked`/`cmd_on/off/autostart` не тронуты ⇒ **tpl/, install/use-пути не изменены** | PASS |
| Констрейнты (машины) | в dev-report явно: «машины не трогались вообще: ни ssh, ни podman наружу»; в скриптах подэтапа grep по ssh/192.168/внешнему podman — следов нет; selfcheck ходит только в mktemp | PASS |

## Failures (FAIL)

Нет.

## External experiments

| EXP-id | DoD-пункт | статус |
|---|---|---|
| — (живой ребут evo card0→card1 + FAEX-контроль) | brief DoD п.5 — **«вне подэтапа»** | не создан и не требуется на код-подэтапе: в brief п.5 прямо помечен вне DoD кода, в dev-report раздел «Не проверено внутри» помечает его отложенным по D6 (отдельное окно по GO пользователя) с планом подтверждения (юнит активен/healthy без ручного вмешательства, journal `_boot`, `.hfctl-watchdog.log`). Код-подэтап этому не препятствует — BLOCKED-EXTERNAL не ставится |

## Regression (полный, по AGENTS.md)

| проверка | результат |
|---|---|
| `bash -n hfctl lib/*.sh` (все 13 файлов) | OK |
| `python3 -m py_compile tpl/python/*.py` | OK |
| `./hfctl` без аргументов → usage | rc=1, usage напечатан |
| `HFCTL_PORT=1 ./hfctl status --json` (отказ корректный, не краш) | rc=0, `{"… "health": null}` — graceful |

## Non-critical notes (не блокируют)

- dev-report называет дифф «155+/66−», фактический numstat `lib/autostart.sh` = **156+/66−** — косметическая неточность отчёта, не влияет на вердикт.
