# 每个协议使用独立的短时客户端和本机随机响应，验证认证及数据转发，
# 不把本机测试等同于服务商面板映射或外部客户端实测。
verify_protocol_loopback() (
    local protocol="$1" address="${2:-127.0.0.1}" tmp http_port client_port nonce response
    local client_pid="" origin_pid="" outbound="" tls_json
    tmp=$(mktemp -d) || return 1
    chmod 700 "$tmp"
    trap '[[ -z "$client_pid" ]] || { kill "$client_pid" 2>/dev/null || true; wait "$client_pid" 2>/dev/null || true; }; [[ -z "$origin_pid" ]] || { kill "$origin_pid" 2>/dev/null || true; wait "$origin_pid" 2>/dev/null || true; }; rm -rf "$tmp"' EXIT

    http_port=$(select_random_available_tcp_port "$REALITY_PORT" "$SOCKS_PORT" "$HY2_PORT" "$WS_PORT" "$SUBSCRIPTION_PORT") || return 1
    client_port=$(select_random_available_tcp_port "$http_port" "$REALITY_PORT" "$SOCKS_PORT" "$HY2_PORT" "$WS_PORT" "$SUBSCRIPTION_PORT") || return 1
    nonce=$(random_hex 12)
    printf '%s' "$nonce" > "$tmp/challenge"
    timeout 12 python3 -m http.server "$http_port" --bind 127.0.0.1 --directory "$tmp" >/dev/null 2>&1 &
    origin_pid=$!
    case "$protocol" in
        reality)
            tls_json="\"tls\":{\"enabled\":true,\"server_name\":$(json_string "$REALITY_SNI"),\"utls\":{\"enabled\":true,\"fingerprint\":\"chrome\"},\"reality\":{\"enabled\":true,\"public_key\":$(json_string "$PUBLIC_KEY"),\"short_id\":$(json_string "$SHORT_ID")}}"
            outbound="\"type\":\"vless\",\"server\":\"127.0.0.1\",\"server_port\":${REALITY_PORT},\"uuid\":$(json_string "$UUID"),\"flow\":\"xtls-rprx-vision\",${tls_json}"
            ;;
        hy2)
            outbound="\"type\":\"hysteria2\",\"server\":\"127.0.0.1\",\"server_port\":${HY2_PORT},\"password\":$(json_string "$HY2_PASSWORD"),\"up_mbps\":100,\"down_mbps\":100,\"tls\":{\"enabled\":true,\"server_name\":$(json_string "$HY2_SNI"),\"insecure\":true}"
            ;;
        socks)
            outbound="\"type\":\"socks\",\"server\":\"127.0.0.1\",\"server_port\":${SOCKS_PORT},\"version\":\"5\",\"username\":$(json_string "$SOCKS_USERNAME"),\"password\":$(json_string "$SOCKS_PASSWORD")"
            ;;
        argo)
            outbound="\"type\":\"vless\",\"server\":$(json_string "$address"),\"server_port\":443,\"uuid\":$(json_string "$UUID"),\"tls\":{\"enabled\":true,\"server_name\":$(json_string "$ARGO_DOMAIN"),\"utls\":{\"enabled\":true,\"fingerprint\":\"chrome\"}},\"transport\":{\"type\":\"ws\",\"path\":$(json_string "$WS_PATH"),\"headers\":{\"Host\":$(json_string "$ARGO_DOMAIN")}}"
            ;;
        *) return 1 ;;
    esac
    printf '{"log":{"level":"error"},"inbounds":[{"type":"socks","tag":"test-in","listen":"127.0.0.1","listen_port":%s}],"outbounds":[{"tag":"test-out",%s}]}' "$client_port" "$outbound" > "$tmp/client.json"
    chmod 600 "$tmp/client.json"
    timeout 5 sing-box check -c "$tmp/client.json" >/dev/null 2>&1 || return 1
    timeout 12 sing-box run -c "$tmp/client.json" >/dev/null 2>&1 &
    client_pid=$!

    for _ in 1 2; do
        response=$(curl --noproxy '' --proxy "socks5h://127.0.0.1:${client_port}" \
            -fsS --connect-timeout 2 --max-time 4 "http://127.0.0.1:${http_port}/challenge" 2>/dev/null || true)
        [[ "$response" == "$nonce" ]] && return 0
        sleep 1
    done
    return 1
)

verify_subscription_payload() (
    local tmp
    [[ -s "$SUBSCRIPTION_FILE" ]] && is_valid_hostname "${ARGO_DOMAIN:-}" && \
        [[ "${SUB_TOKEN:-}" =~ ^[A-Za-z0-9_-]{1,128}$ ]] || return 1
    tmp=$(mktemp -d) || return 1
    chmod 700 "$tmp"
    trap 'rm -rf "$tmp"' EXIT
    printf 'url = "https://%s/sub/%s"\n' "$ARGO_DOMAIN" "$SUB_TOKEN" > "$tmp/curl.conf"
    chmod 600 "$tmp/curl.conf"
    curl --config "$tmp/curl.conf" --noproxy '*' -fsS --connect-timeout 3 --max-time 8 \
        -o "$tmp/response" >/dev/null 2>&1 && cmp -s "$tmp/response" "$SUBSCRIPTION_FILE"
)

verify_enabled_protocols() {
    local failed=false address
    menu_header "服务与诊断 / 协议自检"
    if ! command -v sing-box >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1 || \
        ! command -v curl >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
        warn "缺少 sing-box / python3 / curl / timeout，协议认证自检未执行"
        return 1
    fi
    if ! timeout 8 sing-box check -c "$CONFIG_FILE" >/dev/null 2>&1; then
        warn "服务配置校验失败，协议自检未执行"
        return 1
    fi
    info "配置通过；开始逐项认证与流量测试（每项限时，公网映射需外部验证）"
    info "Reality：验证中..."
    if { [[ "${REALITY_BACKEND:-singbox}" == "xray" ]] && ! service_is_active xray; } || \
        { [[ "${REALITY_BACKEND:-singbox}" != "xray" ]] && ! service_is_active sing-box; } || \
        ! verify_protocol_loopback reality; then
        warn "Reality：本机认证或流量测试未通过"
        failed=true
    else
        success "Reality：本机认证与流量通过，公网未验证"
    fi
    if is_hy2_enabled; then
        info "Hysteria2：验证中..."
        if service_is_active sing-box && verify_protocol_loopback hy2; then
            success "Hysteria2：本机认证与流量通过，公网 UDP 未验证"
        else
            warn "Hysteria2：本机认证或流量测试未通过"
            failed=true
        fi
    else
        info "Hysteria2：未启用，跳过"
    fi
    if is_socks_enabled; then
        info "SOCKS5：验证中..."
        if service_is_active sing-box && verify_protocol_loopback socks; then
            success "SOCKS5：本机认证与流量通过，公网未验证"
        else
            warn "SOCKS5：本机认证或流量测试未通过"
            failed=true
        fi
    else
        info "SOCKS5：未启用，跳过"
    fi
    if argo_enabled; then
        if ! service_is_active sing-box || ! service_is_active sbm-subscription || ! service_is_active argo-tunnel; then
            warn "Argo：必需服务未运行"
            failed=true
        else
            for address in "${ARGO_BEST_CF_DOMAIN_IPV4:-}" "${ARGO_BEST_CF_DOMAIN_IPV6:-}"; do
                [[ -n "$address" ]] || continue
                info "Argo ${address}：验证中..."
                if verify_protocol_loopback argo "$address"; then
                    success "Argo ${address}：服务端经隧道认证与流量通过，外部客户端未验证"
                else
                    warn "Argo ${address}：认证或流量测试未通过"
                    failed=true
                fi
            done
            if [[ -z "${ARGO_BEST_CF_DOMAIN_IPV4:-}${ARGO_BEST_CF_DOMAIN_IPV6:-}" ]]; then
                warn "Argo：未生成通过探测的连接地址"
                failed=true
            fi
            if verify_subscription_payload; then
                success "HTTPS 订阅：服务端访问与内容校验通过，外部客户端未验证"
            else
                warn "HTTPS 订阅：服务端访问或内容校验未通过"
                failed=true
            fi
        fi
    else
        info "Argo 与订阅：未启用，跳过"
    fi
    [[ "$failed" == "false" ]]
}

do_verify() {
    load_params || { warn "未找到配置，请先安装"; return 1; }
    build_share_links
    verify_enabled_protocols
}
