# ════════════════════════════════════════════════════════════
#  菜单功能
# ════════════════════════════════════════════════════════════

# ─── 完整安装 ────────────────────────────────────────────────
do_primary_install() {
    echo ""
    info "开始完整安装..."
    separator

    install_deps
    ensure_time_sync || true
    install_singbox
    generate_params

    while true; do
        # 询问端口模式
        echo ""
        echo -e "${CYAN}${BOLD}── 端口配置 ──${NC}"
        echo -e "  1) 极简单端口模式 (Reality & Hysteria2 共用 443/TCP+UDP) ${GREEN}推荐${NC}"
        echo -e "  2) 自定义分端口模式 (手动设置各个协议端口)"
        prompt_read port_mode "  请选择 [1]: "
        port_mode=${port_mode:-1}

        if [[ "$port_mode" == "1" ]]; then
            REALITY_PORT=443
            HY2_PORT=443
            info "已选择单端口模式: 443"
        else
            prompt_port_value REALITY_PORT "Reality" "$REALITY_PORT" "  Reality 端口 [${REALITY_PORT}]: " || error "端口读取失败"
            prompt_port_value HY2_PORT "Hysteria2" "$HY2_PORT" "  Hysteria2 端口 [${HY2_PORT}]: " || error "端口读取失败"
        fi

        reset_public_ip_cache
        refresh_public_ip_stack || true
        prompt_nat_mapping_config || error "NAT 公网映射端口读取失败"

        if ! validate_service_ports "" "" "" false; then
            warn "端口检查失败，请调整端口后重试"
            continue
        fi
        if ! confirm_port_selection; then
            continue
        fi
        if open_service_ports; then
            break
        fi
        warn "端口放行失败，请调整端口后重试"
    done

    prompt_read input "  Reality 伪装域名 [${REALITY_SNI}]: "
    [[ -n "$input" ]] && REALITY_SNI="$input"

    prompt_read input "  节点名称 [${NODE_NAME}]: "
    [[ -n "$input" ]] && NODE_NAME="$input"
    echo ""
    if ! refresh_public_ip_stack; then
        warn "未能自动获取公网 IP。"
        warn "如需生成 Reality/Hysteria2 直连链接，请手动填写公网 IPv4。"
        prompt_public_ipv4_override_optional || true
    fi
    prompt_ipv4_link_selection_if_multiple || true

    # 生成 TLS 自签证书 (Hysteria2 需要)
    generate_tls_cert

    # 询问 Argo 模式
    echo ""
    echo -e "${CYAN}${BOLD}── Argo 隧道配置 ──${NC}"
    echo -e "  1) 不启用 Argo ${GREEN}推荐${NC}"
    echo -e "  2) 固定域名模式 (需提供 Cloudflare Tunnel Token)"
    prompt_read argo_choice "  请选择 [1]: "
    argo_choice=${argo_choice:-1}
    if [[ "$argo_choice" == "2" ]]; then
        prompt_port_value SUBSCRIPTION_PORT "订阅服务" "$SUBSCRIPTION_PORT" "  订阅服务端口 [${SUBSCRIPTION_PORT}]: " || error "端口读取失败"
        echo -e "\n  ${YELLOW}提示: 请前往 Cloudflare Zero Trust -> Networks -> Tunnels 创建隧道${NC}"
        echo -e "  并将 Public Hostname 转发至 ${GREEN}http://127.0.0.1:${SUBSCRIPTION_PORT}${NC}"
        echo -e "  并获取其对应的 Token ${YELLOW}(以 eyJ 开头的一长串字符)。${NC}"
        echo -e "  ${RED}注意: 千万不要把 Tunnel ID (连接器 ID) 错当成 Token！${NC}"
        prompt_read ARGO_TOKEN "  请输入 Tunnel Token: "
        prompt_read ARGO_DOMAIN "  请输入该隧道绑定的域名 (如 v2.example.com): "
        # 清除用户可能误输入的 http://, https:// 以及结尾的 /
        ARGO_DOMAIN="${ARGO_DOMAIN#http://}"
        ARGO_DOMAIN="${ARGO_DOMAIN#https://}"
        ARGO_DOMAIN="${ARGO_DOMAIN%/}"
        if ! argo_fixed_enabled; then
            warn "Token 或域名为空，Argo 将保持关闭"
            ARGO_TOKEN=""
            ARGO_DOMAIN=""
        else
            install_cloudflared
            validate_service_ports "" "" "" false || error "固定域名 Argo 端口配置无效"
        fi
    else
        ARGO_TOKEN=""
        ARGO_DOMAIN=""
    fi

    write_singbox_config
    write_singbox_service
    argo_fixed_enabled && write_argo_service

    # 启动 sing-box
    info "启动 sing-box..."
    service_enable_now sing-box
    sleep 2
    if service_is_active sing-box; then
        success "sing-box 已启动"
    else
        error "sing-box 启动失败，请查看服务日志"
    fi

    ensure_subscription_service_if_enabled || warn "订阅服务启动失败，可稍后执行 sbm restart 重试"

    if argo_fixed_enabled; then
        info "启动固定域名 Argo 隧道..."
        service_enable_now argo-tunnel
        success "Argo 域名: $ARGO_DOMAIN"
    fi

    # 保存参数
    save_params

    echo ""
    if argo_fixed_enabled; then
        echo -e "${GREEN}${BOLD}✅ 部署完成！HTTPS 订阅地址可导入 v2rayN / v2rayNG。${NC}"
    else
        echo -e "${GREEN}${BOLD}✅ 部署完成！请导入下方 Reality 直连链接。${NC}"
    fi

    # 显示链接
    generate_and_show_links
    show_subscription_url

    press_enter
}

do_install() {
    echo ""
    echo -e "${CYAN}${BOLD}── 部署目标 ──${NC}"
    echo -e "  1) 主节点完整部署 ${GREEN}推荐${NC}"
    echo -e "  2) 只搭建线路机 / 落地机"
    echo -e "  3) 生成线路机部署脚本"
    echo -e "  0) 返回"
    prompt_read target "  请选择 [1]: "
    target=${target:-1}

    case "$target" in
        1) do_primary_install ;;
        2) do_relay_install ;;
        3) do_generate_relay_script ;;
        0) return ;;
        *) warn "无效选项"; sleep 0.5 ;;
    esac
}

# ─── 修改配置 ────────────────────────────────────────────────
do_modify_config() {
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
        clear
        echo -e "${CYAN}${BOLD}"
        echo "  ── 修改配置 ──"
        echo -e "${NC}"
        echo -e "  1) 修改 Reality 端口       ${DIM}(当前: ${REALITY_PORT})${NC}"
        echo -e "  2) 修改伪装域名            ${DIM}(当前: ${REALITY_SNI})${NC}"
        echo -e "  3) 重新生成 UUID           ${DIM}(当前: ${UUID:0:8}...)${NC}"
        echo -e "  4) 重新生成 Reality 密钥对"
        echo -e "  5) 修改节点名称            ${DIM}(当前: ${NODE_NAME})${NC}"
        echo -e "  6) 重新优选伪装域名"
        echo -e "  7) 修改 Hysteria2 端口     ${DIM}(当前: ${HY2_PORT})${NC}"
        echo -e "  8) 重新生成 Hysteria2 密码"
        echo -e "  9) 切换为单端口模式 (443)  ${GREEN}推荐${NC}"
        echo -e "  10) 修改 Argo 隧道 (Token/域名)"
        echo -e "  11) 更新 Argo 订阅链接"
        echo -e "  12) 修改订阅服务端口       ${DIM}(当前: ${SUBSCRIPTION_PORT})${NC}"
        echo -e "  13) 修改 IPv4 链接策略     ${DIM}(当前: $(link_ipv4_selection_label))${NC}"
        echo -e "  14) 修改直连公网 IPv4 覆盖 ${DIM}(当前: $(public_ipv4_override_label))${NC}"
        echo -e "  15) 修改 NAT 公网映射       ${DIM}(当前: $(nat_mode_enabled && echo '已启用' || echo '未启用'))${NC}"
        echo -e "  0) 返回主菜单"
        echo ""
        prompt_read choice "  请选择 [0-15]: "

        local changed=false
        local ports_changed=false
        local restart_singbox=false
        local restart_argo=false
        local links_only_changed=false
        case "$choice" in
            1)
                local new_reality_port
                prompt_port_value new_reality_port "Reality" "$REALITY_PORT" "  新端口 [${REALITY_PORT}]: " || continue
                if [[ "$new_reality_port" != "$REALITY_PORT" ]]; then
                    REALITY_PORT="$new_reality_port"
                    changed=true
                    ports_changed=true
                    restart_singbox=true
                fi
                ;;
            2)
                prompt_read input "  新伪装域名: "
                if [[ -n "$input" ]]; then
                    REALITY_SNI="$input"
                    changed=true
                    restart_singbox=true
                fi
                ;;
            3)
                UUID=$(sing-box generate uuid)
                info "新 UUID: $UUID"
                changed=true
                restart_singbox=true
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
                ;;
            10)
                echo -e "\n  当前模式: $( argo_fixed_enabled && echo "固定域名" || echo "未启用" )"
                echo -e "  1) 关闭 Argo"
                echo -e "  2) 切换为/修改固定域名 Token 模式"
                prompt_read sub_choice "  请选择 [2]: "
                sub_choice=${sub_choice:-2}
                if [[ "$sub_choice" == "2" ]]; then
                    local old_argo_domain="${ARGO_DOMAIN:-}"
                    local old_argo_token="${ARGO_TOKEN:-}"
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
                    if [[ "${ARGO_DOMAIN:-}" != "$old_argo_domain" || "${ARGO_TOKEN:-}" != "$old_argo_token" ]]; then
                        clear_argo_best_cf_cache
                    fi
                else
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
                echo -e "  1) 启用/修改 NAT 公网映射"
                echo -e "  2) 关闭 NAT 公网映射"
                prompt_read sub_choice "  请选择 [1]: "
                sub_choice=${sub_choice:-1}
                if [[ "$sub_choice" == "2" ]]; then
                    NAT_MODE="false"
                    REALITY_PUBLIC_PORT="${REALITY_PORT}"
                    HY2_PUBLIC_PORT="${HY2_PORT}"
                else
                    local nat_public_ip nat_reality_port nat_hy2_port
                    nat_public_ip="${PUBLIC_IPV4_OVERRIDE:-${PUBLIC_IPV4:-}}"
                    nat_reality_port="${REALITY_PUBLIC_PORT:-${REALITY_PORT}}"
                    nat_hy2_port="${HY2_PUBLIC_PORT:-${HY2_PORT}}"
                    if ! nat_mode_enabled; then
                        nat_reality_port="${REALITY_PORT}"
                        nat_hy2_port="${HY2_PORT}"
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
                    NAT_MODE="true"
                    PUBLIC_IPV4_OVERRIDE="$nat_public_ip"
                    REALITY_PUBLIC_PORT="$nat_reality_port"
                    HY2_PUBLIC_PORT="$nat_hy2_port"
                    LINK_IPV4_SELECTION="all"
                    reset_public_ip_cache
                fi
                changed=true
                links_only_changed=true
                ;;
            0) return ;;
            *) continue ;;
        esac

        if [[ "$changed" == "true" ]]; then
            if [[ "$links_only_changed" != "true" ]] && ! validate_service_ports "$old_reality_port" "$old_hy2_port" "$old_subscription_port" false; then
                restore_runtime_params "$old_uuid" "$old_short_id" "$old_private_key" "$old_public_key" \
                    "$old_reality_port" "$old_reality_sni" "$old_ws_port" "$old_ws_path" \
                    "$old_node_name" "$old_hy2_port" "$old_hy2_password" "$old_hy2_sni" \
                    "$old_hy2_masquerade_url" \
                    "$old_subscription_port" "$old_argo_domain" "$old_argo_token" \
                    "$old_argo_best_cf_domain" "$old_argo_best_cf_domain_ipv4" "$old_argo_best_cf_domain_ipv6" \
                    "$old_link_ipv4_selection" "$old_public_ipv4_override" \
                    "$old_nat_mode" "$old_reality_public_port" "$old_hy2_public_port"
                warn "端口检查未通过，已保留原配置"
                press_enter
                continue
            fi
            if [[ "$ports_changed" == "true" ]] && ! confirm_port_selection; then
                restore_runtime_params "$old_uuid" "$old_short_id" "$old_private_key" "$old_public_key" \
                    "$old_reality_port" "$old_reality_sni" "$old_ws_port" "$old_ws_path" \
                    "$old_node_name" "$old_hy2_port" "$old_hy2_password" "$old_hy2_sni" \
                    "$old_hy2_masquerade_url" \
                    "$old_subscription_port" "$old_argo_domain" "$old_argo_token" \
                    "$old_argo_best_cf_domain" "$old_argo_best_cf_domain_ipv4" "$old_argo_best_cf_domain_ipv6" \
                    "$old_link_ipv4_selection" "$old_public_ipv4_override" \
                    "$old_nat_mode" "$old_reality_public_port" "$old_hy2_public_port"
                warn "已取消端口修改"
                press_enter
                continue
            fi
            if [[ "$links_only_changed" != "true" ]] && ! open_service_ports; then
                restore_runtime_params "$old_uuid" "$old_short_id" "$old_private_key" "$old_public_key" \
                    "$old_reality_port" "$old_reality_sni" "$old_ws_port" "$old_ws_path" \
                    "$old_node_name" "$old_hy2_port" "$old_hy2_password" "$old_hy2_sni" \
                    "$old_hy2_masquerade_url" \
                    "$old_subscription_port" "$old_argo_domain" "$old_argo_token" \
                    "$old_argo_best_cf_domain" "$old_argo_best_cf_domain_ipv4" "$old_argo_best_cf_domain_ipv6" \
                    "$old_link_ipv4_selection" "$old_public_ipv4_override" \
                    "$old_nat_mode" "$old_reality_public_port" "$old_hy2_public_port"
                warn "端口放行失败，已保留原配置"
                press_enter
                continue
            fi

            if [[ "$restart_singbox" == "true" ]]; then
                # 确保 TLS 证书存在 (Hysteria2 需要)
                generate_tls_cert
                write_singbox_config
                write_singbox_service
                save_params
                ensure_time_sync || true
                info "重启 sing-box..."
                if ! service_restart sing-box; then
                    restore_runtime_params "$old_uuid" "$old_short_id" "$old_private_key" "$old_public_key" \
                        "$old_reality_port" "$old_reality_sni" "$old_ws_port" "$old_ws_path" \
                        "$old_node_name" "$old_hy2_port" "$old_hy2_password" "$old_hy2_sni" \
                        "$old_hy2_masquerade_url" \
                        "$old_subscription_port" "$old_argo_domain" "$old_argo_token" \
                        "$old_argo_best_cf_domain" "$old_argo_best_cf_domain_ipv4" "$old_argo_best_cf_domain_ipv6" \
                        "$old_link_ipv4_selection" "$old_public_ipv4_override" \
                        "$old_nat_mode" "$old_reality_public_port" "$old_hy2_public_port"
                    write_singbox_config
                    write_singbox_service
                    save_params
                    warn "sing-box 重启失败，正在恢复旧端口配置..."
                    service_restart sing-box 2>/dev/null || true
                    press_enter
                    continue
                fi
                sleep 2
                if service_is_active sing-box; then
                    success "配置已更新并重启"
                else
                    restore_runtime_params "$old_uuid" "$old_short_id" "$old_private_key" "$old_public_key" \
                        "$old_reality_port" "$old_reality_sni" "$old_ws_port" "$old_ws_path" \
                        "$old_node_name" "$old_hy2_port" "$old_hy2_password" "$old_hy2_sni" \
                        "$old_hy2_masquerade_url" \
                        "$old_subscription_port" "$old_argo_domain" "$old_argo_token" \
                        "$old_argo_best_cf_domain" "$old_argo_best_cf_domain_ipv4" "$old_argo_best_cf_domain_ipv6" \
                        "$old_link_ipv4_selection" "$old_public_ipv4_override" \
                        "$old_nat_mode" "$old_reality_public_port" "$old_hy2_public_port"
                    write_singbox_config
                    write_singbox_service
                    save_params
                    warn "sing-box 未成功启动，正在恢复旧端口配置..."
                    service_restart sing-box 2>/dev/null || true
                    press_enter
                    continue
                fi
            else
                save_params
                success "配置已更新"
            fi

            if [[ "$restart_argo" == "true" ]]; then
                if ! refresh_argo_runtime; then
                    restore_runtime_params "$old_uuid" "$old_short_id" "$old_private_key" "$old_public_key" \
                        "$old_reality_port" "$old_reality_sni" "$old_ws_port" "$old_ws_path" \
                        "$old_node_name" "$old_hy2_port" "$old_hy2_password" "$old_hy2_sni" \
                        "$old_hy2_masquerade_url" \
                        "$old_subscription_port" "$old_argo_domain" "$old_argo_token" \
                        "$old_argo_best_cf_domain" "$old_argo_best_cf_domain_ipv4" "$old_argo_best_cf_domain_ipv6" \
                        "$old_link_ipv4_selection" "$old_public_ipv4_override" \
                        "$old_nat_mode" "$old_reality_public_port" "$old_hy2_public_port"
                    save_params
                    if argo_fixed_enabled; then
                        write_argo_service
                        service_enable_now argo-tunnel 2>/dev/null || true
                    else
                        service_stop argo-tunnel 2>/dev/null || true
                        service_disable argo-tunnel 2>/dev/null || true
                    fi
                    warn "Argo 配置更新失败，已恢复原配置"
                    press_enter
                    continue
                fi
            fi
            generate_and_show_links
            ensure_subscription_service_if_enabled || warn "订阅服务启动失败，请检查 python3 或服务日志"
            show_subscription_url
            press_enter
        fi
    done
}

# ─── 查看链接 ────────────────────────────────────────────────
do_show_links() {
    load_params || { warn "未找到配置，请先安装"; press_enter; return; }
    ensure_time_sync || true

    refresh_argo_domain_if_needed

    generate_and_show_links
    ensure_subscription_service_if_enabled || warn "订阅服务未成功启动"
    show_subscription_url
    press_enter
}

# ─── 启动 / 停止 / 重启 ──────────────────────────────────────
do_start() {
    info "启动服务..."
    ensure_time_sync || true
    service_start sing-box && success "sing-box 已启动" || warn "sing-box 启动失败"
    if load_params; then
        if argo_fixed_enabled; then
            service_start argo-tunnel && success "argo-tunnel 已启动" || warn "argo-tunnel 启动失败"
        fi
        save_params
        build_share_links
        write_subscription_assets
        ensure_subscription_service_if_enabled || warn "订阅服务启动失败"
    fi
    press_enter
}

do_stop() {
    info "停止服务..."
    service_stop sing-box && success "sing-box 已停止" || warn "sing-box 停止失败"
    service_stop argo-tunnel && success "argo-tunnel 已停止" || warn "argo-tunnel 停止失败"
    service_stop sbm-subscription && success "订阅服务已停止" || warn "订阅服务停止失败"
    press_enter
}

do_restart() {
    info "重启服务..."
    ensure_time_sync || true
    service_restart sing-box && success "sing-box 已重启" || warn "sing-box 重启失败"
    if load_params; then
        if argo_fixed_enabled; then
            service_restart argo-tunnel && success "argo-tunnel 已重启" || warn "argo-tunnel 重启失败"
        fi
        save_params
        build_share_links
        write_subscription_assets
        ensure_subscription_service_if_enabled || warn "订阅服务重启失败"
        argo_fixed_enabled && info "Argo 域名: ${ARGO_DOMAIN}"
    fi
    press_enter
}

# ─── 重新优选 Reality 伪装域名 ───────────────────────────────
do_reoptimize_reality_sni() {
    if ! load_params; then
        warn "未安装，无法重新优选 Reality 伪装域名"
        return 1
    fi

    if xray_managed_reality; then
        warn "当前 Reality 由 Xray 管理，已禁止 sing-box 重写 SNI，避免与 Hysteria2 共用端口冲突"
        return 1
    fi

    local old_sni="${REALITY_SNI:-}"
    local prev_sni="${REALITY_SNI_PREV:-}"
    info "当前 Reality 伪装域名: ${old_sni:-未设置}，开始重新优选（自动避开当前与上一次域名）..."

    # 清空后触发实测筛选；通过 REALITY_SNI_EXCLUDE 排除当前与上一次域名，
    # 确保重新优选的结果一定不同，否则就失去了重新优选的意义。
    REALITY_SNI=""
    REALITY_SNI_EXCLUDE="${old_sni} ${prev_sni}"
    select_reality_sni
    REALITY_SNI_EXCLUDE=""

    if [[ -z "${REALITY_SNI:-}" ]]; then
        REALITY_SNI="$old_sni"
        warn "未能优选到可用域名，已保留原伪装域名: ${old_sni:-未设置}"
        return 1
    fi

    if [[ "$REALITY_SNI" == "$old_sni" ]]; then
        # 保护分支：候选已被排除，理论上不会命中；仅当可用候选过少时才可能
        success "未找到与当前不同的可用域名: ${REALITY_SNI}，保持不变，跳过重启"
        return 0
    fi

    # 记录上一次域名，下次重新优选时一并避开，避免 A→B→A 往返
    REALITY_SNI_PREV="$old_sni"

    info "新伪装域名: ${REALITY_SNI}，正在写入配置并重启 sing-box..."
    generate_tls_cert
    write_singbox_config
    write_singbox_service
    save_params
    ensure_time_sync || true

    if ! service_restart sing-box; then
        warn "sing-box 重启失败，正在回滚到原伪装域名: ${old_sni}"
        REALITY_SNI="$old_sni"
        REALITY_SNI_PREV="$prev_sni"
        write_singbox_config
        save_params
        service_restart sing-box 2>/dev/null || true
        return 1
    fi

    sleep 2
    if ! service_is_active sing-box; then
        warn "sing-box 未成功启动，正在回滚到原伪装域名: ${old_sni}"
        REALITY_SNI="$old_sni"
        REALITY_SNI_PREV="$prev_sni"
        write_singbox_config
        save_params
        service_restart sing-box 2>/dev/null || true
        return 1
    fi

    success "Reality 伪装域名已更新为: ${REALITY_SNI}"
    refresh_argo_domain_if_needed
    generate_and_show_links
    ensure_subscription_service_if_enabled || warn "订阅服务启动失败"
    show_subscription_url
    return 0
}

# ─── 应用当前版本配置 (一键同步) ─────────────────────────────
# 用当前已保存的凭证 (UUID / 端口 / 域名 / 密钥均不变) 按新版本模板
# 重写服务端配置并重启，再按新格式重新生成链接。适用于升级脚本后
# 让服务端配置与当前稳定链接格式同步生效。
do_apply_latest() {
    if ! load_params; then
        warn "未安装，无法应用配置更新"
        return 1
    fi

    info "正在按 v${SCRIPT_VERSION} 模板重写配置 (UUID / 端口 / 域名 / 密钥保持不变)..."
    ensure_time_sync || true
    generate_tls_cert
    write_singbox_config
    write_singbox_service
    save_params

    info "重启 sing-box 以使新配置生效..."
    if ! service_restart sing-box; then
        warn "sing-box 重启失败，请执行 sbm status 或查看日志排查"
        return 1
    fi
    sleep 2
    if ! service_is_active sing-box; then
        warn "sing-box 未成功启动，请查看日志排查"
        return 1
    fi

    success "配置已按 v${SCRIPT_VERSION} 同步并重启"
    refresh_argo_runtime || return 1
    generate_and_show_links
    ensure_subscription_service_if_enabled || warn "订阅服务启动失败"
    show_subscription_url
    info "请在客户端重新导入上方订阅 / 链接以获得最新格式。"
    return 0
}

disable_cfopt_auto() {
    if [[ "$(service_manager)" == "systemd" ]]; then
        systemctl disable --now sbm-cfopt.timer 2>/dev/null || true
        rm -f "$CFOPT_TIMER" "$CFOPT_SERVICE"
        systemctl daemon-reload 2>/dev/null || true
    fi
    rm -f "$CFOPT_CRON_PERIODIC" "$CFOPT_CRON_D"
    return 0
}

# ─── 查看状态 ────────────────────────────────────────────────
do_status() {
    echo ""
    echo -e "${CYAN}${BOLD}── sing-box 状态 ──${NC}"
    service_status sing-box || warn "sing-box 未安装"
    separator
    echo -e "${CYAN}${BOLD}── argo-tunnel 状态 ──${NC}"
    service_status argo-tunnel || warn "argo-tunnel 未安装"
    separator
    echo -e "${CYAN}${BOLD}── 订阅服务状态 ──${NC}"
    service_status sbm-subscription || warn "订阅服务未安装"
    press_enter
}

# ─── 查看日志 ────────────────────────────────────────────────
do_logs() {
    echo ""
    echo -e "  1) sing-box 日志"
    echo -e "  2) argo-tunnel 日志"
    echo -e "  3) 订阅服务日志"
    echo -e "  0) 返回"
    prompt_read choice "  请选择: "
    case "$choice" in
        1) service_logs sing-box 50 || warn "未找到 sing-box 日志" ;;
        2) service_logs argo-tunnel 50 || warn "未找到 argo-tunnel 日志" ;;
        3) service_logs sbm-subscription 50 || warn "未找到订阅服务日志" ;;
    esac
    press_enter
}

# ─── 开机自启设置 ──────────────────────────────────────────────
do_boot_manage() {
    echo ""
    echo -e "  1) 开启 sing-box 及已配置附加服务的开机自启"
    echo -e "  2) 关闭全部服务的开机自启"
    echo -e "  0) 返回"
    prompt_read choice "  请选择: "
    case "$choice" in
        1)
            service_enable sing-box 2>/dev/null || true
            load_params 2>/dev/null && argo_fixed_enabled && service_enable argo-tunnel 2>/dev/null || true
            load_params 2>/dev/null && argo_fixed_enabled && service_enable sbm-subscription 2>/dev/null || true
            success "已开启开机自启"
            ;;
        2)
            service_disable sing-box 2>/dev/null || true
            service_disable argo-tunnel 2>/dev/null || true
            service_disable sbm-subscription 2>/dev/null || true
            success "已关闭开机自启"
            ;;
    esac
    press_enter
}

# ─── 更新 sing-box ───────────────────────────────────────────
do_upgrade() {
    echo ""
    echo -e "  1) 更新 sing-box"
    echo -e "  2) 更新 cloudflared"
    echo -e "  3) 更新此管理脚本"
    echo -e "  0) 返回"
    prompt_read choice "  请选择: "
    case "$choice" in
        1)
            info "更新 sing-box..."
            install_or_upgrade_singbox_package true || error "sing-box 更新失败。请检查网络、磁盘空间或 GitHub 访问"
            write_singbox_service
            service_restart sing-box 2>/dev/null || true
            success "sing-box 已更新并重启"
            ;;
        2)
            info "更新 cloudflared..."
            if ! load_params || ! argo_fixed_enabled; then
                warn "当前未启用固定域名 Argo，无需更新 cloudflared"
                press_enter
                return
            fi
            install_cloudflared_binary || error "cloudflared 更新失败。请检查网络、磁盘空间或 GitHub 访问"
            service_restart argo-tunnel 2>/dev/null || true
            success "cloudflared 已更新并重启"
            ;;
        3)
            info "更新管理脚本..."
            if download_manager_command; then
                # 从新下载的脚本中提取版本号
                local new_ver
                new_ver=$(grep -m1 '^SCRIPT_VERSION=' "$MANAGER_COMMAND" | cut -d'"' -f2 2>/dev/null || echo "未知")
                success "脚本已更新: v${SCRIPT_VERSION} → v${new_ver}"
                echo ""
                info "当前配置和服务未受影响，不会重写配置或重启服务。"
                info "如需让服务端配置使用当前稳定模板，升级后执行: sbm apply"
                # 仅刷新链接显示 (不重写配置、不重启)
                if load_params; then
                    refresh_argo_domain_if_needed
                    generate_and_show_links
                    ensure_subscription_service_if_enabled || warn "订阅服务未成功启动"
                    show_subscription_url
                fi
                echo ""
                prompt_read _ "按 Enter 重启面板并进入新版本..." || true
                exec bash "$MANAGER_COMMAND"
            else
                warn "更新失败，请检查网络或手动更新"
            fi
            ;;
    esac
    press_enter
}

# ─── 卸载 ────────────────────────────────────────────────────
do_uninstall() {
    echo ""
    warn "即将卸载 sing-box 和 Argo 隧道"
    prompt_read confirm "  确认卸载？(y/N): "
    [[ "$confirm" =~ ^[Yy]$ ]] || { info "已取消"; press_enter; return; }

    service_stop sing-box 2>/dev/null || true
    service_disable sing-box 2>/dev/null || true
    service_stop argo-tunnel 2>/dev/null || true
    service_disable argo-tunnel 2>/dev/null || true
    service_stop sbm-subscription 2>/dev/null || true
    service_disable sbm-subscription 2>/dev/null || true
    disable_cfopt_auto 2>/dev/null || true
    rm -f "$ARGO_SERVICE"
    rm -f "$ARGO_OPENRC_SERVICE"
    rm -f "$SUBSCRIPTION_SERVICE"
    rm -f "$SUBSCRIPTION_OPENRC_SERVICE"
    rm -f "$SINGBOX_OPENRC_SERVICE"
    rm -f "$SINGBOX_SYSTEMD_OVERRIDE_FILE"
    rmdir "$SINGBOX_SYSTEMD_DROPIN_DIR" 2>/dev/null || true
    service_daemon_reload

    case "$(package_manager)" in
        apt) apt-get remove -y sing-box 2>/dev/null || true ;;
        dnf) dnf remove -y sing-box 2>/dev/null || true ;;
        yum) yum remove -y sing-box 2>/dev/null || true ;;
        apk) apk del sing-box 2>/dev/null || true ;;
    esac

    rm -f /usr/local/bin/cloudflared
    remove_manager_link "$MANAGER_SYSTEM_COMMAND" "$MANAGER_COMMAND"
    remove_manager_link "$MANAGER_SYSTEM_ALIAS_COMMAND" "$MANAGER_COMMAND"
    remove_manager_link "$MANAGER_BIN_COMMAND" "$MANAGER_COMMAND"
    remove_manager_link "$MANAGER_BIN_ALIAS_COMMAND" "$MANAGER_COMMAND"
    remove_manager_link "$MANAGER_ALIAS_COMMAND" "$MANAGER_COMMAND"
    remove_manager_link "$MANAGER_COMMAND" "$MANAGER_COMMAND"
    rm -f "$SUBSCRIPTION_SERVER"
    rm -rf "$CONFIG_DIR"

    success "卸载完成"
    press_enter
}

# ─── Banner ──────────────────────────────────────────────────
show_banner() {
    clear
    echo ""
    echo -e "  ${CYAN}${BOLD}sing-box 管理面板${NC}  ${DIM}v${SCRIPT_VERSION}${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"

    # 状态摘要
    local sb_status ar_status
    if service_is_active sing-box; then
        sb_status="${GREEN}● 运行中${NC}"
    else
        sb_status="${RED}○ 未运行${NC}"
    fi
    if service_is_active argo-tunnel; then
        ar_status="${GREEN}● 运行中${NC}"
    else
        ar_status="${RED}○ 未运行${NC}"
    fi

    echo -e "  sing-box:  ${sb_status}    argo-tunnel: ${ar_status}"
    [[ -n "${PUBLIC_IP:-}" ]] && echo -e "  服务器 IP: ${BOLD}${PUBLIC_IP}${NC}"
    echo ""
}

# ─── 主菜单 ──────────────────────────────────────────────────
show_menu() {
    echo -e "  ${CYAN}部署 & 配置${NC}"
    echo -e "   ${BOLD}1)${NC} 部署 / 安装节点"
    echo -e "   ${BOLD}2)${NC} 修改配置 ${DIM}(端口 / 域名 / UUID / SNI)${NC}"
    echo -e "   ${BOLD}3)${NC} 节点链接与订阅"
    echo ""
    echo -e "  ${CYAN}服务管理${NC}"
    echo -e "   ${BOLD}4)${NC} 启动     ${BOLD}5)${NC} 停止     ${BOLD}6)${NC} 重启"
    echo -e "   ${BOLD}7)${NC} 状态     ${BOLD}8)${NC} 日志     ${BOLD}9)${NC} 自启"
    echo ""
    echo -e "  ${CYAN}系统维护${NC}"
    echo -e "  ${BOLD}10)${NC} 更新     ${BOLD}11)${NC} 卸载     ${BOLD}0)${NC} 退出"
    echo ""
}

main_menu() {
    get_public_ip 2>/dev/null || true

    while true; do
        show_banner
        show_menu
        if ! prompt_read choice "  请选择 [0-11]: "; then
            echo ""
            warn "未检测到交互式终端，请在服务器终端直接执行: sbm"
            exit 1
        fi
        case "$choice" in
            1)  do_install ;;
            2)  do_modify_config ;;
            3)  do_show_links ;;
            4)  do_start ;;
            5)  do_stop ;;
            6)  do_restart ;;
            7)  do_status ;;
            8)  do_logs ;;
            9)  do_boot_manage ;;
            10) do_upgrade ;;
            11) do_uninstall ;;
            0)  echo -e "\n  ${CYAN}Bye!${NC}\n"; exit 0 ;;
            *)  warn "无效选项" ; sleep 0.5 ;;
        esac
    done
}

# ════════════════════════════════════════════════════════════
#  入口
# ════════════════════════════════════════════════════════════

main() {
    check_root
    detect_os

    install_manager_command

    # 命令行快捷参数
    # 若用户使用了旧命令名通过兼容链接启动，提示其换用新命令
    if [[ "$(basename "$0")" == "sing-box-manager" ]]; then
        warn "sing-box-manager 命令已更名，推荐后续直接输入: sbm"
        sleep 1
    fi

    case "${1:-}" in
        install)       do_primary_install ;;
        relay-install) do_relay_install ;;
        relay)         do_generate_relay_script ;;
        links|sub)   load_params && { ensure_time_sync || true; refresh_argo_domain_if_needed; generate_and_show_links; ensure_subscription_service_if_enabled || warn "订阅服务未成功启动"; show_subscription_url; } || warn "未安装" ;;
        start)       do_start ;;
        stop)        do_stop ;;
        restart)     do_restart ;;
        resni|reality-sni) do_reoptimize_reality_sni || warn "Reality 伪装域名优选未完成" ;;
        apply|sync)  do_apply_latest || warn "配置同步未完成" ;;
        cfopt|refresh-cf|cfopt-auto) warn "固定域名 Argo 不再使用第三方 CF 优选域名" ;;
        status)      do_status ;;
        uninstall)   do_uninstall ;;
        --help|-h)
            echo "用法: bash $0 [命令]"
            echo ""
            echo "命令:"
            echo "  (无参数)        交互式管理菜单"
            echo "  install         直接安装主节点"
            echo "  relay-install   直接部署当前机器为线路机 / 落地机"
            echo "  relay           生成线路机部署脚本"
            echo "  links           显示分享链接与订阅地址"
            echo "  sub             同 links"
            echo "  start           启动服务"
            echo "  stop            停止服务"
            echo "  restart         重启服务"
            echo "  resni           重新优选 Reality 伪装域名(SNI)并重启生效"
            echo "  apply           按当前版本模板重写配置并重启 (升级后一键同步)"
            echo "  status          查看状态"
            echo "  uninstall       卸载"
            exit 0
            ;;
        *)  main_menu ;;
    esac
}

if [[ "${SBM_TEST_MODE:-}" != "1" ]]; then
    main "$@"
fi
