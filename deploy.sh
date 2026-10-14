#!/usr/bin/env bash

set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
    echo "Run this script as root: sudo ./deploy.sh" >&2
    exit 1
fi

if [[ ! -r /etc/os-release ]]; then
    echo "Cannot identify the operating system." >&2
    exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release

if [[ ${ID:-} != "ubuntu" ]]; then
    echo "This installer supports Ubuntu only (detected: ${ID:-unknown})." >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install --yes --no-install-recommends \
    apt-listchanges \
    btop \
    ca-certificates \
    certbot \
    curl \
    netcat-openbsd \
    nginx \
    python3-certbot-nginx \
    ufw \
    unattended-upgrades \
    wireguard-tools

swap_file=/swapfile

if [[ ! -e ${swap_file} ]]; then
    if ! fallocate --length 1G "${swap_file}"; then
        dd if=/dev/zero of="${swap_file}" bs=1M count=1024 status=progress
    fi
    chmod 600 "${swap_file}"
    mkswap "${swap_file}"
elif [[ $(blkid --output value --match-tag TYPE "${swap_file}" 2>/dev/null || true) != "swap" ]]; then
    echo "${swap_file} exists but is not swap space; refusing to overwrite it." >&2
    exit 1
fi

chmod 600 "${swap_file}"
if ! swapon --show=NAME --noheadings | grep --quiet --fixed-strings "${swap_file}"; then
    swapon "${swap_file}"
fi

if ! grep --quiet --fixed-strings "${swap_file} none swap sw 0 0" /etc/fstab; then
    printf '%s\n' "${swap_file} none swap sw 0 0" >> /etc/fstab
fi

printf '%s\n' 'vm.swappiness=10' > /etc/sysctl.d/99-realgoodapi-swap.conf
sysctl --load /etc/sysctl.d/99-realgoodapi-swap.conf

printf '%s\n' \
    'APT::Periodic::Update-Package-Lists "1";' \
    'APT::Periodic::Unattended-Upgrade "1";' \
    > /etc/apt/apt.conf.d/20auto-upgrades

printf '%s\n' \
    'Unattended-Upgrade::Automatic-Reboot "false";' \
    > /etc/apt/apt.conf.d/52realgoodapi-unattended-upgrades

systemctl enable --now unattended-upgrades.service

echo "Installed dependencies, enabled 1 GB swap, and enabled unattended security updates."
