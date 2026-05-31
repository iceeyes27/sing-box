#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

bash scripts/build-install.sh
bash -n install.sh
bash -n tests/regression.sh

export SBM_TEST_MODE=1
# shellcheck source=../install.sh
source install.sh

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local label="$3"
    [[ "$actual" == "$expected" ]] || fail "${label}: expected '${expected}', got '${actual}'"
}

pm=$(package_manager)
case "$pm" in
    apt|dnf|yum|apk|none) ;;
    *) fail "unexpected package manager: ${pm}" ;;
esac

sm=$(service_manager)
case "$sm" in
    systemd|openrc|none) ;;
    *) fail "unexpected service manager: ${sm}" ;;
esac

arch=$(get_singbox_release_arch 2>/dev/null || true)
case "$(uname -m)" in
    x86_64|amd64) assert_eq "amd64" "$arch" "x86_64 sing-box arch" ;;
    aarch64|arm64) assert_eq "arm64" "$arch" "arm64 sing-box arch" ;;
    armv7l|armv7) assert_eq "armv7" "$arch" "armv7 sing-box arch" ;;
    i386|i686|x86) assert_eq "386" "$arch" "386 sing-box arch" ;;
    *) [[ -z "$arch" ]] || fail "unsupported arch should not map: ${arch}" ;;
esac

profile=$(get_resource_profile)
case "$profile" in
    low-noswap|low-swap|standard|high|unknown) ;;
    *) fail "unexpected resource profile: ${profile}" ;;
esac

cpu_profile=$(get_cpu_profile)
case "$cpu_profile" in
    low|standard|high) ;;
    *) fail "unexpected cpu profile: ${cpu_profile}" ;;
esac

listen=$(subscription_listen_host)
assert_eq "127.0.0.1" "$listen" "subscription listen host"

printf 'OK: smoke passed (%s, %s, %s, %s)\n' "$pm" "$sm" "${arch:-unsupported}" "$profile"
