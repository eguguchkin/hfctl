[Unit]
Description=hipfire watchdog (hfctl): поднимает стек после нештатного падения

[Service]
Type=oneshot
# ВАЖНО: без KillMode=process systemd при завершении oneshot-юнита убивает
# весь cgroup — вместе с только что поднятым контейнером (SIGTERM/143).
KillMode=process
# CONTAINERS_CONF стека (§14): файл ставит cmd_autostart ДО рендера юнитов
Environment=CONTAINERS_CONF=__STACK_DIR__/.hfctl-containers.conf
ExecStart=/usr/bin/env bash __STACK_DIR__/hfctl _watchdog
