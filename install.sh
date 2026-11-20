#!/usr/bin/env bash
#
# ════════════════════════════════════════════════════════════════
#  sing-box 一键部署 & 管理脚本
#  VLESS + Reality (直连) + VLESS + WS (Cloudflare Argo)
#  支持在线一键安装 / 交互式管理 / Cloudflare 优选 IP
# ════════════════════════════════════════════════════════════════
#
#  在线安装:
#    bash <(curl -fsSL "https://raw.githubusercontent.com/iceeyes27/sing-box/main/install.sh")
#

if [ -z "${BASH_VERSION:-}" ]; then
    case "${1:-}" in
        doctor|versions|--help|-h)
            if command -v bash >/dev/null 2>&1; then exec bash "$0" "$@"; fi
            echo "检查未完成：缺少 Bash；未安装任何依赖。" >&2
            exit 2
            ;;
    esac
    set -e
    INSTALL_URL="https://raw.githubusercontent.com/iceeyes27/sing-box/main/install.sh"
    tmp_file="${TMPDIR:-/tmp}/sbm-install.$$"
    trap 'rm -f "$tmp_file"' EXIT HUP INT TERM

    if ! command -v bash >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
        if command -v apk >/dev/null 2>&1; then
            apk add --no-cache bash curl
        elif command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq
            apt-get install -y -qq --no-install-recommends bash curl
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y -q bash curl
        elif command -v yum >/dev/null 2>&1; then
            yum install -y -q bash curl
        fi
    fi

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$INSTALL_URL" -o "$tmp_file"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$tmp_file" "$INSTALL_URL"
    else
        echo "ERROR: curl or wget is required" >&2
        exit 1
    fi

    exec bash "$tmp_file" "$@"
fi

set -euo pipefail

# ─── 常量 ─────────────────────────────────────────────────────
SCRIPT_VERSION="3.4.2"
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
PARAMS_FILE="${CONFIG_DIR}/.params"
SINGBOX_BIN_DIR="/usr/local/bin"
SINGBOX_BIN_PATH="${SINGBOX_BIN_DIR}/sing-box"
LINK_FILE="${CONFIG_DIR}/share-links.txt"
SUBSCRIPTION_FILE="${CONFIG_DIR}/subscription.txt"
SUBSCRIPTION_ENV_FILE="${CONFIG_DIR}/sbm-subscription.env"
SUBSCRIPTION_SERVER="/usr/local/bin/sbm-subscription-server.py"
SUBSCRIPTION_SERVICE="/etc/systemd/system/sbm-subscription.service"
SUBSCRIPTION_OPENRC_SERVICE="/etc/init.d/sbm-subscription"
SUBSCRIPTION_PORT=24630
MANAGER_COMMAND="/usr/local/bin/sbm"
MANAGER_ALIAS_COMMAND="/usr/local/bin/sing-box-manager"
MANAGER_SYSTEM_COMMAND="/usr/bin/sbm"
MANAGER_SYSTEM_ALIAS_COMMAND="/usr/bin/sing-box-manager"
MANAGER_BIN_COMMAND="/bin/sbm"
MANAGER_BIN_ALIAS_COMMAND="/bin/sing-box-manager"
ARGO_SERVICE="/etc/systemd/system/argo-tunnel.service"
ARGO_OPENRC_SERVICE="/etc/init.d/argo-tunnel"
ARGO_ENV_FILE="${CONFIG_DIR}/argo-tunnel.env"
# 旧版 CF 优选定时任务路径，仅用于卸载清理。
CFOPT_SERVICE="/etc/systemd/system/sbm-cfopt.service"
CFOPT_TIMER="/etc/systemd/system/sbm-cfopt.timer"
CFOPT_CRON_PERIODIC="/etc/periodic/weekly/sbm-cfopt"
CFOPT_CRON_D="/etc/cron.d/sbm-cfopt"
XRAY_CONFIG_DIR="/etc/xray"
XRAY_CONFIG_FILE="${XRAY_CONFIG_DIR}/config.json"
SINGBOX_OPENRC_SERVICE="/etc/init.d/sing-box"
SINGBOX_SYSTEMD_SERVICE="/etc/systemd/system/sing-box.service"
SINGBOX_SYSTEMD_MANAGED_MARKER="# Managed by sbm: sing-box installed from release tarball"
SINGBOX_PACKAGED_UNIT_DIRS=(/lib/systemd/system /usr/lib/systemd/system)
SINGBOX_SYSTEMD_DROPIN_DIR="/etc/systemd/system/sing-box.service.d"
# 仓库内置的 sing-box 备份 (vendor/sing-box/)：官方安装渠道均不可用时使用。
VENDORED_SINGBOX_VERSION="1.14.3"
VENDORED_SINGBOX_BASE_URL="https://raw.githubusercontent.com/iceeyes27/sing-box/main/vendor/sing-box"
SINGBOX_SYSTEMD_OVERRIDE_FILE="${SINGBOX_SYSTEMD_DROPIN_DIR}/override.conf"
HY2_DEFAULT_PORT=8443
HY2_DEFAULT_SNI="bing.com"
HY2_DEFAULT_MASQUERADE_URL=""
TIME_SKEW_THRESHOLD=30
LOW_MEMORY_SWAP_FILE="/swapfile.sbm-install"
LOW_MEMORY_SWAP_CREATED=false

# Argo 连接地址候选。它们只用于 URI 的地址部分；SNI 和 Host 始终使用
# ARGO_DOMAIN，不能把这些地址当作 Reality 伪装域名。
ARGO_CF_DOMAIN_LIST_VERSION="2026-09-21.1"
ARGO_CF_DOMAINS=(
    "cf.090227.xyz"
    "cf.877774.xyz"
    "cf.130519.xyz"
    "cf.008500.xyz"
    "store.ubi.com"
    "saas.sin.fan"
)

# Reality 候选通过实际 TLS 1.3 + HTTP/2 握手筛选，按成功率与延迟择优。
# 不依赖第三方 ASN 查询，也不限制正常的 CNAME、多 IP 或 IPv6 解析。
# Cloudflare 域名不列入候选，实际连接到 Cloudflare 地址的探测仍会被排除。
REALITY_SNI_LIST=(
    "www.nazhumi.com"
    "portal.citygrainla.com"
    "www.microsoft.com"
    "www.apple.com"
    "gateway.icloud.com"
    "itunes.apple.com"
    "www.tesla.com"
    "www.intel.com"
    "www.nvidia.com"
    "www.amd.com"
    "www.ibm.com"
    "www.cisco.com"
    "www.dell.com"
    "www.hp.com"
    "www.samsung.com"
    "www.sony.com"
    "www.oracle.com"
)

# 同网段邻居域名扫描是可选来源，仅在用户主动执行时访问以下第三方接口。
REALITY_NEIGHBOR_PREFIX_API="https://stat.ripe.net/data/network-info/data.json?resource="
REALITY_NEIGHBOR_CERTS_API="https://bgp.he.net/certs/api/ip-search?ip="
REALITY_NEIGHBOR_MAX_CANDIDATES=40
REALITY_NEIGHBOR_SERIAL_CANDIDATES=16

# ─── 颜色 ─────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'
if [[ -n "${NO_COLOR:-}" || ! -t 1 ]]; then
    RED='' GREEN='' YELLOW='' CYAN='' BOLD='' DIM='' NC=''
fi

# ─── 辅助函数 ────────────────────────────────────────────────
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

is_valid_hostname() {
    local hostname="${1:-}" label
    local -a labels=()

    [[ -n "$hostname" && ${#hostname} -le 253 ]] || return 1
    [[ "$hostname" == *.* && "$hostname" != .* && "$hostname" != *. ]] || return 1
    IFS='.' read -r -a labels <<< "$hostname"
    for label in "${labels[@]}"; do
        [[ -n "$label" && ${#label} -le 63 ]] || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
}

argo_fixed_enabled() {
    [[ "${ARGO_ENABLED:-false}" == "true" ]] && \
        [[ -n "${ARGO_TOKEN:-}" ]] && is_valid_hostname "${ARGO_DOMAIN:-}"
}

argo_quick_enabled() {
    [[ "${ARGO_ENABLED:-false}" == "true" ]] && [[ -z "${ARGO_TOKEN:-}" ]]
}

argo_enabled() {
    argo_fixed_enabled || argo_quick_enabled
}

argo_mode_label() {
    if argo_fixed_enabled; then
        echo "固定域名"
    elif argo_quick_enabled; then
        echo "临时域名"
    else
        echo "未启用"
    fi
}
success() { echo -e "${GREEN}${BOLD}[OK]${NC} $*"; }

separator() {
    echo -e "${DIM}─────────────────────────────────────────────${NC}"
}

menu_header() {
    echo ""
    echo -e "  ${CYAN}${BOLD}sbm${NC} ${DIM}/ $1${NC}"
    separator
}

menu_section() {
    echo ""
    echo -e "  ${CYAN}${BOLD}$1${NC}"
}

menu_item() {
    echo -e "  ${BOLD}$1)${NC} $2${3:+ ${DIM}$3${NC}}"
}

menu_back() {
    echo ""
    menu_item 0 "${1:-返回上级}"
    echo ""
}

# 菜单 render 函数用 menu_action 同时显示选项并登记命令，编号与分发写在同一处，不会错位。
# MENU_ACTIONS 由 run_menu / prompt_modify_action / main_menu 声明为 local。
menu_action() {
    menu_item "$1" "$3" "${4:-}"
    MENU_ACTIONS[$1]="$2"
}

menu_invalid() {
    warn "无效选项"
    sleep 0.5
}

# 简单选择页使用显式白名单；输错时重试，EOF 不改变调用方的值。
prompt_menu_choice() {
    local __menu_result="$1" __menu_prompt="$2" __menu_choices=" $3 "
    local __menu_default="${4:-}" __menu_choice
    while true; do
        prompt_read __menu_choice "$__menu_prompt" || return 1
        __menu_choice="${__menu_choice:-$__menu_default}"
        if [[ "$__menu_choice" =~ ^(0|[1-9][0-9]*)$ && "$__menu_choices" == *" $__menu_choice "* ]]; then
            printf -v "$__menu_result" '%s' "$__menu_choice"
            return 0
        fi
        warn "无效选项，请重新选择"
    done
}

# 读取一次选择，把 menu_action 登记的命令写入 $1：输入 0 写入 0，无效选项写入空串，EOF 返回 1。
menu_read_action() {
    local result_var="$1" choice
    prompt_read choice "  选择: " || return 1
    printf -v "$result_var" '%s' ""
    if [[ "$choice" == 0 ]]; then
        printf -v "$result_var" '0'
    elif [[ "$choice" =~ ^[1-9][0-9]?$ && -n "${MENU_ACTIONS[choice]:-}" ]]; then
        printf -v "$result_var" '%s' "${MENU_ACTIONS[choice]}"
    fi
}

# 循环显示子菜单并执行选中项；登记的命令格式为 "函数名 [参数]"。
run_menu() {
    local title="$1" render="$2" action
    local MENU_CONTEXT="$title"
    local -a MENU_ACTIONS=()
    while true; do
        MENU_ACTIONS=()
        show_banner
        menu_header "$title"
        "$render"
        menu_back
        menu_read_action action || return 0
        case "$action" in
            0) return 0 ;;
            "") menu_invalid ;;
            *)
                # shellcheck disable=SC2086 # 按空格拆分为函数名和参数
                sbm_menu_action "$action" || true
                ;;
        esac
    done
}

press_enter() {
    [[ "${SBM_NONINTERACTIVE:-false}" == true ]] && return 0
    echo ""
    prompt_read _ "按 Enter 返回${MENU_CONTEXT:-上级菜单}..." || true
}

# 第一个参数是接收输入的变量名，由 read 按名称赋值。
# shellcheck disable=SC2229
prompt_read() {
    local __var_name="$1"
    local __prompt="$2"

    if [[ -t 0 ]]; then
        read -r -p "$__prompt" "$__var_name"
        return $?
    fi

    if [[ -r /dev/tty ]]; then
        read -r -p "$__prompt" "$__var_name" </dev/tty
        return $?
    fi

    return 1
}

prompt_multiline() {
    local __var_name="$1"
    local __prompt="$2"
    local __end_hint="${3:-  输入空行结束}"
    local __line
    local __content=""

    echo -e "$__prompt"
    echo -e "${DIM}${__end_hint}${NC}"

    while true; do
        if [[ -t 0 ]]; then
            IFS= read -r __line
        elif [[ -r /dev/tty ]]; then
            IFS= read -r __line </dev/tty
        else
            break
        fi

        [[ -n "$__line" ]] || break
        if [[ -z "$__content" ]]; then
            __content="$__line"
        else
            __content+=$'\n'"$__line"
        fi
    done

    printf -v "$__var_name" '%s' "$__content"
}
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
    local invocation_id=""
    case "$(service_manager)" in
        systemd)
            # 临时隧道重启后域名会变化；只读取当前进程的日志，避免沿用旧域名。
            if [[ "${3:-}" == current ]]; then
                invocation_id=$(systemctl show "$svc" --property=InvocationID --value 2>/dev/null) || true
            fi
            if [[ "$invocation_id" =~ ^[[:xdigit:]]{32}$ ]]; then
                journalctl -u "$svc" "_SYSTEMD_INVOCATION_ID=${invocation_id}" \
                    --output cat --no-pager -n "$lines" 2>/dev/null
            else
                journalctl -u "$svc" --output cat --no-pager -n "$lines" 2>/dev/null
            fi
            ;;
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
# ─── 公网地址 / NAT ─────────────────────────────────────────
is_valid_ipv4() {
    local ip="$1" octet
    local -a octets

    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r -a octets <<< "$ip"
    [[ ${#octets[@]} -eq 4 ]] || return 1
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]+$ ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done
    return 0
}

is_private_ipv4() {
    local ip=$1
    [[ "$ip" =~ ^10\. ]] && return 0
    [[ "$ip" =~ ^192\.168\. ]] && return 0
    [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
    [[ "$ip" =~ ^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\. ]] && return 0
    [[ "$ip" =~ ^169\.254\. ]] && return 0
    return 1
}

ipv4_to_int() {
    local a b c d
    IFS=. read -r a b c d <<< "$1"
    echo $(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))
}

ipv4_in_cidr() {
    local ip="${1:-}" cidr="${2:-}" bits mask
    [[ "$cidr" == */* ]] || return 1
    bits="${cidr#*/}"
    is_valid_ipv4 "$ip" || return 1
    is_valid_ipv4 "${cidr%/*}" || return 1
    [[ "$bits" =~ ^[0-9]+$ ]] || return 1
    (( 10#$bits >= 1 && 10#$bits <= 32 )) || return 1
    mask=$(( (0xFFFFFFFF << (32 - 10#$bits)) & 0xFFFFFFFF ))
    (( ($(ipv4_to_int "$ip") & mask) == ($(ipv4_to_int "${cidr%/*}") & mask) ))
}

# 输出 $1 所在、前缀长度为 $2 的网段，例如 203.0.113.9 24 → 203.0.113.0/24。
ipv4_network() {
    local bits="$2" value
    value=$(( $(ipv4_to_int "$1") & (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
    printf '%d.%d.%d.%d/%d\n' $(( value >> 24 )) $(( (value >> 16) & 255 )) $(( (value >> 8) & 255 )) $(( value & 255 )) "$bits"
}

is_valid_public_ipv4_for_link() {
    local ip="$1" first_octet

    is_valid_ipv4 "$ip" || return 1
    is_private_ipv4 "$ip" && return 1
    [[ "$ip" =~ ^127\. || "$ip" =~ ^0\. || "$ip" =~ ^255\. ]] && return 1
    first_octet=${ip%%.*}
    (( 10#$first_octet < 224 )) || return 1
    return 0
}

fetch_public_ipv4() {
    local endpoint ip
    for endpoint in \
        "https://ifconfig.me" \
        "https://api.ipify.org" \
        "https://icanhazip.com"; do
        ip=$(curl -4 -s --max-time 4 "$endpoint" 2>/dev/null | tr -d '[:space:]' || true)
        if is_valid_public_ipv4_for_link "$ip"; then
            printf '%s' "$ip"
            return 0
        fi
    done
    return 1
}

fetch_public_ipv6() {
    local endpoint ip
    for endpoint in \
        "https://api6.ipify.org" \
        "https://ifconfig.me" \
        "https://icanhazip.com"; do
        ip=$(curl -6 -s --max-time 4 "$endpoint" 2>/dev/null | tr -d '[:space:]' || true)
        if [[ "$ip" == *:* && "$ip" != *"<"* ]]; then
            printf '%s' "$ip"
            return 0
        fi
    done
    return 1
}

# 出口查询可能返回宿主机的 NAT66 地址；入站链接只能自动选择本机已分配的公网地址。
get_inbound_ipv6() {
    local address
    command -v ip &>/dev/null || return 1
    address=$(ip -6 -o addr show scope global 2>/dev/null | awk '
        / (tentative|dadfailed|deprecated)( |$)/ { next }
        {
            split($4, parts, "/")
            if (parts[1] !~ /^[23][[:xdigit:]]*:/) next
            if ($0 !~ / temporary( |$)/ && stable == "") stable = parts[1]
            if (temporary == "") temporary = parts[1]
        }
        END {
            if (stable != "") print stable
            else if (temporary != "") print temporary
        }
    ') || return 1
    [[ -n "$address" ]] || return 1
    printf '%s' "$address"
}

append_public_ipv4_candidate() {
    local ip="$1"

    is_valid_public_ipv4_for_link "$ip" || return 0
    printf '%s\n' "${PUBLIC_IPV4_LIST:-}" | grep -Fxq "$ip" 2>/dev/null && return 0

    if [[ -z "${PUBLIC_IPV4_LIST:-}" ]]; then
        PUBLIC_IPV4_LIST="$ip"
    else
        PUBLIC_IPV4_LIST+=$'\n'"$ip"
    fi
}

collect_public_ipv4_candidates() {
    local ip

    PUBLIC_IPV4_LIST=""
    [[ -n "${PUBLIC_IPV4:-}" ]] && append_public_ipv4_candidate "$PUBLIC_IPV4"

    if command -v ip &>/dev/null; then
        while IFS= read -r ip; do
            append_public_ipv4_candidate "$ip"
        done < <(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
    fi

    [[ -n "$PUBLIC_IPV4_LIST" ]] || return 1
    PUBLIC_IPV4=$(printf '%s\n' "$PUBLIC_IPV4_LIST" | head -n 1) || true
    return 0
}

refresh_public_ip_stack() {
    if [[ -n "${PUBLIC_IPV4_OVERRIDE:-}" ]]; then
        if ! is_valid_public_ipv4_for_link "$PUBLIC_IPV4_OVERRIDE"; then
            return 1
        fi
        PUBLIC_IPV4="$PUBLIC_IPV4_OVERRIDE"
        PUBLIC_IPV4_LIST="$PUBLIC_IPV4_OVERRIDE"
        PUBLIC_IP="$PUBLIC_IPV4_OVERRIDE"
        PUBLIC_IPV6=$(fetch_public_ipv6 || true)
        if [[ -n "$PUBLIC_IPV6" ]]; then
            IP_STACK_MODE="dual-stack"
        else
            IP_STACK_MODE="ipv4-only"
        fi
        return 0
    fi

    if [[ -n "${IP_STACK_MODE:-}" && -n "${PUBLIC_IP:-}" ]]; then
        if [[ -n "${PUBLIC_IPV4:-}" && -z "${PUBLIC_IPV4_LIST:-}" ]]; then
            collect_public_ipv4_candidates || true
        fi
        return 0
    fi

    reset_public_ip_cache

    PUBLIC_IPV4=$(fetch_public_ipv4 || true)
    PUBLIC_IPV6=$(fetch_public_ipv6 || true)
    collect_public_ipv4_candidates || true

    if [[ -n "$PUBLIC_IPV4" ]]; then
        PUBLIC_IP="$PUBLIC_IPV4"
        if [[ -n "$PUBLIC_IPV6" ]]; then
            IP_STACK_MODE="dual-stack"
        else
            IP_STACK_MODE="ipv4-only"
        fi
        return 0
    fi

    if [[ -n "$PUBLIC_IPV6" ]]; then
        PUBLIC_IP="$PUBLIC_IPV6"
        IP_STACK_MODE="ipv6-only"
        return 0
    fi

    return 1
}

get_public_ip() {
    refresh_public_ip_stack || error "无法获取公网 IP"
}

format_url_host() {
    local host="$1"
    if [[ "$host" == *:* ]]; then
        printf '[%s]' "$host"
    else
        printf '%s' "$host"
    fi
}

has_public_ip_on_interface() {
    command -v ip &>/dev/null || return 1
    ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$PUBLIC_IP"
}

detect_external_access_mode() {
    refresh_public_ip_stack || { echo "unknown"; return 0; }

    if [[ "${IP_STACK_MODE:-}" == "ipv6-only" ]]; then
        echo "ipv6-only"
        return 0
    fi

    if has_public_ip_on_interface; then
        if [[ "${IP_STACK_MODE:-}" == "dual-stack" ]]; then
            echo "dual-stack"
        else
            echo "direct"
        fi
        return 0
    fi

    # 公网 IPv4 只能通过外部查询获得、但不在本机网卡上，通常表示共享 IPv4/NAT。
    echo "nat"
}

nat_mode_enabled() {
    [[ "${NAT_MODE:-false}" == "true" ]]
}

# 出站 IP 优先级：default 不写 DNS/解析策略，保持 sing-box 默认行为；
# 其余取值直接作为 direct 出站 domain_resolver.strategy。
is_valid_outbound_ip_strategy() {
    case "${1:-}" in
        default|prefer_ipv4|prefer_ipv6|ipv4_only|ipv6_only) return 0 ;;
    esac
    return 1
}

outbound_ip_strategy_label() {
    case "${OUTBOUND_IP_STRATEGY:-default}" in
        prefer_ipv4) echo "优先 IPv4" ;;
        prefer_ipv6) echo "优先 IPv6" ;;
        ipv4_only)   echo "仅 IPv4" ;;
        ipv6_only)   echo "仅 IPv6" ;;
        *)           echo "默认" ;;
    esac
}

reality_share_port() {
    if nat_mode_enabled; then
        printf '%s' "${REALITY_PUBLIC_PORT:-${REALITY_PORT}}"
    else
        printf '%s' "${REALITY_PORT}"
    fi
}

socks_share_port() {
    if nat_mode_enabled; then
        printf '%s' "${SOCKS_PUBLIC_PORT:-${SOCKS_PORT}}"
    else
        printf '%s' "${SOCKS_PORT}"
    fi
}

public_ipv4_candidate_count() {
    [[ -n "${PUBLIC_IPV4_LIST:-}" ]] || { echo 0; return 0; }
    printf '%s\n' "$PUBLIC_IPV4_LIST" | sed '/^$/d' | wc -l | tr -d '[:space:]'
}

reset_public_ip_cache() {
    PUBLIC_IPV4=""
    PUBLIC_IPV4_LIST=""
    PUBLIC_IPV6=""
    PUBLIC_IP=""
    IP_STACK_MODE=""
}

public_ipv4_display() {
    if [[ -n "${PUBLIC_IPV4_OVERRIDE:-}" ]]; then
        printf '%s (手动覆盖)' "$PUBLIC_IPV4_OVERRIDE"
    elif [[ -n "${PUBLIC_IPV4_LIST:-}" ]]; then
        printf '%s\n' "$PUBLIC_IPV4_LIST" | awk 'NF { if (out) out=out ", " $0; else out=$0 } END { print out }'
    else
        printf '%s' "${PUBLIC_IPV4:-${PUBLIC_IP:-未获取}}"
    fi
}

selected_public_ipv4_list() {
    local selection="${LINK_IPV4_SELECTION:-all}"
    local ip

    if [[ -n "${PUBLIC_IPV4_OVERRIDE:-}" ]]; then
        is_valid_public_ipv4_for_link "$PUBLIC_IPV4_OVERRIDE" && printf '%s\n' "$PUBLIC_IPV4_OVERRIDE"
        return 0
    fi

    if [[ -z "${PUBLIC_IPV4_LIST:-}" ]]; then
        ip="${PUBLIC_IPV4:-${PUBLIC_IP:-}}"
        is_valid_public_ipv4_for_link "$ip" && printf '%s\n' "$ip"
        return 0
    fi
    if [[ "$selection" != "all" ]]; then
        while IFS= read -r ip; do
            if [[ "$ip" == "$selection" ]]; then
                printf '%s\n' "$ip"
                return 0
            fi
        done <<< "$PUBLIC_IPV4_LIST"
        warn "已保存的 IPv4 ${selection} 当前未检测到，改为输出全部 IPv4。"
    fi
    printf '%s\n' "$PUBLIC_IPV4_LIST"
}

link_ipv4_selection_label() {
    local count
    if [[ -n "${PUBLIC_IPV4_OVERRIDE:-}" ]]; then
        echo "手动覆盖 IPv4"
        return 0
    fi
    count=$(public_ipv4_candidate_count)
    if [[ "${LINK_IPV4_SELECTION:-all}" == "all" ]]; then
        if (( count > 1 )); then
            echo "全部 IPv4"
        else
            echo "默认 IPv4"
        fi
    else
        echo "${LINK_IPV4_SELECTION}"
    fi
}
# ─── 参数持久化 ──────────────────────────────────────────────
PARAM_KEYS=(
    UUID SHORT_ID PRIVATE_KEY PUBLIC_KEY REALITY_PORT REALITY_SNI REALITY_SNI_PREV REALITY_SNI_CUSTOM REALITY_BACKEND WS_PORT WS_PATH NODE_NAME
    SUB_TOKEN SUBSCRIPTION_PORT ARGO_ENABLED ARGO_DOMAIN ARGO_TOKEN ARGO_BEST_CF_DOMAIN
    ARGO_BEST_CF_DOMAIN_IPV4 ARGO_BEST_CF_DOMAIN_IPV6 ARGO_CF_CACHE_DOMAIN ARGO_CF_CACHE_VERSION
    LINK_IPV4_SELECTION PUBLIC_IPV4_OVERRIDE
    HY2_PORT HY2_PASSWORD HY2_SNI HY2_MASQUERADE_URL HY2_ENABLED
    SOCKS_PORT SOCKS_USERNAME SOCKS_PASSWORD SOCKS_ENABLED
    NAT_MODE REALITY_PUBLIC_PORT SOCKS_PUBLIC_PORT
    OUTBOUND_IP_STRATEGY
)

is_param_key() {
    local candidate="$1" key
    for key in "${PARAM_KEYS[@]}"; do
        [[ "$candidate" == "$key" ]] && return 0
    done
    return 1
}

shell_quote() {
    printf '%q' "${1:-}"
}

write_env_file() {
    local file="$1"
    shift

    mkdir -p "$(dirname "$file")"
    : > "$file"
    chmod 600 "$file"
    while [[ $# -gt 0 ]]; do
        local key="$1" value="${2:-}"
        shift 2
        [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
        printf '%s=%s\n' "$key" "$(shell_quote "$value")" >> "$file"
    done
    chown root:root "$file" 2>/dev/null || true
}

write_param() {
    local key="$1"
    local value="${!key-}"
    # 参数文件由专用解析器读取，不执行 shell。统一双引号格式可安全保留
    # 空格、反斜杠、引号和凭据中的 URL 特殊字符。
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '%s="%s"\n' "$key" "$value"
}

random_hex() {
    local bytes="$1" value
    if command -v openssl &>/dev/null; then
        openssl rand -hex "$bytes"
        return $?
    fi
    if resolve_singbox_binary >/dev/null 2>&1; then
        run_singbox generate rand "$bytes" --hex 2>/dev/null && return 0
    fi
    if [[ -r /dev/urandom ]] && command -v od &>/dev/null; then
        value=$(od -An -N "$bytes" -tx1 /dev/urandom 2>/dev/null | tr -d '[:space:]')
        [[ -n "$value" ]] && { printf '%s\n' "$value"; return 0; }
    fi
    return 1
}

random_base64() {
    local bytes="$1" value
    if command -v openssl &>/dev/null; then
        openssl rand -base64 "$bytes"
        return $?
    fi
    if [[ -r /dev/urandom ]] && command -v dd &>/dev/null && command -v base64 &>/dev/null; then
        value=$(dd if=/dev/urandom bs="$bytes" count=1 2>/dev/null | base64 | tr -d '\n')
        [[ -n "$value" ]] && { printf '%s\n' "$value"; return 0; }
    fi
    random_hex "$bytes"
}

parse_param_value() {
    local raw="$1"

    if [[ "$raw" == \"*\" && "$raw" == *\" && ${#raw} -ge 2 ]]; then
        raw="${raw:1:${#raw}-2}"
        raw="${raw//\\\"/\"}"
        raw="${raw//\\\\/\\}"
    elif [[ "$raw" == \'*\' && "$raw" == *\' && ${#raw} -ge 2 ]]; then
        raw="${raw:1:${#raw}-2}"
    fi

    printf '%s' "$raw"
}

load_param_file() {
    local line key raw_value

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" && "$line" != \#* ]] || continue
        [[ "$line" == *"="* ]] || continue
        key="${line%%=*}"
        raw_value="${line#*=}"
        [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
        is_param_key "$key" || continue
        printf -v "$key" '%s' "$(parse_param_value "$raw_value")"
    done < "$PARAMS_FILE"
}

save_params() {
    if [[ "${SBM_LOCK_HELD:-}" != "$BASHPID" && "${SBM_TEST_MODE:-}" != 1 ]]; then
        sbm_with_lock save_params
        return $?
    fi
    mkdir -p "$CONFIG_DIR"
    : > "$PARAMS_FILE"
    chmod 600 "$PARAMS_FILE"
    local key
    for key in "${PARAM_KEYS[@]}"; do
        write_param "$key" >> "$PARAMS_FILE"
    done
    chown root:root "$PARAMS_FILE" 2>/dev/null || true
}

singbox_binary_present() {
    resolve_singbox_binary >/dev/null 2>&1
}

load_params_readonly() {
    [[ -r "$PARAMS_FILE" ]] || return 1
    load_param_file
    HY2_PORT="${HY2_PORT:-$HY2_DEFAULT_PORT}"
    HY2_ENABLED="${HY2_ENABLED:-false}"
    SOCKS_PORT="${SOCKS_PORT:-0}"
    SOCKS_ENABLED="${SOCKS_ENABLED:-false}"
    ARGO_ENABLED="${ARGO_ENABLED:-false}"
    NODE_NAME="${NODE_NAME:-未设置}"
}

is_installed() {
    [[ -f "$PARAMS_FILE" ]] && singbox_binary_present
}

# 只剩参数文件、sing-box 已不存在（手动删除或旧版残留）。
has_stale_config() {
    [[ -f "$PARAMS_FILE" ]] && ! singbox_binary_present
}

# Explicit persistence is used by migration callers; normal reads remain in memory.
# shellcheck disable=SC2120
load_params() {
    local persist="${1:-false}"
    if [[ -f "$PARAMS_FILE" ]]; then
        load_param_file
        # 兼容旧版本:逐字段补齐 Hysteria2 / Argo / SOCKS5 参数，绝不覆盖已有值。
        local need_save=false
        if ! grep -q '^REALITY_BACKEND=' "$PARAMS_FILE" 2>/dev/null; then
            if [[ -f "${XRAY_CONFIG_FILE:-/etc/xray/config.json}" ]] && service_exists xray; then
                REALITY_BACKEND="xray"
            else
                REALITY_BACKEND="singbox"
            fi
            need_save=true
        elif [[ "${REALITY_BACKEND:-}" != "singbox" && "${REALITY_BACKEND:-}" != "xray" ]]; then
            REALITY_BACKEND="singbox"
            need_save=true
        fi
        if [[ -z "${HY2_PORT:-}" ]]; then
            HY2_PORT=${HY2_DEFAULT_PORT}
            need_save=true
        fi
        if [[ -z "${HY2_PASSWORD:-}" ]]; then
            HY2_PASSWORD=$(random_base64 16)
            need_save=true
        fi
        if [[ -z "${HY2_SNI:-}" ]]; then
            HY2_SNI="${HY2_DEFAULT_SNI}"
            need_save=true
        fi
        if ! grep -q '^HY2_MASQUERADE_URL=' "$PARAMS_FILE" 2>/dev/null; then
            HY2_MASQUERADE_URL="${HY2_DEFAULT_MASQUERADE_URL}"
            need_save=true
        fi
        if ! grep -q '^HY2_ENABLED=' "$PARAMS_FILE" 2>/dev/null; then
            HY2_ENABLED="true"
            need_save=true
        elif [[ "${HY2_ENABLED:-}" != "true" && "${HY2_ENABLED:-}" != "false" ]]; then
            HY2_ENABLED="true"
            need_save=true
        fi
        if ! validate_port "${SOCKS_PORT:-}" "SOCKS5" >/dev/null 2>&1; then
            SOCKS_PORT=$(select_random_available_tcp_port \
                "${REALITY_PORT:-}" "${WS_PORT:-}" "${SUBSCRIPTION_PORT:-}")
            need_save=true
        fi
        if [[ -z "${SOCKS_USERNAME:-}" ]]; then
            SOCKS_USERNAME="proxy-${SHORT_ID:-user}"
            need_save=true
        fi
        if [[ -z "${SOCKS_PASSWORD:-}" ]]; then
            SOCKS_PASSWORD=$(random_hex 16)
            need_save=true
        fi
        if ! grep -q '^SOCKS_ENABLED=' "$PARAMS_FILE" 2>/dev/null; then
            # 新增能力对旧安装保持关闭，避免升级后意外扩大公网暴露面。
            SOCKS_ENABLED="false"
            need_save=true
        elif [[ "${SOCKS_ENABLED:-}" != "true" && "${SOCKS_ENABLED:-}" != "false" ]]; then
            SOCKS_ENABLED="false"
            need_save=true
        fi
        if [[ -z "${ARGO_TOKEN:-}" ]]; then
            ARGO_TOKEN=""
            # need_save 不标记，除非有实质性变化
        fi
        if ! grep -q '^ARGO_ENABLED=' "$PARAMS_FILE" 2>/dev/null; then
            # 旧固定域名与旧临时隧道继续启用；v2.7.8+ 的空 Argo 配置保持关闭。
            if [[ -n "${ARGO_TOKEN:-}" ]] && is_valid_hostname "${ARGO_DOMAIN:-}"; then
                ARGO_ENABLED="true"
            elif [[ "${ARGO_DOMAIN:-}" == *.trycloudflare.com ]]; then
                ARGO_ENABLED="true"
            else
                ARGO_ENABLED="false"
            fi
            need_save=true
        elif [[ "${ARGO_ENABLED:-}" != "true" && "${ARGO_ENABLED:-}" != "false" ]]; then
            ARGO_ENABLED="false"
            need_save=true
        fi
        if [[ -z "${ARGO_BEST_CF_DOMAIN:-}" ]]; then
            ARGO_BEST_CF_DOMAIN=""
        fi
        if [[ ! ${ARGO_BEST_CF_DOMAIN_IPV4+x} ]]; then
            ARGO_BEST_CF_DOMAIN_IPV4="${ARGO_BEST_CF_DOMAIN:-}"
            need_save=true
        fi
        if [[ ! ${ARGO_BEST_CF_DOMAIN_IPV6+x} ]]; then
            ARGO_BEST_CF_DOMAIN_IPV6=""
            need_save=true
        fi
        if [[ ! ${ARGO_CF_CACHE_DOMAIN+x} ]]; then
            ARGO_CF_CACHE_DOMAIN=""
            need_save=true
        fi
        if [[ ! ${ARGO_CF_CACHE_VERSION+x} ]]; then
            ARGO_CF_CACHE_VERSION=""
            need_save=true
        fi
        if [[ -z "${LINK_IPV4_SELECTION:-}" ]]; then
            LINK_IPV4_SELECTION="all"
            need_save=true
        elif [[ "$LINK_IPV4_SELECTION" != "all" ]]; then
            if ! is_valid_public_ipv4_for_link "$LINK_IPV4_SELECTION"; then
                LINK_IPV4_SELECTION="all"
                need_save=true
            fi
        fi
        if [[ ! ${PUBLIC_IPV4_OVERRIDE+x} ]]; then
            PUBLIC_IPV4_OVERRIDE=""
            need_save=true
        elif [[ -n "${PUBLIC_IPV4_OVERRIDE:-}" ]]; then
            if ! is_valid_public_ipv4_for_link "$PUBLIC_IPV4_OVERRIDE"; then
                warn "已保存的直连公网 IPv4 覆盖无效，已清除。"
                PUBLIC_IPV4_OVERRIDE=""
                reset_public_ip_cache
                need_save=true
            fi
        fi
        if [[ -z "${SUB_TOKEN:-}" ]]; then
            SUB_TOKEN=$(random_hex 16)
            need_save=true
        fi
        if [[ -z "${SUBSCRIPTION_PORT:-}" ]]; then
            SUBSCRIPTION_PORT=24630
            need_save=true
        fi
        if [[ "${NAT_MODE:-}" != "true" && "${NAT_MODE:-}" != "false" ]]; then
            NAT_MODE="false"
            need_save=true
        fi
        if ! validate_port "${REALITY_PUBLIC_PORT:-}" "NAT Reality 公网映射" >/dev/null 2>&1; then
            REALITY_PUBLIC_PORT="${REALITY_PORT}"
            need_save=true
        fi
        if ! validate_port "${SOCKS_PUBLIC_PORT:-}" "NAT SOCKS5 公网映射" >/dev/null 2>&1; then
            SOCKS_PUBLIC_PORT="${SOCKS_PORT}"
            need_save=true
        fi
        if ! is_valid_outbound_ip_strategy "${OUTBOUND_IP_STRATEGY:-}"; then
            OUTBOUND_IP_STRATEGY="default"
            need_save=true
        fi
        [[ "$need_save" == "true" && "$persist" == true ]] && save_params
        return 0
    fi
    return 1
}

clear_argo_best_cf_cache() {
    ARGO_BEST_CF_DOMAIN=""
    ARGO_BEST_CF_DOMAIN_IPV4=""
    ARGO_BEST_CF_DOMAIN_IPV6=""
    ARGO_CF_CACHE_DOMAIN=""
    ARGO_CF_CACHE_VERSION=""
}

restore_runtime_params() {
    UUID="$1"
    SHORT_ID="$2"
    PRIVATE_KEY="$3"
    PUBLIC_KEY="$4"
    REALITY_PORT="$5"
    REALITY_SNI="$6"
    WS_PORT="$7"
    WS_PATH="$8"
    NODE_NAME="$9"
    HY2_PORT="${10}"
    HY2_PASSWORD="${11}"
    HY2_SNI="${12}"
    HY2_MASQUERADE_URL="${13:-${HY2_DEFAULT_MASQUERADE_URL}}"
    SUBSCRIPTION_PORT="${14}"
    ARGO_DOMAIN="${15}"
    ARGO_TOKEN="${16}"
    ARGO_BEST_CF_DOMAIN="${17}"
    ARGO_BEST_CF_DOMAIN_IPV4="${18}"
    ARGO_BEST_CF_DOMAIN_IPV6="${19}"
    LINK_IPV4_SELECTION="${20:-all}"
    PUBLIC_IPV4_OVERRIDE="${21:-}"
    NAT_MODE="${22:-false}"
    REALITY_PUBLIC_PORT="${23:-${REALITY_PORT}}"
    ARGO_ENABLED="${24:-false}"
    HY2_ENABLED="${25:-false}"
    SOCKS_PORT="${26:-}"
    SOCKS_USERNAME="${27:-}"
    SOCKS_PASSWORD="${28:-}"
    SOCKS_ENABLED="${29:-false}"
    SOCKS_PUBLIC_PORT="${30:-${SOCKS_PORT}}"
    OUTBOUND_IP_STRATEGY="${31:-default}"
    REALITY_SNI_CUSTOM="${32:-}"
    reset_public_ip_cache
}
# 活动内核只读解析；结构化服务/状态检查由内嵌 Python 标准库实现。
SBM_ENGINE_ROOT="/usr/local/libexec/sbm/sing-box"
SBM_STATE_DIR="/var/lib/sbm"
SBM_LOCK_FILE="/run/sbm/maintenance.lock"
SBM_ENGINE_DROPIN="/etc/systemd/system/sing-box.service.d/50-sbm-engine.conf"
# Read as literal capability declarations by manager_script_valid.
# shellcheck disable=SC2034
SBM_STATE_SCHEMA_MIN=1
# shellcheck disable=SC2034
SBM_STATE_SCHEMA_MAX=1
# shellcheck disable=SC2034
SBM_PENDING_RECOVERY=1

engine_python() {
    command -v python3 >/dev/null 2>&1 || return 2
    SBM_INHERITED_LOCK_FD="${SBM_LOCK_FD:-}" python3 - "$SBM_ENGINE_ROOT" "$SBM_STATE_DIR" "$CONFIG_FILE" "$PARAMS_FILE" \
        "$SINGBOX_OPENRC_SERVICE" "$SBM_ENGINE_DROPIN" "$SBM_LOCK_FILE" "$@" <<'SBM_ENGINE_PY'
"""Embedded sbm engine manager. Standard library only; never evaluates shell data."""
import contextlib
import hashlib
import ipaddress
import json
import os
import pathlib
import re
import shlex
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.parse
import urllib.request
from dataclasses import dataclass, field

IO_DEADLINE = None


def io_budget():
    if IO_DEADLINE is not None and time.monotonic() >= IO_DEADLINE:
        raise EngineError("检查未完成：已达到总时限", 2)


class EngineError(Exception):
    def __init__(self, message, code=1):
        super().__init__(message)
        self.code = code


def require(condition, message):
    if not condition:
        raise EngineError(message)


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            io_budget()
            h.update(block)
    return h.hexdigest()


def trusted(path):
    """Existing file and ancestors must be root-owned and not replaceable by others."""
    path = pathlib.Path(path)
    require(path.resolve() == path, "可信文件或目录不能通过未知符号链接替换")
    for item in (path, *path.parents):
        value = item.stat()
        require(value.st_uid == 0, "文件来源或目录权限不可信")
        writable = value.st_mode & 0o022
        sticky_parent = item != path and str(item) in ("/tmp", "/var/tmp") and value.st_mode & stat.S_ISVTX
        require(not writable or sticky_parent, "文件来源或目录权限不可信")
    return path


def trusted_system_file(path):
    """Accept the standard merged-/usr alias only after checking its owner and target."""
    path = pathlib.Path(path)
    if path.resolve() == path:
        return trusted(path)
    legacy = pathlib.Path("/lib")
    require(legacy.is_symlink() and os.lstat(legacy).st_uid == 0, "系统服务路径链接不可信")
    try:
        relative = path.relative_to(legacy)
    except ValueError:
        raise EngineError("系统服务路径链接不受支持") from None
    target = pathlib.Path("/usr/lib") / relative
    require(legacy.resolve() == pathlib.Path("/usr/lib") and path.resolve() == target,
            "系统服务路径链接不受支持")
    trusted(legacy.parent)
    return trusted(target)


def atomic_bytes(path, data, mode=0o600):
    path = pathlib.Path(path)
    require(not path.is_symlink(), "拒绝替换未知符号链接")
    fd, temporary = tempfile.mkstemp(prefix=".sbm-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as handle:
            os.fchmod(handle.fileno(), mode)
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        directory = os.open(str(path.parent), os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.lexists(temporary):
            os.unlink(temporary)


def atomic_json(path, data):
    atomic_bytes(path, (json.dumps(data, sort_keys=True) + "\n").encode())


def load_json(path):
    path = pathlib.Path(path)
    require(path.is_file() and not path.is_symlink(), "状态或配置不是普通文件")
    require(path.stat().st_size <= 4 * 1024 * 1024, "状态或配置文件过大")
    with open(path, encoding="utf-8") as handle:
        content = handle.read(4 * 1024 * 1024 + 1)
    io_budget()
    require(len(content.encode("utf-8")) <= 4 * 1024 * 1024, "状态或配置文件过大")
    return json.loads(content)


def safe_path(value):
    require(isinstance(value, str) and re.fullmatch(r"/[A-Za-z0-9_./+-]*", value), "不支持的路径或启动参数")
    require(".." not in pathlib.PurePosixPath(value).parts, "路径包含越界部分")
    return pathlib.Path(value)


def params_read(path):
    values = {}
    if not path.is_file():
        return values
    require(not path.is_symlink(), "参数文件不是普通文件")
    require(path.stat().st_size <= 1024 * 1024, "参数文件过大")
    with path.open(encoding="utf-8") as handle:
        content = handle.read(1024 * 1024 + 1)
    require(len(content.encode("utf-8")) <= 1024 * 1024, "参数文件过大")
    for line in content.splitlines():
        io_budget()
        match = re.fullmatch(r'([A-Z][A-Z0-9_]*)="((?:[^"\\]|\\[\\"])*)"', line)
        if match:
            values[match[1]] = re.sub(r'\\([\\"])', r'\1', match[2])
    return values


@dataclass
class Paths:
    engines: pathlib.Path
    state: pathlib.Path
    config: pathlib.Path
    params: pathlib.Path
    openrc: pathlib.Path
    dropin: pathlib.Path
    lock: pathlib.Path = pathlib.Path("/run/sbm/maintenance.lock")

    @property
    def manifest(self):
        return self.state / "engine.json"

    @property
    def pending(self):
        return self.state / "pending.json"

    @property
    def current(self):
        return self.engines / "current"


class Host:
    def __init__(self, deadline=None):
        self.deadline = deadline

    def run(self, argv, seconds=5, cwd=None, check=True):
        if self.deadline is not None:
            seconds = min(seconds, self.deadline - time.monotonic())
        if seconds <= 0:
            raise EngineError("检查未完成：已达到总时限", 2)
        try:
            result = subprocess.run(argv, cwd=cwd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, timeout=seconds, text=True,
                                    encoding="utf-8", errors="replace")
        except (OSError, subprocess.TimeoutExpired):
            raise EngineError("命令不可用或超时", 2) from None
        if check and result.returncode:
            program = pathlib.Path(str(argv[0])).name
            if program not in ("systemctl", "rc-service", "rc-update", "runuser", "ss", "openssl"):
                program = "核心"
            raise EngineError(program + " 查询或操作失败（退出码 " + str(result.returncode) + "）")
        return result

    def manager(self):
        if shutil.which("systemctl"):
            if self.run(["systemctl", "show", "--property=Version", "--value"], check=False).returncode == 0:
                return "systemd"
        if shutil.which("rc-service"):
            return "openrc"
        return "none"

    def pid(self, manager):
        if manager == "systemd":
            text = self.run(["systemctl", "show", "sing-box", "--property=MainPID", "--value"]).stdout.strip()
        else:
            child = pathlib.Path("/run/openrc/options/sing-box/child_pid")
            pidfile = pathlib.Path("/run/sing-box.pid")
            text = (child if child.exists() else pidfile).read_text().strip()
        require(re.fullmatch(r"[1-9][0-9]*", text), "无法确认实际核心进程")
        return int(text)

    def active(self, manager):
        if manager == "systemd":
            return self.run(["systemctl", "is-active", "--quiet", "sing-box"], check=False).returncode == 0
        if manager == "openrc":
            return self.run(["rc-service", "sing-box", "status"], check=False).returncode == 0
        return False

    def enabled(self, manager):
        if manager == "systemd":
            value = self.run(["systemctl", "is-enabled", "sing-box"], check=False).stdout.strip()
            require(value in ("enabled", "disabled"), "不支持的服务自启状态")
            return value == "enabled"
        output = self.run(["rc-update", "show", "default"]).stdout
        return bool(re.search(r"^\s*sing-box\s*\|", output, re.M))

    def restart(self, manager):
        if manager == "systemd":
            self.run(["systemctl", "restart", "sing-box"], seconds=30)
        else:
            result = self.run(["rc-service", "sing-box", "status"], check=False)
            if result.returncode in (32, 64):
                # A live old PID must never be hidden by zap.
                try:
                    os.kill(self.pid(manager), 0)
                except (ProcessLookupError, FileNotFoundError, EngineError):
                    self.run(["rc-service", "sing-box", "zap"], seconds=10)
                else:
                    raise EngineError("OpenRC 状态异常且仍有存活进程")
            self.run(["rc-service", "sing-box", "restart"], seconds=30)

    def stop(self, manager):
        self.run(["systemctl", "stop", "sing-box"] if manager == "systemd" else
                 ["rc-service", "sing-box", "stop"], seconds=30)

    def reload(self, manager):
        if manager == "systemd":
            self.run(["systemctl", "daemon-reload"], seconds=10)


@dataclass
class Contract:
    manager: str
    binary: pathlib.Path
    argv: list
    workdir: pathlib.Path
    files: list
    service_files: list
    user: str = "root"
    group: str = ""
    running: bool = False
    enabled: bool = False
    signature: str = ""
    config_hash: str = ""
    inbounds: list = field(default_factory=list)

    def fingerprint(self, paths):
        values = []
        require(len(set(paths)) <= 128, "配置材料过多")
        total = 0
        for path in sorted(set(paths)):
            io_budget()
            require(path.is_file() and not path.is_symlink(), "配置材料缺失或是未知链接")
            meta = path.stat()
            require(meta.st_size <= 64 * 1024 * 1024, "配置材料过大")
            total += meta.st_size
            require(total <= 128 * 1024 * 1024, "配置材料总量过大")
            values.append((str(path), meta.st_mode, meta.st_uid, meta.st_gid, digest(path)))
        return hashlib.sha256(json.dumps(values, sort_keys=True).encode()).hexdigest()

    def config_snapshot(self):
        material = list(self.files)
        inbounds = []
        for filename in self.files:
            config = load_json(filename)
            require(isinstance(config, dict), "配置结构无效")
            require(set(config) <= {"log", "inbounds", "outbounds", "route", "dns"}, "配置包含尚未支持的扩展")
            require(isinstance(config.get("log", {}), dict) and isinstance(config.get("route", {}), dict), "配置结构无效")
            require(isinstance(config.get("inbounds", []), list) and isinstance(config.get("outbounds", []), list), "配置结构无效")
            require(set(config.get("log", {})) <= {"level", "timestamp", "disabled"}, "配置包含文件日志或未知日志设置")
            require(not config.get("route", {}).get("rule_set"), "暂不接管带规则集的配置")
            for outbound in config.get("outbounds", []):
                require(isinstance(outbound, dict), "配置结构无效")
                require(outbound.get("type") in ("direct", "block", "dns"), "暂不接管含额外代理出站的配置")
            for inbound in config.get("inbounds", []):
                require(isinstance(inbound, dict), "配置结构无效")
                require(inbound.get("type") in ("vless", "hysteria2", "socks"), "配置包含尚未支持的入站")
                require(isinstance(inbound.get("listen_port"), int) and 0 < inbound["listen_port"] <= 65535,
                        "入站端口无效")
                tls = inbound.get("tls", {})
                require(isinstance(tls, dict), "TLS 配置结构无效")
                require(not tls.get("acme"), "暂不接管自动签发证书的配置")
                for key in ("key_path", "certificate_path"):
                    if key in tls:
                        value = safe_path(tls[key])
                        material.append(value)
                inbounds.append(inbound)
        self.inbounds = inbounds
        self.config_hash = self.fingerprint(material)
        # Directory membership is part of the contract, not only current file bytes.
        self.signature = self.fingerprint(self.service_files)
        return self.config_hash

    def check_args(self):
        return ["check" if value == "run" else value for value in self.argv]


def startup_args(tokens):
    require(tokens.count("run") == 1, "不支持的服务启动方式")
    result = []
    files = []
    directories = []
    workdir = pathlib.Path("/")
    index = 0
    while index < len(tokens):
        flag = tokens[index]
        if flag == "run":
            result.append(flag)
            index += 1
            continue
        require(flag in ("-c", "--config", "-C", "--config-directory", "-D", "--directory"),
                "启动参数超出受支持范围")
        require(index + 1 < len(tokens), "服务启动参数缺失")
        value = safe_path(tokens[index + 1])
        if flag in ("-D", "--directory"):
            require(value.is_dir() and not value.is_symlink(), "工作目录不存在或不受支持")
            workdir = value
        elif flag in ("-C", "--config-directory"):
            require(value.is_dir() and not value.is_symlink(), "配置目录不存在或不受支持")
            directories.append(value)
            members = config_files(value)
            files.extend(members)
        else:
            files.append(value)
        result.extend((flag, str(value)))
        index += 2
    require(files, "服务没有明确的配置文件")
    return result, list(dict.fromkeys(files)), directories, workdir


def config_files(directory):
    members = []
    with os.scandir(directory) as entries:
        for item in entries:
            io_budget()
            if item.name.endswith(".json"):
                members.append(pathlib.Path(item.path))
                require(len(members) <= 128, "配置目录文件过多")
    return sorted(members)


def read_contract(paths, host):
    manager = host.manager()
    service_files = []
    user = "root"
    if manager == "systemd":
        properties = ("ExecStart", "ExecStartPre", "ExecStartPost", "ExecStop", "FragmentPath", "DropInPaths",
                      "User", "Group", "WorkingDirectory", "RootDirectory", "RootImage", "NoExecPaths",
                      "InaccessiblePaths", "BindPaths", "BindReadOnlyPaths", "Environment", "EnvironmentFiles",
                      "DynamicUser", "PrivateUsers", "ProtectHome", "ExecPaths", "RestrictFileSystems",
                      "AppArmorProfile", "SELinuxContext", "SupplementaryGroups", "ReadOnlyPaths", "ReadWritePaths")
        result = host.run(["systemctl", "show", "sing-box", "--no-pager"] +
                          ["--property=" + name for name in properties])
        values = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
        for name in ("ExecStartPre", "ExecStartPost", "ExecStop", "RootDirectory", "RootImage", "NoExecPaths",
                     "InaccessiblePaths", "BindPaths", "BindReadOnlyPaths", "Environment", "EnvironmentFiles",
                     "ExecPaths", "RestrictFileSystems", "AppArmorProfile", "SELinuxContext", "SupplementaryGroups",
                     "ReadOnlyPaths", "ReadWritePaths"):
            require(not values.get(name), "服务含未知启动钩子、环境或沙箱路径")
        for name in ("DynamicUser", "PrivateUsers", "ProtectHome"):
            require(values.get(name, "no") in ("", "no"), "服务执行安全策略超出支持范围")
        text = values.get("ExecStart", "")
        match = re.fullmatch(r"\{ path=(/[A-Za-z0-9_./+-]+) ; argv\[\]=([A-Za-z0-9_./+ =-]+) ; ignore_errors=no ;[^{}]*\}", text)
        require(match, "无法安全解析唯一的服务执行命令")
        binary = safe_path(match[1])
        words = match[2].split()
        require(words and words[0] == str(binary), "服务核心路径不一致")
        argv, files, directories, workdir = startup_args(words[1:])
        configured_workdir = values.get("WorkingDirectory")
        if configured_workdir:
            workdir = safe_path(configured_workdir)
            require(workdir.is_dir(), "服务工作目录不存在")
        user = values.get("User") or "root"
        group = values.get("Group") or ""
        require(re.fullmatch(r"[A-Za-z0-9_-]+", user), "服务用户无效")
        require(not group or re.fullmatch(r"[A-Za-z0-9_-]+", group), "服务组无效")
        fragment = safe_path(values.get("FragmentPath", ""))
        require(fragment.name == "sing-box.service", "未知服务单元")
        service_files.append(trusted_system_file(fragment))
        for name in values.get("DropInPaths", "").split():
            path = safe_path(name)
            path = trusted_system_file(path)
            text = path.read_text()
            require(path == paths.dropin or not re.search(r"^\s*ExecStart\s*=", text, re.M),
                    "管理员已覆盖服务执行命令，未接管")
            service_files.append(path)
    elif manager == "openrc":
        group = ""
        text = paths.openrc.read_text()
        # Shell source is never executed. Only two exact, documented templates are accepted.
        lines = [line.strip() for line in text.splitlines() if line.strip() and not line.lstrip().startswith("#")]
        definitions = {}
        for line in lines:
            if re.fullmatch(r'(name|description|command|command_args|pidfile|output_log|error_log|supervisor)="[A-Za-z0-9_./ +:-]+"', line):
                key, value = line.split("=", 1)
                require(key not in definitions, "OpenRC 字段重复")
                definitions[key] = value[1:-1]
            elif line in ("command_background=true", "respawn_delay=5", "respawn_max=5", "respawn_period=60",
                          "depend() {", "need net", "}", "depend() { need net; }"):
                continue
            else:
                raise EngineError("OpenRC 服务含未知自定义内容")
        require(definitions.get("name") == "sing-box" and definitions.get("pidfile") == "/run/sing-box.pid",
                "OpenRC 服务不是受支持模板")
        require(definitions.get("supervisor") == "supervise-daemon" or "command_background=true" in lines,
                "不支持的 OpenRC 进程方式")
        normalized = re.sub(r'^command="[A-Za-z0-9_./+-]+"$', 'command="CORE"', "\n".join(lines), flags=re.M)
        normalized = re.sub(r'^command_args="[A-Za-z0-9_./ +:-]+"$', 'command_args="ARGS"', normalized, flags=re.M)
        prefix = 'name="sing-box"\n'
        description = 'description="sing-box service"\n'
        base = 'command="CORE"\ncommand_args="ARGS"\n'
        logs = 'pidfile="/run/sing-box.pid"\noutput_log="/var/log/sing-box.log"\nerror_log="/var/log/sing-box.log"\n'
        supervised = prefix + description + base + 'supervisor="supervise-daemon"\nrespawn_delay=5\nrespawn_max=5\nrespawn_period=60\n' + logs + 'depend() {\nneed net\n}'
        legacy = prefix + base + 'command_background=true\n' + logs + 'depend() { need net; }'
        require(normalized in (supervised, legacy, prefix + description + base + 'command_background=true\n' + logs + 'depend() {\nneed net\n}'),
                "OpenRC 服务未匹配完整受支持模板")
        confd = pathlib.Path("/etc/conf.d/sing-box")
        require(not confd.exists() or not re.sub(r"(?m)^\s*#.*$", "", confd.read_text()).strip(),
                "OpenRC 存在额外覆盖配置")
        binary = safe_path(definitions.get("command", ""))
        argv, files, directories, workdir = startup_args(definitions.get("command_args", "").split())
        service_files.append(paths.openrc)
        if confd.exists():
            service_files.append(confd)
    else:
        raise EngineError("服务管理器不受支持", 2)
    require(binary.is_file() and os.access(binary, os.X_OK), "实际服务核心不存在或不可执行")
    # Package symlinks are accepted only after validating the resolved chain.
    trusted(binary.resolve())
    for filename in service_files:
        trusted(filename)
    contract = Contract(manager, binary, argv, workdir, files, service_files, user, group,
                        host.active(manager), host.enabled(manager))
    contract.directories = directories
    contract.config_snapshot()
    return contract


class EngineStore:
    def __init__(self, paths):
        self.paths = paths

    def read(self):
        require(self.paths.manifest.is_file(), "受管版本状态缺失")
        trusted(self.paths.manifest)
        data = load_json(self.paths.manifest)
        require(data.get("schema") == 1 and set(data) <= {"schema", "current", "previous", "contract", "updated"},
                "版本状态格式不受支持")
        for key in ("current", "previous"):
            record = data.get(key)
            if record:
                self.record_path(record)
        return data

    def record_path(self, record):
        require(isinstance(record, dict) and set(record) == {"version", "sha256", "path", "source", "evidence", "config_hash"},
                "版本记录无效")
        require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?", record["version"]), "版本记录无效")
        require(re.fullmatch(r"[0-9a-f]{64}", record["sha256"]), "版本摘要无效")
        require(record["evidence"] in ("static", "runtime"), "版本证据无效")
        path = self.paths.engines / (record["version"] + "-" + record["sha256"]) / "sing-box"
        require(str(path) == record["path"] and path.resolve() == path, "受管内核路径无效")
        trusted(path)
        require(path.is_file() and not path.is_symlink() and stat.S_IMODE(path.stat().st_mode) == 0o755,
                "受管内核类型或执行权限异常")
        require(digest(path) == record["sha256"], "受管内核摘要不一致")
        return path

    def resolve(self):
        require(not self.paths.pending.exists(), "存在未完成事务，请先恢复")
        data = self.read()
        current = self.record_path(data["current"])
        require(self.paths.current.is_symlink() and self.paths.current.resolve() == current,
                "受管核心入口与记录不一致")
        return current

    def save_binary(self, binary, version, source, evidence, config_hash):
        sha = digest(binary)
        directory = self.paths.engines / (version + "-" + sha)
        directory.mkdir(mode=0o755, exist_ok=True)
        trusted(directory)
        destination = directory / "sing-box"
        if not destination.exists():
            atomic_bytes(destination, pathlib.Path(binary).read_bytes(), 0o755)
        require(digest(destination) == sha, "恢复核心保存失败")
        require(destination.is_file() and not destination.is_symlink() and
                stat.S_IMODE(destination.stat().st_mode) == 0o755, "恢复核心执行权限异常")
        return dict(version=version, sha256=sha, path=str(destination), source=source,
                    evidence=evidence, config_hash=config_hash)

    def switch(self, record):
        self.record_path(record)
        temporary = self.paths.engines / (".current-" + str(os.getpid()))
        require(not os.path.lexists(temporary), "临时核心入口已存在")
        os.symlink(record["path"], temporary)
        try:
            os.replace(temporary, self.paths.current)
        finally:
            if os.path.lexists(temporary):
                temporary.unlink()

    def cleanup(self, keep, dry_run=False):
        require(not self.paths.pending.exists(), "有未完成事务，未清理版本")
        protected = {record["path"] for record in keep if record}
        candidates = []
        for directory in self.paths.engines.iterdir():
            match = re.fullmatch(r"([0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?)-([0-9a-f]{64})", directory.name)
            if not match or directory.is_symlink() or not directory.is_dir():
                continue
            binary = directory / "sing-box"
            if str(binary) in protected:
                continue
            require(list(directory.iterdir()) == [binary], "历史版本目录含未知文件，未删除")
            record = dict(version=match[1], sha256=match[2], path=str(binary), source="sbm", evidence="static", config_hash="")
            self.record_path(record)
            candidates.append((binary, directory))
        if dry_run:
            return
        for binary, directory in candidates:
            binary.unlink()
            directory.rmdir()


def binary_version(host, binary):
    binary = pathlib.Path(binary).resolve()
    trusted(binary)
    require(binary.is_file() and os.access(binary, os.X_OK), "核心不是普通可执行文件")
    with binary.open("rb") as handle:
        require(handle.read(4) == b"\x7fELF", "未执行未知的核心脚本")
    output = host.run([str(binary), "version"], seconds=8).stdout
    match = re.search(r"^sing-box version ([0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?)\s*$", output, re.M)
    require(match, "核心自报版本无效")
    return match[1]


def installation_source(host, binary):
    real = binary.resolve()
    if str(real).startswith("/usr/local/libexec/sbm/sing-box/"):
        return "sbm"
    for command, args, label in (("dpkg-query", ["-S", str(real)], "deb"),
                                 ("apk", ["info", "--who-owns", str(real)], "apk"),
                                 ("rpm", ["-qf", str(real)], "rpm")):
        if shutil.which(command) and host.run([command] + args, check=False).returncode == 0:
            return label
    require(str(real) in ("/usr/local/bin/sing-box", "/usr/bin/sing-box"), "核心来源不明，未接管")
    # A package-free release installation is allowed only in its documented location.
    require(str(real) == "/usr/local/bin/sing-box", "核心来源不明，未接管")
    return "release"

class HTTPSOnly(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        require(urllib.parse.urlsplit(newurl).scheme == "https", "下载重定向不是 HTTPS")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def fetch(url, target=None, maximum=4 * 1024 * 1024):
    require(url.startswith("https://"), "下载地址不是 HTTPS")
    opener = urllib.request.build_opener(HTTPSOnly())
    request = urllib.request.Request(url, headers={"User-Agent": "sbm-version-manager", "Accept": "application/vnd.github+json"})
    started = time.monotonic()
    try:
        with opener.open(request, timeout=15) as response:
            data = bytearray()
            with contextlib.ExitStack() as stack:
                output = stack.enter_context(open(target, "wb")) if target else None
                count = 0
                while True:
                    require(time.monotonic() - started < 90, "下载已达到总时限")
                    block = response.read(128 * 1024)
                    if not block:
                        break
                    count += len(block)
                    require(count <= maximum, "下载内容超过大小上限")
                    if output:
                        output.write(block)
                    else:
                        data.extend(block)
                return count if output else bytes(data)
    except (OSError, ValueError):
        raise EngineError("官方发布下载失败，未切换安装来源") from None


def release_asset(version, arch):
    require(not version or re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version), "仅支持明确的稳定版本号")
    suffix = "tags/v" + version if version else "latest"
    release = json.loads(fetch("https://api.github.com/repos/SagerNet/sing-box/releases/" + suffix))
    tag = release.get("tag_name", "")
    require(re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag) and
            release.get("draft") is False and release.get("prerelease") is False,
            "官方发布不是稳定版本")
    require(not version or tag == "v" + version, "官方版本与请求不一致")
    version = tag[1:]
    name = "sing-box-" + version + "-linux-" + arch + "-musl.tar.gz"
    assets = [item for item in release.get("assets", []) if item.get("name") == name]
    require(len(assets) == 1, "官方架构资产缺失或不唯一")
    asset = assets[0]
    expected_url = "https://github.com/SagerNet/sing-box/releases/download/" + tag + "/" + name
    require(asset.get("browser_download_url") == expected_url and asset.get("state") == "uploaded" and
            isinstance(asset.get("size"), int) and 0 < asset["size"] <= 128 * 1024 * 1024,
            "官方资产元信息无效")
    checksum = asset.get("digest") or ""
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", checksum):
        sums = [item for item in release.get("assets", [])
                if item.get("name") in ("sing-box-" + version + "-checksums.txt", "checksums.txt", "SHA256SUMS")]
        require(len(sums) == 1, "官方 SHA256 缺失，更新已停止")
        url = sums[0].get("browser_download_url", "")
        require(url == "https://github.com/SagerNet/sing-box/releases/download/" + tag + "/" + sums[0]["name"],
                "官方校验地址无效")
        matches = []
        for line in fetch(url).decode("utf-8").splitlines():
            match = re.fullmatch(r"([0-9a-f]{64})\s+\*?" + re.escape(name), line)
            if match:
                matches.append(match[1])
        require(len(matches) == 1, "官方校验文件中缺少唯一资产摘要")
        checksum = "sha256:" + matches[0]
    return dict(version=version, name=name, url=expected_url, size=asset["size"], sha256=checksum[7:])


def unpack_candidate(archive, destination, asset, arch):
    require(digest(archive) == asset["sha256"], "安装包 SHA256 不一致")
    expected = asset["name"][:-7] + "/sing-box"
    with tarfile.open(archive, "r:gz") as handle:
        members = handle.getmembers()
        require(len(members) <= 100, "归档成员过多")
        for item in members:
            path = pathlib.PurePosixPath(item.name)
            require(not path.is_absolute() and ".." not in path.parts and (item.isfile() or item.isdir()),
                    "归档含越界路径、链接或特殊文件")
        binary = [item for item in members if item.name == expected and item.isfile()]
        require(len(binary) == 1 and 0 < binary[0].size <= 256 * 1024 * 1024, "归档核心成员无效")
        with handle.extractfile(binary[0]) as source:
            atomic_bytes(destination, source.read(), 0o755)
    header = destination.read_bytes()[:20]
    require(len(header) == 20 and header[:4] == b"\x7fELF" and header[5] in (1, 2), "候选不是有效 ELF 核心")
    machine = int.from_bytes(header[18:20], "little" if header[5] == 1 else "big")
    require(machine == {"amd64": 62, "arm64": 183, "armv7": 40, "386": 3}[arch], "候选架构不符")


def read_process(pid):
    directory = pathlib.Path("/proc") / str(pid)
    first = (directory / "stat").read_text().rsplit(") ", 1)[1].split()
    require(first[0] not in ("Z", "X"), "核心进程已经退出")
    binary_hash = digest(directory / "exe")
    argv = [value.decode("utf-8") for value in (directory / "cmdline").read_bytes().split(b"\0") if value]
    second = (directory / "stat").read_text().rsplit(") ", 1)[1].split()
    require(first[19] == second[19], "进程在检查期间变化")
    return binary_hash, argv


def port_owned(host, pid, port, udp=False):
    output = host.run(["ss", "-H", "-l", "-u" if udp else "-t", "-n", "-p"]).stdout
    for line in output.splitlines():
        fields = line.split()
        if len(fields) >= 5 and fields[3].rsplit(":", 1)[-1] == str(port) and ("pid=" + str(pid) + ",") in line:
            return True
    return False


def local_challenge(host, binary, inbound, directory):
    """Run an isolated local origin and authenticated client after readiness checks."""
    import http.server
    import secrets
    import threading
    nonce = secrets.token_hex(24).encode()

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(nonce)

        def log_message(self, *args):
            pass

    origin = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=origin.serve_forever, daemon=True)
    thread.start()
    probe = socket.socket()
    probe.bind(("127.0.0.1", 0))
    client_port = probe.getsockname()[1]
    probe.close()
    protocol = inbound["type"]
    user = inbound.get("users", [{}])[0]
    listen = inbound.get("listen", "::")
    require(listen in ("::", "0.0.0.0", "127.0.0.1"), "本机认证暂不支持此监听地址")
    outbound = dict(type=protocol, server="127.0.0.1", server_port=inbound["listen_port"], tag="test-out")
    if protocol == "socks":
        require(user.get("username") and user.get("password"), "SOCKS 认证资料缺失")
        outbound.update(version="5", username=user["username"], password=user["password"])
    else:
        require(user.get("password"), "Hysteria2 认证资料缺失")
        outbound.update(password=user["password"], up_mbps=100, down_mbps=100,
                        tls=dict(enabled=True, insecure=True, server_name=inbound.get("tls", {}).get("server_name", "localhost")))
    client = dict(log=dict(level="error"), inbounds=[dict(type="socks", listen="127.0.0.1", listen_port=client_port)],
                  outbounds=[outbound])
    filename = directory / "client.json"
    atomic_json(filename, client)
    process = None
    try:
        host.run([str(binary), "check", "-c", str(filename)], seconds=8)
        process = subprocess.Popen([str(binary), "run", "-c", str(filename)], stdin=subprocess.DEVNULL,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = min(time.monotonic() + 15, host.deadline or float("inf"))
        ready = False
        while time.monotonic() < deadline:
            require(process.poll() is None, "临时认证客户端提前退出")
            try:
                with socket.create_connection(("127.0.0.1", client_port), timeout=0.2):
                    ready = True
                    break
            except OSError:
                time.sleep(0.1)
        require(ready, "临时认证客户端未就绪")
        require(shutil.which("curl"), "缺少本机认证依赖 curl")
        while time.monotonic() < deadline:
            result = host.run(["curl", "--noproxy", "", "--proxy", "socks5h://127.0.0.1:" + str(client_port),
                               "-fsS", "--connect-timeout", "1", "--max-time", "3",
                               "http://127.0.0.1:" + str(origin.server_port) + "/"], seconds=4, check=False)
            if result.returncode == 0 and result.stdout.encode() == nonce:
                return
            time.sleep(0.2)
        raise EngineError("本机认证或数据转发未通过（已等待客户端就绪）")
    finally:
        if process:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)
        origin.shutdown()
        origin.server_close()
        filename.unlink(missing_ok=True)


def runtime_health(host, contract, binary, directory):
    previous_deadline = host.deadline
    host.deadline = min(previous_deadline or float("inf"), time.monotonic() + 60)
    try:
        require(shutil.which("ss"), "缺少 ss，无法核对监听归属")
        expected = digest(binary)
        ready = False
        while time.monotonic() < host.deadline:
            try:
                require(host.active(contract.manager), "服务未正常运行")
                pid = host.pid(contract.manager)
                actual, arguments = read_process(pid)
                ready = actual == expected and arguments[1:] == contract.argv and all(
                    port_owned(host, pid, inbound["listen_port"], inbound["type"] == "hysteria2")
                    for inbound in contract.inbounds)
                if ready:
                    break
            except (EngineError, OSError):
                pass
            time.sleep(0.1)
        require(ready, "服务核心或监听未在时限内就绪")
        for _ in range(2):
            require(host.active(contract.manager), "服务未正常运行")
            pid = host.pid(contract.manager)
            actual, arguments = read_process(pid)
            require(actual == expected and arguments[1:] == contract.argv, "实际运行核心或参数与目标不一致")
            for inbound in contract.inbounds:
                require(port_owned(host, pid, inbound["listen_port"], inbound["type"] == "hysteria2"),
                        "预期监听未归属于实际核心进程")
            time.sleep(0.2)
        for inbound in contract.inbounds:
            if inbound["type"] in ("socks", "hysteria2"):
                local_challenge(host, binary, inbound, directory)
    finally:
        host.deadline = previous_deadline


def contract_guard(contract, ignore=None):
    # Include config directory membership so added files cannot evade drift detection.
    members = [(str(directory), [str(item) for item in config_files(directory)])
               for directory in contract.directories]
    services = [item for item in contract.service_files if item != ignore]
    dropins = systemd_dropin_inventory(ignore) if contract.manager == "systemd" else []
    value = dict(config=contract.config_snapshot(), members=members, services=contract.fingerprint(services), dropins=dropins,
                 argv=contract.argv, user=contract.user, group=contract.group, workdir=str(contract.workdir))
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


SYSTEMD_UNIT_PATHS = tuple(pathlib.Path(path) for path in (
    "/etc/systemd/system.control", "/run/systemd/system.control", "/run/systemd/transient",
    "/run/systemd/generator.early", "/etc/systemd/system", "/etc/systemd/system.attached",
    "/run/systemd/system", "/run/systemd/system.attached", "/run/systemd/generator",
    "/usr/local/lib/systemd/system", "/usr/lib/systemd/system", "/lib/systemd/system",
    "/run/systemd/generator.late"))


def systemd_dropin_inventory(ignore):
    """Track on-disk drop-ins too, including changes not yet loaded by systemd."""
    entries = []
    for root in SYSTEMD_UNIT_PATHS:
        for suffix in ("service.d", "sing-.service.d", "sing-box.service.d"):
            directory = root / suffix
            if not directory.is_dir():
                continue
            for item in directory.iterdir():
                io_budget()
                if item.suffix != ".conf" or item == ignore:
                    continue
                require(len(entries) < 128, "systemd 覆盖配置过多")
                path = trusted_system_file(item)
                require(path.is_file() and not path.is_symlink(), "systemd 覆盖配置不是普通文件")
                meta = path.stat()
                require(meta.st_size <= 4 * 1024 * 1024, "systemd 覆盖配置过大")
                entries.append((str(item), str(path), meta.st_mode, meta.st_uid, meta.st_gid, digest(path)))
    return sorted(entries)


class Upgrade:
    def __init__(self, paths, host):
        self.paths = paths
        self.host = host
        self.store = EngineStore(paths)

    def prepare_storage(self):
        require(os.geteuid() == 0, "版本操作需要 root 权限")
        self.paths.engines.mkdir(parents=True, mode=0o755, exist_ok=True)
        self.paths.state.mkdir(parents=True, mode=0o700, exist_ok=True)
        trusted(self.paths.engines)
        trusted(self.paths.state)
        require(self.paths.state.stat().st_mode & 0o077 == 0, "版本状态目录应仅 root 可访问")
        require(shutil.disk_usage(self.paths.engines).free > 512 * 1024 * 1024,
                "磁盘空间不足，未开始版本切换")
        require(not os.statvfs(self.paths.engines).f_flag & getattr(os, "ST_NOEXEC", 8),
                "版本目录所在文件系统禁止执行")

    def check(self, binary, contract):
        command = [str(binary)] + contract.check_args()
        if contract.user != "root" or contract.group:
            require(shutil.which("runuser"), "无法按实际服务用户检查候选")
            command = ["runuser", "-u", contract.user] + (["-g", contract.group] if contract.group else []) + ["--"] + command
        self.host.run(command, seconds=15, cwd=str(contract.workdir))

    def entry_path(self, contract):
        return self.paths.dropin if contract.manager == "systemd" else self.paths.openrc

    def entry_data(self, contract):
        if contract.manager == "systemd":
            arguments = " ".join(contract.argv)
            return ("# Managed by sbm: engine schema 1\n[Service]\nExecStart=\nExecStart=" +
                    str(self.paths.current) + " " + arguments + "\n").encode()
        original = self.paths.openrc.read_text()
        updated, count = re.subn(r'^command="[A-Za-z0-9_./+-]+"$', 'command="' + str(self.paths.current) + '"', original, flags=re.M)
        require(count == 1, "OpenRC 核心入口不唯一")
        return updated.encode()

    def snapshot(self, contract, old_record, old_state):
        import base64
        entry = self.entry_path(contract)
        require(not entry.is_symlink(), "服务入口是未知链接")
        prior = None
        if entry.exists():
            prior = dict(data=base64.b64encode(entry.read_bytes()).decode(), mode=stat.S_IMODE(entry.stat().st_mode),
                         uid=entry.stat().st_uid, gid=entry.stat().st_gid)
        current = os.readlink(self.paths.current) if self.paths.current.is_symlink() else None
        require(current is not None or not os.path.lexists(self.paths.current), "活动入口不是符号链接")
        require(digest(contract.binary) == old_record["sha256"], "原核心在检查期间发生变化")
        return dict(schema=1, manager=contract.manager, old=old_record, target=None, manifest=old_state, entry=prior,
                    original_binary=str(contract.binary.resolve()), original_sha256=old_record["sha256"],
                    current=current, running=contract.running, enabled=contract.enabled,
                    argv=contract.argv, workdir=str(contract.workdir), user=contract.user, group=contract.group,
                    files=[str(item) for item in contract.files], directories=[str(item) for item in contract.directories],
                    service_files=[str(item) for item in contract.service_files],
                    guard=contract_guard(contract, entry), new_entry=base64.b64encode(self.entry_data(contract)).decode(),
                    phase="prepared")

    def restore(self):
        import base64
        trusted(self.paths.pending)
        saved = load_json(self.paths.pending)
        require(saved.get("schema") == 1 and saved.get("manager") in ("systemd", "openrc"), "恢复事务格式无效")
        required = {"schema", "manager", "old", "target", "manifest", "entry", "original_binary", "original_sha256", "current",
                    "running", "enabled", "argv", "workdir", "user", "group", "files", "directories", "service_files",
                    "guard", "new_entry", "phase"}
        require(set(saved) == required and type(saved["running"]) is bool and type(saved["enabled"]) is bool and
                saved["phase"] in ("prepared", "switched"), "恢复事务字段无效")
        require(isinstance(saved["argv"], list) and all(isinstance(item, str) for item in saved["argv"]), "恢复参数无效")
        startup_args(saved["argv"])
        require(re.fullmatch(r"[A-Za-z0-9_-]+", saved["user"]) and
                (not saved["group"] or re.fullmatch(r"[A-Za-z0-9_-]+", saved["group"])), "恢复服务用户无效")
        for key in ("original_sha256", "guard"):
            require(isinstance(saved[key], str) and re.fullmatch(r"[0-9a-f]{64}", saved[key]), "恢复摘要无效")
        for key in ("files", "directories", "service_files"):
            require(isinstance(saved[key], list) and len(saved[key]) <= 128 and all(isinstance(item, str) for item in saved[key]),
                    "恢复材料清单无效")
            for item in saved[key]:
                safe_path(item)
        require(isinstance(saved["new_entry"], str) and len(saved["new_entry"]) <= 65536, "恢复入口过大")
        if saved["entry"]:
            require(set(saved["entry"]) == {"data", "mode", "uid", "gid"} and
                    isinstance(saved["entry"]["data"], str) and len(saved["entry"]["data"]) <= 65536 and
                    type(saved["entry"]["mode"]) is int and 0 <= saved["entry"]["mode"] <= 0o777 and
                    saved["entry"]["uid"] == 0 and type(saved["entry"]["gid"]) is int and saved["entry"]["gid"] >= 0,
                    "恢复入口权限或内容无效")
        require(saved["current"] is None or saved["manifest"] is not None and
                saved["current"] == saved["manifest"]["current"]["path"], "恢复活动入口无效")
        if saved["target"]:
            self.store.record_path(saved["target"])
        current_value = os.readlink(self.paths.current) if self.paths.current.is_symlink() else None
        require(not os.path.lexists(self.paths.current) or self.paths.current.is_symlink(), "活动入口被外部替换")
        allowed = {saved["current"], saved["target"]["path"] if saved["target"] else None}
        require(current_value in allowed, "活动入口被外部修改，保留恢复材料")
        binary = self.store.record_path(saved["old"])
        if saved["manifest"] is None:
            original_binary = safe_path(saved["original_binary"])
            trusted(original_binary)
            require(digest(original_binary) == saved["original_sha256"], "原软件包核心被外部修改，保留恢复材料，未重启")
        contract = Contract(saved["manager"], binary, saved["argv"], safe_path(saved["workdir"]),
                            [safe_path(item) for item in saved["files"]],
                            [safe_path(item) for item in saved["service_files"]], saved["user"], saved["group"],
                            saved["running"], saved["enabled"])
        contract.directories = [safe_path(item) for item in saved["directories"]]
        entry = self.entry_path(contract)
        require(contract_guard(contract, entry) == saved["guard"], "配置或其他服务文件已变化，保留恢复材料，请手动检查")
        live = read_contract(self.paths, self.host)
        require(contract_guard(live, entry) == saved["guard"], "实际服务契约已变化，保留恢复材料")
        allowed_binaries = {saved["original_binary"], saved["old"]["path"]}
        if saved["target"]:
            allowed_binaries.add(saved["target"]["path"])
        require(str(live.binary.resolve()) in allowed_binaries, "实际服务核心已变化，保留恢复材料")
        expected = base64.b64decode(saved["new_entry"], validate=True)
        original = saved["entry"]
        previous = base64.b64decode(original["data"], validate=True) if original else None
        require(not entry.is_symlink(), "服务入口出现未知链接，未覆盖")
        if entry.exists():
            require(entry.read_bytes() in (expected, previous), "服务入口被外部修改，未覆盖")
        self.host.deadline = time.monotonic() + 60
        try:
            self.check(binary, contract)
            if original:
                atomic_bytes(entry, previous, original["mode"])
                os.chown(entry, original["uid"], original["gid"])
            elif entry.exists():
                entry.unlink()
            if saved["current"] is None:
                if self.paths.current.is_symlink():
                    self.paths.current.unlink()
            else:
                self.store.switch(saved["manifest"]["current"])
            if saved["manifest"] is None:
                if self.paths.manifest.exists():
                    self.paths.manifest.unlink()
            else:
                atomic_json(self.paths.manifest, saved["manifest"])
            self.host.reload(contract.manager)
            require(self.host.enabled(contract.manager) == contract.enabled, "服务自启状态被外部修改")
            if contract.running:
                self.host.restart(contract.manager)
                with tempfile.TemporaryDirectory(prefix="restore-", dir=self.paths.state) as temporary:
                    runtime_health(self.host, contract, binary, pathlib.Path(temporary))
            elif self.host.active(contract.manager):
                self.host.stop(contract.manager)
            self.paths.pending.unlink()
            print("已恢复操作前的核心、服务入口与运行状态；当前配置保持不变。")
        finally:
            self.host.deadline = None

    def execute(self, version="", rollback=False):
        require(not self.paths.pending.exists(), "存在未完成事务，请先执行回退恢复")
        contract = read_contract(self.paths, self.host)
        old_state = self.store.read() if self.paths.manifest.exists() else None
        if old_state:
            require(self.store.resolve().resolve() == contract.binary.resolve(), "服务与受管入口不一致")
            require(rollback or old_state["current"]["evidence"] == "runtime", "当前版本运行未验证，请先启动验证或回退")
            require(contract_guard(contract, self.entry_path(contract)) == old_state["contract"], "服务或配置契约已变化，请先检查")
        require(not self.paths.current.exists() or old_state is not None, "活动入口缺少对应受管状态")
        source = "sbm" if old_state else installation_source(self.host, contract.binary)
        old_version = binary_version(self.host, contract.binary)
        original_sha256 = digest(contract.binary)
        before = contract_guard(contract, self.entry_path(contract))
        if not rollback:
            self.check(contract.binary, contract)
        require(contract_guard(contract, self.entry_path(contract)) == before, "配置在原版本检查期间变化")
        self.prepare_storage()
        with tempfile.TemporaryDirectory(prefix="upgrade-", dir=self.paths.state) as temporary:
            work = pathlib.Path(temporary)
            if contract.running and not rollback:
                runtime_health(self.host, contract, contract.binary, work)
            old_record = self.store.save_binary(contract.binary, old_version, source,
                                               "static" if rollback else "runtime" if contract.running else "static", contract.config_hash)
            if rollback:
                require(old_state and old_state.get("previous"), "没有可回退的上一版本")
                target = old_state["previous"].copy()
                candidate = self.store.record_path(target)
            else:
                arch = {"x86_64": "amd64", "aarch64": "arm64", "armv7l": "armv7", "i386": "386", "i686": "386"}.get(os.uname().machine)
                require(arch, "架构不受支持")
                asset = release_asset(version, arch)
                require(tuple(map(int, asset["version"].split("."))) > tuple(map(int, old_version.split("-")[0].split("."))),
                        "目标版本不高于当前版本；降级请使用上一版本回退")
                archive = work / "core.tar.gz"
                count = fetch(asset["url"], archive, maximum=asset["size"])
                require(count == asset["size"], "下载大小与官方资产不一致")
                candidate = work / "sing-box"
                unpack_candidate(archive, candidate, asset, arch)
                require(binary_version(self.host, candidate) == asset["version"], "候选自报版本与官方发布不一致")
                target = self.store.save_binary(candidate, asset["version"], "official", "static", contract.config_hash)
                candidate = pathlib.Path(target["path"])
            require(contract_guard(contract, self.entry_path(contract)) == before, "配置在下载期间变化，未切换")
            require(digest(contract.binary) == original_sha256, "原核心在下载期间被外部修改，未切换")
            self.check(candidate, contract)
            require(contract_guard(contract, self.entry_path(contract)) == before, "配置在候选检查期间变化")
            # Snapshot after all non-mutating validation; records absence as well as bytes.
            saved = self.snapshot(contract, old_record, old_state)
            saved["target"] = target
            atomic_json(self.paths.pending, saved)
            try:
                require(contract_guard(contract, self.entry_path(contract)) == before, "配置在切换前发生变化")
                require(digest(contract.binary) == original_sha256, "原核心在切换前被外部修改")
                self.host.deadline = time.monotonic() + 60
                self.store.switch(target)
                saved["phase"] = "switched"
                atomic_json(self.paths.pending, saved)
                entry = self.entry_path(contract)
                entry.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
                import base64
                atomic_bytes(entry, base64.b64decode(saved["new_entry"]), 0o644 if contract.manager == "systemd" else 0o755)
                self.host.reload(contract.manager)
                changed = read_contract(self.paths, self.host)
                require(changed.binary == self.paths.current and changed.argv == contract.argv, "生效服务入口与预期不一致")
                require(self.host.enabled(contract.manager) == contract.enabled, "服务自启状态发生变化")
                if contract.running:
                    self.host.restart(contract.manager)
                    runtime_health(self.host, changed, candidate, work)
                    target["evidence"] = "runtime"
                else:
                    require(not self.host.active(contract.manager), "原停止服务被意外启动")
                    target["evidence"] = "static"
                target["config_hash"] = changed.config_hash
                require(contract_guard(changed, entry) == before, "配置或服务在验证期间发生变化")
                # A failing version being rolled back is not promoted into a healthy recovery point.
                prior = None if rollback else old_record
                data = dict(schema=1, current=target, previous=prior, contract=before, updated=int(time.time()))
                atomic_json(self.paths.manifest, data)
                self.paths.pending.unlink()
                self.host.deadline = None
            except BaseException:
                try:
                    self.restore()
                except EngineError as recovery_error:
                    print("恢复未完成（" + str(recovery_error) + "），已保留恢复材料；请执行 sbm doctor 检查，再执行回退。", file=sys.stderr)
                except (OSError, ValueError):
                    print("恢复未完成，已保留恢复材料；请执行 sbm doctor 检查，再执行回退。", file=sys.stderr)
                raise
            try:
                self.store.cleanup((target, prior))
            except (EngineError, OSError):
                print("[WARN] 历史版本清理未完成，当前版本已保留。", file=sys.stderr)
            print("核心版本已切换到 " + target["version"] + ("，运行验证通过，公网未验证。" if contract.running else "，配置已验证，服务保持停止，运行未验证。"))

    def validate_start(self, allow_stopped=False):
        if not self.paths.manifest.exists():
            return
        require(not self.paths.pending.exists(), "存在未完成版本事务")
        data = self.store.read()
        contract = read_contract(self.paths, self.host)
        binary = self.store.resolve()
        require(contract.binary == self.paths.current and contract.binary.resolve() == binary,
                "服务入口与受管核心不一致")
        self.check(binary, contract)
        if contract.running:
            with tempfile.TemporaryDirectory(prefix="validate-", dir=self.paths.state) as temporary:
                runtime_health(self.host, contract, binary, pathlib.Path(temporary))
            data["current"]["evidence"] = "runtime"
        else:
            require(allow_stopped, "核心当前未运行")
            data["current"]["evidence"] = "static"
        data["current"]["config_hash"] = contract.config_hash
        data["contract"] = contract_guard(contract, self.entry_path(contract))
        atomic_json(self.paths.manifest, data)

    def writable_config(self):
        contract = read_contract(self.paths, self.host)
        require(self.store.resolve() == contract.binary.resolve(), "服务与受管核心不一致")
        require(contract.files == [self.paths.config] and len(contract.inbounds) <= 4,
                "当前服务使用额外配置，不能使用模板配置修改")
        return 0

    def remove_managed(self):
        require(not self.paths.pending.exists(), "未完成事务必须先恢复")
        if not self.paths.manifest.exists():
            return
        data = self.store.read()
        contract = read_contract(self.paths, self.host)
        require(not self.host.active(contract.manager), "请先停止服务再卸载受管版本")
        require(contract.binary == self.paths.current, "服务入口已被外部修改，未删除")
        # Validate every historical removal before touching active links or service entry.
        self.store.cleanup((), dry_run=True)
        if contract.manager == "systemd":
            require(self.paths.dropin.read_bytes() == self.entry_data(contract), "受管覆盖文件已变化")
            self.paths.dropin.unlink()
        else:
            # The full uninstall removes this known project template separately.
            require(self.paths.openrc in contract.service_files, "未知 OpenRC 服务")
        trusted(self.paths.engines)
        self.paths.current.unlink()
        self.store.cleanup(())
        self.paths.manifest.unlink()
        self.host.reload(contract.manager)

class Doctor:
    def __init__(self, paths, host):
        self.paths = paths
        self.host = host
        self.failed = False
        self.incomplete = False

    def item(self, label, check):
        try:
            value = check()
            print("[正常] " + label + ("：" + value if value else ""))
        except EngineError as error:
            if error.code == 2:
                self.incomplete = True
                print("[未完成] " + label)
            else:
                self.failed = True
                print("[异常] " + label)
        except (PermissionError, FileNotFoundError, OSError, ValueError):
            self.incomplete = True
            print("[未完成] " + label)

    def run(self):
        print("sbm / 统一诊断（本机只读）")
        print("系统：" + os.uname().sysname + " / " + os.uname().machine)
        if not self.paths.params.exists() and not self.paths.config.exists() and not self.paths.manifest.exists():
            print("[信息] 尚未安装节点；主菜单 → 安装节点")
            return 0
        self.item("保存参数", lambda: self.parameters())
        self.item("配置结构", lambda: self.configuration())
        self.item("版本状态", lambda: self.versions())
        contract = None
        try:
            contract = read_contract(self.paths, self.host)
        except EngineError as error:
            self.incomplete = self.incomplete or error.code == 2
            self.failed = self.failed or error.code != 2
            print("[未完成] 服务契约" if error.code == 2 else "[异常] 服务契约")
        except (OSError, ValueError):
            self.incomplete = True
            print("[未完成] 服务契约")
        if contract:
            self.item("服务版本来源", lambda: binary_version(self.host, contract.binary) + " / " +
                      ("sbm" if self.paths.manifest.exists() else installation_source(self.host, contract.binary)))
            cli = shutil.which("sing-box")
            if cli:
                self.item("系统 CLI 版本", lambda: binary_version(self.host, pathlib.Path(cli)))
            print("[信息] 服务：" + ("运行中" if contract.running else "已停止") +
                  "；开机自启：" + ("开启" if contract.enabled else "关闭"))
            if contract.running:
                def process_check():
                    pid = self.host.pid(contract.manager)
                    actual, arguments = read_process(pid)
                    require(actual == digest(contract.binary) and arguments[1:] == contract.argv,
                            "运行核心与服务不一致")
                    return "核心摘要与启动参数一致"
                self.item("实际核心", process_check)
                def listeners():
                    pid = self.host.pid(contract.manager)
                    for inbound in contract.inbounds:
                        require(port_owned(self.host, pid, inbound["listen_port"], inbound["type"] == "hysteria2"),
                                "监听未归属于核心")
                    return "预期端口归属于实际核心进程"
                self.item("监听归属", listeners)
            for inbound in contract.inbounds:
                certificate = inbound.get("tls", {}).get("certificate_path")
                if certificate:
                    def cert_check(filename=certificate):
                        self.host.run(["openssl", "x509", "-checkend", "0", "-noout", "-in", filename])
                        return "未过期"
                    self.item("本机证书", cert_check)
        print("[信息] 完整配置语义、协议认证和公网连接：未检查")
        print("操作入口：服务管理 → 协议自检 / 公网连通性排查；系统维护 → sing-box 版本管理")
        return 1 if self.failed else 2 if self.incomplete else 0

    def parameters(self):
        values = params_read(self.paths.params)
        require(all(key in values for key in ("REALITY_PORT", "REALITY_SNI", "UUID")), "保存参数不完整")
        enabled = [name for key, name in (("HY2_ENABLED", "Hysteria2"), ("SOCKS_ENABLED", "SOCKS5"),
                                          ("ARGO_ENABLED", "Argo")) if values.get(key) == "true"]
        # Display only controlled labels; values such as node names may contain terminal escapes.
        label = "Reality" + (" / " + " / ".join(enabled) if enabled else "")
        if shutil.which("ip"):
            output = self.host.run(["ip", "-6", "-o", "addr", "show", "scope", "global"], check=False).stdout
            count = 0
            for line in output.splitlines():
                fields = line.split()
                if len(fields) >= 4:
                    try:
                        address = ipaddress.ip_interface(fields[3]).ip
                        if address.is_global:
                            count += 1
                    except ValueError:
                        pass
            label += "；网卡公网 IPv6：" + str(count) + " 个（入站未验证）"
        return label

    def configuration(self):
        value = load_json(self.paths.config)
        require(isinstance(value, dict) and isinstance(value.get("inbounds"), list), "配置结构无效")
        return "JSON 可读；未执行内核检查"

    def versions(self):
        require(not self.paths.pending.exists(), "有未完成版本操作")
        if not self.paths.manifest.exists():
            return "未启用 sbm 版本管理"
        data = EngineStore(self.paths).read()
        EngineStore(self.paths).resolve()
        record = data["current"]
        return record["version"] + ("；运行验证通过" if record["evidence"] == "runtime" else "；运行未验证")


def show_versions(paths, host):
    if paths.pending.exists():
        print("状态：有未完成事务，请执行 sbm rollback sing-box --yes 恢复。")
        return 1
    if paths.manifest.exists():
        data = EngineStore(paths).read()
        EngineStore(paths).resolve()
        for key, label in (("current", "当前版本"), ("previous", "上一版本")):
            record = data.get(key)
            if record:
                print(label + "：" + record["version"] + "（" +
                      ("运行已验证" if record["evidence"] == "runtime" else "配置已验证，运行未验证") + "）")
        print("管理来源：sbm 独立版本目录；系统软件包保留")
    else:
        contract = read_contract(paths, host)
        print("当前版本：" + binary_version(host, contract.binary))
        print("管理来源：" + installation_source(host, contract.binary) + "；尚未启用 sbm 版本管理")
    return 0


def engine_main(argv):
    global IO_DEADLINE
    require(len(argv) >= 8, "内核管理参数缺失")
    paths = Paths(*(pathlib.Path(item) for item in argv[:7]))
    action = argv[7]
    host = Host(time.monotonic() + 15 if action in ("doctor", "versions") else None)
    IO_DEADLINE = host.deadline
    if action == "doctor":
        return Doctor(paths, host).run()
    if action == "resolve":
        print(EngineStore(paths).resolve())
    elif action == "versions":
        return show_versions(paths, host)
    elif action == "compatible":
        if paths.manifest.exists():
            EngineStore(paths).resolve()
        return 0
    elif action == "manager-download":
        require(len(argv) == 9, "管理脚本下载目标缺失")
        metadata = json.loads(fetch("https://api.github.com/repos/iceeyes27/sing-box/commits/main"))
        revision = metadata.get("sha", "")
        require(re.fullmatch(r"[0-9a-f]{40}", revision), "管理脚本提交无效")
        base = "https://raw.githubusercontent.com/iceeyes27/sing-box/" + revision + "/"
        content = fetch(base + "install.sh", maximum=4 * 1024 * 1024)
        checksum = fetch(base + "dist/install.sh.sha256").decode("ascii").strip()
        require(re.fullmatch(r"[0-9a-f]{64}  install.sh", checksum) and
                hashlib.sha256(content).hexdigest() == checksum[:64], "管理脚本校验失败")
        target = pathlib.Path(argv[8])
        require(target.is_file() and not target.is_symlink() and target.stat().st_uid == os.geteuid(), "管理脚本临时文件不可信")
        atomic_bytes(target, content)
    elif action in ("upgrade", "rollback", "validate-start", "refresh", "remove-managed", "writable-config"):
        require(os.geteuid() == 0, "版本操作需要 root 权限")
        import fcntl
        inherited_fd = os.environ.get("SBM_INHERITED_LOCK_FD", "")
        require(re.fullmatch(r"[0-9]+", inherited_fd), "版本操作缺少维护锁")
        lock_fd = int(inherited_fd)
        actual_lock = os.fstat(lock_fd)
        expected_lock = paths.lock.stat()
        require(actual_lock.st_ino == expected_lock.st_ino and actual_lock.st_dev == expected_lock.st_dev and
                expected_lock.st_uid == 0 and stat.S_ISREG(expected_lock.st_mode), "维护锁来源无效")
        # Keep the inherited open-file description alive if the parent shell exits.
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        updater = Upgrade(paths, host)
        def interrupted(signum, frame):
            raise EngineError("版本操作被中断，恢复材料已保留")
        signal.signal(signal.SIGTERM, interrupted)
        signal.signal(signal.SIGINT, interrupted)
        if action == "rollback" and paths.pending.exists():
            updater.restore()
        elif action == "writable-config":
            return updater.writable_config()
        elif action == "remove-managed":
            updater.remove_managed()
        elif action == "refresh":
            updater.validate_start(allow_stopped=True)
        elif action == "validate-start":
            updater.validate_start()
        else:
            updater.execute(argv[8] if len(argv) > 8 else "", rollback=action == "rollback")
    else:
        raise EngineError("未知内核管理动作", 2)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(engine_main(sys.argv[1:]))
    except EngineError as error:
        print("[ERROR] " + str(error), file=sys.stderr)
        raise SystemExit(error.code)
    except (OSError, ValueError, KeyError, TypeError, AttributeError, RuntimeError, tarfile.TarError):
        # Never expose malformed config, ExecStart, URLs, credentials, or raw command errors.
        print("[ERROR] 检查或版本操作未完成；未输出可能包含凭据的原始错误。", file=sys.stderr)
        raise SystemExit(2)
SBM_ENGINE_PY
}

sbm_flock_available() { command -v flock >/dev/null 2>&1; }

# Installation may need flock before it can take the normal maintenance lock.
# A private atomic directory prevents two first-install bootstraps from racing.
sbm_prepare_install_lock() (
    sbm_flock_available && return 0
    local lock_dir="${SBM_LOCK_FILE%/*}" bootstrap_dir package
    umask 077
    mkdir -p "$lock_dir" || return 1
    [[ -d "$lock_dir" && ! -L "$lock_dir" && -O "$lock_dir" && "$(stat -c %a "$lock_dir")" == 700 ]] || return 1
    bootstrap_dir="${lock_dir}/install-bootstrap.lock"
    if ! mkdir -m 700 "$bootstrap_dir" 2>/dev/null; then
        warn "安装依赖初始化正在进行，或存在未清理的初始化锁: ${bootstrap_dir}"
        return 1
    fi
    trap 'rmdir "$bootstrap_dir" 2>/dev/null || true' EXIT
    case "$(package_manager)" in
        apk) package=flock ;;
        apt|dnf|yum) package=util-linux ;;
        *) warn "缺少 flock，且无法识别系统包管理器"; return 1 ;;
    esac
    info "安装首次部署所需的 flock..."
    install_packages_low_resource "$package" || return 1
    hash -r 2>/dev/null || true
    sbm_flock_available || { warn "flock 安装后仍不可用"; return 1; }
)

sbm_lock_acquire() {
    [[ "${SBM_LOCK_HELD:-}" == "$BASHPID" ]] && return 0
    sbm_flock_available || { warn "缺少 flock，未执行修改"; return 1; }
    if [[ ! -e "$(dirname "$SBM_LOCK_FILE")" ]]; then
        (umask 077; mkdir -m 700 "$(dirname "$SBM_LOCK_FILE")") || return 1
    fi
    [[ -d "$(dirname "$SBM_LOCK_FILE")" && ! -L "$SBM_LOCK_FILE" ]] || return 1
    [[ ! -L "$(dirname "$SBM_LOCK_FILE")" && -O "$(dirname "$SBM_LOCK_FILE")" && "$(stat -c %a "$(dirname "$SBM_LOCK_FILE")")" == 700 ]] || return 1
    exec {SBM_LOCK_FD}>>"$SBM_LOCK_FILE" || return 1
    if ! flock -n "$SBM_LOCK_FD"; then
        exec {SBM_LOCK_FD}>&-
        warn "另一个管理操作正在执行，请稍后重试"
        return 1
    fi
    SBM_LOCK_HELD="$BASHPID"
}

sbm_lock_release() {
    [[ "${SBM_LOCK_HELD:-}" == "$BASHPID" ]] || return 0
    flock -u "$SBM_LOCK_FD" || true
    exec {SBM_LOCK_FD}>&-
    unset SBM_LOCK_HELD SBM_LOCK_FD
}

sbm_with_lock() {
    if [[ "${SBM_LOCK_HELD:-}" == "$BASHPID" ]]; then "$@"; return $?; fi
    if [[ "${1:-}" == do_primary_install ]] && ! sbm_flock_available; then
        sbm_prepare_install_lock || return 1
    fi
    sbm_lock_acquire || return 1
    local result=0
    if [[ -e "$SBM_STATE_DIR/pending.json" ]]; then
        if [[ "${1:-}" == engine_rollback ]]; then
            "$@" || result=$?
        else
            warn "有未完成的版本操作，请先执行 sbm rollback sing-box --yes"
            result=1
        fi
    elif [[ -e "$SBM_STATE_DIR/engine.json" ]] && ! engine_python compatible; then
        result=1
    else
        "$@" || result=$?
    fi
    sbm_lock_release
    return "$result"
}

resolve_singbox_binary() {
    if [[ -e "$SBM_STATE_DIR/engine.json" || -e "$SBM_STATE_DIR/pending.json" || -L "$SBM_ENGINE_ROOT/current" ]]; then
        engine_python resolve
    else
        command -v sing-box 2>/dev/null || { [[ -x "$SINGBOX_BIN_PATH" ]] && printf '%s\n' "$SINGBOX_BIN_PATH"; }
    fi
}

run_singbox() {
    local binary
    binary=$(resolve_singbox_binary) || return 1
    "$binary" "$@"
}

# timeout 只能执行真实程序，不能执行 Bash 函数。
run_singbox_bounded() {
    local seconds="$1" binary
    shift
    binary=$(resolve_singbox_binary) || return 1
    command -v timeout >/dev/null 2>&1 || return 1
    timeout -k 1 "$seconds" "$binary" "$@"
}

engine_finish_start() {
    [[ -f "$SBM_STATE_DIR/engine.json" ]] || return 0
    engine_python validate-start
}

engine_refresh_after_change() {
    [[ -f "$SBM_STATE_DIR/engine.json" ]] || return 0
    engine_python refresh
}

sbm_mutation_guard() {
    [[ ! -e "$SBM_STATE_DIR/pending.json" ]] || { warn "有未完成的版本操作，请先恢复"; return 1; }
}

engine_config_guard() {
    [[ -f "$SBM_STATE_DIR/engine.json" ]] || return 0
    engine_python writable-config
}
# ─── 管理命令 (sbm) ─────────────────────────────────────────
ensure_command_aliases() {
    [[ -f "$MANAGER_COMMAND" ]] || return 0
    ensure_command_link "$MANAGER_COMMAND" "$MANAGER_ALIAS_COMMAND"
    ensure_command_link "$MANAGER_COMMAND" "$MANAGER_SYSTEM_COMMAND"
    ensure_command_link "$MANAGER_COMMAND" "$MANAGER_SYSTEM_ALIAS_COMMAND"
    ensure_command_link "$MANAGER_COMMAND" "$MANAGER_BIN_COMMAND"
    ensure_command_link "$MANAGER_COMMAND" "$MANAGER_BIN_ALIAS_COMMAND"
}

resolve_existing_path() {
    local path="$1"
    local dir base

    if command -v readlink >/dev/null 2>&1; then
        readlink -f "$path" 2>/dev/null && return 0
    fi

    dir="$(dirname "$path")"
    base="$(basename "$path")"
    (cd "$dir" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$base")
}

is_manager_source() {
    local source_path="$1"
    local resolved_source resolved_manager

    [[ "$source_path" == "$MANAGER_COMMAND" ]] && return 0
    [[ -e "$source_path" && -e "$MANAGER_COMMAND" ]] || return 1

    resolved_source="$(resolve_existing_path "$source_path" 2>/dev/null || true)"
    resolved_manager="$(resolve_existing_path "$MANAGER_COMMAND" 2>/dev/null || true)"
    [[ -n "$resolved_source" && "$resolved_source" == "$resolved_manager" ]]
}

ensure_command_link() {
    local target="$1"
    local link_path="$2"
    local link_dir existing_target

    link_dir="$(dirname "$link_path")"
    [[ -d "$link_dir" ]] || return 0

    if [[ -e "$link_path" || -L "$link_path" ]]; then
        [[ -L "$link_path" ]] || return 0
        existing_target="$(readlink "$link_path" 2>/dev/null || true)"
        [[ "$existing_target" == "$target" ]] && return 0
        [[ -n "$existing_target" && -e "$existing_target" ]] && manager_script_valid "$existing_target" && return 0
        rm -f "$link_path" 2>/dev/null || return 0
    fi

    ln -sf "$target" "$link_path" 2>/dev/null || true
}

remove_manager_link() {
    local link_path="$1"
    local target="$2"

    if [[ -L "$link_path" ]]; then
        [[ "$(readlink "$link_path" 2>/dev/null)" == "$target" ]] && rm -f "$link_path"
        return 0
    fi

    [[ "$link_path" == "$target" ]] && rm -f "$link_path"
}

manager_script_valid() {
    local script_path="$1"
    [[ -f "$script_path" && -s "$script_path" ]] || return 1
    grep -q '^SCRIPT_VERSION=' "$script_path" 2>/dev/null || return 1
    grep -q 'main "$@"' "$script_path" 2>/dev/null || return 1
    bash -n "$script_path" || return 1
    if [[ -e "$SBM_STATE_DIR/engine.json" || -e "$SBM_STATE_DIR/pending.json" ]]; then
        grep -qx 'SBM_STATE_SCHEMA_MIN=1' "$script_path" || return 1
        grep -qx 'SBM_STATE_SCHEMA_MAX=1' "$script_path" || return 1
        grep -qx 'SBM_PENDING_RECOVERY=1' "$script_path" || return 1
    fi
    return 0
}

install_manager_from_file() {
    local source_path="$1"
    if [[ "${SBM_LOCK_HELD:-}" != "$BASHPID" && "${SBM_TEST_MODE:-}" != 1 ]]; then
        sbm_with_lock install_manager_from_file "$source_path"
        return $?
    fi

    manager_script_valid "$source_path" || return 1
    mkdir -p "$(dirname "$MANAGER_COMMAND")" 2>/dev/null || return 1

    local staged
    staged=$(mktemp "${MANAGER_COMMAND}.new.XXXXXX") || return 1
    if ! cp "$source_path" "$staged" || ! chmod 755 "$staged" || ! manager_script_valid "$staged"; then
        rm -f "$staged"; return 1
    fi
    if [[ -f "$MANAGER_COMMAND" ]] && manager_script_valid "$MANAGER_COMMAND"; then
        cp -p "$MANAGER_COMMAND" "${MANAGER_COMMAND}.previous" || { rm -f "$staged"; return 1; }
    fi
    mv -f "$staged" "$MANAGER_COMMAND" || { rm -f "$staged"; return 1; }

    manager_script_valid "$MANAGER_COMMAND" || return 1
    chmod +x "$MANAGER_COMMAND" 2>/dev/null || true
    ensure_command_aliases
    hash -r 2>/dev/null || true
    return 0
}

download_manager_command() {
    local tmp_file result=0
    tmp_file=$(mktemp) || return 1
    if engine_python manager-download "$tmp_file" && manager_script_valid "$tmp_file"; then
        install_manager_from_file "$tmp_file" || result=$?
    else result=1; fi
    rm -f "$tmp_file"
    return "$result"
}

install_manager_command() {
    if [[ "${SBM_LOCK_HELD:-}" != "$BASHPID" && "${SBM_TEST_MODE:-}" != 1 ]]; then
        sbm_with_lock install_manager_command
        return $?
    fi
    is_manager_source "${BASH_SOURCE[0]:-}" && {
        ensure_command_aliases
        return 0
    }

    local source_path
    source_path="${BASH_SOURCE[0]:-}"
    install_manager_from_file "$source_path" 2>/dev/null && return 0
    download_manager_command && return 0

    warn "未能安装 sbm 命令，当前安装流程继续；请稍后重新执行在线安装命令修复"
    return 0
}
# ─── 安装组件 ────────────────────────────────────────────────
get_meminfo_kb() {
    local key="$1" name value
    [[ -r /proc/meminfo ]] || return 1
    while read -r name value _; do
        if [[ "$name" == "${key}:" && "$value" =~ ^[0-9]+$ ]]; then
            echo "$value"
            return 0
        fi
    done < /proc/meminfo
    return 1
}

get_resource_profile() {
    local mem_total swap_total
    mem_total=$(get_meminfo_kb MemTotal 2>/dev/null || echo 0)
    swap_total=$(get_meminfo_kb SwapTotal 2>/dev/null || echo 0)

    if (( mem_total <= 0 )); then
        echo "unknown"
    elif (( mem_total < 786432 && swap_total < 131072 )); then
        echo "low-noswap"
    elif (( mem_total < 786432 )); then
        echo "low-swap"
    elif (( mem_total < 1572864 )); then
        echo "standard"
    else
        echo "high"
    fi
}

get_cpu_count() {
    local cpu_count
    if command -v nproc &>/dev/null; then
        cpu_count=$(nproc 2>/dev/null || echo 1)
    elif command -v getconf &>/dev/null; then
        cpu_count=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
    elif [[ -r /proc/cpuinfo ]]; then
        cpu_count=$(grep -c '^processor[[:space:]]*:' /proc/cpuinfo 2>/dev/null || echo 1)
    else
        cpu_count=1
    fi
    [[ "$cpu_count" =~ ^[0-9]+$ && "$cpu_count" -gt 0 ]] || cpu_count=1
    echo "$cpu_count"
}

get_cpu_profile() {
    local cpu_count
    cpu_count=$(get_cpu_count)
    if (( cpu_count <= 1 )); then
        echo "low"
    elif (( cpu_count <= 2 )); then
        echo "standard"
    else
        echo "high"
    fi
}

resource_profile_label() {
    case "$(get_resource_profile)" in
        low-noswap) echo "低内存 / 无可用 swap" ;;
        low-swap)   echo "低内存 / 有可用 swap" ;;
        standard)   echo "标准内存" ;;
        high)       echo "高内存" ;;
        *)          echo "未知内存状态" ;;
    esac
}

cpu_profile_label() {
    case "$(get_cpu_profile)" in
        low)      echo "低 CPU ($(get_cpu_count) 核)" ;;
        standard) echo "标准 CPU ($(get_cpu_count) 核)" ;;
        high)     echo "高 CPU ($(get_cpu_count) 核)" ;;
        *)        echo "未知 CPU 状态" ;;
    esac
}

cleanup_low_memory_swap() {
    [[ "$LOW_MEMORY_SWAP_CREATED" == "true" ]] || return 0
    swapoff "$LOW_MEMORY_SWAP_FILE" >/dev/null 2>&1 || true
    rm -f "$LOW_MEMORY_SWAP_FILE" >/dev/null 2>&1 || true
    LOW_MEMORY_SWAP_CREATED=false
}

prepare_low_memory_swap() {
    local available_mb

    [[ "$(get_resource_profile)" == "low-noswap" ]] || return 0
    command -v mkswap &>/dev/null && command -v swapon &>/dev/null || return 0

    if [[ -e "$LOW_MEMORY_SWAP_FILE" ]]; then
        warn "检测到低内存，但 ${LOW_MEMORY_SWAP_FILE} 已存在，跳过临时 swap 创建"
        return 0
    fi

    available_mb=$(df -Pm / 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)
    [[ "$available_mb" =~ ^[0-9]+$ ]] || available_mb=0
    if (( available_mb < 640 )); then
        warn "检测到低内存且磁盘可用空间不足，继续使用分批安装"
        return 0
    fi

    info "检测到低内存且无可用 swap，临时启用 512MB swap 支撑安装..."
    if command -v fallocate &>/dev/null; then
        fallocate -l 512M "$LOW_MEMORY_SWAP_FILE" >/dev/null 2>&1 || \
            dd if=/dev/zero of="$LOW_MEMORY_SWAP_FILE" bs=1M count=512 status=none >/dev/null 2>&1 || true
    else
        dd if=/dev/zero of="$LOW_MEMORY_SWAP_FILE" bs=1M count=512 status=none >/dev/null 2>&1 || true
    fi

    if [[ ! -s "$LOW_MEMORY_SWAP_FILE" ]]; then
        rm -f "$LOW_MEMORY_SWAP_FILE" >/dev/null 2>&1 || true
        warn "临时 swap 文件创建失败，继续使用分批安装"
        return 0
    fi

    chmod 600 "$LOW_MEMORY_SWAP_FILE" >/dev/null 2>&1 || true
    if mkswap "$LOW_MEMORY_SWAP_FILE" >/dev/null 2>&1 && swapon "$LOW_MEMORY_SWAP_FILE" >/dev/null 2>&1; then
        LOW_MEMORY_SWAP_CREATED=true
        trap cleanup_low_memory_swap EXIT
        success "临时 swap 已启用"
    else
        rm -f "$LOW_MEMORY_SWAP_FILE" >/dev/null 2>&1 || true
        warn "当前 VPS 不允许启用临时 swap，继续使用分批安装"
    fi
}

is_low_memory_without_swap() {
    [[ "$(get_resource_profile)" == "low-noswap" && "$LOW_MEMORY_SWAP_CREATED" != "true" ]]
}

run_low_resource() {
    if command -v ionice &>/dev/null; then
        ionice -c 3 nice -n 19 "$@"
    else
        nice -n 19 "$@"
    fi
}

package_manager() {
    if command -v apt-get &>/dev/null; then
        echo "apt"
    elif command -v dnf &>/dev/null; then
        echo "dnf"
    elif command -v yum &>/dev/null; then
        echo "yum"
    elif command -v apk &>/dev/null; then
        echo "apk"
    else
        echo "none"
    fi
}

singbox_binary_available() {
    resolve_singbox_binary >/dev/null 2>&1
}

is_apt_package_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

install_apt_packages_low_resource() {
    local pkg
    export DEBIAN_FRONTEND=noninteractive
    run_low_resource apt-get update -qq -o Acquire::Languages=none 2>/dev/null || return 1
    apt-get clean >/dev/null 2>&1 || true

    for pkg in "$@"; do
        if is_apt_package_installed "$pkg"; then
            continue
        fi
        info "安装依赖: ${pkg}"
        if ! run_low_resource apt-get install -y -qq --no-install-recommends \
            -o Dpkg::Use-Pty=0 \
            -o APT::Install-Recommends=false \
            -o APT::Install-Suggests=false \
            "$pkg" > /dev/null 2>&1; then
            warn "依赖安装失败: ${pkg}"
            return 1
        fi
        apt-get clean >/dev/null 2>&1 || true
    done
}

install_yum_packages_low_resource() {
    local manager="$1" pkg
    shift
    for pkg in "$@"; do
        if command -v rpm &>/dev/null && rpm -q "$pkg" >/dev/null 2>&1; then
            continue
        fi
        info "安装依赖: ${pkg}"
        if ! run_low_resource "$manager" install -y -q "$pkg" > /dev/null 2>&1; then
            warn "依赖安装失败: ${pkg}"
            return 1
        fi
    done
}

install_apk_packages_low_resource() {
    local pkg
    for pkg in "$@"; do
        if apk info -e "$pkg" >/dev/null 2>&1; then
            continue
        fi
        info "安装依赖: ${pkg}"
        if ! run_low_resource apk add --no-cache "$pkg" > /dev/null 2>&1; then
            warn "依赖安装失败: ${pkg}"
            return 1
        fi
    done
}

install_packages_low_resource() {
    case "$(package_manager)" in
        apt) install_apt_packages_low_resource "$@" ;;
        dnf) install_yum_packages_low_resource dnf "$@" ;;
        yum) install_yum_packages_low_resource yum "$@" ;;
        apk) install_apk_packages_low_resource "$@" ;;
        *)   return 1 ;;
    esac
}

install_missing_required_deps() {
    local missing_required=()
    local missing_optional=()

    command -v curl &>/dev/null || missing_required+=(curl)
    command -v openssl &>/dev/null || missing_optional+=(openssl)

    if [[ ${#missing_required[@]} -gt 0 ]]; then
        warn "缺少关键依赖: ${missing_required[*]}"
        install_packages_low_resource "${missing_required[@]}" || return 1
    fi

    if [[ ${#missing_optional[@]} -gt 0 ]]; then
        warn "缺少可选依赖: ${missing_optional[*]}"
        if ! install_packages_low_resource "${missing_optional[@]}"; then
            warn "可选依赖安装失败: ${missing_optional[*]}。将继续部署 Reality / Argo，Hysteria2 会自动关闭"
        fi
    fi

    command -v curl &>/dev/null
}

install_optional_deps() {
    local optional=()
    local cpu_profile profile

    profile=$(get_resource_profile)
    cpu_profile=$(get_cpu_profile)
    case "$profile" in
        low-noswap)
            if is_low_memory_without_swap; then
                warn "检测到低内存且无可用 swap，跳过可选依赖安装"
                return 0
            fi
            ;;
        low-swap)
            info "低内存但已有可用 swap，将分批安装缺失的可选依赖"
            ;;
        standard|high)
            info "当前资源状态允许安装缺失的可选依赖"
            ;;
        *)
            info "内存状态未知，按保守策略分批安装缺失的可选依赖"
            ;;
    esac

    if [[ "$cpu_profile" == "low" ]]; then
        info "检测到低 CPU，缺失依赖将使用低优先级串行安装"
    fi

    command -v wget &>/dev/null || optional+=(wget)
    command -v jq &>/dev/null || optional+=(jq)
    command -v python3 &>/dev/null || optional+=(python3)
    command -v ip &>/dev/null || optional+=(iproute2)
    command -v lsof &>/dev/null || optional+=(lsof)
    [[ -f /etc/ssl/certs/ca-certificates.crt ]] || optional+=(ca-certificates)

    [[ ${#optional[@]} -gt 0 ]] || return 0
    info "安装可选依赖: ${optional[*]}"
    if ! install_packages_low_resource "${optional[@]}"; then
        warn "部分可选依赖安装失败，继续核心部署；订阅服务或端口检测能力可能受限"
    fi
}

get_singbox_release_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l|armv7) echo "armv7" ;;
        i386|i686|x86) echo "386" ;;
        *) return 1 ;;
    esac
}

get_latest_singbox_version() {
    local version latest_url

    version=$(curl -fsSL --connect-timeout 10 --max-time 20 \
        "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null \
        | awk -F'"' '/"tag_name"/ { gsub(/^v/, "", $4); print $4; exit }' || true)

    if [[ -z "$version" ]]; then
        latest_url=$(curl -fsSIL --connect-timeout 10 --max-time 20 -o /dev/null -w '%{url_effective}' \
            "https://github.com/SagerNet/sing-box/releases/latest" 2>/dev/null || true)
        version="${latest_url##*/v}"
    fi

    [[ "$version" =~ ^[0-9]+(\.[0-9]+)+$ ]] || return 1
    echo "$version"
}

# 用 "$@" 输出 tar.gz 字节流，解出 $1 指定的成员并原子替换 SINGBOX_BIN_PATH。
install_singbox_archive() {
    local archive_member="$1" tmp_bin
    shift
    tmp_bin="${SINGBOX_BIN_DIR}/.sing-box.${$}.tmp"

    if ! mkdir -p "$SINGBOX_BIN_DIR"; then
        return 1
    fi
    if ! "$@" | tar -xzO "$archive_member" > "$tmp_bin"; then
        rm -f "$tmp_bin"
        return 1
    fi

    chmod 755 "$tmp_bin"
    if ! "$tmp_bin" version >/dev/null 2>&1; then
        rm -f "$tmp_bin"
        return 1
    fi
    mv -f "$tmp_bin" "$SINGBOX_BIN_PATH"

    hash -r 2>/dev/null || true
    if ! singbox_binary_available && [[ -x "$SINGBOX_BIN_PATH" ]]; then
        ln -sf "$SINGBOX_BIN_PATH" /usr/bin/sing-box 2>/dev/null || true
        hash -r 2>/dev/null || true
    fi

    singbox_binary_available
}

install_singbox_from_official_tarball() {
    local version arch

    arch=$(get_singbox_release_arch) || return 1
    version=$(get_latest_singbox_version) || return 1
    info "下载 sing-box 官方二进制: v${version} (${arch}-musl)"
    install_singbox_archive "sing-box-${version}-linux-${arch}-musl/sing-box" \
        curl -fL --retry 3 --connect-timeout 15 \
        "https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-${arch}-musl.tar.gz"
}

installed_singbox_version() {
    singbox_binary_available || return 1
    run_singbox version 2>/dev/null | awk 'NR == 1 { print $3; exit }'
}

# $1 >= $2 时返回 0；只比较 主.次.修订，忽略预发布后缀。
version_at_least() {
    local -a have want
    local i x y
    IFS=. read -r -a have <<< "${1%%-*}"
    IFS=. read -r -a want <<< "${2%%-*}"
    for i in 0 1 2; do
        x="${have[i]:-0}"; y="${want[i]:-0}"
        [[ "$x" =~ ^[0-9]+$ ]] || x=0
        [[ "$y" =~ ^[0-9]+$ ]] || y=0
        (( 10#$x > 10#$y )) && return 0
        (( 10#$x < 10#$y )) && return 1
    done
    return 0
}

# 脚本可能从 /tmp 运行：本地文件及其两级父目录须属于当前用户且组/其他用户不可写，防止被他人替换。
trusted_local_file() {
    local path="$1" dir
    dir=$(dirname "$path")
    for path in "$path" "$dir" "$(dirname "$dir")"; do
        [[ -O "$path" ]] || return 1
        [[ -z "$(find "$path" -maxdepth 0 \( -perm -0002 -o -perm -0020 \) 2>/dev/null)" ]] || return 1
    done
}

# 官方渠道均不可用时的兜底：优先使用脚本同目录的 vendor/sing-box/，否则从本仓库下载。
install_singbox_from_vendored_tarball() {
    local upgrade="${1:-false}" arch name current script_dir local_archive

    arch=$(get_singbox_release_arch) || return 1
    name="sing-box-${VENDORED_SINGBOX_VERSION}-linux-${arch}-musl"
    if [[ "$upgrade" == "true" ]] && current=$(installed_singbox_version) && [[ -n "$current" ]] \
        && version_at_least "$current" "$VENDORED_SINGBOX_VERSION"; then
        warn "当前 sing-box v${current} 不低于仓库内置版本 v${VENDORED_SINGBOX_VERSION}，无可用更新"
        return 1
    fi

    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd) || script_dir=""
    local_archive="${script_dir}/vendor/sing-box/${name}.tar.gz"
    if [[ -n "$script_dir" && -f "$local_archive" ]] && trusted_local_file "$local_archive"; then
        info "使用本地内置 sing-box: v${VENDORED_SINGBOX_VERSION} (${arch}-musl)"
        install_singbox_archive "${name}/sing-box" cat "$local_archive"
    else
        info "下载仓库内置 sing-box: v${VENDORED_SINGBOX_VERSION} (${arch}-musl)"
        install_singbox_archive "${name}/sing-box" \
            curl -fL --retry 3 --connect-timeout 15 "${VENDORED_SINGBOX_BASE_URL}/${name}.tar.gz"
    fi
}

install_singbox_release_binary() {
    local upgrade="${1:-false}"
    install_singbox_from_official_tarball && return 0
    warn "sing-box 官方二进制不可用，改用仓库内置版本 v${VENDORED_SINGBOX_VERSION}"
    install_singbox_from_vendored_tarball "$upgrade"
}

# 软件包安装成功后，移除此前由 release 包安装的二进制和 systemd 单元，避免遮蔽软件包版本。
remove_singbox_release_install() {
    if [[ -L /usr/bin/sing-box && "$(readlink /usr/bin/sing-box)" == "$SINGBOX_BIN_PATH" ]]; then
        rm -f /usr/bin/sing-box
    fi
    rm -f "$SINGBOX_BIN_PATH"
    if [[ -f "$SINGBOX_SYSTEMD_SERVICE" ]] && grep -qF "$SINGBOX_SYSTEMD_MANAGED_MARKER" "$SINGBOX_SYSTEMD_SERVICE"; then
        rm -f "$SINGBOX_SYSTEMD_SERVICE"
        service_daemon_reload
    fi
    hash -r 2>/dev/null || true
}

install_or_upgrade_singbox_package() {
    local upgrade="${1:-false}"
    local apk_args=(add --no-cache)
    local packaged=false

    if [[ "$(package_manager)" == "apk" ]]; then
        [[ "$upgrade" == "true" ]] && apk_args+=(--upgrade)
        if run_low_resource apk "${apk_args[@]}" sing-box > /dev/null 2>&1 && singbox_binary_available; then
            packaged=true
        else
            warn "Alpine 软件源安装 sing-box 失败，改用官方 musl 二进制"
            install_singbox_release_binary "$upgrade" || return 1
        fi
    elif curl -fsSL --connect-timeout 15 https://sing-box.app/install.sh | sh; then
        packaged=true
    else
        warn "sing-box 官方安装脚本不可用，改用官方 musl 二进制"
        install_singbox_release_binary "$upgrade" || return 1
    fi
    # 软件包装在 /usr/bin；此前的 release 安装位于 /usr/local/bin，会在 PATH 中优先而遮蔽新版本。
    if [[ "$packaged" == "true" && -f /usr/bin/sing-box && ! -L /usr/bin/sing-box ]]; then
        remove_singbox_release_install
    fi

    singbox_binary_available
}

install_deps() {
    info "安装基础依赖..."
    info "资源检测: $(resource_profile_label), $(cpu_profile_label)"
    prepare_low_memory_swap
    install_missing_required_deps || error "关键依赖安装失败: curl。请检查系统内存、磁盘空间或软件源"
    install_optional_deps
    success "关键依赖就绪"
}

parse_rtc_utc_epoch() {
    local rtc_raw="$1"
    local rtc_input rtc_epoch rtc_tz
    [[ -n "$rtc_raw" ]] || return 1

    if [[ "$rtc_raw" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2})[[:space:]]+([0-9]{2}:[0-9]{2}:[0-9]{2})(\.[0-9]+)?[[:space:]]*([+-][0-9]{2}:?[0-9]{2}|UTC|Z)? ]]; then
        rtc_tz="${BASH_REMATCH[4]:-UTC}"
        [[ "$rtc_tz" == "Z" ]] && rtc_tz="UTC"
        rtc_input="${BASH_REMATCH[1]} ${BASH_REMATCH[2]} ${rtc_tz}"
    elif [[ "$rtc_raw" =~ [A-Z][a-z]{2}[[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2})[[:space:]]+([0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        rtc_input="${BASH_REMATCH[1]} ${BASH_REMATCH[2]} UTC"
    elif [[ "$rtc_raw" =~ [A-Z][a-z]{2}[[:space:]]+([A-Z][a-z]{2})[[:space:]]+([0-9]{1,2})[[:space:]]+([0-9]{2}:[0-9]{2}:[0-9]{2})[[:space:]]+([0-9]{4}) ]]; then
        rtc_input="${BASH_REMATCH[1]} ${BASH_REMATCH[2]} ${BASH_REMATCH[3]} ${BASH_REMATCH[4]} UTC"
    else
        return 1
    fi

    rtc_epoch=$(LC_ALL=C date -u -d "$rtc_input" +%s 2>/dev/null || return 1)
    [[ "$rtc_epoch" =~ ^[0-9]+$ ]] || return 1
    (( rtc_epoch >= 946684800 )) || return 1
    echo "$rtc_epoch"
}

get_rtc_utc_epoch() {
    local rtc_raw

    if command -v hwclock &>/dev/null; then
        rtc_raw=$(LC_ALL=C hwclock --utc --show 2>/dev/null || true)
        parse_rtc_utc_epoch "$rtc_raw" && return 0
    fi

    if command -v timedatectl &>/dev/null; then
        rtc_raw=$(LC_ALL=C timedatectl 2>/dev/null | awk -F': ' '/RTC time:/ {print $2; exit}' || true)
        parse_rtc_utc_epoch "$rtc_raw" && return 0
    fi

    return 1
}

get_time_skew_seconds() {
    local system_epoch rtc_epoch diff
    system_epoch=$(date -u +%s 2>/dev/null || return 1)
    rtc_epoch=$(get_rtc_utc_epoch 2>/dev/null || return 1)
    diff=$((system_epoch - rtc_epoch))
    (( diff < 0 )) && diff=$(( -diff ))
    echo "$diff"
}

is_time_synchronized() {
    if command -v timedatectl &>/dev/null; then
        [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]]
    elif command -v chronyc &>/dev/null; then
        chronyc tracking 2>/dev/null | grep -Eq 'Leap status[[:space:]]*:[[:space:]]*Normal'
    else
        return 1
    fi
}

existing_time_sync_service() {
    local svc
    for svc in systemd-timesyncd chrony chronyd ntp ntpd openntpd; do
        if service_exists "$svc"; then
            echo "$svc"
            return 0
        fi
    done
    if command -v chronyc &>/dev/null; then
        echo "chrony"
        return 0
    fi
    if command -v ntpq &>/dev/null || command -v ntpd &>/dev/null; then
        echo "ntp"
        return 0
    fi
    return 1
}

start_time_sync_service() {
    local svc
    for svc in systemd-timesyncd chrony chronyd ntp ntpd openntpd; do
        service_exists "$svc" || continue
        service_enable_now "$svc" 2>/dev/null || true
    done
}

step_system_time_with_ntp() {
    command -v ntpd &>/dev/null || return 1
    ntpd -d -n -q -p time.cloudflare.com >/dev/null 2>&1
}

install_time_sync_service() {
    local existing_svc

    if existing_svc=$(existing_time_sync_service 2>/dev/null); then
        info "检测到已有时间同步服务: ${existing_svc}，不安装新的时间同步服务"
        return 0
    fi

    case "$(package_manager)" in
        apt)
            info "安装时间同步服务 systemd-timesyncd..."
            if install_apt_packages_low_resource systemd-timesyncd; then
                return 0
            fi
            info "systemd-timesyncd 安装失败，回退安装 chrony..."
            install_apt_packages_low_resource chrony || return 1
            ;;
        dnf)
            info "安装时间同步服务 chrony..."
            install_yum_packages_low_resource dnf chrony || return 1
            ;;
        yum)
            info "安装时间同步服务 chrony..."
            install_yum_packages_low_resource yum chrony || return 1
            ;;
        apk)
            info "安装时间同步服务 chrony..."
            install_apk_packages_low_resource chrony || return 1
            ;;
        *) return 1 ;;
    esac
    return 0
}

attempt_time_sync() {
    if command -v timedatectl &>/dev/null; then
        timedatectl set-ntp true 2>/dev/null || true
    fi
    start_time_sync_service
    sleep 2
    if command -v chronyc &>/dev/null; then
        chronyc -a makestep >/dev/null 2>&1 || true
        sleep 2
    elif command -v ntpd &>/dev/null; then
        step_system_time_with_ntp || true
        sleep 2
    fi
}

ensure_time_sync() {
    local skew=""
    local need_sync=false

    if skew=$(get_time_skew_seconds 2>/dev/null); then
        if (( skew > TIME_SKEW_THRESHOLD )); then
            need_sync=true
        fi
    fi

    if ! is_time_synchronized; then
        need_sync=true
    fi

    if [[ "$need_sync" != "true" ]]; then
        success "系统时间同步正常"
        return 0
    fi

    if [[ -n "$skew" ]]; then
        warn "检测到系统时间与 RTC 相差 ${skew}s，开始同步修复..."
    else
        warn "检测到系统时间未同步，开始同步修复..."
    fi

    attempt_time_sync

    if ! is_time_synchronized; then
        install_time_sync_service && attempt_time_sync
    fi

    if skew=$(get_time_skew_seconds 2>/dev/null); then
        if is_time_synchronized && (( skew <= TIME_SKEW_THRESHOLD )); then
            success "系统时间已同步，当前与 RTC 误差 ${skew}s"
            return 0
        fi
        warn "时间同步后系统时间与 RTC 仍相差 ${skew}s，请检查宿主机/虚拟化平台时间源"
        return 1
    fi

    if is_time_synchronized; then
        success "系统时间已同步"
        return 0
    fi

    warn "自动时间同步失败，请手动检查 NTP 服务"
    return 1
}

install_singbox() {
    if [[ -e "$SBM_STATE_DIR/engine.json" || -e "$SBM_STATE_DIR/pending.json" || -L "$SBM_ENGINE_ROOT/current" ]]; then
        resolve_singbox_binary >/dev/null || { warn "受管内核状态异常，未执行安装"; return 1; }
        engine_config_guard || return 1
    fi
    if singbox_binary_available; then
        local ver
        ver=$(run_singbox version 2>/dev/null | head -1 || echo "unknown")
        info "sing-box 已安装: $ver"
    else
        info "安装 sing-box..."
        install_or_upgrade_singbox_package false || error "sing-box 安装失败。请检查网络、磁盘空间或 GitHub 访问"
        success "sing-box 安装完成"
    fi
    mkdir -p "$CONFIG_DIR"
}

install_cloudflared_from_apk() {
    [[ "$(package_manager)" == "apk" ]] || return 1
    run_low_resource apk add --no-cache cloudflared >/dev/null 2>&1 || return 1
    command -v cloudflared >/dev/null 2>&1 || return 1
    cloudflared --version >/dev/null 2>&1
}

install_cloudflared_binary() {
    local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH_CF}"
    local tmp_file

    tmp_file=$(mktemp) || return 1
    if ! curl -fsSL --retry 3 --connect-timeout 15 "$url" -o "$tmp_file"; then
        rm -f "$tmp_file"
        return 1
    fi
    chmod 755 "$tmp_file"
    if ! "$tmp_file" --version >/dev/null 2>&1; then
        rm -f "$tmp_file"
        return 1
    fi
    if command -v install >/dev/null 2>&1; then
        install -m 0755 "$tmp_file" /usr/local/bin/cloudflared
    else
        cp "$tmp_file" /usr/local/bin/cloudflared
        chmod 755 /usr/local/bin/cloudflared
    fi
    rm -f "$tmp_file"
    cloudflared --version >/dev/null 2>&1
}

install_cloudflared() {
    if command -v cloudflared &>/dev/null; then
        info "cloudflared 已安装"
        return
    fi
    info "安装 cloudflared..."
    if [[ "$(package_manager)" == "apk" ]]; then
        install_cloudflared_from_apk && { success "cloudflared 安装完成"; return; }
        warn "Alpine 软件源安装 cloudflared 失败，改用官方二进制"
    fi
    install_cloudflared_binary || error "cloudflared 安装失败。请检查网络、磁盘空间、系统架构或 GitHub 访问"
    success "cloudflared 安装完成"
}

# release 包不带 systemd 单元；软件包未提供 sing-box.service 时由脚本写入自管单元。
write_singbox_systemd_unit_if_needed() {
    local singbox_bin unit_dir
    if [[ ! -f "$SINGBOX_SYSTEMD_SERVICE" ]] || ! grep -qF "$SINGBOX_SYSTEMD_MANAGED_MARKER" "$SINGBOX_SYSTEMD_SERVICE"; then
        [[ -f "$SINGBOX_SYSTEMD_SERVICE" ]] && return 0
        for unit_dir in "${SINGBOX_PACKAGED_UNIT_DIRS[@]}"; do
            [[ -f "${unit_dir}/sing-box.service" ]] && return 0
        done
    fi

    singbox_bin=$(resolve_singbox_binary) || return 1
    if ! cat > "$SINGBOX_SYSTEMD_SERVICE" << EOF
${SINGBOX_SYSTEMD_MANAGED_MARKER}
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target network-online.target
Wants=network-online.target

[Service]
ExecStart=${singbox_bin} run -c ${CONFIG_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    then
        warn "无法写入 sing-box systemd 服务"
        return 1
    fi
}

write_singbox_service() {
    if [[ -e "$SBM_STATE_DIR/engine.json" ]]; then
        engine_python compatible || return 1
        # The managed service contract is owned by the version transaction.
        return 0
    fi
    case "$(service_manager)" in
        openrc)
            local singbox_bin
            singbox_bin=$(resolve_singbox_binary) || return 1

            prepare_openrc_supervision sing-box "$SINGBOX_OPENRC_SERVICE" || return 1
            cat > "$SINGBOX_OPENRC_SERVICE" << EOF || return 1
#!/sbin/openrc-run
name="sing-box"
description="sing-box service"
command="${singbox_bin}"
command_args="run -c ${CONFIG_FILE}"
$(openrc_supervision_block)
pidfile="/run/sing-box.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"

depend() {
    need net
}
EOF
            chmod 755 "$SINGBOX_OPENRC_SERVICE"
            ;;
        systemd)
            write_singbox_systemd_unit_if_needed || return 1
            if ! mkdir -p "$SINGBOX_SYSTEMD_DROPIN_DIR" 2>/dev/null; then
                warn "无法创建 sing-box systemd 自恢复目录，继续使用默认服务"
                return 0
            fi
            if ! cat > "$SINGBOX_SYSTEMD_OVERRIDE_FILE" << 'EOF'
[Unit]
StartLimitIntervalSec=0

[Service]
Restart=always
RestartSec=3
LimitNOFILE=1048576
EOF
            then
                warn "无法写入 sing-box systemd 自恢复配置，继续使用默认服务"
                return 0
            fi
            service_daemon_reload
            ;;
        *)
            return 0
            ;;
    esac
}
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
# ─── 生成参数 ────────────────────────────────────────────────
generate_params() {
    info "生成安全参数..."
    UUID=$(run_singbox generate uuid)
    SHORT_ID=$(random_hex 4)

    local keypair
    keypair=$(run_singbox generate reality-keypair)
    PRIVATE_KEY=$(echo "$keypair" | grep -i "PrivateKey" | awk '{print $NF}')
    PUBLIC_KEY=$(echo "$keypair" | grep -i "PublicKey"  | awk '{print $NF}')

    REALITY_PORT=${REALITY_PORT:-$(select_random_available_tcp_port)}
    # Reality 承载内核：singbox(默认) 或 xray。可通过环境变量 REALITY_BACKEND=xray 选择。
    REALITY_BACKEND="${REALITY_BACKEND:-singbox}"
    # 新安装先保持为空，由安装流程按连续握手结果选择；探测失败不回退默认 SNI。
    REALITY_SNI="${REALITY_SNI:-}"
    REALITY_SNI_CUSTOM=""
    WS_PORT=8080
    WS_PATH="/${SHORT_ID}"
    NODE_NAME=${NODE_NAME:-"sing-box-vps"}
    SUB_TOKEN=$(random_hex 16)
    SUBSCRIPTION_PORT=${SUBSCRIPTION_PORT:-24630}
    ARGO_DOMAIN=""
    ARGO_TOKEN=""
    ARGO_ENABLED="false"
    ARGO_BEST_CF_DOMAIN=""
    ARGO_BEST_CF_DOMAIN_IPV4=""
    ARGO_BEST_CF_DOMAIN_IPV6=""
    ARGO_CF_CACHE_DOMAIN=""
    ARGO_CF_CACHE_VERSION=""
    LINK_IPV4_SELECTION="all"
    PUBLIC_IPV4_OVERRIDE=""
    NAT_MODE="false"
    REALITY_PUBLIC_PORT="${REALITY_PORT}"

    # Hysteria2 参数
    HY2_PORT=${HY2_PORT:-${HY2_DEFAULT_PORT}}
    HY2_PASSWORD=$(random_base64 16)
    HY2_SNI="${HY2_DEFAULT_SNI}"
    HY2_MASQUERADE_URL="${HY2_DEFAULT_MASQUERADE_URL}"
    HY2_ENABLED="false"

    # 标准 SOCKS5 代理参数。默认关闭，启用后使用独立 TCP 端口与账号密码。
    SOCKS_PORT=${SOCKS_PORT:-$(select_random_available_tcp_port \
        "$REALITY_PORT" "$WS_PORT" "$SUBSCRIPTION_PORT")}
    SOCKS_PUBLIC_PORT="${SOCKS_PORT}"
    SOCKS_USERNAME="proxy-${SHORT_ID}"
    SOCKS_PASSWORD=$(random_hex 16)
    SOCKS_ENABLED="false"

    # 出站 IP 优先级，可通过环境变量 OUTBOUND_IP_STRATEGY=prefer_ipv6 等在安装时指定。
    OUTBOUND_IP_STRATEGY="${OUTBOUND_IP_STRATEGY:-default}"
    if ! is_valid_outbound_ip_strategy "$OUTBOUND_IP_STRATEGY"; then
        warn "无效的 OUTBOUND_IP_STRATEGY=${OUTBOUND_IP_STRATEGY}，已使用默认出站策略"
        OUTBOUND_IP_STRATEGY="default"
    fi

    success "参数生成完成"
}

# 仅供新安装使用；旧配置加载不应用这些默认值。
prompt_install_protocols() {
    local network_mode="$1" choice default_argo protocol selected_argo selected_socks selected_hy2 valid
    local -a protocols=()
    case "$network_mode" in
        ipv4-only|dual-stack) default_argo="false" ;;
        ipv6-only) default_argo="true" ;;
        *) warn "未确认网络类型，无法设置安装默认协议"; return 1 ;;
    esac
    while true; do
        menu_header "安装节点 / 2. 选择协议"
        menu_section "基础协议"
        echo "  网络类型: ${network_mode}"
        echo "  [✓] Reality (基础功能)"
        menu_section "可选协议 · 可多选，如 1,3"
        menu_item 1 "Argo 隧道"
        menu_item 2 "SOCKS5 代理"
        menu_item 3 "Hysteria2" "UDP 直连"
        menu_item 4 "仅 Reality" "不启用可选协议"
        [[ "$network_mode" == "ipv6-only" ]] && echo "  本地只有 IPv4 时需启用 Argo，并使用 Argo 节点。"
        echo "  Enter 使用推荐组合 ($( [[ "$default_argo" == true ]] && printf 'Reality + Argo' || printf '仅 Reality' ))。"
        menu_back "取消安装"
        prompt_read choice "  请选择协议: " || return 1
        choice="${choice//[[:space:]]/}"
        choice="${choice//，/,}"
        selected_argo=false; selected_socks=false; selected_hy2=false
        case "$choice" in
            "") selected_argo="$default_argo" ;;
            0) return 1 ;;
            4) ;;
            *)
                if [[ ! "$choice" =~ ^[123](,[123]){0,2}$ ]]; then
                    warn "请选择 1、2、3 的组合，或输入 4 仅使用 Reality"
                    continue
                fi
                IFS=, read -r -a protocols <<< "$choice"
                valid=true
                for protocol in "${protocols[@]}"; do
                    case "$protocol" in
                        1) [[ "$selected_argo" == true ]] && valid=false; selected_argo=true ;;
                        2) [[ "$selected_socks" == true ]] && valid=false; selected_socks=true ;;
                        3) [[ "$selected_hy2" == true ]] && valid=false; selected_hy2=true ;;
                    esac
                done
                if [[ "$valid" != true ]]; then
                    warn "同一协议只需选择一次"
                    continue
                fi
                ;;
        esac
        ARGO_ENABLED="$selected_argo"
        SOCKS_ENABLED="$selected_socks"
        HY2_ENABLED="$selected_hy2"
        return 0
    done
}

detect_install_network() {
    local choice
    while true; do
        reset_public_ip_cache
        if refresh_public_ip_stack; then
            INSTALL_NETWORK_MODE="$IP_STACK_MODE"
            return 0
        fi
        warn "公网网络检测失败，请重试或手动指定类型。"
        menu_header "安装节点 / 2. 网络类型"
        menu_section "检测失败 · 手动指定或重试"
        menu_item 1 "重新检测"
        menu_item 2 "IPv4-only"
        menu_item 3 "IPv6-only"
        menu_item 4 "双栈"
        menu_back "取消安装"
        prompt_menu_choice choice "  请选择: " "0 1 2 3 4" || return 1
        case "$choice" in
            0) return 1 ;;
            1) continue ;;
            2) INSTALL_NETWORK_MODE="ipv4-only"; return 0 ;;
            3) INSTALL_NETWORK_MODE="ipv6-only"; return 0 ;;
            4) INSTALL_NETWORK_MODE="dual-stack"; return 0 ;;
            *) warn "请输入 1-4" ;;
        esac
    done
}

# ─── TLS 证书生成 (Hysteria2) ────────────────────────────────
generate_tls_cert() {
    local key_file="${CONFIG_DIR}/server.key"
    local cert_file="${CONFIG_DIR}/server.crt"

    is_hy2_enabled || return 0

    if [[ -f "$key_file" && -f "$cert_file" ]]; then
        info "TLS 证书已存在，跳过生成"
        return
    fi

    if ! command -v openssl &>/dev/null; then
        HY2_ENABLED="false"
        warn "未检测到 openssl，跳过 Hysteria2 证书生成；本次部署将仅启用 Reality / Argo"
        return 0
    fi

    info "生成自签 TLS 证书 (Hysteria2)..."
    if ! openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$key_file" -out "$cert_file" \
        -days 3650 -nodes -subj "/CN=${HY2_SNI}" 2>/dev/null; then
        HY2_ENABLED="false"
        warn "Hysteria2 证书生成失败；本次部署将仅启用 Reality / Argo"
        return 0
    fi
    chmod 600 "$key_file" "$cert_file"
    HY2_ENABLED="true"
    success "TLS 自签证书已生成 (有效期 10 年)"
}

is_hy2_enabled() {
    [[ "${HY2_ENABLED:-false}" == "true" ]]
}

is_socks_enabled() {
    [[ "${SOCKS_ENABLED:-false}" == "true" ]]
}

# ─── 端口 / 防火墙检查 ───────────────────────────────────────
validate_port() {
    local port=$1
    local label=$2

    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        warn "${label} 端口必须是数字: ${port}"
        return 1
    fi
    port="${port#"${port%%[!0]*}"}"
    port="${port:-0}"
    if (( ${#port} > 5 )) || (( 10#$port < 1 || 10#$port > 65535 )); then
        warn "${label} 端口超出范围 (1-65535): ${port}"
        return 1
    fi
    return 0
}

get_port_listeners() {
    local port=$1
    local proto=$2

    if command -v ss &>/dev/null; then
        if [[ "$proto" == "tcp" ]]; then
            ss -H -ltnp "( sport = :${port} )" 2>/dev/null || true
        else
            ss -H -lunp "( sport = :${port} )" 2>/dev/null || true
        fi
        return 0
    fi

    if command -v netstat &>/dev/null; then
        if [[ "$proto" == "tcp" ]]; then
            netstat -lntp 2>/dev/null | awk -v p=":${port}$" '$4 ~ p'
        else
            netstat -lnup 2>/dev/null | awk -v p=":${port}$" '$4 ~ p'
        fi
        return 0
    fi

    if command -v lsof &>/dev/null; then
        if [[ "$proto" == "tcp" ]]; then
            lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null || true
        else
            lsof -nP -iUDP:"$port" 2>/dev/null || true
        fi
        return 0
    fi

    warn "未找到 ss/netstat/lsof，跳过 ${proto^^} 端口占用检查"
    return 0
}

verify_reality_local_listener() {
    local listeners
    if ! command -v ss &>/dev/null && ! command -v netstat &>/dev/null && ! command -v lsof &>/dev/null; then
        warn "无法检测 Reality 本机监听端口：缺少 ss/netstat/lsof"
        return 1
    fi
    listeners=$(get_port_listeners "$REALITY_PORT" tcp)
    if [[ -z "$listeners" ]]; then
        warn "Reality 未在本机 ${REALITY_PORT}/TCP 监听"
        return 1
    fi
}

select_random_available_tcp_port() {
    local candidate listeners reserved conflict

    for _ in $(seq 1 100); do
        candidate=$((10000 + (((RANDOM << 15) | RANDOM) % 55536)))
        case "$candidate" in
            24630) continue ;;
        esac
        conflict=false
        for reserved in "$@"; do
            if [[ -n "$reserved" && "$candidate" == "$reserved" ]]; then
                conflict=true
                break
            fi
        done
        [[ "$conflict" == "false" ]] || continue
        listeners=$(get_port_listeners "$candidate" tcp 2>/dev/null || true)
        [[ -z "$listeners" ]] || continue
        printf '%s\n' "$candidate"
        return 0
    done

    # 极端环境下无法读取监听表时仍给出稳定的高位默认值，后续端口校验会再次确认。
    printf '28805\n'
}

assert_port_available() {
    local port=$1
    local proto=$2
    local label=$3
    local listeners

    listeners=$(get_port_listeners "$port" "$proto")
    if [[ -n "$listeners" ]]; then
        warn "${label} 需要的 ${proto^^} 端口 ${port} 已被占用:"
        echo "$listeners" | head -n 3
        return 1
    fi
    success "${label} 使用的 ${proto^^} 端口 ${port} 当前可绑定"
    return 0
}

detect_firewall_backend() {
    local ufw_status
    local iptables_input

    if command -v ufw &>/dev/null; then
        ufw_status=$(ufw status 2>/dev/null | head -n 1 || true)
        if [[ "$ufw_status" =~ [Ss]tatus:\ active ]]; then
            echo "ufw"
            return 0
        fi
    fi

    if command -v firewall-cmd &>/dev/null; then
        if [[ "$(firewall-cmd --state 2>/dev/null || true)" == "running" ]]; then
            echo "firewalld"
            return 0
        fi
    fi

    if command -v iptables &>/dev/null; then
        iptables_input=$(iptables -S INPUT 2>/dev/null || true)
        if [[ -n "$iptables_input" ]] && echo "$iptables_input" | grep -Eq '^-P INPUT (DROP|REJECT)$|^-A INPUT '; then
            echo "iptables"
            return 0
        fi
    fi

    echo "none"
}

firewall_backend_label() {
    case "$1" in
        ufw) echo "UFW" ;;
        firewalld) echo "firewalld" ;;
        iptables) echo "iptables" ;;
        *) echo "none" ;;
    esac
}

firewall_port_open() {
    local backend=$1
    local port=$2
    local proto=$3

    case "$backend" in
        ufw)
            ufw status 2>/dev/null | grep -Eq "(^|[[:space:]])${port}/${proto}([[:space:]]|$).*ALLOW"
            ;;
        firewalld)
            firewall-cmd --query-port="${port}/${proto}" 2>/dev/null | grep -qx 'yes' || \
                firewall-cmd --permanent --query-port="${port}/${proto}" 2>/dev/null | grep -qx 'yes'
            ;;
        iptables)
            iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null
            ;;
        none)
            return 1
            ;;
        *)
            return 1
            ;;
    esac
}

# ─── 防火墙放行 ──────────────────────────────────────────────
open_firewall() {
    local port=$1
    local backend=$2
    shift 2 || true
    local protocol
    local protocols=("$@")

    if [[ -z "${backend:-}" ]]; then
        backend=$(detect_firewall_backend)
    fi
    if [[ ${#protocols[@]} -eq 0 ]]; then
        protocols=(tcp udp)
    fi

    if [[ "$backend" == "none" ]]; then
        warn "未检测到启用中的 UFW / firewalld / iptables 规则，跳过本机自动放行端口 ${port}"
        return 0
    fi

    info "检测到防火墙方案: $(firewall_backend_label "$backend")，检查端口 ${port} 放行状态"

    for protocol in "${protocols[@]}"; do
        if firewall_port_open "$backend" "$port" "$protocol"; then
            info "端口 ${port}/${protocol} 已放行"
            continue
        fi

        info "放行端口 ${port}/${protocol}..."
        case "$backend" in
            ufw)
                ufw allow "${port}/${protocol}" >/dev/null 2>&1
                ;;
            firewalld)
                firewall-cmd --permanent --add-port="${port}/${protocol}" >/dev/null 2>&1
                firewall-cmd --reload >/dev/null 2>&1
                ;;
            iptables)
                iptables -C INPUT -p "$protocol" --dport "$port" -j ACCEPT 2>/dev/null || \
                    iptables -I INPUT -p "$protocol" --dport "$port" -j ACCEPT >/dev/null 2>&1
                ;;
        esac

        if firewall_port_open "$backend" "$port" "$protocol"; then
            success "端口 ${port}/${protocol} 已通过 $(firewall_backend_label "$backend") 放行"
        else
            warn "端口 ${port}/${protocol} 放行失败，请手动检查 $(firewall_backend_label "$backend") 规则"
            return 1
        fi
    done

    return 0
}

open_service_ports() {
    local backend
    backend=$(detect_firewall_backend)

    [[ -n "${REALITY_PORT:-}" ]] && open_firewall "$REALITY_PORT" "$backend" tcp || return 1
    if is_hy2_enabled && [[ -n "${HY2_PORT:-}" ]]; then
        open_firewall "$HY2_PORT" "$backend" udp || return 1
    fi
    if is_socks_enabled && [[ -n "${SOCKS_PORT:-}" ]]; then
        open_firewall "$SOCKS_PORT" "$backend" tcp || return 1
    fi
    return 0
}

validate_service_ports() {
    local old_reality_port=${1:-}
    local old_hy2_port=${2:-}
    local old_subscription_port=${3:-}
    local should_open_firewall=${4:-true}
    local old_socks_port=${5:-}

    validate_port "${REALITY_PORT:-}" "Reality" || return 1
    if argo_enabled; then
        validate_port "${WS_PORT:-}" "VLESS-WS" || return 1
    fi
    if is_hy2_enabled; then
        validate_port "${HY2_PORT:-}" "Hysteria2" || return 1
    fi
    if is_socks_enabled; then
        validate_port "${SOCKS_PORT:-}" "SOCKS5" || return 1
    fi
    if argo_enabled; then
        validate_port "${SUBSCRIPTION_PORT:-}" "订阅服务" || return 1
    fi

    if argo_enabled && [[ "${REALITY_PORT}" == "${WS_PORT}" ]]; then
        warn "Reality 端口 ${REALITY_PORT}/TCP 与 VLESS-WS 内部端口 ${WS_PORT}/TCP 冲突"
        return 1
    fi
    if argo_enabled && [[ "${SUBSCRIPTION_PORT}" == "${REALITY_PORT}" || "${SUBSCRIPTION_PORT}" == "${WS_PORT}" ]]; then
        warn "订阅服务端口 ${SUBSCRIPTION_PORT}/TCP 与现有 TCP 服务端口冲突"
        return 1
    fi
    if is_socks_enabled; then
        if [[ "${SOCKS_PORT}" == "${REALITY_PORT}" ]]; then
            warn "SOCKS5 端口 ${SOCKS_PORT}/TCP 与 Reality 端口冲突"
            return 1
        fi
        if argo_enabled && [[ "${SOCKS_PORT}" == "${WS_PORT}" || "${SOCKS_PORT}" == "${SUBSCRIPTION_PORT}" ]]; then
            warn "SOCKS5 端口 ${SOCKS_PORT}/TCP 与现有 TCP 服务端口冲突"
            return 1
        fi
    fi

    if [[ -z "$old_reality_port" || "$REALITY_PORT" != "$old_reality_port" ]]; then
        assert_port_available "$REALITY_PORT" "tcp" "Reality" || return 1
    else
        info "Reality 端口未变化，跳过占用检查"
    fi

    if is_hy2_enabled && [[ -z "$old_hy2_port" || "$HY2_PORT" != "$old_hy2_port" ]]; then
        assert_port_available "$HY2_PORT" "udp" "Hysteria2" || return 1
    elif is_hy2_enabled; then
        info "Hysteria2 端口未变化，跳过占用检查"
    fi

    if argo_enabled && [[ -z "$old_reality_port" ]]; then
        assert_port_available "$WS_PORT" "tcp" "VLESS-WS" || return 1
    fi

    if argo_enabled; then
        if [[ -z "$old_subscription_port" || "$SUBSCRIPTION_PORT" != "$old_subscription_port" ]]; then
            assert_port_available "$SUBSCRIPTION_PORT" "tcp" "订阅服务" || return 1
        else
            info "订阅服务端口未变化，跳过占用检查"
        fi
    fi

    if is_socks_enabled; then
        if [[ -z "$old_socks_port" || "$SOCKS_PORT" != "$old_socks_port" ]]; then
            assert_port_available "$SOCKS_PORT" "tcp" "SOCKS5" || return 1
        else
            info "SOCKS5 端口未变化，跳过占用检查"
        fi
    fi

    if [[ "$should_open_firewall" == "true" ]]; then
        open_service_ports || return 1
    fi
    return 0
}

prompt_port_value() {
    local __var_name=$1
    local label=$2
    local current=$3
    local prompt=$4
    local allow_cancel=${5:-false}
    local input candidate

    while true; do
        prompt_read input "$prompt" || return 1
        if [[ "$allow_cancel" == true && "$input" == 0 ]]; then return 1; fi
        candidate="${input:-$current}"
        if validate_port "$candidate" "$label"; then
            candidate="${candidate#"${candidate%%[!0]*}"}"
            printf -v "$__var_name" '%s' "$candidate"
            return 0
        fi
        warn "请重新输入 ${label} 端口"
    done
}

prompt_hy2_port() {
    prompt_port_value "$1" "Hysteria2" "$HY2_PORT" \
        "  本机 UDP 端口 [${HY2_PORT}]，输入 0 返回: " true
}

show_port_confirmation() {
    menu_header "${PORT_CONFIRM_TITLE:-安装节点 / 3. 端口确认}"
    menu_section "本机监听"
    echo -e "  Reality:      ${BOLD}${REALITY_PORT}/TCP${NC}"
    if ! is_hy2_enabled; then
        echo -e "  Hysteria2:    ${DIM}未启用${NC}"
    elif [[ "${HY2_PORT}" == "${REALITY_PORT}" ]]; then
        echo -e "  Hysteria2:    ${BOLD}${HY2_PORT}/UDP${NC} ${DIM}(与 Reality 共用端口号，协议不同)${NC}"
    else
        echo -e "  Hysteria2:    ${BOLD}${HY2_PORT}/UDP${NC}"
    fi
    if is_socks_enabled; then
        echo -e "  SOCKS5:       ${BOLD}${SOCKS_PORT}/TCP${NC}"
    else
        echo -e "  SOCKS5:       ${DIM}未启用${NC}"
    fi
    if argo_enabled; then
        menu_section "订阅"
        echo -e "  订阅服务:     ${BOLD}${SUBSCRIPTION_PORT}/TCP${NC} ${DIM}(仅本机/Argo 使用)${NC}"
    fi
    menu_section "本机防火墙"
    echo -e "  监听端口: ${BOLD}${REALITY_PORT}/TCP${NC}$(is_hy2_enabled && printf ', %s/UDP' "$HY2_PORT")$(is_socks_enabled && printf ', %s/TCP' "$SOCKS_PORT")"
    echo ""
}

confirm_port_selection() {
    local input

    show_port_confirmation
    while true; do
        prompt_read input "  按 Enter 确认，输入 0 返回修改: " || return 1
        case "$input" in
            "") return 0 ;;
            0|r|R) return 1 ;;
            *) warn "请按 Enter 确认，或输入 0 返回修改" ;;
        esac
    done
}

public_ipv4_override_label() {
    if [[ -n "${PUBLIC_IPV4_OVERRIDE:-}" ]]; then
        printf '%s' "$PUBLIC_IPV4_OVERRIDE"
    else
        printf '自动检测'
    fi
}

prompt_public_ipv4_override_optional() {
    local input

    while true; do
        prompt_read input "  请输入用于直连链接的公网 IPv4 (留空跳过): " || return 1
        [[ -z "$input" ]] && return 1
        if is_valid_public_ipv4_for_link "$input"; then
            PUBLIC_IPV4_OVERRIDE="$input"
            LINK_IPV4_SELECTION="all"
            reset_public_ip_cache
            success "已设置直连公网 IPv4 覆盖: ${PUBLIC_IPV4_OVERRIDE}"
            return 0
        fi
        warn "无效的公网 IPv4。请勿填写私网、回环、CGNAT、多播或保留地址。"
    done
}

prompt_public_ipv4_override() {
    local choice input

    menu_header "网络设置 / 直连公网 IPv4"
    menu_section "当前覆盖值: $(public_ipv4_override_label)"
    echo -e "  ${DIM}该值仅用于生成 Reality/Hysteria2 直连分享链接和订阅内容，不会修改服务端监听配置。${NC}"
    menu_item 1 "设置或修改覆盖 IPv4"
    menu_item 2 "清除覆盖并恢复自动检测"
    menu_back "取消"
    prompt_menu_choice choice "  请选择 [0]: " "0 1 2" 0 || return 1

    case "$choice" in
        1)
            while true; do
                prompt_read input "  请输入用于直连链接的公网 IPv4: " || return 1
                if is_valid_public_ipv4_for_link "$input"; then
                    PUBLIC_IPV4_OVERRIDE="$input"
                    LINK_IPV4_SELECTION="all"
                    reset_public_ip_cache
                    success "已设置直连公网 IPv4 覆盖: ${PUBLIC_IPV4_OVERRIDE}"
                    return 0
                fi
                warn "无效的公网 IPv4。请勿填写私网、回环、CGNAT、多播或保留地址。"
            done
            ;;
        2)
            PUBLIC_IPV4_OVERRIDE=""
            LINK_IPV4_SELECTION="all"
            reset_public_ip_cache
            success "已清除直连公网 IPv4 覆盖，恢复自动检测。"
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# 返回 1 表示取消或 EOF，返回 2 表示当前没有可用的多 IPv4 选择。
prompt_ipv4_link_selection_if_multiple() {
    local count input index ip selected all_option default_option=1 choices="0"

    if [[ -n "${PUBLIC_IPV4_OVERRIDE:-}" ]]; then
        warn "当前已设置直连公网 IPv4 覆盖，多 IPv4 链接策略暂不生效。请先清除覆盖值。"
        return 2
    fi
    refresh_public_ip_stack || return 2
    count=$(public_ipv4_candidate_count)
    if (( count <= 1 )); then
        return 2
    fi

    menu_header "多 IPv4 链接策略"
    menu_section "检测到多个 IPv4"
    echo -e "  检测到多个 IPv4: ${BOLD}$(public_ipv4_display)${NC}"
    index=1
    while IFS= read -r ip; do
        [[ -n "$ip" ]] || continue
        if [[ "$ip" == "${LINK_IPV4_SELECTION:-all}" ]]; then
            default_option=$index
        fi
        if [[ "$ip" == "${LINK_IPV4_SELECTION:-all}" ]]; then
            menu_item "$index" "仅启用 ${ip}" "当前"
        elif (( index == 1 )); then
            menu_item "$index" "仅启用 ${ip}" "推荐"
        else
            menu_item "$index" "仅启用 ${ip}"
        fi
        choices+=" $index"
        index=$((index + 1))
    done <<< "$PUBLIC_IPV4_LIST"
    all_option=$index
    menu_item "$all_option" "全部启用" "$( [[ "${LINK_IPV4_SELECTION:-all}" == all ]] && printf '当前' || true )"
    choices+=" $all_option"
    [[ "${LINK_IPV4_SELECTION:-all}" == all ]] && default_option=$all_option
    menu_back
    prompt_menu_choice input "  请选择 [${default_option}]: " "$choices" "$default_option" || return 1
    [[ "$input" == 0 ]] && return 1

    if (( input < all_option )); then
        selected=$(printf '%s\n' "$PUBLIC_IPV4_LIST" | sed -n "${input}p")
        LINK_IPV4_SELECTION="$selected"
    elif [[ "$input" == "$all_option" ]]; then
        LINK_IPV4_SELECTION="all"
    fi

    info "已选择 IPv4 链接策略: $(link_ipv4_selection_label)"
    return 0
}

show_external_access_requirements() {
    menu_section "本机监听"
    echo -e "  Reality:      ${BOLD}${REALITY_PORT}/TCP${NC}"
    if is_hy2_enabled; then
        echo -e "  Hysteria2:    ${BOLD}${HY2_PORT}/UDP${NC}"
    else
        echo -e "  Hysteria2:    ${DIM}未启用${NC}"
    fi
    if is_socks_enabled; then
        echo -e "  SOCKS5:       ${BOLD}${SOCKS_PORT}/TCP${NC}"
    else
        echo -e "  SOCKS5:       ${DIM}未启用${NC}"
    fi
    if argo_enabled; then
        echo -e "  订阅服务:     ${BOLD}127.0.0.1:${SUBSCRIPTION_PORT}/TCP${NC}"
    fi
    echo ""
}

# ─── sing-box 配置生成 ───────────────────────────────────────
write_singbox_config() {
    # 关键变量校验: 防止空值写入配置导致 sing-box 崩溃
    local missing=""
    [[ -z "${UUID:-}" ]]        && missing+="UUID "
    [[ -z "${REALITY_PORT:-}" ]] && missing+="REALITY_PORT "
    [[ -z "${REALITY_SNI:-}" ]] && missing+="REALITY_SNI "
    [[ -z "${PRIVATE_KEY:-}" ]] && missing+="PRIVATE_KEY "
    [[ -z "${SHORT_ID:-}" ]]    && missing+="SHORT_ID "
    if argo_enabled; then
        [[ -z "${WS_PORT:-}" ]] && missing+="WS_PORT "
        [[ -z "${WS_PATH:-}" ]] && missing+="WS_PATH "
    fi
    if is_hy2_enabled; then
        [[ -z "${HY2_PORT:-}" ]]    && missing+="HY2_PORT "
        [[ -z "${HY2_PASSWORD:-}" ]] && missing+="HY2_PASSWORD "
        [[ -z "${HY2_SNI:-}" ]]     && missing+="HY2_SNI "
    fi
    if is_socks_enabled; then
        [[ -z "${SOCKS_PORT:-}" ]]     && missing+="SOCKS_PORT "
        [[ -z "${SOCKS_USERNAME:-}" ]] && missing+="SOCKS_USERNAME "
        [[ -z "${SOCKS_PASSWORD:-}" ]] && missing+="SOCKS_PASSWORD "
    fi
    if [[ -n "$missing" ]]; then
        error "配置生成失败: 以下关键变量为空: ${missing}"
    fi
    local outbound_ip_strategy="${OUTBOUND_IP_STRATEGY:-default}"
    if ! is_valid_outbound_ip_strategy "$outbound_ip_strategy"; then
        error "配置生成失败: 无效的出站 IP 优先级: ${outbound_ip_strategy}"
    fi

    local json_uuid json_reality_sni json_private_key json_short_id json_ws_path argo_inbound hy2_inbound
    local json_hy2_password json_hy2_sni json_key_path json_cert_path
    local json_socks_username json_socks_password socks_inbound
    local reality_inbound inbounds_joined inbound_part

    json_uuid=$(json_string "$UUID")
    json_reality_sni=$(json_string "$REALITY_SNI")
    json_private_key=$(json_string "$PRIVATE_KEY")
    json_short_id=$(json_string "$SHORT_ID")
    argo_inbound=""
    if argo_enabled; then
        json_ws_path=$(json_string "$WS_PATH")
        argo_inbound=$(cat << ARGO_EOF
        {
            "type": "vless",
            "tag": "vless-ws-argo",
            "listen": "127.0.0.1",
            "listen_port": ${WS_PORT},
            "users": [
                {
                    "uuid": ${json_uuid}
                }
            ],
            "transport": {
                "type": "ws",
                "path": ${json_ws_path}
            }
        }
ARGO_EOF
)
    fi
    hy2_inbound=""
    if is_hy2_enabled; then
        json_hy2_password=$(json_string "$HY2_PASSWORD")
        json_hy2_sni=$(json_string "$HY2_SNI")
        json_key_path=$(json_string "${CONFIG_DIR}/server.key")
        json_cert_path=$(json_string "${CONFIG_DIR}/server.crt")
        hy2_inbound=$(cat << HY2_EOF
        {
            "type": "hysteria2",
            "tag": "hysteria2-in",
            "listen": "::",
            "listen_port": ${HY2_PORT},
            "up_mbps": 100,
            "down_mbps": 100,
            "users": [
                {
                    "password": ${json_hy2_password}
                }
            ],
            "tls": {
                "enabled": true,
                "server_name": ${json_hy2_sni},
                "key_path": ${json_key_path},
                "certificate_path": ${json_cert_path}
            },
            "masquerade": {
                "type": "string",
                "status_code": 404,
                "headers": {
                    "content-type": "text/plain; charset=utf-8",
                    "cache-control": "no-store"
                },
                "content": "Not Found\n"
            }
        }
HY2_EOF
)
    fi

    socks_inbound=""
    if is_socks_enabled; then
        json_socks_username=$(json_string "$SOCKS_USERNAME")
        json_socks_password=$(json_string "$SOCKS_PASSWORD")
        socks_inbound=$(cat << SOCKS_EOF
        {
            "type": "socks",
            "tag": "socks5-in",
            "listen": "::",
            "listen_port": ${SOCKS_PORT},
            "users": [
                {
                    "username": ${json_socks_username},
                    "password": ${json_socks_password}
                }
            ]
        }
SOCKS_EOF
)
    fi

    # Reality 入站：仅当 Reality 由 sing-box 自己承载时才写入。
    # REALITY_BACKEND=xray 时该入站交给 Xray-core，sing-box 让出该端口。
    reality_inbound=""
    if [[ "${REALITY_BACKEND:-singbox}" != "xray" ]]; then
        reality_inbound=$(cat << REALITY_EOF
        {
            "type": "vless",
            "tag": "vless-reality",
            "listen": "::",
            "listen_port": ${REALITY_PORT},
            "users": [
                {
                    "uuid": ${json_uuid},
                    "flow": "xtls-rprx-vision"
                }
            ],
            "tls": {
                "enabled": true,
                "server_name": ${json_reality_sni},
                "reality": {
                    "enabled": true,
                    "handshake": {
                        "server": ${json_reality_sni},
                        "server_port": 443
                    },
                    "private_key": ${json_private_key},
                    "short_id": [
                        ${json_short_id}
                    ]
                }
            }
        }
REALITY_EOF
)
    fi

    # 按顺序拼接非空入站，自动处理逗号，避免首项缺失时产生非法 JSON。
    inbounds_joined=""
    for inbound_part in "$reality_inbound" "$argo_inbound" "$hy2_inbound" "$socks_inbound"; do
        [[ -n "$inbound_part" ]] || continue
        if [[ -z "$inbounds_joined" ]]; then
            inbounds_joined="$inbound_part"
        else
            inbounds_joined="${inbounds_joined},"$'\n'"$inbound_part"
        fi
    done

    # 出站 IP 优先级：sing-box 1.12+ 已移除 direct.domain_strategy，
    # 改为 domain_resolver 指向本机系统 DNS 并携带 strategy。
    local dns_section="" direct_resolver=""
    if [[ "$outbound_ip_strategy" != "default" ]]; then
        dns_section=$(cat << DNS_EOF

    "dns": {
        "servers": [
            {
                "type": "local",
                "tag": "local"
            }
        ]
    },
DNS_EOF
)
        direct_resolver=$(cat << RESOLVER_EOF
,
            "domain_resolver": {
                "server": "local",
                "strategy": "${outbound_ip_strategy}"
            }
RESOLVER_EOF
)
    fi

    cat > "$CONFIG_FILE" << SINGBOX_EOF
{
    "log": {
        "level": "warn",
        "timestamp": true
    },
    "inbounds": [
${inbounds_joined}
    ],${dns_section}
    "outbounds": [
        {
            "type": "direct",
            "tag": "direct"${direct_resolver}
        },
        {
            "type": "block",
            "tag": "block"
        }
    ]
}
SINGBOX_EOF

    chmod 600 "$CONFIG_FILE"
    chown root:root "$CONFIG_FILE"

    local check_output
    if check_output=$(run_singbox check -c "$CONFIG_FILE" 2>&1); then
        success "配置校验通过"
    else
        warn "配置校验失败，详细信息:"
        echo -e "${RED}${check_output}${NC}"
        error "请检查上方错误并修复后重试"
    fi
}

systemd_hardening_block() {
    cat <<'EOF'
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
SystemCallArchitectures=native
EOF
}
# ─── Argo 服务 ───────────────────────────────────────────────
ensure_argo_dependencies() {
    if ! command -v python3 >/dev/null 2>&1; then
        info "安装 Argo 订阅网关依赖: python3"
        install_packages_low_resource python3 || {
            warn "python3 安装失败，Argo 订阅网关无法运行"
            return 1
        }
    fi
    install_cloudflared
}

quick_tunnel_config_conflict() {
    local config
    for config in "${HOME:-/root}/.cloudflared/config.yaml" \
        "/root/.cloudflared/config.yaml" "/etc/cloudflared/config.yaml" "/.cloudflared/config.yaml"; do
        if [[ -f "$config" ]]; then
            warn "临时隧道与已有 cloudflared 配置冲突: ${config}；未修改该文件"
            return 0
        fi
    done
    return 1
}

write_argo_service() {
    local cloudflared_bin exec_cmd argo_origin_url systemd_hardening edge_ip_version="auto"
    if ! argo_enabled; then
        warn "Argo 未启用"
        return 1
    fi
    cloudflared_bin=$(command -v cloudflared 2>/dev/null || echo "/usr/local/bin/cloudflared")
    argo_origin_url="http://127.0.0.1:${SUBSCRIPTION_PORT}"
    # auto 同时适配旧配置刷新与双栈；纯 IPv6 安装显式使用 IPv6。
    if [[ "${IP_STACK_MODE:-${INSTALL_NETWORK_MODE:-}}" == "ipv6-only" ]]; then
        edge_ip_version="6"
    fi
    if argo_fixed_enabled; then
        info "使用固定域名启动 Argo 隧道"
        info "Cloudflare Public Hostname 需转发至 ${argo_origin_url}"
        write_env_file "$ARGO_ENV_FILE" ARGO_TOKEN "$ARGO_TOKEN" TUNNEL_TOKEN "$ARGO_TOKEN"
        exec_cmd="tunnel --protocol http2 --no-autoupdate --edge-ip-version ${edge_ip_version} run"
    else
        quick_tunnel_config_conflict && return 1
        info "使用 Argo 临时隧道 (trycloudflare.com)"
        rm -f "$ARGO_ENV_FILE"
        exec_cmd="tunnel --url ${argo_origin_url} --no-autoupdate --protocol http2 --edge-ip-version ${edge_ip_version}"
    fi

    if [[ "$(service_manager)" == "openrc" ]]; then
        prepare_openrc_supervision argo-tunnel "$ARGO_OPENRC_SERVICE" || return 1
        cat > "$ARGO_OPENRC_SERVICE" << EOF || return 1
#!/sbin/openrc-run
name="argo-tunnel"
description="Cloudflare Argo Tunnel"
command="${cloudflared_bin}"
command_args="${exec_cmd}"
$(openrc_supervision_block)
pidfile="/run/argo-tunnel.pid"
output_log="/var/log/argo-tunnel.log"
error_log="/var/log/argo-tunnel.log"
EOF
        if argo_fixed_enabled; then
            cat >> "$ARGO_OPENRC_SERVICE" << EOF || return 1
env_file="${ARGO_ENV_FILE}"
start_pre() {
    if [ -r "\${env_file}" ]; then
        set -a
        . "\${env_file}"
        set +a
    fi
}
EOF
        fi
        cat >> "$ARGO_OPENRC_SERVICE" << 'EOF' || return 1

depend() {
    need net
    after sing-box
}
EOF
        chmod 755 "$ARGO_OPENRC_SERVICE"
        return
    fi

    systemd_hardening=$(systemd_hardening_block)
    cat > "$ARGO_SERVICE" << EOF
[Unit]
Description=Cloudflare Argo Tunnel
After=network.target sing-box.service
Wants=sing-box.service

[Service]
Type=simple
User=nobody
EOF
    argo_fixed_enabled && printf 'EnvironmentFile=%s\n' "$ARGO_ENV_FILE" >> "$ARGO_SERVICE"
    cat >> "$ARGO_SERVICE" << EOF
ExecStart=${cloudflared_bin} ${exec_cmd}
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
${systemd_hardening}

[Install]
WantedBy=multi-user.target
EOF
    service_daemon_reload
}

# ─── 订阅服务 ────────────────────────────────────────────────
write_subscription_server() {
    cat > "$SUBSCRIPTION_SERVER" << 'PYEOF'
#!/usr/bin/env python3
import argparse
import os
import select
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


def build_handler(token: str, data_file: str, upstream_host: str, upstream_port: int):
    subscription_path = f"/sub/{token}"
    data_path = Path(data_file)

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            parsed = urlparse(self.path)
            query_token = parse_qs(parsed.query).get("token", [""])[0]
            token_ok = parsed.path == subscription_path or (
                parsed.path == "/sub" and query_token == token
            )

            if parsed.path.startswith("/sub"):
                if not token_ok:
                    self.send_response(403)
                    self.send_header("Content-Type", "text/plain; charset=utf-8")
                    self.end_headers()
                    self.wfile.write(b"Forbidden\n")
                    return
            else:
                self.proxy_to_upstream()
                return

            if not data_path.exists():
                self.send_response(503)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.end_headers()
                self.wfile.write(b"Subscription is not ready\n")
                return

            payload = data_path.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def proxy_to_upstream(self):
            self.close_connection = True
            try:
                upstream = socket.create_connection((upstream_host, upstream_port), timeout=10)
            except OSError:
                self.send_response(502)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.end_headers()
                self.wfile.write(b"Upstream is not ready\n")
                return

            with upstream:
                upstream.settimeout(None)
                is_upgrade = self.headers.get("Upgrade", "").lower() == "websocket"
                request_lines = [f"{self.command} {self.path} HTTP/1.1\r\n"]
                for key, value in self.headers.items():
                    lower_key = key.lower()
                    if lower_key in {"host", "connection", "proxy-connection", "keep-alive"}:
                        continue
                    request_lines.append(f"{key}: {value}\r\n")
                request_lines.append(f"Host: {upstream_host}:{upstream_port}\r\n")
                request_lines.append("Connection: Upgrade\r\n" if is_upgrade else "Connection: close\r\n")
                request_lines.append("\r\n")
                upstream.sendall("".join(request_lines).encode("iso-8859-1"))
                self.forward_streams(upstream)

        def forward_streams(self, upstream):
            sockets = [self.connection, upstream]
            while True:
                readable, _, _ = select.select(sockets, [], [], 60)
                if not readable:
                    continue
                for source in readable:
                    chunk = source.recv(65536)
                    if not chunk:
                        return
                    target = upstream if source is self.connection else self.connection
                    target.sendall(chunk)

        def log_message(self, format, *args):
            return

    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--token")
    parser.add_argument("--token-env", default="SUB_TOKEN")
    parser.add_argument("--file", required=True)
    parser.add_argument("--upstream-host", default="127.0.0.1")
    parser.add_argument("--upstream-port", type=int, required=True)
    args = parser.parse_args()

    class Server(ThreadingHTTPServer):
        address_family = socket.AF_INET6 if ":" in args.listen else socket.AF_INET

        def server_bind(self):
            if self.address_family == socket.AF_INET6 and hasattr(socket, "IPV6_V6ONLY"):
                try:
                    self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
                except OSError:
                    pass
            return super().server_bind()

    token = args.token or os.environ.get(args.token_env)
    if not token:
        raise SystemExit("subscription token is required")

    server = Server((args.listen, args.port), build_handler(token, args.file, args.upstream_host, args.upstream_port))
    server.serve_forever()


if __name__ == "__main__":
    main()
PYEOF
    chmod 755 "$SUBSCRIPTION_SERVER"
}

subscription_listen_host() {
    echo "127.0.0.1"
}

write_subscription_service() {
    local listen_host systemd_hardening
    listen_host=$(subscription_listen_host)
    write_env_file "$SUBSCRIPTION_ENV_FILE" SUB_TOKEN "${SUB_TOKEN:-}"

    if [[ "$(service_manager)" == "openrc" ]]; then
        prepare_openrc_supervision sbm-subscription "$SUBSCRIPTION_OPENRC_SERVICE" || return 1
        cat > "$SUBSCRIPTION_OPENRC_SERVICE" << EOF || return 1
#!/sbin/openrc-run
name="sbm-subscription"
description="SBM Subscription Server"
command="/usr/bin/python3"
command_args="${SUBSCRIPTION_SERVER} --listen ${listen_host} --port ${SUBSCRIPTION_PORT} --file ${SUBSCRIPTION_FILE} --upstream-host 127.0.0.1 --upstream-port ${WS_PORT}"
$(openrc_supervision_block)
pidfile="/run/sbm-subscription.pid"
output_log="/var/log/sbm-subscription.log"
error_log="/var/log/sbm-subscription.log"
env_file="${SUBSCRIPTION_ENV_FILE}"

start_pre() {
    if [ -r "\${env_file}" ]; then
        set -a
        . "\${env_file}"
        set +a
    fi
}

depend() {
    need net
}
EOF
        chmod 755 "$SUBSCRIPTION_OPENRC_SERVICE"
        return
    fi

    systemd_hardening=$(systemd_hardening_block)
    cat > "$SUBSCRIPTION_SERVICE" << EOF
[Unit]
Description=SBM Subscription Server
After=network.target

[Service]
Type=simple
EnvironmentFile=${SUBSCRIPTION_ENV_FILE}
ExecStart=/usr/bin/env python3 ${SUBSCRIPTION_SERVER} --listen ${listen_host} --port ${SUBSCRIPTION_PORT} --file ${SUBSCRIPTION_FILE} --upstream-host 127.0.0.1 --upstream-port ${WS_PORT}
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
${systemd_hardening}

[Install]
WantedBy=multi-user.target
EOF
    service_daemon_reload
}

ensure_subscription_service() {
    validate_port "${SUBSCRIPTION_PORT}" "订阅服务" || return 1
    if ! command -v python3 &>/dev/null; then
        warn "未检测到 python3，无法启动订阅服务"
        return 1
    fi

    write_subscription_server || return 1
    write_subscription_service || return 1

    service_enable_now sbm-subscription
}

ensure_subscription_service_if_enabled() {
    argo_enabled || return 0
    ensure_subscription_service
}

argo_quick_domain_alive() {
    local domain="$1" code
    is_valid_hostname "$domain" || return 1
    code=$(curl -so /dev/null --connect-timeout 3 --max-time 6 -w '%{http_code}' \
        "https://${domain}/" 2>/dev/null || true)
    case "$code" in
        ''|000|52[0-9]|53[0-9]) return 1 ;;
        *) return 0 ;;
    esac
}

argo_quick_startup_hint() {
    local logs="$1"
    if [[ -z "$logs" ]]; then
        warn "Argo 隧道日志为空或不可读，请检查服务是否启动及日志权限"
    elif printf '%s\n' "$logs" | grep -Ei 'no such host|server misbehaving|DNS query failed|error looking up|lookup .*(:53|timeout|refused)' >/dev/null; then
        warn "cloudflared 出现 DNS 解析错误，请检查系统 DNS 能否解析 api.trycloudflare.com 和 argotunnel.com 的 SRV 记录"
    elif printf '%s\n' "$logs" | grep -Ei 'x509:|TLS handshake|tls: failed' >/dev/null; then
        warn "cloudflared 出现 TLS 错误，请检查系统时间、CA 证书及 api.trycloudflare.com:443 的连通性"
    elif printf '%s\n' "$logs" | grep -Ei '429|too many requests' >/dev/null; then
        warn "Cloudflare 临时隧道申请被限流，请稍后重试，避免频繁重启隧道"
    elif printf '%s\n' "$logs" | grep -Ei 'flag provided but not defined|unknown flag|Incorrect Usage' >/dev/null; then
        warn "cloudflared 启动参数不受当前版本支持，请更新 cloudflared 后重试"
    elif printf '%s\n' "$logs" | grep -Ei 'failed to request quick Tunnel|quick tunnel provisioning failed|failed to (unmarshal|read|parse) quick Tunnel' >/dev/null; then
        warn "Cloudflare 临时隧道申请失败，请检查 api.trycloudflare.com:443 的出站连接及 Cloudflare 服务状态"
    else
        warn "cloudflared 尚未输出临时域名，请检查隧道启动日志"
    fi
    case "$(service_manager)" in
        systemd) warn "查看日志: journalctl -u argo-tunnel -n 80 --no-pager" ;;
        openrc) warn "查看日志: tail -n 80 /var/log/argo-tunnel.log" ;;
    esac
}

fetch_argo_domain() {
    local max=30 i=0 candidate="" logs="" previous_domain="${ARGO_DOMAIN:-}"

    argo_quick_enabled || return 0
    ARGO_DOMAIN=""
    while (( i < max )); do
        # OpenRC 日志会跨重启追加；从最后一次申请开始读取，排除历史域名。
        logs=$(service_logs argo-tunnel 1000 current 2>/dev/null | \
            awk '/Requesting new quick Tunnel/ { logs = "" } { logs = logs $0 "\n" } END { printf "%s", logs }') || true
        candidate=$(printf '%s\n' "$logs" | \
            grep -Eo 'https://[[:alnum:]-]+\.trycloudflare\.com' | \
            grep -Ev '^https://(api|www)\.trycloudflare\.com$' | \
            tail -1 | sed 's|https://||') || true
        # 域名分配与公网可达是两个阶段。DNS/边缘尚未就绪或 VPS 无法回访
        # 域名时仍可提取结果；后续 WebSocket 握手负责验证节点可用性。
        if [[ -n "$candidate" ]] && is_valid_hostname "$candidate"; then
            ARGO_DOMAIN="$candidate"
            [[ "$ARGO_DOMAIN" == "$previous_domain" ]] || clear_argo_best_cf_cache
            return 0
        fi
        i=$((i + 1))
        if (( i < max )); then sleep 2; fi
    done

    ARGO_DOMAIN="$previous_domain"
    warn "等待 Argo 临时域名超时（约 60 秒）"
    argo_quick_startup_hint "$logs"
    return 1
}

refresh_argo_domain_if_needed() {
    argo_quick_enabled || return 0
    service_is_active argo-tunnel || return 0
    if [[ -n "${ARGO_DOMAIN:-}" ]] && argo_quick_domain_alive "$ARGO_DOMAIN"; then
        return 0
    fi
    if fetch_argo_domain; then
        save_params
    fi
    return 0
}

refresh_argo_runtime() {
    if ! argo_enabled; then
        service_stop argo-tunnel 2>/dev/null || true
        service_disable argo-tunnel 2>/dev/null || true
        service_stop sbm-subscription 2>/dev/null || true
        service_disable sbm-subscription 2>/dev/null || true
        ARGO_ENABLED="false"
        ARGO_TOKEN=""
        ARGO_DOMAIN=""
        rm -f "$ARGO_ENV_FILE"
        clear_argo_best_cf_cache
        save_params
        return 0
    fi

    if argo_quick_enabled && quick_tunnel_config_conflict; then
        return 1
    fi
    ensure_argo_dependencies || return 1
    # 源站先可用，再启动隧道并校验临时域名。
    ensure_subscription_service_if_enabled || return 1
    write_argo_service || return 1
    if service_is_active argo-tunnel; then
        service_restart argo-tunnel || return 1
    elif ! service_enable_now argo-tunnel; then
        warn "argo-tunnel 重启失败，无法更新 Argo 订阅链接"
        return 1
    fi
    if ! service_is_active argo-tunnel; then
        warn "Argo 隧道未运行，未更新订阅链接"
        return 1
    fi

    if argo_quick_enabled; then
        sleep 3
        fetch_argo_domain || return 1
    fi

    save_params
    return 0
}

update_argo_subscription_links() {
    if ! argo_enabled; then
        warn "当前未启用 Argo"
        return 1
    fi
    refresh_argo_runtime || return 1
    generate_and_show_links
    if [[ -z "${GENERATED_ARGO_LINKS:-}" ]]; then
        warn "Argo 节点链接未通过探测，链接更新未完成"
        return 1
    fi
    service_is_active argo-tunnel || { warn "Argo 隧道未运行，链接更新未完成"; return 1; }
    service_is_active sbm-subscription || { warn "订阅服务未运行，链接更新未完成"; return 1; }
    success "Argo 订阅链接已更新；公网连接仍需验证"
    show_subscription_url
}
# ─── Reality 优选 SNI ────────────────────────────────────────
ensure_reality_probe_dependencies() {
    if ! command -v curl >/dev/null 2>&1 || ! reality_curl_supports_h2; then
        warn "Reality 域名检查需要支持 HTTP/2 的 curl，当前环境不满足"
        return 1
    fi
    return 0
}

get_reality_probe_parallelism() {
    local cpu_count profile
    cpu_count=$(get_cpu_count)
    profile=$(get_resource_profile)

    if [[ "$profile" == "low-noswap" ]]; then
        echo 1
    elif (( cpu_count <= 1 )); then
        echo 1
    elif (( cpu_count <= 2 )); then
        echo 3
    else
        echo 6
    fi
}

# 本机 curl 是否支持 HTTP/2(Schannel / 无 nghttp2 的精简版不支持)。
reality_curl_supports_h2() {
    curl --version 2>/dev/null | grep -qiw HTTP2
}

reality_sni_is_listed() {
    local requested="${1:-}" candidate
    is_valid_hostname "$requested" || return 1
    for candidate in "${REALITY_SNI_LIST[@]}"; do
        [[ "$requested" == "$candidate" ]] && return 0
    done
    return 1
}

# 内置列表之外只认 REALITY_SNI_CUSTOM：用户手动指定或邻居扫描选出、且已通过严格检查的那一个域名。
reality_sni_is_approved() {
    local requested="${1:-}"
    is_valid_hostname "$requested" || return 1
    [[ -n "${REALITY_SNI_CUSTOM:-}" && "$requested" == "$REALITY_SNI_CUSTOM" ]] && return 0
    reality_sni_is_listed "$requested"
}

is_cloudflare_address() {
    local ip="${1:-}" a b c
    case "${ip,,}" in
        2400:cb00:*|2606:4700:*|2803:f800:*|2405:b500:*|2405:8100:*|2a06:98c[0-7]:*|2c0f:f248:*) return 0 ;;
    esac
    is_valid_ipv4 "$ip" || return 1
    IFS=. read -r a b c _ <<< "$ip"
    case "$a.$b" in
        173.245) (( c >= 48 && c <= 63 )) ;;
        103.21)  (( c >= 244 && c <= 247 )) ;;
        103.22)  (( c >= 200 && c <= 203 )) ;;
        103.31)  (( c >= 4 && c <= 7 )) ;;
        141.101) (( c >= 64 && c <= 127 )) ;;
        108.162) (( c >= 192 )) ;;
        190.93)  (( c >= 240 )) ;;
        188.114) (( c >= 96 && c <= 111 )) ;;
        197.234) (( c >= 240 && c <= 243 )) ;;
        198.41)  (( c >= 128 )) ;;
        162.158|162.159) return 0 ;;
        104.*)   (( b >= 16 && b <= 27 )) ;;
        172.*)   (( b >= 64 && b <= 71 )) ;;
        131.0)   (( c >= 72 && c <= 75 )) ;;
        *)       return 1 ;;
    esac
}

# 参数 5 strict=1 时还要求直接返回 HTTP 200，用于内置列表之外的域名。
# 参数 6 networks 非空时只走 IPv4，连接地址必须落在这些网段内且不在参数 7 own_ips 中，用于邻居扫描。
probe_reality_sni_candidate() {
    local idx="$1" sni="$2" result_file="$3" require_h2="${4:-1}" strict="${5:-0}"
    local networks="${6:-}" own_ips="${7:-}"
    local out http_ver appconnect remote_ip http_code ms attempt network in_network last_ip=""
    local success_count=0 total_ms=0 max_ms=0 attempts=3
    # 用 HEAD(-I) 探测：仅取响应头即可拿到协议版本与握手耗时，不下载正文，
    # 对低带宽 / 低配 VPS 更省流量和时间(h2/ALPN 是连接级，与请求方法无关)。
    local curl_opts=(-I --tlsv1.3 --connect-timeout 2 --max-time 4)
    # 仅当本机 curl 支持 h2 时才协商 h2，否则该 flag 会让 curl 直接报错。
    (( require_h2 )) && curl_opts+=(--http2)
    [[ -n "$networks" ]] && curl_opts+=(-4)

    for attempt in $(seq 1 "$attempts"); do
        # 剩余取样已凑不够两次成功时提前结束，不再等待无效目标超时。
        (( success_count + attempts - attempt + 1 >= 2 )) || break
        # 连续取样，优先选择成功率高且平均/最大握手延迟低的目标。
        out=$(curl --noproxy '*' -o /dev/null -s -w '%{http_version} %{time_appconnect} %{remote_ip} %{http_code}' \
            "${curl_opts[@]}" "https://${sni}" 2>/dev/null) || continue
        read -r http_ver appconnect remote_ip http_code <<< "$out"

        if (( require_h2 )) && [[ "$http_ver" != "2" ]]; then
            continue
        fi
        [[ "$appconnect" =~ ^[0-9]+([.][0-9]+)?$ ]] || continue
        [[ -n "$remote_ip" ]] || continue
        is_cloudflare_address "$remote_ip" && continue
        if (( strict )) && [[ "$http_code" != "200" ]]; then
            continue
        fi
        if [[ -n "$networks" ]]; then
            [[ " $own_ips " == *" $remote_ip "* ]] && continue
            in_network=0
            for network in $networks; do
                if ipv4_in_cidr "$remote_ip" "$network"; then
                    in_network=1
                    break
                fi
            done
            (( in_network )) || continue
        fi
        ms=$(awk -v t="$appconnect" 'BEGIN {printf "%d", t * 1000}' 2>/dev/null || echo 0)
        [[ "$ms" =~ ^[0-9]+$ && "$ms" -gt 0 && "$ms" -lt 9999 ]] || continue
        success_count=$((success_count + 1))
        total_ms=$((total_ms + ms))
        last_ip="$remote_ip"
        if (( ms > max_ms )); then
            max_ms=$ms
        fi
    done

    (( success_count >= 2 )) || return 0
    echo "$idx $success_count $((total_ms / success_count)) $max_ms $sni $last_ip" >> "$result_file"
    return 0
}

# 按本机并发上限探测一批域名；调用方负责在 set +e 区间内调用。
# 参数依次为结果文件、strict、networks、own_ips，其后是域名列表。
run_reality_sni_probes() {
    local result_file="$1" strict="$2" networks="$3" own_ips="$4"
    shift 4
    local probe_parallelism idx=0 active_jobs=0 sni
    probe_parallelism=$(get_reality_probe_parallelism)

    # 并发数为 1 时直接前台串行探测，避免在受限机器上 fork 后台任务。
    for sni in "$@"; do
        if (( probe_parallelism <= 1 )); then
            probe_reality_sni_candidate "$idx" "$sni" "$result_file" 1 "$strict" "$networks" "$own_ips"
        else
            probe_reality_sni_candidate "$idx" "$sni" "$result_file" 1 "$strict" "$networks" "$own_ips" &
            active_jobs=$((active_jobs + 1))
            if (( active_jobs >= probe_parallelism )); then
                wait
                active_jobs=0
            fi
        fi
        idx=$((idx + 1))
    done
    wait 2>/dev/null
}

reality_sni_runtime_usable() {
    local sni="$1" tmp strict=0
    reality_sni_is_approved "$sni" || return 1
    reality_sni_is_listed "$sni" || strict=1
    ensure_reality_probe_dependencies || return 1
    tmp=$(mktemp) || return 1
    probe_reality_sni_candidate 0 "$sni" "$tmp" 1 "$strict"
    local result=1
    [[ -s "$tmp" ]] && result=0
    rm -f "$tmp"
    return "$result"
}

# 采用用户指定的域名：内置列表内按常规检查；列表外须通过严格检查，通过后记入 REALITY_SNI_CUSTOM。
adopt_reality_sni() {
    local sni="${1:-}"
    if reality_sni_is_listed "$sni"; then
        reality_sni_runtime_usable "$sni" || return 1
    else
        REALITY_SNI_CUSTOM="$sni" reality_sni_runtime_usable "$sni" || return 1
        REALITY_SNI_CUSTOM="$sni"
    fi
    REALITY_SNI="$sni"
}

select_reality_sni() {
    if [[ -n "${REALITY_SNI:-}" ]]; then
        if ! reality_sni_is_approved "$REALITY_SNI"; then
            if adopt_reality_sni "$REALITY_SNI"; then
                info "当前已设定列表外域名并通过严格检查 (TLS1.3 + HTTP/2 + HTTP 200，非 Cloudflare 地址): $REALITY_SNI"
                return 0
            fi
            warn "Reality 伪装域名不在审核列表中，且未通过列表外域名的严格检查: $REALITY_SNI"
            REALITY_SNI=""
            return 1
        fi
        if reality_sni_runtime_usable "$REALITY_SNI"; then
            info "当前已设定审核域名并通过运行时检查: $REALITY_SNI"
            return 0
        fi
        warn "Reality 伪装域名未通过运行时检查: $REALITY_SNI"
        REALITY_SNI=""
        return 1
    fi
    local probe_parallelism
    probe_parallelism=$(get_reality_probe_parallelism)

    if ! ensure_reality_probe_dependencies; then
        REALITY_SNI=""
        return 1
    fi
    info "正在实测 ${#REALITY_SNI_LIST[@]} 个 Reality 候选域名 (要求 TLS1.3 + HTTP/2，排除 Cloudflare 地址，按握手成功率和延迟择优)，并发数: ${probe_parallelism}"

    local tmp_dir
    if ! tmp_dir=$(mktemp -d); then
        REALITY_SNI=""
        warn "创建临时目录失败，未选择 Reality 域名"
        return 1
    fi

    # 探测过程允许个别命令失败：在低内存/无 swap 机器上，后台任务 fork 失败、
    # wait 返回非零或管道 SIGPIPE 都会在 set -euo pipefail 下误终止整个脚本。
    # 本函数会在全部失败时返回失败，这里只避免后台探测受 errexit 干扰。
    local errexit_was_set=0
    [[ $- == *e* ]] && errexit_was_set=1
    set +e

    # 仅保留通过 TLS1.3 + h2 能力门槛的域名，再按握手延迟择优。
    run_reality_sni_probes "${tmp_dir}/results.txt" 0 "" "" "${REALITY_SNI_LIST[@]}"

    # 需要排除的域名（重新优选时排除当前/上一次，确保结果不同）；
    # 两端补空格便于按整词匹配。常规安装时该变量为空，不影响行为。
    local exclude=" ${REALITY_SNI_EXCLUDE:-} "

    local best_sni="" best_time=9999 best_success=0 best_max=9999
    if [[ -f "${tmp_dir}/results.txt" ]]; then
        local best
        # 成功次数优先，其次平均延迟、最大延迟和候选顺序。
        best=$(awk -v ex="$exclude" 'index(ex, " " $5 " ") == 0' "${tmp_dir}/results.txt" \
            | sort -k2,2nr -k3,3n -k4,4n -k1,1n | head -1)
        best_success=$(echo "$best" | awk '{print $2}')
        best_time=$(echo "$best" | awk '{print $3}')
        best_max=$(echo "$best" | awk '{print $4}')
        best_sni=$(echo "$best" | awk '{print $5}')
    fi

    (( errexit_was_set )) && set -e

    rm -rf "$tmp_dir"

    if [[ -n "$best_sni" ]]; then
        REALITY_SNI="$best_sni"
        success "已选择连续握手最稳定的 Reality 域名: ${REALITY_SNI} (${best_success}/3，平均 ${best_time}ms，最大 ${best_max}ms)"
        return 0
    else
        REALITY_SNI=""
        warn "无审核域名通过运行时检查，未选择 Reality 域名"
        return 1
    fi
}

verify_reality_fallback_sni() {
    local sni="${1:-${REALITY_SNI:-}}" port="${2:-${REALITY_PORT:-}}" code
    reality_sni_is_approved "$sni" || return 1
    is_valid_hostname "$sni" || return 1
    validate_port "$port" "Reality" >/dev/null 2>&1 || return 1

    code=$(curl --noproxy '*' -k -sS -o /dev/null --connect-timeout 3 --max-time 8 \
        --resolve "${sni}:${port}:127.0.0.1" -w '%{http_code}' \
        "https://${sni}:${port}/" 2>/dev/null || true)
    [[ "$code" =~ ^[1-5][0-9][0-9]$ ]]
}

verify_or_reselect_reality_sni() {
    local old_sni="${REALITY_SNI:-}" failed_sni next_sni

    if verify_reality_fallback_sni "$old_sni" "$REALITY_PORT"; then
        success "Reality TLS 转发验证通过: ${old_sni}"
        return 0
    fi

    failed_sni="$old_sni"
    warn "Reality 完整 TLS 转发验证失败，正在排除 ${failed_sni} 后重新选择"
    REALITY_SNI=""
    REALITY_SNI_EXCLUDE="$failed_sni"
    select_reality_sni || true
    unset REALITY_SNI_EXCLUDE
    next_sni="$REALITY_SNI"
    if [[ -z "$next_sni" || "$next_sni" == "$failed_sni" ]]; then
        REALITY_SNI="$old_sni"
        return 1
    fi

    write_singbox_config
    service_restart sing-box || true
    sleep 2
    if service_is_active sing-box && verify_reality_fallback_sni "$next_sni" "$REALITY_PORT"; then
        success "Reality 已切换到通过完整 TLS 转发验证的 SNI: ${next_sni}"
        return 0
    fi

    REALITY_SNI="$old_sni"
    write_singbox_config
    service_restart sing-box 2>/dev/null || true
    warn "新的 SNI 未通过完整验证，已恢复原 SNI: ${old_sni}"
    return 1
}

# ─── Reality 同网段邻居域名 ──────────────────────────────────
# 可选来源：只有用户主动执行邻居扫描时才访问 stat.ripe.net 与 bgp.he.net，
# 安装和常规重新优选不依赖这些接口。
reality_neighbor_fetch() {
    curl -fsS --connect-timeout 5 --max-time 15 "$1" 2>/dev/null
}

# 输出用于检索和归属校验的网段：本机 /24，以及本机所在 BGP 前缀（短于 /20 时收敛到本机 /20）。
reality_neighbor_networks() {
    local ip="$1" body prefix bits
    ipv4_network "$ip" 24
    body=$(reality_neighbor_fetch "${REALITY_NEIGHBOR_PREFIX_API}${ip}") || return 0
    prefix=$(printf '%s' "$body" | tr -d ' \n\r\t' | grep -oE '"prefix":"[0-9.]+/[0-9]+"' | cut -d'"' -f4 | head -n 1) || return 0
    ipv4_in_cidr "$ip" "$prefix" || return 0
    bits="${prefix#*/}"
    (( bits < 24 )) || return 0
    (( bits >= 20 )) || bits=20
    ipv4_network "$ip" "$bits"
}

# 输出各网段证书透明度记录中的主机名，每行一个；单个网段查询失败时跳过。
reality_neighbor_hostnames() {
    local network body
    for network in "$@"; do
        body=$(reality_neighbor_fetch "${REALITY_NEIGHBOR_CERTS_API}${network}") || continue
        printf '%s' "$body" | tr -d ' \n\r\t' | grep -oE '"hostnames":\[[^]]*\]' \
            | sed 's/^"hostnames"://' | tr -d '[]"' | tr ',' '\n' || true
    done
}

# 从标准输入读取主机名，剔除自动生成、动态解析和邮件/面板类主机名，
# 按不含数字、com/net/org 优先、层级少、长度短的顺序输出。
reality_neighbor_rank() {
    awk '
        {
            host = tolower($0)
            sub(/^\*\./, "", host)
            if (host !~ /^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z][a-z]+$/) next
            if (host ~ /[0-9]+[-.][0-9]+[-.][0-9]+/) next
            if (host ~ /(^|\.)(mail|smtp|pop|pop3|imap|mx|mx[0-9]+|ns[0-9]+|webmail|cpanel|whm|autodiscover|autoconfig)\./) next
            if (host ~ /(^|\.)(nip\.io|sslip\.io|xip\.io|duckdns\.org|dpdns\.org|ddns\.net|no-ip\.org|localhost|local|arpa)$/) next
            if (seen[host]++) next
            n = split(host, parts, ".")
            rank = 3
            if (parts[n] == "com") rank = 0
            else if (parts[n] == "net") rank = 1
            else if (parts[n] == "org") rank = 2
            if (host ~ /[0-9]/) rank += 4
            printf "%d %d %d %s\n", rank, n, length(host), host
        }
    ' | sort -k1,1n -k2,2n -k3,3n -k4,4 | awk '{ print $4 }'
}

# 扫描本机公网 IPv4 所在网段的证书域名，选出连接地址在同网段、直接返回 HTTP 200 的站点。
# 成功时设置 REALITY_SNI 并记入 REALITY_SNI_CUSTOM；失败时清空 REALITY_SNI，不改动 REALITY_SNI_CUSTOM。
select_reality_neighbor_sni() {
    local ip own_ips sni network tmp_dir top max="$REALITY_NEIGHBOR_MAX_CANDIDATES"
    local best_success best_time best_max best_sni
    local -a networks=() candidates=()

    REALITY_SNI=""
    ensure_reality_probe_dependencies || return 1
    refresh_public_ip_stack || true
    ip="${PUBLIC_IPV4:-}"
    if ! is_valid_public_ipv4_for_link "$ip"; then
        warn "未检测到公网 IPv4，无法扫描同网段邻居域名"
        return 1
    fi
    own_ips=$(printf '%s\n%s\n' "$ip" "${PUBLIC_IPV4_LIST:-}" | tr '\n' ' ')

    info "正在查询 ${ip} 所在网段，并从证书透明度记录检索同网段域名 (stat.ripe.net / bgp.he.net)..."
    mapfile -t networks < <(reality_neighbor_networks "$ip")
    (( $(get_reality_probe_parallelism) > 1 )) || max="$REALITY_NEIGHBOR_SERIAL_CANDIDATES"
    # 先取本机 /24 的域名，不足时再用更大的网段补齐。
    for network in "${networks[@]}"; do
        while IFS= read -r sni; do
            (( ${#candidates[@]} < max )) || break
            if is_valid_hostname "$sni" && [[ " ${REALITY_SNI_EXCLUDE:-} ${candidates[*]} " != *" $sni "* ]]; then
                candidates+=("$sni")
            fi
        done < <(reality_neighbor_hostnames "$network" | reality_neighbor_rank)
    done
    if (( ${#candidates[@]} == 0 )); then
        warn "未检索到同网段候选域名：第三方接口不可用，或该网段没有合适的站点"
        return 1
    fi
    info "正在实测 ${#candidates[@]} 个同网段候选域名 (要求 TLS1.3 + HTTP/2 + HTTP 200，连接地址位于 ${networks[*]} 且不是本机)"

    if ! tmp_dir=$(mktemp -d); then
        warn "创建临时目录失败，未选择 Reality 域名"
        return 1
    fi
    local errexit_was_set=0
    [[ $- == *e* ]] && errexit_was_set=1
    set +e
    run_reality_sni_probes "${tmp_dir}/results.txt" 1 "${networks[*]}" "$own_ips" "${candidates[@]}"
    top=""
    # 成功次数优先，其次平均延迟、最大延迟和候选顺序。
    [[ -f "${tmp_dir}/results.txt" ]] && top=$(sort -k2,2nr -k3,3n -k4,4n -k1,1n "${tmp_dir}/results.txt" | awk 'NR <= 5')
    (( errexit_was_set )) && set -e
    rm -rf "$tmp_dir"

    if [[ -z "$top" ]]; then
        warn "同网段候选域名均未通过检查，未选择邻居域名"
        return 1
    fi
    echo "$top" | awk '{ printf "  %d) %s  %s  %s/3  平均 %sms\n", NR, $5, $6, $2, $3 }'
    read -r _ best_success best_time best_max best_sni _ <<< "$top"
    REALITY_SNI="$best_sni"
    reality_sni_is_listed "$best_sni" || REALITY_SNI_CUSTOM="$best_sni"
    success "已选择同网段邻居域名: ${REALITY_SNI} (${best_success}/3，平均 ${best_time}ms，最大 ${best_max}ms)"
}

# ─── URL 编码 ────────────────────────────────────────────────
urlencode() {
    local value="$1" output="" char encoded i

    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$value" 2>/dev/null && return 0
    fi

    # 生成的 SOCKS5 凭据即使在精简系统缺少 python3 时也必须保持 URL 有效。
    local LC_ALL=C
    for ((i = 0; i < ${#value}; i++)); do
        char="${value:i:1}"
        case "$char" in
            [a-zA-Z0-9.~_-]) output+="$char" ;;
            *)
                printf -v encoded '%%%02X' "'$char"
                output+="$encoded"
                ;;
        esac
    done
    printf '%s\n' "$output"
}

append_subscription_link() {
    local link="$1"
    if [[ -z "$GENERATED_SUBSCRIPTION_RAW" ]]; then
        GENERATED_SUBSCRIPTION_RAW="$link"
    else
        GENERATED_SUBSCRIPTION_RAW+=$'\n'"$link"
    fi
}

append_reality_link() {
    local link="$1"
    if [[ -z "$GENERATED_REALITY_LINKS" ]]; then
        GENERATED_REALITY_LINKS="$link"
    else
        GENERATED_REALITY_LINKS+=$'\n'"$link"
    fi
    append_subscription_link "$link"
}

append_hy2_link() {
    local link="$1"
    if [[ -z "$GENERATED_HY2_LINKS" ]]; then
        GENERATED_HY2_LINKS="$link"
    else
        GENERATED_HY2_LINKS+=$'\n'"$link"
    fi
    append_subscription_link "$link"
}

append_socks_link() {
    local link="$1"
    if [[ -z "$GENERATED_SOCKS_LINKS" ]]; then
        GENERATED_SOCKS_LINKS="$link"
    else
        GENERATED_SOCKS_LINKS+=$'\n'"$link"
    fi
}

get_hy2_cert_pin_sha256() {
    local cert_file="${CONFIG_DIR}/server.crt"
    local pin

    if [[ -n "${HY2_CERT_PIN_SHA256:-}" ]]; then
        printf '%s' "$HY2_CERT_PIN_SHA256"
        return 0
    fi

    if [[ ! -f "$cert_file" ]]; then
        HY2_SHARE_LINK_WARNING="Hysteria2 证书文件缺失，已跳过 HY2 分享链接生成。"
        return 1
    fi

    pin=$(openssl x509 -in "$cert_file" -outform der 2>/dev/null \
        | openssl dgst -sha256 -r 2>/dev/null \
        | awk '{print tolower($1)}') || true

    if [[ ! "$pin" =~ ^[0-9a-f]{64}$ ]]; then
        HY2_SHARE_LINK_WARNING="无法计算 Hysteria2 证书固定指纹，已跳过 HY2 分享链接生成。请检查证书文件或 openssl。"
        return 1
    fi

    HY2_CERT_PIN_SHA256="$pin"
    printf '%s' "$HY2_CERT_PIN_SHA256"
}

hy2_share_link_available() {
    [[ -f "${CONFIG_DIR}/server.crt" && -n "${HY2_PORT:-}" ]] || return 1
    [[ -f "$CONFIG_FILE" ]] || return 1
    grep -q '"type"[[:space:]]*:[[:space:]]*"hysteria2"' "$CONFIG_FILE" || return 1
    get_hy2_cert_pin_sha256 >/dev/null
}

socks_share_link_available() {
    is_socks_enabled && [[ -n "${SOCKS_PORT:-}" && -n "${SOCKS_USERNAME:-}" && -n "${SOCKS_PASSWORD:-}" ]]
}

build_socks_link_for_ip() {
    local ip="$1" host username_enc password_enc port

    socks_share_link_available || return 0
    [[ -n "$ip" ]] || return 0
    host=$(format_url_host "$ip")
    username_enc=$(urlencode "$SOCKS_USERNAME")
    password_enc=$(urlencode "$SOCKS_PASSWORD")
    # IPv4 NAT 公网映射端口不适用于本机原生 IPv6 入口。
    if [[ "$ip" == *:* ]]; then
        port="$SOCKS_PORT"
    else
        port=$(socks_share_port)
    fi
    append_socks_link "socks5://${username_enc}:${password_enc}@${host}:${port}"
}

build_direct_share_links_for_ip() {
    local ip="$1"
    local family_label="$2"
    local host remark reality_name

    [[ -n "$ip" ]] || return
    host=$(format_url_host "$ip")

    if [[ -n "$family_label" ]]; then
        reality_name="${NODE_NAME}-${family_label}-Reality"
    else
        reality_name="${NODE_NAME}-Reality"
    fi

    remark=$(urlencode "$reality_name")
    append_reality_link "vless://${UUID}@${host}:$(reality_share_port)?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${remark}"

    build_socks_link_for_ip "$ip"

    if hy2_share_link_available; then
        local hy2_remark hy2_pass_enc hy2_name hy2_pin_sha hy2_pin_enc
        if [[ -n "$family_label" ]]; then
            hy2_name="${NODE_NAME}-${family_label}-Hysteria2"
        else
            hy2_name="${NODE_NAME}-Hysteria2"
        fi
        hy2_remark=$(urlencode "$hy2_name")
        hy2_pass_enc=$(urlencode "${HY2_PASSWORD}")
        hy2_pin_sha=$(get_hy2_cert_pin_sha256) || return 0
        hy2_pin_enc=$(urlencode "${hy2_pin_sha}")
        append_hy2_link "hysteria2://${hy2_pass_enc}@${host}:${HY2_PORT}?sni=${HY2_SNI}&insecure=1&pinSHA256=${hy2_pin_enc}#${hy2_remark}"
    fi
}

build_direct_share_links_for_selected_ipv4s() {
    local selected_ips ip count index label

    selected_ips=$(selected_public_ipv4_list)
    [[ -n "$selected_ips" ]] || return 0
    count=$(printf '%s\n' "$selected_ips" | sed '/^$/d' | wc -l | tr -d '[:space:]')
    index=1
    while IFS= read -r ip; do
        [[ -n "$ip" ]] || continue
        label=""
        if (( count > 1 )); then
            label="IPv4-${index}"
        fi
        build_direct_share_links_for_ip "$ip" "$label"
        index=$((index + 1))
    done <<< "$selected_ips"
}

append_argo_link() {
    local link="$1"
    if [[ -z "$GENERATED_ARGO_LINKS" ]]; then
        GENERATED_ARGO_LINKS="$link"
    else
        GENERATED_ARGO_LINKS+=$'\n'"$link"
    fi
    append_subscription_link "$link"
}

argo_cf_domain_is_candidate() {
    local requested="${1:-}" candidate
    for candidate in "${ARGO_CF_DOMAINS[@]}"; do
        [[ "$requested" == "$candidate" ]] && return 0
    done
    return 1
}

probe_argo_cf_domain() {
    local idx="$1" domain="$2" family="$3" result_file="$4" attempts="${5:-3}"
    local output code appconnect ms
    local -a family_args=()
    local success_count=0 total_ms=0 max_ms=0
    [[ "$family" == "4" ]] && family_args=(-4)
    [[ "$family" == "6" ]] && family_args=(-6)
    argo_enabled && is_valid_hostname "${ARGO_DOMAIN:-}" && is_valid_hostname "$domain" || return 0

    for _ in $(seq 1 "$attempts"); do
        output=$(curl --noproxy '*' "${family_args[@]}" --http1.1 -sS -o /dev/null \
            --connect-timeout 3 --max-time 8 \
            --connect-to "${ARGO_DOMAIN}:443:${domain}:443" \
            -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
            -H 'Sec-WebSocket-Version: 13' \
            -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
            -w '%{http_code} %{time_appconnect}' \
            "https://${ARGO_DOMAIN}${WS_PATH:-/}" 2>/dev/null || true)
        read -r code appconnect <<< "$output"
        [[ "$code" == "101" ]] || continue
        [[ "$appconnect" =~ ^[0-9]+([.][0-9]+)?$ ]] || continue
        ms=$(awk -v t="$appconnect" 'BEGIN {printf "%d", t * 1000}' 2>/dev/null || echo 0)
        [[ "$ms" =~ ^[0-9]+$ && "$ms" -gt 0 && "$ms" -lt 9999 ]] || continue
        success_count=$((success_count + 1))
        total_ms=$((total_ms + ms))
        (( ms > max_ms )) && max_ms=$ms
    done

    (( success_count >= 2 )) || return 0
    printf '%s %s %s %s %s\n' "$idx" "$success_count" "$((total_ms / success_count))" "$max_ms" "$domain" >> "$result_file"
}

select_argo_cf_domain_for_family() {
    local family="$1" tmp_dir result_file idx domain best
    tmp_dir=$(mktemp -d) || return 1
    result_file="${tmp_dir}/results"

    for idx in "${!ARGO_CF_DOMAINS[@]}"; do
        domain="${ARGO_CF_DOMAINS[$idx]}"
        probe_argo_cf_domain "$idx" "$domain" "$family" "$result_file" 3 &
    done
    wait 2>/dev/null || true

    if [[ -s "$result_file" ]]; then
        best=$(sort -k2,2nr -k3,3n -k4,4n -k1,1n "$result_file" | head -1)
        domain=$(printf '%s\n' "$best" | awk '{print $5}')
        rm -rf "$tmp_dir"
        printf '%s\n' "$domain"
        return 0
    fi
    rm -rf "$tmp_dir"
    return 1
}

resolve_argo_best_cf_domains() {
    local changed=false selected=""
    argo_enabled && is_valid_hostname "${ARGO_DOMAIN:-}" || return 1

    if [[ "${ARGO_CF_CACHE_DOMAIN:-}" != "$ARGO_DOMAIN" || "${ARGO_CF_CACHE_VERSION:-}" != "$ARGO_CF_DOMAIN_LIST_VERSION" ]]; then
        clear_argo_best_cf_cache
        changed=true
    fi

    if [[ -n "${ARGO_BEST_CF_DOMAIN_IPV4:-}" ]] && argo_cf_domain_is_candidate "$ARGO_BEST_CF_DOMAIN_IPV4"; then
        local verify4
        verify4=$(mktemp) || return 1
        probe_argo_cf_domain 0 "$ARGO_BEST_CF_DOMAIN_IPV4" 4 "$verify4" 2
        [[ -s "$verify4" ]] || ARGO_BEST_CF_DOMAIN_IPV4=""
        rm -f "$verify4"
    else
        ARGO_BEST_CF_DOMAIN_IPV4=""
    fi
    if [[ -z "$ARGO_BEST_CF_DOMAIN_IPV4" ]] && selected=$(select_argo_cf_domain_for_family 4); then
        ARGO_BEST_CF_DOMAIN_IPV4="$selected"
        changed=true
    fi

    if [[ -n "${ARGO_BEST_CF_DOMAIN_IPV6:-}" ]] && argo_cf_domain_is_candidate "$ARGO_BEST_CF_DOMAIN_IPV6"; then
        local verify6
        verify6=$(mktemp) || return 1
        probe_argo_cf_domain 0 "$ARGO_BEST_CF_DOMAIN_IPV6" 6 "$verify6" 2
        [[ -s "$verify6" ]] || ARGO_BEST_CF_DOMAIN_IPV6=""
        rm -f "$verify6"
    else
        ARGO_BEST_CF_DOMAIN_IPV6=""
    fi
    if [[ -z "$ARGO_BEST_CF_DOMAIN_IPV6" ]] && selected=$(select_argo_cf_domain_for_family 6); then
        ARGO_BEST_CF_DOMAIN_IPV6="$selected"
        changed=true
    fi

    ARGO_BEST_CF_DOMAIN="${ARGO_BEST_CF_DOMAIN_IPV4:-${ARGO_BEST_CF_DOMAIN_IPV6:-}}"
    ARGO_CF_CACHE_DOMAIN="$ARGO_DOMAIN"
    ARGO_CF_CACHE_VERSION="$ARGO_CF_DOMAIN_LIST_VERSION"
    if [[ "$changed" == "true" && -f "$PARAMS_FILE" ]]; then
        save_params
    fi
    [[ -n "$ARGO_BEST_CF_DOMAIN_IPV4" || -n "$ARGO_BEST_CF_DOMAIN_IPV6" ]]
}

build_argo_link_for_domain() {
    local address="${1:-${ARGO_DOMAIN:-}}" family_label="${2:-}" argo_name argo_remark

    argo_enabled || return
    is_valid_hostname "${ARGO_DOMAIN:-}" || return
    is_valid_hostname "$address" || return
    argo_name="${NODE_NAME}-Argo${family_label:+-${family_label}}"
    argo_remark=$(urlencode "$argo_name")
    append_argo_link "vless://${UUID}@${address}:443?encryption=none&security=tls&sni=${ARGO_DOMAIN}&type=ws&host=${ARGO_DOMAIN}&path=${WS_PATH}&fp=chrome#${argo_remark}"
}

# ─── 链接与订阅生成 ──────────────────────────────────────────
build_share_links() {
    GENERATED_REALITY_LINKS=""
    GENERATED_ARGO_LINKS=""
    GENERATED_HY2_LINKS=""
    GENERATED_SOCKS_LINKS=""
    SOCKS_IPV6_ADDRESS=""
    SOCKS_IPV6_LINK_WARNING=""
    GENERATED_SUBSCRIPTION_RAW=""
    HY2_SHARE_LINK_WARNING=""
    HY2_CERT_PIN_SHA256=""

    if ! refresh_public_ip_stack; then
        warn "无法自动获取公网 IP，直连链接未生成。可在修改配置中设置直连公网 IPv4 覆盖。"
        IP_STACK_MODE="unknown"
        PUBLIC_IP=""
        PUBLIC_IPV4=""
        PUBLIC_IPV4_LIST=""
        PUBLIC_IPV6=""
    fi

    case "${IP_STACK_MODE:-}" in
        dual-stack)
            build_direct_share_links_for_selected_ipv4s
            ;;
        ipv6-only)
            if argo_enabled; then
                warn "检测到 IPv6-only VPS，IPv4 客户端请使用 Argo 节点；Reality 为独立直连入口。"
            else
                warn "检测到 IPv6-only VPS，且未启用 Argo；本地 IPv4 无法连接，未生成 Reality/Hysteria2 直连链接。"
            fi
            ;;
        unknown)
            ;;
        *)
            build_direct_share_links_for_selected_ipv4s
            ;;
    esac

    if socks_share_link_available; then
        SOCKS_IPV6_ADDRESS=$(get_inbound_ipv6 || true)
        if [[ -n "$SOCKS_IPV6_ADDRESS" ]]; then
            build_socks_link_for_ip "$SOCKS_IPV6_ADDRESS"
        elif [[ -n "${PUBLIC_IPV6:-}" ]]; then
            SOCKS_IPV6_LINK_WARNING="已检测到 IPv6 出口，但未确认本机可用的公网 IPv6；请由服务商分配可入站公网 IPv6，当前不生成 IPv6 入口链接。"
        fi
    fi

    if argo_enabled && is_valid_hostname "${ARGO_DOMAIN:-}"; then
        if resolve_argo_best_cf_domains; then
            [[ -n "${ARGO_BEST_CF_DOMAIN_IPV4:-}" ]] && build_argo_link_for_domain "$ARGO_BEST_CF_DOMAIN_IPV4" "IPv4"
            if [[ -n "${ARGO_BEST_CF_DOMAIN_IPV6:-}" && "$ARGO_BEST_CF_DOMAIN_IPV6" != "$ARGO_BEST_CF_DOMAIN_IPV4" ]]; then
                build_argo_link_for_domain "$ARGO_BEST_CF_DOMAIN_IPV6" "IPv6"
            fi
        else
            warn "CF 优选地址未通过 Argo 域名实测，未生成 Argo 节点链接"
        fi
    fi
}

write_subscription_assets() {
    local subscription_base64

    subscription_base64=$(printf '%s' "${GENERATED_SUBSCRIPTION_RAW}" | base64 | tr -d '\r\n')
    printf '%s' "${subscription_base64}" > "$SUBSCRIPTION_FILE"
    chmod 600 "$SUBSCRIPTION_FILE"
}

subscription_https_url() {
    argo_enabled && is_valid_hostname "${ARGO_DOMAIN:-}" && [[ -n "${SUB_TOKEN:-}" ]] || return 1
    echo "https://${ARGO_DOMAIN}/sub/${SUB_TOKEN}"
}

subscription_local_url() {
    [[ -n "${SUB_TOKEN:-}" ]] || return 1
    echo "http://127.0.0.1:${SUBSCRIPTION_PORT}/sub/${SUB_TOKEN}"
}

show_subscription_url() {
    local public_subscription_url local_subscription_url

    [[ -n "${GENERATED_SUBSCRIPTION_RAW:-}" ]] && argo_enabled || return 0
    if ! service_is_active sbm-subscription || ! service_is_active argo-tunnel; then
        warn "订阅服务或 Argo 隧道未运行，不展示未经验证的订阅地址"
        return 0
    fi

    menu_header "节点链接 / 订阅地址"
    if public_subscription_url=$(subscription_https_url); then
        echo -e "${GREEN}${BOLD}HTTPS 订阅地址（公网可用性待验证）${NC}"
        echo -e "${YELLOW}${BOLD}${public_subscription_url}${NC}"
        # 手机客户端可直接扫码导入；不为此额外安装依赖。
        if command -v qrencode >/dev/null 2>&1; then
            echo ""
            qrencode -t ANSIUTF8 -m 1 "$public_subscription_url" 2>/dev/null || true
        fi
    else
        echo -e "${DIM}Argo 域名尚未就绪，仅提供本机调试地址。${NC}"
    fi
    if local_subscription_url=$(subscription_local_url); then
        echo ""
        echo -e "${DIM}本机调试${NC}"
        echo -e "${DIM}${local_subscription_url}${NC}"
    fi
    echo ""
}

generate_and_show_links() {
    build_share_links

    menu_header "节点链接 / 配置信息 & 分享链接"

    menu_section "基本信息"
    case "${IP_STACK_MODE:-}" in
        dual-stack)
            echo -e "  公网类型:      ${BOLD}IPv4 + IPv6${NC}"
            echo -e "  服务器 IPv4:   ${BOLD}$(public_ipv4_display)${NC}"
            echo -e "  IPv6 出口:     ${BOLD}${PUBLIC_IPV6}${NC}"
            ;;
        ipv6-only)
            echo -e "  公网类型:      ${BOLD}IPv6-only${NC}"
            echo -e "  IPv6 出口:     ${BOLD}${PUBLIC_IP}${NC}"
            ;;
        unknown)
            echo -e "  公网类型:      ${BOLD}未获取${NC}"
            echo -e "  服务器 IPv4:   ${BOLD}未获取${NC}"
            ;;
        *)
            echo -e "  公网类型:      ${BOLD}IPv4-only${NC}"
            echo -e "  服务器 IPv4:   ${BOLD}$(public_ipv4_display)${NC}"
            ;;
    esac
    if [[ -n "${PUBLIC_IPV4_OVERRIDE:-}" || $(public_ipv4_candidate_count) -gt 1 ]]; then
        echo -e "  IPv4 策略:     ${BOLD}$(link_ipv4_selection_label)${NC}"
    fi
    if [[ "${OUTBOUND_IP_STRATEGY:-default}" != "default" ]]; then
        echo -e "  出站优先级:    ${BOLD}$(outbound_ip_strategy_label)${NC}"
    fi
    if [[ "${IP_STACK_MODE:-}" == "unknown" ]]; then
        echo -e "  ${DIM}提示: 可在 [网络设置] -> [直连公网 IPv4] 设置正确公网 IP 后重新生成链接。${NC}"
    fi
    echo -e "  UUID:          ${BOLD}${UUID}${NC}"
    if [[ "${IP_STACK_MODE:-}" != "ipv6-only" && "${IP_STACK_MODE:-}" != "unknown" ]]; then
        echo -e "  Reality 端口:  ${BOLD}$(reality_share_port)${NC}$(nat_mode_enabled && printf ' (本机监听 %s)' "$REALITY_PORT")"
        echo -e "  Reality SNI:   ${BOLD}${REALITY_SNI}${NC}"
        echo -e "  Public Key:    ${BOLD}${PUBLIC_KEY}${NC}"
        echo -e "  Short ID:      ${BOLD}${SHORT_ID}${NC}"
    fi
    if is_socks_enabled; then
        echo -e "  SOCKS5 端口:   ${BOLD}$(socks_share_port)${NC}$(nat_mode_enabled && printf ' (本机监听 %s)' "$SOCKS_PORT")"
        echo -e "  SOCKS5 用户名: ${BOLD}${SOCKS_USERNAME}${NC}"
    fi
    if argo_enabled; then
        echo -e "  订阅端口:      ${BOLD}${SUBSCRIPTION_PORT}${NC}"
        if argo_fixed_enabled; then
            echo -e "  Argo 模式:     ${GREEN}固定域名 (Token)${NC}"
        else
            echo -e "  Argo 模式:     ${GREEN}临时域名${NC}"
        fi
        echo -e "  Argo 域名:     ${BOLD}${ARGO_DOMAIN:-未配置}${NC}"
        echo -e "  WS Path:       ${BOLD}${WS_PATH}${NC}"
    else
        echo -e "  Argo 模式:     ${DIM}未启用${NC}"
    fi
    if is_hy2_enabled && [[ "${IP_STACK_MODE:-}" != "ipv6-only" && "${IP_STACK_MODE:-}" != "unknown" ]]; then
        echo -e "  Hysteria2 本机端口: ${BOLD}${HY2_PORT}/UDP${NC}"
        echo -e "  Hysteria2 密码: ${BOLD}${HY2_PASSWORD}${NC}"
    fi
    echo ""

    if [[ -n "${GENERATED_REALITY_LINKS}" ]]; then
        menu_section "VLESS + Reality (直连)"
        echo -e "${YELLOW}${GENERATED_REALITY_LINKS}${NC}"
        echo -e "  ${DIM}提示: Reality 请使用 Xray-core / sing-box 内核；若 v2rayN 当前使用 v2fly core，请先切换到 Xray core。${NC}"
        echo ""
    fi

    if [[ -n "${GENERATED_ARGO_LINKS}" ]]; then
        menu_section "VLESS + WS + Argo (CDN)"
        echo -e "  伪装域名(SNI): ${BOLD}${ARGO_DOMAIN}${NC}"
        echo -e "  接入地址(ADDR): ${BOLD}${ARGO_DOMAIN}${NC}"
        echo -e "${YELLOW}${GENERATED_ARGO_LINKS}${NC}"
        echo ""
    fi

    if [[ -n "${GENERATED_HY2_LINKS}" ]]; then
        menu_section "Hysteria2 (QUIC/UDP 高速)"
        echo -e "${YELLOW}${GENERATED_HY2_LINKS}${NC}"
        echo -e "  ${DIM}提示: 链接同时提供 insecure=1 与 pinSHA256，以兼容 v2rayN 和支持证书固定的客户端。${NC}"
        echo ""
    elif [[ -n "${HY2_SHARE_LINK_WARNING:-}" ]]; then
        echo -e "${YELLOW}  ${HY2_SHARE_LINK_WARNING}${NC}"
        echo ""
    elif [[ "${IP_STACK_MODE:-}" == "unknown" ]]; then
        echo -e "${YELLOW}  未生成 Reality/Hysteria2 直连链接：未获取公网 IPv4。${NC}"
        echo -e "${DIM}  可设置直连公网 IPv4 覆盖后执行 sbm links 重新生成。${NC}"
        echo ""
    elif [[ "${IP_STACK_MODE:-}" != "ipv6-only" ]]; then
        echo -e "${DIM}  Hysteria2: 未启用${NC}"
        echo ""
    fi

    if [[ -n "${GENERATED_SOCKS_LINKS}" ]]; then
        menu_section "SOCKS5 代理"
        echo -e "${YELLOW}${GENERATED_SOCKS_LINKS}${NC}"
        echo ""
    elif is_socks_enabled; then
        echo -e "${YELLOW}  未获取可用于 SOCKS5 链接的公网 IP。${NC}"
        echo ""
    fi

    if [[ -n "${SOCKS_IPV6_LINK_WARNING:-}" ]]; then
        echo -e "${YELLOW}  ${SOCKS_IPV6_LINK_WARNING}${NC}"
        echo ""
    fi

    show_external_access_requirements
    write_subscription_assets

    {
        echo "# sing-box 分享链接 - $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        if [[ -n "$GENERATED_REALITY_LINKS" ]]; then
            echo "# VLESS + Reality (直连)"
            printf '%s\n' "$GENERATED_REALITY_LINKS"
        fi
        if [[ -n "$GENERATED_ARGO_LINKS" ]]; then
            echo ""
            echo "# VLESS + WS + Argo (CDN)"
            printf '%s\n' "$GENERATED_ARGO_LINKS"
        fi
        if [[ -n "$GENERATED_HY2_LINKS" ]]; then
            echo ""
            echo "# Hysteria2 (QUIC/UDP 高速)"
            printf '%s\n' "$GENERATED_HY2_LINKS"
        fi
        if [[ -n "$GENERATED_SOCKS_LINKS" ]]; then
            echo ""
            echo "# SOCKS5"
            printf '%s\n' "$GENERATED_SOCKS_LINKS"
        fi
        if [[ -n "${GENERATED_SUBSCRIPTION_RAW:-}" ]] && argo_enabled; then
            echo ""
            echo "# Subscription"
            local subscription_url
            if subscription_url=$(subscription_https_url); then
                echo "$subscription_url"
            fi
        fi
    } > "$LINK_FILE"
    chmod 600 "$LINK_FILE"

    echo -e "${DIM}链接已保存至: ${LINK_FILE}${NC}"
}

json_string() {
    local value="${1-}"
    local json_output
    if command -v python3 >/dev/null 2>&1; then
        if json_output=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$value" 2>/dev/null); then
            printf '%s\n' "$json_output"
            return 0
        fi
    fi

    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}
    printf '"%s"\n' "$value"
}
# 每个协议使用独立的短时客户端和本机随机响应，验证认证及数据转发，
# 不把本机测试等同于外部客户端实测。
verify_protocol_loopback() (
    local protocol="$1" address="${2:-127.0.0.1}" tmp http_port client_port nonce response
    local client_pid="" origin_pid="" outbound="" tls_json binary deadline ready=false
    binary=$(resolve_singbox_binary) || return 1
    deadline=$((SECONDS + 20))
    tmp=$(mktemp -d) || return 1
    chmod 700 "$tmp"
    trap '[[ -z "$client_pid" ]] || { kill "$client_pid" 2>/dev/null || true; wait "$client_pid" 2>/dev/null || true; }; [[ -z "$origin_pid" ]] || { kill "$origin_pid" 2>/dev/null || true; wait "$origin_pid" 2>/dev/null || true; }; rm -rf "$tmp"' EXIT

    http_port=$(select_random_available_tcp_port "$REALITY_PORT" "$SOCKS_PORT" "$HY2_PORT" "$WS_PORT" "$SUBSCRIPTION_PORT") || return 1
    client_port=$(select_random_available_tcp_port "$http_port" "$REALITY_PORT" "$SOCKS_PORT" "$HY2_PORT" "$WS_PORT" "$SUBSCRIPTION_PORT") || return 1
    nonce=$(random_hex 12)
    printf '%s' "$nonce" > "$tmp/challenge"
    timeout 12 python3 -m http.server "$http_port" --bind 127.0.0.1 --directory "$tmp" >/dev/null 2>&1 &
    origin_pid=$!
    case "$protocol" in
        reality)
            tls_json="\"tls\":{\"enabled\":true,\"server_name\":$(json_string "$REALITY_SNI"),\"utls\":{\"enabled\":true,\"fingerprint\":\"chrome\"},\"reality\":{\"enabled\":true,\"public_key\":$(json_string "$PUBLIC_KEY"),\"short_id\":$(json_string "$SHORT_ID")}}"
            outbound="\"type\":\"vless\",\"server\":\"127.0.0.1\",\"server_port\":${REALITY_PORT},\"uuid\":$(json_string "$UUID"),\"flow\":\"xtls-rprx-vision\",${tls_json}"
            ;;
        hy2)
            outbound="\"type\":\"hysteria2\",\"server\":\"127.0.0.1\",\"server_port\":${HY2_PORT},\"password\":$(json_string "$HY2_PASSWORD"),\"up_mbps\":100,\"down_mbps\":100,\"tls\":{\"enabled\":true,\"server_name\":$(json_string "$HY2_SNI"),\"insecure\":true}"
            ;;
        socks)
            outbound="\"type\":\"socks\",\"server\":$(json_string "$address"),\"server_port\":${SOCKS_PORT},\"version\":\"5\",\"username\":$(json_string "$SOCKS_USERNAME"),\"password\":$(json_string "$SOCKS_PASSWORD")"
            ;;
        argo)
            outbound="\"type\":\"vless\",\"server\":$(json_string "$address"),\"server_port\":443,\"uuid\":$(json_string "$UUID"),\"tls\":{\"enabled\":true,\"server_name\":$(json_string "$ARGO_DOMAIN"),\"utls\":{\"enabled\":true,\"fingerprint\":\"chrome\"}},\"transport\":{\"type\":\"ws\",\"path\":$(json_string "$WS_PATH"),\"headers\":{\"Host\":$(json_string "$ARGO_DOMAIN")}}"
            ;;
        *) return 1 ;;
    esac
    printf '{"log":{"level":"error"},"inbounds":[{"type":"socks","tag":"test-in","listen":"127.0.0.1","listen_port":%s}],"outbounds":[{"tag":"test-out",%s}]}' "$client_port" "$outbound" > "$tmp/client.json"
    chmod 600 "$tmp/client.json"
    timeout 5 "$binary" check -c "$tmp/client.json" >/dev/null 2>&1 || return 1
    timeout 20 "$binary" run -c "$tmp/client.json" >/dev/null 2>&1 &
    client_pid=$!

    # Both origin and proxy must accept connections before testing authentication.
    while (( SECONDS < deadline )); do
        kill -0 "$origin_pid" "$client_pid" 2>/dev/null || return 1
        if python3 - "$http_port" "$client_port" <<'PY' >/dev/null 2>&1
import socket, sys
for port in sys.argv[1:]:
    with socket.create_connection(("127.0.0.1", int(port)), timeout=0.2):
        pass
PY
        then ready=true; break; fi
        sleep 0.1
    done
    [[ "$ready" == true ]] || return 1
    while (( SECONDS < deadline )); do
        response=$(curl --noproxy '' --proxy "socks5h://127.0.0.1:${client_port}" \
            -fsS --connect-timeout 2 --max-time 4 "http://127.0.0.1:${http_port}/challenge" 2>/dev/null || true)
        [[ "$response" == "$nonce" ]] && return 0
        sleep 0.2
    done
    return 1
)

verify_subscription_payload() (
    local tmp
    [[ -s "$SUBSCRIPTION_FILE" ]] && is_valid_hostname "${ARGO_DOMAIN:-}" && \
        [[ "${SUB_TOKEN:-}" =~ ^[A-Za-z0-9_-]{1,128}$ ]] || return 1
    tmp=$(mktemp -d) || return 1
    chmod 700 "$tmp"
    trap 'rm -rf "$tmp"' EXIT
    printf 'url = "https://%s/sub/%s"\n' "$ARGO_DOMAIN" "$SUB_TOKEN" > "$tmp/curl.conf"
    chmod 600 "$tmp/curl.conf"
    curl --config "$tmp/curl.conf" --noproxy '*' -fsS --connect-timeout 3 --max-time 8 \
        -o "$tmp/response" >/dev/null 2>&1 && cmp -s "$tmp/response" "$SUBSCRIPTION_FILE"
)

verify_enabled_protocols() {
    local failed=false address
    menu_header "服务管理 / 协议自检"
    if ! resolve_singbox_binary >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1 || \
        ! command -v curl >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
        warn "缺少 sing-box / python3 / curl / timeout，协议认证自检未执行"
        return 1
    fi
    if ! run_singbox_bounded 8 check -c "$CONFIG_FILE" >/dev/null 2>&1; then
        warn "服务配置校验失败，协议自检未执行"
        return 1
    fi
    info "配置通过；开始逐项认证与流量测试（每项限时，公网连接尚未验证）"
    info "Reality：验证中..."
    if { [[ "${REALITY_BACKEND:-singbox}" == "xray" ]] && ! service_is_active xray; } || \
        { [[ "${REALITY_BACKEND:-singbox}" != "xray" ]] && ! service_is_active sing-box; } || \
        ! verify_protocol_loopback reality; then
        warn "Reality：本机认证或流量测试未通过"
        failed=true
    else
        success "Reality：本机认证与流量通过，公网未验证"
    fi
    if is_hy2_enabled; then
        info "Hysteria2：验证中..."
        if service_is_active sing-box && verify_protocol_loopback hy2; then
            success "Hysteria2：本机认证与流量通过，公网 UDP 未验证"
        else
            warn "Hysteria2：本机认证或流量测试未通过"
            failed=true
        fi
    else
        info "Hysteria2：未启用，跳过"
    fi
    if is_socks_enabled; then
        info "SOCKS5：验证中..."
        if service_is_active sing-box && verify_protocol_loopback socks; then
            success "SOCKS5：本机认证与流量通过，公网未验证"
        else
            warn "SOCKS5：本机认证或流量测试未通过"
            failed=true
        fi
        if service_is_active sing-box && verify_protocol_loopback socks ::1; then
            success "SOCKS5 IPv6：本机 IPv6 监听、认证与流量通过，公网未验证"
        else
            warn "SOCKS5 IPv6：本机 IPv6 监听、认证或流量测试未通过"
            failed=true
        fi
        address=$(get_inbound_ipv6 || true)
        if [[ -n "$address" ]]; then
            if service_is_active sing-box && verify_protocol_loopback socks "$address"; then
                success "SOCKS5 IPv6 ${address}：本机公网地址认证与流量通过，外部入站未验证"
            else
                warn "SOCKS5 IPv6 ${address}：本机公网地址认证或流量测试未通过"
                failed=true
            fi
        else
            warn "SOCKS5 IPv6：未确认本机可用公网 IPv6，公网入口未启用；IPv6 出口正常不代表可以入站"
        fi
    else
        info "SOCKS5：未启用，跳过"
    fi
    if argo_enabled; then
        if ! service_is_active sing-box || ! service_is_active sbm-subscription || ! service_is_active argo-tunnel; then
            warn "Argo：必需服务未运行"
            failed=true
        else
            for address in "${ARGO_BEST_CF_DOMAIN_IPV4:-}" "${ARGO_BEST_CF_DOMAIN_IPV6:-}"; do
                [[ -n "$address" ]] || continue
                info "Argo ${address}：验证中..."
                if verify_protocol_loopback argo "$address"; then
                    success "Argo ${address}：服务端经隧道认证与流量通过，外部客户端未验证"
                else
                    warn "Argo ${address}：认证或流量测试未通过"
                    failed=true
                fi
            done
            if [[ -z "${ARGO_BEST_CF_DOMAIN_IPV4:-}${ARGO_BEST_CF_DOMAIN_IPV6:-}" ]]; then
                warn "Argo：未生成通过探测的连接地址"
                failed=true
            fi
            if verify_subscription_payload; then
                success "HTTPS 订阅：服务端访问与内容校验通过，外部客户端未验证"
            else
                warn "HTTPS 订阅：服务端访问或内容校验未通过"
                failed=true
            fi
        fi
    else
        info "Argo 与订阅：未启用，跳过"
    fi
    [[ "$failed" == "false" ]]
}

do_verify() {
    load_params || { warn "未找到配置，请先安装"; return 1; }
    build_share_links
    verify_enabled_protocols
}
# 不安装命令、不迁移参数、不请求网络、不运行内核配置检查。
do_doctor() {
    if ! command -v python3 >/dev/null 2>&1; then
        warn "统一诊断未完成：缺少 python3，未安装任何依赖"
        return 2
    fi
    engine_python doctor
}

do_doctor_menu() { do_doctor || true; press_enter; }
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
# ─── 修改配置 ────────────────────────────────────────────────
# 每个分类一个 render_modify_* 函数：按当前状态只列出可用操作，并用 menu_action
# 登记对应的 modify_* 函数名，do_modify_config 直接执行该函数。
modify_category_title() {
    case "$1" in
        reality)  echo "协议设置 / Reality" ;;
        hy2)      echo "协议设置 / Hysteria2" ;;
        socks)    echo "协议设置 / SOCKS5" ;;
        argo)     echo "协议设置 / Argo 隧道" ;;
        identity) echo "协议设置 / 节点名称与 UUID" ;;
        network)  echo "网络设置" ;;
        *)        return 1 ;;
    esac
}

render_modify_reality() {
    menu_section "当前连接"
    echo "  本机 ${REALITY_PORT}/TCP"
    echo "  伪装域名 ${REALITY_SNI}"
    menu_section "连接设置"
    menu_action 1 modify_reality_port "修改端口" "疑似端口被封时更换"
    menu_action 2 do_reoptimize_reality_sni "重新优选伪装域名" "连接不稳定时优先尝试"
    menu_action 3 do_scan_reality_neighbor_sni "扫描同网段邻居域名" "需访问 stat.ripe.net / bgp.he.net"
    menu_action 4 modify_reality_sni "手动指定伪装域名" "列表外域名须直接返回 HTTP 200"
    menu_action 5 modify_single_port_mode "切换为单端口模式 (443)"
    menu_section "凭据"
    menu_action 6 modify_reality_keypair "重新生成密钥对" "客户端需重新导入"
}

render_modify_hy2() {
    menu_section "当前状态"
    local state="未启用"
    is_hy2_enabled && state="已启用"
    echo "  ${state} · 本机 ${HY2_PORT}/UDP"
    menu_section "设置"
    if is_hy2_enabled; then
        menu_action 1 modify_hy2_enabled "关闭 Hysteria2"
    else
        menu_action 1 modify_hy2_enabled "启用 Hysteria2" "先设置本机 UDP 端口"
    fi
    menu_action 2 modify_hy2_port "修改端口" "本机 UDP 监听端口"
    if is_hy2_enabled; then
        menu_action 3 modify_hy2_password "重新生成密码"
    fi
}

render_modify_socks() {
    menu_section "当前状态"
    if is_socks_enabled; then
        echo "  已启用 · ${SOCKS_USERNAME}@${SOCKS_PORT}/TCP"
        echo "  建议在安全组中仅允许业务服务器的固定 IP 访问该端口。"
        menu_section "设置"
        menu_action 1 modify_socks_disable "关闭 SOCKS5"
        menu_action 2 modify_socks_port "修改端口"
        menu_action 3 modify_socks_username "修改用户名"
        menu_action 4 modify_socks_password "重新生成密码"
    else
        echo "  未启用"
        menu_section "设置"
        menu_action 1 modify_socks_enable "启用 SOCKS5" "用户名密码认证"
    fi
}

render_modify_identity() {
    menu_section "当前节点"
    echo "  ${NODE_NAME} · UUID ${UUID:0:8}…"
    menu_section "设置"
    menu_action 1 modify_node_name "修改节点名称"
    menu_action 2 modify_uuid "重新生成 UUID" "客户端需重新导入"
}

render_modify_argo() {
    menu_section "当前状态"
    if argo_enabled; then
        echo "  $(argo_mode_label) · 订阅本机端口 ${SUBSCRIPTION_PORT}/TCP"
    else
        echo "  未启用"
    fi
    echo "  Argo 通过 Cloudflare 隧道连接，其他协议保持直连。"
    menu_section "隧道模式"
    if argo_quick_enabled; then
        menu_action 1 modify_argo_quick "重新申请临时域名" "trycloudflare.com"
    else
        menu_action 1 modify_argo_quick "使用临时隧道" "trycloudflare.com · 无需域名"
    fi
    if argo_fixed_enabled; then
        menu_action 2 modify_argo_fixed "修改 Token 或域名"
    else
        menu_action 2 modify_argo_fixed "使用固定隧道" "需 Cloudflare Tunnel Token"
    fi
    argo_enabled || return 0
    menu_action 3 modify_argo_disable "关闭 Argo"
    menu_section "订阅"
    menu_action 4 update_argo_subscription_links "更新订阅链接"
    menu_action 5 modify_subscription_port "修改订阅服务端口"
}

render_modify_network() {
    menu_section "当前状态"
    echo "  直连公网 IPv4: $(public_ipv4_override_label)"
    echo "  出站 IP 优先级: $(outbound_ip_strategy_label)"
    menu_section "入站 · 客户端如何连到本机"
    menu_action 1 modify_public_ipv4_override "直连公网 IPv4" "$(public_ipv4_override_label)"
    menu_action 2 modify_link_ipv4_selection "多 IPv4 链接策略"
    menu_section "出站 · 本机如何访问目标网站"
    menu_action 3 modify_outbound_ip_strategy "出站 IP 优先级" "$(outbound_ip_strategy_label)"
}

prompt_modify_action() {
    local result_var="$1" category="$2" title picked
    local -a MENU_ACTIONS=()
    title=$(modify_category_title "$category") || { warn "未知配置分类: ${category}"; return 1; }
    while true; do
        MENU_ACTIONS=()
        clear
        menu_header "$title"
        "render_modify_${category}"
        menu_back
        menu_read_action picked || return 1
        if [[ -n "$picked" ]]; then
            printf -v "$result_var" '%s' "$picked"
            return 0
        fi
        menu_invalid
    done
}

# 以下 modify_* 函数只在 do_modify_config 内调用：通过动态作用域写入其 changed / ports_changed /
# restart_singbox / restart_reality_backend / restart_argo / links_only_changed 标记并读取 old_* 快照。
# 返回非 0 表示取消，调用方会恢复修改前的全部运行参数。
modify_reality_port() {
    local new_reality_port="$REALITY_PORT"
    prompt_port_value new_reality_port "Reality 本机监听" "$REALITY_PORT" \
        "  本机监听 TCP 端口 [${REALITY_PORT}]，输入 0 返回: " true || return 1
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
}

modify_reality_sni() {
    local input=""
    prompt_read input "  新伪装域名: " || return 1
    [[ -n "$input" ]] || return 0
    if ! ensure_reality_probe_dependencies; then
        warn "Reality 域名安全检查依赖不可用，未修改配置"
        return 1
    fi
    if adopt_reality_sni "$input"; then
        changed=true
        restart_singbox=true
        restart_reality_backend=true
    elif reality_sni_is_listed "$input"; then
        warn "该域名未通过 Reality 运行时检查，未修改配置"
    else
        warn "列表外域名须支持 TLS 1.3 + HTTP/2、直接返回 HTTP 200 且不在 Cloudflare 地址上；该域名未通过检查，未修改配置"
    fi
}

modify_uuid() {
    UUID=$(run_singbox generate uuid) && [[ -n "$UUID" ]] || { warn "UUID 生成失败"; return 1; }
    info "新 UUID: $UUID"
    changed=true
    restart_singbox=true
    restart_reality_backend=true
}

modify_reality_keypair() {
    local keypair
    keypair=$(run_singbox generate reality-keypair) || { warn "Reality 密钥对生成失败"; return 1; }
    PRIVATE_KEY=$(echo "$keypair" | grep -i "PrivateKey" | awk '{print $NF}' || true)
    PUBLIC_KEY=$(echo "$keypair" | grep -i "PublicKey"  | awk '{print $NF}' || true)
    SHORT_ID=$(random_hex 4) || SHORT_ID=""
    if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" || -z "$SHORT_ID" ]]; then
        warn "Reality 密钥对生成失败"
        return 1
    fi
    WS_PATH="/${SHORT_ID}"
    info "新密钥对已生成"
    changed=true
    restart_singbox=true
    restart_reality_backend=true
}

modify_node_name() {
    local input=""
    prompt_read input "  新节点名称: " || return 1
    if [[ -n "$input" ]]; then
        NODE_NAME="$input"
        changed=true
    fi
}

modify_hy2_port() {
    local new_hy2_port
    prompt_hy2_port new_hy2_port || return 1
    if [[ "$new_hy2_port" != "$HY2_PORT" ]]; then
        HY2_PORT="$new_hy2_port"
        changed=true
        if is_hy2_enabled; then
            ports_changed=true
            restart_singbox=true
        else
            links_only_changed=true
        fi
    fi
}

modify_hy2_password() {
    HY2_PASSWORD=$(random_base64 16) && [[ -n "$HY2_PASSWORD" ]] || { warn "Hysteria2 密码生成失败"; return 1; }
    info "新 Hysteria2 密码: $HY2_PASSWORD"
    changed=true
    restart_singbox=true
}

modify_single_port_mode() {
    REALITY_PORT=443
    HY2_PORT=443
    info "已切换为单端口模式: 443"
    changed=true
    ports_changed=true
    restart_singbox=true
    restart_reality_backend=true
}

modify_argo_quick() {
    ARGO_ENABLED="true"
    ARGO_TOKEN=""
    ARGO_DOMAIN=""
    clear_argo_best_cf_cache
    changed=true
    restart_singbox=true
    restart_argo=true
}

modify_argo_fixed() {
    local input=""
    menu_header "协议设置 / Argo 隧道 / 固定隧道"
    ARGO_ENABLED="true"
    echo -e "  ${YELLOW}提示: 请确保在 Cloudflare 仪表盘中将该域名转发至 http://127.0.0.1:${SUBSCRIPTION_PORT}${NC}"
    echo -e "  ${RED}注意: 请填写完整的 Token (以 eyJ 开头)，千万不要误填为 Tunnel ID。${NC}"
    prompt_read input "  新 Tunnel Token [${ARGO_TOKEN:0:10}...]: " || return 1
    [[ -n "$input" ]] && ARGO_TOKEN="$input"
    input=""
    prompt_read input "  新自定义域名 [${ARGO_DOMAIN}]: " || return 1
    if [[ -n "$input" ]]; then
        ARGO_DOMAIN="$input"
        ARGO_DOMAIN="${ARGO_DOMAIN#http://}"
        ARGO_DOMAIN="${ARGO_DOMAIN#https://}"
        ARGO_DOMAIN="${ARGO_DOMAIN%/}"
    fi
    if ! argo_fixed_enabled; then
        warn "Tunnel Token 或固定域名无效，已保留原 Argo 配置"
        press_enter
        return 1
    fi
    if [[ "${ARGO_DOMAIN:-}" != "$old_argo_domain" || "${ARGO_TOKEN:-}" != "$old_argo_token" ]]; then
        clear_argo_best_cf_cache
    fi
    changed=true
    restart_singbox=true
    restart_argo=true
}

modify_argo_disable() {
    ARGO_ENABLED="false"
    ARGO_TOKEN=""
    ARGO_DOMAIN=""
    clear_argo_best_cf_cache
    changed=true
    restart_singbox=true
    restart_argo=true
}

modify_subscription_port() {
    local new_subscription_port
    prompt_port_value new_subscription_port "订阅服务" "$SUBSCRIPTION_PORT" "  新订阅服务端口 [${SUBSCRIPTION_PORT}]: " || return 1
    if [[ "$new_subscription_port" != "$SUBSCRIPTION_PORT" ]]; then
        SUBSCRIPTION_PORT="$new_subscription_port"
        changed=true
        ports_changed=true
        restart_argo=true
    fi
}

modify_link_ipv4_selection() {
    local selection_result=0
    prompt_ipv4_link_selection_if_multiple || selection_result=$?
    if (( selection_result != 0 )); then
        if (( selection_result == 2 )); then
            warn "多 IPv4 链接策略当前不可用，请检查公网 IP 检测结果或 IPv4 覆盖设置"
            press_enter
        fi
        return 1
    fi
    if [[ "${LINK_IPV4_SELECTION:-all}" != "$old_link_ipv4_selection" ]]; then
        changed=true
        links_only_changed=true
    fi
}

modify_public_ipv4_override() {
    if ! prompt_public_ipv4_override; then
        press_enter
        return 1
    fi
    if [[ "${PUBLIC_IPV4_OVERRIDE:-}" != "$old_public_ipv4_override" ]]; then
        changed=true
        links_only_changed=true
    fi
}

modify_hy2_enabled() {
    if is_hy2_enabled; then
        HY2_ENABLED="false"
        info "Hysteria2 已关闭"
    else
        local new_hy2_port
        prompt_hy2_port new_hy2_port || return 1
        HY2_PORT="$new_hy2_port"
        HY2_ENABLED="true"
        info "Hysteria2 将启用在 ${HY2_PORT}/UDP"
    fi
    changed=true
    ports_changed=true
    restart_singbox=true
}

modify_socks_enable() {
    prompt_port_value SOCKS_PORT "SOCKS5" "$SOCKS_PORT" \
        "  SOCKS5 TCP 端口 [${SOCKS_PORT}]，输入 0 返回: " true || return 1
    if ! nat_mode_enabled; then SOCKS_PUBLIC_PORT="$SOCKS_PORT"; fi
    SOCKS_ENABLED="true"
    info "SOCKS5 将启用在 ${SOCKS_PORT}/TCP"
    changed=true
    ports_changed=true
    restart_singbox=true
}

modify_socks_port() {
    local new_socks_port
    prompt_port_value new_socks_port "SOCKS5" "$SOCKS_PORT" \
        "  新 SOCKS5 TCP 端口 [${SOCKS_PORT}]，输入 0 返回: " true || return 1
    [[ "$new_socks_port" != "$SOCKS_PORT" ]] || return 0
    SOCKS_PORT="$new_socks_port"
    if ! nat_mode_enabled; then SOCKS_PUBLIC_PORT="$SOCKS_PORT"; fi
    changed=true
    ports_changed=true
    restart_singbox=true
}

modify_socks_username() {
    local input=""
    prompt_read input "  新 SOCKS5 用户名: " || return 1
    if [[ -z "$input" || ${#input} -gt 255 ]]; then
        warn "SOCKS5 用户名长度必须为 1-255 个字符"
        press_enter
        return 1
    fi
    SOCKS_USERNAME="$input"
    changed=true
    restart_singbox=true
}

modify_socks_password() {
    SOCKS_PASSWORD=$(random_hex 16) && [[ -n "$SOCKS_PASSWORD" ]] || { warn "SOCKS5 密码生成失败"; return 1; }
    info "SOCKS5 密码已重新生成"
    changed=true
    restart_singbox=true
}

modify_socks_disable() {
    SOCKS_ENABLED="false"
    info "SOCKS5 已关闭"
    changed=true
    ports_changed=true
    restart_singbox=true
}

modify_outbound_ip_strategy() {
    local sub_choice="" new_strategy=""
    menu_header "网络设置 / 出站 IP 优先级"
    menu_section "当前: $(outbound_ip_strategy_label)"
    echo "  决定代理访问目标网站时走 IPv4 还是 IPv6，与客户端用哪种 IP 连入无关。"
    echo "  仅对客户端交给服务端解析的域名生效（远程 DNS / socks5h）。"
    menu_item 1 "默认" "sing-box 自动选择"
    menu_item 2 "优先 IPv4" "目标无 IPv4 时使用 IPv6"
    menu_item 3 "优先 IPv6" "目标无 IPv6 时使用 IPv4"
    menu_item 4 "仅 IPv4"
    menu_item 5 "仅 IPv6" "仅有 IPv4 的网站将无法访问"
    menu_back "取消"
    prompt_menu_choice sub_choice "  请选择 [0]: " "0 1 2 3 4 5" 0 || return 1
    case "${sub_choice:-0}" in
        1) new_strategy="default" ;;
        2) new_strategy="prefer_ipv4" ;;
        3) new_strategy="prefer_ipv6" ;;
        4) new_strategy="ipv4_only" ;;
        5) new_strategy="ipv6_only" ;;
        0) return 1 ;;
        *) warn "无效选项"; return 1 ;;
    esac
    if [[ "$new_strategy" == "$old_outbound_ip_strategy" ]]; then
        info "出站 IP 优先级未变化"
        press_enter
        return 1
    fi
    case "$new_strategy" in
        prefer_ipv6|ipv6_only)
            if ! fetch_public_ipv6 >/dev/null; then
                if [[ "$new_strategy" == "ipv6_only" ]]; then
                    warn "未检测到 IPv6 出站，不能设为仅 IPv6"
                    press_enter
                    return 1
                fi
                warn "未检测到 IPv6 出站，优先 IPv6 实际仍会使用 IPv4"
            fi
            ;;
        ipv4_only)
            if ! fetch_public_ipv4 >/dev/null; then
                warn "未检测到 IPv4 出站，不能设为仅 IPv4"
                press_enter
                return 1
            fi
            ;;
    esac
    if [[ "${REALITY_BACKEND:-singbox}" == "xray" ]]; then
        warn "Reality 由 Xray 承载，此设置不影响 Reality 流量的出站"
    fi
    OUTBOUND_IP_STRATEGY="$new_strategy"
    info "出站 IP 优先级: $(outbound_ip_strategy_label)"
    changed=true
    restart_singbox=true
}

# 校验并应用 do_modify_config 中已修改的参数；失败时恢复 old_runtime_params 快照。
# 始终返回 0，以保持调用处的 errexit 行为。
apply_modified_config() {
    local PORT_CONFIRM_TITLE="${MENU_CONTEXT} / 端口确认"
    if [[ "$ports_changed" == "true" || "$links_only_changed" != "true" ]] && ! validate_service_ports \
        "$old_reality_port" "$old_hy2_active_port" "$old_subscription_port" false "$old_socks_active_port"; then
        restore_runtime_params "${old_runtime_params[@]}"
        warn "端口检查未通过，已保留原配置"
        press_enter
        return 0
    fi
    if [[ "$ports_changed" == "true" ]] && ! confirm_port_selection; then
        restore_runtime_params "${old_runtime_params[@]}"
        warn "已取消端口修改"
        press_enter
        return 0
    fi
    if [[ "$restart_reality_backend" == "true" && "${REALITY_BACKEND:-singbox}" == "xray" ]] && ! xray_managed_reality; then
        restore_runtime_params "${old_runtime_params[@]}"
        warn "Reality 由 Xray 承载，但 Xray 配置或服务不存在，未修改配置"
        press_enter
        return 0
    fi
    if [[ "$restart_singbox" == "true" ]]; then
        local hy2_requested="${HY2_ENABLED:-false}"
        generate_tls_cert
        if [[ "$hy2_requested" == "true" ]] && ! is_hy2_enabled; then
            restore_runtime_params "${old_runtime_params[@]}"
            warn "Hysteria2 证书不可用，已保留原配置"
            press_enter
            return 0
        fi
    fi
    if [[ "$links_only_changed" != "true" ]] && ! open_service_ports; then
        restore_runtime_params "${old_runtime_params[@]}"
        warn "端口放行失败，已保留原配置"
        press_enter
        return 0
    fi

    if [[ "$restart_singbox" == "true" ]]; then
        write_singbox_config
        local restart_failed=false
        write_singbox_service || restart_failed=true
        local xray_update_required=false
        if [[ "$restart_reality_backend" == "true" && "${REALITY_BACKEND:-singbox}" == "xray" ]]; then
            if ! write_xray_reality_config "$REALITY_SNI" "$REALITY_PORT" "$UUID" "$PRIVATE_KEY" "$SHORT_ID"; then
                restore_runtime_params "${old_runtime_params[@]}"
                write_singbox_config
                warn "Xray Reality 配置更新失败，已保留原配置"
                press_enter
                return 0
            fi
            xray_update_required=true
        fi
        save_params
        info "重启 sing-box..."
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
            return 0
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
            return 0
        fi
    else
        save_params
        success "配置已更新"
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
            return 0
        fi
    fi
    generate_and_show_links
    if ! service_is_active sbm-subscription && argo_enabled; then
        warn "订阅服务未运行，请检查 python3 或服务日志"
    fi
    show_subscription_url
    verify_enabled_protocols || warn "部分协议未通过服务端认证测试；公网连接尚未验证"
    press_enter
}

do_modify_config() {
    local category="${1:-reality}" selected_action
    local MENU_CONTEXT
    MENU_CONTEXT=$(modify_category_title "$category") || { warn "未知配置分类: ${category}"; return; }
    load_params || { warn "未找到配置，请先安装"; press_enter; return; }

    while true; do
        prompt_modify_action selected_action "$category" || return 0
        [[ "$selected_action" == 0 ]] && return 0
        if [[ "${SBM_TEST_MODE:-}" != 1 ]]; then
            sbm_lock_acquire || continue
            if ! sbm_mutation_guard || ! engine_config_guard || ! load_params; then sbm_lock_release; continue; fi
        fi
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
        local old_hy2_enabled="${HY2_ENABLED:-false}"
        local old_socks_port="${SOCKS_PORT}"
        local old_socks_username="${SOCKS_USERNAME}"
        local old_socks_password="${SOCKS_PASSWORD}"
        local old_socks_enabled="${SOCKS_ENABLED:-false}"
        local old_socks_public_port="${SOCKS_PUBLIC_PORT:-${SOCKS_PORT}}"
        local old_outbound_ip_strategy="${OUTBOUND_IP_STRATEGY:-default}"
        local old_reality_sni_custom="${REALITY_SNI_CUSTOM:-}"
        local old_hy2_active_port="" old_socks_active_port=""
        [[ "$old_hy2_enabled" == "true" ]] && old_hy2_active_port="$old_hy2_port"
        [[ "$old_socks_enabled" == "true" ]] && old_socks_active_port="$old_socks_port"
        local -a old_runtime_params=(
            "$old_uuid" "$old_short_id" "$old_private_key" "$old_public_key"
            "$old_reality_port" "$old_reality_sni" "$old_ws_port" "$old_ws_path"
            "$old_node_name" "$old_hy2_port" "$old_hy2_password" "$old_hy2_sni"
            "$old_hy2_masquerade_url" "$old_subscription_port" "$old_argo_domain" "$old_argo_token"
            "$old_argo_best_cf_domain" "$old_argo_best_cf_domain_ipv4" "$old_argo_best_cf_domain_ipv6"
            "$old_link_ipv4_selection" "$old_public_ipv4_override" "$old_nat_mode"
            "$old_reality_public_port" "$old_argo_enabled" "$old_hy2_enabled"
            "$old_socks_port" "$old_socks_username" "$old_socks_password" "$old_socks_enabled" "$old_socks_public_port"
            "$old_outbound_ip_strategy" "$old_reality_sni_custom"
        )
        case "$selected_action" in
            0) return ;;
            # 以下两项自行写配置、重启并展示链接，不经过快照恢复与 apply_modified_config。
            do_reoptimize_reality_sni|do_scan_reality_neighbor_sni)
                "$selected_action" || true
                engine_refresh_after_change || warn "受管版本验证未完成"
                sbm_lock_release
                press_enter
                continue
                ;;
            update_argo_subscription_links)
                update_argo_subscription_links || warn "Argo 订阅链接更新失败"
                sbm_lock_release
                press_enter
                continue
                ;;
        esac

        local changed=false
        local ports_changed=false
        local restart_singbox=false
        local restart_reality_backend=false
        local restart_argo=false
        local links_only_changed=false
        if ! "$selected_action"; then
            restore_runtime_params "${old_runtime_params[@]}"
            sbm_lock_release
            continue
        fi
        [[ "$changed" == "true" ]] && apply_modified_config
        if [[ "$changed" == true ]]; then engine_refresh_after_change || warn "受管版本验证未完成"; fi
        sbm_lock_release
    done
}
# ─── 查看链接 ────────────────────────────────────────────────
# 不暂停，供 sbm links 直接调用；未安装时返回 1。
show_links() {
    load_params || return 1
    ensure_subscription_service_if_enabled || warn "订阅服务未成功启动"
    refresh_argo_domain_if_needed
    generate_and_show_links
    show_subscription_url
}

do_show_links() {
    show_links || warn "未找到配置，请先安装"
    press_enter
}

# ─── 公网连通性排查 ──────────────────────────────────────────
# 先排除本机原因（未监听 / 本机防火墙未放行），否则外部检测必然全红。
report_local_tcp_port() {
    local label="$1" port="$2" backend="$3"
    if [[ -n "$(get_port_listeners "$port" tcp)" ]]; then
        echo -e "  ${GREEN}✓${NC} ${label} 本机 ${port}/TCP 正在监听"
    else
        echo -e "  ${RED}✗${NC} ${label} 本机 ${port}/TCP 未监听：先在「服务管理」启动服务或查看日志"
    fi
    [[ "$backend" == "none" ]] && return 0
    if firewall_port_open "$backend" "$port" tcp; then
        echo -e "  ${GREEN}✓${NC} ${label} $(firewall_backend_label "$backend") 已放行 ${port}/TCP"
    else
        echo -e "  ${RED}✗${NC} ${label} $(firewall_backend_label "$backend") 未找到 ${port}/TCP 放行规则"
    fi
}

# 本机检查无法确认服务商防火墙、NAT 映射或线路封锁，交给外部 TCP 探测判断。
show_connectivity_guide() {
    menu_header "服务管理 / 公网连通性排查"
    load_params || { warn "未找到配置，请先安装"; return 1; }
    [[ -n "${PUBLIC_IPV4:-}${PUBLIC_IPV4_OVERRIDE:-}" ]] || refresh_public_ip_stack >/dev/null 2>&1 || true

    local backend
    backend=$(detect_firewall_backend)
    menu_section "本机预检"
    report_local_tcp_port Reality "$REALITY_PORT" "$backend"
    if is_socks_enabled; then
        report_local_tcp_port SOCKS5 "$SOCKS_PORT" "$backend"
    fi

    local ip found=false
    menu_section "在浏览器中打开（外部 TCP 检测）"
    while IFS= read -r ip; do
        [[ -n "$ip" ]] || continue
        found=true
        echo -e "  Reality  ${BOLD}https://tcp.ping.pe/${ip}:$(reality_share_port)${NC}"
        if is_socks_enabled; then
            echo -e "  SOCKS5   ${BOLD}https://tcp.ping.pe/${ip}:$(socks_share_port)${NC}"
        fi
    done < <(selected_public_ipv4_list 2>/dev/null)
    if [[ "$found" != "true" ]]; then
        echo "  未检测到可直连的公网 IPv4；可在「网络设置 → 直连公网 IPv4」手动指定。"
    fi

    menu_section "结果判断"
    echo -e "  ${GREEN}全部绿色${NC}      端口未被封锁；仍不可用时检查客户端参数，或在「协议设置 → Reality」重新优选伪装域名"
    echo -e "  ${RED}全部红色${NC}      外部均无法连接：先执行「协议自检」，再检查本机防火墙"
    echo -e "  ${YELLOW}仅中国红色${NC}    端口疑似被封：在「协议设置 → Reality → 修改端口」更换端口后重新导入节点"
    echo ""
    echo -e "  ${DIM}Hysteria2 使用 UDP，不适用此 TCP 检测；Argo 经 Cloudflare 转发，无需检测端口。${NC}"
    echo -e "  ${DIM}打开链接会把服务器 IP 和端口提交给 tcp.ping.pe 检测；脚本本身不访问该网站。${NC}"
}

do_connectivity_guide() {
    show_connectivity_guide || true
    press_enter
}

# ─── 启动 / 停止 / 重启 ──────────────────────────────────────
do_start() {
    menu_header "服务管理 / 启动服务"
    info "启动服务..."
    local core_ready=true result=0
    service_start sing-box && success "sing-box 已启动" || { core_ready=false; result=1; warn "sing-box 启动失败"; }
    if [[ "$core_ready" == true ]] && ! engine_finish_start; then
        core_ready=false; result=1; warn "sing-box 启动验证未通过"
    fi
    if load_params; then
        # 临时隧道的域名检查会访问源站，订阅网关必须先就绪。
        local subscription_ready=true
        ensure_subscription_service_if_enabled || { subscription_ready=false; result=1; warn "订阅服务启动失败"; }
        if argo_enabled; then
            if [[ "$subscription_ready" == "true" && "$core_ready" == "true" ]]; then
                service_start argo-tunnel && success "argo-tunnel 已启动" || { result=1; warn "argo-tunnel 启动失败"; }
                refresh_argo_domain_if_needed
            else
                warn "sing-box 或订阅网关未就绪，未启动 Argo 隧道"
            fi
        fi
        if [[ "$result" == 0 ]]; then
            if ! save_params || ! build_share_links || ! write_subscription_assets; then
                warn "服务已启动，但链接信息更新失败"
                result=1
            fi
        fi
    else
        warn "无法读取已保存参数，其他服务未操作"
        result=1
    fi
    press_enter
    return "$result"
}

do_stop() {
    menu_header "服务管理 / 停止服务"
    info "停止服务..."
    local svc state result=0
    for svc in sing-box argo-tunnel sbm-subscription; do
        if [[ "$svc" != sing-box ]] && ! service_exists "$svc"; then continue; fi
        service_stop "$svc" 2>/dev/null || true
        state=$(service_runtime_state "$svc") || state=unknown
        if [[ "$state" == stopped ]]; then
            success "${svc} 已停止"
        else
            warn "${svc} 未确认停止"
            result=1
        fi
    done
    press_enter
    return "$result"
}

do_restart() {
    menu_header "服务管理 / 重启服务"
    info "重启服务..."
    local core_ready=true result=0
    service_restart sing-box && success "sing-box 已重启" || { core_ready=false; result=1; warn "sing-box 重启失败"; }
    if [[ "$core_ready" == true ]] && ! engine_finish_start; then
        core_ready=false; result=1; warn "sing-box 重启验证未通过"
    fi
    if load_params; then
        local subscription_ready=true
        ensure_subscription_service_if_enabled || { subscription_ready=false; result=1; warn "订阅服务重启失败"; }
        if argo_enabled; then
            if [[ "$subscription_ready" == "true" && "$core_ready" == "true" ]]; then
                if service_restart argo-tunnel; then
                    success "argo-tunnel 已重启"
                else
                    result=1
                    warn "argo-tunnel 重启失败"
                fi
                if [[ "$result" == 0 ]] && argo_quick_enabled; then
                    sleep 3
                    fetch_argo_domain || { result=1; warn "Argo 已重启，但尚未取得新的临时域名"; }
                fi
            else
                warn "sing-box 或订阅网关未就绪，未重启 Argo 隧道"
            fi
        fi
        if [[ "$result" == 0 ]]; then
            if ! save_params || ! build_share_links || ! write_subscription_assets; then
                warn "服务已启动，但链接信息更新失败"
                result=1
            fi
        fi
        if [[ "$result" == 0 ]] && argo_enabled && [[ -n "${ARGO_DOMAIN:-}" ]]; then
            info "Argo 域名: ${ARGO_DOMAIN}"
        fi
    else
        warn "无法读取已保存参数，其他服务未操作"
        result=1
    fi
    press_enter
    return "$result"
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
# 无参数时从内置列表优选；参数 neighbor 改为扫描本机同网段的邻居域名。
do_reoptimize_reality_sni() {
    local selector="select_reality_sni" action="重新优选" title="优选伪装域名"
    case "${1:-}" in
        "") ;;
        neighbor|--neighbor)
            selector="select_reality_neighbor_sni"
            action="扫描同网段邻居域名"
            title="扫描同网段邻居域名"
            ;;
        *)
            warn "未知参数: ${1}（可用: neighbor）"
            return 1
            ;;
    esac
    engine_config_guard || return 1
    menu_header "协议设置 / Reality / ${title}"
    if ! load_params; then
        warn "未安装，无法重新优选 Reality 伪装域名"
        return 1
    fi

    local old_sni="${REALITY_SNI:-}"
    local prev_sni="${REALITY_SNI_PREV:-}"
    local old_custom="${REALITY_SNI_CUSTOM:-}"
    local reality_service="sing-box"
    xray_managed_reality && reality_service="xray"
    info "当前 Reality 伪装域名: ${old_sni:-未设置}，开始${action}（自动避开当前与上一次域名）..."

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
    if ! "$selector"; then
        REALITY_SNI="$old_sni"
        REALITY_SNI_CUSTOM="$old_custom"
        REALITY_SNI_EXCLUDE=""
        warn "未能优选到可用域名，已保留原伪装域名: ${old_sni:-未设置}"
        return 1
    fi
    REALITY_SNI_EXCLUDE=""

    if [[ -z "${REALITY_SNI:-}" ]]; then
        REALITY_SNI="$old_sni"
        REALITY_SNI_CUSTOM="$old_custom"
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
            REALITY_SNI_CUSTOM="$old_custom"
            return 1
        fi
    else
        generate_tls_cert
        write_singbox_config
        if ! write_singbox_service; then
            REALITY_SNI="$old_sni"
            REALITY_SNI_PREV="$prev_sni"
            REALITY_SNI_CUSTOM="$old_custom"
            write_singbox_config
            warn "sing-box 服务文件更新失败，已恢复原伪装域名"
            return 1
        fi
    fi
    save_params

    if ! service_restart "$reality_service"; then
        warn "${reality_service} 重启失败，正在回滚到原伪装域名: ${old_sni}"
        REALITY_SNI="$old_sni"
        REALITY_SNI_PREV="$prev_sni"
        REALITY_SNI_CUSTOM="$old_custom"
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
        REALITY_SNI_CUSTOM="$old_custom"
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
    if [[ "$selector" == "select_reality_neighbor_sni" ]]; then
        info "邻居站点不受本项目审核，可能随时下线或改版；失效时执行 sbm resni 可回到内置列表。"
    fi
    ensure_subscription_service_if_enabled || warn "订阅服务启动失败"
    refresh_argo_domain_if_needed
    generate_and_show_links
    show_subscription_url
    engine_refresh_after_change || return 1
    return 0
}

do_scan_reality_neighbor_sni() {
    do_reoptimize_reality_sni neighbor
}

# ─── 应用当前版本配置 (一键同步) ─────────────────────────────
# 用当前已保存的凭证 (UUID / 端口 / 域名 / 密钥均不变) 按新版本模板
# 重写服务端配置并重启，再按新格式重新生成链接。适用于升级脚本后
# 让服务端配置与当前稳定链接格式同步生效。
do_apply_latest() {
    engine_config_guard || return 1
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
    write_singbox_service || return 1
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
    engine_refresh_after_change || return 1
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
    menu_header "服务管理 / 运行状态"
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
    local choice
    menu_header "服务管理 / 日志"
    menu_section "选择服务"
    menu_item 1 "sing-box 日志"
    menu_item 2 "argo-tunnel 日志"
    menu_item 3 "订阅服务日志"
    menu_back
    prompt_menu_choice choice "  请选择: " "0 1 2 3" || return
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
    local choice svc state expected result=0 action
    local -a services=(sing-box)
    menu_header "服务管理 / 开机自启"
    menu_section "服务设置"
    menu_item 1 "开启" "sing-box 及已配置附加服务"
    menu_item 2 "关闭" "全部服务"
    menu_back
    prompt_menu_choice choice "  请选择: " "0 1 2" || return
    [[ "$choice" == 0 ]] && return
    if [[ "${SBM_TEST_MODE:-}" != 1 ]]; then
        sbm_lock_acquire || return 1
        sbm_mutation_guard || { sbm_lock_release; return 1; }
    fi
    if [[ "$choice" == 1 ]]; then
        action=service_enable; expected=enabled
        if load_params 2>/dev/null && argo_enabled; then services+=(argo-tunnel sbm-subscription); fi
    else
        action=service_disable; expected=disabled
        for svc in argo-tunnel sbm-subscription; do
            if service_exists "$svc"; then services+=("$svc"); fi
        done
    fi
    for svc in "${services[@]}"; do
        if ! "$action" "$svc" 2>/dev/null; then
            warn "${svc} 开机自启设置失败"
            result=1
            continue
        fi
        state=$(service_boot_state "$svc") || state=unknown
        if [[ "$state" != "$expected" ]]; then
            warn "${svc} 开机自启状态未确认"
            result=1
        fi
    done
    if [[ "$result" == 0 ]]; then
        [[ "$choice" == 1 ]] && success "已开启开机自启" || success "已关闭开机自启"
    fi
    sbm_lock_release
    press_enter
    return "$result"
}

# ─── 更新组件 ────────────────────────────────────────────────
do_upgrade_singbox() {
    singbox_version_menu
}

do_upgrade_cloudflared() {
    menu_header "系统维护 / 更新 cloudflared"
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
    press_enter
}

do_upgrade_script() {
    menu_header "系统维护 / 更新管理脚本"
    if ! download_manager_command; then
        warn "更新失败，请检查网络或手动更新"
        press_enter
        return
    fi
    # 从新下载的脚本中提取版本号
    local new_ver
    new_ver=$(grep -m1 '^SCRIPT_VERSION=' "$MANAGER_COMMAND" | cut -d'"' -f2 2>/dev/null || echo "未知")
    success "脚本已更新: v${SCRIPT_VERSION} → v${new_ver}"
    echo ""
    info "当前配置和服务未受影响，不会重写配置或重启服务。"
    info "如需让服务端配置使用当前稳定模板，升级后执行: sbm apply"
    echo ""
    prompt_read _ "按 Enter 重启面板并进入新版本..." || true
    sbm_lock_release
    exec bash "$MANAGER_COMMAND"
}

# ─── 重新安装 ────────────────────────────────────────────────
do_reinstall() {
    menu_header "系统维护 / 重新安装节点"
    warn "将重新生成 UUID、Reality 密钥和端口，客户端需重新导入节点"
    local confirm=""
    prompt_read confirm "  确认重新安装？(y/N): " || true
    [[ "$confirm" =~ ^[Yy]$ ]] || { info "已取消"; press_enter; return; }
    do_primary_install
}

# ─── 卸载 ────────────────────────────────────────────────────
do_uninstall() {
    menu_header "系统维护 / 卸载"
    warn "即将卸载 sing-box 和 Argo 隧道"
    local confirm=""
    prompt_read confirm "  确认卸载？(y/N): " || true
    [[ "$confirm" =~ ^[Yy]$ ]] || { info "已取消"; press_enter; return; }

    service_stop sing-box 2>/dev/null || true
    service_disable sing-box 2>/dev/null || true
    service_stop argo-tunnel 2>/dev/null || true
    service_disable argo-tunnel 2>/dev/null || true
    service_stop sbm-subscription 2>/dev/null || true
    service_disable sbm-subscription 2>/dev/null || true
    if [[ -e "$SBM_STATE_DIR/engine.json" ]]; then
        engine_python remove-managed || { warn "受管版本清理未完成，停止卸载"; return 1; }
    fi
    disable_cfopt_auto 2>/dev/null || true
    rm -f "$ARGO_SERVICE"
    rm -f "$ARGO_OPENRC_SERVICE"
    rm -f "$SUBSCRIPTION_SERVICE"
    rm -f "$SUBSCRIPTION_OPENRC_SERVICE"
    rm -f "$SINGBOX_OPENRC_SERVICE"
    rm -f "$SINGBOX_SYSTEMD_OVERRIDE_FILE"
    rmdir "$SINGBOX_SYSTEMD_DROPIN_DIR" 2>/dev/null || true
    remove_singbox_release_install
    service_daemon_reload

    case "$(package_manager)" in
        apt) apt-get remove -y sing-box 2>/dev/null || true ;;
        dnf) dnf remove -y sing-box 2>/dev/null || true ;;
        yum) yum remove -y sing-box 2>/dev/null || true ;;
        apk) apk del sing-box 2>/dev/null || true ;;
    esac

    # 本脚本安装的 cloudflared 是普通文件；符号链接通常指向用户自装的 cloudflared，保留。
    [[ -L /usr/local/bin/cloudflared ]] || rm -f /usr/local/bin/cloudflared
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
    if [[ -e "$SBM_STATE_DIR/engine.json" ]] && ! resolve_singbox_binary >/dev/null 2>&1; then
        menu_action 1 do_doctor_menu "统一诊断" "受管内核状态异常"
        menu_action 2 singbox_version_menu "sing-box 版本管理" "检查或恢复"
    elif is_installed; then
        menu_action 1 do_show_links "查看节点链接" "分享链接 / 订阅地址"
        menu_action 2 protocol_menu "协议设置" "Reality / Hysteria2 / SOCKS5 / Argo"
        menu_action 3 "do_modify_config network" "网络设置" "公网 IPv4 / 链接策略 / 出站 IP 优先级"
        menu_action 4 service_menu "服务管理" "启停 / 日志 / 自检 / 连通性排查"
        menu_action 5 maintenance_menu "系统维护" "更新 / 配置同步 / 重装 / 卸载"
    elif has_stale_config; then
        menu_action 1 do_primary_install "安装节点" "将覆盖旧配置"
        menu_action 2 do_upgrade_script "更新管理脚本"
    else
        menu_action 1 do_primary_install "安装节点" "Reality 主节点，可选 Argo / SOCKS5 / Hysteria2"
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
    menu_action 2 "do_modify_config hy2" "Hysteria2" "$(feature_state_label is_hy2_enabled "${HY2_PORT}/UDP")"
    menu_action 3 "do_modify_config socks" "SOCKS5" "$(feature_state_label is_socks_enabled "$(socks_share_port)/TCP")"
    menu_section "隧道"
    menu_action 4 "do_modify_config argo" "Argo 隧道" "$(argo_mode_label)"
    menu_section "通用"
    menu_action 5 "do_modify_config identity" "节点名称与 UUID" "${NODE_NAME:-}"
}

# 进入时读取一次参数；子页面修改后全局变量已同步，重绘无需再读。
protocol_menu() {
    load_params_readonly >/dev/null 2>&1 || true
    run_menu "协议设置" render_protocol_menu
}

render_service_menu() {
    menu_section "运行控制"
    menu_action 1 do_start_menu "启动服务"
    menu_action 2 do_stop "停止服务"
    menu_action 3 do_restart_menu "重启服务"
    menu_section "诊断"
    menu_action 4 do_status "查看状态"
    menu_action 5 do_logs "查看日志"
    menu_action 6 do_verify_menu "协议自检" "本机认证与流量测试"
    menu_action 7 do_connectivity_guide "公网连通性排查" "外部检测端口是否被封"
    menu_section "设置"
    menu_action 8 do_boot_manage "开机自启"
    menu_action 9 do_doctor_menu "统一诊断" "本机只读检查"
}

# 菜单内保留操作失败提示后继续交互；CLI 仍保留非零退出状态。
do_start_menu() { do_start || true; }
do_restart_menu() { do_restart || true; }

service_menu() {
    run_menu "服务管理" render_service_menu
}

render_maintenance_menu() {
    menu_section "更新"
    menu_action 1 do_upgrade_script "更新管理脚本" "不改动配置和服务"
    menu_action 2 singbox_version_menu "sing-box 版本管理" "稳定版 / 指定版本 / 回退"
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
            *)
                # shellcheck disable=SC2086 # 按空格拆分为函数名和参数
                sbm_menu_action "$action" || true
                ;;
        esac
    done
}

# ════════════════════════════════════════════════════════════
#  入口
# ════════════════════════════════════════════════════════════

main() {
    local SBM_NONINTERACTIVE=false
    [[ -n "${1:-}" ]] && SBM_NONINTERACTIVE=true
    case "${1:-}" in
        doctor) [[ $# == 1 ]] || return 2; do_doctor; return $? ;;
        versions) engine_cli "$@"; return $? ;;
        --help|-h) show_usage; return 0 ;;
        upgrade|rollback) engine_cli "$@"; return $? ;;
    esac
    check_root
    detect_os

    # 命令行快捷参数
    # 若用户使用了旧命令名通过兼容链接启动，提示其换用新命令
    if [[ "$(basename "$0")" == "sing-box-manager" ]]; then
        warn "sing-box-manager 命令已更名，推荐后续直接输入: sbm"
        sleep 1
    fi

    case "${1:-}" in
        install)     sbm_with_lock do_primary_install ;;
        links|sub)   sbm_with_lock show_links ;;
        start)       sbm_with_lock do_start ;;
        stop)        sbm_with_lock do_stop ;;
        restart)     sbm_with_lock do_restart ;;
        resni|reality-sni) sbm_with_lock do_reoptimize_reality_sni "${2:-}" ;;
        apply|sync)  sbm_with_lock do_apply_latest ;;
        cfopt|refresh-cf|cfopt-auto) warn "CF 优选现已在 links/sub 命令中自动执行" ;;
        status)      do_status ;;
        verify)      sbm_with_lock do_verify ;;
        check)       show_connectivity_guide ;;
        uninstall)   sbm_with_lock do_uninstall ;;
        --help|-h)
            show_usage
            return 0
            ;;
        "") main_menu ;;
        *)
            echo -e "${RED}[ERROR]${NC} 未知命令: ${1}" >&2
            echo "执行 'sbm --help' 查看可用命令" >&2
            return 1
            ;;
    esac
}

show_usage() {
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
            echo "  resni neighbor  扫描同网段邻居域名作为 Reality 伪装域名（访问第三方接口）"
            echo "  apply           按当前版本模板重写配置并重启 (升级后一键同步)"
            echo "  status          查看状态"
            echo "  verify          对启用协议执行限时认证与流量测试"
            echo "  check           输出公网端口外部检测地址与结果判断"
            echo "  doctor          本机只读诊断（不联网、不修改配置）"
            echo "  versions sing-box                查看当前与上一版本"
            echo "  upgrade sing-box [--version X.Y.Z] --yes  更新稳定版"
            echo "  rollback sing-box --yes           回退上一版本或恢复中断操作"
            echo "  uninstall       卸载"
}

sbm_menu_action() {
    local action="$1"
    case "$action" in
        protocol_menu|service_menu|maintenance_menu|singbox_version_menu|do_doctor_menu|do_status|do_logs|do_boot_manage|do_modify_config\ *)
            # shellcheck disable=SC2086 # Only menu_action's registered function/arguments.
            $action
            ;;
        *)
            # shellcheck disable=SC2086
            sbm_with_lock $action
            ;;
    esac
}

if [[ "${SBM_TEST_MODE:-}" != "1" ]]; then
    main "$@"
fi
