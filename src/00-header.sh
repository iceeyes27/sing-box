#!/usr/bin/env bash
#
# ════════════════════════════════════════════════════════════════
#  sing-box 一键部署 & 管理脚本
#  VLESS + Reality (直连) + VLESS + WS (Cloudflare Argo)
#  支持在线一键安装 / 交互式管理 / Cloudflare 优选 IP
# ════════════════════════════════════════════════════════════════
#
#  在线安装:
#    bash <(curl -fsSL "https://raw.githubusercontent.com/iceeyes27/sing-box/main/install.sh")
#

if [ -z "${BASH_VERSION:-}" ]; then
    set -e
    INSTALL_URL="https://raw.githubusercontent.com/iceeyes27/sing-box/main/install.sh"
    tmp_file="${TMPDIR:-/tmp}/sbm-install.$$"
    trap 'rm -f "$tmp_file"' EXIT HUP INT TERM

    if ! command -v bash >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
        if command -v apk >/dev/null 2>&1; then
            apk add --no-cache bash curl
        elif command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq
            apt-get install -y -qq --no-install-recommends bash curl
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y -q bash curl
        elif command -v yum >/dev/null 2>&1; then
            yum install -y -q bash curl
        fi
    fi

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$INSTALL_URL" -o "$tmp_file"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$tmp_file" "$INSTALL_URL"
    else
        echo "ERROR: curl or wget is required" >&2
        exit 1
    fi

    exec bash "$tmp_file" "$@"
fi

set -euo pipefail

