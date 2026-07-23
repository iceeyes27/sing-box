# ─── Argo 服务 ───────────────────────────────────────────────
ensure_argo_dependencies() {
    if ! command -v python3 >/dev/null 2>&1; then
        info "安装 Argo 订阅网关依赖: python3"
        install_packages_low_resource python3 || {
            warn "python3 安装失败，Argo 订阅网关无法运行"
            return 1
        }
    fi
    install_cloudflared
}

write_argo_service() {
    local cloudflared_bin exec_cmd argo_origin_url systemd_hardening
    if ! argo_enabled; then
        warn "Argo 未启用"
        return 1
    fi
    cloudflared_bin=$(command -v cloudflared 2>/dev/null || echo "/usr/local/bin/cloudflared")
    argo_origin_url="http://127.0.0.1:${SUBSCRIPTION_PORT}"
    if argo_fixed_enabled; then
        info "使用固定域名启动 Argo 隧道"
        info "Cloudflare Public Hostname 需转发至 ${argo_origin_url}"
        write_env_file "$ARGO_ENV_FILE" ARGO_TOKEN "$ARGO_TOKEN" TUNNEL_TOKEN "$ARGO_TOKEN"
        exec_cmd="tunnel --protocol http2 --no-autoupdate run"
    else
        info "使用 Argo 临时隧道 (trycloudflare.com)"
        rm -f "$ARGO_ENV_FILE"
        exec_cmd="tunnel --url ${argo_origin_url} --no-autoupdate --protocol http2"
    fi

    if [[ "$(service_manager)" == "openrc" ]]; then
        cat > "$ARGO_OPENRC_SERVICE" << EOF
#!/sbin/openrc-run
name="argo-tunnel"
description="Cloudflare Argo Tunnel"
command="${cloudflared_bin}"
command_args="${exec_cmd}"
command_background=true
pidfile="/run/argo-tunnel.pid"
output_log="/var/log/argo-tunnel.log"
error_log="/var/log/argo-tunnel.log"
EOF
        if argo_fixed_enabled; then
            cat >> "$ARGO_OPENRC_SERVICE" << EOF
env_file="${ARGO_ENV_FILE}"
start_pre() {
    if [ -r "\${env_file}" ]; then
        set -a
        . "\${env_file}"
        set +a
    fi
}
EOF
        fi
        cat >> "$ARGO_OPENRC_SERVICE" << 'EOF'

depend() {
    need net
    after sing-box
}
EOF
        chmod 755 "$ARGO_OPENRC_SERVICE"
        return
    fi

    systemd_hardening=$(systemd_hardening_block)
    cat > "$ARGO_SERVICE" << EOF
[Unit]
Description=Cloudflare Argo Tunnel
After=network.target sing-box.service
Wants=sing-box.service

[Service]
Type=simple
User=nobody
EOF
    argo_fixed_enabled && printf 'EnvironmentFile=%s\n' "$ARGO_ENV_FILE" >> "$ARGO_SERVICE"
    cat >> "$ARGO_SERVICE" << EOF
ExecStart=${cloudflared_bin} ${exec_cmd}
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
${systemd_hardening}

[Install]
WantedBy=multi-user.target
EOF
    service_daemon_reload
}

# ─── 订阅服务 ────────────────────────────────────────────────
write_subscription_server() {
    cat > "$SUBSCRIPTION_SERVER" << 'PYEOF'
#!/usr/bin/env python3
import argparse
import os
import select
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


def build_handler(token: str, data_file: str, upstream_host: str, upstream_port: int):
    subscription_path = f"/sub/{token}"
    data_path = Path(data_file)

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            parsed = urlparse(self.path)
            query_token = parse_qs(parsed.query).get("token", [""])[0]
            token_ok = parsed.path == subscription_path or (
                parsed.path == "/sub" and query_token == token
            )

            if parsed.path.startswith("/sub"):
                if not token_ok:
                    self.send_response(403)
                    self.send_header("Content-Type", "text/plain; charset=utf-8")
                    self.end_headers()
                    self.wfile.write(b"Forbidden\n")
                    return
            else:
                self.proxy_to_upstream()
                return

            if not data_path.exists():
                self.send_response(503)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.end_headers()
                self.wfile.write(b"Subscription is not ready\n")
                return

            payload = data_path.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def proxy_to_upstream(self):
            self.close_connection = True
            try:
                upstream = socket.create_connection((upstream_host, upstream_port), timeout=10)
            except OSError:
                self.send_response(502)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.end_headers()
                self.wfile.write(b"Upstream is not ready\n")
                return

            with upstream:
                upstream.settimeout(None)
                is_upgrade = self.headers.get("Upgrade", "").lower() == "websocket"
                request_lines = [f"{self.command} {self.path} HTTP/1.1\r\n"]
                for key, value in self.headers.items():
                    lower_key = key.lower()
                    if lower_key in {"host", "connection", "proxy-connection", "keep-alive"}:
                        continue
                    request_lines.append(f"{key}: {value}\r\n")
                request_lines.append(f"Host: {upstream_host}:{upstream_port}\r\n")
                request_lines.append("Connection: Upgrade\r\n" if is_upgrade else "Connection: close\r\n")
                request_lines.append("\r\n")
                upstream.sendall("".join(request_lines).encode("iso-8859-1"))
                self.relay(upstream)

        def relay(self, upstream):
            sockets = [self.connection, upstream]
            while True:
                readable, _, _ = select.select(sockets, [], [], 60)
                if not readable:
                    continue
                for source in readable:
                    chunk = source.recv(65536)
                    if not chunk:
                        return
                    target = upstream if source is self.connection else self.connection
                    target.sendall(chunk)

        def log_message(self, format, *args):
            return

    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--token")
    parser.add_argument("--token-env", default="SUB_TOKEN")
    parser.add_argument("--file", required=True)
    parser.add_argument("--upstream-host", default="127.0.0.1")
    parser.add_argument("--upstream-port", type=int, required=True)
    args = parser.parse_args()

    class Server(ThreadingHTTPServer):
        address_family = socket.AF_INET6 if ":" in args.listen else socket.AF_INET

        def server_bind(self):
            if self.address_family == socket.AF_INET6 and hasattr(socket, "IPV6_V6ONLY"):
                try:
                    self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
                except OSError:
                    pass
            return super().server_bind()

    token = args.token or os.environ.get(args.token_env)
    if not token:
        raise SystemExit("subscription token is required")

    server = Server((args.listen, args.port), build_handler(token, args.file, args.upstream_host, args.upstream_port))
    server.serve_forever()


if __name__ == "__main__":
    main()
PYEOF
    chmod 755 "$SUBSCRIPTION_SERVER"
}

subscription_listen_host() {
    echo "127.0.0.1"
}

write_subscription_service() {
    local listen_host systemd_hardening
    listen_host=$(subscription_listen_host)
    write_env_file "$SUBSCRIPTION_ENV_FILE" SUB_TOKEN "${SUB_TOKEN:-}"

    if [[ "$(service_manager)" == "openrc" ]]; then
        cat > "$SUBSCRIPTION_OPENRC_SERVICE" << EOF
#!/sbin/openrc-run
name="sbm-subscription"
description="SBM Subscription Server"
command="/usr/bin/python3"
command_args="${SUBSCRIPTION_SERVER} --listen ${listen_host} --port ${SUBSCRIPTION_PORT} --file ${SUBSCRIPTION_FILE} --upstream-host 127.0.0.1 --upstream-port ${WS_PORT}"
command_background=true
pidfile="/run/sbm-subscription.pid"
output_log="/var/log/sbm-subscription.log"
error_log="/var/log/sbm-subscription.log"
env_file="${SUBSCRIPTION_ENV_FILE}"

start_pre() {
    if [ -r "\${env_file}" ]; then
        set -a
        . "\${env_file}"
        set +a
    fi
}

depend() {
    need net
}
EOF
        chmod 755 "$SUBSCRIPTION_OPENRC_SERVICE"
        return
    fi

    systemd_hardening=$(systemd_hardening_block)
    cat > "$SUBSCRIPTION_SERVICE" << EOF
[Unit]
Description=SBM Subscription Server
After=network.target

[Service]
Type=simple
EnvironmentFile=${SUBSCRIPTION_ENV_FILE}
ExecStart=/usr/bin/env python3 ${SUBSCRIPTION_SERVER} --listen ${listen_host} --port ${SUBSCRIPTION_PORT} --file ${SUBSCRIPTION_FILE} --upstream-host 127.0.0.1 --upstream-port ${WS_PORT}
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
${systemd_hardening}

[Install]
WantedBy=multi-user.target
EOF
    service_daemon_reload
}

ensure_subscription_service() {
    validate_port "${SUBSCRIPTION_PORT}" "订阅服务" || return 1
    if ! command -v python3 &>/dev/null; then
        warn "未检测到 python3，无法启动订阅服务"
        return 1
    fi

    write_subscription_server
    write_subscription_service

    service_enable_now sbm-subscription
}

ensure_subscription_service_if_enabled() {
    argo_enabled || return 0
    ensure_subscription_service
}

argo_quick_domain_alive() {
    local domain="$1" code
    is_valid_hostname "$domain" || return 1
    code=$(curl -so /dev/null --connect-timeout 3 --max-time 6 -w '%{http_code}' \
        "https://${domain}/" 2>/dev/null || true)
    case "$code" in
        ''|000|52[0-9]|53[0-9]) return 1 ;;
        *) return 0 ;;
    esac
}

fetch_argo_domain() {
    local max=15 i=0 candidate="" previous_domain="${ARGO_DOMAIN:-}"

    argo_quick_enabled || return 0
    ARGO_DOMAIN=""
    while (( i < max )); do
        candidate=$(service_logs argo-tunnel 1000 2>/dev/null | \
            grep -Eo 'https://[[:alnum:]-]+\.trycloudflare\.com' | \
            tail -1 | sed 's|https://||')
        if [[ -n "$candidate" ]] && argo_quick_domain_alive "$candidate"; then
            ARGO_DOMAIN="$candidate"
            [[ "$ARGO_DOMAIN" == "$previous_domain" ]] || clear_argo_best_cf_cache
            return 0
        fi
        i=$((i + 1))
        sleep 2
    done

    if [[ -n "$candidate" ]]; then
        ARGO_DOMAIN="$candidate"
        warn "Argo 临时域名暂未通过存活验证，已保留日志中的最新域名: ${candidate}"
        return 0
    fi
    ARGO_DOMAIN="$previous_domain"
    return 1
}

refresh_argo_domain_if_needed() {
    argo_quick_enabled || return 0
    service_is_active argo-tunnel || return 0
    if [[ -n "${ARGO_DOMAIN:-}" ]] && argo_quick_domain_alive "$ARGO_DOMAIN"; then
        return 0
    fi
    if fetch_argo_domain; then
        save_params
    fi
    return 0
}

refresh_argo_runtime() {
    if ! argo_enabled; then
        service_stop argo-tunnel 2>/dev/null || true
        service_disable argo-tunnel 2>/dev/null || true
        service_stop sbm-subscription 2>/dev/null || true
        service_disable sbm-subscription 2>/dev/null || true
        ARGO_ENABLED="false"
        ARGO_TOKEN=""
        ARGO_DOMAIN=""
        rm -f "$ARGO_ENV_FILE"
        clear_argo_best_cf_cache
        save_params
        return 0
    fi

    ensure_argo_dependencies || return 1
    write_argo_service || return 1
    if service_is_active argo-tunnel; then
        service_restart argo-tunnel || return 1
    elif ! service_enable_now argo-tunnel; then
        warn "argo-tunnel 重启失败，无法更新 Argo 订阅链接"
        return 1
    fi

    if argo_quick_enabled; then
        sleep 3
        if ! fetch_argo_domain; then
            warn "未能从 cloudflared 日志取得 Argo 临时域名"
            return 1
        fi
    fi

    save_params
    return 0
}

update_argo_subscription_links() {
    if ! argo_enabled; then
        warn "当前未启用 Argo"
        return 1
    fi
    refresh_argo_runtime || return 1
    generate_and_show_links
    ensure_subscription_service_if_enabled || warn "订阅服务启动失败，请检查 python3 或服务日志"
    success "Argo 订阅链接已更新"
    show_subscription_url
}
