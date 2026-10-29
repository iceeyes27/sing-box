# ─── 修改配置 ────────────────────────────────────────────────
# 每个分类一个 render_modify_* 函数：按当前状态只列出可用操作，并用 menu_action
# 登记对应的 modify_* 函数名，do_modify_config 直接执行该函数。
modify_category_title() {
    case "$1" in
        reality)  echo "协议设置 / Reality" ;;
        hy2)      echo "协议设置 / Hysteria2" ;;
        socks)    echo "协议设置 / SOCKS5" ;;
        argo)     echo "协议设置 / Argo 隧道" ;;
        identity) echo "协议设置 / 节点名称与 UUID" ;;
        network)  echo "网络设置" ;;
        *)        return 1 ;;
    esac
}

render_modify_reality() {
    menu_section "当前连接"
    if nat_mode_enabled; then
        echo "  公网 ${REALITY_PUBLIC_PORT}/TCP → 本机 ${REALITY_PORT}/TCP"
    else
        echo "  本机 ${REALITY_PORT}/TCP"
    fi
    echo "  伪装域名 ${REALITY_SNI}"
    menu_section "连接设置"
    menu_action 1 modify_reality_port "修改端口" "疑似端口被封时更换"
    menu_action 2 do_reoptimize_reality_sni "重新优选伪装域名" "连接不稳定时优先尝试"
    menu_action 3 modify_reality_sni "手动指定伪装域名"
    menu_action 4 modify_single_port_mode "切换为单端口模式 (443)"
    menu_section "凭据"
    menu_action 5 modify_reality_keypair "重新生成密钥对" "客户端需重新导入"
}

render_modify_hy2() {
    menu_section "当前状态"
    if is_hy2_enabled; then
        echo "  已启用 · ${HY2_PORT}/UDP"
        menu_section "设置"
        menu_action 1 modify_hy2_port "修改端口"
        menu_action 2 modify_hy2_password "重新生成密码"
        menu_action 3 modify_hy2_enabled "关闭 Hysteria2"
    else
        echo "  未启用 · 需要 UDP 可达；NAT VPS 需服务商提供 UDP 映射"
        menu_section "设置"
        menu_action 1 modify_hy2_enabled "启用 Hysteria2" "${HY2_PORT}/UDP"
    fi
}

render_modify_socks() {
    menu_section "当前状态"
    if is_socks_enabled; then
        echo "  已启用 · ${SOCKS_USERNAME}@${SOCKS_PORT}/TCP"
        echo "  建议在安全组中仅允许业务服务器的固定 IP 访问该端口。"
        menu_section "设置"
        menu_action 1 modify_socks_port "修改端口"
        menu_action 2 modify_socks_username "修改用户名"
        menu_action 3 modify_socks_password "重新生成密码"
        menu_action 4 modify_socks_disable "关闭 SOCKS5"
    else
        echo "  未启用"
        menu_section "设置"
        menu_action 1 modify_socks_enable "启用 SOCKS5" "用户名密码认证"
    fi
}

render_modify_identity() {
    menu_section "当前节点"
    echo "  ${NODE_NAME} · UUID ${UUID:0:8}…"
    menu_section "设置"
    menu_action 1 modify_node_name "修改节点名称"
    menu_action 2 modify_uuid "重新生成 UUID" "客户端需重新导入"
}

render_modify_argo() {
    menu_section "当前状态"
    if argo_enabled; then
        echo "  $(argo_mode_label) · 订阅本机端口 ${SUBSCRIPTION_PORT}/TCP"
    else
        echo "  未启用"
    fi
    echo "  Argo 通过 Cloudflare 隧道连接，其他协议保持直连。"
    menu_section "隧道模式"
    if argo_quick_enabled; then
        menu_action 1 modify_argo_quick "重新申请临时域名" "trycloudflare.com"
    else
        menu_action 1 modify_argo_quick "使用临时隧道" "trycloudflare.com · 无需域名"
    fi
    if argo_fixed_enabled; then
        menu_action 2 modify_argo_fixed "修改 Token 或域名"
    else
        menu_action 2 modify_argo_fixed "使用固定隧道" "需 Cloudflare Tunnel Token"
    fi
    argo_enabled || return 0
    menu_action 3 modify_argo_disable "关闭 Argo"
    menu_section "订阅"
    menu_action 4 update_argo_subscription_links "更新订阅链接"
    menu_action 5 modify_subscription_port "修改订阅服务端口"
}

render_modify_network() {
    local nat_label
    nat_label=$(nat_mode_enabled && printf '已启用' || printf '未启用')
    menu_section "当前状态"
    echo "  NAT ${nat_label} · $(public_ipv4_override_label)"
    echo "  出站 IP 优先级: $(outbound_ip_strategy_label)"
    menu_section "入站 · 客户端如何连到本机"
    menu_action 1 modify_nat_mapping "NAT 公网映射" "$nat_label"
    menu_action 2 modify_public_ipv4_override "直连公网 IPv4" "$(public_ipv4_override_label)"
    menu_action 3 modify_link_ipv4_selection "多 IPv4 链接策略"
    menu_section "出站 · 本机如何访问目标网站"
    menu_action 4 modify_outbound_ip_strategy "出站 IP 优先级" "$(outbound_ip_strategy_label)"
}

prompt_modify_action() {
    local result_var="$1" category="$2" title picked
    local -a MENU_ACTIONS=()
    title=$(modify_category_title "$category") || { warn "未知配置分类: ${category}"; return 1; }
    while true; do
        MENU_ACTIONS=()
        clear
        menu_header "$title"
        "render_modify_${category}"
        menu_back
        menu_read_action picked || return 1
        if [[ -n "$picked" ]]; then
            printf -v "$result_var" '%s' "$picked"
            return 0
        fi
        menu_invalid
    done
}

# 以下 modify_* 函数只在 do_modify_config 内调用：通过动态作用域写入其 changed / ports_changed /
# restart_singbox / restart_reality_backend / restart_argo / links_only_changed 标记并读取 old_* 快照。
# 返回非 0 表示取消，调用方会恢复修改前的全部运行参数。
modify_reality_port() {
    local new_reality_port="$REALITY_PORT"
    local new_reality_public_port="${REALITY_PUBLIC_PORT:-${REALITY_PORT}}"
    if nat_mode_enabled; then
        prompt_port_value new_reality_public_port "Reality 公网" "$new_reality_public_port" \
            "  公网 TCP 端口 [${new_reality_public_port}]: " || return 1
    fi
    prompt_port_value new_reality_port "Reality 本机监听" "$REALITY_PORT" \
        "  本机监听 TCP 端口 [${REALITY_PORT}]: " || return 1
    if nat_mode_enabled && [[ "$new_reality_public_port" != "$REALITY_PUBLIC_PORT" ]]; then
        REALITY_PUBLIC_PORT="$new_reality_public_port"
        changed=true
        ports_changed=true
        links_only_changed=true
    fi
    if [[ "$new_reality_port" != "$REALITY_PORT" ]]; then
        REALITY_PORT="$new_reality_port"
        if ! nat_mode_enabled; then
            REALITY_PUBLIC_PORT="$new_reality_port"
        fi
        changed=true
        ports_changed=true
        restart_singbox=true
        restart_reality_backend=true
        links_only_changed=false
    fi
}

modify_reality_sni() {
    local input=""
    prompt_read input "  新伪装域名: " || return 1
    [[ -n "$input" ]] || return 0
    if ! ensure_reality_probe_dependencies; then
        warn "Reality 域名安全检查依赖不可用，未修改配置"
        return 1
    fi
    if reality_sni_runtime_usable "$input"; then
        REALITY_SNI="$input"
        changed=true
        restart_singbox=true
        restart_reality_backend=true
    else
        warn "该域名未通过 Reality 运行时检查，未修改配置"
    fi
}

modify_uuid() {
    UUID=$(sing-box generate uuid) && [[ -n "$UUID" ]] || { warn "UUID 生成失败"; return 1; }
    info "新 UUID: $UUID"
    changed=true
    restart_singbox=true
    restart_reality_backend=true
}

modify_reality_keypair() {
    local keypair
    keypair=$(sing-box generate reality-keypair) || { warn "Reality 密钥对生成失败"; return 1; }
    PRIVATE_KEY=$(echo "$keypair" | grep -i "PrivateKey" | awk '{print $NF}' || true)
    PUBLIC_KEY=$(echo "$keypair" | grep -i "PublicKey"  | awk '{print $NF}' || true)
    SHORT_ID=$(random_hex 4) || SHORT_ID=""
    if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" || -z "$SHORT_ID" ]]; then
        warn "Reality 密钥对生成失败"
        return 1
    fi
    WS_PATH="/${SHORT_ID}"
    info "新密钥对已生成"
    changed=true
    restart_singbox=true
    restart_reality_backend=true
}

modify_node_name() {
    local input=""
    prompt_read input "  新节点名称: " || return 1
    if [[ -n "$input" ]]; then
        NODE_NAME="$input"
        changed=true
    fi
}

modify_hy2_port() {
    local new_hy2_port
    prompt_port_value new_hy2_port "Hysteria2" "$HY2_PORT" "  新 Hysteria2 端口 [${HY2_PORT}]: " || return 1
    if [[ "$new_hy2_port" != "$HY2_PORT" ]]; then
        HY2_PORT="$new_hy2_port"
        changed=true
        ports_changed=true
        restart_singbox=true
    fi
}

modify_hy2_password() {
    HY2_PASSWORD=$(random_base64 16) && [[ -n "$HY2_PASSWORD" ]] || { warn "Hysteria2 密码生成失败"; return 1; }
    info "新 Hysteria2 密码: $HY2_PASSWORD"
    changed=true
    restart_singbox=true
}

modify_single_port_mode() {
    REALITY_PORT=443
    HY2_PORT=443
    info "已切换为单端口模式: 443"
    changed=true
    ports_changed=true
    restart_singbox=true
    restart_reality_backend=true
}

modify_argo_quick() {
    ARGO_ENABLED="true"
    ARGO_TOKEN=""
    ARGO_DOMAIN=""
    clear_argo_best_cf_cache
    changed=true
    restart_singbox=true
    restart_argo=true
}

modify_argo_fixed() {
    local input=""
    menu_header "协议设置 / Argo 隧道 / 固定隧道"
    ARGO_ENABLED="true"
    echo -e "  ${YELLOW}提示: 请确保在 Cloudflare 仪表盘中将该域名转发至 http://127.0.0.1:${SUBSCRIPTION_PORT}${NC}"
    echo -e "  ${RED}注意: 请填写完整的 Token (以 eyJ 开头)，千万不要误填为 Tunnel ID。${NC}"
    prompt_read input "  新 Tunnel Token [${ARGO_TOKEN:0:10}...]: " || return 1
    [[ -n "$input" ]] && ARGO_TOKEN="$input"
    input=""
    prompt_read input "  新自定义域名 [${ARGO_DOMAIN}]: " || return 1
    if [[ -n "$input" ]]; then
        ARGO_DOMAIN="$input"
        ARGO_DOMAIN="${ARGO_DOMAIN#http://}"
        ARGO_DOMAIN="${ARGO_DOMAIN#https://}"
        ARGO_DOMAIN="${ARGO_DOMAIN%/}"
    fi
    if ! argo_fixed_enabled; then
        warn "Tunnel Token 或固定域名无效，已保留原 Argo 配置"
        press_enter
        return 1
    fi
    if [[ "${ARGO_DOMAIN:-}" != "$old_argo_domain" || "${ARGO_TOKEN:-}" != "$old_argo_token" ]]; then
        clear_argo_best_cf_cache
    fi
    changed=true
    restart_singbox=true
    restart_argo=true
}

modify_argo_disable() {
    ARGO_ENABLED="false"
    ARGO_TOKEN=""
    ARGO_DOMAIN=""
    clear_argo_best_cf_cache
    changed=true
    restart_singbox=true
    restart_argo=true
}

modify_subscription_port() {
    local new_subscription_port
    prompt_port_value new_subscription_port "订阅服务" "$SUBSCRIPTION_PORT" "  新订阅服务端口 [${SUBSCRIPTION_PORT}]: " || return 1
    if [[ "$new_subscription_port" != "$SUBSCRIPTION_PORT" ]]; then
        SUBSCRIPTION_PORT="$new_subscription_port"
        changed=true
        ports_changed=true
        restart_argo=true
    fi
}

modify_link_ipv4_selection() {
    if ! prompt_ipv4_link_selection_if_multiple; then
        warn "当前未检测到多个 IPv4"
        press_enter
        return 1
    fi
    if [[ "${LINK_IPV4_SELECTION:-all}" != "$old_link_ipv4_selection" ]]; then
        changed=true
        links_only_changed=true
    fi
}

modify_public_ipv4_override() {
    if ! prompt_public_ipv4_override; then
        press_enter
        return 1
    fi
    if [[ "${PUBLIC_IPV4_OVERRIDE:-}" != "$old_public_ipv4_override" ]]; then
        changed=true
        links_only_changed=true
    fi
}

modify_nat_mapping() {
    local input="" sub_choice=1
    menu_header "网络设置 / NAT 公网映射"
    # 未启用时只有“启用”一种操作，直接进入填写。
    if nat_mode_enabled; then
        menu_item 1 "修改 NAT 公网映射"
        menu_item 2 "关闭 NAT 公网映射"
        menu_back "取消"
        prompt_read sub_choice "  请选择 [1]: " || return 1
        sub_choice=${sub_choice:-1}
        [[ "$sub_choice" == "0" ]] && return 1
        [[ "$sub_choice" =~ ^[12]$ ]] || { warn "无效选项"; return 1; }
    else
        echo "  公网 IPv4 不在本机网卡上时（NAT VPS），填写服务商面板分配的公网 IP 与映射端口。"
    fi
    if [[ "$sub_choice" == "2" ]]; then
        NAT_MODE="false"
        REALITY_PUBLIC_PORT="${REALITY_PORT}"
        HY2_PUBLIC_PORT="${HY2_PORT}"
        SOCKS_PUBLIC_PORT="${SOCKS_PORT}"
    else
        local nat_public_ip nat_reality_port nat_hy2_port nat_socks_port
        nat_public_ip="${PUBLIC_IPV4_OVERRIDE:-${PUBLIC_IPV4:-}}"
        nat_reality_port="${REALITY_PUBLIC_PORT:-${REALITY_PORT}}"
        nat_hy2_port="${HY2_PUBLIC_PORT:-${HY2_PORT}}"
        nat_socks_port="${SOCKS_PUBLIC_PORT:-${SOCKS_PORT}}"
        if ! nat_mode_enabled; then
            nat_reality_port="${REALITY_PORT}"
            nat_hy2_port="${HY2_PORT}"
            nat_socks_port="${SOCKS_PORT}"
        fi
        prompt_read input "  NAT 公网 IPv4 [${nat_public_ip}]: " || return 1
        [[ -n "$input" ]] && nat_public_ip="$input"
        if ! is_valid_public_ipv4_for_link "$nat_public_ip"; then
            warn "NAT 公网 IPv4 无效"
            press_enter
            return 1
        fi
        prompt_port_value nat_reality_port "NAT Reality 公网映射" \
            "$nat_reality_port" \
            "  Reality 公网 TCP 端口 [${nat_reality_port}]: " || return 1
        if is_hy2_enabled; then
            prompt_port_value nat_hy2_port "NAT Hysteria2 公网映射" \
                "$nat_hy2_port" \
                "  Hysteria2 公网 UDP 端口 [${nat_hy2_port}]: " || return 1
        fi
        if is_socks_enabled; then
            prompt_port_value nat_socks_port "NAT SOCKS5 公网映射" \
                "$nat_socks_port" \
                "  SOCKS5 公网 TCP 端口 [${nat_socks_port}]: " || return 1
            if [[ "$nat_socks_port" == "$nat_reality_port" ]]; then
                warn "NAT SOCKS5 公网 TCP 端口不能与 Reality 公网 TCP 端口相同"
                press_enter
                return 1
            fi
        fi
        NAT_MODE="true"
        PUBLIC_IPV4_OVERRIDE="$nat_public_ip"
        REALITY_PUBLIC_PORT="$nat_reality_port"
        HY2_PUBLIC_PORT="$nat_hy2_port"
        SOCKS_PUBLIC_PORT="$nat_socks_port"
        LINK_IPV4_SELECTION="all"
        reset_public_ip_cache
    fi
    changed=true
    links_only_changed=true
}

modify_hy2_enabled() {
    if is_hy2_enabled; then
        HY2_ENABLED="false"
        info "Hysteria2 已关闭"
    else
        HY2_ENABLED="true"
        info "Hysteria2 将启用在 ${HY2_PORT}/UDP"
    fi
    changed=true
    ports_changed=true
    restart_singbox=true
}

modify_socks_enable() {
    prompt_port_value SOCKS_PORT "SOCKS5" "$SOCKS_PORT" \
        "  SOCKS5 TCP 端口 [${SOCKS_PORT}]: " || return 1
    SOCKS_PUBLIC_PORT="$SOCKS_PORT"
    if nat_mode_enabled; then
        prompt_port_value SOCKS_PUBLIC_PORT "NAT SOCKS5 公网映射" "$SOCKS_PUBLIC_PORT" \
            "  SOCKS5 公网 TCP 端口 [${SOCKS_PUBLIC_PORT}]: " || return 1
    fi
    SOCKS_ENABLED="true"
    info "SOCKS5 将启用在 ${SOCKS_PORT}/TCP"
    changed=true
    ports_changed=true
    restart_singbox=true
}

modify_socks_port() {
    local new_socks_port new_socks_public_port
    prompt_port_value new_socks_port "SOCKS5" "$SOCKS_PORT" \
        "  新 SOCKS5 TCP 端口 [${SOCKS_PORT}]: " || return 1
    SOCKS_PORT="$new_socks_port"
    if nat_mode_enabled; then
        new_socks_public_port="${SOCKS_PUBLIC_PORT:-${SOCKS_PORT}}"
        prompt_port_value new_socks_public_port "NAT SOCKS5 公网映射" "$new_socks_public_port" \
            "  SOCKS5 公网 TCP 端口 [${new_socks_public_port}]: " || return 1
        SOCKS_PUBLIC_PORT="$new_socks_public_port"
    else
        SOCKS_PUBLIC_PORT="$SOCKS_PORT"
    fi
    changed=true
    ports_changed=true
    restart_singbox=true
}

modify_socks_username() {
    local input=""
    prompt_read input "  新 SOCKS5 用户名: " || return 1
    if [[ -z "$input" || ${#input} -gt 255 ]]; then
        warn "SOCKS5 用户名长度必须为 1-255 个字符"
        press_enter
        return 1
    fi
    SOCKS_USERNAME="$input"
    changed=true
    restart_singbox=true
}

modify_socks_password() {
    SOCKS_PASSWORD=$(random_hex 16) && [[ -n "$SOCKS_PASSWORD" ]] || { warn "SOCKS5 密码生成失败"; return 1; }
    info "SOCKS5 密码已重新生成"
    changed=true
    restart_singbox=true
}

modify_socks_disable() {
    SOCKS_ENABLED="false"
    info "SOCKS5 已关闭"
    changed=true
    ports_changed=true
    restart_singbox=true
}

modify_outbound_ip_strategy() {
    local sub_choice="" new_strategy=""
    menu_header "网络设置 / 出站 IP 优先级"
    menu_section "当前: $(outbound_ip_strategy_label)"
    echo "  决定代理访问目标网站时走 IPv4 还是 IPv6，与客户端用哪种 IP 连入无关。"
    echo "  仅对客户端交给服务端解析的域名生效（远程 DNS / socks5h）。"
    menu_item 1 "默认" "sing-box 自动选择"
    menu_item 2 "优先 IPv4" "目标无 IPv4 时使用 IPv6"
    menu_item 3 "优先 IPv6" "目标无 IPv6 时使用 IPv4"
    menu_item 4 "仅 IPv4"
    menu_item 5 "仅 IPv6" "仅有 IPv4 的网站将无法访问"
    menu_back "取消"
    prompt_read sub_choice "  请选择 [0]: " || return 1
    case "${sub_choice:-0}" in
        1) new_strategy="default" ;;
        2) new_strategy="prefer_ipv4" ;;
        3) new_strategy="prefer_ipv6" ;;
        4) new_strategy="ipv4_only" ;;
        5) new_strategy="ipv6_only" ;;
        0) return 1 ;;
        *) warn "无效选项"; return 1 ;;
    esac
    if [[ "$new_strategy" == "$old_outbound_ip_strategy" ]]; then
        info "出站 IP 优先级未变化"
        press_enter
        return 1
    fi
    case "$new_strategy" in
        prefer_ipv6|ipv6_only)
            if ! fetch_public_ipv6 >/dev/null; then
                if [[ "$new_strategy" == "ipv6_only" ]]; then
                    warn "未检测到 IPv6 出站，不能设为仅 IPv6"
                    press_enter
                    return 1
                fi
                warn "未检测到 IPv6 出站，优先 IPv6 实际仍会使用 IPv4"
            fi
            ;;
        ipv4_only)
            if ! fetch_public_ipv4 >/dev/null; then
                warn "未检测到 IPv4 出站，不能设为仅 IPv4"
                press_enter
                return 1
            fi
            ;;
    esac
    if [[ "${REALITY_BACKEND:-singbox}" == "xray" ]]; then
        warn "Reality 由 Xray 承载，此设置不影响 Reality 流量的出站"
    fi
    OUTBOUND_IP_STRATEGY="$new_strategy"
    info "出站 IP 优先级: $(outbound_ip_strategy_label)"
    changed=true
    restart_singbox=true
}

# 校验并应用 do_modify_config 中已修改的参数；失败时恢复 old_runtime_params 快照。
# 始终返回 0，以保持调用处的 errexit 行为。
apply_modified_config() {
    if [[ "$ports_changed" == "true" || "$links_only_changed" != "true" ]] && ! validate_service_ports \
        "$old_reality_port" "$old_hy2_port" "$old_subscription_port" false "$old_socks_active_port"; then
        restore_runtime_params "${old_runtime_params[@]}"
        warn "端口检查未通过，已保留原配置"
        press_enter
        return 0
    fi
    if [[ "$ports_changed" == "true" ]] && ! confirm_port_selection; then
        restore_runtime_params "${old_runtime_params[@]}"
        warn "已取消端口修改"
        press_enter
        return 0
    fi
    if [[ "$restart_reality_backend" == "true" && "${REALITY_BACKEND:-singbox}" == "xray" ]] && ! xray_managed_reality; then
        restore_runtime_params "${old_runtime_params[@]}"
        warn "Reality 由 Xray 承载，但 Xray 配置或服务不存在，未修改配置"
        press_enter
        return 0
    fi
    if nat_mode_enabled && [[ "$REALITY_PORT" != "$old_reality_port" || "$REALITY_PUBLIC_PORT" != "$old_reality_public_port" ]]; then
        warn "请确认服务商面板已将公网 ${REALITY_PUBLIC_PORT}/TCP 转发到本机 ${REALITY_PORT}/TCP；脚本无法修改面板映射"
    fi
    if [[ "$links_only_changed" != "true" ]] && ! open_service_ports; then
        restore_runtime_params "${old_runtime_params[@]}"
        warn "端口放行失败，已保留原配置"
        press_enter
        return 0
    fi

    if [[ "$restart_singbox" == "true" ]]; then
        # 确保 TLS 证书存在 (Hysteria2 需要)
        generate_tls_cert
        write_singbox_config
        write_singbox_service
        local xray_update_required=false
        if [[ "$restart_reality_backend" == "true" && "${REALITY_BACKEND:-singbox}" == "xray" ]]; then
            if ! write_xray_reality_config "$REALITY_SNI" "$REALITY_PORT" "$UUID" "$PRIVATE_KEY" "$SHORT_ID"; then
                restore_runtime_params "${old_runtime_params[@]}"
                write_singbox_config
                warn "Xray Reality 配置更新失败，已保留原配置"
                press_enter
                return 0
            fi
            xray_update_required=true
        fi
        save_params
        info "重启 sing-box..."
        local restart_failed=false
        service_restart_bounded sing-box || restart_failed=true
        if [[ "$xray_update_required" == "true" ]]; then
            info "重启 Xray..."
            service_restart_bounded xray || restart_failed=true
        fi
        if [[ "$restart_failed" == "true" ]]; then
            restore_runtime_params "${old_runtime_params[@]}"
            write_singbox_config
            write_singbox_service
            [[ "$xray_update_required" == "true" ]] && write_xray_reality_config "$REALITY_SNI" "$REALITY_PORT" "$UUID" "$PRIVATE_KEY" "$SHORT_ID" || true
            save_params
            warn "服务重启失败，正在恢复旧配置..."
            service_restart_bounded sing-box 2>/dev/null || true
            [[ "$xray_update_required" == "true" ]] && service_restart_bounded xray 2>/dev/null || true
            press_enter
            return 0
        fi
        sleep 2
        local services_ready=true
        service_is_active sing-box || services_ready=false
        if [[ "$xray_update_required" == "true" ]]; then
            service_is_active xray || services_ready=false
        fi
        if [[ "$restart_reality_backend" == "true" && "$services_ready" == "true" ]]; then
            verify_reality_local_listener || services_ready=false
        fi
        if [[ "$services_ready" == "true" ]]; then
            success "配置已更新并重启"
            if nat_mode_enabled && [[ "$REALITY_PORT" != "$old_reality_port" ]]; then
                warn "仅已验证本机 ${REALITY_PORT}/TCP 监听；公网 ${REALITY_PUBLIC_PORT}/TCP 映射及外部连接尚未验证"
            fi
        else
            restore_runtime_params "${old_runtime_params[@]}"
            write_singbox_config
            write_singbox_service
            [[ "$xray_update_required" == "true" ]] && write_xray_reality_config "$REALITY_SNI" "$REALITY_PORT" "$UUID" "$PRIVATE_KEY" "$SHORT_ID" || true
            save_params
            warn "服务未正常启动或 Reality 新端口未监听，正在恢复旧配置..."
            service_restart_bounded sing-box 2>/dev/null || true
            [[ "$xray_update_required" == "true" ]] && service_restart_bounded xray 2>/dev/null || true
            press_enter
            return 0
        fi
    else
        save_params
        success "配置已更新"
        if nat_mode_enabled && [[ "$REALITY_PUBLIC_PORT" != "$old_reality_public_port" ]]; then
            warn "仅已更新链接使用的公网 ${REALITY_PUBLIC_PORT}/TCP；服务商面板映射及外部连接尚未验证"
        fi
    fi

    if [[ "$restart_argo" == "true" ]]; then
        if ! refresh_argo_runtime; then
            restore_runtime_params "${old_runtime_params[@]}"
            save_params
            if argo_enabled; then
                if ensure_subscription_service_if_enabled && write_argo_service; then
                    service_enable_now argo-tunnel 2>/dev/null || warn "原 Argo 服务未恢复运行"
                else
                    warn "原 Argo 服务未恢复运行"
                fi
            else
                service_stop argo-tunnel 2>/dev/null || true
                service_disable argo-tunnel 2>/dev/null || true
            fi
            warn "Argo 配置更新失败，已恢复原参数；请检查服务运行状态"
            press_enter
            return 0
        fi
    fi
    generate_and_show_links
    if ! service_is_active sbm-subscription && argo_enabled; then
        warn "订阅服务未运行，请检查 python3 或服务日志"
    fi
    show_subscription_url
    verify_enabled_protocols || warn "部分协议未通过服务端认证测试；公网连接尚未验证"
    press_enter
}

do_modify_config() {
    local category="${1:-reality}" selected_action
    local MENU_CONTEXT
    MENU_CONTEXT=$(modify_category_title "$category") || { warn "未知配置分类: ${category}"; return; }
    load_params || { warn "未找到配置，请先安装"; press_enter; return; }

    while true; do
        local old_uuid="${UUID}"
        local old_short_id="${SHORT_ID}"
        local old_private_key="${PRIVATE_KEY}"
        local old_public_key="${PUBLIC_KEY}"
        local old_reality_port="${REALITY_PORT}"
        local old_reality_sni="${REALITY_SNI}"
        local old_ws_port="${WS_PORT}"
        local old_ws_path="${WS_PATH}"
        local old_node_name="${NODE_NAME}"
        local old_hy2_port="${HY2_PORT}"
        local old_hy2_password="${HY2_PASSWORD}"
        local old_hy2_sni="${HY2_SNI}"
        local old_hy2_masquerade_url="${HY2_MASQUERADE_URL:-${HY2_DEFAULT_MASQUERADE_URL}}"
        local old_subscription_port="${SUBSCRIPTION_PORT}"
        local old_argo_enabled="${ARGO_ENABLED:-false}"
        local old_argo_domain="${ARGO_DOMAIN:-}"
        local old_argo_token="${ARGO_TOKEN:-}"
        local old_argo_best_cf_domain="${ARGO_BEST_CF_DOMAIN:-}"
        local old_argo_best_cf_domain_ipv4="${ARGO_BEST_CF_DOMAIN_IPV4:-}"
        local old_argo_best_cf_domain_ipv6="${ARGO_BEST_CF_DOMAIN_IPV6:-}"
        local old_link_ipv4_selection="${LINK_IPV4_SELECTION:-all}"
        local old_public_ipv4_override="${PUBLIC_IPV4_OVERRIDE:-}"
        local old_nat_mode="${NAT_MODE:-false}"
        local old_reality_public_port="${REALITY_PUBLIC_PORT:-${REALITY_PORT}}"
        local old_hy2_public_port="${HY2_PUBLIC_PORT:-${HY2_PORT}}"
        local old_hy2_enabled="${HY2_ENABLED:-false}"
        local old_socks_port="${SOCKS_PORT}"
        local old_socks_username="${SOCKS_USERNAME}"
        local old_socks_password="${SOCKS_PASSWORD}"
        local old_socks_enabled="${SOCKS_ENABLED:-false}"
        local old_socks_public_port="${SOCKS_PUBLIC_PORT:-${SOCKS_PORT}}"
        local old_outbound_ip_strategy="${OUTBOUND_IP_STRATEGY:-default}"
        local old_socks_active_port=""
        [[ "$old_socks_enabled" == "true" ]] && old_socks_active_port="$old_socks_port"
        local -a old_runtime_params=(
            "$old_uuid" "$old_short_id" "$old_private_key" "$old_public_key"
            "$old_reality_port" "$old_reality_sni" "$old_ws_port" "$old_ws_path"
            "$old_node_name" "$old_hy2_port" "$old_hy2_password" "$old_hy2_sni"
            "$old_hy2_masquerade_url" "$old_subscription_port" "$old_argo_domain" "$old_argo_token"
            "$old_argo_best_cf_domain" "$old_argo_best_cf_domain_ipv4" "$old_argo_best_cf_domain_ipv6"
            "$old_link_ipv4_selection" "$old_public_ipv4_override" "$old_nat_mode"
            "$old_reality_public_port" "$old_hy2_public_port" "$old_argo_enabled" "$old_hy2_enabled"
            "$old_socks_port" "$old_socks_username" "$old_socks_password" "$old_socks_enabled" "$old_socks_public_port"
            "$old_outbound_ip_strategy"
        )
        prompt_modify_action selected_action "$category" || return

        case "$selected_action" in
            0) return ;;
            # 以下两项自行写配置、重启并展示链接，不经过快照恢复与 apply_modified_config。
            do_reoptimize_reality_sni)
                do_reoptimize_reality_sni || true
                press_enter
                continue
                ;;
            update_argo_subscription_links)
                update_argo_subscription_links || warn "Argo 订阅链接更新失败"
                press_enter
                continue
                ;;
        esac

        local changed=false
        local ports_changed=false
        local restart_singbox=false
        local restart_reality_backend=false
        local restart_argo=false
        local links_only_changed=false
        if ! "$selected_action"; then
            restore_runtime_params "${old_runtime_params[@]}"
            continue
        fi
        [[ "$changed" == "true" ]] && apply_modified_config
    done
}
