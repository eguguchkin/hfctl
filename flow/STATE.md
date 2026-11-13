# STATE — hfctl watch (dev-flow)

- Сабстэдж: `watch/polish` — **ЗАКРЫТ (2026-11-13)**: reviewer APPROVED
  round 2; tester round 1 внутреннее 0 FAIL; EXP-001 PASS на машине B
  (один прогон на конец пакета по D12; фикс log_h=4 — EXP не затронут);
  tester в фикс-раунде пропущен по D11 (запись в history)
- Предыдущий: `watch/watch-tui` — закрыт 2026-11-13 (APPROVED round 3)
- Следующий шаг: пуш пользователя (11afed2 + 4ac36c4) → доставка на машину B
  (pull + install.sh, без recreate и без перепуска EXP по D12) → selfcheck
  в TTY 42/42 → статусный коммит spec/state.md (сделан) + hflab (сделан)
- Бэклог (некритичные, не блокируют): markdown-склейка spec/hfctl.md:60–61;
  `hfctl status` rc=127 без podman (pre-existing lib/); selfcheck-кейс
  «log tail visible» привязан к log_h=5; прежние: дробность GPU temp
  (решено — оставить как есть), usage rc=1 — сделано в этом сабстэдже.
- Открытые вопросы к спеке (review round 1): нет новых.
