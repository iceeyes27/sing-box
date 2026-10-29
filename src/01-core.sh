# ─── 常量 ─────────────────────────────────────────────────────
SCRIPT_VERSION="3.2.0"
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
SCRIPT_URL="https://raw.githubusercontent.com/iceeyes27/sing-box/main/install.sh"
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
            # shellcheck disable=SC2086 # 按空格拆分为函数名和参数
            *) $action ;;
        esac
    done
}

press_enter() {
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
