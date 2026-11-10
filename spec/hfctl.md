# Спецификация UX / CLI: hfctl (установка и управление hipfire-сервером)

Статус: **принята к реализации** (2026-11-08). Все решения ниже согласованы
с пользователем; фактические цифры проверены на тестовых машинах (Strix Halo gfx1151,
hipfire 0.4.5) и по upstream-докам (`docs/SERVE.md`, `docs/MODELS.md`).

## 1 · Цели и принципы

1. Путь новичка — **4 команды от clone до работающего сервера с автозапуском**.
2. Ровно **три именованные конфигурации** (профиля). Переключение — одна
   команда, действует сразу и после ребута (конфиг автозапуска заменяется).
3. Никаких сюрпризов: скачивание только с предварительным «нужно X GB»,
   несовместимое железо отсекается **до** трафика, цифры в сообщениях об отказе.
4. Каждой сценарий — одна команда; состояние «что крутится и что будет после
   перезагрузки» видно одной командой.
5. Официальный контейнер `ghcr.io/warpfront/hipfire` + официальный compose —
   никаких форков движка; hfctl только конфигурирует и администрирует.

## 2 · Дистрибуция и первичная установка

Репозиторий на GitHub (public). README начинается с quickstart:

```bash
git clone https://github.com/<org>/hfctl.git
cd hfctl
./install.sh              # кладёт дерево hfctl в стек + симлинк в ~/.local/bin (без sudo)
hfctl install             # preflight → модели → конфиг → старт → smoke → автозапуск
```

- Единственный путь — `git clone` + `./install.sh` (этап 8: curl-режим и
  «одной строкой» УДАЛЕНЫ, решение пользователя 2026-11-10).
- `install.sh` — **только** bootstrap: копирует `hfctl`, `lib/`, `tpl/` в
  `~/hipfire/` (бинарь в стеке, `~/.local/bin/hfctl` = симлинк), проверяет
  PATH (не в PATH → печатает строку для `.bashrc`/`.profile`), печатает
  следующий шаг. Больше ничего. Запуск вне дерева (рядом нет
  `hfctl`+`lib/`+`tpl/`) — внятный отказ с текстом и rc 1.
- `hfctl` НЕ однофайловый (этап 8): диспетчер `hfctl` (env-конфигурация +
  `source` модулей + dispatch) + `lib/*.sh` (логические модули) + `tpl/`
  (все шаблоны: compose-yaml, systemd-юниты, `.env`, python-помощники,
  bench-фикстура). Дистрибуция и обновление — целым деревом: повтор
  `install.sh` из того же клона идемпотентен, свежий клон → `install.sh` =
  обновление (AGENTS правило 5; install.sh перезаписывает ровно
  `hfctl`+`lib/`+`tpl/`, остальное в стеке не трогает).
- Все артефакты инсталляции — в `~/hipfire/` (диспетчер `~/hipfire/hfctl` +
  `lib/`, `tpl/`, модели `~/hipfire/models/<сет>/` per-сет, состояние
  движка per-профиль `~/hipfire/profiles/<профиль>/{config,kernel}` (этап 7:
  явные bind-маунты вместо named volumes; disk-тир кэша —
  `profiles/<профиль>/config/session-cache/`), compose-файлы, `.env`, логи).
  Вне каталога: systemd-user юниты, образ ghcr, podman network,
  `limits.d/99-<user>-memlock.conf`, группа render, linger.

## 3 · Карта команд

| Команда | Действие |
|---|---|
| `hfctl install [--profile P] [--port N] [--bind A] [--models-dir D] [--yes] [--no-autostart]` | Развернуть «с нуля или поверх»: preflight → скачивание нужного профилю → конфиг-профиль → старт → health → smoke → **автозапуск включается** (если не `--no-autostart`). Идемпотентна: повтор продолжает/чинит, не начинает заново |
| `hfctl use <profile>` | Переключиться на профиль: проверка железа → ленивый добор недостающих моделей (с вопросом и цифрами) → конфиг → `up -d --force-recreate` → health → smoke. Конфиг автозапуска заменяется новым профилем. Ничего не удаляет |
| `hfctl status [--json]` | Активный профиль, health, **фактически принятый батч-роут**, что скачано, режим автозапуска, версия образа |
| `hfctl logs [-f] [N]` | Логи контейнера сервера (по умолчанию хвост N=50) |
| `hfctl watch [--interval N]` | Живой наблюдатель обработки (дефолт N=2 c): поллинг `/stats` + `/metrics`, строка только на ИЗМЕНЕНИИ видимых счётчиков — `очередь` (`queue_depth`), `обслужено` (`requests_served`, дельта), `done: <tok/s>` (`recent_tok_s`, скорость последнего завершённого запроса), `кэш: <tokens> (+delta)` (`hipfire_cached_prompt_tokens_total` из `/metrics` — кумулятивный счётчик реюза сессийного кэша), `ошибки` (только когда >0), температура GPU с хоста (max по AMD-картам из `/sys/class/drm/card*/device/hwmon`, `GPU: ?` если не видно). В простое — heartbeat раз в ~60 c (`обменов нет…`); при долгой генерации
(когда `served` минутами не меняется) — `обработка идёт (очередь: N…)` тем же тиком; сервер недоступен — сообщение раз в ~30 c, восстановление без перезапуска; первую строку печатает сразу. Выход Ctrl-C. Печатает факт «обработка идёт» там, где `podman logs` молчит (движок не логирует жизненный цикл запросов) |
| `hfctl on` | Включить автозапуск (юнит+таймер+linger) и поднять стек |
| `hfctl off` | Остановить стек **и** снять с автозапуска (юниты disable, вотчдог выключен, linger off). Файлы, модели, образ целы |
| `hfctl uninstall [--purge-models] [--purge-image]` | Полная зачистка: контейнеры, сеть проекта, state-каталоги `profiles/` + legacy-вольюмы, юниты, limits.d, маркеры, `~/hipfire` (модели при сохранении переезжают и возвращаются). Подтверждение с перечнем; по умолчанию модели и образ щадит |

Вспомогательные:

| Команда | Действие |
|---|---|
| `hfctl doctor` | Только диагностика (без записи): ОС, /dev/kfd, GPU, RAM-пул, группа render, memlock, порт, кто держит gpu-lock, podman/podman-compose, модели на диске vs профили |
| `hfctl models` | Что скачано (файл, размер, sha-статус), что требуется каждому профилю, свободное место |

Скрытые синонимы (не в help/README, совместимость с прежними заметками):
`up`→поднять сейчас, `down`→стоп сейчас (маркер), `mode X`→`use X`.

**Всего 7 команд повседневного цикла + 2 диагностики.** Автономная команда
`autostart/noautostart` исчезает — её место заняли `on/off`.

## 4 · Модель состояний

Два независимых переключателя; каждая команда честно говорит, какой трогает:

1. **Профиль** (`install --profile` / `use`) — что и как крутится.
   Канонический профиль пишется в стек (`~/hipfire/.env`: `HFCTL_PROFILE`);
   `install`-повтор, boot-юнит и вотчдог поднимают именно его.
2. **Включён/выключен** (`on` / `off`) — поднимать ли при загрузке.
   `off` выключает и boot-юнит, и вотчдог-таймер (механизм маркера
   `.hfctl-stopped` остаётся внутренней защитой, пользователю не виден).

`hfctl status` первой строкой:

```
профиль: 27b-single (по умолчанию mq4-xts; mq6-xt hot-swap) | автозапуск: вкл | healthy: ok
```

## 5 · Профили

| id | Модель(и) | Движок | Порог пула памяти |
|---|---|---|---|
| `27b-single` ⭐ default | `qwen3.8:27b-mq4-xts` (default в /v1/models) + `qwen3.8:27b-mq6-xt`, draft `dflash-mq4` | singleton + DFlash, serial FIFO | ~60 GiB (Strix Halo 64 GB проходит) |
| `27b-slots` | те же обе | `multi_slot` 2×262144 (HOL-изоляция; −42% соло / −24% агрегат — принято осознанно) | ~60 GiB |
| `flash-multi` | `qwen3.8:flash-next-mq4-xts` (split base 70.9 GB + общий PLE sidecar `ple-q4`, стримится с диска) | **VMM continuous batching** (fn-lanes) | **≥ 80 GiB** (72 GB — минимум реестра на базу; запас на lane store/OS/контейнер) |

Конфиг-наборы ключей движка:

- `27b-single`: `memory.max_seq=262144`, `speculation.dflash=on` (+env
  `HIPFIRE_DFLASH_DRAFT`, контейнерный путь), `serve.vmm_batch=true`,
  `serve.continuous_batch_size=4`, `serve.batch_nonexact=true`,
  `serve.multi_slot=false`, `memory.session_cache_disk_bytes=34359738368`.
- `27b-slots`: `serve.multi_slot=true`, `serve.multi_slot_slots=2`,
  `serve.multi_slot_ctx=262144`, `serve.continuous_batch_size=1`,
  `serve.vmm_batch=false`, `memory.max_seq=262144`.
- `flash-multi`: `serve.vmm_batch=true`, `serve.continuous_batch_size=4`,
  `serve.batch_sampled=true` (он default on), `serve.multi_slot=false`,
  `memory.max_seq=262144`, `speculation.dflash=off` (у flash свой native MTP;
  роут lanes решает сам движок).

Основание (docs/SERVE.md, секция «Flash-Next exact lane batching (qwen4,
arch 16)»): concurrent Flash-Next запросы «share one trunk step on the exact
fn-lanes route… every committed token and state byte per request is identical
to that request run alone on the singleton route»; включается парой
`vmm_batch=true` + `continuous_batch_size>=2`; при отказе — лог
`qwen4 lanes refused: <reason> — fallback to sequential` (сервер не падает).
Multi_slot в SERVE.md назван «the legacy route»; VMM-batching — магистраль
(#897 merged; #1013, #1050 open). Статус роута в 0.4.5: default off,
experimental — см. §7 про отображение фактического роута.

## 6 · Гейты железа (отказ до скачивания, с цифрами)

Проверяются в `install` и в начале `use`:

1. Ubuntu/Debian — иначе выход.
2. `podman` + `podman-compose` есть — иначе команда установки (apt, sudo точечно).
3. `/dev/kfd` + `/dev/dri/renderD*` — иначе выход («нужен AMD GPU с ROCm»).
4. **RAM-гейт профиля**: пул (MemTotal для APU-сборок) против порога профиля.
   Для flash текст отказа:
   ```
   ERROR: профиль flash-multi требует ≥80 GiB единого пула памяти
          (flash-next mq4-xts: 70.9 GB резидентно целиком; offload на APU
           не добавляет ёмкости — это та же память; + lane store для батча).
          На этой машине: <N> GiB. Доступные профили: 27b-single, 27b-slots.
   ```
   Жёсткий блок (решение пользователя). Порог — константа в шапке hfctl,
   уточняется живым тестом на 128 GB-машине.
5. Порт не занят; предупреждение, если gpu-lock держит другой процесс
   (`/run/lock/hipfire/gpu-pci-*.lock`, эксклюзивен на карту).

## 7 · Отображение фактического режима (обязательно)

Роут может вежливо деградировать — значит UX обязан показывать реальность, а
не желание:

- `use flash-multi` после smoke читает load-признаки (`/health`, логи
  `spec:`/`lanes`/`continuous_batch_route`) и печатает одно из:
  `lanes: vmm, cbs=4 (exact)` / `⚠️ vmm lanes refused на этом GPU — сервер
  работает serial (fallback)`.
- `status` включает поле батч-роута и режим спекуляции (`dflash τ` — если
  доступно, иначе `spec:` из лога загрузки).
- Аналогично `27b-slots`/`27b-single`: мода из `/health` (`multi_slot: true/false`).

## 8 · Скачивание и идемпотентность

- `install` в 27b-профиле качает **обе кванты сразу** (~34 GB + draft
  ~1.2 GB) — профиль заявляет hot-swap, обе должны лежать на диске.
- `use` добирает только недостающее: перед началом —
  `нужно скачать 70.9 GB (+7.5 GB PLE), есть 0, свободное место X — продолжаем? [Y/n]`
  (`--yes` / неинтерактив без TTY: авто-да, но цифра напечатана).
- Ничего не удаляется при смене профиля; мусорные осиротевшие модели — только
  руками или `uninstall --purge-models`.
- Загрузка — через `hipfire pull --yes` (init-контейнер), sha256-верификация,
  повторные файлы пропускаются (уже так).

## 9 · Прочие UX-требования

- **Нумерованные этапы**: `[3/7] скачиваю qwen3.8-27b.mq4-xts (14 GB) …`.
- **sudo ровно в двух местах** (группа render, limits.d), с объявлением до
  и человеческим сообщением о перелогине/ребуте: «шаг 2 из 2: ребут →
  повтори ту же команду» (exit-код 42 остаётся внутренним механизмом).
- **Финальный блок install**: адрес `http://<IP>:<port>`, пример клиента
  (`base_url: http://<IP>:11435/v1`, модели из `/v1/models`), как сменить
  профиль (`hfctl use …`), как остановить (`hfctl off`), как снести
  (`hfctl uninstall`).
- Нечётные аргументы — внятная ошибка со списком профилей, а не usage-dump.
- Выход с ненулевым кодом при: откате гейта, падении health (с последними
  строками лога в stderr), отказе smoke.

## 10 · Отличия от текущего hfctl (объём работ)

1. Новый `install.sh` + README с quickstart (в репо).
2. Таблица профилей вместо пар `--mode/--model`: константы
   `profile_<id>` = (модели, draft, ключи конфига, порог RAM, expectation роута).
   Перенос логики `_config_prod.sh`/`mode()` в один массив.
3. `use` = прежний `mode` + канонический `HFCTL_PROFILE` + ленивый pull
   недостающих моделей + smoke + проверка фактического роута (§7).
4. RAM-гейт в install/use (§6).
5. `off` = прежние `noautostart`+стоп одной командой; `on` = autostart+up.
   `up|down|mode` — скрытые алиасы.
6. `status` — поле профиля и фактического батч-роута; `--json`.
7. Дефолт модели 27b-профиля меняется с mq6 на **mq4** (`HIPFIRE_MODEL=
   qwen3.8:27b-mq4-xts`); mq6 остаётся скачанной и доступной hot-swap'ом.
8. `flash-multi` конфиг + скачка split base + PLE sidecar'ов (init-контейнер
   `pull` тянет их по реестру сам, хардлинки shared-файлов — проверять).

## 11 · План приёмки

- `27b-single ↔ 27b-slots ↔ off ↔ on ↔ use 27b-single` — полный цикл на тестовой машине (60 GiB Halo),
  каждый шаг: health + smoke + «что будет после boot» (содержимое юнита/env).
- `use flash-multi` на 60 GiB-машине проверяется **как отказ с цифрами** (60 GiB).
- Ребут-приёмка после переключения профиля: загрузился именно новый профиль.
- `uninstall` после всех переключений — «как будто никогда не было».
- Холодный install на голой машине — первый боевой (когда появится).

## 12 · Открытые вопросы (не блокируют реализацию)

1. ~~Точный порог RAM для flash-multi (80 GiB — оценка) и поведение на
   gfx1151 128 GB: примут ли qwen4-lanes этот GPU — проверить живым тестом.~~
   **ЗАКРЫТО этапом 4 (2026-11-08, живой тест на 128 GB Halo)**: qwen4 fn-lanes ПРИНЯТЫ на
   gfx1151 (lanes=4, spec=mtp K=7, sampled=true); порог 80 GiB подтверждён
   живым admission (рабочий максимум ~105 GB, запас 25+ GB остаётся).
2. ~~Draft/sidecar-реестр для flash (нужен ли отдельный dflash-черновик —
   судя по докам, у flash native MTP, dflash выключен).~~ **ЗАКРЫТО**:
   native MTP K=7 + n-gram copy lane поднимаются сами, dflash off — верно.
3. Имя/URL публичного репозитория и org (`<org>` в quickstart выше).
