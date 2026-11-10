# shellcheck shell=bash
# ── файлы стека (официальные compose-файлы hipfire 0.4.5 — в tpl/compose/) ──
render_tpl() {  # render_tpl <file.tpl> <out> <NAME=value> ...
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

sync_tree() {  # дерево (hfctl+lib+tpl) в стек; «копируем только при отсутствии»
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

ensure_symlink() {  # ~/.local/bin/hfctl → бинарь в стеке (вариант 2: стек = истина)
  local bin_dir="$HOME/.local/bin"
  mkdir -p "$bin_dir"
  ln -sfn "$STACK_DIR/hfctl" "$bin_dir/hfctl"
}
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
write_env() {  # write_env <profile_id> <default_model>
  local prof="$1" model="$2"
  render_tpl "$TPL_DIR/env/env.tpl" "$STACK_DIR/.env" \
    MODELS_DIR="$MODELS_DIR" STATE_DIR="$STATE_BASE/$prof" PROFILE="$prof" \
    IMAGE="$IMAGE" MODEL="$model" BIND="$BIND" PORT="$PORT"
}
