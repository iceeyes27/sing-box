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
