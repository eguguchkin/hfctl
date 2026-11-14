# Task: engine/0.4.6 — пин образа 0.4.5 → 0.4.6 (механический)

Лабораторная приёмка ЗАВЕРШЕНА (до кода, правило 5 hflab) — обе машины зелёные:

- Машина B (che-FAEX1, flash-multi): `HFCTL_IMAGE=…0.4.6 hfctl use flash-multi`
  → HEALTHY 25 c, smoke OK, `fn-lanes staged: lanes=4 spec=mtp K=7
  sampled=true` (+ новая policy-фаза `ple_project=lane`), init
  «Already downloaded» ×2 (докачки нет), doctor rc=0, refus/panic 0,
  `hipfire 0.4.6 (165cf0e962a8)`; bench quick solo-code **75.8 tok/s**
  (75.73–75.99) τ=5.00 против бейслайна 75.22 — без регрессии; `hfctl on`
  возвращён.
- che-evo (прод, 27b-single): HEALTHY 10 c, smoke OK, роут
  `singleton+DFlash (spec: dflash )`; честный bare-bench ×3 (модель
  mq4-xts, промпт merge_sort md5 253c7ac5) — decode **131.0 tok/s,
  τ=13.18, prefill ~115 tok/s, ttft ~331 мс, разброс нулевой** против
  эталона 0.4.5 130.5 / 13.18. Md5 бинарей 0.4.6: hipfire
  `00c1815b07fed8a86469d53b3af0c228`, daemon
  `390daa1db620cf8e789a08849986c59d`.
- Замечание к брифу: DoD 2 назван против цифры 75.3 τ11.83 — это цифра
  mq6-xt; фактический прод-модель mq4-xts (была и до апдейта, `.env` не
  менял модель), поэтому сравнение против 130.5/13.18 (mq4-xts, тот же
  промпт) — критерий «без регрессии» ВЫПОЛНЕН с запасом.

## Scope (только это)

1. `hfctl` (диспетчер): пин IMAGE `0.4.5` → `0.4.6` (строка IMAGE в шапке
   ~:36 и тип-комментарий над ней ~:35). Больше в диспетчере ничего.
2. Док-строки/комментарии с упоминанием пина «0.4.5» в продукте: README.md,
   spec/hfctl.md, комментарии lib/*.sh — заменить на 0.4.6 там, где речь о
   ПИНЕ ОБРАЗА/версии движка. НЕ трогать: упоминания этапов истории,
   changelog-строки, доки бейслайнов бенчей (75.22/75.3 и т.п. — это
   измерения, не пин).
3. `lib/stack_files.sh`: в комментарии к golden'ам tpl/compose — пометка,
   что compose.yml/compose.halo.yml апстрима 0.4.6 байт-идентичны 0.4.5
   (blob'ы совпали в git) → golden'ы валидны и для 0.4.6 (факт recon
   hflab flow/recon/0.4.6-recon.md, вопрос 10).
4. spec/status.md (или текущий формат статуса в spec/) — строка статуса
   сабстэджа.
5. tpl/ НЕ трогать вообще (golden'ы compose + bench-фикстура md5 253c7ac5).

## Проверки

- `bash -n` всех изменённых .sh; usage `./hfctl` без аргументов → rc=1;
- grep по репо: не осталось упоминаний пина 0.4.5 (кроме changelog/истории);
- tpl/ не изменён (`git status` должен показать только перечисленные файлы).

## Вне scope (закрыто оркестратором)

- hflab: scripts/lib.sh (проброс HF_MODEL/HF_PROMPT_FILE/HF_IMAGE в
  hfssh_run), scripts/remote/_bench_arms.sh (IMAGE из env, дефолт mq4-xts,
  терпимость к podman-compose netns-noise, NO JSON guard), AGENTS.md,
  STATE.md — правит и коммитит оркестратор.
- Доставка на машины (D12): после пуша пользователем, без перепусков.
