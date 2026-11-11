# shellcheck shell=bash
# ── файлы стека (официальные compose-файлы hipfire 0.4.5 — в tpl/compose/) ──
# Модуль не определяет глобалов; пишет через хелперы диспетчера (log/die),
# читает SELF/STACK_DIR/TPL_DIR/MODELS_DIR/STATE_BASE/IMAGE/BIND/PORT/
# DRAFT_FILE (диспетчер), cur_profile (lib/stack.sh), profile_field
# (lib/profiles.sh). Вызывается из commands.sh (install/use) и autostart.sh
# (render_tpl для systemd-юнитов).

# Назначение: отрендерить один шаблон из tpl/: прочитать файл $1, заменить в
#   его тексте плейсхолдеры __NAME__ на пары NAME=value, переданные
#   вызывающим rest-аргументами, и записать результат в $out.
#
# Побочные эффекты: пишет файл $out — перезапись (truncate, новый inode,
#   владелец — текущий юзер); читает файл-шаблон $1 (cat). При
#   нераскрытых плейсхолдерах — FATAL die() в stderr и выход процесса.
#
# Ограничения/допущения: требует глобал die (диспетчер). Локалы tpl/out
#   одной строкой: tpl — полный текст шаблона (cat срезает хвостовые
#   переводы строк, printf '%s\n' возвращает ровно один \n в конце),
#   out — путь назначения. Подстановка наивная `${tpl//__NAME__/value}`:
#   значение может содержать переводы строк (prompt_vol) и не
#   экранируется; порядок пар ВАЖЕН — имена передавать в порядке
#   убывания длины (заметка в теле). Наборы плейсхолдеров фиксированы
#   на вызывающих: compose.local.yml.tpl (LOCAL_DRAFT_ENV, LOCAL_PROMPTS),
#   env.tpl (MODELS_DIR, STATE_DIR, PROFILE, IMAGE, MODEL, BIND, PORT),
#   systemd-шаблоны (autostart.sh: PODMAN_BIN, STACK_DIR, CF).
#
# @param 1: string       # путь файла-шаблона .tpl (читается cat целиком)
# @param 2: string       # путь файла назначения (перезаписывается целиком)
# @param 3..N: string[]  # rest пары NAME=value (после shift 2), имена — в
#   порядке убывания длины
# @returns integer       # всегда 0 при возврате — нераскрытые плейсхолдеры
#   завершают процесс die (exit 1), сбой чтения $1 — через set -e
render_tpl() {
  local tpl out; tpl="$(cat "$1")"; out="$2"; shift 2
  local kv name value
  # имена передавать в порядке убывания длины (длинное раньше короткого —
  # защита от вложенных совпадений; наборы фиксированы на вызывающем)
  for kv in "$@"; do
    name="${kv%%=*}"; value="${kv#*=}"
    tpl="${tpl//__${name}__/${value}}"
  done
  if printf '%s' "$tpl" | grep -qE '__[A-Z0-9_]+__'; then
    die "нераскрытые плейсхолдеры в шаблоне $1"
  fi
  printf '%s\n' "$tpl" > "$out"
}

# Назначение: скопировать дерево hfctl (бинарь-диспетчер + lib/ + tpl/) в
#   $STACK_DIR по правилу «копируем только при отсутствии»: есть в стеке
#   бинарь — no-op (повторная установка из старого клона НЕ откатывает
#   свежий стек; обновление — только install.sh, AGENTS правило 5).
#
# Побочные эффекты: только при отсутствии $STACK_DIR/hfctl — mkdir -p
#   $STACK_DIR, install -m 0755 $SELF → $STACK_DIR/hfctl (перезапись) и
#   rm -rf $STACK_DIR/lib, $STACK_DIR/tpl (старые копии удаляются, inode
#   меняются) с cp -a обоих каталогов из дерева рядом с диспетчером
#   (свежие inode, владелец — текущий юзер, атрибуты сохранены). Читает
#   $SELF и lib/, tpl/ рядом с ним. Когда копия в стеке уже есть или
#   запускаемся прямо из стека — файлов не касается вовсе.
#
# Ограничения/допущения: требует глобалы SELF и STACK_DIR (диспетчер) и
#   die. Дерево без lib/ или tpl/ рядом с $SELF → die («установи через
#   git clone + ./install.sh»). Два ранних return 0: копия в стеке
#   уже есть; $SELF и есть $STACK_DIR/hfctl (юниты systemd исполняют
#   стек напрямую). Живые вызовы: write_stack_files этого файла (до
#   первого compose up) и cmd_autostart (юниты ссылаются на
#   $STACK_DIR/hfctl).
#
# @returns integer # всегда 0 — отказы это die (exit 1) либо сбой
#   mkdir/install/rm/cp под set -e (процесс завершается)
sync_tree() {
  # маркер — $STACK_DIR/hfctl: повторная установка из старого клона НЕ
  # откатывает свежий стек (обновление — только install.sh, AGENTS правило 5).
  [ -f "$STACK_DIR/hfctl" ] && return 0      # в стеке уже есть — НЕ трогать
  [ "$SELF" = "$STACK_DIR/hfctl" ] && return 0   # запускаемся прямо из стека (юниты)
  [ -d "$(dirname "$SELF")/lib" ] && [ -d "$(dirname "$SELF")/tpl" ] || \
    die "дерево hfctl неполное: рядом нет lib/ и tpl/ — установи через git clone + ./install.sh"
  mkdir -p "$STACK_DIR"
  install -m 0755 "$SELF" "$STACK_DIR/hfctl"
  rm -rf "${STACK_DIR:?}/lib" "${STACK_DIR:?}/tpl"
  cp -a "$(dirname "$SELF")/lib"  "$STACK_DIR/lib"
  cp -a "$(dirname "$SELF")/tpl"  "$STACK_DIR/tpl"
}

# Назначение: симлинк ~/.local/bin/hfctl → бинарь стека
#   $STACK_DIR/hfctl (вариант 2: стек = истина, PATH-точка переживает
#   переезды клона).
#
# Побочные эффекты: mkdir -p $HOME/.local/bin; ln -sfn ЗАМЕНОЙ перезаписывает
#   симлинк $HOME/.local/bin/hfctl (существующая ссылка заменяется молча;
#   сам файл-цель не трогается). В stdout не печатает.
#
# Ограничения/допущения: требует глобал STACK_DIR (диспетчер); порядок на
#   вызывающем — после sync_tree (иначе ссылка ведёт в несуществующий
#   путь: ln цель не проверяет). Сбой ln (например, на месте ссылки
#   лежит обычный файл или каталог) завершает процесс через set -e.
#
# @returns integer # всегда 0 при возврате — сбой ln завершает процесс set -e
ensure_symlink() {
  local bin_dir="$HOME/.local/bin"
  mkdir -p "$bin_dir"
  ln -sfn "$STACK_DIR/hfctl" "$bin_dir/hfctl"
}

# Назначение: сгенерировать файлы стека в $STACK_DIR целиком — дерево hfctl
#   (sync_tree + ensure_symlink), каталоги, каноническая compose-тройка
#   и compose.local.yml с DFlash-wiring и prompts-маунтом. .env здесь НЕ
#   пишется — это write_env ниже (её вызывает тот же install/use).
#
# Побочные эффекты: mkdir -p $STACK_DIR и $MODELS_DIR (маунт-каталог сета
#   активного профиля); sync_tree (бинарь+lib+tpl в $STACK_DIR) и
#   ensure_symlink ($HOME/.local/bin/hfctl); install -m 0644 ПЕРЕЗАПИСЫВАЕТ
#   $STACK_DIR/compose.yml и $STACK_DIR/compose.halo.yml дословными
#   копиями tpl/compose/compose.yml и tpl/compose/compose.halo.yml;
#   render_tpl ПЕРЕЗАПИСЫВАЕТ $STACK_DIR/compose.local.yml из
#   tpl/compose/compose.local.yml.tpl. Все файлы — inode текущего юзера.
#   Читает: шаблоны tpl/compose/, наличие каталога
#   $STACK_DIR/benchmarks/prompts, профиль из ТЕКУЩЕГО .env (cur_profile →
#   profile_field поле 3). В stdout — log-строка «стек в …».
#
# Ограничения/допущения: требует глобалы STACK_DIR, MODELS_DIR, TPL_DIR,
#   DRAFT_FILE, log (диспетчер), cur_profile (stack.sh), profile_field
#   (profiles.sh). Порядок: после migrate_state и set_models_dir (state-
#   каталоги и сет моделей должны существовать до генерации) и ДО первого
#   `compose up`/recreate (podman-compose читает каноническую -f-тройку
#   при каждом вызове); .env пишется вызывающим сразу после, до compose up.
#   DFlash-строка выбирается по профилю ПРЕЖНЕГО .env (чистый стек →
#   PROFILE_DEFAULT) и может отличаться от устанавливаемого install'ом;
#   поле 3 — только маркер «есть draft», путь всегда глобал DRAFT_FILE
#   (КОНТЕЙНЕРНЫЙ путь в маунт моделей). prompts-маунт появляется только
#   если каталог уже лежит в стеке — hfctl фикстуры не раскладывает.
#   Локалы prompt_vol/draft_env одной строкой: пустая строка или
#   предформированный YAML-фрагмент (prompt_vol содержит переводы строк).
#
# @returns integer # всегда 0 при возврате — die render_tpl (нераскрытые
#   плейсхолдеры) и сбои mkdir/install завершает set -e
write_stack_files() {
  log "стек в $STACK_DIR"
  mkdir -p "$STACK_DIR" "$MODELS_DIR"
  # бинарь живёт В СТЕКЕ (источник истины; юниты ссылаются на него).
  # Копируем только при отсутствии (обновление — install.sh):
  # перезапись здесь могла бы откатить свежий install.sh-бинарь старым.
  sync_tree
  ensure_symlink

  # compose.yml — дословно из репозитория hipfire 0.4.5 (без monitoring-профилей:
  # они ссылаются на каталоги репо, которые hfctl не разворачивает).
  # СТАТИЧЕСКИЕ файлы: ${VAR:-def} внутри — переменные COMPOSE, не shell —
  # копировать целыми, без shell-экспансии/envsubst (графля brief №2).
  install -m 0644 "$TPL_DIR/compose/compose.yml" "$STACK_DIR/compose.yml"
  install -m 0644 "$TPL_DIR/compose/compose.halo.yml" "$STACK_DIR/compose.halo.yml"

  # compose.local.yml: DFlash-wiring для профилей с draft (mq6-xt не объявляет
  # sidecar в реестре; MQ4 draft — рекомендованный контроллер). Профили без
  # draft (flash-multi: native MTP) получают пустой env = DFlash выключен.
  local prompt_vol="" draft_env=""
  [ -d "$STACK_DIR/benchmarks/prompts" ] && prompt_vol=$'\n    volumes:\n      - ./benchmarks/prompts:/prompts:ro'
  local cur_draft; cur_draft=$(profile_field "$(cur_profile)" 3)
  [ "$cur_draft" != "-" ] && [ -n "$cur_draft" ] && draft_env="      HIPFIRE_DFLASH_DRAFT: $DRAFT_FILE"
  render_tpl "$TPL_DIR/compose/compose.local.yml.tpl" "$STACK_DIR/compose.local.yml" \
    LOCAL_DRAFT_ENV="$draft_env" LOCAL_PROMPTS="$prompt_vol"
}

# ── .env: канон профиля + параметры (порт/bind/путь сохраняем существующие) ─
# Назначение: записать $STACK_DIR/.env — канон профиля (HFCTL_PROFILE) и
#   параметры сервера (модель по умолчанию, порт, bind, путь моделей,
#   state-каталог, образ) из глобалов диспетчера и аргументов; шаблон
#   tpl/env/env.tpl.
#
# Побочные эффекты: ПЕРЕЗАПИСЬ (truncate, inode текущего юзера) файла
#   $STACK_DIR/.env через render_tpl: ключи HFCTL_PROFILE, HIPFIRE_MODEL,
#   HIPFIRE_PORT, HIPFIRE_BIND, HIPFIRE_UI, HIPFIRE_SERVE_ARGS,
#   HIPFIRE_MODELS_PATH (= глобал MODELS_DIR), HIPFIRE_STATE_DIR
#   (= $STATE_BASE/<prof>), HIPFIRE_IMAGE; ручные правки .env теряются
#   (шапка шаблона напоминает про hfctl up). Читает только tpl/env/env.tpl;
#   в stdout не печатает.
#
# Ограничения/допущения: требует глобалы TPL_DIR, STACK_DIR, MODELS_DIR,
#   STATE_BASE, IMAGE, BIND, PORT (диспетчер); MODELS_DIR берётся в момент
#   вызова (его переставляют set_models_dir / env-префикс cmd_pull).
#   Живые вызовы — cmd_install и cmd_use (после write_stack_files и
#   ДО `compose up`/recreate: podman-compose читает HIPFIRE_* из .env) и
#   откат в cmd_use при неподошедшем профиле — ЕДИНСТВЕННЫЙ вызов после
#   compose, без recreate. Откат передаёт prev_prof=cur_profile и
#   prev_model=cur_model как есть: пустой prev_model возможен на
#   вырожденном .env без HIPFIRE_MODEL (fallback cur_model недостижим).
#
# @param 1: '27b-single' | '27b-slots' | 'flash-multi' # канонический id
#   профиля (вызывающие идут после resolve_profile; откат — verbatim
#   cur_profile)
# @param 2: /^[\w.-]+:[\w.-]+$/ | ''                   # модель по умолчанию для
#   HIPFIRE_MODEL (HFCTL_MODEL env / поле 1 профиля / prev_model отката);
#   '' — вырожденный откат с пустым cur_model
# @returns integer                                     # всегда 0 при возврате — die
#   render_tpl и сбой записи завершает процесс (set -e)
write_env() {
  local prof="$1" model="$2"
  render_tpl "$TPL_DIR/env/env.tpl" "$STACK_DIR/.env" \
    MODELS_DIR="$MODELS_DIR" STATE_DIR="$STATE_BASE/$prof" PROFILE="$prof" \
    IMAGE="$IMAGE" MODEL="$model" BIND="$BIND" PORT="$PORT"
}
