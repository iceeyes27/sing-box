#!/usr/bin/env bash
# Optional real-core loopback integration test; does not touch installed services.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SBM_TEST_MODE=1
source "${ROOT_DIR}/install.sh"

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
HY2_PORT=$(select_random_available_tcp_port "$REALITY_PORT" "$SOCKS_PORT")
WS_PORT=$(select_random_available_tcp_port "$REALITY_PORT" "$SOCKS_PORT" "$HY2_PORT")
SUBSCRIPTION_PORT=$(select_random_available_tcp_port "$REALITY_PORT" "$SOCKS_PORT" "$HY2_PORT" "$WS_PORT")
UUID=$(sing-box generate uuid)
integration_keys=$(sing-box generate reality-keypair)
PRIVATE_KEY=$(printf '%s\n' "$integration_keys" | grep -i 'PrivateKey' | awk '{print $NF}')
PUBLIC_KEY=$(printf '%s\n' "$integration_keys" | grep -i 'PublicKey' | awk '{print $NF}')
SHORT_ID=$(random_hex 4)
REALITY_SNI=www.nazhumi.com
ARGO_ENABLED=false
HY2_ENABLED=true
SOCKS_ENABLED=true
HY2_PASSWORD=$(random_base64 16)
HY2_SNI=example.com
SOCKS_USERNAME=integration-user
SOCKS_PASSWORD=$(random_hex 16)
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 \
    -subj /CN=example.com -keyout "${integration_dir}/server.key" \
    -out "${integration_dir}/server.crt" >/dev/null 2>&1
chown() { :; }
write_singbox_config >/dev/null
timeout 50 sing-box run -c "$CONFIG_FILE" >"${integration_dir}/core.log" 2>&1 &
integration_pid=$!
sleep 1
for integration_protocol in reality hy2 socks; do
    if verify_protocol_loopback "$integration_protocol"; then
        printf 'PASS: %s authenticated loopback traffic\n' "$integration_protocol"
    else
        printf 'FAIL: %s authenticated loopback traffic\n' "$integration_protocol" >&2
        exit 1
    fi
done
