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
./install.sh          # кладёт hfctl в стек ~/hipfire/ + симлинк в ~/.local/bin (без sudo)
hfctl doctor          # (опционально) проверка железа до скачивания
hfctl install         # сервер: ~34 GB моделей, потом healthy + smoke
```

После `hfctl install` сервер на `http://<IP>:11435` (LAN, без ключа),
автозапуск при загрузке включён, падения поднимает вотчдог.

```bash
curl http://<IP>:11435/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.8:27b-mq4-xts","messages":[{"role":"user","content":"привет"}],"max_tokens":400,"reasoning_effort":"none"}'
```

Любой OpenAI-совместимый клиент: `base_url = http://<IP>:11435/v1`,
список моделей — `curl http://<IP>:11435/v1/models`.

## Команды

| Команда | Что делает |
|---|---|
| `hfctl install [--profile P] [--port N] [--bind A] [--models-dir D] [--no-autostart] [--force]` | развернуть/починить инсталляцию (идемпотентно) + автозапуск |
| `hfctl use <profile>` | переключить профиль; заменяет конфиг автозапуска — выбор переживает рестарт |
| `hfctl status [--json]` | профиль, health, автозапуск, контейнеры |
| `hfctl logs [-f] [-n N]` | логи сервера |
| `hfctl watch [--interval N]` | живой наблюдатель обработки (дефолт 2 c): строка при изменении очереди/счётчика обслуженных, `tok/s` последнего `done`, **cached_tokens** кумулятивно из `/metrics` (дельта по запросу), температура GPU с хоста (`/sys` hwmon); в простое — heartbeat раз в ~60 c (`обменов нет…`, при долгой генерации — `обработка идёт (очередь: N…)`), при недоступности сервера — предупреждение раз в ~30 c с самолечением; Ctrl-C — обычный выход |
| `hfctl on` / `hfctl off` | автозапуск вкл / стоп+снятие (файлы и модели целы) |
| `hfctl doctor` | диагностика без изменений (железо, профили, gpu-lock) |
| `hfctl models` | что скачано, доступность профилей |
| `hfctl bench [full] [--compare]` | бенч сервера: tok/s, τ, TTFT, параллельность, HOL; бейслайн для сравнений |
| `hfctl pull <profile>` | скачать сет модели профиля без переключения |
| `hfctl uninstall [--purge-models] [--purge-image]` | снести всё (по умолчанию модели и образ щадит) |

## Бенч производительности

`hfctl bench` меряет реальную скорость твоего сервера и запоминает прогоны
для сравнений (бейслайн = твой прошлый прогон):

```bash
hfctl bench                 # быстрый (~90 с): соло-код (пик спекуляции),
                            # соло-проза (бытовой baseline), TTFT
hfctl bench full            # + prefill-100k, long-gen 4096, parallel N=2/4,
                            # HOL-изоляция (~15 мин)
hfctl bench --compare       # дельта с последним прогоном (после обновления
                            # образа или смены профиля)
hfctl bench --json > b.json # машиночитаемый артефакт
```

- Артефакты: `~/hipfire/bench-runs/<timestamp>.json` (профиль, модель, роут,
  цифры, md5 фикстуры). Первый прогон — бейслайн.
- Метрики честные: wall + `usage.completion_tokens` (работает на всех
  роутах); τ и движковый tok/s — best-effort из логов.
- Интерпретация параллельности привязана к роуту: lanes → «масштабирование
  X%», serial → «FIFO: aggregate ≈ solo — норма», слоты → «очередь слотов».
- `--runs N` (default 3) — повторов на сценарий; WARN при разбросе >5%.
- Конфиг сервера bench не меняет; `--fresh` (recreate) — только по явному
  запросу.

## Профили

| Профиль | Что внутри | Требования |
|---|---|---|
| `27b-single` *(default)* | Qwen3.8-27B: `mq4-xts` (быстрее) + `mq6-xt` (качественнее), DFlash-спекуляция, singleton | ~60 GiB пула |
| `27b-slots` | те же модели, multi_slot 2×262144 | ~60 GiB |
| `flash-multi` | Qwen3.8 Flash-Next `mq4-xts`, VMM continuous batching (fn-lanes) | ≥80 GiB пула |

Переключение в любой момент: `hfctl use flash-multi` — недостающие модели
докачаются (с вопросом), скачанное не удаляется. На машинах, где профиль не
помещается, hfctl откажет с цифрами **до** скачивания. Обход гейта — `--force`
у install/use (или env `HFCTL_FORCE=1` — тот же единственный смысл, который
выставляет флаг): warn с цифрами и дальше как обычно, но движок может отказать
в загрузке.

## Как это устроено

- Всё в одном каталоге `~/hipfire/`: `hfctl` (диспетчер), `lib/` (модули),
  `tpl/` (шаблоны: compose/.env/юниты/python/bench-фикстура
  `tpl/bench/merge_sort_thinking_off.txt`), `models/<сет>/`
  (модели, per-сет), `profiles/<профиль>/{config,kernel}` (состояние движка
  per-профиль: конфиг, disk-тир контекст-кэша в `config/session-cache/`,
  кэш прекомпилированных ядер; бэкап = `tar` каталога), compose-файлы, `.env`.
  В `.env` нет строки `COMPOSE_FILE`: podman-compose её не читает, hfctl сам
  передаёт каноническую `-f`-тройку при каждом вызове.
  Вне каталога: systemd user юниты, контейнеры podman,
  `/etc/security/limits.d/99-hipfire-memlock.conf`, группа `render`, linger.
- Дистрибуция: `git clone` + `./install.sh` (копирует `hfctl`, `lib/`,
  `tpl/` в стек и ставит симлинк `~/.local/bin/hfctl`). Обновление бинаря —
  свежий клон + тот же `install.sh`: перезаписываются ровно эти три элемента,
  модели/state/конфиги в стеке остаются.
- Автозапуск: systemd user unit (boot) + watchdog-таймер 1 мин (краши;
  rootless podman не переживает отсоединение compose, поэтому надзор внешний).
- Модели тянет официальный `hipfire pull` (sha256-верификация, идемпотентно).
- Явная остановка — только `hfctl off` (иначе вотчдог поднимет контейнер).
- Бэкап состояния профиля: `tar czf backup.tgz --exclude='*/config/models' -C
  ~/hipfire profiles` — (незанятое состояние: конфиг, disk-тир кэша, ядерный кэш;
  каталог `models` внутри config — поверхностная точка вложенного bind,
  его содержимого на хосте нет). Восстановление: распаковать поверх +
  **обязательно recreate** (`hfctl up`): вложенный bind моделей держит старый
  inode точки монтирования, без пересоздания контейнера движок увидит пустой
  `models` → «model not found locally» (проверено приёмкой этапа 7).

## Если что-то пошло не так

- `hfctl doctor` — первая точка диагностики.
- install печатает «шаг 2 из 2: повтори после ребута/перелогина» — так и
  сделать: группа render и memlock применяются только к новым сессиям.
- Сервер не здоров: `hfctl logs -f` и `hfctl status`.
- Модель в ответах «думает дольше ответа»: у клиентов с маленьким
  `max_tokens` ставь `reasoning_effort:"none"` (или `max_tokens ≥ 400`).

Детали и спецификация: `spec/hfctl.md` (UX), `spec/plan.md` (план/DoD).
