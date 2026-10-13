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
    ca-certificates \
    certbot \
    curl \
    nginx \
    python3-certbot-nginx \
    ufw \
    wireguard-tools

echo "Installed Nginx, WireGuard, Certbot, UFW, and diagnostic tools."
