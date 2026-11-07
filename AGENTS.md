# hfbox — настройка и деплой сервера hipfire

Проект умеет поднимать сервер hipfire в нужной пользователю конфигурации
на **чистой машине** (и поддерживать уже развёрнутое состояние на che-evo).
Язык ответов — русский.

## Целевая конфигурация (прод, 2026-11-07)

| Параметр | Значение |
|---|---|
| Модель | `qwen3.8:27b-mq4-xts` (+ draft sidecar `qwen38-27b-dflash-mq4.hfq` из реестра) |
| Образ | `ghcr.io/warpfront/hipfire:0.4.5` (публичный на ghcr; теги 0.4.3…0.4.5 + latest) |
| `memory.max_seq` | 262144 |
| Спекуляция | DFlash `auto` из реестра (paired-draft вручную включать не надо) |
| `serve.vmm_batch` | true (деградирует в serial FIFO на gfx1151 — см. «Факты о движке») |
| `serve.continuous_batch_size` | 4 |
| `serve.batch_nonexact` | true |
| Bind | `0.0.0.0:11435`, **без** API-ключа (LAN) |
| `memory.session_cache_disk_bytes` | 32 GiB (на qwen3.5 инертен — см. факты) |

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
- `.env` прод: `HIPFIRE_MODEL=qwen3.8:27b-mq4-xts`, `HIPFIRE_PORT=11435`,
  `HIPFIRE_BIND=0.0.0.0`, `HIPFIRE_MODELS_PATH=/home/<user>/models/hipfire`,
  `HIPFIRE_IMAGE=ghcr.io/warpfront/hipfire:0.4.5`,
  `HIPFIRE_IMAGE_TARGET=full`.
- **На чистой машине модели скачиваются самим compose-стеком**
  (hipfire-init тянет модель + sidecars и верифицирует SHA-256;
  pull идемпотентен, уже верифицированные файлы пропускает).
  На che-evo модели уже лежат в `/home/hipfire/models/hipfire`
  (container view: `/home/hipfire/.hipfire/models`) — все 4 SHA-256 сверены:
  - `qwen3.8-27b.mq4-xts` `3e38ccba…f8ae` (14987185152 B)
  - `qwen38-27b-dflash-mq4.hfq` `d0a74a23…401bc` (draft sidecar)
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
   флагом `--mode battery|chain` (не позиционный).
3. **Prompt-фикстура**: `benchmarks/prompts/merge_sort_thinking_off.txt`,
   md5 `253c7ac5`. Ничего не редактировать в ней — любая правка байтов
   меняет md5 и τ. Для сравнений — только с зафиксированным хешем.
4. par_test: перед запуском чистить старые `resp_N.json` в OUT-каталоге —
   парсер собирает всё по глоб.
5. Смена конфига требует `up -d --force-recreate` — рестарт контейнера без
   recreate конфиг из volume может не перечитать корректно (правильный
   путь: config set → force-recreate → wait_health).

## Результаты бенчей (2026-11-07, gfx1151, 0.4.5)

Хост: che-evo; бинари 0.4.5: hipfire md5 `1c3a2859…`, daemon `f3cd6434…`;
prompt merge_sort md5 `253c7ac5`; свежие процессы ×3.

- **DFlash: decode 130.5 tok/s, τ=13.18 (stdev 0.05)** — реален для
  boilerplate-кода (текст глазами чистый; живая проверка 76.2 tok/s τ6.8).
- **AR: decode 14.2 tok/s** (стабильно).
- Проза: τ~2–3, decode 30–60 tok/s.
- battery: attractor=0, retrieval_miss=0. chain: кэш сессий работает
  (cached 442→1323).
- Параллельный API-тест N=4/8: все 200, связные, без перемешивания —
  сериализация FIFO (движок degrades в order lane, см. ниже).

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
- **serve.multi_slot** (SCS slot engine, experimental) — работает на
  gfx1151 c 27B (ядра в паке: `gemv_hfq4g256_multirow_default_mq4v2`,
  `attention_q8_0_flash_prefill_wmma_gfx11_hd256_paged`,
  `kv_cache_write_q8_0_batched_paged`; DFlash2 draft грузится (slots),
  B=16), НО: (а) 4 слота×262144 отбиваются OOM-guard'ом (needs 48.7 GiB >
  MemAvailable 53.75−8 headroom); живой вариант 2×262144; (б) в слот-режиме
  DFlash не armed («spec: off») — decode AR-уровня 14–31 tok/s; (в)
  агрегат НЕ растёт: 2×250 tok параллельно 27.4 c vs 25.7 c последовательно
  (шина LPDDR делится); (г) тайминги per-request в слот-режиме приходят
  null. **Вывод: прод остаётся на «serial FIFO + DFlash».**
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
  (контент не страдает).

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
