# ─── Banner ──────────────────────────────────────────────────
banner_service_status() {
    if service_is_active "$1"; then
        printf '%b' "${GREEN}● 运行中${NC}"
    else
        printf '%b' "${RED}○ 未运行${NC}"
    fi
}

show_banner() {
    clear
    echo ""
    echo -e "  ${CYAN}${BOLD}sing-box 管理面板${NC}  ${DIM}v${SCRIPT_VERSION}${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"

    if has_stale_config; then
        echo -e "  ${YELLOW}检测到旧配置，但 sing-box 未安装${NC}"
        echo ""
        return
    elif ! is_installed; then
        echo -e "  ${YELLOW}尚未安装节点${NC}"
        echo ""
        return
    fi
    # 未配置 Argo 时不显示 argo-tunnel，避免把“未启用”误读为故障。
    local status_line
    status_line="  sing-box: $(banner_service_status sing-box)"
    if service_exists argo-tunnel 2>/dev/null; then
        status_line+="    argo-tunnel: $(banner_service_status argo-tunnel)"
    fi
    echo -e "$status_line"
    [[ -n "${PUBLIC_IP:-}" ]] && echo -e "  服务器 IP: ${BOLD}${PUBLIC_IP}${NC}"
    echo ""
}

# ─── 主菜单 ──────────────────────────────────────────────────
show_menu() {
    menu_section "主菜单"
    if is_installed; then
        menu_action 1 do_show_links "查看节点链接" "分享链接 / 订阅地址"
        menu_action 2 protocol_menu "协议设置" "Reality / Hysteria2 / SOCKS5 / Argo"
        menu_action 3 "do_modify_config network" "网络设置" "NAT / 公网 IPv4 / 出站 IP 优先级"
        menu_action 4 service_menu "服务管理" "启停 / 日志 / 自检 / 连通性排查"
        menu_action 5 maintenance_menu "系统维护" "更新 / 配置同步 / 重装 / 卸载"
    elif has_stale_config; then
        menu_action 1 do_primary_install "安装节点" "将覆盖旧配置"
        menu_action 2 do_upgrade_script "更新管理脚本"
    else
        menu_action 1 do_primary_install "安装节点" "Reality 主节点，可选 Argo / SOCKS5"
        menu_action 2 do_upgrade_script "更新管理脚本"
    fi
    menu_back "退出"
}

feature_state_label() {
    if "$1"; then
        printf '已启用 · %s' "$2"
    else
        printf '未启用'
    fi
}

render_protocol_menu() {
    menu_section "直连协议"
    menu_action 1 "do_modify_config reality" "Reality" "$(reality_share_port)/TCP · ${REALITY_SNI:-}"
    menu_action 2 "do_modify_config hy2" "Hysteria2" "$(feature_state_label is_hy2_enabled "$(hy2_share_port)/UDP")"
    menu_action 3 "do_modify_config socks" "SOCKS5" "$(feature_state_label is_socks_enabled "$(socks_share_port)/TCP")"
    menu_section "隧道"
    menu_action 4 "do_modify_config argo" "Argo 隧道" "$(argo_mode_label)"
    menu_section "通用"
    menu_action 5 "do_modify_config identity" "节点名称与 UUID" "${NODE_NAME:-}"
}

# 进入时读取一次参数；子页面修改后全局变量已同步，重绘无需再读。
protocol_menu() {
    load_params >/dev/null 2>&1 || true
    run_menu "协议设置" render_protocol_menu
}

render_service_menu() {
    menu_section "运行控制"
    menu_action 1 do_start "启动服务"
    menu_action 2 do_stop "停止服务"
    menu_action 3 do_restart "重启服务"
    menu_section "诊断"
    menu_action 4 do_status "查看状态"
    menu_action 5 do_logs "查看日志"
    menu_action 6 do_verify_menu "协议自检" "本机认证与流量测试"
    menu_action 7 do_connectivity_guide "公网连通性排查" "外部检测端口是否被封"
    menu_section "设置"
    menu_action 8 do_boot_manage "开机自启"
}

service_menu() {
    run_menu "服务管理" render_service_menu
}

render_maintenance_menu() {
    menu_section "更新"
    menu_action 1 do_upgrade_script "更新管理脚本" "不改动配置和服务"
    menu_action 2 do_upgrade_singbox "更新 sing-box"
    menu_action 3 do_upgrade_cloudflared "更新 cloudflared" "仅 Argo 使用"
    menu_action 4 do_apply_menu "按当前版本同步配置" "升级脚本后执行，等同 sbm apply"
    menu_section "重装与卸载"
    menu_action 5 do_reinstall "重新安装节点" "覆盖当前配置"
    menu_action 6 do_uninstall "卸载" "需再次确认"
}

maintenance_menu() {
    run_menu "系统维护" render_maintenance_menu
}

do_verify_menu() {
    do_verify || warn "协议自检未通过；可查看日志，或用「公网连通性排查」确认外部可达"
    press_enter
}

do_apply_menu() {
    do_apply_latest || warn "配置同步未完成"
    press_enter
}

main_menu() {
    get_public_ip 2>/dev/null || true
    local action
    local MENU_CONTEXT="主菜单"
    local -a MENU_ACTIONS=()

    while true; do
        MENU_ACTIONS=()
        show_banner
        show_menu
        if ! menu_read_action action; then
            echo ""
            warn "未检测到交互式终端，请在服务器终端直接执行: sbm"
            exit 1
        fi
        case "$action" in
            0)  echo -e "\n  ${CYAN}Bye!${NC}\n"; exit 0 ;;
            "") menu_invalid ;;
            # shellcheck disable=SC2086 # 按空格拆分为函数名和参数
            *)  $action ;;
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
        links|sub)   show_links || warn "未安装" ;;
        start)       do_start ;;
        stop)        do_stop ;;
        restart)     do_restart ;;
        resni|reality-sni) do_reoptimize_reality_sni || warn "Reality 伪装域名优选未完成" ;;
        apply|sync)  do_apply_latest || warn "配置同步未完成" ;;
        cfopt|refresh-cf|cfopt-auto) warn "CF 优选现已在 links/sub 命令中自动执行" ;;
        status)      do_status ;;
        verify)      do_verify ;;
        check)       show_connectivity_guide ;;
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
            echo "  check           输出公网端口外部检测地址与结果判断"
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
