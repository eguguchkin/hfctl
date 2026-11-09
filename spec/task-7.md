# Этап 7 — хранилище состояния: per-профиль явные каталоги (вместо named volumes)

Задача поставлена пользователем 2026-11-09. Суть: заменить именованные
вольюмы состояния движка на явные per-профиль каталоги:

```
~/hipfire/profiles/<профиль>/config   →  /home/hipfire/.hipfire      (сейчас: volume hipfire-config)
~/hipfire/profiles/<профиль>/kernel   →  /var/cache/hipfire          (сейчас: volume hipfire-kernels)
```

## Мотивация

1. **Безопасность кэша (основной драйвер)**: disk-тир контекст-кэша
   (`session-cache/` + `session_cache_disk_bytes`) сегодня лежит в ОДНОМ
   общем каталоге и общем бюджетном пуле (32 GiB) на ВСЕ профили. При
   переключении профиля снапшоты другого семейства/модели могут попасть
   в кэш и стать невалидными. Защита движка (`other-build files` в логе)
   — «на честном слове» движка и не гарантирует разделение по профилям.
   Per-профиль state-директория = изоляция по конструкции.
2. **Наблюдаемость**: состояние (конфиг, кэш, pid-файлы, registry-cache)
   в домашнем каталоге юзера: `ls ~/hipfire/profiles/<prof>/config`;
   бэкап = обычный `tar`; диагностика без podman-обвязки.
3. **Единство инсталляции**: `~/hipfire/` становится полностью явным
   (бинарь, compose, .env, models, state) — «всё, что наше, в одном
   каталоге».

## Факты, на которых стоит решение (проверены 2026-11-09)

- Контент home-вольюма на FAEX = **140K**: `config.toml`, `serve.pid`,
  `daemon-pci-*.pid`, `registry.cache.json` (110K),
  `cache/verified-artifacts.json`, `session-cache/lock` (0 B).
- Kernel-вольюм = **36K** (`gfx1151/*.hip|hsaco|radiowave.json`),
  arch-скауп (GPU + сборка образа), НЕ model-скауп → дублирование
  per-профиль стоит 36K × N профилей — безвредно.
- **Модели НЕ переезжают**: остаются per-сет `models/{27b,flash}`
  (27b-single и 27b-slots делят ~22 GB; per-профиль = дублирование).
  Bind-маунт модели остаётся вложенным внутрь state-директории:
  `models/<сет>` → `/home/hipfire/.hipfire/models` (сейчас — внутрь
  вольюма, после — bind-в-bind).
- `memory.session_cache_dir` — СУЩЕСТВУЮЩИЙ ключ движка 0.4.5
  (default = `<home>/session-cache`); per-профильность disk-тира
  получается автоматически, НОВЫЙ ключ не нужен.
- RAM-тир (`session_cache_bytes`) — per-процесс, умирает при recreate;
  не меняется.
- Disk-тир на FAEX сегодня физически не пишет (0 байт, `0 snapshots
  indexed`) — пересечение профилей *прямо сейчас* не наблюдается;
  решение делает конфигурацию корректной по конструкции.
- Rootless: bind-маунты под home юзера уже работают (models так живёт);
  предупреждение «models is not writable by uid 1000 → container root»
  вероятно исчезнет (безвредно и в любом случае).

## Что делается (в hfctl)

1. **Составной compose-шаблон**: `volume hipfire-config` →
   bind `${HIPFIRE_STATE_DIR}/config:/home/hipfire/.hipfire`;
   `volume hipfire-kernels` →
   bind `${HIPFIRE_STATE_DIR}/kernel:/var/cache/hipfire`;
   `HIPFIRE_STATE_DIR = $STACK_DIR/profiles/<активный_профиль>`
   (пишется в .env; при `use` — обновляется + migrate + recreate).
   Top-level `volumes:` блок из шаблона убирается.
2. **install**: создаёт `profiles/<профиль>/{config,kernel}`;
   **миграция одноразово**: если legacy-вольюм существует
   (ищем по имени `hipfire_hipfire-config` через `podman volume ls`,
   не хардкодом пути) и каталог профиля пуст/нет — копирует `_data`
   целиком (включая `session-cache/` — у реального юзера там могут
   быть гигабайты снапшотов) в каталог профиля; после успешного подъёма
   на bind-маунтах legacy-вольюмы НЕ удаляются автоматически
   (удаляет `uninstall`).
3. **use/apply_profile**: при первом переключении на профиль с
   пустым каталогам — та же миграция из legacy-вольюма (для активного
   профиля); далее — recreate под своим state-каталогом.
4. **uninstall**: purge добавляет `rm -rf $STACK_DIR/profiles` +
   idempotent `podman volume rm` legacy-имён (для старых установок).
5. **doctor**: проверка существования/записуемости
   `profiles/<профиль>/{config,kernel}` + WARN если legacy-вольюм
   ещё жив (миграция не завершена).
6. **README/spec**: обновить описания структуры `~/hipfire`.

## Не меняется

- Модели (per-сет), образ, env-переменные профиля, watchdog,
  RAM-тир, `memory.session_cache_dir` (используем default).

## DoD (приёмка на FAEX: flash активен; recreate flash-стека — безопасен,
чужих сервисов нет)

- install/use на существующей машине: каталог профиля создан,
  config.toml/pid/session-cache появились в нём; НОВЫЕ named volumes
  НЕ создаются; serve healthy, smoke 200.
- Миграция: состояние legacy-вольюма (140K) попало в каталог профиля
  без потерь (diff по файлам); legacy-вольюм остался (удаляется
  uninstall).
- Per-профильность: конфиг профиля сохраняется после переключения
  и обратно (у каждого профиля свой config.toml с «своими» значениями
  профиля — сверить через doctor/config get: 27b `batch_nonexact=true`,
  flash `batch_nonexact=false`).
- Вложенный bind: models-маунт работает внутри state-директории
  (запрос к модели = 200, `dflash:true` на evo / lanes=4 в логе на FAEX).
- Бэкап-цикл: `tar` каталога профиля → удалить → восстановить →
  serve видит state (pid/session-cache на месте), healthy.
- uninstall --purge-models --purge-image: `profiles/` и legacy-вольюмы
  отсутствуют, машина «как никогда не было».
- Регресс-минимум: `status [--json]`, `logs -n 5`, `on/off`, `watch`
  (2 тика) — поведение без изменений.

## Уроки приёмки (2026-11-09, FAEX/EVO)

- **Бэкап-восстановление state требует recreate**: вложенный bind моделей
  навешивается на inode каталога точки монтирования внутри state-каталога;
  стирание/восстановление каталогов под ним оставляет живой контейнер со
  СТАРЫМ inode → внутри контейнера `/home/hipfire/.hipfire/models` виден
  пустым → «model not found locally: … run hipfire pull» (404 на chat,
  хотя /v1/models отвечает из registry-кэша и health зелёный). Лечение:
  после restore — `compose up -d --force-recreate`. README описывает
  каноничную процедуру `tar --exclude='*/config/models'` + recreate.
- В legacy-вольюме остаётся ХВОСТ после миграции: serve.pid и daemon-*.pid
  чистятся движком при остановке старого контейнера — diff file-list
  миграции отличается на эти pid-файлы; это норма (артефакт времени,
  config.toml перезаписан apply_profile, pid-файлы движок создаёт заново).
- Smoke на ФРЕШЕ движке: первый запрос может варить недостающие ядра
  (72 «unplanned kernel … bound lazily» на evo) > 120 c
  → curl -m 120 рвал соединение, ответ пустой, FATAL «смоук не прошёл».
  Патч: smoke `-m 300` (c49959e).
- `uninstall` был интерактивным без неинтерактивного пути: добавлен флаг
  `--yes` (c49959e); до этого вместе с `--yes` работал только env HFCTL_YES.
- Kernel-кэш мигрируется (36K, gfx1151/), но движок всё равно лениво
  биндит «unplanned» ядра («module already compiled» — биндинг вне
  предсказанного плана, не пересборка); время старта это не портит,
  per-профильное дублирование 36K × N профилей — безвредно.

## DoD-чеклист фактический
- FAEX: миграция 140K+36K ✅; mounts bind (config+kernel+models) ✅;
  НОВЫХ томов не создаётся ✅; lanes=4 staged ✅; per-профиль config.toml
  (batch_nonexact=false и др.) ✅; doctor: state-строка + legacy-WARN ✅;
  smoke 200 ✅ (после recreate); session-cache внутри config/ ✅.
- EVO: uninstall --yes → «как никогда не было» (profiles/ и legacy-вольюмы
  отсутствуют); чистый install → bind-маунты, doctor БЕЗ legacy-WARN,
  27b-single healthy, smoke ×2, dflash — подтверждается фазой 2 (текущий
  прогон, результат добавлю в STATE).
- Итерацию «uninstall --purge-models --purge-image» (полный purge моделей)
  на evo НЕ гоняли — уничтожило бы 130 GB моделей (повторное скачивание
  часов). Purge-пути по коду: `rm -rf $STACK_DIR` (включает profiles/)
  + `podman volume rm` legacy-имён (идемпотентен). Остаток: проверить при
  будущей полной зачистке.
