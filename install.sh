#!/usr/bin/env bash
# install.sh — bootstrap hfctl: кладёт бинарь в стек (~/hipfire/hfctl — там
# его ждут юниты) и симлинк в ~/.local/bin (без sudo). Сам сервер НЕ ставит
# — это делает 'hfctl install'.
#
# Два способа запуска:
#   1) из клона репозитория:   git clone <repo> && cd hfctl && ./install.sh
#   2) одной строкой (curl):   curl -fsSL <raw_url>/install.sh | bash
#
# Идемпотентен: повторный запуск просто обновляет бинарь (и симлинк).
set -euo pipefail

STACK_DIR="${HFCTL_DIR:-$HOME/hipfire}"
BIN_DIR="${HFCTL_BIN_DIR:-$HOME/.local/bin}"
RAW_URL="${HFCTL_RAW_URL:-https://raw.githubusercontent.com/ORG/hfctl/master}"

err() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; }
ok()  { printf '\033[1;32mOK:\033[0m %s\n' "$*"; }

# ── откуда брать hfctl: рядом со скриптом (клон) или из сети (curl|bash) ────
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -n "$script_dir" ] && [ -f "$script_dir/hfctl" ]; then
  cp "$script_dir/hfctl" "$tmp"
  echo "источник: локальный клон ($script_dir/hfctl)"
else
  # curl-режим: качаем в стек
  echo "источник: $RAW_URL/hfctl"
  curl -fsSL "$RAW_URL/hfctl" -o "$tmp" || { err "не смог скачать hfctl — проверь сеть или задай HFCTL_RAW_URL"; exit 1; }
fi
command -v bash >/dev/null || { err "нужен bash"; exit 1; }

# ── бинарь живёт В СТЕКЕ (источник истины: юниты и вотчдог ссылаются на него)
mkdir -p "$STACK_DIR"
install -m 0755 "$tmp" "$STACK_DIR/hfctl"
ok "hfctl → $STACK_DIR/hfctl"

# ── ~/.local/bin/hfctl = симлинк в стек (одна копия, рассинхрон невозможен) ─
mkdir -p "$BIN_DIR"
ln -sfn "$STACK_DIR/hfctl" "$BIN_DIR/hfctl"
ok "симлинк: $BIN_DIR/hfctl → $STACK_DIR/hfctl"

# ── PATH ────────────────────────────────────────────────────────────────────
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    echo
    echo "ВАЖНО: $BIN_DIR не в PATH. Выполни одну из команд:"
    echo "  echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.bashrc && source ~/.bashrc"
    echo "  (или перелогинься — ~/.profile подхватит ~/.local/bin сам)"
    ;;
esac

# ── следующий шаг ───────────────────────────────────────────────────────────
cat <<EOF

Готово. Дальше (постановка сервера, ~15–40 GB скачивания, sudo точечно):

  hfctl install            # профиль 27b-single по умолчанию + автозапуск

Полезно сразу: 'hfctl doctor' — проверить железо до скачивания.
Профили: 27b-single | 27b-slots | flash-multi (см. 'hfctl models').
Обновление бинаря: повтори этот же install.sh (стек останется на месте).
EOF
