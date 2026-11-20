# ════════════════════════════════════════════════════════════
#  菜单功能
# ════════════════════════════════════════════════════════════

# 仅在用户完成选择后更新参数；返回 1 表示取消或 EOF。
prompt_install_argo_config() {
    local argo_choice new_subscription_port new_argo_token new_argo_domain
    while true; do
        menu_header "安装节点 / 5. Argo 隧道"
        menu_section "域名模式"
        menu_item 1 "临时域名" "trycloudflare.com · 推荐"
        menu_item 2 "固定域名" "需要 Cloudflare Tunnel Token"
        menu_back "取消安装"
        prompt_menu_choice argo_choice "  请选择 [1]: " "0 1 2" 1 || return 1
        case "$argo_choice" in
            0) return 1 ;;
            1) ARGO_TOKEN=""; ARGO_DOMAIN=""; return 0 ;;
        esac
        prompt_port_value new_subscription_port "订阅服务" "$SUBSCRIPTION_PORT" \
            "  订阅服务端口 [${SUBSCRIPTION_PORT}]，输入 0 返回: " true || continue
        echo -e "\n  ${YELLOW}提示: 请前往 Cloudflare Zero Trust -> Networks -> Tunnels 创建隧道${NC}"
        echo -e "  并将 Public Hostname 转发至 ${GREEN}http://127.0.0.1:${new_subscription_port}${NC}"
        echo -e "  并获取其对应的 Token ${YELLOW}(以 eyJ 开头的一长串字符)。${NC}"
        echo -e "  ${RED}注意: 千万不要把 Tunnel ID (连接器 ID) 错当成 Token！${NC}"
        prompt_read new_argo_token "  请输入 Tunnel Token，输入 0 返回: " || return 1
        [[ "$new_argo_token" == 0 ]] && continue
        prompt_read new_argo_domain "  隧道绑定域名 (如 v2.example.com)，输入 0 返回: " || return 1
        [[ "$new_argo_domain" == 0 ]] && continue
        new_argo_domain="${new_argo_domain#http://}"
        new_argo_domain="${new_argo_domain#https://}"
        new_argo_domain="${new_argo_domain%/}"
        if [[ -z "$new_argo_token" ]] || ! is_valid_hostname "$new_argo_domain"; then
            warn "Token 或域名无效，请重新选择隧道模式"
            continue
        fi
        SUBSCRIPTION_PORT="$new_subscription_port"
        ARGO_TOKEN="$new_argo_token"
        ARGO_DOMAIN="$new_argo_domain"
        return 0
    done
}

# ─── 完整安装 ────────────────────────────────────────────────
do_primary_install() {
    [[ "${SBM_TEST_MODE:-}" == 1 ]] || install_manager_command
    local INSTALL_NETWORK_MODE="" argo_ready=true subscription_ready=true
    local input port_mode auto_reality_port
    menu_header "安装节点 / 1. 准备环境"
    if [[ "${REALITY_BACKEND:-singbox}" != "singbox" ]]; then
        error "新安装仅支持 sing-box 承载 Reality；已有 Xray 配置仍可继续管理"
    fi
    info "开始完整安装..."
    separator

    install_deps
    ensure_time_sync || true
    install_singbox || return 1
    generate_params
    if ! detect_install_network || ! prompt_install_protocols "$INSTALL_NETWORK_MODE"; then
        info "已取消安装"
        return 0
    fi
    auto_reality_port="$REALITY_PORT"
    if is_socks_enabled; then
        info "SOCKS5 已生成随机用户名和密码，安装后随节点链接显示。"
    fi
    ensure_reality_probe_dependencies || error "Reality 域名检查依赖不可用，安装已停止"
    select_reality_sni || error "未找到通过运行时检查的 Reality 伪装域名，安装已停止"

    # 在端口放行前确认所选 Hysteria2 的证书可用。
    if is_hy2_enabled; then
        generate_tls_cert
        if ! is_hy2_enabled; then
            warn "所选协议组合尚未完成部署：Hysteria2 证书不可用"
            return 1
        fi
    fi

    while true; do
        # Reality 默认使用随机高位 TCP 端口，降低标准 443 端口的无效扫描压力。
        menu_header "安装节点 / 3. 本机监听端口"
        menu_section "Reality 本机监听"
        menu_item 1 "自动高位端口" "${auto_reality_port}/TCP · 推荐"
        menu_item 2 "使用 443/TCP"
        menu_item 3 "自定义 TCP 端口"
        menu_back "取消安装"
        prompt_menu_choice port_mode "  请选择 [1]: " "0 1 2 3" 1 || { info "已取消安装"; return 0; }

        case "$port_mode" in
            0) info "已取消安装"; return 0 ;;
            1) REALITY_PORT="$auto_reality_port"; info "已选择自动高位端口: ${REALITY_PORT}/TCP" ;;
            2) REALITY_PORT=443; info "已选择标准端口: 443/TCP" ;;
            3)
                prompt_port_value REALITY_PORT "Reality" "$REALITY_PORT" \
                    "  Reality TCP 端口 [${REALITY_PORT}]，输入 0 返回: " true || continue
                ;;
        esac
        REALITY_PUBLIC_PORT="$REALITY_PORT"
        if is_hy2_enabled; then
            menu_section "Hysteria2 本机监听"
            prompt_hy2_port HY2_PORT || continue
        fi
        if is_socks_enabled; then
            prompt_port_value SOCKS_PORT "SOCKS5" "$SOCKS_PORT" \
                "  SOCKS5 TCP 端口 [${SOCKS_PORT}]，输入 0 返回: " true || continue
            SOCKS_PUBLIC_PORT="$SOCKS_PORT"
        fi

        reset_public_ip_cache
        refresh_public_ip_stack || true
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
        if ! adopt_reality_sni "$input"; then
            warn "该域名未通过 Reality 运行时检查（列表外域名还须直接返回 HTTP 200），保留自动优选域名: ${REALITY_SNI}"
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

    # 仅为已勾选 Argo 的安装配置隧道模式。
    if argo_enabled && ! prompt_install_argo_config; then
        info "已取消安装"
        return 0
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
    write_singbox_service || error "sing-box 服务文件更新失败，安装已停止"
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
