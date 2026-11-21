[Unit]
Description=hipfire watchdog (hfctl): поднимает стек после нештатного падения

[Service]
Type=oneshot
# ВАЖНО: без KillMode=process systemd при завершении oneshot-юнита убивает
# весь cgroup — вместе с только что поднятым контейнером (SIGTERM/143).
KillMode=process
# CONTAINERS_CONF стека (§14/§15): tracked-файл клона — существует всегда
Environment=CONTAINERS_CONF=__STACK_DIR__/tpl/etc/hfctl-containers.conf
ExecStart=/usr/bin/env bash __STACK_DIR__/hfctl _watchdog
