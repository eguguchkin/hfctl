[Unit]
Description=hipfire serve (podman compose stack, hfctl)
After=podman-user-wait-network-online.service

[Service]
Type=oneshot
RemainAfterExit=yes
# не убивать cgroup контейнеров при остановке юнита
KillMode=process
WorkingDirectory=__STACK_DIR__
# CONTAINERS_CONF стека (§14/§15): tracked-файл клона — существует всегда
Environment=CONTAINERS_CONF=__STACK_DIR__/tpl/etc/hfctl-containers.conf
ExecStart=/usr/bin/env bash __STACK_DIR__/hfctl _boot
ExecStop=__PODMAN_BIN__ compose __CF__ stop
TimeoutStartSec=900
Restart=on-failure
RestartSec=30

[Install]
WantedBy=default.target
