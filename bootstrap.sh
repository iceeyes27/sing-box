#!/bin/sh
set -e

INSTALL_URL="https://raw.githubusercontent.com/iceeyes27/sing-box/main/install.sh"

install_bootstrap_deps() {
    need_install=0
    command -v bash >/dev/null 2>&1 || need_install=1
    command -v curl >/dev/null 2>&1 || need_install=1
    [ "$need_install" -eq 1 ] || return 0

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
}

fetch_install_script() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$INSTALL_URL"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- "$INSTALL_URL"
    else
        echo "ERROR: curl or wget is required" >&2
        return 1
    fi
}

install_bootstrap_deps
fetch_install_script | bash
