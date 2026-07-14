# ─── 生成参数 ────────────────────────────────────────────────
generate_params() {
    info "生成安全参数..."
    UUID=$(sing-box generate uuid)
    SHORT_ID=$(openssl rand -hex 4)

    local keypair
    keypair=$(sing-box generate reality-keypair)
    PRIVATE_KEY=$(echo "$keypair" | grep -i "PrivateKey" | awk '{print $NF}')
    PUBLIC_KEY=$(echo "$keypair" | grep -i "PublicKey"  | awk '{print $NF}')

    REALITY_PORT=${REALITY_PORT:-443}
    REALITY_SNI="" # 在配置时通过测速自动选择
    WS_PORT=8080
    WS_PATH="/${SHORT_ID}"
    NODE_NAME=${NODE_NAME:-"sing-box-vps"}
    SUB_TOKEN=$(openssl rand -hex 16)
    SUBSCRIPTION_PORT=${SUBSCRIPTION_PORT:-24630}
    ARGO_DOMAIN=""
    ARGO_TOKEN=""
    ARGO_PROTOCOL="auto"
    ARGO_BEST_CF_DOMAIN=""
    ARGO_BEST_CF_DOMAIN_IPV4=""
    ARGO_BEST_CF_DOMAIN_IPV6=""
    LINK_IPV4_SELECTION="all"
    PUBLIC_IPV4_OVERRIDE=""

    # Hysteria2 参数
    HY2_PORT=${HY2_PORT:-${HY2_DEFAULT_PORT}}
    HY2_PASSWORD=$(openssl rand -base64 16)
    HY2_SNI="${HY2_DEFAULT_SNI}"
    HY2_MASQUERADE_URL="${HY2_DEFAULT_MASQUERADE_URL}"
    # 默认不限速(BBR)；设置数值会启用 Brutal 并按该带宽收发
    HY2_UP_MBPS=""
    HY2_DOWN_MBPS=""

    success "参数生成完成"
}

# ─── TLS 证书生成 (Hysteria2) ────────────────────────────────
generate_tls_cert() {
    local key_file="${CONFIG_DIR}/server.key"
    local cert_file="${CONFIG_DIR}/server.crt"

    if [[ -f "$key_file" && -f "$cert_file" ]]; then
        info "TLS 证书已存在，跳过生成"
        return
    fi

    info "生成自签 TLS 证书 (Hysteria2)..."
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$key_file" -out "$cert_file" \
        -days 3650 -nodes -subj "/CN=${HY2_SNI}" 2>/dev/null
    chmod 600 "$key_file" "$cert_file"
    success "TLS 自签证书已生成 (有效期 10 年)"
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

# iptables 直接插入的规则重启即失效，按发行版方案尽力持久化:
#   Debian/Ubuntu: netfilter-persistent(iptables-persistent 包)
#   Alpine/OpenRC: /etc/init.d/iptables save + 开机自启
#   RHEL 系:      iptables-services(写 /etc/sysconfig/iptables)
#   兜底:         已存在 /etc/iptables 目录时写 rules.v4
# 全部不可用时返回 1，由调用方提示用户。不主动安装持久化软件包。
persist_iptables_rules() {
    command -v iptables-save >/dev/null 2>&1 || return 1

    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1 && return 0
    fi

    if [[ -x /etc/init.d/iptables ]] && command -v rc-service >/dev/null 2>&1; then
        if rc-service iptables save >/dev/null 2>&1; then
            rc-update add iptables default >/dev/null 2>&1 || true
            return 0
        fi
    fi

    if command -v systemctl >/dev/null 2>&1 && \
        systemctl list-unit-files iptables.service 2>/dev/null | grep -q '^iptables\.service'; then
        if iptables-save > /etc/sysconfig/iptables 2>/dev/null; then
            systemctl enable iptables >/dev/null 2>&1 || true
            return 0
        fi
    fi

    if [[ -d /etc/iptables ]]; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null && return 0
    fi

    return 1
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

    local iptables_rule_added=false
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
                iptables_rule_added=true
                ;;
        esac

        if firewall_port_open "$backend" "$port" "$protocol"; then
            success "端口 ${port}/${protocol} 已通过 $(firewall_backend_label "$backend") 放行"
        else
            warn "端口 ${port}/${protocol} 放行失败，请手动检查 $(firewall_backend_label "$backend") 规则"
            return 1
        fi
    done

    if [[ "$backend" == "iptables" && "$iptables_rule_added" == "true" ]]; then
        if persist_iptables_rules; then
            info "iptables 放行规则已持久化"
        else
            warn "iptables 规则暂未持久化，重启后可能失效；建议安装 iptables-persistent (Debian/Ubuntu) / iptables-services (RHEL 系)，或改用 ufw / firewalld"
        fi
    fi

    return 0
}

# ─── Hysteria2 端口跳跃 (UDP 端口范围 DNAT 到主端口) ───────────
# 用 iptables/ip6tables 在 nat PREROUTING 把一段 UDP 端口范围整体 DNAT 到
# Hysteria2 主端口。DNAT 在 INPUT 过滤之前发生，改写后目标端口即主端口，因此
# 无需再为整段范围放行 INPUT——主端口本就已放行。外部云安全组/NAT 面板仍需
# 用户自行放行该范围。规则精确删除依赖 state 文件记录上一次的范围与目标端口。
hy2_hop_state_file() { printf '%s/hy2-hop.state' "$CONFIG_DIR"; }

# 校验 "小端口:大端口" 格式(1-65535，小 < 大)
validate_hop_range() {
    local range="${1:-}" start end
    [[ "$range" =~ ^[0-9]+:[0-9]+$ ]] || return 1
    start=${range%%:*}
    end=${range##*:}
    (( start >= 1 && start <= 65535 && end >= 1 && end <= 65535 && start < end )) || return 1
    return 0
}

is_valid_argo_protocol() {
    case "${1:-}" in
        auto|http2|quic) return 0 ;;
        *) return 1 ;;
    esac
}

hy2_hop_range_label() {
    if validate_hop_range "${HY2_HOP_RANGE:-}"; then
        printf '%s → %s' "$HY2_HOP_RANGE" "$HY2_PORT"
    else
        printf '未启用'
    fi
}

# 删除上一次写入的端口跳跃 DNAT 规则(幂等；无 state 文件时直接返回)
remove_hy2_port_hopping() {
    local state_file range target
    state_file=$(hy2_hop_state_file)
    [[ -f "$state_file" ]] || return 0
    range=$(sed -n '1p' "$state_file" 2>/dev/null)
    target=$(sed -n '2p' "$state_file" 2>/dev/null)
    if [[ -n "$range" && -n "$target" ]] && command -v iptables >/dev/null 2>&1; then
        iptables -t nat -D PREROUTING -p udp --dport "$range" -j DNAT --to-destination ":$target" 2>/dev/null || true
        command -v ip6tables >/dev/null 2>&1 && \
            ip6tables -t nat -D PREROUTING -p udp --dport "$range" -j DNAT --to-destination ":$target" 2>/dev/null || true
        persist_iptables_rules >/dev/null 2>&1 || true
    fi
    rm -f "$state_file"
    return 0
}

# 按当前 HY2_HOP_RANGE / HY2_PORT 重建端口跳跃规则。未启用时仅清理旧规则。
apply_hy2_port_hopping() {
    remove_hy2_port_hopping
    validate_hop_range "${HY2_HOP_RANGE:-}" || return 0

    if ! command -v iptables >/dev/null 2>&1; then
        warn "未找到 iptables，无法配置 Hysteria2 端口跳跃；请安装 iptables 后重试"
        return 1
    fi

    local range="$HY2_HOP_RANGE" target="$HY2_PORT"
    iptables -t nat -C PREROUTING -p udp --dport "$range" -j DNAT --to-destination ":$target" 2>/dev/null || \
        iptables -t nat -A PREROUTING -p udp --dport "$range" -j DNAT --to-destination ":$target"
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -t nat -C PREROUTING -p udp --dport "$range" -j DNAT --to-destination ":$target" 2>/dev/null || \
            ip6tables -t nat -A PREROUTING -p udp --dport "$range" -j DNAT --to-destination ":$target" 2>/dev/null || true
    fi

    local state_file
    state_file=$(hy2_hop_state_file)
    printf '%s\n%s\n' "$range" "$target" > "$state_file"
    chmod 600 "$state_file" 2>/dev/null || true

    if persist_iptables_rules >/dev/null 2>&1; then
        success "Hysteria2 端口跳跃已启用: UDP ${range} → ${target}"
    else
        warn "端口跳跃规则已生效，但未能持久化，重启后可能失效；建议安装 iptables-persistent (Debian/Ubuntu) / iptables-services (RHEL 系)"
    fi
    warn "若使用云安全组 / NAT 小鸡 / 厂商面板防火墙，请另行放行 UDP 端口范围 ${range}"
    return 0
}

open_service_ports() {
    local backend
    backend=$(detect_firewall_backend)

    [[ -n "${REALITY_PORT:-}" ]] && open_firewall "$REALITY_PORT" "$backend" || return 1
    if [[ -n "${HY2_PORT:-}" && "${HY2_PORT}" != "${REALITY_PORT:-}" ]]; then
        open_firewall "$HY2_PORT" "$backend" || return 1
    fi
    return 0
}

validate_service_ports() {
    local old_reality_port=${1:-}
    local old_hy2_port=${2:-}
    local old_subscription_port=${3:-}
    local should_open_firewall=${4:-true}

    validate_port "${REALITY_PORT:-}" "Reality" || return 1
    validate_port "${WS_PORT:-}" "VLESS-WS" || return 1
    validate_port "${HY2_PORT:-}" "Hysteria2" || return 1
    validate_port "${SUBSCRIPTION_PORT:-}" "订阅服务" || return 1

    if [[ "${REALITY_PORT}" == "${WS_PORT}" ]]; then
        warn "Reality 端口 ${REALITY_PORT}/TCP 与 VLESS-WS 内部端口 ${WS_PORT}/TCP 冲突"
        return 1
    fi
    if [[ "${SUBSCRIPTION_PORT}" == "${REALITY_PORT}" || "${SUBSCRIPTION_PORT}" == "${WS_PORT}" ]]; then
        warn "订阅服务端口 ${SUBSCRIPTION_PORT}/TCP 与现有 TCP 服务端口冲突"
        return 1
    fi

    if [[ -z "$old_reality_port" || "$REALITY_PORT" != "$old_reality_port" ]]; then
        assert_port_available "$REALITY_PORT" "tcp" "Reality" || return 1
    else
        info "Reality 端口未变化，跳过占用检查"
    fi

    if [[ -z "$old_hy2_port" || "$HY2_PORT" != "$old_hy2_port" ]]; then
        assert_port_available "$HY2_PORT" "udp" "Hysteria2" || return 1
    else
        info "Hysteria2 端口未变化，跳过占用检查"
    fi

    if [[ -z "$old_reality_port" ]]; then
        assert_port_available "$WS_PORT" "tcp" "VLESS-WS" || return 1
    fi

    if [[ -z "$old_subscription_port" || "$SUBSCRIPTION_PORT" != "$old_subscription_port" ]]; then
        assert_port_available "$SUBSCRIPTION_PORT" "tcp" "订阅服务" || return 1
    else
        info "订阅服务端口未变化，跳过占用检查"
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
    if [[ "${HY2_PORT}" == "${REALITY_PORT}" ]]; then
        echo -e "  Hysteria2:    ${BOLD}${HY2_PORT}/UDP${NC} ${DIM}(与 Reality 共用端口号，协议不同)${NC}"
    else
        echo -e "  Hysteria2:    ${BOLD}${HY2_PORT}/UDP${NC}"
    fi
    echo -e "  订阅服务:     ${BOLD}${SUBSCRIPTION_PORT}/TCP${NC} ${DIM}(仅本机/Argo 使用)${NC}"
    echo -e "  需要外部放行: ${BOLD}${REALITY_PORT}/TCP${NC}, ${BOLD}${HY2_PORT}/UDP${NC}"
    echo -e "  不需要外部放行: ${BOLD}${SUBSCRIPTION_PORT}/TCP${NC}"
    echo ""
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

is_positive_int() {
    [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]
}

hy2_bandwidth_label() {
    if is_positive_int "${HY2_UP_MBPS:-}" && is_positive_int "${HY2_DOWN_MBPS:-}"; then
        printf '上行 %s / 下行 %s Mbps (Brutal)' "$HY2_UP_MBPS" "$HY2_DOWN_MBPS"
    else
        printf '不限速 (BBR)'
    fi
}

# 交互修改 Hysteria2 带宽限速；有实际变化返回 0，取消/无变化返回 1
prompt_hy2_bandwidth() {
    local new_up new_down

    echo ""
    echo -e "${CYAN}${BOLD}── Hysteria2 带宽限速 ──${NC}"
    echo -e "  当前: ${BOLD}$(hy2_bandwidth_label)${NC}"
    echo -e "  ${DIM}两项都填正整数则启用 Brutal 并按该带宽收发(按实际带宽的 90%~95% 填写);${NC}"
    echo -e "  ${DIM}任一留空则不限速(BBR，带宽未知时推荐)。${NC}"
    prompt_read new_up "  上行 Mbps (留空不限速): " || return 1
    prompt_read new_down "  下行 Mbps (留空不限速): " || return 1

    if [[ -n "$new_up" || -n "$new_down" ]]; then
        if ! is_positive_int "$new_up" || ! is_positive_int "$new_down"; then
            warn "上下行需同时为正整数，或同时留空恢复不限速"
            return 1
        fi
    else
        new_up=""
        new_down=""
    fi

    if [[ "$new_up" == "${HY2_UP_MBPS:-}" && "$new_down" == "${HY2_DOWN_MBPS:-}" ]]; then
        info "带宽设置未变化"
        return 1
    fi

    HY2_UP_MBPS="$new_up"
    HY2_DOWN_MBPS="$new_down"
    success "Hysteria2 带宽已设置为: $(hy2_bandwidth_label)"
    return 0
}

# 交互修改 Hysteria2 端口跳跃范围；有实际变化返回 0，取消/无变化返回 1。
# 仅更新 HY2_HOP_RANGE 变量，规则由调用方 apply_hy2_port_hopping 落地。
prompt_hy2_hop_range() {
    local choice input start end

    echo ""
    echo -e "${CYAN}${BOLD}── Hysteria2 端口跳跃 ──${NC}"
    echo -e "  当前: ${BOLD}$(hy2_hop_range_label)${NC}"
    echo -e "  ${DIM}把一段 UDP 端口整体转发到 Hysteria2 主端口(${HY2_PORT})，客户端在范围内随机跳端口，${NC}"
    echo -e "  ${DIM}可缓解运营商对单一 UDP 端口的 QoS/限速。依赖 iptables，需能持久化才可长期生效。${NC}"
    echo -e "  1) 设置/修改端口范围"
    echo -e "  2) 关闭端口跳跃"
    echo -e "  0) 取消"
    prompt_read choice "  请选择 [0]: " || return 1
    choice=${choice:-0}

    case "$choice" in
        1)
            prompt_read input "  端口范围 (格式 小端口:大端口，如 20000:40000): " || return 1
            if ! validate_hop_range "$input"; then
                warn "范围格式无效。需为 小端口:大端口，均在 1-65535 且小端口 < 大端口"
                return 1
            fi
            start=${input%%:*}
            end=${input##*:}
            if (( HY2_PORT >= start && HY2_PORT <= end )); then
                warn "主端口 ${HY2_PORT} 不能落在跳跃范围内，请另选范围"
                return 1
            fi
            if [[ "$input" == "${HY2_HOP_RANGE:-}" ]]; then
                info "端口跳跃范围未变化"
                return 1
            fi
            HY2_HOP_RANGE="$input"
            info "端口跳跃范围已设为: ${HY2_HOP_RANGE}"
            return 0
            ;;
        2)
            if [[ -z "${HY2_HOP_RANGE:-}" ]]; then
                info "端口跳跃本就未启用"
                return 1
            fi
            HY2_HOP_RANGE=""
            info "已关闭端口跳跃"
            return 0
            ;;
        *)
            return 1
            ;;
    esac
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
    local count input index ip selected

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
    echo -e "  1) 全部启用 ${GREEN}推荐${NC}"
    index=2
    while IFS= read -r ip; do
        [[ -n "$ip" ]] || continue
        echo -e "  ${index}) 仅启用 ${ip}"
        index=$((index + 1))
    done <<< "$PUBLIC_IPV4_LIST"

    prompt_read input "  请选择 [1]: " || input=1
    input=${input:-1}

    if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 2 && input < index )); then
        selected=$(printf '%s\n' "$PUBLIC_IPV4_LIST" | sed -n "$((input - 1))p")
        LINK_IPV4_SELECTION="$selected"
    else
        LINK_IPV4_SELECTION="all"
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
            echo -e "  检测到 IPv6-only VPS，当前仅生成 Argo 节点链接。"
            echo -e "  Argo 的 ${WS_PORT}/TCP 仅供本机回环/隧道使用，一般不需要在外部面板放行。"
            echo -e "  Subscription: ${BOLD}HTTPS Argo 域名${NC} ${DIM}(本机 ${SUBSCRIPTION_PORT}/TCP 不需要外部放行)${NC}"
            echo ""
            return
            ;;
        dual-stack)
            echo -e "  检测到 IPv4 + IPv6 双栈 VPS，直连节点仅使用 IPv4，Argo 会分别输出 IPv4 / IPv6 接入链接。"
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
    if [[ "${HY2_PORT}" == "${REALITY_PORT}" ]]; then
        echo -e "  Hysteria2:    ${BOLD}${HY2_PORT}/UDP${NC} ${DIM}(与 Reality 共用端口号，但协议不同)${NC}"
    else
        echo -e "  Hysteria2:    ${BOLD}${HY2_PORT}/UDP${NC}"
    fi
    echo -e "  Subscription: ${BOLD}HTTPS Argo 域名${NC} ${DIM}(本机 ${SUBSCRIPTION_PORT}/TCP 不需要外部放行)${NC}"
    echo -e "  ${DIM}Argo 和订阅网关均仅供本机回环/隧道使用，一般不需要在外部面板放行。${NC}"
    if [[ "$access_mode" != "direct" && "$access_mode" != "ipv6-only" && "$access_mode" != "dual-stack" ]]; then
        echo -e "  ${DIM}注意: 当前脚本默认外部端口与本机监听端口相同；如果面板做了不同端口号的 NAT 映射，生成的节点链接和订阅地址需要按外部端口另行适配。${NC}"
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
    [[ -z "${WS_PORT:-}" ]]     && missing+="WS_PORT "
    [[ -z "${WS_PATH:-}" ]]     && missing+="WS_PATH "
    [[ -z "${HY2_PORT:-}" ]]    && missing+="HY2_PORT "
    [[ -z "${HY2_PASSWORD:-}" ]] && missing+="HY2_PASSWORD "
    [[ -z "${HY2_SNI:-}" ]]     && missing+="HY2_SNI "
    [[ -z "${HY2_MASQUERADE_URL:-}" ]] && missing+="HY2_MASQUERADE_URL "
    if [[ -n "$missing" ]]; then
        error "配置生成失败: 以下关键变量为空: ${missing}"
    fi

    local json_uuid json_reality_sni json_private_key json_short_id json_ws_path
    local json_hy2_password json_hy2_sni json_key_path json_cert_path json_hy2_masquerade_url

    json_uuid=$(json_string "$UUID")
    json_reality_sni=$(json_string "$REALITY_SNI")
    json_private_key=$(json_string "$PRIVATE_KEY")
    json_short_id=$(json_string "$SHORT_ID")
    json_ws_path=$(json_string "$WS_PATH")
    json_hy2_password=$(json_string "$HY2_PASSWORD")
    json_hy2_sni=$(json_string "$HY2_SNI")
    json_key_path=$(json_string "${CONFIG_DIR}/server.key")
    json_cert_path=$(json_string "${CONFIG_DIR}/server.crt")
    json_hy2_masquerade_url=$(json_string "$HY2_MASQUERADE_URL")

    # Hysteria2 带宽:两项均为正整数时启用 Brutal 并按该带宽限速；
    # 否则不写入(sing-box 使用 BBR，不限速)。旧版硬编码 100/100 会把
    # 大带宽 VPS 白白限在 100Mbps。
    local hy2_bandwidth_lines=""
    if [[ "${HY2_UP_MBPS:-}" =~ ^[1-9][0-9]*$ && "${HY2_DOWN_MBPS:-}" =~ ^[1-9][0-9]*$ ]]; then
        hy2_bandwidth_lines="            \"up_mbps\": ${HY2_UP_MBPS},
            \"down_mbps\": ${HY2_DOWN_MBPS},"
    fi

    cat > "$CONFIG_FILE" << SINGBOX_EOF
{
    "log": {
        "level": "warn",
        "timestamp": true
    },
    "inbounds": [
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
        },
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
                "path": ${json_ws_path},
                "max_early_data": 2048,
                "early_data_header_name": "Sec-WebSocket-Protocol"
            }
        },
        {
            "type": "hysteria2",
            "tag": "hysteria2-in",
            "listen": "::",
            "listen_port": ${HY2_PORT},
${hy2_bandwidth_lines}
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

# ─── Reality 链接自检: 临时客户端配置 ────────────────────────
# 生成与分享链接参数完全一致的 sing-box 客户端配置(vless + reality +
# vision + chrome 指纹)，用于在服务器本机验证「链接参数 ↔ 服务端配置」
# 是否匹配。Reality 参数不匹配时服务端会把客户端当普通访客透传到伪装站，
# 客户端侧表现为超时而非报错，因此只能用真实客户端走一遍链路来验证。
write_reality_client_check_config() {
    local out_file="$1"
    local server="$2"
    local server_port="$3"
    local socks_port="$4"

    local json_server json_sni json_uuid json_pbk json_sid
    json_server=$(json_string "$server")
    json_sni=$(json_string "$REALITY_SNI")
    json_uuid=$(json_string "$UUID")
    json_pbk=$(json_string "$PUBLIC_KEY")
    json_sid=$(json_string "$SHORT_ID")

    cat > "$out_file" << CLIENT_EOF
{
    "log": {
        "level": "warn"
    },
    "inbounds": [
        {
            "type": "socks",
            "tag": "socks-in",
            "listen": "127.0.0.1",
            "listen_port": ${socks_port}
        }
    ],
    "outbounds": [
        {
            "type": "vless",
            "tag": "reality-out",
            "server": ${json_server},
            "server_port": ${server_port},
            "uuid": ${json_uuid},
            "flow": "xtls-rprx-vision",
            "tls": {
                "enabled": true,
                "server_name": ${json_sni},
                "utls": {
                    "enabled": true,
                    "fingerprint": "chrome"
                },
                "reality": {
                    "enabled": true,
                    "public_key": ${json_pbk},
                    "short_id": ${json_sid}
                }
            }
        }
    ]
}
CLIENT_EOF
    chmod 600 "$out_file"
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

