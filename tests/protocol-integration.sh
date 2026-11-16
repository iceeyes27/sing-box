#!/usr/bin/env bash
# Optional real-core loopback integration test; does not touch installed services.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SBM_TEST_MODE=1
source "${ROOT_DIR}/install.sh"

read -r -a integration_protocols <<< "${SBM_TEST_PROTOCOLS:-reality hy2 socks}"
for integration_protocol in "${integration_protocols[@]}"; do
    case "$integration_protocol" in
        reality|hy2|socks) ;;
        *) echo "Unsupported test protocol: $integration_protocol" >&2; exit 1 ;;
    esac
done

integration_dir=$(mktemp -d /tmp/sbm-protocol-test.XXXXXX)
integration_pid=""
cleanup() {
    if [[ -n "$integration_pid" ]]; then
        kill "$integration_pid" 2>/dev/null || true
        wait "$integration_pid" 2>/dev/null || true
    fi
    [[ "$integration_dir" == /tmp/sbm-protocol-test.* ]] && rm -rf "$integration_dir"
}
trap cleanup EXIT

if ! command -v sing-box >/dev/null 2>&1; then
    case "$(uname -m)" in
        x86_64) integration_arch=amd64 ;;
        aarch64) integration_arch=arm64 ;;
        *) echo "Unsupported test architecture" >&2; exit 1 ;;
    esac
    integration_tag=$(curl -fsSL --connect-timeout 5 --max-time 12 \
        https://api.github.com/repos/SagerNet/sing-box/releases/latest \
        | sed -n 's/.*"tag_name": "\([^"]*\)".*/\1/p')
    [[ "$integration_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Cannot resolve sing-box release" >&2; exit 1; }
    integration_package="sing-box-${integration_tag#v}-linux-${integration_arch}-musl"
    curl -fsSL --retry 1 --connect-timeout 5 --max-time 45 \
        "https://github.com/SagerNet/sing-box/releases/download/${integration_tag}/${integration_package}.tar.gz" \
        -o "${integration_dir}/core.tgz"
    tar -xzf "${integration_dir}/core.tgz" -C "$integration_dir"
    PATH="${integration_dir}/${integration_package}:$PATH"
fi

CONFIG_DIR="$integration_dir"
CONFIG_FILE="${integration_dir}/config.json"
REALITY_BACKEND=singbox
REALITY_PORT=$(select_random_available_tcp_port)
SOCKS_PORT=$(select_random_available_tcp_port "$REALITY_PORT")
HY2_PORT=8443
integration_hy2_port=$(select_random_available_tcp_port "$REALITY_PORT" "$SOCKS_PORT" "$HY2_PORT")
WS_PORT=$(select_random_available_tcp_port "$REALITY_PORT" "$SOCKS_PORT" "$HY2_PORT" "$integration_hy2_port")
SUBSCRIPTION_PORT=$(select_random_available_tcp_port "$REALITY_PORT" "$SOCKS_PORT" "$HY2_PORT" "$integration_hy2_port" "$WS_PORT")
UUID=$(sing-box generate uuid)
integration_keys=$(sing-box generate reality-keypair)
PRIVATE_KEY=$(printf '%s\n' "$integration_keys" | grep -i 'PrivateKey' | awk '{print $NF}')
PUBLIC_KEY=$(printf '%s\n' "$integration_keys" | grep -i 'PublicKey' | awk '{print $NF}')
SHORT_ID=$(random_hex 4)
REALITY_SNI=www.nazhumi.com
ARGO_ENABLED=false
HY2_ENABLED=false
SOCKS_ENABLED=true
HY2_PASSWORD=$(random_base64 16)
HY2_SNI=example.com
SOCKS_USERNAME=integration-user
SOCKS_PASSWORD=$(random_hex 16)
prompt_read() { read -r "$1"; }
changed=false; ports_changed=false; restart_singbox=false
modify_hy2_enabled <<< "$integration_hy2_port" >/dev/null
[[ "$HY2_ENABLED" == true && "$HY2_PORT" == "$integration_hy2_port" ]] || { echo "HY2 custom-port enable failed" >&2; exit 1; }
generate_tls_cert >/dev/null
is_hy2_enabled || { echo "HY2 certificate generation failed" >&2; exit 1; }
chown() { :; }
write_singbox_config >/dev/null
timeout 50 sing-box run -c "$CONFIG_FILE" >"${integration_dir}/core.log" 2>&1 &
integration_pid=$!
sleep 1
for integration_protocol in "${integration_protocols[@]}"; do
    if verify_protocol_loopback "$integration_protocol"; then
        printf 'PASS: %s authenticated loopback traffic\n' "$integration_protocol"
    else
        printf 'FAIL: %s authenticated loopback traffic\n' "$integration_protocol" >&2
        exit 1
    fi
done
# Changing the local HY2 port must still allow authenticated UDP traffic.
integration_old_hy2_port="$HY2_PORT"
integration_hy2_port=$(select_random_available_tcp_port "$REALITY_PORT" "$SOCKS_PORT" "$HY2_PORT" "$WS_PORT" "$SUBSCRIPTION_PORT")
modify_hy2_port <<< "$integration_hy2_port" >/dev/null
[[ "$HY2_PORT" == "$integration_hy2_port" ]] || { echo "HY2 custom-port edit failed" >&2; exit 1; }
kill "$integration_pid"
wait "$integration_pid" 2>/dev/null || true
integration_pid=""
write_singbox_config >/dev/null
timeout 50 sing-box run -c "$CONFIG_FILE" >"${integration_dir}/core.log" 2>&1 &
integration_pid=$!
sleep 1
if verify_protocol_loopback hy2; then
    printf 'PASS: hy2 local port change %s -> %s authenticated loopback traffic\n' "$integration_old_hy2_port" "$HY2_PORT"
else
    printf 'FAIL: hy2 authenticated loopback traffic after local port change\n' >&2
    exit 1
fi
if [[ " ${integration_protocols[*]} " == *" socks "* ]]; then
    if verify_protocol_loopback socks ::1; then
        printf 'PASS: socks IPv6 authenticated loopback traffic\n'
    else
        printf 'FAIL: socks IPv6 authenticated loopback traffic\n' >&2
        exit 1
    fi
fi
