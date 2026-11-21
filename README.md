# hfctl — сервер hipfire на Ubuntu/Debian одной командой

`hfctl` ставит и обслуживает [hipfire](https://github.com/warpfront/hipfire)
(LLM-сервер для AMD Strix Halo / gfx11xx, официальный контейнер ghcr) на
голой машине: preflight, скачивание моделей, конфиг, systemd-автозапуск,
вотчдог крашей, переключение профилей — всё от обычного юзера (sudo точечно,
два места: группа render + memlock).

## Быстрый старт

```bash
git clone https://github.com/eguguchkin/hfctl.git
cd hfctl
./hfctl doctor         # (опционально) проверка железа до скачивания
./hfctl on             # сервер: preflight → ~34 GB моделей → конфиг → healthy + smoke → автозапуск
```

Клон и есть стек: код (`hfctl`, `lib/`, `tpl/`) и машинное состояние
(`.data/` — модели, профили, bench-runs; `.env` — канон профиля) живут в
одном каталоге. После первого `./hfctl on` сервер на `http://<IP>:11435`
(LAN, без ключа), автозапуск при загрузке включён, падения поднимает
вотчдог. Повторный `hfctl on` = автозапуск + поднять сейчас; параметры
профиля (`--profile/--port/--bind/--models-dir`) работают только при
первом `on` — дальше их меняет `hfctl use`.

```bash
curl http://<IP>:11435/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.8:27b-mq4-xts","messages":[{"role":"user","content":"привет"}],"max_tokens":400,"reasoning_effort":"none"}'
```

Любой OpenAI-совместимый клиент: `base_url = http://<IP>:11435/v1`,
список моделей — `curl http://<IP>:11435/v1/models`.

## Команды

| Команда | Что делает |
|---|---|
| `hfctl on [--profile P] [--port N] [--bind A] [--models-dir D] [--no-autostart] [--force]` | поднять стек; на пустом клоне — bootstrap (preflight → модели → конфиг → health → smoke → автозапуск, идемпотентно); на развёрнутом — автозапуск + поднять сейчас (флаги-мутаторы запрещены — их меняет `use`) |
| `hfctl use <profile>` | переключить профиль; заменяет конфиг автозапуска — выбор переживает рестарт |
| `hfctl status [--json]` | профиль, health, автозапуск, контейнеры |
| `hfctl logs [-f] [-n N]` | логи сервера |
| `hfctl watch [--interval N]` | живой дашборд (дефолт 2 c): на TTY — TUI с блоками «Движок» (Model/Uptime/Queue/Errors/τ avg/Served/Retries/Cache), «Железо» (GPU freq/GPU load/GPU power/GPU temp/CPU temp), «Скорость» (decode tok/s = последний завершённый запрос, prefill tok/s = среднее гистограммы, sparkline-активность за тик ~60 с), «Память» (RAM (MemAvailable/Total + bar)/Swap/KV pages), «Логи» (сид `--tail 50` при старте + live `podman logs -f`); клавиши: `q` — выход, `+`/`-` — интервал (1..10 c), `p` — пауза логов; минимальный терминал 80×24, при меньшем блоки сжимаются (не краш); в пайп или лог-файле — строка полного среза (очередь/обслужено/ошибки/ретраи/prefill tok/s (avg)/decode tok/s (последний)/mem/swap/GPU temp·sclk·power·busy/Tctl) БЕСУСЛОВНО раз в N c; сервер недоступен — строка раз в 30 c с самолечением (без дублей); `q`/Ctrl-C — обычный выход |
| `hfctl on` / `hfctl off` | поднять сейчас / стоп+снятие с автозапуска (файлы и модели целы) |
| `hfctl doctor` | диагностика без изменений (железо, профили, gpu-lock) |
| `hfctl models` | что скачано, доступность профилей |
| `hfctl bench [full] [--compare]` | бенч сервера: tok/s, τ, TTFT, параллельность, HOL; бейслайн для сравнений |
| `hfctl pull <profile>` | скачать сет модели профиля без переключения |
| `hfctl uninstall [--purge-models] [--purge-image]` | снять привязки к машине (юниты+таймер, контейнер/сеть, linger, limits.d); клон, `.data/` (модели/профили) и симлинк остаются; модели и образ — только по явным флагам |

## Бенч производительности

`hfctl bench` меряет реальную скорость твоего сервера и запоминает прогоны
для сравнений (бейслайн = твой прошлый прогон):

```bash
hfctl bench                 # быстрый (~90 с): соло-код (пик спекуляции),
                            # соло-проза (бытовой baseline), TTFT
hfctl bench full            # + prefill-100k, long-gen 4096, parallel N=2/4,
                            # HOL-изоляция (~15 мин)
hfctl bench --parallel 2,4  # параллельная картина поверх quick/full: агрегат
                            # + per-request wall по позициям (1..8)
hfctl bench --compare       # дельта с последним прогоном (после обновления
                            # образа или смены профиля)
hfctl bench --json > b.json # машиночитаемый артефакт
```

- Артефакты: `~/hfctl/.data/bench-runs/<timestamp>.json` (профиль, модель,
  роут, цифры, md5 фикстуры). Первый прогон — бейслайн.
- Метрики честные: wall + `usage.completion_tokens` (работает на всех
  роутах); τ и движковый tok/s — best-effort из логов.
- Интерпретация параллельности привязана к роуту: lanes → «масштабирование
  X%», serial → «FIFO: aggregate ≈ solo — норма», слоты → «очередь слотов».
- `--runs N` (default 3) — повторов на сценарий; WARN при разбросе >5%.
- `--parallel N[,M…]` — параллельные батчи поверх режима (1..8; каждый —
  один прогон; full без флага = 2,4).
- Конфиг сервера bench не меняет; `--fresh` (recreate) — только по явному
  запросу.
- Ctrl-C (SIGINT/SIGTERM) прерывает прогон на любой фазе: частичный прогон
  не сохраняется, начатые запросы доубиваются (rc 130/143).

## Профили

| Профиль | Что внутри | Требования |
|---|---|---|
| `27b-single` *(default)* | Qwen3.8-27B: `mq4-xts` (быстрее) + `mq6-xt` (качественнее), DFlash-спекуляция, singleton | ~60 GiB пула |
| `27b-slots` | те же модели, multi_slot 2×262144 | ~60 GiB |
| `flash-multi` | Qwen3.8 Flash-Next `mq4-xts`, VMM continuous batching (fn-lanes) | ≥80 GiB пула |

Переключение в любой момент: `hfctl use flash-multi` — недостающие модели
докачаются (с вопросом), скачанное не удаляется. На машинах, где профиль не
помещается, hfctl откажет с цифрами **до** скачивания. Обход гейта — `--force`
у on/use (или env `HFCTL_FORCE=1` — тот же единственный смысл, который
выставляет флаг): warn с цифрами и дальше как обычно, но движок может отказать
в загрузке.

## Лейаут v2: клон = стек

| Путь | Что там |
|---|---|
| `~/hfctl/hfctl`, `lib/`, `tpl/`, `tests/`, `.dev/` | tracked-код: диспетчер, модули, шаблоны, батарея, борд |
| `~/hfctl/.env` | канон профиля (пишет hfctl; gitignored) |
| `~/hfctl/.data/models/{27b,flash}/` | сеты моделей + draft (per-сет) |
| `~/hfctl/.data/profiles/<профиль>/{config,kernel}/` | состояние движка per-профиль: конфиг, disk-тир кэша (`config/session-cache/`), кэш ядер; бэкап = `tar` каталога |
| `~/hfctl/.data/bench-runs/<timestamp>.json` | артефакты bench |
| `~/hfctl/.data/benchmarks/prompts/` | опциональный `/prompts`-маунт (лаба создаёт сама) |
| `~/hfctl/.data/.hfctl-stopped`, `.hfctl.lock` | маркер явной остановки; flock up/boot/watchdog |

Вне каталога остаются только осознанные исключения: systemd-user юниты
`~/.config/systemd/user/`, симлинк `~/.local/bin/hfctl`,
`/etc/security/limits.d/99-hipfire-memlock.conf`, группа `render`, linger,
podman-образ и контейнеры.

Дистрибуция и обновление — сам git: `git pull` в клоне обновляет код;
пересборка мира не нужна — recreate делает `use` (или `off`/`on`). Ручной
`cp` бинаря не нужен и вреден (контейнер останется со старым маунтом).

**Warnings:**

- `git clean -fd` безопасен (всё машинное — gitignored); **`git clean -fdx`
  удаляет `.data/` вместе с моделями — запрещённая команда.**
- Одна инсталляция на юзера: имя контейнера (`hipfire_hipfire_1`), порт
  11435 и имена юнитов (`hipfire-compose*`) глобальны — второй клон на той
  же машине конфликтует при up.
- `~/hfctl/.data/` переживает `uninstall`: он снимает привязки (юниты,
  контейнер/сеть, linger, limits.d), данные остаются до `--purge-models`.

## Миграция с лейаута v1 (`~/hipfire`)

Стек эпохи до этапа 14 (`~/hipfire` с `models/`, `profiles/`, `.env`) переносится
в клон за один даунтайм-заход (mv в пределах /home — иноды целы):

```bash
hfctl off                                  # старый бинарь: стоп, юниты, linger
cd ~/hfctl && git pull                     # код v2
mkdir -p .data
mv ~/hipfire/models   .data/models
mv ~/hipfire/profiles .data/profiles
[ -d ~/hipfire/bench-runs ] && mv ~/hipfire/bench-runs .data/bench-runs
#   НЕ переносить: .env, compose*.yml, маркеры, бинарь+lib+tpl — всё это
#   первый on пересоздаст из клона
./hfctl on --profile <id из старого .env> [--port N --bind A]   # если не дефолт
./hfctl doctor && ./hfctl status           # healthy; затем reboot-приёмка
rm -rf ~/hipfire                           # старый стек — после healthy
```

## Как это устроено

- Всё машинное состояние — в `.data/` клона (таблица выше). В `.env` нет
  строки `COMPOSE_FILE`: podman-compose её не читает, hfctl сам передаёт
  каноническую `-f`-тройку при каждом вызове. Скоуп containers.conf —
  tracked-файл `tpl/etc/hfctl-containers.conf` клона (производных копий нет).
- Автозапуск: systemd user unit (boot) + watchdog-таймер 1 мин (краши;
  rootless podman не переживает отсоединение compose, поэтому надзор внешний).
  Юниты ставятся последним шагом bootstrap'а — таймер не тикает до первого
  здорового подъёма.
- Модели тянет официальный `hipfire pull` (sha256-верификация, идемпотентно).
- Явная остановка — только `hfctl off` (иначе вотчдог поднимет контейнер).
- Бэкап состояния профиля: `tar czf backup.tgz --exclude='*/config/models' -C
  ~/hfctl/.data profiles` — (незанятое состояние: конфиг, disk-тир кэша,
  ядерный кэш; каталог `models` внутри config — поверхностная точка
  вложенного bind, его содержимого на хосте нет). Восстановление:
  распаковать поверх + **обязательно recreate** (`hfctl up`): вложенный bind
  моделей держит старый inode точки монтирования, без пересоздания
  контейнера движок увидит пустой `models` → «model not found locally»
  (проверено приёмкой этапа 7).

## Если что-то пошло не так

- `hfctl doctor` — первая точка диагностики.
- `hfctl on` (bootstrap) печатает «повтори после ребута/перелогина» — так и
  сделать: группа render и memlock применяются только к новым сессиям
  (повтор — та же команда `./hfctl on` с теми же флагами).
- Сервер не здоров: `hfctl logs -f` и `hfctl status`.
- Модель в ответах «думает дольше ответа»: у клиентов с маленьким
  `max_tokens` ставь `reasoning_effort:"none"` (или `max_tokens ≥ 400`).

Детали и спецификация: `.dev/SPEC.md` (UX), `.dev/PLAN.md` (план/DoD).
