#!/bin/bash
# hfbox (remote): донастройка хоста для rootless-podman стека hipfire.
# Точечный sudo: apt, usermod render, limits.d, enable-linger, systemd unit.
set -u
STACK="$HF_STACK"            # имя каталога стека в $HOME (обычно "hipfire")
MEMLOCK=1318060032           # нужен NPU-транку (hipfire doctor --npu >= этот байт)
UNIT_DIR="$HOME/.config/systemd/user"
UNIT="$UNIT_DIR/hipfire-compose.service"
USER_NAME=$(id -un)

echo "== 1. apt: podman + podman-compose"
if command -v podman >/dev/null 2>&1 && command -v podman-compose >/dev/null 2>&1; then
  echo "   уже установлены: podman $(podman --version | awk '{print $3}'), $(podman-compose --version 2>&1 | head -1)"
else
  sudo apt-get update -y || true
  sudo apt-get install -y podman podman-compose
fi

echo "== 2. группа render"
if id -nG "$USER_NAME" | grep -qw render; then
  echo "   уже в render"
else
  sudo usermod -aG render "$USER_NAME"
  echo "   добавлен в render (вступит в силу при следующем логине; на уже живых"
  echo "   ssh-сессия право может не действовать — это учтено chmod ниже)"
fi
# render-группа из будущего логина: чтобы текущий контейнер уже видел GPU,
# при podman start из текущей сессии/юнита явного добавления не требуется,
# но /dev/dri и /dev/kfd делаются доступными группе render.
sudo chmod 664 /dev/dri/* 2>/dev/null || true
sudo chmod 664 /dev/kfd 2>/dev/null || true

echo "== 3. limits.d memlock ($MEMLOCK)"
LIMITS=/etc/security/limits.d/99-hipfire-memlock.conf
if sudo test -f "$LIMITS" && grep -q "$MEMLOCK" "$LIMITS" 2>/dev/null; then
  echo "   уже настроен: $(grep "$USER_NAME" "$LIMITS" 2>/dev/null | head -2)"
else
  printf '%s soft memlock %s\n%s hard memlock %s\n' \
    "$USER_NAME" "$MEMLOCK" "$USER_NAME" "$MEMLOCK" | \
    sudo tee "$LIMITS" >/dev/null
  echo "   записан $LIMITS (вступает в силу при следующем логине/юнит-рестарте)"
fi

echo "== 4. systemd --user unit"
mkdir -p "$UNIT_DIR"
cat > "$UNIT" <<EOF
[Unit]
Description=hipfire serve (podman compose stack)
After=podman-user-wait-network-online.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$HOME/$STACK
ExecStart=/usr/bin/podman compose -f compose.yml -f compose.halo.yml -f compose.local.yml up -d
ExecStop=/usr/bin/podman compose -f compose.yml -f compose.halo.yml -f compose.local.yml stop
TimeoutStartSec=900

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable hipfire-compose.service

echo "== 5. linger"
if loginctl show-user "$USER_NAME" 2>/dev/null | grep -q '^Linger=yes'; then
  echo "   уже включён"
else
  sudo loginctl enable-linger "$USER_NAME"
  echo "   включён"
fi

echo "== Итог host_prep: DONE (ступень 4–5 нужна тоже и до up, не только после)"
