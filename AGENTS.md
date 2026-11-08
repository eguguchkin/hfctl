# hfbox — настройка и деплой сервера hipfire

Проект умеет поднимать сервер hipfire в нужной пользователю конфигурации
на **чистой машине** (и поддерживать уже развёрнутое состояние на che-evo).
Язык ответов — русский.

## Целевая конфигурация (прод, 2026-11-07)

| Параметр | Значение |
|---|---|
| Модель | `qwen3.8:27b-mq6-xt` (+ draft sidecar `qwen38-27b-dflash-mq4.hfq`, явный env — см. DFlash-wiring) |
| Образ | `ghcr.io/warpfront/hipfire:0.4.5` (публичный на ghcr; теги 0.4.3…0.4.5 + latest) |
| `memory.max_seq` | 262144 |
| Спекуляция | `speculation.dflash=on` + `HIPFIRE_DFLASH_DRAFT` env (mq6-xt не объявляет sidecar в реестре; MQ4 draft — рекомендованный контроллер) |
| `serve.vmm_batch` | true (деградирует в serial FIFO на gfx1151 — см. «Факты о движке») |
| `serve.continuous_batch_size` | 4 |
| `serve.batch_nonexact` | true |
| Bind | `0.0.0.0:11435`, **без** API-ключа (LAN) |
| `memory.session_cache_disk_bytes` | 32 GiB (на qwen3.5 инертен — см. факты) |

### DFlash-wiring для mq6-xt (важно при смене тега)

Реестр объявляет `speculation.dflash=auto` только для тегов с dflash-sidecar
(`qwen3.8:27b-mq4-xts` и т.п.). У `mq6-xt` sidecar не объявлен, а схемный
default `off` → включаем явно: `config set speculation.dflash on` (сделано в
`config_prod.sh`) + путь черновика env'ом `HIPFIRE_DFLASH_DRAFT`
(пишется в `compose.local.yml`, канон против legacy `developer.dflash_draft`).
Проверка: load summary `spec: dflash (draft …, block 8)`.

Ограничения пользователя (неизменные): не выходить за рамки обычного юзера
(sudo только точечно), запуск через официальный контейнер ghcr, без «плана А»
(хостовой сборки), параллельность важна (но серийный DFlash выигрывает у
multi-slot — см. факты).

## Хост-профиль che-evo (Strix Halo) — эталонная машина

- `ssh -i ~/.ssh/strix_halo_key -o BatchMode=yes hipfire@192.168.1.254 'bash -s' <<'EOF' … EOF`
  — единственный надёжный паттерн для удалённых shell-скриптов.
- Ubuntu 26.04.1, kernel 7.0.0-38; AMD Ryzen AI MAX+ 395 (16C/32T);
  GPU Radeon 8060S = **gfx1151**; NPU XDNA2 `/dev/accel/accel0` (root:render).
- Память: единый пул ~60 GiB (каталожные «68.7 GB VRAM / 64 GiB SKU»);
  swap 8 GiB. `vram_total=2GiB` в GTT — норма для Halo.
- podman 5.7.0 rootless; **нет** compose-провайдера — ставить
  `podman-compose` 1.5.0-2 из apt.
- Юзер `hipfire` НЕ в группе `render` → `sudo usermod -aG render hipfire`
  (только `che` в ней из коробки).
- memlock hard limit из коробки 8 MiB → нужен
  `/etc/security/limits.d/99-hipfire-memlock.conf`:
  `hipfire soft/hard memlock 1318060032` (нужно NPU-trunk'у; проверяется
  `hipfire doctor --npu`).
- Имя контейнеров: `hipfire_hipfire_1` (serve) + `hipfire_hipfire-init_1`
  (puller, exited 0).
- Rootless-нюанс: если каталог моделей недоступен на запись uid 1000 в
  user namespace, контейнер уходит на container-root (печатает
  предупреждение) и продолжает работать.

## Хост-профиль che-FAEX1 (192.168.1.249) — вторая машина, 128 GB Halo

- Тот же юзер `hipfire` (uid **1001**, в sudo), тот же ключ `strix_halo_key`.
- Ubuntu 26.04.1; Strix Halo **gfx1151** (тот же GPU, что che-evo);
  пул MemTotal 128.6 GB (122 GiB); /home 1.7T (1.3T свободно);
  /dev/kfd + card0 + renderD128.
- podman 5.7.0 есть, podman-compose — ставить (hfctl делает сам).
- Сосед: контейнер `gufo-qwen-flash` юзера `che` (uid 1000, :8080) —
  может держать ~113 GB пула; перед этапом 4 ПРЕДУПРЕДИТЬ пользователя,
  он останавливает gufo сам (не трогать руками); старт только при
  MemAvailable ≥ ~100 GiB.
- Этап 4 (spec/plan.md): flash-multi E2E, lanes-судьба на gfx1151+128 GB,
  калибровка порога RAM.

## Деплой-механика (источник: живой стек на che-evo)

- Директория стека на хосте: `/home/hipfire/hipfire` (копия репо ~500 MB,
  можно без `.git`). Источник для tar|ssh — worktree репозитория hipfire.
- **Рабочая команда всегда:**
  `podman compose -f compose.yml -f compose.halo.yml -f compose.local.yml …`
  **podman-compose НЕ читает `COMPOSE_FILE` из `.env`** — в -f перечислять
  явно всегда (строка в .env безвредна, но не работает).
- compose-файлы репозитория: `compose.yml` (anchor `x-hipfire-engine`,
  init-сервис тянет модель `command: pull --yes`, verify SHA-256 уже внутри),
  `compose.halo.yml` (NPU `/dev/accel` + memlock ulimits 1318060032),
  `compose.local.yml` (маунт `benchmarks/prompts` → `/prompts:ro`).
- `.env` прод: `HIPFIRE_MODEL=qwen3.8:27b-mq6-xt`, `HIPFIRE_PORT=11435`,
  `HIPFIRE_BIND=0.0.0.0`, `HIPFIRE_MODELS_PATH=/home/<user>/models/hipfire`,
  `HIPFIRE_IMAGE=ghcr.io/warpfront/hipfire:0.4.5`,
  `HIPFIRE_IMAGE_TARGET=full`.
- **На чистой машине модели скачиваются самим compose-стеком**
  (hipfire-init тянет модель + sidecars и верифицирует SHA-256;
  pull идемпотентен, уже верифицированные файлы пропускает).
  На che-evo модели уже лежат в `/home/hipfire/models/hipfire`
  (container view: `/home/hipfire/.hipfire/models`) — sha256 сверены:
  - `qwen3.8-27b.mq6-xt` `9d472ddc…c8b2f` (21385849856 B) — **прод с 2026-11-08**
  - `qwen3.8-27b.mq4-xts` `3e38ccba…f8ae` (14987185152 B) — оставлен как откат
  - `qwen38-27b-dflash-mq4.hfq` `d0a74a23…401bc` (draft sidecar, общий)
  - `qwen3.8-27b.mtp` `f0d46d07…32e`, `qwen3.8-27b-vision.hfq` `269457cb…875c9`
- Контейнер во время деплоя может печатать предупреждение
  «models is not writable by uid 1000 …; running as the container root» —
  это безвредно, стек продолжает работу.
- Размеры decimal (MB=10^6). `ls -lh` показывает MiB/GiB: 15 GB файл виден
  как `14G` — это НЕ недокачивание. Проверять md5, не размер.
- GPU-мемлок: `/dev/kfd`, `/dev/dri`; NPU — `/dev/accel` (из compose.halo.yml
  — опционально: сервер работает и без него, но мемлок-лимит всё равно
  нужен).
- Автоматизация: см. `scripts/deploy_hipfire.sh` — он делает всё это сам
  (host-prep → repo → .env → compose.local.yml → config → up → health → smoke).

## Конфиг сервера (контроль-плейн)

- Живой (live) конфиг движка лежит в named volume `hipfire-config` (путь в
  контейнере `/home/hipfire/.hipfire`).
- Применение **one-shot** (движок может быть выключен):
  ```
  podman run --rm -v hipfire-config:/home/hipfire/.hipfire \
    ghcr.io/warpfront/hipfire:0.4.5 hipfire config set <key> <value>
  ```
  (в compose-стеке volume называется `hipfire_hipfire-config` — то же самое
  volume, префикс проекта; можно использовать оба имени при podman).
- Прод-набор ключей (источник истины — `scripts/config_prod.sh`, там
  фиксированный список):
  `memory.max_seq=262144`, `memory.session_cache_disk_bytes=34359738368`,
  `serve.vmm_batch=true`, `serve.continuous_batch_size=4`,
  `serve.batch_nonexact=true`, `serve.multi_slot=false`,
  `serve.multi_slot_slots=4` (запас), `serve.multi_slot_ctx=262144`.
  DFlash вручную не конфигурируется: `qwen3.8:27b-mq4-xts` — Qwen3.8-27B tier,
  registry сам ставит `speculation.dflash=auto` (present draft → fire).
- После смены конфига — recreate стека
  (`podman compose -f … -f … -f … up -d --force-recreate`) и ждать health
  (full быть healthy ~70–120 c; на первый pull модели — минуты).

## Эксплуатация / диагностика

- Первая точка при непонятках: **`podman logs -t hipfire_hipfire_1`**
  (метки времени через `-t`).
- Health endpoint: `curl http://127.0.0.1:11435/health` — `loading_model`
  НЕ null => ещё грузится; null + `status: ok` + `model: qwen3.8:27b-mq4-xts`
  => готово. При рестарте full-stack даёт 70+ c.
- Смоук-запрос: модель отвечает 20–60 tok/s на прозаических prompt'ах;
  DFlash по логам `dflash:true`.
- Автозапуск: systemd --user unit `hipfire-compose.service` (oneshot,
  RemainAfterExit, TimeoutStartSec=900, WorkingDirectory=/home/<user>/hipfire).
  Обязательно `loginctl enable-linger <user>` (Linger=yes) — без linger
  контейнер убивается SIGTERM при выходе юзера; на che-evo это уже один
  раз воспроизводили.

## Грабли (история, чтобы не повторить)

1. **reasoning_effort из реестра съедает короткий max_tokens**: модель из
   реестра носит `reasoning_effort=medium` — на клиентах с max_tokens<400
   это даёт RUNAWAY/EMPTY (thinking-бюджет съедает токены). Решения:
   в запросе выставлять `reasoning_effort:"none"` (или low) для коротких
   ответов, либо давать max_tokens ≥ 400.
2. **serve_harness.py требует КОНТЕЙНЕРНЫЙ путь модели**
   (`/home/hipfire/.hipfire/models/qwen3.8-27b.mq4-xts`), иначе 404. Режим
   флагом `--mode battery|chain` (не позиционный). Общий класс ошибки: ЛЮБОЙ
   путь к файлу модели, который видит контейнер (env `HIPFIRE_DFLASH_DRAFT`,
   аргументы harness), — контейнерный (`/home/hipfire/.hipfire/models/...`),
   т.к. host-каталог смонтирован туда (hfctl наступил дважды-подобное).
3. **Prompt-фикстура**: `benchmarks/prompts/merge_sort_thinking_off.txt`,
   md5 `253c7ac5`. Ничего не редактировать в ней — любая правка байтов
   меняет md5 и τ. Для сравнений — только с зафиксированным хешем.
4. par_test: перед запуском чистить старые `resp_N.json` в OUT-каталоге —
   парсер собирает всё по глоб.
5. **/dev/dri нумеруется по-разному между загрузками** (на che-evo: card0↔card1;
   renderD128 стабилен). Путь устройства запечатывается в конфиг контейнера при
   создании → после ребута `up -d` может вечно падать «crun: cannot stat
   /dev/dri/card0». Лечится `up -d --force-recreate` (в hfctl `_boot` вшит
   автоматом). Gate в boot — по `/dev/dri/renderD*` + `/dev/kfd`, не по card0.
6. **limits.d применяется к session-скоупам только после перезапуска user@**
   (ребут или полный выход всех сессий; при нулевом числе сессий помогает
   отключение linger). Симптом: новый ssh всё ещё с ulimit -Hl=8192.
7. Смена конфига требует `up -d --force-recreate` — рестарт контейнера без
   recreate конфиг из volume может не перечитать корректно (правильный
   путь: config set → force-recreate → wait_health).

## Результаты бенчей (2026-11-07, gfx1151, 0.4.5)

Хост: che-evo; бинари 0.4.5: hipfire md5 `1c3a2859…`, daemon `f3cd6434…`;
prompt merge_sort md5 `253c7ac5`; свежие процессы ×3.
**Внимание: цифры ниже сняты на `mq4-xts`** (baseline до перехода на mq6-xt).

- **DFlash: decode 130.5 tok/s, τ=13.18 (stdev 0.05)** — реален для
  boilerplate-кода (текст глазами чистый; живая проверка 76.2 tok/s τ6.8).
- **AR: decode 14.2 tok/s** (стабильно).

### Эталон 2026-11-08: прод `qwen3.8:27b-mq6-xt` (тот же образ/промпт, ×3)

- **DFlash: decode 75.3 tok/s, τ=11.83** (prefill 84, ttft ~450 мс).
- **AR: decode 9.6 tok/s** (prefill 109, ttft ~349 мс).
- Против mq4-xts: −42%decode; хуже чисто-байтового масштаба (×1.43) из-за
  снижения τ (MQ4-draft на MQ4-таргете обучен: 13.18 → 11.83).
- Артефакты: `.local-analysis/bench_mq6.txt`, `~/bench-runs/`.
- Параллельные замеры FIFO-vs-slots (таблица выше) тоже сняты на mq4-xts;
  относительные выводы для mq6-xt ожидаемо те же.
- **A/B драфта на mq6-xt** (2026-11-08): `qwen38-27b-dflash-mq6.hfq`
  (sha256 `d190ef2f…9015`, скачан) даёт τ=11.83 (тот же) и decode
  **73.5 tok/s против 75.3** у MQ4-draft → прод остаётся на MQ4-draft
  (дефолт в `_config_prod.sh`); переключение драфта: env
  `HF_DFLASH_DRAFT=<путь>` через `config_prod.sh` + recreate
  (`scripts/bench_arms.sh` теперь принимает `HF_ARMS=off|dflash`).
- Проза: τ~2–3, decode 30–60 tok/s.
- battery: attractor=0, retrieval_miss=0. chain: кэш сессий работает
  (cached 442→1323).
- Параллельный API-тест N=4/8: все 200, связные, без перемешивания —
  сериализация FIFO (движок degrades в order lane, см. ниже).

### Замеры параллельности 2026-11-07 (`scripts/conc_bench.sh`, ×3 повтора, разброс <1%)

Температура 0, reasoning_effort none, проза+код; метрика wall=curl-время.

| Метрика | Прод serial FIFO+DFlash | multi_slot=2×262144 |
|---|---|---|
| Соло короткий (4 tok) | 0.45 c | 0.44 c (равно) |
| Соло длинный (1000 tok прозы) | **52.3 c (19.1 tok/s)** | 74.5 c (13.4 tok/s, −42%) |
| 2 параллельно (600 проза + 600 код) | PAR_WALL 45.6 c; агрегат **26.3 tok/s**; проза 33.0, код-второй 45.6 | PAR_WALL 60.3 c; агрегат 19.9 tok/s (−24%); проза 60.3, код-второй **28.4** |
| Короткий через 2 c после длинного | **50.8 c** (HOL) | **0.8 c** (изоляция полная) |

Выводы:
- multi_slot выполняет своё обещание ровно в одном сценарии — HOL-изоляция
  (50.8 → 0.8 c, ~60×), и ускоряет «второй по счёту» запрос, если он
  быстрый по природе (код: 45.6 → 28.4 c).
- ПЛАТА: соло-скорость −42% и агрегат −24% против serial+DFlash; слот-маршрут
  на gfx1151 не догоняет singleton DFlash даже со спекуляцией (блок 16).
- Решение (2026-11-07): **прод остаётся serial FIFO + DFlash** (критерий
  «агрегат не ниже одиночного VMM» не выполнен). Переключение на слоты —
  осознанный размен под часы пик: `config set serve.multi_slot true /
  serve.multi_slot_slots 2 / serve.continuous_batch_size 1 /
  serve.vmm_batch false` + recreate (откат — `scripts/config_prod.sh`).
- Замеры: `.local-analysis/conc_prod.txt`, `.local-analysis/conc_slots.txt`.

## Факты о движке (проверяй перед новыми клеймами)

- **VMM-batching для 27B на gfx1151 ОТКАЗЫВАЕТ на загрузке** (лог:
  «VMM flash decode refused: singleton q8 decode uses a gfx1151 route
  without a VMM twin»); код: `rdna-compute/attention.rs::
  vmm_flash_decode_plan` — Q8+gfx1151 = GQA-роут refusal, fp8 = gfx1201-only;
  exact и non-exact проходят один и тот же гейт. Сервер корректно
  деградирует в serial FIFO (`serve.max_queue=64`).
- **GitHub-обзор (2026-11-07)**: инициативы gfx1151-VMM-twin НЕТ — ни open,
  ни merged. Ближайшее: merged PR #897 «admit gfx1100 Exact VMM AR lanes»
  (gfx1100 обошёлся без новых ядер — там singleton q8 идёт через generic-роут
  с готовым twin; gfx1151 требует собственный GQA-twin); open #1013
  (multi-slot VMM paged KV, gfx1100); open #1050 (Glimmer continuous
  batching, риск ребейза в тех же vmm/slots файлах).
- **Оценка порта**: Path A (nonexact Q8Generic) ≈ 1–2 нед (twin-ядра
  уже в `attention_flash_decode_vmm_rows.hip`: VMM_ROWS_Q8_TILE +
  VMM_ROWS_Q8_REDUCE, только admission + sizing); Path B (exact, byte-identical)
  ≈ 2–4 нед (переписывать gfx1151 GQA-тайл в includable-body + registry +
  byte-оракели). Блокеры: #1050 в полёте, планка доказательств как в
  #897, sizing 262K partials.
- **serve.multi_slot** (SCS slot engine, «the legacy route» по SERVE.md, но
  lifecycle=stable в CONFIG.md и активно развивается — swap-тиры, TTL-sweep,
  batched head, embeddings; removal не заявлен) — работает на
  gfx1151 c 27B (ядра в паке: `gemv_hfq4g256_multirow_default_mq4v2`,
  `attention_q8_0_flash_prefill_wmma_gfx11_hd256_paged`,
  `kv_cache_write_q8_0_batched_paged`), НО: (а) 4 слота×262144 отбиваются
  OOM-guard'ом (needs 48.7 GiB >
  MemAvailable 53.75−8 headroom); живой вариант 2×262144; (б) **DFlash в
  слот-режиме РАБОТАЕТ** (dflash_slot.rs, «DFlash2 draft loaded (slots)»,
  блок фиксирован 16 — «multi-slot admits only 16»); строка логи «spec: off
  (no speculator armed)» — артефакт отчёта: на slot-ветке speculator
  заполняется только для MTP (main.rs:1592); (в)
  агрегат НЕ растёт: 2×250 tok параллельно 27.4 c vs 25.7 c последовательно
  (шина LPDDR делится); (г) тайминги per-request в слот-режиме приходят
  null; (д) смысл рычага — **head-of-line изоляция** (короткий запрос идёт
  сразу в своём слоте на 15–40 tok/s вместо ожидания всей длинной
  генерации в FIFO), а не агрегат.
- **qwen3.8-flash-next на 60 GiB Halo НЕ ВЛЕЗАЕТ**: базовый трук 70.9 GB
  (mq4-xts, min 72 GB) / 59.1 GB (mq3-xts, min 64 GB) должен быть
  полностью резидентным, а всего ~60 GiB единой памяти; offload на APU не
  добавляет ёмкости (тот же пул). PLE/n-gram-строки по дизайну живут ВНЕ
  резидентной памяти (sidecar ple-q4 29.1 GB / ple-q8 54.4 GB, стримятся с
  диска), но сам базы не хватает. Влезет только на Halo 128 GB или
  дискретке ≥96 GB.
- **session_cache_disk_bytes для qwen3.5(27B) инертен** (disk tier =
  только Qwen4/Gemma4); кросс-туровой кэш 27B = DeltaNet checkpoint pool
  в GPU-RAM (резерв ~240 MB). Ключ остаётся в конфиге с запасом на будущую
  модель.
- multi_slot и continuous_batch_size>1 взаимоисключающие; dflash_block
  должен resolve в UNBATCHED при multi_slot; n-gram/CASK/adaptive-KV/
  drafter в слот-режиме отклоняются (refused).
- Current best = **DFlash на serial lane**: серийный DFlash 130.5 tok/s —
  максимум сейчас. Параллелизм API-уровня (N клиентов) работает как
  FIFO-очередь: per-request время растёт пропорционально позиции в очереди
  (контент не страдает). FIFO = **head-of-line блокировка**: SERVE.md прямо
  зовёт это «known gap» (запрос, пришедший во время singleton-генерации,
  ждёт её целиком; её TTFT включает чужую генерацию).
- **gpu-lock ЭКСКЛЮЗИВЕН на карту** (gpu_lock.rs: flock
  `/run/lock/hipfire/gpu-pci-<bdf>.lock`, «exclusive, non-blocking»;
  shared-режим только для weight-host). Второй `hipfire serve` на том же
  GPU получает `Claim::Busy(«already reserved by holder PID …»)` и FATAL.
  Обход: `HIPFIRE_LOCK_DIR` в разные каталоги («Different directories do
  not see each other's locks») — unsupported-соседство, каждый процесс
  видит только свой OOM-бюджет.
- **Два сервера на одной Halo = две очереди, одна труба.** Веса ×2
  (~15.6→~31 GB из ~60 GiB; KV стандартного VMM-пути растёт лениво — два
  сервера с 262144 могут ужиться, проверять admission-цифрами). Агрегат не
  удваивается (LPDDR одна), зато свободный сервер держит полный singleton
  DFlash ~130 tok/s.
- **Prefix-кэша между запросами у нашего маршрута нет**: `/health` даёт
  `prefix_cache: false`, `prefix_cache_max_bytes: 0`. Есть только
  session-кэш внутри одного процесса (DeltaNet checkpoint pool;
  `cached_tokens` 442→1323 в chain-тесте). Следствие для мульти-инстанс:
  прокси нужен sticky по conversation-id; «префикс уже на сервере Б» для
  stateless-клиентов не существует — Б всё равно префиллит. Практичная
  политика — мягкая аффинность с переключением при глубокой очереди
  (цена = пере-префилл истории, секунды).

## hfctl — end-user деплой (одна команда на голом Ubuntu/Debian)

`hfctl` (в корне hfbox) — автономный однофайловый CLI для «голого» ПК:
копируется целиком (`scp hfctl user@host:`) и запускается на ЦЕЛЕВОЙ машине
от обычного юзера (не из ocbox, не через ssh-паттерн hfbox-скриптов).
**Вся инсталляция в одном каталоге `~/hipfire/`**: бинарь `~/hipfire/hfctl`
(копия, которой поставлено), модели `~/hipfire/models/`, compose-файлы, .env,
`.hfctl-stopped` (маркер явной остановки), `.hfctl-watchdog.log`.
Вне каталога остаются только: юниты `~/.config/systemd/user/hipfire-compose*`,
image ghcr, podman volumes/network, `/etc/security/limits.d/99-hipfire-memlock.conf`,
группа render, linger.

```
bash hfctl install [--mode single|slots] [--model mq6|mq4] [--slots N]
bash hfctl up | down | status | logs [N] | mode single|slots [N]
bash hfctl autostart | noautostart
bash hfctl uninstall [--purge-models] [--purge-image]
```

- install: префлайт (Ubuntu/Debian, /dev/kfd, apt podman+podman-compose,
  группа render (+перелогин exit 42), limits.d memlock (+ребут exit 42),
  linger) → генерация **встроенных** compose-файлов (upstream hipfire 0.4.5,
  monitoring-профили срезаны) + .env + compose.local.yml (DFlash draft env;
  prompts-маунт, если каталог есть) → pull образа → **обе модели**
  (mq6-xt + mq4-xts) + dflash-mq4 draft → конфиг-профиль через
  `podman compose run --rm --no-deps` (volume проекта гарантирован) →
  force-recreate → wait_health → smoke. Идемпотентен.
- Переподнимание при краше: `restart: unless-stopped` в compose.yml НЕ работает
  для rootless после `compose up -d` (проверено kill-тестом: контейнер остался
  Exited; podmon-наблюдатель не переживает отсоединение, а
  podman-restart.service — только сессионный старт). Поэтому autostart
  ставит **watchdog**: `hipfire-compose-watchdog.timer` (1 мин) →
  `hfctl _watchdog` → если контейнер не running и нет маркера
  `.hfctl-stopped` — `compose up -d`. Явная остановка только через
  `hfctl down` (ставит маркер); `podman stop` вручную вотчдог воскресит.
- noautostart снимает и linger (выключенный сервер не вскакивает при boot);
  файлы/образ/модели целы. uninstall — слоёный: по умолчанию щадит модели и
  образ (--purge-models/--purge-image), снимает контейнеры, volumes
  config/kernels, юнит, limits.d, каталог стека.
- Переменные: HFCTL_IMAGE/_DIR/_MODELS/_PORT/_BIND/_MODEL в шапке файла.

## Скрипты (в этом репозитории)

Все запускаются с локальной машины (контейнер ocbox), они сами делают
ssh на целевой хост. Общие переменные окружения (или переменные в шапке
файла):

| Переменная | По умолчанию | Смысл |
|---|---|---|
| `HF_HOST` | `hipfire@192.168.1.254` | user@host цели |
| `HF_KEY` | `~/.ssh/strix_halo_key` | SSH-ключ |

- `scripts/host_prep.sh` — разовая подготовка хоста (sudo apt podman +
  podman-compose, usermod -aG render, limits.d memlock, enable-linger,
  systemd user unit).
- `scripts/config_prod.sh` — собрать/обновить `.env`, compose.local.yml,
  прод-конфиг one-shot в volume (движок может быть ещё выключен).
- `scripts/deploy_hipfire.sh` — полный деплой на чистую машину:
  host_prep → перенос репо (tar|ssh или git clone) → config_prod →
  compose up → health. «Сервер уже на che-evo» = тот же скрипт,
  шаги идиомпотентны.
- `scripts/wait_health.sh` — до-ready polling с выводом статуса.
- `scripts/smoke.sh` — 2–3 запроса (короткий код + проза) + health,
  проверка dflash:true.
- `scripts/bench_arms.sh` — bench AR vs DFlash (3 прогона each, prompt
  merge_sort_thinking_off.txt через /prompts маунт, JSON в bench-runs/)
  + md5 бинарников.
- `scripts/par_test.sh N` — параллельный API-тест: N одновременных
  запросов; перед гонкой чистит старые resp_*.json.
- `scripts/slot_ab.sh` — A/B «параллель vs сериал» для экспериментов с
  multi_slot (в текущей прод-конфигурации — не запускать, только для
  экспериментов).
- `scripts/slots_mode.sh on [slots=2] [ctx=262144] | off` — переключить
  сервер на слот-движок (HOL-изоляция ценой ~25% агрегата) и обратно на
  прод; делает config → force-recreate → wait_health → печать активного
  режима из /health.

## Порядок работы над задачами hfbox

1. Любое изменение целевого конфига — только через `config_prod.sh` (не
   руками в volume и не через отдельные `config set` из головы без записи
   в скрипт).
2. После любой смены конфига — recreate + wait_health + smoke
   (порядок фиксированный).
3. Язык ответов — русский, ответы подробные.

## Чек-лист «чистая машина»

- [ ] sudo usermod -aG render <user>
- [ ] limits.d memlock (1318060032)
- [ ] apt: podman, podman-compose
- [ ] `loginctl enable-linger <user>`
- [ ] stack dir с compose-файлами + .env (prod)
- [ ] compose.local.yml (prompts ro)
- [ ] one-shot config set (prod-набор) в volume hipfire-config
- [ ] `podman compose -f compose.yml -f compose.halo.yml -f compose.local.yml up -d`
- [ ] wait_health (~70–120 c после pull)
- [ ] smoke (3 запроса, dflash:true)
- [ ] systemd user unit enabled
