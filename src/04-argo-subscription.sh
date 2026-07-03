# ─── Argo 服务 ───────────────────────────────────────────────
write_argo_service() {
    local cloudflared_bin exec_cmd argo_origin_url systemd_hardening
    cloudflared_bin=$(command -v cloudflared 2>/dev/null || echo "/usr/local/bin/cloudflared")
    argo_origin_url="http://127.0.0.1:${SUBSCRIPTION_PORT}"

    if [[ -n "${ARGO_TOKEN:-}" ]]; then
        info "使用 Token 模式启动 Argo 隧道 (固定域名)"
        info "Cloudflare Public Hostname 需转发至 ${argo_origin_url}"
        write_env_file "$ARGO_ENV_FILE" ARGO_TOKEN "$ARGO_TOKEN" TUNNEL_TOKEN "$ARGO_TOKEN"
        # --protocol auto: 优先 QUIC(抗丢包/抖动更强)，出站 UDP 7844 被封时自动回退 http2。
        # --retries 8: 边缘连接出错时多重试几次，尽量让进程存活而不是退出。
        exec_cmd="tunnel --protocol auto --retries 8 --no-autoupdate run"
    else
        info "使用临时隧道模式 (trycloudflare.com)"
        exec_cmd="tunnel --url ${argo_origin_url} --no-autoupdate --protocol auto --retries 8"
    fi

    if [[ "$(service_manager)" == "openrc" ]]; then
        cat > "$ARGO_OPENRC_SERVICE" << EOF
#!/sbin/openrc-run
name="argo-tunnel"
description="Cloudflare Argo Tunnel"
command="${cloudflared_bin}"
command_args="${exec_cmd}"
# supervise-daemon 会在 cloudflared 崩溃退出后自动重启，等价于 systemd 的 Restart=always。
supervisor=supervise-daemon
respawn_delay=5
respawn_max=0
pidfile="/run/argo-tunnel.pid"
output_log="/var/log/argo-tunnel.log"
error_log="/var/log/argo-tunnel.log"
EOF
        if [[ -n "${ARGO_TOKEN:-}" ]]; then
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
StartLimitIntervalSec=0

[Service]
Type=simple
User=nobody
Group=nogroup
EOF
    [[ -n "${ARGO_TOKEN:-}" ]] && printf 'EnvironmentFile=%s\n' "$ARGO_ENV_FILE" >> "$ARGO_SERVICE"
    cat >> "$ARGO_SERVICE" << EOF
ExecStart=${cloudflared_bin} ${exec_cmd}
Restart=always
RestartSec=5
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

# ─── 获取 Argo 域名 ──────────────────────────────────────────
fetch_argo_domain() {
    if [[ -n "${ARGO_TOKEN:-}" ]]; then
        # Token 模式下，如果用户没填域名，提醒一下
        if [[ -z "${ARGO_DOMAIN:-}" ]]; then
            warn "检测到 Token 模式但未配置自定义域名，分享链接将不包含 Argo 节点。"
            return 1
        fi
        return 0
    fi

    # 临时域名模式获取逻辑
    local max=10 i=0
    local previous_domain="${ARGO_DOMAIN:-}"
    ARGO_DOMAIN=""
    while [[ $i -lt $max ]]; do
        ARGO_DOMAIN=$(service_logs argo-tunnel 1000 2>/dev/null | \
                      grep -Eo 'https://[[:alnum:]-]+\.trycloudflare\.com' | \
                      tail -1 | sed 's|https://||')
        if [[ -n "$ARGO_DOMAIN" ]]; then
            if [[ -n "$previous_domain" && "$ARGO_DOMAIN" != "$previous_domain" ]]; then
                clear_argo_best_cf_cache
                info "检测到新的 Argo 临时域名，已清空缓存的优选接入域名"
            fi
            return 0
        fi
        i=$((i + 1))
        sleep 3
    done
    return 1
}

refresh_argo_domain_if_needed() {
    # 本函数在 set -e 下常被裸调用，任何路径都必须返回 0：
    # 「argo-tunnel 未运行」「域名未变化」都是正常情况，
    # 若透传非零返回码会直接终止整个脚本。
    service_is_active argo-tunnel || return 0

    if [[ -n "${ARGO_TOKEN:-}" ]]; then
        # 固定域名模式域名由用户配置，进程重启也不变，无需从日志重新抓取。
        return 0
    fi

    # 临时隧道每次重启都会分配新的随机域名，缓存里的旧域名会变成死链。
    # 因此这里总是以 cloudflared 当前进程日志中的域名为准，抓到新域名就刷新缓存，
    # 保证 `sbm links` 输出的永远是当前实际可用的临时域名。
    local cached_domain="${ARGO_DOMAIN:-}"
    if fetch_argo_domain 2>/dev/null; then
        if [[ "${ARGO_DOMAIN:-}" != "$cached_domain" ]]; then
            save_params
        fi
    else
        # 抓取失败(如日志已滚动或进程刚起还没打印域名)时回退到缓存域名，
        # 避免 Argo 链接直接消失。
        ARGO_DOMAIN="$cached_domain"
    fi
    return 0
}

refresh_argo_runtime() {
    if [[ -n "${ARGO_TOKEN:-}" && -z "${ARGO_DOMAIN:-}" ]]; then
        warn "固定域名模式缺少 Argo 域名，无法生成 Argo 订阅链接"
        return 1
    fi

    if [[ -z "${ARGO_TOKEN:-}" ]]; then
        ARGO_DOMAIN=""
        clear_argo_best_cf_cache
    fi

    write_argo_service
    if ! service_restart argo-tunnel; then
        warn "argo-tunnel 重启失败，无法更新 Argo 订阅链接"
        return 1
    fi

    if [[ -z "${ARGO_TOKEN:-}" ]]; then
        sleep 5
        if ! fetch_argo_domain; then
            warn "未获取到新的 Argo 临时域名，订阅链接未更新"
            return 1
        fi
    fi

    save_params
    return 0
}

update_argo_subscription_links() {
    refresh_argo_runtime || return 1
    generate_and_show_links
    ensure_subscription_service || warn "订阅服务启动失败，请检查 python3 或服务日志"
    success "Argo 订阅链接已更新"
    show_subscription_url
}

