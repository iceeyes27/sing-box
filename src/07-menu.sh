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
    menu_item 1 "节点与协议" "安装 / Reality / Hysteria2 / SOCKS5 / Argo"
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
        menu_item 5 "Argo 隧道" "可选"
        menu_item 6 "节点身份"
        menu_back
        prompt_read choice "  选择 [0-6]: " || return
        case "$choice" in
            1) do_primary_install ;;
            2) do_modify_config reality ;;
            3) do_modify_config hy2 ;;
            4) do_modify_config socks ;;
            5) do_modify_config argo ;;
            6) do_modify_config identity ;;
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
            echo -e "${RED}[ERROR]${NC} 未知命令: ${1}" >&2
            echo "执行 'sbm --help' 查看可用命令" >&2
            return 1
            ;;
    esac
}

if [[ "${SBM_TEST_MODE:-}" != "1" ]]; then
    main "$@"
fi
