# ─── 修改配置 ────────────────────────────────────────────────
prompt_modify_action() {
    local output_var="$1" category="$2" menu_choice action
    while true; do
        clear
        case "$category" in
            reality)
                menu_header "节点与协议 / Reality"
                menu_section "当前连接"
                if nat_mode_enabled; then
                    echo "  公网 ${REALITY_PUBLIC_PORT}/TCP → 本机 ${REALITY_PORT}/TCP"
                else
                    echo "  本机 ${REALITY_PORT}/TCP"
                fi
                menu_section "连接设置"
                menu_item 1 "修改端口"
                menu_item 2 "修改伪装域名" "${REALITY_SNI}"
                menu_item 3 "重新优选伪装域名"
                menu_item 4 "切换为单端口模式 (443)"
                menu_section "凭据"
                menu_item 5 "重新生成 Reality 密钥对"
                ;;
            hy2)
                menu_header "节点与协议 / Hysteria2"
                menu_section "当前状态"
                echo "  $(is_hy2_enabled && printf '已启用' || printf '未启用') · ${HY2_PORT}/UDP"
                menu_section "设置"
                menu_item 1 "启用或关闭"
                menu_item 2 "修改端口"
                menu_item 3 "重新生成密码"
                ;;
            socks)
                menu_header "节点与协议 / SOCKS5"
                menu_section "当前状态"
                echo "  $(is_socks_enabled && printf '已启用 · %s/TCP' "$SOCKS_PORT" || printf '未启用')"
                menu_section "设置"
                menu_item 1 "管理 SOCKS5 代理"
                ;;
            identity)
                menu_header "节点与协议 / 节点身份"
                menu_section "当前节点"
                echo "  ${NODE_NAME} · UUID ${UUID:0:8}…"
                menu_section "设置"
                menu_item 1 "修改节点名称"
                menu_item 2 "重新生成 UUID"
                ;;
            argo)
                menu_header "连接与订阅 / Argo"
                menu_section "当前状态"
                echo "  $(argo_mode_label) · 订阅本机端口 ${SUBSCRIPTION_PORT}/TCP"
                menu_section "隧道与订阅"
                menu_item 1 "修改隧道模式、Token 或域名"
                menu_item 2 "更新订阅链接"
                menu_item 3 "修改订阅服务端口"
                ;;
            network)
                menu_header "连接与订阅 / 公网与 NAT"
                menu_section "当前状态"
                echo "  NAT $(nat_mode_enabled && printf '已启用' || printf '未启用') · $(public_ipv4_override_label)"
                menu_section "公网设置"
                menu_item 1 "修改 NAT 公网映射"
                menu_item 2 "修改直连公网 IPv4"
                menu_item 3 "修改 IPv4 链接策略"
                ;;
            *) warn "未知配置分类: ${category}"; return 1 ;;
        esac
        menu_back
        prompt_read menu_choice "  选择: " || return 1
        action=""
        case "${category}:${menu_choice}" in
            *:0) action=0 ;;
            reality:1) action=1 ;; reality:2) action=2 ;; reality:3) action=6 ;;
            reality:4) action=9 ;; reality:5) action=4 ;;
            hy2:1) action=16 ;; hy2:2) action=7 ;; hy2:3) action=8 ;;
            socks:1) action=17 ;;
            identity:1) action=5 ;; identity:2) action=3 ;;
            argo:1) action=10 ;; argo:2) action=11 ;; argo:3) action=12 ;;
            network:1) action=15 ;; network:2) action=14 ;; network:3) action=13 ;;
        esac
        if [[ -n "$action" ]]; then
            printf -v "$output_var" '%s' "$action"
            return 0
        fi
        warn "无效选项"
    done
}

do_modify_config() {
    local category="${1:-reality}" selected_action choice
    local MENU_CONTEXT="当前配置页"
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
        )
        prompt_modify_action selected_action "$category" || return
        choice="$selected_action"

        local changed=false
        local ports_changed=false
        local restart_singbox=false
        local restart_reality_backend=false
        local restart_argo=false
        local links_only_changed=false
        case "$choice" in
            1)
                local new_reality_port="$REALITY_PORT"
                local new_reality_public_port="${REALITY_PUBLIC_PORT:-${REALITY_PORT}}"
                if nat_mode_enabled; then
                    prompt_port_value new_reality_public_port "Reality 公网" "$new_reality_public_port" \
                        "  公网 TCP 端口 [${new_reality_public_port}]: " || continue
                fi
                prompt_port_value new_reality_port "Reality 本机监听" "$REALITY_PORT" \
                    "  本机监听 TCP 端口 [${REALITY_PORT}]: " || continue
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
                ;;
            2)
                prompt_read input "  新伪装域名: "
                if [[ -n "$input" ]]; then
                    if ! ensure_reality_probe_dependencies; then
                        warn "Reality 域名安全检查依赖不可用，未修改配置"
                        continue
                    fi
                    if reality_sni_runtime_usable "$input"; then
                        REALITY_SNI="$input"
                        changed=true
                        restart_singbox=true
                        restart_reality_backend=true
                    else
                        warn "该域名未通过 Reality 运行时检查，未修改配置"
                    fi
                fi
                ;;
            3)
                UUID=$(sing-box generate uuid)
                info "新 UUID: $UUID"
                changed=true
                restart_singbox=true
                restart_reality_backend=true
                ;;
            4)
                local keypair
                keypair=$(sing-box generate reality-keypair)
                PRIVATE_KEY=$(echo "$keypair" | grep -i "PrivateKey" | awk '{print $NF}')
                PUBLIC_KEY=$(echo "$keypair" | grep -i "PublicKey"  | awk '{print $NF}')
                SHORT_ID=$(random_hex 4)
                WS_PATH="/${SHORT_ID}"
                info "新密钥对已生成"
                changed=true
                restart_singbox=true
                restart_reality_backend=true
                ;;
            5)
                prompt_read input "  新节点名称: "
                if [[ -n "$input" ]]; then
                    NODE_NAME="$input"
                    changed=true
                fi
                ;;
            6)
                # 复用 sbm resni 流程：自动避开当前/上一次域名并自行写配置、
                # 重启、展示链接，因此处理完直接返回菜单。
                do_reoptimize_reality_sni || true
                press_enter
                continue
                ;;
            7)
                local new_hy2_port
                prompt_port_value new_hy2_port "Hysteria2" "$HY2_PORT" "  新 Hysteria2 端口 [${HY2_PORT}]: " || continue
                if [[ "$new_hy2_port" != "$HY2_PORT" ]]; then
                    HY2_PORT="$new_hy2_port"
                    changed=true
                    ports_changed=true
                    restart_singbox=true
                fi
                ;;
            8)
                HY2_PASSWORD=$(random_base64 16)
                info "新 Hysteria2 密码: $HY2_PASSWORD"
                changed=true
                restart_singbox=true
                ;;
            9)
                REALITY_PORT=443
                HY2_PORT=443
                info "已切换为单端口模式: 443"
                changed=true
                ports_changed=true
                restart_singbox=true
                restart_reality_backend=true
                ;;
            10)
                menu_header "连接与订阅 / Argo / 隧道模式"
                menu_section "当前模式: $(argo_mode_label)"
                menu_item 1 "临时域名" "trycloudflare.com"
                menu_item 2 "固定域名" "Token 模式"
                menu_item 3 "关闭 Argo"
                menu_back "取消"
                prompt_read sub_choice "  请选择 [1]: " || continue
                sub_choice=${sub_choice:-1}
                [[ "$sub_choice" == "0" ]] && continue
                [[ "$sub_choice" =~ ^[123]$ ]] || { warn "无效选项"; continue; }
                if [[ "$sub_choice" == "2" ]]; then
                    local old_argo_domain="${ARGO_DOMAIN:-}"
                    local old_argo_token="${ARGO_TOKEN:-}"
                    ARGO_ENABLED="true"
                    echo -e "  ${YELLOW}提示: 请确保在 Cloudflare 仪表盘中将该域名转发至 http://127.0.0.1:${SUBSCRIPTION_PORT}${NC}"
                    echo -e "  ${RED}注意: 请填写完整的 Token (以 eyJ 开头)，千万不要误填为 Tunnel ID。${NC}"
                    prompt_read input "  新 Tunnel Token [${ARGO_TOKEN:0:10}...]: "
                    [[ -n "$input" ]] && ARGO_TOKEN="$input"
                    prompt_read input "  新自定义域名 [${ARGO_DOMAIN}]: "
                    if [[ -n "$input" ]]; then
                        ARGO_DOMAIN="$input"
                        ARGO_DOMAIN="${ARGO_DOMAIN#http://}"
                        ARGO_DOMAIN="${ARGO_DOMAIN#https://}"
                        ARGO_DOMAIN="${ARGO_DOMAIN%/}"
                    fi
                    if ! argo_fixed_enabled; then
                        warn "Tunnel Token 或固定域名无效，已保留原 Argo 配置"
                        ARGO_ENABLED="$old_argo_enabled"
                        ARGO_TOKEN="$old_argo_token"
                        ARGO_DOMAIN="$old_argo_domain"
                        press_enter
                        continue
                    fi
                    if [[ "${ARGO_DOMAIN:-}" != "$old_argo_domain" || "${ARGO_TOKEN:-}" != "$old_argo_token" ]]; then
                        clear_argo_best_cf_cache
                    fi
                elif [[ "$sub_choice" == "3" ]]; then
                    ARGO_ENABLED="false"
                    ARGO_TOKEN=""
                    ARGO_DOMAIN=""
                    clear_argo_best_cf_cache
                else
                    ARGO_ENABLED="true"
                    ARGO_TOKEN=""
                    ARGO_DOMAIN=""
                    clear_argo_best_cf_cache
                fi
                changed=true
                restart_singbox=true
                restart_argo=true
                ;;
            11)
                if ! update_argo_subscription_links; then
                    warn "Argo 订阅链接更新失败"
                fi
                press_enter
                continue
                ;;
            12)
                local new_subscription_port
                prompt_port_value new_subscription_port "订阅服务" "$SUBSCRIPTION_PORT" "  新订阅服务端口 [${SUBSCRIPTION_PORT}]: " || continue
                if [[ "$new_subscription_port" != "$SUBSCRIPTION_PORT" ]]; then
                    SUBSCRIPTION_PORT="$new_subscription_port"
                    changed=true
                    ports_changed=true
                    restart_argo=true
                fi
                ;;
            13)
                if prompt_ipv4_link_selection_if_multiple; then
                    if [[ "${LINK_IPV4_SELECTION:-all}" != "$old_link_ipv4_selection" ]]; then
                        changed=true
                        links_only_changed=true
                    fi
                else
                    warn "当前未检测到多个 IPv4"
                    press_enter
                    continue
                fi
                ;;
            14)
                if prompt_public_ipv4_override; then
                    if [[ "${PUBLIC_IPV4_OVERRIDE:-}" != "$old_public_ipv4_override" ]]; then
                        changed=true
                        links_only_changed=true
                    fi
                else
                    press_enter
                    continue
                fi
                ;;
            15)
                menu_header "连接与订阅 / 公网与 NAT / 映射"
                menu_section "管理公网映射"
                menu_item 1 "启用或修改 NAT 公网映射"
                menu_item 2 "关闭 NAT 公网映射"
                menu_back "取消"
                prompt_read sub_choice "  请选择 [1]: " || continue
                sub_choice=${sub_choice:-1}
                [[ "$sub_choice" == "0" ]] && continue
                [[ "$sub_choice" =~ ^[12]$ ]] || { warn "无效选项"; continue; }
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
                    prompt_read input "  NAT 公网 IPv4 [${nat_public_ip}]: " || continue
                    [[ -n "$input" ]] && nat_public_ip="$input"
                    if ! is_valid_public_ipv4_for_link "$nat_public_ip"; then
                        warn "NAT 公网 IPv4 无效"
                        press_enter
                        continue
                    fi
                    prompt_port_value nat_reality_port "NAT Reality 公网映射" \
                        "$nat_reality_port" \
                        "  Reality 公网 TCP 端口 [${nat_reality_port}]: " || continue
                    if is_hy2_enabled; then
                        prompt_port_value nat_hy2_port "NAT Hysteria2 公网映射" \
                            "$nat_hy2_port" \
                            "  Hysteria2 公网 UDP 端口 [${nat_hy2_port}]: " || continue
                    fi
                    if is_socks_enabled; then
                        prompt_port_value nat_socks_port "NAT SOCKS5 公网映射" \
                            "$nat_socks_port" \
                            "  SOCKS5 公网 TCP 端口 [${nat_socks_port}]: " || continue
                        if [[ "$nat_socks_port" == "$nat_reality_port" ]]; then
                            warn "NAT SOCKS5 公网 TCP 端口不能与 Reality 公网 TCP 端口相同"
                            press_enter
                            continue
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
                ;;
            16)
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
                ;;
            17)
                if is_socks_enabled; then
                    menu_header "节点与协议 / SOCKS5 / 管理"
                    menu_section "当前 ${SOCKS_USERNAME}@${SOCKS_PORT}/TCP"
                    menu_item 1 "修改端口"
                    menu_item 2 "修改用户名"
                    menu_item 3 "重新生成密码"
                    menu_item 4 "关闭 SOCKS5"
                    menu_back "取消"
                    prompt_read sub_choice "  请选择 [0]: " || continue
                    sub_choice=${sub_choice:-0}
                    case "$sub_choice" in
                        1)
                            local new_socks_port new_socks_public_port
                            prompt_port_value new_socks_port "SOCKS5" "$SOCKS_PORT" \
                                "  新 SOCKS5 TCP 端口 [${SOCKS_PORT}]: " || continue
                            SOCKS_PORT="$new_socks_port"
                            if nat_mode_enabled; then
                                new_socks_public_port="${SOCKS_PUBLIC_PORT:-${SOCKS_PORT}}"
                                prompt_port_value new_socks_public_port "NAT SOCKS5 公网映射" "$new_socks_public_port" \
                                    "  SOCKS5 公网 TCP 端口 [${new_socks_public_port}]: " || continue
                                SOCKS_PUBLIC_PORT="$new_socks_public_port"
                            else
                                SOCKS_PUBLIC_PORT="$SOCKS_PORT"
                            fi
                            ports_changed=true
                            ;;
                        2)
                            prompt_read input "  新 SOCKS5 用户名: " || continue
                            if [[ -z "$input" || ${#input} -gt 255 ]]; then
                                warn "SOCKS5 用户名长度必须为 1-255 个字符"
                                press_enter
                                continue
                            fi
                            SOCKS_USERNAME="$input"
                            ;;
                        3)
                            SOCKS_PASSWORD=$(random_hex 16)
                            info "SOCKS5 密码已重新生成"
                            ;;
                        4)
                            SOCKS_ENABLED="false"
                            info "SOCKS5 已关闭"
                            ports_changed=true
                            ;;
                        *) continue ;;
                    esac
                else
                    prompt_read input "  启用 SOCKS5 代理？(y/N): " || continue
                    [[ "$input" =~ ^[Yy]$ ]] || continue
                    prompt_port_value SOCKS_PORT "SOCKS5" "$SOCKS_PORT" \
                        "  SOCKS5 TCP 端口 [${SOCKS_PORT}]: " || continue
                    SOCKS_PUBLIC_PORT="$SOCKS_PORT"
                    if nat_mode_enabled; then
                        prompt_port_value SOCKS_PUBLIC_PORT "NAT SOCKS5 公网映射" "$SOCKS_PUBLIC_PORT" \
                            "  SOCKS5 公网 TCP 端口 [${SOCKS_PUBLIC_PORT}]: " || continue
                    fi
                    SOCKS_ENABLED="true"
                    info "SOCKS5 将启用在 ${SOCKS_PORT}/TCP"
                    ports_changed=true
                fi
                changed=true
                restart_singbox=true
                ;;
            0) return ;;
            *) continue ;;
        esac

        if [[ "$changed" == "true" ]]; then
            if [[ "$ports_changed" == "true" || "$links_only_changed" != "true" ]] && ! validate_service_ports \
                "$old_reality_port" "$old_hy2_port" "$old_subscription_port" false "$old_socks_active_port"; then
                restore_runtime_params "${old_runtime_params[@]}"
                warn "端口检查未通过，已保留原配置"
                press_enter
                continue
            fi
            if [[ "$ports_changed" == "true" ]] && ! confirm_port_selection; then
                restore_runtime_params "${old_runtime_params[@]}"
                warn "已取消端口修改"
                press_enter
                continue
            fi
            if [[ "$restart_reality_backend" == "true" && "${REALITY_BACKEND:-singbox}" == "xray" ]] && ! xray_managed_reality; then
                restore_runtime_params "${old_runtime_params[@]}"
                warn "Reality 由 Xray 承载，但 Xray 配置或服务不存在，未修改配置"
                press_enter
                continue
            fi
            if nat_mode_enabled && [[ "$REALITY_PORT" != "$old_reality_port" || "$REALITY_PUBLIC_PORT" != "$old_reality_public_port" ]]; then
                warn "请确认服务商面板已将公网 ${REALITY_PUBLIC_PORT}/TCP 转发到本机 ${REALITY_PORT}/TCP；脚本无法修改面板映射"
            fi
            if [[ "$links_only_changed" != "true" ]] && ! open_service_ports; then
                restore_runtime_params "${old_runtime_params[@]}"
                warn "端口放行失败，已保留原配置"
                press_enter
                continue
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
                        continue
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
                    continue
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
                    continue
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
                    continue
                fi
            fi
            generate_and_show_links
            if ! service_is_active sbm-subscription && argo_enabled; then
                warn "订阅服务未运行，请检查 python3 或服务日志"
            fi
            show_subscription_url
            verify_enabled_protocols || warn "部分协议未通过服务端认证测试；公网连接尚未验证"
            press_enter
        fi
    done
}
