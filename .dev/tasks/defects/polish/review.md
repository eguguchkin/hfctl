# Review: defects/polish
Verdict: APPROVED
Round: 1

## Against DoD
| item | met/partial/missing | proof/complaint |
|---|---|---|
| 1 (юнит: комментарий над KillMode, парсится без «Failed to parse») | met (внутри доступными средствами) | Перепроверено своими руками: комментарий — строка 8, `KillMode=process` — строка 9, структура как в эталоне `hipfire-compose-watchdog.service.tpl:6-8` (комментарий строкой выше). `diff` файла против HEAD с вырезанными comment-only строками: единственный зазор — удаление inline-коммента с той же строки, т.е. **содержимое директив байт-идентично HEAD**. Рендер (`sed` __STACK_DIR__/__PODMAN_BIN__/__CF__ → /tmp): ни одной строки `key=value…#` (grep `^[A-Za-z][^=]*=[^#]*#` → rc=1), все `#` только с начала строки. **Полноценный `systemd-analyze verify` НЕ делался — бинарь (и `systemctl`) отсутствуют в ocbox-контейнере** (`command -v` пусто, проверено ревьюером). Это хвост оркестратора: verify/`systemctl --user cat` при доставке на машину (что и так DoD 4-часть). |
| 2 (temp_color = по напечатанному, обе строки; границы selfcheck) | met | Определения перечитаны: `fmti = str(int(x))` (усечение), `fmt_c = '%.1f' % x` (округление). Границы пересчитаны ревьюером независимо: 79.95→"80.0"→жёлтый ✓, 89.96→"90.0"→красный ✓ (double 79.95/89.96 чуть выше границ, округление вверх), 79.96→fmti "79"→0 ✓, 89.96→fmti "89"→жёлтый ✓, 90.0→"90"→красный ✓. Оба call-site в `rows_hardware` (:1203-1204) передают ровно тот fmt, которым ПЕЧАТАЮТ (GPU—fmti/fmti, CPU—fmt_c/fmt_c). grep по всему репо: других потребителей `temp_color` нет (только rows_hardware + selfcheck). Обратная совместимость: `fmt=None` → прежнее сырое сравнение, прежние проверки не изменены. |
| 3 (bash -n, рендер+verify локально, selfcheck rc=0, git status) | met | `python3 tpl/python/watch_tui.py --selfcheck` → **`selfcheck: 52/52 ok`, rc=0** (проверено ревьюером лично). `bash -n hfctl` OK (правок .sh нет). `git status --porcelain`: ровно `M tpl/python/watch_tui.py`, `M tpl/systemd/hipfire-compose.service.tpl` + неотаблированный `.dev/tasks/defects/` (артефакты). `tpl/bench/merge_sort_thinking_off.txt` md5 `253c7ac5…` — цела. |
| 4 (машины не трогаем) | met | В диффе только два файла; ssh/podman наружу в отчёте нет; машинная часть явно оставлена оркестратору. |

## Blocking
Нет.

## Non-critical notes
1. `float(fmt(deg))` бросит ValueError на fmt-заглушке ('?') — в безопасности только
   потому, что оба call-site вызывают fmt лишь при `deg is not None` (fmt_c/fmti
   печатают '?' исключительно для None). Ограничение честно зафиксировано в
   dev-report; если появится третий fmt с заглушкой — защищать внутри temp_color.
2. Хвост оркестратора (не дефект сабстэджа): `systemd-analyze verify` рендеренного
   файла + исчезновение `Failed to parse kill mode specification` в journal —
   подтверждаются только на машине при доставке (пересоздание юнитов `hfctl off/on`),
   по одной машине за раз (правило пользователя 2026-11-14).

## Questions to the spec
Нет.
