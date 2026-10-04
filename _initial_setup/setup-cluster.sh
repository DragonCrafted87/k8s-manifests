#!/bin/sh
# OpenMandriva install for the single k3s server roost-drake
# at 192.168.0.54. Workload apply is a later step.
set -eu

hostnamectl set-hostname roost-drake.stealthdragonland.net
if grep -q '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
    sed -i 's/^127\.0\.1\.1[[:space:]].*/127.0.1.1 roost-drake.stealthdragonland.net roost-drake/' /etc/hosts
else
    printf '%s\n' '127.0.1.1 roost-drake.stealthdragonland.net roost-drake' >> /etc/hosts
fi
hostname -f

dnf info nfs-utils
dnf info cifs-utils
dnf install -y nfs-utils cifs-utils

if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port=6443/tcp
    firewall-cmd --permanent --add-port=10250/tcp
    firewall-cmd --permanent --add-port=8472/udp
    firewall-cmd --reload
fi

curl -sfL https://get.k3s.io | sh -s - server \
    --disable traefik \
    --disable servicelb \
    --node-name roost-drake \
    --tls-san roost-drake.stealthdragonland.net \
    --resolv-conf /run/systemd/resolve/resolv.conf \
    --write-kubeconfig-mode 644

/usr/local/bin/k3s kubectl get nodes

# MetalLB v0.16.0, then manifests/01_infrastructure/metallb/pool.yml.
# SMB CSI v1.20.3, then manifests/01_infrastructure/smb/volumes.yml.
# Apply the rest of manifests/ only after those two are Ready.
# Do not apply the later/ directory.
