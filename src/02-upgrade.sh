# 版本操作和菜单共用动作；Python 子进程负责完整事务和信号处理。
engine_upgrade() { engine_python upgrade "${1:-}"; }
engine_rollback() { engine_python rollback; }
engine_versions() { engine_python versions; }

engine_cli() {
    local action="$1" version="" confirmed=false
    shift
    [[ "${1:-}" == sing-box ]] || { warn "请指定 sing-box"; return 2; }
    shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes) confirmed=true; shift ;;
            --version)
                [[ "$action" == upgrade && $# -ge 2 && -z "$version" ]] || return 2
                version="$2"; shift 2 ;;
            *) warn "未知版本操作参数"; return 2 ;;
        esac
    done
    if [[ "$action" == versions ]]; then
        [[ -z "$version" ]] || return 2
        engine_versions
        return $?
    fi
    [[ "$confirmed" == true ]] || { warn "变更需要 --yes，首次使用将启用 sbm 版本管理并保留系统软件包"; return 2; }
    check_root
    if [[ "$action" == upgrade ]]; then sbm_with_lock engine_upgrade "$version"; else sbm_with_lock engine_rollback; fi
}

singbox_version_menu() {
    local choice version confirm
    while true; do
        menu_header "系统维护 / sing-box 版本管理"
        engine_versions || true
        menu_item 1 "更新稳定版"
        menu_item 2 "指定稳定版本"
        menu_item 3 "回退上一版本"
        menu_back
        prompt_menu_choice choice "  请选择: " "0 1 2 3" || return 0
        [[ "$choice" == 0 ]] && return 0
        version=""
        if [[ "$choice" == 2 ]]; then
            prompt_read version "  稳定版本号 (如 1.14.3)，输入 0 返回: " || return 0
            [[ "$version" == 0 ]] && continue
            [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { warn "版本号格式无效"; continue; }
        fi
        info "由 sbm 管理运行版本；系统软件包和当前配置保留。"
        prompt_read confirm "  确认执行版本操作？(y/N): " || return 0
        [[ "$confirm" =~ ^[Yy]$ ]] || continue
        if [[ "$choice" == 3 ]]; then sbm_with_lock engine_rollback || true; else sbm_with_lock engine_upgrade "$version" || true; fi
        press_enter
    done
}
