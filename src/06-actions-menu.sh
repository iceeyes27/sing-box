# ════════════════════════════════════════════════════════════
#  菜单功能
# ════════════════════════════════════════════════════════════

# ─── 完整安装 ────────────────────────────────────────────────
do_primary_install() {
    local INSTALL_NETWORK_MODE="" argo_ready=true subscription_ready=true
    menu_header "安装节点 / 1. 准备环境"
    if [[ "${REALITY_BACKEND:-singbox}" != "singbox" ]]; then
        error "新安装仅支持 sing-box 承载 Reality；已有 Xray 配置仍可继续管理"
    fi
    info "开始完整安装..."
    separator

    install_deps
    ensure_time_sync || true
    install_singbox
    generate_params
    detect_install_network || error "网络类型确认失败"
    prompt_install_protocols "$INSTALL_NETWORK_MODE" || error "协议选择未完成"
    if is_socks_enabled; then
        info "SOCKS5 已生成随机用户名和密码，安装后随节点链接显示。"
    fi
    ensure_reality_probe_dependencies || error "Reality 域名检查依赖不可用，安装已停止"
    select_reality_sni || error "未找到通过运行时检查的 Reality 伪装域名，安装已停止"

    while true; do
        # Reality 默认使用随机高位 TCP 端口，降低标准 443 端口的无效扫描压力。
        menu_header "安装节点 / 3. 端口与公网映射"
        menu_section "Reality 本机监听"
        menu_item 1 "自动高位端口" "${REALITY_PORT}/TCP · 推荐"
        menu_item 2 "使用 443/TCP"
        menu_item 3 "自定义 TCP 端口"
        prompt_read port_mode "  请选择 [1]: "
        port_mode=${port_mode:-1}

        if [[ "$port_mode" == "1" ]]; then
            info "已选择自动高位端口: ${REALITY_PORT}/TCP"
        elif [[ "$port_mode" == "2" ]]; then
            REALITY_PORT=443
            info "已选择标准端口: 443/TCP"
        else
            prompt_port_value REALITY_PORT "Reality" "$REALITY_PORT" "  Reality 端口 [${REALITY_PORT}]: " || error "端口读取失败"
        fi
        REALITY_PUBLIC_PORT="$REALITY_PORT"
        if is_socks_enabled; then
            prompt_port_value SOCKS_PORT "SOCKS5" "$SOCKS_PORT" "  SOCKS5 端口 [${SOCKS_PORT}]: " || error "SOCKS5 端口读取失败"
            SOCKS_PUBLIC_PORT="$SOCKS_PORT"
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

    menu_header "安装节点 / 4. 节点身份"
    prompt_read input "  Reality 伪装域名 [${REALITY_SNI}]: "
    if [[ -n "$input" ]]; then
        ensure_reality_probe_dependencies || error "Reality 域名安全检查依赖不可用，安装已停止"
        if reality_sni_runtime_usable "$input"; then
            REALITY_SNI="$input"
        else
            warn "该域名未通过 Reality 运行时检查，保留自动优选域名: ${REALITY_SNI}"
        fi
    fi

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

    # 仅为已勾选 Argo 的安装配置隧道模式。
    if argo_enabled; then
        menu_header "安装节点 / 5. Argo 隧道"
        menu_section "域名模式"
        menu_item 1 "临时域名" "trycloudflare.com · 推荐"
        menu_item 2 "固定域名" "需要 Cloudflare Tunnel Token"
        prompt_read argo_choice "  请选择 [1]: "
        argo_choice=${argo_choice:-1}
        if [[ "$argo_choice" == "2" ]]; then
            ARGO_ENABLED="true"
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
                warn "Token 或域名无效，改用临时 Argo"
                ARGO_TOKEN=""
                ARGO_DOMAIN=""
            fi
        else
            ARGO_ENABLED="true"
            ARGO_TOKEN=""
            ARGO_DOMAIN=""
        fi
    fi
    if argo_enabled; then
        if argo_quick_enabled && quick_tunnel_config_conflict; then
            error "临时 Argo 隧道配置冲突，安装已停止"
        fi
        if ! ensure_argo_dependencies; then
            error "Argo 依赖安装失败，所选协议组合未完成部署"
        fi
    fi
    if argo_enabled; then
        validate_service_ports "" "" "" false || error "Argo 端口配置无效"
    fi

    write_singbox_config
    write_singbox_service
    if argo_enabled; then
        write_argo_service || error "Argo 隧道配置失败，安装已停止"
    fi

    # 启动 sing-box
    info "启动 sing-box..."
    service_enable_now sing-box
    sleep 2
    if service_is_active sing-box; then
        success "sing-box 已启动"
    else
        error "sing-box 启动失败，请查看服务日志"
    fi

    if ! verify_or_reselect_reality_sni; then
        warn "Reality 完整 TLS 转发验证未通过，已保留当前运行配置"
        save_params
        return 1
    fi

    ensure_subscription_service_if_enabled || { subscription_ready=false; warn "订阅网关启动失败，可稍后执行 sbm restart 重试"; }

    if argo_enabled; then
        info "启动 Argo 隧道..."
        if service_enable_now argo-tunnel; then
            if argo_quick_enabled; then
                sleep 3
                fetch_argo_domain || { argo_ready=false; warn "Argo 已启动，但尚未取得临时域名"; }
            fi
            [[ -n "${ARGO_DOMAIN:-}" ]] && success "Argo 域名: $ARGO_DOMAIN"
        else
            argo_ready=false
            warn "Argo 隧道启动失败，可稍后执行 sbm restart 重试"
        fi
    fi

    if argo_enabled && [[ "$argo_ready" == "true" ]] && ! resolve_argo_best_cf_domains; then
        argo_ready=false
        warn "CF 优选地址未通过当前 Argo 域名的实测"
    fi

    # 保存参数
    save_params

    menu_header "安装节点 / 部署结果"
    if argo_enabled && { [[ "$argo_ready" != "true" || "$subscription_ready" != "true" ]] || ! service_is_active argo-tunnel || ! service_is_active sbm-subscription || ! is_valid_hostname "${ARGO_DOMAIN:-}"; }; then
        warn "所选协议组合尚未完成部署：Argo 或订阅网关未就绪。"
        return 1
    elif argo_enabled; then
        echo -e "${GREEN}${BOLD}✅ 所选服务已启动，节点连接仍需客户端验证。${NC}"
    elif [[ "$INSTALL_NETWORK_MODE" == "ipv6-only" ]]; then
        success "Reality 服务已部署；未启用 Argo，本地 IPv4 无法连接，未生成 Reality 直连链接。"
    else
        echo -e "${GREEN}${BOLD}✅ 部署完成！请导入下方 Reality 直连链接。${NC}"
    fi

    # 显示链接
    generate_and_show_links
    show_subscription_url
    verify_enabled_protocols || warn "部分协议未通过服务端认证测试；公网连接尚未验证"

    press_enter
}

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

# ─── 查看链接 ────────────────────────────────────────────────
do_show_links() {
    load_params || { warn "未找到配置，请先安装"; press_enter; return; }

    ensure_subscription_service_if_enabled || warn "订阅服务未成功启动"
    refresh_argo_domain_if_needed

    generate_and_show_links
    show_subscription_url
    press_enter
}

# ─── 启动 / 停止 / 重启 ──────────────────────────────────────
do_start() {
    menu_header "服务与诊断 / 启动服务"
    info "启动服务..."
    local core_ready=true
    service_start sing-box && success "sing-box 已启动" || { core_ready=false; warn "sing-box 启动失败"; }
    if load_params; then
        # 临时隧道的域名检查会访问源站，订阅网关必须先就绪。
        local subscription_ready=true
        ensure_subscription_service_if_enabled || { subscription_ready=false; warn "订阅服务启动失败"; }
        if argo_enabled; then
            if [[ "$subscription_ready" == "true" && "$core_ready" == "true" ]]; then
                service_start argo-tunnel && success "argo-tunnel 已启动" || warn "argo-tunnel 启动失败"
                refresh_argo_domain_if_needed
            else
                warn "sing-box 或订阅网关未就绪，未启动 Argo 隧道"
            fi
        fi
        save_params
        build_share_links
        write_subscription_assets
    fi
    press_enter
}

do_stop() {
    menu_header "服务与诊断 / 停止服务"
    info "停止服务..."
    service_stop sing-box && success "sing-box 已停止" || warn "sing-box 停止失败"
    service_stop argo-tunnel && success "argo-tunnel 已停止" || warn "argo-tunnel 停止失败"
    service_stop sbm-subscription && success "订阅服务已停止" || warn "订阅服务停止失败"
    press_enter
}

do_restart() {
    menu_header "服务与诊断 / 重启服务"
    info "重启服务..."
    local core_ready=true
    service_restart sing-box && success "sing-box 已重启" || { core_ready=false; warn "sing-box 重启失败"; }
    if load_params; then
        local subscription_ready=true
        ensure_subscription_service_if_enabled || { subscription_ready=false; warn "订阅服务重启失败"; }
        if argo_enabled; then
            if [[ "$subscription_ready" == "true" && "$core_ready" == "true" ]]; then
                service_restart argo-tunnel && success "argo-tunnel 已重启" || warn "argo-tunnel 重启失败"
                if argo_quick_enabled; then
                    sleep 3
                    fetch_argo_domain || warn "Argo 已重启，但尚未取得新的临时域名"
                fi
            else
                warn "sing-box 或订阅网关未就绪，未重启 Argo 隧道"
            fi
        fi
        save_params
        build_share_links
        write_subscription_assets
        argo_enabled && [[ -n "${ARGO_DOMAIN:-}" ]] && info "Argo 域名: ${ARGO_DOMAIN}"
    fi
    press_enter
}

# ─── Xray Reality 配置更新 ───────────────────────────────────
write_xray_reality_config() {
    local sni="$1"
    local port="${2:-}" uuid="${3:-}" private_key="${4:-}" short_id="${5:-}"
    local config="${XRAY_CONFIG_FILE:-/etc/xray/config.json}"
    local tmp="${config}.new"

    is_valid_hostname "$sni" || return 1
    [[ -z "$port" ]] || validate_port "$port" "Reality" || return 1
    [[ -f "$config" ]] || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    command -v xray >/dev/null 2>&1 || return 1

    if ! python3 - "$config" "$tmp" "$sni" "$port" "$uuid" "$private_key" "$short_id" <<'PY'
import json
import os
import sys

source, target, sni, port, uuid, private_key, short_id = sys.argv[1:]
with open(source, "r", encoding="utf-8") as handle:
    config = json.load(handle)

updated = False
for inbound in config.get("inbounds", []):
    stream = inbound.get("streamSettings", {})
    reality = stream.get("realitySettings")
    if inbound.get("protocol") != "vless" or stream.get("security") != "reality" or not isinstance(reality, dict):
        continue
    reality["target"] = f"{sni}:443"
    reality["serverNames"] = [sni]
    if port:
        clients = inbound.get("settings", {}).get("clients", [])
        if len(clients) != 1 or not all((uuid, private_key, short_id)):
            raise SystemExit("Xray Reality credentials missing or ambiguous")
        inbound["port"] = int(port)
        clients[0]["id"] = uuid
        reality["privateKey"] = private_key
        reality["shortIds"] = [short_id]
    updated = True

if not updated:
    raise SystemExit("Xray Reality inbound not found")

with open(target, "w", encoding="utf-8") as handle:
    json.dump(config, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
os.chmod(target, os.stat(source).st_mode & 0o777)
PY
    then
        rm -f "$tmp"
        return 1
    fi

    if ! xray run -test -format json -config "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        return 1
    fi

    mv -f "$tmp" "$config"
}

write_xray_reality_sni() {
    write_xray_reality_config "$1"
}

# ─── 重新优选 Reality 伪装域名 ───────────────────────────────
do_reoptimize_reality_sni() {
    menu_header "节点与协议 / Reality / 优选伪装域名"
    if ! load_params; then
        warn "未安装，无法重新优选 Reality 伪装域名"
        return 1
    fi

    local old_sni="${REALITY_SNI:-}"
    local prev_sni="${REALITY_SNI_PREV:-}"
    local reality_service="sing-box"
    xray_managed_reality && reality_service="xray"
    info "当前 Reality 伪装域名: ${old_sni:-未设置}，开始重新优选（自动避开当前与上一次域名）..."

    if ! ensure_reality_probe_dependencies; then
        warn "Reality 域名安全检查依赖不可用，已保留原配置"
        return 1
    fi

    # 清空后触发实测筛选；通过 REALITY_SNI_EXCLUDE 排除当前与上一次域名，
    # 确保重新优选的结果一定不同，否则就失去了重新优选的意义。
    REALITY_SNI=""
    REALITY_SNI_EXCLUDE="${old_sni} ${prev_sni}"
    if [[ "$reality_service" == "xray" ]]; then
        REALITY_SNI_EXCLUDE+=" www.microsoft.com www.apple.com gateway.icloud.com itunes.apple.com"
    fi
    if ! select_reality_sni; then
        REALITY_SNI="$old_sni"
        REALITY_SNI_EXCLUDE=""
        warn "未能优选到可用域名，已保留原伪装域名: ${old_sni:-未设置}"
        return 1
    fi
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

    info "新伪装域名: ${REALITY_SNI}，正在写入配置并重启 ${reality_service}..."
    if [[ "$reality_service" == "xray" ]]; then
        if ! write_xray_reality_sni "$REALITY_SNI"; then
            warn "Xray Reality 配置更新失败，已保留原伪装域名: ${old_sni}"
            REALITY_SNI="$old_sni"
            REALITY_SNI_PREV="$prev_sni"
            return 1
        fi
    else
        generate_tls_cert
        write_singbox_config
        write_singbox_service
    fi
    save_params

    if ! service_restart "$reality_service"; then
        warn "${reality_service} 重启失败，正在回滚到原伪装域名: ${old_sni}"
        REALITY_SNI="$old_sni"
        REALITY_SNI_PREV="$prev_sni"
        if [[ "$reality_service" == "xray" ]]; then
            write_xray_reality_sni "$old_sni" 2>/dev/null || true
        else
            write_singbox_config
        fi
        save_params
        service_restart "$reality_service" 2>/dev/null || true
        return 1
    fi

    sleep 2
    if ! service_is_active "$reality_service"; then
        warn "${reality_service} 未成功启动，正在回滚到原伪装域名: ${old_sni}"
        REALITY_SNI="$old_sni"
        REALITY_SNI_PREV="$prev_sni"
        if [[ "$reality_service" == "xray" ]]; then
            write_xray_reality_sni "$old_sni" 2>/dev/null || true
        else
            write_singbox_config
        fi
        save_params
        service_restart "$reality_service" 2>/dev/null || true
        return 1
    fi

    success "Reality 伪装域名已更新为: ${REALITY_SNI}"
    ensure_subscription_service_if_enabled || warn "订阅服务启动失败"
    refresh_argo_domain_if_needed
    generate_and_show_links
    show_subscription_url
    return 0
}

# ─── 应用当前版本配置 (一键同步) ─────────────────────────────
# 用当前已保存的凭证 (UUID / 端口 / 域名 / 密钥均不变) 按新版本模板
# 重写服务端配置并重启，再按新格式重新生成链接。适用于升级脚本后
# 让服务端配置与当前稳定链接格式同步生效。
do_apply_latest() {
    menu_header "系统维护 / 配置同步"
    if ! load_params; then
        warn "未安装，无法应用配置更新"
        return 1
    fi

    if ! ensure_reality_probe_dependencies; then
        warn "Reality 域名安全检查依赖不可用，未执行配置更新"
        return 1
    fi
    if ! reality_sni_runtime_usable "${REALITY_SNI:-}"; then
        warn "当前 Reality 伪装域名未通过运行时检查，未执行配置更新"
        return 1
    fi

    info "正在按 v${SCRIPT_VERSION} 模板重写配置 (UUID / 端口 / 域名 / 密钥保持不变)..."
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

    if ! verify_or_reselect_reality_sni; then
        warn "Reality 完整 TLS 转发验证未通过，已保留可恢复配置"
        return 1
    fi
    save_params

    success "配置已按 v${SCRIPT_VERSION} 同步并重启"
    refresh_argo_runtime || return 1
    generate_and_show_links
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
    menu_header "服务与诊断 / 运行状态"
    menu_section "sing-box"
    service_status sing-box || warn "sing-box 未安装"
    menu_section "argo-tunnel"
    service_status argo-tunnel || warn "argo-tunnel 未安装"
    menu_section "订阅服务"
    service_status sbm-subscription || warn "订阅服务未安装"
    press_enter
}

# ─── 查看日志 ────────────────────────────────────────────────
do_logs() {
    menu_header "服务与诊断 / 日志"
    menu_section "选择服务"
    menu_item 1 "sing-box 日志"
    menu_item 2 "argo-tunnel 日志"
    menu_item 3 "订阅服务日志"
    menu_back
    prompt_read choice "  请选择: " || return
    [[ "$choice" == 0 ]] && return
    case "$choice" in
        1) service_logs sing-box 50 || warn "未找到 sing-box 日志" ;;
        2) service_logs argo-tunnel 50 || warn "未找到 argo-tunnel 日志" ;;
        3) service_logs sbm-subscription 50 || warn "未找到订阅服务日志" ;;
    esac
    press_enter
}

# ─── 开机自启设置 ──────────────────────────────────────────────
do_boot_manage() {
    menu_header "服务与诊断 / 开机自启"
    menu_section "服务设置"
    menu_item 1 "开启" "sing-box 及已配置附加服务"
    menu_item 2 "关闭" "全部服务"
    menu_back
    prompt_read choice "  请选择: " || return
    [[ "$choice" == 0 ]] && return
    case "$choice" in
        1)
            service_enable sing-box 2>/dev/null || true
            load_params 2>/dev/null && argo_enabled && service_enable argo-tunnel 2>/dev/null || true
            load_params 2>/dev/null && argo_enabled && service_enable sbm-subscription 2>/dev/null || true
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
    menu_header "系统维护 / 更新"
    menu_section "组件"
    menu_item 1 "更新 sing-box"
    menu_item 2 "更新 cloudflared"
    menu_section "管理脚本"
    menu_item 3 "更新此管理脚本"
    menu_back
    prompt_read choice "  请选择: " || return
    [[ "$choice" == 0 ]] && return
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
            if ! load_params || ! argo_enabled; then
                warn "当前未启用 Argo，无需更新 cloudflared"
                press_enter
                return
            fi
            install_cloudflared_binary || error "cloudflared 更新失败。请检查网络、磁盘空间或 GitHub 访问"
            if ! service_restart argo-tunnel; then
                warn "cloudflared 已更新，但 Argo 隧道重启失败"
                press_enter
                return
            fi
            if argo_quick_enabled; then
                sleep 3
                fetch_argo_domain || warn "Argo 已重启，但尚未取得新的临时域名"
                save_params
            fi
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
                    ensure_subscription_service_if_enabled || warn "订阅服务未成功启动"
                    refresh_argo_domain_if_needed
                    generate_and_show_links
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
    menu_header "系统维护 / 卸载"
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
    menu_section "主菜单"
    menu_item 1 "节点与协议" "安装 / Reality / Hysteria2 / SOCKS5"
    menu_item 2 "连接与订阅" "Argo / NAT / 链接"
    menu_item 3 "服务与诊断" "运行 / 状态 / 日志"
    menu_item 4 "系统维护" "更新 / 配置同步 / 卸载"
    menu_back "退出"
}

node_menu() {
    local choice
    local MENU_CONTEXT="节点与协议"
    while true; do
        show_banner
        menu_header "节点与协议"
        menu_section "部署"
        menu_item 1 "安装节点"
        menu_section "协议配置"
        menu_item 2 "Reality"
        menu_item 3 "Hysteria2"
        menu_item 4 "SOCKS5"
        menu_item 5 "节点身份"
        menu_back
        prompt_read choice "  选择 [0-5]: " || return
        case "$choice" in
            1) do_primary_install ;;
            2) do_modify_config reality ;;
            3) do_modify_config hy2 ;;
            4) do_modify_config socks ;;
            5) do_modify_config identity ;;
            0) return ;;
            *) warn "无效选项" ;;
        esac
    done
}

connection_menu() {
    local choice
    local MENU_CONTEXT="连接与订阅"
    while true; do
        show_banner
        menu_header "连接与订阅"
        menu_section "隧道与订阅"
        menu_item 1 "Argo 与订阅配置"
        menu_item 2 "查看节点链接与订阅"
        menu_section "公网接入"
        menu_item 3 "公网 IPv4 与 NAT"
        menu_back
        prompt_read choice "  选择 [0-3]: " || return
        case "$choice" in
            1) do_modify_config argo ;;
            2) do_show_links ;;
            3) do_modify_config network ;;
            0) return ;;
            *) warn "无效选项" ;;
        esac
    done
}

service_menu() {
    local choice
    local MENU_CONTEXT="服务与诊断"
    while true; do
        show_banner
        menu_header "服务与诊断"
        menu_section "运行控制"
        menu_item 1 "启动服务"
        menu_item 2 "停止服务"
        menu_item 3 "重启服务"
        menu_section "检查"
        menu_item 4 "查看状态"
        menu_item 5 "查看日志"
        menu_item 6 "开机自启"
        menu_item 7 "协议自检" "认证与流量测试；公网仍需外部验证"
        menu_back
        prompt_read choice "  选择 [0-7]: " || return
        case "$choice" in
            1) do_start ;; 2) do_stop ;; 3) do_restart ;;
            4) do_status ;; 5) do_logs ;; 6) do_boot_manage ;;
            7) do_verify || warn "协议自检未通过"; press_enter ;;
            0) return ;;
            *) warn "无效选项" ;;
        esac
    done
}

maintenance_menu() {
    local choice
    local MENU_CONTEXT="系统维护"
    while true; do
        show_banner
        menu_header "系统维护"
        menu_section "更新"
        menu_item 1 "更新组件与管理脚本"
        menu_item 2 "按当前版本同步配置"
        menu_section "删除"
        menu_item 3 "卸载" "需再次确认"
        menu_back
        prompt_read choice "  选择 [0-3]: " || return
        case "$choice" in
            1) do_upgrade ;;
            2) do_apply_latest || warn "配置同步未完成"; press_enter ;;
            3) do_uninstall ;;
            0) return ;;
            *) warn "无效选项" ;;
        esac
    done
}

main_menu() {
    get_public_ip 2>/dev/null || true

    while true; do
        show_banner
        show_menu
        if ! prompt_read choice "  选择 [0-4]: "; then
            echo ""
            warn "未检测到交互式终端，请在服务器终端直接执行: sbm"
            exit 1
        fi
        case "$choice" in
            1)  node_menu ;;
            2)  connection_menu ;;
            3)  service_menu ;;
            4)  maintenance_menu ;;
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
        install)     do_primary_install ;;
        links|sub)   if load_params; then ensure_subscription_service_if_enabled || warn "订阅服务未成功启动"; refresh_argo_domain_if_needed; generate_and_show_links; show_subscription_url; else warn "未安装"; fi ;;
        start)       do_start ;;
        stop)        do_stop ;;
        restart)     do_restart ;;
        resni|reality-sni) do_reoptimize_reality_sni || warn "Reality 伪装域名优选未完成" ;;
        apply|sync)  do_apply_latest || warn "配置同步未完成" ;;
        cfopt|refresh-cf|cfopt-auto) warn "CF 优选现已在 links/sub 命令中自动执行" ;;
        status)      do_status ;;
        verify)      do_verify ;;
        uninstall)   do_uninstall ;;
        --help|-h)
            echo "用法: bash $0 [命令]"
            echo ""
            echo "命令:"
            echo "  (无参数)        交互式管理菜单"
            echo "  install         直接安装主节点"
            echo "  links           显示分享链接与订阅地址"
            echo "  sub             同 links"
            echo "  start           启动服务"
            echo "  stop            停止服务"
            echo "  restart         重启服务"
            echo "  resni           重新优选 Reality 伪装域名(SNI)并重启生效"
            echo "  apply           按当前版本模板重写配置并重启 (升级后一键同步)"
            echo "  status          查看状态"
            echo "  verify          对启用协议执行限时认证与流量测试"
            echo "  uninstall       卸载"
            exit 0
            ;;
        "") main_menu ;;
        *)
            error "未知命令: ${1}"
            echo "执行 'sbm --help' 查看可用命令"
            return 1
            ;;
    esac
}

if [[ "${SBM_TEST_MODE:-}" != "1" ]]; then
    main "$@"
fi
