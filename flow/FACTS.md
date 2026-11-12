# FACTS (проверено оркестратором, 2026-11-12; цитаты — текущее дерево)

## Метрики движка 0.4.5 (`/metrics`, Prometheus)
Источник: `/workspace/hipfire/crates/hipfire-cli/src/serve/metrics.rs:277-523`.
Сверено по коду; в репо hfctl движок — только consumer.

- Счётчики: `hipfire_requests_total`, `hipfire_requests_failed_total`,
  `hipfire_prompt_tokens_total`, `hipfire_completion_tokens_total`,
  `hipfire_cached_prompt_tokens_total`, `hipfire_retries_total`,
  `hipfire_retries_succeeded_total`, `hipfire_uptime_seconds`,
  `hipfire_context_capacity_tokens`.
- Gauges: `hipfire_queue_depth`, `hipfire_queue_capacity`,
  `hipfire_kv_pages_free`, `hipfire_kv_pages_total`, `hipfire_slots_active`,
  `hipfire_slots_total`.
- Гистограммы (объединённо: `_bucket/_sum/_count`): `hipfire_ttft_milliseconds`,
  `hipfire_request_latency_milliseconds`, `hipfire_time_per_output_token_milliseconds`,
  `hipfire_decode_tokens_per_second`, **`hipfire_prefill_tokens_per_second`**,
  `hipfire_spec_tau`.
- **Живая скорость префилла** = Δ`hipfire_prompt_tokens_total` / Δt за тик
  (префилл = всплеск, весь промпт «сгорает» за секунды; decode токены этот
  счётчик не двигает). Гистограмма prefill даёт среднее по всему аптайму —
  только для строки «avg».
- **Живая скорость decode** = Δ`hipfire_completion_tokens_total` / Δt;
  `/stats recent_tok_s` — только скорость последнего завершённого запроса.

## `/stats` (JSON)
Читает существующий харнес: `tpl/python/watch_stats.py` (ключи:
`queue_depth`, `requests_served`, `recent_tok_s`, `retries_attempted`).
Печатает per-request ошибки только в stdout-журнал; lifecycle не логируется
(fact hflab AGENTS.md, «Наблюдаемость по запросам»).

## Host sysfs (Strix Halo / gfx1151)
- AMD-карта: `/sys/class/drm/card*/device/vendor` = `0x1002`;
  датчики в `…/device/hwmon/hwmon*/`: `temp1_input` (мК), `freq1_input`
  (sclk, кГц), `power1_input` (мВт), `gpu_busy_percent` (0..100),
  `mem_info_vram_used` / `mem_info_gtt_used` (байты).
- CPU (k10temp): Tctl — `temp1_input` hwmon-датчика k10temp.
- hipfire сам читает `mem_info_vram_used`/`gtt_used` в своих bench-чекпоинтах
  на Halo (`/workspace/hipfire/docs/perf-checkpoints/2026-10-27-qwen-vl-*.json`),
  т.е. файлы существуют на целевых машинах.
- Существующий bash-реализатор GPU temp: `gpu_temp()` в
  `lib/commands.sh:258-271` (max по temp1_input всех AMD hwmon).

## Текущий `hfctl watch`
- Реализация: `cmd_watch()` в `lib/commands.sh:297-376` (bash-цикл, curl
  /stats+/metrics, python `watch_stats.py`, awk, `gpu_temp`); печатает строку
  только при изменении счётчиков, heartbeat раз в 60 с при простое,
  «сервер недоступен» раз в 30 с; `--interval N` (default 2, ≥1).
- Контейнер: `CONTAINER=hipfire_hipfire_1` (диспетчер `hfctl:52`);
  `podman logs -t --tail N -f` уже работает (`cmd_logs`, `lib/commands.sh:239`).
- Python-харнесы: 15 файлов в `tpl/python/` — python3 обязателен на целевой
  машине, stdlib-подход принят в репо.

## Датчики на che-FAEX1 (проверено оркестратором вживую, 2026-11-12)
- `amdgpu` hwmon живёт в `/sys/class/drm/card0/device/hwmon/hwmon7`;
  `freq1_input` = **Гц** (600000000 = 600 МГц), `power1_input` = мВт,
  `gpu_busy_percent` = `/sys/class/drm/card0/device/gpu_busy_percent`
  (НЕ в hwmon-каталоге).
- CPU Tctl (k10temp) — в `/sys/class/hwmon/hwmon3` (name=k10temp),
  `temp1_input`/`temp1_label`; пути `/sys/class/drm/card*/device/hwmon`
  его НЕ содержат — искать надо по `/sys/class/hwmon/hwmon*/name`.
- tmux-окно исполняет команду БЕЗ .bashrc (не интерактивный shell) →
  `~/.local/bin` в PATH нет (login-shell добавляет через .profile);
  `hfctl watch` в tmux без явного PATH/полного пути → rc=127.
- PATH-фикс на FAEX1 сделан: `export PATH="$HOME/.local/bin:$PATH"`
  в `~/.bashrc` (подсказка install.sh, как рекомендовано продуктом).

## Контекст
- Движок имеет собственный `hipfire tui` (ratatui,
  `/workspace/hipfire/crates/hipfire-tui/`), но он в контейнере: не видит
  host-датчики/RAM/логи пода удобной подстройкой → TUI в hfctl не дубль,
  а другая зона (железо + пода).
- `watch` в README/spec описан как «живой наблюдатель»
  (`spec/hfctl.md:60`) — описание придётся дописать после приёмки.
