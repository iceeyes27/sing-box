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

# 所有 OpenRC 操作共享同一个截止时间，恢复步骤也计入超时。
service_command_before_deadline() {
    local deadline=$1 remaining
    shift
    remaining=$((deadline - SECONDS))
    (( remaining > 0 )) || return 124
    timeout -k 1 "$remaining" "$@"
}

openrc_service_pid_alive() {
    local svc=$1 pid=""
    [[ -r "/run/${svc}.pid" ]] || return 1
    read -r pid < "/run/${svc}.pid" || true
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null
}

# supervise-daemon 存活时，OpenRC 可能仍报告 started；还需检查业务子进程。
openrc_service_child_active() {
    local svc=$1 pid="" stat="" child_file="/run/openrc/options/${1}/child_pid"
    if [[ ! -r "$child_file" ]]; then
        # 旧后台服务没有监督器元数据，继续使用 OpenRC 自身的进程检查。
        if grep -qF 'supervisor="supervise-daemon"' "/etc/init.d/${svc}" 2>/dev/null; then
            return 1
        fi
        return 0
    fi
    read -r pid < "$child_file" || true
    [[ "$pid" =~ ^[1-9][0-9]*$ && -r "/proc/${pid}/stat" ]] || return 1
    read -r stat < "/proc/${pid}/stat" || return 1
    stat=${stat##*) }
    [[ "${stat%% *}" != Z && "${stat%% *}" != X ]] && kill -0 "$pid" 2>/dev/null
}

openrc_stop_service() {
    local svc=$1 deadline=$2 result=0 status=0
    service_command_before_deadline "$deadline" rc-service "$svc" stop || result=$?
    case "$result" in 124|137) return "$result" ;; esac
    service_command_before_deadline "$deadline" rc-service "$svc" status >/dev/null 2>&1 || status=$?
    case "$status" in
        3) return 0 ;;
        32|64)
            # 只清理已确认崩溃的服务；仍有存活 PID 时不能移除管理状态。
            if openrc_service_pid_alive "$svc"; then
                warn "${svc} 仍有存活进程，未清除 OpenRC 状态"
                return 1
            fi
            service_command_before_deadline "$deadline" rc-service "$svc" zap
            ;;
        0) return 1 ;;
        *) return "$status" ;;
    esac
}

openrc_service_action() (
    local svc=$1 action=$2 seconds=${3:-30} status=0 attempt
    [[ "$seconds" =~ ^[1-9][0-9]*$ ]] || return 1
    if ! command -v timeout >/dev/null 2>&1; then
        warn "缺少 timeout 命令，无法限时操作 ${svc}"
        return 1
    fi
    SECONDS=0
    service_command_before_deadline "$seconds" rc-service "$svc" status >/dev/null 2>&1 || status=$?
    case "$status" in
        0)
            if [[ "$action" == start ]]; then
                if openrc_service_child_active "$svc"; then return 0; fi
                action=restart
            fi
            ;;
        3|16) action=start ;;
        32|64)
            openrc_stop_service "$svc" "$seconds" || return $?
            action=start
            ;;
        *) return "$status" ;;
    esac
    service_command_before_deadline "$seconds" rc-service "$svc" "$action" || return $?
    # 后台启动返回成功不代表进程存活；连续检查可识别启动后立即退出。
    for ((attempt = 0; attempt < 2; attempt++)); do
        service_command_before_deadline "$seconds" sleep 0.2 || return $?
        service_command_before_deadline "$seconds" rc-service "$svc" status >/dev/null 2>&1 || return $?
        openrc_service_child_active "$svc" || return 1
    done
)

openrc_supervision_block() {
    cat <<'EOF'
supervisor="supervise-daemon"
respawn_delay=5
respawn_max=5
respawn_period=60
EOF
}

# 切换旧后台服务前先用旧脚本停止进程，避免新监督器无法接管旧进程。
prepare_openrc_supervision() (
    local svc=$1 service_file=$2 status=0
    [[ -f "$service_file" ]] || return 0
    grep -qF 'supervisor="supervise-daemon"' "$service_file" && return 0
    command -v timeout >/dev/null 2>&1 || return 1
    SECONDS=0
    service_command_before_deadline 30 rc-service "$svc" status >/dev/null 2>&1 || status=$?
    case "$status" in
        0|32|64) openrc_stop_service "$svc" 30 ;;
        3|16) return 0 ;;
        *) return "$status" ;;
    esac
)

service_start() {
    local svc=$1
    case "$(service_manager)" in
        systemd) systemctl start "$svc" 2>/dev/null ;;
        openrc)  openrc_service_action "$svc" start ;;
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
        openrc)  openrc_service_action "$svc" restart ;;
        *)       return 1 ;;
    esac
}

# 用于交互式配置修改；缺少 timeout 时失败，而不是无限等待或误报成功。
service_restart_bounded() {
    local svc=$1 seconds=${2:-30}
    if ! command -v timeout >/dev/null 2>&1; then
        warn "缺少 timeout 命令，无法安全重启 ${svc}"
        return 1
    fi
    case "$(service_manager)" in
        systemd) timeout "$seconds" systemctl restart "$svc" 2>/dev/null ;;
        openrc) openrc_service_action "$svc" restart "$seconds" ;;
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
        openrc)  rc-service "$svc" status >/dev/null 2>&1 && openrc_service_child_active "$svc" ;;
        *)       return 1 ;;
    esac
}

# Report an unknown state separately from a confirmed stopped/disabled state.
service_runtime_state() {
    local svc=$1 state status=0
    case "$(service_manager)" in
        systemd)
            state=$(systemctl is-active "$svc" 2>/dev/null) || true
            case "$state" in
                active|activating|deactivating|reloading) echo running ;;
                inactive|failed) echo stopped ;;
                *) return 1 ;;
            esac
            ;;
        openrc)
            rc-service "$svc" status >/dev/null 2>&1 || status=$?
            case "$status" in
                0) openrc_service_child_active "$svc" || return 1; echo running ;;
                3) echo stopped ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

service_boot_state() {
    local svc=$1 state
    case "$(service_manager)" in
        systemd)
            state=$(systemctl is-enabled "$svc" 2>/dev/null) || true
            case "$state" in
                enabled|enabled-runtime|linked|linked-runtime) echo enabled ;;
                disabled|masked|masked-runtime|static|indirect) echo disabled ;;
                *) return 1 ;;
            esac
            ;;
        openrc)
            state=$(rc-update show default 2>/dev/null) || return 1
            if printf '%s\n' "$state" | grep -Eq "^[[:space:]]*${svc}[[:space:]]*\\|"; then
                echo enabled
            else
                echo disabled
            fi
            ;;
        *) return 1 ;;
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
