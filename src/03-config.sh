# ─── 生成参数 ────────────────────────────────────────────────
generate_params() {
    info "生成安全参数..."
    UUID=$(sing-box generate uuid)
    SHORT_ID=$(random_hex 4)

    local keypair
    keypair=$(sing-box generate reality-keypair)
    PRIVATE_KEY=$(echo "$keypair" | grep -i "PrivateKey" | awk '{print $NF}')
    PUBLIC_KEY=$(echo "$keypair" | grep -i "PublicKey"  | awk '{print $NF}')

    REALITY_PORT=${REALITY_PORT:-$(select_random_available_tcp_port)}
    # Reality 承载内核：singbox(默认) 或 xray。可通过环境变量 REALITY_BACKEND=xray 选择。
    REALITY_BACKEND="${REALITY_BACKEND:-singbox}"
    # 新安装先保持为空，由安装流程按连续握手结果选择；探测失败仍回退默认 SNI。
    REALITY_SNI="${REALITY_SNI:-}"
    WS_PORT=8080
    WS_PATH="/${SHORT_ID}"
    NODE_NAME=${NODE_NAME:-"sing-box-vps"}
    SUB_TOKEN=$(random_hex 16)
    SUBSCRIPTION_PORT=${SUBSCRIPTION_PORT:-24630}
    ARGO_DOMAIN=""
    ARGO_TOKEN=""
    ARGO_ENABLED="true"
    ARGO_BEST_CF_DOMAIN=""
    ARGO_BEST_CF_DOMAIN_IPV4=""
    ARGO_BEST_CF_DOMAIN_IPV6=""
    LINK_IPV4_SELECTION="all"
    PUBLIC_IPV4_OVERRIDE=""
    NAT_MODE="false"
    REALITY_PUBLIC_PORT="${REALITY_PORT}"

    # Hysteria2 参数
    HY2_PORT=${HY2_PORT:-${HY2_DEFAULT_PORT}}
    HY2_PUBLIC_PORT="${HY2_PORT}"
    HY2_PASSWORD=$(random_base64 16)
    HY2_SNI="${HY2_DEFAULT_SNI}"
    HY2_MASQUERADE_URL="${HY2_DEFAULT_MASQUERADE_URL}"
    HY2_ENABLED="false"

    success "参数生成完成"
}

# ─── TLS 证书生成 (Hysteria2) ────────────────────────────────
generate_tls_cert() {
    local key_file="${CONFIG_DIR}/server.key"
    local cert_file="${CONFIG_DIR}/server.crt"

    is_hy2_enabled || return 0

    if [[ -f "$key_file" && -f "$cert_file" ]]; then
        info "TLS 证书已存在，跳过生成"
        return
    fi

    if ! command -v openssl &>/dev/null; then
        HY2_ENABLED="false"
        warn "未检测到 openssl，跳过 Hysteria2 证书生成；本次部署将仅启用 Reality / Argo"
        return 0
    fi

    info "生成自签 TLS 证书 (Hysteria2)..."
    if ! openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$key_file" -out "$cert_file" \
        -days 3650 -nodes -subj "/CN=${HY2_SNI}" 2>/dev/null; then
        HY2_ENABLED="false"
        warn "Hysteria2 证书生成失败；本次部署将仅启用 Reality / Argo"
        return 0
    fi
    chmod 600 "$key_file" "$cert_file"
    HY2_ENABLED="true"
    success "TLS 自签证书已生成 (有效期 10 年)"
}

is_hy2_enabled() {
    [[ "${HY2_ENABLED:-false}" == "true" ]]
}

# ─── 端口 / 防火墙检查 ───────────────────────────────────────
validate_port() {
    local port=$1
    local label=$2

    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        warn "${label} 端口必须是数字: ${port}"
        return 1
    fi
    if (( port < 1 || port > 65535 )); then
        warn "${label} 端口超出范围 (1-65535): ${port}"
        return 1
    fi
    return 0
}

get_port_listeners() {
    local port=$1
    local proto=$2

    if command -v ss &>/dev/null; then
        if [[ "$proto" == "tcp" ]]; then
            ss -H -ltnp "( sport = :${port} )" 2>/dev/null || true
        else
            ss -H -lunp "( sport = :${port} )" 2>/dev/null || true
        fi
        return 0
    fi

    if command -v netstat &>/dev/null; then
        if [[ "$proto" == "tcp" ]]; then
            netstat -lntp 2>/dev/null | awk -v p=":${port}$" '$4 ~ p'
        else
            netstat -lnup 2>/dev/null | awk -v p=":${port}$" '$4 ~ p'
        fi
        return 0
    fi

    if command -v lsof &>/dev/null; then
        if [[ "$proto" == "tcp" ]]; then
            lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null || true
        else
            lsof -nP -iUDP:"$port" 2>/dev/null || true
        fi
        return 0
    fi

    warn "未找到 ss/netstat/lsof，跳过 ${proto^^} 端口占用检查"
    return 0
}

select_random_available_tcp_port() {
    local attempt candidate listeners

    for attempt in $(seq 1 100); do
        candidate=$((10000 + (((RANDOM << 15) | RANDOM) % 55536)))
        case "$candidate" in
            24630) continue ;;
        esac
        listeners=$(get_port_listeners "$candidate" tcp 2>/dev/null || true)
        [[ -z "$listeners" ]] || continue
        printf '%s\n' "$candidate"
        return 0
    done

    # 极端环境下无法读取监听表时仍给出稳定的高位默认值，后续端口校验会再次确认。
    printf '28805\n'
}

assert_port_available() {
    local port=$1
    local proto=$2
    local label=$3
    local listeners

    listeners=$(get_port_listeners "$port" "$proto")
    if [[ -n "$listeners" ]]; then
        warn "${label} 需要的 ${proto^^} 端口 ${port} 已被占用:"
        echo "$listeners" | head -n 3
        return 1
    fi
    success "${label} 使用的 ${proto^^} 端口 ${port} 当前可绑定"
    return 0
}

detect_firewall_backend() {
    local ufw_status
    local iptables_input

    if command -v ufw &>/dev/null; then
        ufw_status=$(ufw status 2>/dev/null | head -n 1 || true)
        if [[ "$ufw_status" =~ [Ss]tatus:\ active ]]; then
            echo "ufw"
            return 0
        fi
    fi

    if command -v firewall-cmd &>/dev/null; then
        if [[ "$(firewall-cmd --state 2>/dev/null || true)" == "running" ]]; then
            echo "firewalld"
            return 0
        fi
    fi

    if command -v iptables &>/dev/null; then
        iptables_input=$(iptables -S INPUT 2>/dev/null || true)
        if [[ -n "$iptables_input" ]] && echo "$iptables_input" | grep -Eq '^-P INPUT (DROP|REJECT)$|^-A INPUT '; then
            echo "iptables"
            return 0
        fi
    fi

    echo "none"
}

firewall_backend_label() {
    case "$1" in
        ufw) echo "UFW" ;;
        firewalld) echo "firewalld" ;;
        iptables) echo "iptables" ;;
        *) echo "none" ;;
    esac
}

firewall_port_open() {
    local backend=$1
    local port=$2
    local proto=$3

    case "$backend" in
        ufw)
            ufw status 2>/dev/null | grep -Eq "(^|[[:space:]])${port}/${proto}([[:space:]]|$).*ALLOW"
            ;;
        firewalld)
            firewall-cmd --query-port="${port}/${proto}" 2>/dev/null | grep -qx 'yes' || \
                firewall-cmd --permanent --query-port="${port}/${proto}" 2>/dev/null | grep -qx 'yes'
            ;;
        iptables)
            iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null
            ;;
        none)
            return 1
            ;;
        *)
            return 1
            ;;
    esac
}

# ─── 防火墙放行 ──────────────────────────────────────────────
open_firewall() {
    local port=$1
    local backend=$2
    shift 2 || true
    local protocol
    local protocols=("$@")

    if [[ -z "${backend:-}" ]]; then
        backend=$(detect_firewall_backend)
    fi
    if [[ ${#protocols[@]} -eq 0 ]]; then
        protocols=(tcp udp)
    fi

    if [[ "$backend" == "none" ]]; then
        warn "未检测到启用中的 UFW / firewalld / iptables 规则，跳过本机自动放行端口 ${port}"
        warn "如果你使用 NAT 小鸡、云安全组或厂商面板防火墙，请到外部面板手动放行对应端口"
        return 0
    fi

    info "检测到防火墙方案: $(firewall_backend_label "$backend")，检查端口 ${port} 放行状态"

    for protocol in "${protocols[@]}"; do
        if firewall_port_open "$backend" "$port" "$protocol"; then
            info "端口 ${port}/${protocol} 已放行"
            continue
        fi

        info "放行端口 ${port}/${protocol}..."
        case "$backend" in
            ufw)
                ufw allow "${port}/${protocol}" >/dev/null 2>&1
                ;;
            firewalld)
                firewall-cmd --permanent --add-port="${port}/${protocol}" >/dev/null 2>&1
                firewall-cmd --reload >/dev/null 2>&1
                ;;
            iptables)
                iptables -C INPUT -p "$protocol" --dport "$port" -j ACCEPT 2>/dev/null || \
                    iptables -I INPUT -p "$protocol" --dport "$port" -j ACCEPT >/dev/null 2>&1
                ;;
        esac

        if firewall_port_open "$backend" "$port" "$protocol"; then
            success "端口 ${port}/${protocol} 已通过 $(firewall_backend_label "$backend") 放行"
        else
            warn "端口 ${port}/${protocol} 放行失败，请手动检查 $(firewall_backend_label "$backend") 规则"
            return 1
        fi
    done

    return 0
}

open_service_ports() {
    local backend
    backend=$(detect_firewall_backend)

    [[ -n "${REALITY_PORT:-}" ]] && open_firewall "$REALITY_PORT" "$backend" tcp || return 1
    if is_hy2_enabled && [[ -n "${HY2_PORT:-}" ]]; then
        open_firewall "$HY2_PORT" "$backend" udp || return 1
    fi
    return 0
}

validate_service_ports() {
    local old_reality_port=${1:-}
    local old_hy2_port=${2:-}
    local old_subscription_port=${3:-}
    local should_open_firewall=${4:-true}

    validate_port "${REALITY_PORT:-}" "Reality" || return 1
    if argo_enabled; then
        validate_port "${WS_PORT:-}" "VLESS-WS" || return 1
    fi
    if is_hy2_enabled; then
        validate_port "${HY2_PORT:-}" "Hysteria2" || return 1
    fi
    if nat_mode_enabled; then
        validate_port "${REALITY_PUBLIC_PORT:-}" "NAT Reality 公网映射" || return 1
        if is_hy2_enabled; then
            validate_port "${HY2_PUBLIC_PORT:-}" "NAT Hysteria2 公网映射" || return 1
        fi
    fi
    if argo_enabled; then
        validate_port "${SUBSCRIPTION_PORT:-}" "订阅服务" || return 1
    fi

    if argo_enabled && [[ "${REALITY_PORT}" == "${WS_PORT}" ]]; then
        warn "Reality 端口 ${REALITY_PORT}/TCP 与 VLESS-WS 内部端口 ${WS_PORT}/TCP 冲突"
        return 1
    fi
    if argo_enabled && [[ "${SUBSCRIPTION_PORT}" == "${REALITY_PORT}" || "${SUBSCRIPTION_PORT}" == "${WS_PORT}" ]]; then
        warn "订阅服务端口 ${SUBSCRIPTION_PORT}/TCP 与现有 TCP 服务端口冲突"
        return 1
    fi

    if [[ -z "$old_reality_port" || "$REALITY_PORT" != "$old_reality_port" ]]; then
        assert_port_available "$REALITY_PORT" "tcp" "Reality" || return 1
    else
        info "Reality 端口未变化，跳过占用检查"
    fi

    if is_hy2_enabled && [[ -z "$old_hy2_port" || "$HY2_PORT" != "$old_hy2_port" ]]; then
        assert_port_available "$HY2_PORT" "udp" "Hysteria2" || return 1
    elif is_hy2_enabled; then
        info "Hysteria2 端口未变化，跳过占用检查"
    fi

    if argo_enabled && [[ -z "$old_reality_port" ]]; then
        assert_port_available "$WS_PORT" "tcp" "VLESS-WS" || return 1
    fi

    if argo_enabled; then
        if [[ -z "$old_subscription_port" || "$SUBSCRIPTION_PORT" != "$old_subscription_port" ]]; then
            assert_port_available "$SUBSCRIPTION_PORT" "tcp" "订阅服务" || return 1
        else
            info "订阅服务端口未变化，跳过占用检查"
        fi
    fi

    if [[ "$should_open_firewall" == "true" ]]; then
        open_service_ports || return 1
    fi
    return 0
}

prompt_port_value() {
    local __var_name=$1
    local label=$2
    local current=$3
    local prompt=$4
    local input candidate

    while true; do
        prompt_read input "$prompt" || return 1
        candidate="${input:-$current}"
        if validate_port "$candidate" "$label"; then
            printf -v "$__var_name" '%s' "$candidate"
            return 0
        fi
        warn "请重新输入 ${label} 端口"
    done
}

show_port_confirmation() {
    echo ""
    echo -e "${CYAN}${BOLD}── 端口确认 ──${NC}"
    echo -e "  Reality:      ${BOLD}${REALITY_PORT}/TCP${NC}"
    if ! is_hy2_enabled; then
        echo -e "  Hysteria2:    ${DIM}未启用${NC}"
    elif [[ "${HY2_PORT}" == "${REALITY_PORT}" ]]; then
        echo -e "  Hysteria2:    ${BOLD}${HY2_PORT}/UDP${NC} ${DIM}(与 Reality 共用端口号，协议不同)${NC}"
    else
        echo -e "  Hysteria2:    ${BOLD}${HY2_PORT}/UDP${NC}"
    fi
    if nat_mode_enabled; then
        echo -e "  NAT Reality:  ${BOLD}${REALITY_PUBLIC_PORT}/TCP -> ${REALITY_PORT}/TCP${NC}"
        if is_hy2_enabled; then
            echo -e "  NAT Hysteria2:${BOLD}${HY2_PUBLIC_PORT}/UDP -> ${HY2_PORT}/UDP${NC}"
        fi
    fi
    if argo_enabled; then
        echo -e "  订阅服务:     ${BOLD}${SUBSCRIPTION_PORT}/TCP${NC} ${DIM}(仅本机/Argo 使用)${NC}"
    fi
    if nat_mode_enabled; then
        echo -e "  本机防火墙:   ${BOLD}${REALITY_PORT}/TCP${NC}$(is_hy2_enabled && printf ', %s/UDP' "$HY2_PORT")"
        echo -e "  服务商面板:   ${BOLD}${REALITY_PUBLIC_PORT}/TCP${NC}$(is_hy2_enabled && printf ', %s/UDP' "$HY2_PUBLIC_PORT")"
    elif is_hy2_enabled; then
        echo -e "  需要外部放行: ${BOLD}${REALITY_PORT}/TCP${NC}, ${BOLD}${HY2_PORT}/UDP${NC}"
    else
        echo -e "  需要外部放行: ${BOLD}${REALITY_PORT}/TCP${NC}"
    fi
    argo_enabled && echo -e "  不需要外部放行: ${BOLD}${SUBSCRIPTION_PORT}/TCP${NC}"
    echo ""
}

prompt_nat_mapping_config() {
    local detected_mode input candidate

    detected_mode=$(detect_external_access_mode)
    if [[ "$detected_mode" != "nat" ]]; then
        NAT_MODE="false"
        REALITY_PUBLIC_PORT="${REALITY_PORT}"
        HY2_PUBLIC_PORT="${HY2_PORT}"
        return 0
    fi

    if ! nat_mode_enabled; then
        REALITY_PUBLIC_PORT="${REALITY_PORT}"
        HY2_PUBLIC_PORT="${HY2_PORT}"
    fi
    NAT_MODE="true"
    PUBLIC_IPV4_OVERRIDE="${PUBLIC_IPV4:-${PUBLIC_IP:-}}"
    REALITY_PUBLIC_PORT="${REALITY_PUBLIC_PORT:-${REALITY_PORT}}"
    HY2_PUBLIC_PORT="${HY2_PUBLIC_PORT:-${HY2_PORT}}"
    echo ""
    echo -e "${CYAN}${BOLD}── NAT 公网映射 ──${NC}"
    echo -e "  检测到公网 IPv4 不在本机网卡，按 NAT VPS 配置。"
    echo -e "  公网 IPv4: ${BOLD}${PUBLIC_IPV4_OVERRIDE}${NC}"
    prompt_port_value REALITY_PUBLIC_PORT "NAT Reality 公网映射" "$REALITY_PUBLIC_PORT" \
        "  面板分配的 Reality 公网 TCP 端口 [${REALITY_PUBLIC_PORT}]: " || return 1
    if is_hy2_enabled; then
        while true; do
            prompt_read input "  面板分配的 Hysteria2 公网 UDP 端口 [${HY2_PUBLIC_PORT}]，输入 0 禁用: " || return 1
            candidate="${input:-$HY2_PUBLIC_PORT}"
            if [[ "$candidate" == "0" ]]; then
                HY2_ENABLED="false"
                info "NAT 面板未提供 UDP 映射，已禁用 Hysteria2"
                break
            fi
            if validate_port "$candidate" "NAT Hysteria2 公网映射"; then
                HY2_PUBLIC_PORT="$candidate"
                break
            fi
        done
    fi
}

confirm_port_selection() {
    local input

    show_port_confirmation
    prompt_read input "  按 Enter 继续，输入 r 重新选择: " || return 1
    [[ "$input" =~ ^[Rr]$ ]] && return 1
    return 0
}

public_ipv4_override_label() {
    if [[ -n "${PUBLIC_IPV4_OVERRIDE:-}" ]]; then
        printf '%s' "$PUBLIC_IPV4_OVERRIDE"
    else
        printf '自动检测'
    fi
}

prompt_public_ipv4_override_optional() {
    local input

    while true; do
        prompt_read input "  请输入用于直连链接的公网 IPv4 (留空跳过): " || return 1
        [[ -z "$input" ]] && return 1
        if is_valid_public_ipv4_for_link "$input"; then
            PUBLIC_IPV4_OVERRIDE="$input"
            LINK_IPV4_SELECTION="all"
            reset_public_ip_cache
            success "已设置直连公网 IPv4 覆盖: ${PUBLIC_IPV4_OVERRIDE}"
            return 0
        fi
        warn "无效的公网 IPv4。请勿填写私网、回环、CGNAT、多播或保留地址。"
    done
}

prompt_public_ipv4_override() {
    local choice input

    echo ""
    echo -e "${CYAN}${BOLD}── 直连公网 IPv4 覆盖 ──${NC}"
    echo -e "  当前覆盖值: ${BOLD}$(public_ipv4_override_label)${NC}"
    echo -e "  ${DIM}该值仅用于生成 Reality/Hysteria2 直连分享链接和订阅内容，不会修改服务端监听配置。${NC}"
    echo -e "  1) 设置/修改覆盖 IPv4"
    echo -e "  2) 清除覆盖，恢复自动检测"
    echo -e "  0) 取消"
    prompt_read choice "  请选择 [0]: " || return 1
    choice=${choice:-0}

    case "$choice" in
        1)
            while true; do
                prompt_read input "  请输入用于直连链接的公网 IPv4: " || return 1
                if is_valid_public_ipv4_for_link "$input"; then
                    PUBLIC_IPV4_OVERRIDE="$input"
                    LINK_IPV4_SELECTION="all"
                    reset_public_ip_cache
                    success "已设置直连公网 IPv4 覆盖: ${PUBLIC_IPV4_OVERRIDE}"
                    return 0
                fi
                warn "无效的公网 IPv4。请勿填写私网、回环、CGNAT、多播或保留地址。"
            done
            ;;
        2)
            PUBLIC_IPV4_OVERRIDE=""
            LINK_IPV4_SELECTION="all"
            reset_public_ip_cache
            success "已清除直连公网 IPv4 覆盖，恢复自动检测。"
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

prompt_ipv4_link_selection_if_multiple() {
    local count input index ip selected all_option

    if [[ -n "${PUBLIC_IPV4_OVERRIDE:-}" ]]; then
        warn "当前已设置直连公网 IPv4 覆盖，多 IPv4 链接策略暂不生效。请先清除覆盖值。"
        return 1
    fi
    refresh_public_ip_stack || return 1
    count=$(public_ipv4_candidate_count)
    if (( count <= 1 )); then
        return 1
    fi

    echo ""
    echo -e "${CYAN}${BOLD}── 多 IPv4 链接策略 ──${NC}"
    echo -e "  检测到多个 IPv4: ${BOLD}$(public_ipv4_display)${NC}"
    index=1
    while IFS= read -r ip; do
        [[ -n "$ip" ]] || continue
        if (( index == 1 )); then
            echo -e "  ${index}) 仅启用 ${ip} ${GREEN}推荐${NC}"
        else
            echo -e "  ${index}) 仅启用 ${ip}"
        fi
        index=$((index + 1))
    done <<< "$PUBLIC_IPV4_LIST"
    all_option=$index
    echo -e "  ${all_option}) 全部启用"

    prompt_read input "  请选择 [1]: " || input=1
    input=${input:-1}

    if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input < all_option )); then
        selected=$(printf '%s\n' "$PUBLIC_IPV4_LIST" | sed -n "${input}p")
        LINK_IPV4_SELECTION="$selected"
    elif [[ "$input" == "$all_option" ]]; then
        LINK_IPV4_SELECTION="all"
    else
        LINK_IPV4_SELECTION=$(printf '%s\n' "$PUBLIC_IPV4_LIST" | sed -n '1p')
    fi

    info "已选择 IPv4 链接策略: $(link_ipv4_selection_label)"
    return 0
}

show_external_access_requirements() {
    local access_mode
    access_mode=$(detect_external_access_mode)

    echo -e "${CYAN}${BOLD}── 外部放行提示 ──${NC}"
    case "$access_mode" in
        ipv6-only)
            echo -e "  检测到 IPv6-only VPS；通过 Argo 生成外部节点链接。"
            if argo_enabled; then
                echo -e "  Argo 的 ${WS_PORT}/TCP 仅供本机回环/隧道使用，一般不需要在外部面板放行。"
                echo -e "  Subscription: ${BOLD}HTTPS Argo 域名${NC} ${DIM}(本机 ${SUBSCRIPTION_PORT}/TCP 不需要外部放行)${NC}"
            fi
            echo ""
            return
            ;;
        dual-stack)
            echo -e "  检测到 IPv4 + IPv6 双栈 VPS，Reality/Hysteria2 直连节点使用 IPv4。"
            echo -e "  订阅地址通过 Argo HTTPS 域名访问，本机订阅端口不需要外部放行。"
            ;;
        direct)
            echo -e "  本机检测到公网 IP 直接挂载在网卡上。若仍有安全组/云防火墙，请同步放行以下端口。"
            ;;
        nat)
            echo -e "  检测到当前环境疑似 NAT / 转发型 VPS。仅修改本机防火墙通常不够，必须在面板额外放行或映射端口。"
            [[ -n "${PUBLIC_IPV4_OVERRIDE:-}" ]] && echo -e "  当前直连链接使用手动覆盖 IPv4: ${BOLD}${PUBLIC_IPV4_OVERRIDE}${NC}"
            ;;
        panel)
            echo -e "  当前环境未检测到公网 IP 直接挂载在本机网卡，可能经过宿主机、防火墙面板或云安全组。请在外部面板同步放行。"
            [[ -n "${PUBLIC_IPV4_OVERRIDE:-}" ]] && echo -e "  当前直连链接使用手动覆盖 IPv4: ${BOLD}${PUBLIC_IPV4_OVERRIDE}${NC}"
            ;;
        unknown)
            echo -e "  未能检测公网地址，请按实际网络环境放行端口。"
            echo -e "  如需直连 Reality/Hysteria2，请在修改配置中设置直连公网 IPv4 覆盖。"
            ;;
    esac
    if [[ -n "${PUBLIC_IPV4_OVERRIDE:-}" ]]; then
        echo -e "  IPv4 链接策略: ${BOLD}$(link_ipv4_selection_label)${NC} (${BOLD}$(public_ipv4_display)${NC})"
    elif (( $(public_ipv4_candidate_count) > 1 )); then
        echo -e "  IPv4 链接策略: ${BOLD}$(link_ipv4_selection_label)${NC} (${BOLD}$(public_ipv4_display)${NC})"
    fi
    echo -e "  Reality:      ${BOLD}${REALITY_PORT}/TCP${NC}"
    if ! is_hy2_enabled; then
        echo -e "  Hysteria2:    ${DIM}未启用${NC}"
    elif [[ "${HY2_PORT}" == "${REALITY_PORT}" ]]; then
        echo -e "  Hysteria2:    ${BOLD}${HY2_PORT}/UDP${NC} ${DIM}(与 Reality 共用端口号，但协议不同)${NC}"
    else
        echo -e "  Hysteria2:    ${BOLD}${HY2_PORT}/UDP${NC}"
    fi
    if argo_enabled; then
        echo -e "  Subscription: ${BOLD}HTTPS Argo 域名${NC} ${DIM}(本机 ${SUBSCRIPTION_PORT}/TCP 不需要外部放行)${NC}"
        echo -e "  ${DIM}Argo 和订阅网关均仅供本机回环/隧道使用，一般不需要在外部面板放行。${NC}"
    fi
    if nat_mode_enabled; then
        echo -e "  NAT Reality: ${BOLD}${REALITY_PUBLIC_PORT}/TCP -> ${REALITY_PORT}/TCP${NC}"
        if is_hy2_enabled; then
            echo -e "  NAT Hysteria2: ${BOLD}${HY2_PUBLIC_PORT}/UDP -> ${HY2_PORT}/UDP${NC}"
        fi
    fi
    echo ""
}

# ─── sing-box 配置生成 ───────────────────────────────────────
write_singbox_config() {
    # 关键变量校验: 防止空值写入配置导致 sing-box 崩溃
    local missing=""
    [[ -z "${UUID:-}" ]]        && missing+="UUID "
    [[ -z "${REALITY_PORT:-}" ]] && missing+="REALITY_PORT "
    [[ -z "${REALITY_SNI:-}" ]] && missing+="REALITY_SNI "
    [[ -z "${PRIVATE_KEY:-}" ]] && missing+="PRIVATE_KEY "
    [[ -z "${SHORT_ID:-}" ]]    && missing+="SHORT_ID "
    if argo_enabled; then
        [[ -z "${WS_PORT:-}" ]] && missing+="WS_PORT "
        [[ -z "${WS_PATH:-}" ]] && missing+="WS_PATH "
    fi
    if is_hy2_enabled; then
        [[ -z "${HY2_PORT:-}" ]]    && missing+="HY2_PORT "
        [[ -z "${HY2_PASSWORD:-}" ]] && missing+="HY2_PASSWORD "
        [[ -z "${HY2_SNI:-}" ]]     && missing+="HY2_SNI "
        [[ -z "${HY2_MASQUERADE_URL:-}" ]] && missing+="HY2_MASQUERADE_URL "
    fi
    if [[ -n "$missing" ]]; then
        error "配置生成失败: 以下关键变量为空: ${missing}"
    fi

    local json_uuid json_reality_sni json_private_key json_short_id json_ws_path argo_inbound hy2_inbound
    local json_hy2_password json_hy2_sni json_key_path json_cert_path json_hy2_masquerade_url
    local reality_inbound inbounds_joined inbound_part

    json_uuid=$(json_string "$UUID")
    json_reality_sni=$(json_string "$REALITY_SNI")
    json_private_key=$(json_string "$PRIVATE_KEY")
    json_short_id=$(json_string "$SHORT_ID")
    argo_inbound=""
    if argo_enabled; then
        json_ws_path=$(json_string "$WS_PATH")
        argo_inbound=$(cat << ARGO_EOF
        {
            "type": "vless",
            "tag": "vless-ws-argo",
            "listen": "127.0.0.1",
            "listen_port": ${WS_PORT},
            "users": [
                {
                    "uuid": ${json_uuid}
                }
            ],
            "transport": {
                "type": "ws",
                "path": ${json_ws_path}
            }
        }
ARGO_EOF
)
    fi
    hy2_inbound=""
    if is_hy2_enabled; then
        json_hy2_password=$(json_string "$HY2_PASSWORD")
        json_hy2_sni=$(json_string "$HY2_SNI")
        json_key_path=$(json_string "${CONFIG_DIR}/server.key")
        json_cert_path=$(json_string "${CONFIG_DIR}/server.crt")
        json_hy2_masquerade_url=$(json_string "$HY2_MASQUERADE_URL")
        hy2_inbound=$(cat << HY2_EOF
        {
            "type": "hysteria2",
            "tag": "hysteria2-in",
            "listen": "::",
            "listen_port": ${HY2_PORT},
            "up_mbps": 100,
            "down_mbps": 100,
            "users": [
                {
                    "password": ${json_hy2_password}
                }
            ],
            "tls": {
                "enabled": true,
                "server_name": ${json_hy2_sni},
                "key_path": ${json_key_path},
                "certificate_path": ${json_cert_path}
            },
            "masquerade": {
                "type": "proxy",
                "url": ${json_hy2_masquerade_url},
                "rewrite_host": true
            }
        }
HY2_EOF
)
    fi

    # Reality 入站：仅当 Reality 由 sing-box 自己承载时才写入。
    # REALITY_BACKEND=xray 时该入站交给 Xray-core，sing-box 让出该端口。
    reality_inbound=""
    if [[ "${REALITY_BACKEND:-singbox}" != "xray" ]]; then
        reality_inbound=$(cat << REALITY_EOF
        {
            "type": "vless",
            "tag": "vless-reality",
            "listen": "::",
            "listen_port": ${REALITY_PORT},
            "users": [
                {
                    "uuid": ${json_uuid},
                    "flow": "xtls-rprx-vision"
                }
            ],
            "tls": {
                "enabled": true,
                "server_name": ${json_reality_sni},
                "reality": {
                    "enabled": true,
                    "handshake": {
                        "server": ${json_reality_sni},
                        "server_port": 443
                    },
                    "private_key": ${json_private_key},
                    "short_id": [
                        ${json_short_id}
                    ]
                }
            }
        }
REALITY_EOF
)
    fi

    # 按顺序拼接非空入站，自动处理逗号，避免首项缺失时产生非法 JSON。
    inbounds_joined=""
    for inbound_part in "$reality_inbound" "$argo_inbound" "$hy2_inbound"; do
        [[ -n "$inbound_part" ]] || continue
        if [[ -z "$inbounds_joined" ]]; then
            inbounds_joined="$inbound_part"
        else
            inbounds_joined="${inbounds_joined},"$'\n'"$inbound_part"
        fi
    done

    cat > "$CONFIG_FILE" << SINGBOX_EOF
{
    "log": {
        "level": "warn",
        "timestamp": true
    },
    "inbounds": [
${inbounds_joined}
    ],
    "outbounds": [
        {
            "type": "direct",
            "tag": "direct"
        },
        {
            "type": "block",
            "tag": "block"
        }
    ]
}
SINGBOX_EOF

    chmod 600 "$CONFIG_FILE"
    chown root:root "$CONFIG_FILE"

    local check_output
    if check_output=$(sing-box check -c "$CONFIG_FILE" 2>&1); then
        success "配置校验通过"
    else
        warn "配置校验失败，详细信息:"
        echo -e "${RED}${check_output}${NC}"
        error "请检查上方错误并修复后重试"
    fi
}

systemd_hardening_block() {
    cat <<'EOF'
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
SystemCallArchitectures=native
EOF
}
