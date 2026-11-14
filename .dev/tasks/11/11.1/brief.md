# Brief: engine-0.4.6 — образ hipfire 0.4.5 → 0.4.6 в hfctl

Сабстэдж продукта hfctl. Факты приёмки собраны в hflab
(`/workspace/hflab/flow/recon/0.4.6-recon.md`, 2026-11-13) — конспект ниже;
лабораторная приёмка на машинах идёт ПЕРЕД кодом hfctl (правило 5 hflab)
и уже санкционирована пользователем («обновляй»), кроме окна прерывания
машины B (живой трафик — ждём GO).

## Констар-факты (из recon, с цитатами в hflab)
- Реестр 0.4.6: sha256/size НАШИХ файлов не изменились → `pull --yes` без
  докачки; ловушка 2026-11-08 не срабатывает.
- compose.yml / compose.halo.yml байт-идентичны v0.4.5 → golden'ы tpl/compose
  валидны, не правим.
- Дефолты наших ключей не двигались; `HIPFIRE_DFLASH_DRAFT` жив; load-summary
  «spec: dflash (…)» и «fn-lanes staged» не менялись.
- D2-refus fn-lanes не для нас (UMA off, never probed).
- Автоматические выгоды: #1060/#1061/#1087 (+новый лог `[qwen-cache cold`).
- Тег ghcr 0.4.6 существует; образ скачан на машину B (digest ab388091…).

## Goal
`hfctl` по умолчанию ставит/поднимает `ghcr.io/warpfront/hipfire:0.4.6`;
доки соответствуют; приёмка на обеих живых машинах (лабораторный канал
`HFCTL_IMAGE`) зелёная ДО коммита кода, после кода — доставка без перепусков (D12).

## DoD
1. Лабораторная приёмка машины B (flash-multi): `HFCTL_IMAGE=…:0.4.6
   hfctl use flash-multi` (тот же профиль) → `fn-lanes staged … lanes=4
   spec=mtp`, smoke 200, `hfctl bench` quick без регрессии против бейслайна
   этапа 9 (solo-code 75.22 route=lanes; поимённо в отчёте), init-строки
   sha «Already downloaded» (нет докачки), doctor rc=0.
2. Лабораторная приёмка che-evo (27b-single, прод): `spec: dflash (draft
   qwen38-27b-dflash-mq4.hfq …)` в load summary, smoke dflash:true,
   bench ×3 против эталона 75.3 tok/s τ=11.83 (допуск ±10%, разброс повтор
   не выше обычного stdev 0.05→~, численные критерии фиксирует отчёт).
3. Код hfctl: IMAGE default 0.4.5→0.4.6 (`hfctl:36` + тип-комментарий `:35`);
   док-строки/комментарии «0.4.5», относящиеся к ПИНУ образа (README,
   spec/hfctl.md, lib/*.sh, tpl/env/env.tpl нет — там __IMAGE__); комментарии
   golden-заголовков tpl/compose НЕ правятся (байт-идентичность с апстримом);
   `lib/stack_files.sh` — пометка, что golden'ы валидны и для 0.4.6
   (файлы идентичны).
4. Внутренние проверки: bash -n, usage rc=1, selfcheck watch не затронут,
   `tpl/bench/` md5 канон, spec/state.md через статус-коммит.
5. Регрессия продуктовая: install/use/idempotency без машины — по
   возможности; машинная часть закрыта п.1–2 (D12: после кода — доставка
   без перепуска, если код = только пин+доки).
6. hflab (вне кода hfctl, тот же сабстэдж-пакет): пины 0.4.5→0.4.6 в
   scripts/*, AGENTS.md (таблица целевой конфигурации, факты: реестр не
   менялся, `[qwen-cache cold`, D2-refus не для Halo, LANE_ROW_EXACT-заметка),
   STATE.md.

## Specification references
- hfctl spec/hfctl.md (образ, профили), AGENTS.md правила 1,5,6,7 + dev-flow.
- hflab flow/recon/0.4.6-recon.md (факты).

## Constraints and traps
- Не трогать tpl/compose/* (golden). Не трогать tpl/bench/.
- Машина B: прерывание только по GO пользователя (живой трафик, вечер
  2026-11-13/14). che-evo — прод: recreate только после зелёной машины B.
- После recreate на 0.4.6 — первая компиляция ядер (одноразово, минуты);
  wait_health с запасом.
- Откат: тег 0.4.5 жив на ghcr, digests моделей идентичны → откат без докачки.
