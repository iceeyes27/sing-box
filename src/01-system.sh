# ─── 权限 / 系统检测 ─────────────────────────────────────────
check_root() {
    [[ $EUID -eq 0 ]] || error "请使用 root 权限运行: sudo bash $0"
}

detect_os() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  ARCH_CF="amd64" ;;
        aarch64) ARCH_CF="arm64" ;;
        armv7l)  ARCH_CF="arm" ;;
        i386|i686) ARCH_CF="386" ;;
        *) ARCH_CF="amd64" ;;
    esac
}

service_manager() {
    if command -v systemctl &>/dev/null && systemctl list-unit-files >/dev/null 2>&1; then
        echo "systemd"
    elif command -v rc-service &>/dev/null; then
        echo "openrc"
    else
        echo "none"
    fi
}

service_exists() {
    local svc=$1
    case "$(service_manager)" in
        systemd)
            local load_state
            load_state=$(systemctl show -p LoadState --value "$svc" 2>/dev/null || echo "not-found")
            [[ -n "$load_state" && "$load_state" != "not-found" ]]
            ;;
        openrc)
            [[ -x "/etc/init.d/${svc}" ]]
            ;;
        *) return 1 ;;
    esac
}

xray_managed_reality() {
    # Reality 是否由 Xray-core 承载：以持久化的 REALITY_BACKEND 为准，
    # 并要求 Xray 配置与服务实际存在，避免参数与落地状态不一致。
    [[ "${REALITY_BACKEND:-singbox}" == "xray" ]] || return 1
    [[ -f "${XRAY_CONFIG_FILE:-/etc/xray/config.json}" ]] && service_exists xray
}

service_daemon_reload() {
    [[ "$(service_manager)" == "systemd" ]] && systemctl daemon-reload 2>/dev/null || true
}

service_start() {
    local svc=$1
    case "$(service_manager)" in
        systemd) systemctl start "$svc" 2>/dev/null ;;
        openrc)  rc-service "$svc" start 2>/dev/null ;;
        *)       return 1 ;;
    esac
}

service_stop() {
    local svc=$1
    case "$(service_manager)" in
        systemd) systemctl stop "$svc" 2>/dev/null ;;
        openrc)  rc-service "$svc" stop 2>/dev/null ;;
        *)       return 1 ;;
    esac
}

service_restart() {
    local svc=$1
    case "$(service_manager)" in
        systemd) systemctl restart "$svc" 2>/dev/null ;;
        openrc)  rc-service "$svc" restart 2>/dev/null || rc-service "$svc" start 2>/dev/null ;;
        *)       return 1 ;;
    esac
}

# 用于交互式配置修改；缺少 timeout 时失败，而不是无限等待或误报成功。
service_restart_bounded() {
    local svc=$1 seconds=${2:-30} result
    if ! command -v timeout >/dev/null 2>&1; then
        warn "缺少 timeout 命令，无法安全重启 ${svc}"
        return 1
    fi
    case "$(service_manager)" in
        systemd) timeout "$seconds" systemctl restart "$svc" 2>/dev/null ;;
        openrc)
            timeout "$seconds" rc-service "$svc" restart 2>/dev/null && return 0
            result=$?
            if [[ "$result" == 124 || "$result" == 137 ]]; then
                return "$result"
            fi
            timeout "$seconds" rc-service "$svc" start 2>/dev/null
            ;;
        *) return 1 ;;
    esac
}

service_enable() {
    local svc=$1
    case "$(service_manager)" in
        systemd) systemctl enable "$svc" 2>/dev/null ;;
        openrc)  rc-update add "$svc" default 2>/dev/null ;;
        *)       return 1 ;;
    esac
}

service_disable() {
    local svc=$1
    case "$(service_manager)" in
        systemd) systemctl disable "$svc" 2>/dev/null ;;
        openrc)  rc-update del "$svc" default 2>/dev/null ;;
        *)       return 1 ;;
    esac
}

service_enable_now() {
    local svc=$1
    service_enable "$svc" 2>/dev/null || true
    service_restart "$svc" 2>/dev/null || service_start "$svc"
}

service_is_active() {
    local svc=$1
    case "$(service_manager)" in
        systemd) systemctl is-active --quiet "$svc" 2>/dev/null ;;
        openrc)  rc-service "$svc" status 2>/dev/null | grep -Eq 'started|running' ;;
        *)       return 1 ;;
    esac
}

service_status() {
    local svc=$1
    case "$(service_manager)" in
        systemd) systemctl status "$svc" --no-pager -l 2>/dev/null | head -15 ;;
        openrc)  rc-service "$svc" status 2>/dev/null || return 1 ;;
        *)       return 1 ;;
    esac
}

service_logs() {
    local svc=$1
    local lines=${2:-50}
    case "$(service_manager)" in
        systemd) journalctl -u "$svc" --output cat --no-pager -n "$lines" 2>/dev/null ;;
        openrc)
            if [[ -f "/var/log/${svc}.log" ]]; then
                tail -n "$lines" "/var/log/${svc}.log"
            else
                return 1
            fi
            ;;
        *) return 1 ;;
    esac
}
