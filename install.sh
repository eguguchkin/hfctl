#!/usr/bin/env bash
# install.sh — bootstrap hfctl: дерево целиком (диспетчер hfctl + lib/ +
# tpl/) из локального клона (единственный источник) кладёт в стек
# ~/hipfire/ (там его ждут юниты) и симлинк в ~/.local/bin (без sudo).
# Сам сервер НЕ ставит — это делает 'hfctl install'.
#
# Способ запуска:
#   git clone <repo> && cd hfctl && ./install.sh
#
# Идемпотентен: повторный запуск из того же клона просто перезаписывает те
# же элементы (md5-равные). Свежий клон → install.sh = обновление бинаря
# (AGENTS правило 5); остальное в стеке (models/, profiles/, .env,
# compose*, benchmarks/) install.sh не трогает.
set -euo pipefail

STACK_DIR="${HFCTL_DIR:-$HOME/hipfire}"
BIN_DIR="${HFCTL_BIN_DIR:-$HOME/.local/bin}"

err() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; }
ok()  { printf '\033[1;32mOK:\033[0m %s\n' "$*"; }

# ── источник: дерево рядом со скриптом (git clone); других режимов нет ──────
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -z "$script_dir" ] || [ ! -f "$script_dir/hfctl" ] \
   || [ ! -d "$script_dir/lib" ] || [ ! -d "$script_dir/tpl" ]; then
  err "дерево hfctl неполное: рядом нет lib/ и tpl/ — установи через git clone + ./install.sh"
  exit 1
fi
echo "источник: локальный клон ($script_dir)"
command -v bash >/dev/null || { err "нужен bash"; exit 1; }

# ── бинарь живёт В СТЕКЕ (источник истины: юниты и вотчдог ссылаются на него);
# обновление = перезапись ровно трёх элементов: hfctl, lib/, tpl/
mkdir -p "$STACK_DIR"
rm -rf "${STACK_DIR:?}/hfctl" "${STACK_DIR:?}/lib" "${STACK_DIR:?}/tpl"
install -m 0755 "$script_dir/hfctl" "$STACK_DIR/hfctl"
cp -a "$script_dir/lib" "$STACK_DIR/lib"
cp -a "$script_dir/tpl" "$STACK_DIR/tpl"
ok "hfctl → $STACK_DIR/hfctl (+lib/, tpl/)"

# ── ~/.local/bin/hfctl = симлинк в стек (одна копия, рассинхрон невозможен) ─
mkdir -p "$BIN_DIR"
# ln -sfn НЕ заменяет существующий РЕАЛЬНЫЙ файл — удаляем явно
[ -L "$BIN_DIR/hfctl" ] || [ ! -e "$BIN_DIR/hfctl" ] || rm -f "$BIN_DIR/hfctl"
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
Обновление бинаря: свежий клон репозитория → тот же install.sh (стек и модели останутся).
EOF
