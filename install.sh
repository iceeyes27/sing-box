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
SCRIPT_VERSION="2.7.10"
DEFAULT_REALITY_SNI="www.microsoft.com"
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
PARAMS_FILE="${CONFIG_DIR}/.params"
SINGBOX_BIN_DIR="/usr/local/bin"
SINGBOX_BIN_PATH="${SINGBOX_BIN_DIR}/sing-box"
# 旧版 CF 优选文件，仅用于卸载清理。
CF_DOMAINS_FILE="${CONFIG_DIR}/cf_domains.txt"
LINK_FILE="${CONFIG_DIR}/share-links.txt"
SUBSCRIPTION_FILE="${CONFIG_DIR}/subscription.txt"
SUBSCRIPTION_ENV_FILE="${CONFIG_DIR}/sbm-subscription.env"
SUBSCRIPTION_SERVER="/usr/local/bin/sbm-subscription-server.py"
SUBSCRIPTION_SERVICE="/etc/systemd/system/sbm-subscription.service"
SUBSCRIPTION_OPENRC_SERVICE="/etc/init.d/sbm-subscription"
SUBSCRIPTION_PORT=24630
RELAY_SCRIPT_TEMPLATE="${TMPDIR:-/tmp}/sbm-relay-install.XXXXXX.sh"
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
SINGBOX_OPENRC_SERVICE="/etc/init.d/sing-box"
SINGBOX_SYSTEMD_DROPIN_DIR="/etc/systemd/system/sing-box.service.d"
SINGBOX_SYSTEMD_OVERRIDE_FILE="${SINGBOX_SYSTEMD_DROPIN_DIR}/override.conf"
HY2_DEFAULT_PORT=8443
HY2_DEFAULT_SNI="bing.com"
HY2_DEFAULT_MASQUERADE_URL="https://www.bing.com"
TIME_SKEW_THRESHOLD=30
LOW_MEMORY_SWAP_FILE="/swapfile.sbm-install"
LOW_MEMORY_SWAP_CREATED=false

# Reality 伪装域名候选列表
# Reality 客户端在「国内→VPS」这条连接上，线路里声称访问的就是这个 SNI。
# 一旦该域名被 GFW 按 SNI 封锁 / 限速 / 偶发重置(即「半被墙」，如 amazon.com)，
# 你的 Reality 隧道会一并继承同样的命运。挑选标准(第 1 条是硬性底线):
#   1) 「国内一定能通」——GFW 不按 SNI 封锁/限速，国内可稳定握手;
#   2) 稳定支持 TLS 1.3 + HTTP/2(Reality 转发所需);
#   3) 境外高信誉大厂站点，封锁代价高，借用其 TLS 身份更可信。
# 注意:select_reality_sni 的实测跑在「境外 VPS」上，只能验证 TLS1.3+h2 与握手
# 延迟，无法发现「国内是否被墙」。因此本列表必须人工保证全部「国内可达」，
# 不要把半被墙站点(amazon / mozilla / swift 等)放进来——服务端测不出来。
# 国内 CDN 落地反而是优点(说明 GFW 不会封)，无需刻意回避。
REALITY_SNI_LIST=(
    "www.microsoft.com"  # Azure/Akamai 中国 CDN，国内稳定可达
    "www.apple.com"      # Apple 中国 CDN，国内稳定可达
    "gateway.icloud.com" # iCloud 国内正常使用
    "itunes.apple.com"   # Apple，国内可达
    "www.tesla.com"      # 特斯拉在华运营，国内可达
    "www.intel.com"      # Intel，国内可达
    "www.nvidia.com"     # NVIDIA，国内可达
    "www.amd.com"        # AMD，国内可达
    "www.ibm.com"        # IBM，国内可达
    "www.cisco.com"      # Cisco，在华运营，国内可达
    "www.dell.com"       # Dell，在华运营，国内可达
    "www.hp.com"         # HP/惠普，在华运营，国内可达
    "www.qualcomm.com"   # 高通，在华运营，国内可达
    "www.samsung.com"    # 三星，在华运营，国内可达
    "www.sony.com"       # 索尼，在华运营，国内可达
    "www.oracle.com"     # Oracle，在华运营，国内可达
    "www.vmware.com"     # VMware，企业级站点，国内可达
)

# ─── 颜色 ─────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

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
    [[ -n "${ARGO_TOKEN:-}" ]] && is_valid_hostname "${ARGO_DOMAIN:-}"
}
success() { echo -e "${GREEN}${BOLD}[OK]${NC} $*"; }

separator() {
    echo -e "${DIM}─────────────────────────────────────────────${NC}"
}

press_enter() {
    echo ""
    prompt_read _ "按 Enter 返回主菜单..." || true
}

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
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
    elif command -v lsb_release &>/dev/null; then
        OS=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
    else
        OS="unknown"
    fi

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  ARCH_CF="amd64" ;;
        aarch64) ARCH_CF="arm64" ;;
        armv7l)  ARCH_CF="arm"   ;;
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
    local xray_config="${XRAY_CONFIG_FILE:-/etc/xray/config.json}"
    [[ -f "$xray_config" ]] && service_exists xray
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

reality_share_port() {
    if nat_mode_enabled; then
        printf '%s' "${REALITY_PUBLIC_PORT:-${REALITY_PORT}}"
    else
        printf '%s' "${REALITY_PORT}"
    fi
}

hy2_share_port() {
    if nat_mode_enabled; then
        printf '%s' "${HY2_PUBLIC_PORT:-${HY2_PORT}}"
    else
        printf '%s' "${HY2_PORT}"
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
    UUID SHORT_ID PRIVATE_KEY PUBLIC_KEY REALITY_PORT REALITY_SNI REALITY_SNI_PREV WS_PORT WS_PATH NODE_NAME
    SUB_TOKEN SUBSCRIPTION_PORT ARGO_DOMAIN ARGO_TOKEN ARGO_BEST_CF_DOMAIN
    ARGO_BEST_CF_DOMAIN_IPV4 ARGO_BEST_CF_DOMAIN_IPV6 LINK_IPV4_SELECTION PUBLIC_IPV4_OVERRIDE
    HY2_PORT HY2_PASSWORD HY2_SNI HY2_MASQUERADE_URL HY2_ENABLED
    NAT_MODE REALITY_PUBLIC_PORT HY2_PUBLIC_PORT
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
    printf '%s=%s\n' "$key" "$(shell_quote "$value")"
}

random_hex() {
    local bytes="$1" value
    if command -v openssl &>/dev/null; then
        openssl rand -hex "$bytes"
        return $?
    fi
    if command -v sing-box &>/dev/null; then
        sing-box generate rand "$bytes" --hex 2>/dev/null && return 0
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
    mkdir -p "$CONFIG_DIR"
    : > "$PARAMS_FILE"
    chmod 600 "$PARAMS_FILE"
    local key
    for key in "${PARAM_KEYS[@]}"; do
        write_param "$key" >> "$PARAMS_FILE"
    done
    chown root:root "$PARAMS_FILE" 2>/dev/null || true
}

load_params() {
    if [[ -f "$PARAMS_FILE" ]]; then
        load_param_file
        # 兼容旧版本: 逐字段补齐 Hysteria2 / Argo Token 参数，绝不覆盖已有值
        local need_save=false
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
        if [[ -z "${HY2_MASQUERADE_URL:-}" ]]; then
            HY2_MASQUERADE_URL="${HY2_DEFAULT_MASQUERADE_URL}"
            need_save=true
        fi
        if [[ -z "${HY2_ENABLED:-}" ]]; then
            HY2_ENABLED="true"
            need_save=true
        fi
        if [[ -z "${ARGO_TOKEN:-}" ]]; then
            ARGO_TOKEN=""
            # need_save 不标记，除非有实质性变化
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
        if ! validate_port "${HY2_PUBLIC_PORT:-}" "NAT Hysteria2 公网映射" >/dev/null 2>&1; then
            HY2_PUBLIC_PORT="${HY2_PORT}"
            need_save=true
        fi
        [[ "$need_save" == "true" ]] && save_params
        return 0
    fi
    return 1
}

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
    return 0
}

install_manager_from_file() {
    local source_path="$1"

    manager_script_valid "$source_path" || return 1
    mkdir -p "$(dirname "$MANAGER_COMMAND")" 2>/dev/null || return 1

    if command -v install >/dev/null 2>&1; then
        install -m 0755 "$source_path" "$MANAGER_COMMAND" 2>/dev/null || return 1
    else
        cp "$source_path" "$MANAGER_COMMAND" 2>/dev/null || return 1
        chmod +x "$MANAGER_COMMAND" 2>/dev/null || return 1
    fi

    manager_script_valid "$MANAGER_COMMAND" || return 1
    chmod +x "$MANAGER_COMMAND" 2>/dev/null || true
    ensure_command_aliases
    hash -r 2>/dev/null || true
    return 0
}

download_manager_command() {
    local tmp_file
    tmp_file=$(mktemp) || return 1

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$SCRIPT_URL" -o "$tmp_file" 2>/dev/null || {
            rm -f "$tmp_file"
            return 1
        }
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$tmp_file" "$SCRIPT_URL" 2>/dev/null || {
            rm -f "$tmp_file"
            return 1
        }
    else
        rm -f "$tmp_file"
        return 1
    fi

    install_manager_from_file "$tmp_file"
    local result=$?
    rm -f "$tmp_file"
    return "$result"
}

install_manager_command() {
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

clear_argo_best_cf_cache() {
    ARGO_BEST_CF_DOMAIN=""
    ARGO_BEST_CF_DOMAIN_IPV4=""
    ARGO_BEST_CF_DOMAIN_IPV6=""
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
    HY2_PUBLIC_PORT="${24:-${HY2_PORT}}"
    reset_public_ip_cache
}
# ─── 安装组件 ────────────────────────────────────────────────
get_meminfo_kb() {
    local key="$1" name value unit
    [[ -r /proc/meminfo ]] || return 1
    while read -r name value unit; do
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
    command -v sing-box &>/dev/null
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

    version=$(curl -fsSL "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null \
        | awk -F'"' '/"tag_name"/ { gsub(/^v/, "", $4); print $4; exit }' || true)

    if [[ -z "$version" ]]; then
        latest_url=$(curl -fsSIL -o /dev/null -w '%{url_effective}' \
            "https://github.com/SagerNet/sing-box/releases/latest" 2>/dev/null || true)
        version="${latest_url##*/v}"
    fi

    [[ "$version" =~ ^[0-9]+(\.[0-9]+)+$ ]] || return 1
    echo "$version"
}

install_singbox_from_official_tarball() {
    local version arch url tmp_bin archive_member

    arch=$(get_singbox_release_arch) || return 1
    version=$(get_latest_singbox_version) || return 1
    url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-${arch}-musl.tar.gz"
    archive_member="sing-box-${version}-linux-${arch}-musl/sing-box"
    tmp_bin="${SINGBOX_BIN_DIR}/.sing-box.${$}.tmp"

    info "下载 sing-box 官方二进制: v${version} (${arch}-musl)"
    if ! mkdir -p "$SINGBOX_BIN_DIR"; then
        return 1
    fi
    if ! curl -fL --retry 3 --connect-timeout 15 "$url" \
        | tar -xzO "$archive_member" > "$tmp_bin"; then
        rm -f "$tmp_bin"
        return 1
    fi

    chmod 755 "$tmp_bin"
    mv -f "$tmp_bin" "$SINGBOX_BIN_PATH"

    hash -r 2>/dev/null || true
    if ! singbox_binary_available && [[ -x "$SINGBOX_BIN_PATH" ]]; then
        ln -sf "$SINGBOX_BIN_PATH" /usr/bin/sing-box 2>/dev/null || true
        hash -r 2>/dev/null || true
    fi

    singbox_binary_available
}

install_or_upgrade_singbox_package() {
    local upgrade="${1:-false}"
    local apk_args=(add --no-cache)

    if [[ "$(package_manager)" == "apk" ]]; then
        [[ "$upgrade" == "true" ]] && apk_args+=(--upgrade)
        if ! run_low_resource apk "${apk_args[@]}" sing-box > /dev/null 2>&1 || ! singbox_binary_available; then
            warn "Alpine 软件源安装 sing-box 失败，改用官方 musl 二进制"
            install_singbox_from_official_tarball || return 1
        fi
    else
        curl -fsSL https://sing-box.app/install.sh | sh || return 1
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
    if command -v sing-box &>/dev/null; then
        local ver
        ver=$(sing-box version 2>/dev/null | head -1 || echo "unknown")
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

write_singbox_service() {
    case "$(service_manager)" in
        openrc)
            local singbox_bin
            singbox_bin=$(command -v sing-box 2>/dev/null || echo "/usr/bin/sing-box")

            cat > "$SINGBOX_OPENRC_SERVICE" << EOF
#!/sbin/openrc-run
name="sing-box"
description="sing-box service"
command="${singbox_bin}"
command_args="run -c ${CONFIG_FILE}"
command_background=true
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
# ─── 生成参数 ────────────────────────────────────────────────
generate_params() {
    info "生成安全参数..."
    UUID=$(sing-box generate uuid)
    SHORT_ID=$(random_hex 4)

    local keypair
    keypair=$(sing-box generate reality-keypair)
    PRIVATE_KEY=$(echo "$keypair" | grep -i "PrivateKey" | awk '{print $NF}')
    PUBLIC_KEY=$(echo "$keypair" | grep -i "PublicKey"  | awk '{print $NF}')

    REALITY_PORT=${REALITY_PORT:-443}
    # 默认固定 SNI。自动测速只能反映 VPS 到目标站点的路径，不能代表客户端链路。
    REALITY_SNI="${REALITY_SNI:-${DEFAULT_REALITY_SNI}}"
    WS_PORT=8080
    WS_PATH="/${SHORT_ID}"
    NODE_NAME=${NODE_NAME:-"sing-box-vps"}
    SUB_TOKEN=$(random_hex 16)
    SUBSCRIPTION_PORT=${SUBSCRIPTION_PORT:-24630}
    ARGO_DOMAIN=""
    ARGO_TOKEN=""
    ARGO_BEST_CF_DOMAIN=""
    ARGO_BEST_CF_DOMAIN_IPV4=""
    ARGO_BEST_CF_DOMAIN_IPV6=""
    LINK_IPV4_SELECTION="all"
    PUBLIC_IPV4_OVERRIDE=""
    NAT_MODE="false"
    REALITY_PUBLIC_PORT="${REALITY_PORT}"

    # Hysteria2 参数
    HY2_PORT=${HY2_PORT:-${HY2_DEFAULT_PORT}}
    HY2_PUBLIC_PORT="${HY2_PORT}"
    HY2_PASSWORD=$(random_base64 16)
    HY2_SNI="${HY2_DEFAULT_SNI}"
    HY2_MASQUERADE_URL="${HY2_DEFAULT_MASQUERADE_URL}"
    HY2_ENABLED="true"

    success "参数生成完成"
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
    [[ "${HY2_ENABLED:-true}" == "true" ]]
}

# ─── 端口 / 防火墙检查 ───────────────────────────────────────
validate_port() {
    local port=$1
    local label=$2

    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        warn "${label} 端口必须是数字: ${port}"
        return 1
    fi
    if (( port < 1 || port > 65535 )); then
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
        warn "如果你使用 NAT 小鸡、云安全组或厂商面板防火墙，请到外部面板手动放行对应端口"
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

    [[ -n "${REALITY_PORT:-}" ]] && open_firewall "$REALITY_PORT" "$backend" || return 1
    if is_hy2_enabled && [[ -n "${HY2_PORT:-}" && "${HY2_PORT}" != "${REALITY_PORT:-}" ]]; then
        open_firewall "$HY2_PORT" "$backend" || return 1
    fi
    return 0
}

validate_service_ports() {
    local old_reality_port=${1:-}
    local old_hy2_port=${2:-}
    local old_subscription_port=${3:-}
    local should_open_firewall=${4:-true}

    validate_port "${REALITY_PORT:-}" "Reality" || return 1
    if argo_fixed_enabled; then
        validate_port "${WS_PORT:-}" "VLESS-WS" || return 1
    fi
    if is_hy2_enabled; then
        validate_port "${HY2_PORT:-}" "Hysteria2" || return 1
    fi
    if nat_mode_enabled; then
        validate_port "${REALITY_PUBLIC_PORT:-}" "NAT Reality 公网映射" || return 1
        if is_hy2_enabled; then
            validate_port "${HY2_PUBLIC_PORT:-}" "NAT Hysteria2 公网映射" || return 1
        fi
    fi
    if argo_fixed_enabled; then
        validate_port "${SUBSCRIPTION_PORT:-}" "订阅服务" || return 1
    fi

    if argo_fixed_enabled && [[ "${REALITY_PORT}" == "${WS_PORT}" ]]; then
        warn "Reality 端口 ${REALITY_PORT}/TCP 与 VLESS-WS 内部端口 ${WS_PORT}/TCP 冲突"
        return 1
    fi
    if argo_fixed_enabled && [[ "${SUBSCRIPTION_PORT}" == "${REALITY_PORT}" || "${SUBSCRIPTION_PORT}" == "${WS_PORT}" ]]; then
        warn "订阅服务端口 ${SUBSCRIPTION_PORT}/TCP 与现有 TCP 服务端口冲突"
        return 1
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

    if argo_fixed_enabled && [[ -z "$old_reality_port" ]]; then
        assert_port_available "$WS_PORT" "tcp" "VLESS-WS" || return 1
    fi

    if argo_fixed_enabled; then
        if [[ -z "$old_subscription_port" || "$SUBSCRIPTION_PORT" != "$old_subscription_port" ]]; then
            assert_port_available "$SUBSCRIPTION_PORT" "tcp" "订阅服务" || return 1
        else
            info "订阅服务端口未变化，跳过占用检查"
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
    local input candidate

    while true; do
        prompt_read input "$prompt" || return 1
        candidate="${input:-$current}"
        if validate_port "$candidate" "$label"; then
            printf -v "$__var_name" '%s' "$candidate"
            return 0
        fi
        warn "请重新输入 ${label} 端口"
    done
}

show_port_confirmation() {
    echo ""
    echo -e "${CYAN}${BOLD}── 端口确认 ──${NC}"
    echo -e "  Reality:      ${BOLD}${REALITY_PORT}/TCP${NC}"
    if ! is_hy2_enabled; then
        echo -e "  Hysteria2:    ${DIM}未启用${NC}"
    elif [[ "${HY2_PORT}" == "${REALITY_PORT}" ]]; then
        echo -e "  Hysteria2:    ${BOLD}${HY2_PORT}/UDP${NC} ${DIM}(与 Reality 共用端口号，协议不同)${NC}"
    else
        echo -e "  Hysteria2:    ${BOLD}${HY2_PORT}/UDP${NC}"
    fi
    if nat_mode_enabled; then
        echo -e "  NAT Reality:  ${BOLD}${REALITY_PUBLIC_PORT}/TCP -> ${REALITY_PORT}/TCP${NC}"
        if is_hy2_enabled; then
            echo -e "  NAT Hysteria2:${BOLD}${HY2_PUBLIC_PORT}/UDP -> ${HY2_PORT}/UDP${NC}"
        fi
    fi
    if argo_fixed_enabled; then
        echo -e "  订阅服务:     ${BOLD}${SUBSCRIPTION_PORT}/TCP${NC} ${DIM}(仅本机/Argo 使用)${NC}"
    fi
    if nat_mode_enabled; then
        echo -e "  本机防火墙:   ${BOLD}${REALITY_PORT}/TCP${NC}$(is_hy2_enabled && printf ', %s/UDP' "$HY2_PORT")"
        echo -e "  服务商面板:   ${BOLD}${REALITY_PUBLIC_PORT}/TCP${NC}$(is_hy2_enabled && printf ', %s/UDP' "$HY2_PUBLIC_PORT")"
    elif is_hy2_enabled; then
        echo -e "  需要外部放行: ${BOLD}${REALITY_PORT}/TCP${NC}, ${BOLD}${HY2_PORT}/UDP${NC}"
    else
        echo -e "  需要外部放行: ${BOLD}${REALITY_PORT}/TCP${NC}"
    fi
    argo_fixed_enabled && echo -e "  不需要外部放行: ${BOLD}${SUBSCRIPTION_PORT}/TCP${NC}"
    echo ""
}

prompt_nat_mapping_config() {
    local detected_mode input candidate

    detected_mode=$(detect_external_access_mode)
    if [[ "$detected_mode" != "nat" ]]; then
        NAT_MODE="false"
        REALITY_PUBLIC_PORT="${REALITY_PORT}"
        HY2_PUBLIC_PORT="${HY2_PORT}"
        return 0
    fi

    if ! nat_mode_enabled; then
        REALITY_PUBLIC_PORT="${REALITY_PORT}"
        HY2_PUBLIC_PORT="${HY2_PORT}"
    fi
    NAT_MODE="true"
    PUBLIC_IPV4_OVERRIDE="${PUBLIC_IPV4:-${PUBLIC_IP:-}}"
    REALITY_PUBLIC_PORT="${REALITY_PUBLIC_PORT:-${REALITY_PORT}}"
    HY2_PUBLIC_PORT="${HY2_PUBLIC_PORT:-${HY2_PORT}}"
    echo ""
    echo -e "${CYAN}${BOLD}── NAT 公网映射 ──${NC}"
    echo -e "  检测到公网 IPv4 不在本机网卡，按 NAT VPS 配置。"
    echo -e "  公网 IPv4: ${BOLD}${PUBLIC_IPV4_OVERRIDE}${NC}"
    prompt_port_value REALITY_PUBLIC_PORT "NAT Reality 公网映射" "$REALITY_PUBLIC_PORT" \
        "  面板分配的 Reality 公网 TCP 端口 [${REALITY_PUBLIC_PORT}]: " || return 1
    if is_hy2_enabled; then
        while true; do
            prompt_read input "  面板分配的 Hysteria2 公网 UDP 端口 [${HY2_PUBLIC_PORT}]，输入 0 禁用: " || return 1
            candidate="${input:-$HY2_PUBLIC_PORT}"
            if [[ "$candidate" == "0" ]]; then
                HY2_ENABLED="false"
                info "NAT 面板未提供 UDP 映射，已禁用 Hysteria2"
                break
            fi
            if validate_port "$candidate" "NAT Hysteria2 公网映射"; then
                HY2_PUBLIC_PORT="$candidate"
                break
            fi
        done
    fi
}

confirm_port_selection() {
    local input

    show_port_confirmation
    prompt_read input "  按 Enter 继续，输入 r 重新选择: " || return 1
    [[ "$input" =~ ^[Rr]$ ]] && return 1
    return 0
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

    echo ""
    echo -e "${CYAN}${BOLD}── 直连公网 IPv4 覆盖 ──${NC}"
    echo -e "  当前覆盖值: ${BOLD}$(public_ipv4_override_label)${NC}"
    echo -e "  ${DIM}该值仅用于生成 Reality/Hysteria2 直连分享链接和订阅内容，不会修改服务端监听配置。${NC}"
    echo -e "  1) 设置/修改覆盖 IPv4"
    echo -e "  2) 清除覆盖，恢复自动检测"
    echo -e "  0) 取消"
    prompt_read choice "  请选择 [0]: " || return 1
    choice=${choice:-0}

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

prompt_ipv4_link_selection_if_multiple() {
    local count input index ip selected

    if [[ -n "${PUBLIC_IPV4_OVERRIDE:-}" ]]; then
        warn "当前已设置直连公网 IPv4 覆盖，多 IPv4 链接策略暂不生效。请先清除覆盖值。"
        return 1
    fi
    refresh_public_ip_stack || return 1
    count=$(public_ipv4_candidate_count)
    if (( count <= 1 )); then
        return 1
    fi

    echo ""
    echo -e "${CYAN}${BOLD}── 多 IPv4 链接策略 ──${NC}"
    echo -e "  检测到多个 IPv4: ${BOLD}$(public_ipv4_display)${NC}"
    echo -e "  1) 全部启用 ${GREEN}推荐${NC}"
    index=2
    while IFS= read -r ip; do
        [[ -n "$ip" ]] || continue
        echo -e "  ${index}) 仅启用 ${ip}"
        index=$((index + 1))
    done <<< "$PUBLIC_IPV4_LIST"

    prompt_read input "  请选择 [1]: " || input=1
    input=${input:-1}

    if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 2 && input < index )); then
        selected=$(printf '%s\n' "$PUBLIC_IPV4_LIST" | sed -n "$((input - 1))p")
        LINK_IPV4_SELECTION="$selected"
    else
        LINK_IPV4_SELECTION="all"
    fi

    info "已选择 IPv4 链接策略: $(link_ipv4_selection_label)"
    return 0
}

show_external_access_requirements() {
    local access_mode
    access_mode=$(detect_external_access_mode)

    echo -e "${CYAN}${BOLD}── 外部放行提示 ──${NC}"
    case "$access_mode" in
        ipv6-only)
            echo -e "  检测到 IPv6-only VPS；仅在配置固定域名 Argo 后生成外部节点链接。"
            if argo_fixed_enabled; then
                echo -e "  Argo 的 ${WS_PORT}/TCP 仅供本机回环/隧道使用，一般不需要在外部面板放行。"
                echo -e "  Subscription: ${BOLD}HTTPS Argo 域名${NC} ${DIM}(本机 ${SUBSCRIPTION_PORT}/TCP 不需要外部放行)${NC}"
            fi
            echo ""
            return
            ;;
        dual-stack)
            echo -e "  检测到 IPv4 + IPv6 双栈 VPS，Reality/Hysteria2 直连节点使用 IPv4。"
            echo -e "  订阅地址通过 Argo HTTPS 域名访问，本机订阅端口不需要外部放行。"
            ;;
        direct)
            echo -e "  本机检测到公网 IP 直接挂载在网卡上。若仍有安全组/云防火墙，请同步放行以下端口。"
            ;;
        nat)
            echo -e "  检测到当前环境疑似 NAT / 转发型 VPS。仅修改本机防火墙通常不够，必须在面板额外放行或映射端口。"
            [[ -n "${PUBLIC_IPV4_OVERRIDE:-}" ]] && echo -e "  当前直连链接使用手动覆盖 IPv4: ${BOLD}${PUBLIC_IPV4_OVERRIDE}${NC}"
            ;;
        panel)
            echo -e "  当前环境未检测到公网 IP 直接挂载在本机网卡，可能经过宿主机、防火墙面板或云安全组。请在外部面板同步放行。"
            [[ -n "${PUBLIC_IPV4_OVERRIDE:-}" ]] && echo -e "  当前直连链接使用手动覆盖 IPv4: ${BOLD}${PUBLIC_IPV4_OVERRIDE}${NC}"
            ;;
        unknown)
            echo -e "  未能检测公网地址，请按实际网络环境放行端口。"
            echo -e "  如需直连 Reality/Hysteria2，请在修改配置中设置直连公网 IPv4 覆盖。"
            ;;
    esac
    if [[ -n "${PUBLIC_IPV4_OVERRIDE:-}" ]]; then
        echo -e "  IPv4 链接策略: ${BOLD}$(link_ipv4_selection_label)${NC} (${BOLD}$(public_ipv4_display)${NC})"
    elif (( $(public_ipv4_candidate_count) > 1 )); then
        echo -e "  IPv4 链接策略: ${BOLD}$(link_ipv4_selection_label)${NC} (${BOLD}$(public_ipv4_display)${NC})"
    fi
    echo -e "  Reality:      ${BOLD}${REALITY_PORT}/TCP${NC}"
    if ! is_hy2_enabled; then
        echo -e "  Hysteria2:    ${DIM}未启用${NC}"
    elif [[ "${HY2_PORT}" == "${REALITY_PORT}" ]]; then
        echo -e "  Hysteria2:    ${BOLD}${HY2_PORT}/UDP${NC} ${DIM}(与 Reality 共用端口号，但协议不同)${NC}"
    else
        echo -e "  Hysteria2:    ${BOLD}${HY2_PORT}/UDP${NC}"
    fi
    if argo_fixed_enabled; then
        echo -e "  Subscription: ${BOLD}HTTPS Argo 域名${NC} ${DIM}(本机 ${SUBSCRIPTION_PORT}/TCP 不需要外部放行)${NC}"
        echo -e "  ${DIM}Argo 和订阅网关均仅供本机回环/隧道使用，一般不需要在外部面板放行。${NC}"
    fi
    if nat_mode_enabled; then
        echo -e "  NAT Reality: ${BOLD}${REALITY_PUBLIC_PORT}/TCP -> ${REALITY_PORT}/TCP${NC}"
        if is_hy2_enabled; then
            echo -e "  NAT Hysteria2: ${BOLD}${HY2_PUBLIC_PORT}/UDP -> ${HY2_PORT}/UDP${NC}"
        fi
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
    if argo_fixed_enabled; then
        [[ -z "${WS_PORT:-}" ]] && missing+="WS_PORT "
        [[ -z "${WS_PATH:-}" ]] && missing+="WS_PATH "
    fi
    if is_hy2_enabled; then
        [[ -z "${HY2_PORT:-}" ]]    && missing+="HY2_PORT "
        [[ -z "${HY2_PASSWORD:-}" ]] && missing+="HY2_PASSWORD "
        [[ -z "${HY2_SNI:-}" ]]     && missing+="HY2_SNI "
        [[ -z "${HY2_MASQUERADE_URL:-}" ]] && missing+="HY2_MASQUERADE_URL "
    fi
    if [[ -n "$missing" ]]; then
        error "配置生成失败: 以下关键变量为空: ${missing}"
    fi

    local json_uuid json_reality_sni json_private_key json_short_id json_ws_path argo_inbound hy2_inbound
    local json_hy2_password json_hy2_sni json_key_path json_cert_path json_hy2_masquerade_url

    json_uuid=$(json_string "$UUID")
    json_reality_sni=$(json_string "$REALITY_SNI")
    json_private_key=$(json_string "$PRIVATE_KEY")
    json_short_id=$(json_string "$SHORT_ID")
    argo_inbound=""
    if argo_fixed_enabled; then
        json_ws_path=$(json_string "$WS_PATH")
        argo_inbound=$(cat << ARGO_EOF
,
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
        json_hy2_masquerade_url=$(json_string "$HY2_MASQUERADE_URL")
        hy2_inbound=$(cat << HY2_EOF
,
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
                "type": "proxy",
                "url": ${json_hy2_masquerade_url},
                "rewrite_host": true
            }
        }
HY2_EOF
)
    fi

    cat > "$CONFIG_FILE" << SINGBOX_EOF
{
    "log": {
        "level": "warn",
        "timestamp": true
    },
    "inbounds": [
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
        }${argo_inbound}${hy2_inbound}
    ],
    "outbounds": [
        {
            "type": "direct",
            "tag": "direct"
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
    if check_output=$(sing-box check -c "$CONFIG_FILE" 2>&1); then
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
write_argo_service() {
    local cloudflared_bin exec_cmd argo_origin_url systemd_hardening
    if ! argo_fixed_enabled; then
        warn "Argo 未启用：必须同时配置固定域名和 Tunnel Token"
        return 1
    fi
    cloudflared_bin=$(command -v cloudflared 2>/dev/null || echo "/usr/local/bin/cloudflared")
    argo_origin_url="http://127.0.0.1:${SUBSCRIPTION_PORT}"
    info "使用固定域名启动 Argo 隧道"
    info "Cloudflare Public Hostname 需转发至 ${argo_origin_url}"
    write_env_file "$ARGO_ENV_FILE" ARGO_TOKEN "$ARGO_TOKEN" TUNNEL_TOKEN "$ARGO_TOKEN"
    exec_cmd="tunnel --protocol http2 --no-autoupdate run"

    if [[ "$(service_manager)" == "openrc" ]]; then
        cat > "$ARGO_OPENRC_SERVICE" << EOF
#!/sbin/openrc-run
name="argo-tunnel"
description="Cloudflare Argo Tunnel"
command="${cloudflared_bin}"
command_args="${exec_cmd}"
command_background=true
pidfile="/run/argo-tunnel.pid"
output_log="/var/log/argo-tunnel.log"
error_log="/var/log/argo-tunnel.log"
EOF
        cat >> "$ARGO_OPENRC_SERVICE" << EOF
env_file="${ARGO_ENV_FILE}"
start_pre() {
    if [ -r "\${env_file}" ]; then
        set -a
        . "\${env_file}"
        set +a
    fi
}
EOF
        cat >> "$ARGO_OPENRC_SERVICE" << 'EOF'

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
Group=nogroup
EOF
    printf 'EnvironmentFile=%s\n' "$ARGO_ENV_FILE" >> "$ARGO_SERVICE"
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
                self.relay(upstream)

        def relay(self, upstream):
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
        cat > "$SUBSCRIPTION_OPENRC_SERVICE" << EOF
#!/sbin/openrc-run
name="sbm-subscription"
description="SBM Subscription Server"
command="/usr/bin/python3"
command_args="${SUBSCRIPTION_SERVER} --listen ${listen_host} --port ${SUBSCRIPTION_PORT} --file ${SUBSCRIPTION_FILE} --upstream-host 127.0.0.1 --upstream-port ${WS_PORT}"
command_background=true
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

    write_subscription_server
    write_subscription_service

    service_enable_now sbm-subscription
}

ensure_subscription_service_if_enabled() {
    argo_fixed_enabled || return 0
    ensure_subscription_service
}

# 固定域名不会从日志发现或自动更换。
refresh_argo_domain_if_needed() {
    return 0
}

refresh_argo_runtime() {
    if ! argo_fixed_enabled; then
        service_stop argo-tunnel 2>/dev/null || true
        service_disable argo-tunnel 2>/dev/null || true
        service_stop sbm-subscription 2>/dev/null || true
        service_disable sbm-subscription 2>/dev/null || true
        ARGO_TOKEN=""
        ARGO_DOMAIN=""
        clear_argo_best_cf_cache
        save_params
        return 0
    fi

    install_cloudflared
    write_argo_service || return 1
    if ! service_enable_now argo-tunnel; then
        warn "argo-tunnel 重启失败，无法更新 Argo 订阅链接"
        return 1
    fi

    save_params
    return 0
}

update_argo_subscription_links() {
    if ! argo_fixed_enabled; then
        warn "当前未启用固定域名 Argo"
        return 1
    fi
    refresh_argo_runtime || return 1
    generate_and_show_links
    ensure_subscription_service_if_enabled || warn "订阅服务启动失败，请检查 python3 或服务日志"
    success "Argo 订阅链接已更新"
    show_subscription_url
}
# ─── Reality 优选 SNI ────────────────────────────────────────
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

probe_reality_sni_candidate() {
    local idx="$1" sni="$2" result_file="$3" require_h2="${4:-1}"
    local out http_ver appconnect ms
    # 用 HEAD(-I) 探测：仅取响应头即可拿到协议版本与握手耗时，不下载正文，
    # 对低带宽 / 低配 VPS 更省流量和时间(h2/ALPN 是连接级，与请求方法无关)。
    local curl_opts=(-I --tlsv1.3 --connect-timeout 2 --max-time 4)
    # 仅当本机 curl 支持 h2 时才协商 h2，否则该 flag 会让 curl 直接报错。
    (( require_h2 )) && curl_opts+=(--http2)

    # 一次请求同时拿到 HTTP 协议版本与 TLS 握手耗时:
    #   --tlsv1.3 强制最低 TLS 1.3(连上即满足 Reality 的 1.3 要求)
    #   %{http_version}==2 表示目标支持 h2
    #   %{time_appconnect} 是「TCP+TLS 握手完成」时间，正是 Reality 关心的握手延迟
    out=$(curl -o /dev/null -s -w '%{http_version} %{time_appconnect}' \
        "${curl_opts[@]}" "https://${sni}" 2>/dev/null || true)
    http_ver="${out%% *}"
    appconnect="${out##* }"

    # 能力门槛:支持 h2 的机器要求目标协商出 HTTP/2；并需有效 TLS 握手时间。
    if (( require_h2 )); then
        [[ "$http_ver" == "2" ]] || return 0
    fi
    [[ "$appconnect" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 0
    ms=$(awk -v t="$appconnect" 'BEGIN {printf "%d", t * 1000}' 2>/dev/null || echo 0)
    [[ "$ms" =~ ^[0-9]+$ && "$ms" -gt 0 && "$ms" -lt 9999 ]] || return 0

    echo "$idx $ms $sni" >> "$result_file"
    return 0
}

select_reality_sni() {
    if [[ -n "${REALITY_SNI:-}" ]]; then
        info "当前已设定伪装域名: $REALITY_SNI，跳过测速"
        return
    fi
    local probe_parallelism
    probe_parallelism=$(get_reality_probe_parallelism)

    # 本机 curl 支持 h2 时把 HTTP/2 作为硬门槛；不支持则降级为仅 TLS1.3。
    local require_h2=0 gate_desc="TLS1.3"
    if reality_curl_supports_h2; then
        require_h2=1
        gate_desc="TLS1.3 + HTTP/2"
    fi
    info "正在实测 ${#REALITY_SNI_LIST[@]} 个 Reality 候选域名 (要求 ${gate_desc}，按握手延迟择优)，并发数: ${probe_parallelism}"

    local tmp_dir
    if ! tmp_dir=$(mktemp -d); then
        REALITY_SNI="${REALITY_SNI_LIST[0]}"
        warn "创建临时目录失败，使用默认伪装域名: ${REALITY_SNI}"
        return 0
    fi

    # 探测过程允许个别命令失败：在低内存/无 swap 机器上，后台任务 fork 失败、
    # wait 返回非零或管道 SIGPIPE 都会在 set -euo pipefail 下误终止整个脚本。
    # 本函数已有「全部失败时使用列表首项」的保护逻辑，这里临时关闭 errexit 即可。
    local errexit_was_set=0
    [[ $- == *e* ]] && errexit_was_set=1
    set +e

    # 仅保留通过 TLS1.3 + h2 能力门槛的域名，再按握手延迟择优。
    # 并发数为 1 时直接前台串行探测，避免在受限机器上 fork 后台任务。
    local active_jobs=0
    for idx in "${!REALITY_SNI_LIST[@]}"; do
        local sni="${REALITY_SNI_LIST[$idx]}"
        if (( probe_parallelism <= 1 )); then
            probe_reality_sni_candidate "$idx" "$sni" "${tmp_dir}/results.txt" "$require_h2"
        else
            probe_reality_sni_candidate "$idx" "$sni" "${tmp_dir}/results.txt" "$require_h2" &
            active_jobs=$((active_jobs + 1))
            if (( active_jobs >= probe_parallelism )); then
                wait
                active_jobs=0
            fi
        fi
    done
    wait 2>/dev/null

    # 需要排除的域名（重新优选时排除当前/上一次，确保结果不同）；
    # 两端补空格便于按整词匹配。常规安装时该变量为空，不影响行为。
    local exclude=" ${REALITY_SNI_EXCLUDE:-} "

    local best_sni="" best_time=9999
    if [[ -f "${tmp_dir}/results.txt" ]]; then
        local best
        # 按握手延迟(第 2 列)升序为主，列表顺序(第 1 列)仅作并列时的稳定排序。
        best=$(awk -v ex="$exclude" 'index(ex, " " $3 " ") == 0' "${tmp_dir}/results.txt" \
            | sort -k2,2n -k1,1n | head -1)
        best_time=$(echo "$best" | awk '{print $2}')
        best_sni=$(echo "$best" | awk '{print $3}')
    fi

    (( errexit_was_set )) && set -e

    rm -rf "$tmp_dir"

    if [[ -n "$best_sni" ]]; then
        REALITY_SNI="$best_sni"
        success "已选择握手最快的合规 Reality 域名: ${REALITY_SNI} (TLS 握手延迟: ${best_time}ms)"
    else
        # 无域名通过 TLS1.3+h2 实测时，回退到候选列表中第一个未被排除的域名
        local fallback=""
        local cand
        for cand in "${REALITY_SNI_LIST[@]}"; do
            [[ "$exclude" == *" $cand "* ]] && continue
            fallback="$cand"
            break
        done
        REALITY_SNI="${fallback:-${REALITY_SNI_LIST[0]}}"
        warn "无域名通过 TLS1.3 + HTTP/2 实测，使用默认伪装域名: ${REALITY_SNI}"
    fi
}

# ─── URL 编码 ────────────────────────────────────────────────
urlencode() {
    python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1" 2>/dev/null || echo "$1"
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
        append_hy2_link "hysteria2://${hy2_pass_enc}@${host}:$(hy2_share_port)?sni=${HY2_SNI}&insecure=1&pinSHA256=${hy2_pin_enc}#${hy2_remark}"
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

build_argo_link_for_domain() {
    local argo_name argo_remark

    argo_fixed_enabled || return
    argo_name="${NODE_NAME}-Argo"
    argo_remark=$(urlencode "$argo_name")
    # 固定域名同时作为连接地址、SNI 和 Host，避免第三方优选域名及早期数据参数造成漂移。
    append_argo_link "vless://${UUID}@${ARGO_DOMAIN}:443?encryption=none&security=tls&sni=${ARGO_DOMAIN}&type=ws&host=${ARGO_DOMAIN}&path=${WS_PATH}&fp=chrome#${argo_remark}"
}

# ─── 链接与订阅生成 ──────────────────────────────────────────
build_share_links() {
    GENERATED_REALITY_LINKS=""
    GENERATED_ARGO_LINKS=""
    GENERATED_HY2_LINKS=""
    GENERATED_SUBSCRIPTION_RAW=""
    ARGO_BEST_CF_DOMAIN_IPV4=""
    ARGO_BEST_CF_DOMAIN_IPV6=""
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
            if argo_fixed_enabled; then
                warn "检测到 IPv6-only VPS，仅生成固定域名 Argo 节点链接。"
            else
                warn "检测到 IPv6-only VPS，且未配置固定域名 Argo，无法生成外部节点链接。"
            fi
            ;;
        unknown)
            ;;
        *)
            build_direct_share_links_for_selected_ipv4s
            ;;
    esac

    if argo_fixed_enabled; then
        build_argo_link_for_domain
    fi
}

write_subscription_assets() {
    local subscription_base64

    subscription_base64=$(printf '%s' "${GENERATED_SUBSCRIPTION_RAW}" | base64 | tr -d '\r\n')
    printf '%s' "${subscription_base64}" > "$SUBSCRIPTION_FILE"
    chmod 600 "$SUBSCRIPTION_FILE"
}

subscription_https_url() {
    argo_fixed_enabled && [[ -n "${SUB_TOKEN:-}" ]] || return 1
    echo "https://${ARGO_DOMAIN}/sub/${SUB_TOKEN}"
}

subscription_local_url() {
    [[ -n "${SUB_TOKEN:-}" ]] || return 1
    echo "http://127.0.0.1:${SUBSCRIPTION_PORT}/sub/${SUB_TOKEN}"
}

show_subscription_url() {
    local public_subscription_url local_subscription_url

    [[ -n "${GENERATED_SUBSCRIPTION_RAW:-}" ]] && argo_fixed_enabled || return

    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║                      订阅地址                       ║${NC}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    if public_subscription_url=$(subscription_https_url); then
        echo -e "${GREEN}${BOLD}HTTPS 订阅（导入 v2rayN / v2rayNG）${NC}"
        echo -e "${YELLOW}${BOLD}${public_subscription_url}${NC}"
    else
        echo -e "${DIM}未启用固定域名 Argo，仅提供本机调试地址。${NC}"
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

    echo ""
    echo -e "${PURPLE}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${PURPLE}${BOLD}║              📋 配置信息 & 分享链接                 ║${NC}"
    echo -e "${PURPLE}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""

    echo -e "${CYAN}${BOLD}── 基本信息 ──${NC}"
    case "${IP_STACK_MODE:-}" in
        dual-stack)
            echo -e "  公网类型:      ${BOLD}IPv4 + IPv6${NC}"
            echo -e "  服务器 IPv4:   ${BOLD}$(public_ipv4_display)${NC}"
            echo -e "  服务器 IPv6:   ${BOLD}${PUBLIC_IPV6}${NC}"
            ;;
        ipv6-only)
            echo -e "  公网类型:      ${BOLD}IPv6-only${NC}"
            echo -e "  服务器 IPv6:   ${BOLD}${PUBLIC_IP}${NC}"
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
    if [[ "${IP_STACK_MODE:-}" == "unknown" ]]; then
        echo -e "  ${DIM}提示: 可在 [修改配置] -> [修改直连公网 IPv4 覆盖] 中手动设置正确公网 IP 后重新生成链接。${NC}"
    fi
    echo -e "  UUID:          ${BOLD}${UUID}${NC}"
    if [[ "${IP_STACK_MODE:-}" != "ipv6-only" && "${IP_STACK_MODE:-}" != "unknown" ]]; then
        echo -e "  Reality 端口:  ${BOLD}$(reality_share_port)${NC}$(nat_mode_enabled && printf ' (本机监听 %s)' "$REALITY_PORT")"
        echo -e "  Reality SNI:   ${BOLD}${REALITY_SNI}${NC}"
        echo -e "  Public Key:    ${BOLD}${PUBLIC_KEY}${NC}"
        echo -e "  Short ID:      ${BOLD}${SHORT_ID}${NC}"
    fi
    if argo_fixed_enabled; then
        echo -e "  订阅端口:      ${BOLD}${SUBSCRIPTION_PORT}${NC}"
        echo -e "  Argo 模式:     ${GREEN}固定域名 (Token)${NC}"
        echo -e "  Argo 域名:     ${BOLD}${ARGO_DOMAIN:-未配置}${NC}"
        echo -e "  WS Path:       ${BOLD}${WS_PATH}${NC}"
    else
        echo -e "  Argo 模式:     ${DIM}未启用${NC}"
    fi
    if [[ "${IP_STACK_MODE:-}" != "ipv6-only" && "${IP_STACK_MODE:-}" != "unknown" ]]; then
        echo -e "  Hysteria2 端口: ${BOLD}$(hy2_share_port)${NC}$(nat_mode_enabled && printf ' (本机监听 %s)' "$HY2_PORT")"
        echo -e "  Hysteria2 密码: ${BOLD}${HY2_PASSWORD}${NC}"
    fi
    echo ""

    if [[ -n "${GENERATED_REALITY_LINKS}" ]]; then
        echo -e "${GREEN}${BOLD}── VLESS + Reality (直连) ──${NC}"
        echo -e "${YELLOW}${GENERATED_REALITY_LINKS}${NC}"
        echo -e "  ${DIM}提示: Reality 请使用 Xray-core / sing-box 内核；若 v2rayN 当前使用 v2fly core，请先切换到 Xray core。${NC}"
        echo ""
    fi

    if [[ -n "${GENERATED_ARGO_LINKS}" ]]; then
        echo -e "${BLUE}${BOLD}── VLESS + WS + Argo (CDN) ──${NC}"
        echo -e "  伪装域名(SNI): ${BOLD}${ARGO_DOMAIN}${NC}"
        echo -e "  接入地址(ADDR): ${BOLD}${ARGO_DOMAIN}${NC}"
        echo -e "${YELLOW}${GENERATED_ARGO_LINKS}${NC}"
        echo ""
    fi

    if [[ -n "${GENERATED_HY2_LINKS}" ]]; then
        echo -e "${PURPLE}${BOLD}── Hysteria2 (QUIC/UDP 高速) ──${NC}"
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
        echo -e "${DIM}  Hysteria2: 未启用 (重新安装即可自动启用)${NC}"
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
        if [[ -n "${GENERATED_SUBSCRIPTION_RAW:-}" ]] && argo_fixed_enabled; then
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

new_relay_script_path() {
    local template="${RELAY_SCRIPT_TEMPLATE:-${TMPDIR:-/tmp}/sbm-relay-install.XXXXXX.sh}"
    mktemp "$template"
}

escape_sed_replacement() {
    printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}

replace_file_token() {
    local file="$1"
    local token="$2"
    local value tmp_file

    value=$(escape_sed_replacement "$3")
    tmp_file=$(mktemp "${file}.XXXXXX") || return 1
    if sed "s|${token}|${value}|g" "$file" > "$tmp_file"; then
        cat "$tmp_file" > "$file"
        rm -f "$tmp_file"
        return 0
    fi
    rm -f "$tmp_file"
    return 1
}

normalize_relay_ws_path() {
    local ws_path="${1-}"

    [[ -n "$ws_path" ]] || return 1
    [[ "$ws_path" == /* ]] || ws_path="/${ws_path}"
    printf '%s' "$ws_path"
}

urldecode() {
    local value="${1-}"
    value="${value//+/ }"
    printf '%b' "${value//%/\\x}"
}

is_valid_uuid_basic() {
    local candidate="${1-}"
    [[ "$candidate" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

parse_vless_ws_argo_link() {
    local link="${1-}"
    local rest authority query uuid hostport server port port_suffix
    local upstream_host="" upstream_sni="" upstream_ws_path="" relay_name="" transport=""
    local pair key value
    local query_pairs=()
    local IFS

    [[ -n "$link" && "$link" == vless://* ]] || return 1

    rest="${link#vless://}"
    if [[ "$rest" == *#* ]]; then
        relay_name=$(urldecode "${rest#*#}")
        rest="${rest%%#*}"
    fi

    [[ "$rest" == *\?* ]] || return 1
    authority="${rest%%\?*}"
    query="${rest#*\?}"
    [[ "$authority" == *@* ]] || return 1

    uuid=$(urldecode "${authority%@*}")
    hostport="${authority#*@}"

    if [[ "$hostport" == \[*\]* ]]; then
        server="${hostport#\[}"
        server="${server%%\]*}"
        port_suffix="${hostport#*\]}"
        [[ "$port_suffix" == :* ]] && port="${port_suffix#:}"
    elif [[ "$hostport" == *:* ]]; then
        server="${hostport%:*}"
        port="${hostport##*:}"
    else
        server="$hostport"
        port=""
    fi

    IFS='&'
    read -r -a query_pairs <<< "$query"
    for pair in "${query_pairs[@]}"; do
        key="${pair%%=*}"
        value=""
        [[ "$pair" == *=* ]] && value="${pair#*=}"
        case "$key" in
            type) transport="$(urldecode "$value")" ;;
            host) upstream_host="$(urldecode "$value")" ;;
            sni) upstream_sni="$(urldecode "$value")" ;;
            path) upstream_ws_path="$(urldecode "$value")" ;;
        esac
    done

    [[ "${transport,,}" == "ws" ]] || return 1
    [[ -n "$uuid" && -n "$server" ]] || return 1
    [[ -n "$upstream_host" || -n "$upstream_sni" ]] || return 1
    [[ -n "$upstream_ws_path" ]] || return 1

    upstream_ws_path=$(normalize_relay_ws_path "$upstream_ws_path") || return 1

    printf 'UPSTREAM_UUID\t%s\n' "$uuid"
    printf 'UPSTREAM_SERVER\t%s\n' "$server"
    printf 'UPSTREAM_SERVER_PORT\t%s\n' "$port"
    printf 'UPSTREAM_HOST\t%s\n' "${upstream_host:-$upstream_sni}"
    printf 'UPSTREAM_WS_PATH\t%s\n' "$upstream_ws_path"
    printf 'RELAY_NAME\t%s\n' "$relay_name"
}

parse_first_vless_ws_argo_from_text() {
    local text="${1-}"
    local line candidate parsed_output

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ "$line" == *vless://* ]] || continue
        candidate="vless://${line#*vless://}"
        if parsed_output=$(parse_vless_ws_argo_link "$candidate" 2>/dev/null); then
            printf '%s\n' "$parsed_output"
            return 0
        fi
    done <<< "$text"
    return 1
}

decode_subscription_content() {
    local raw="${1-}"
    local compact decoded

    compact=$(printf '%s' "$raw" | tr -d ' \r\n\t')
    [[ -n "$compact" ]] || return 1

    if decoded=$(printf '%s' "$compact" | base64 -d 2>/dev/null); then
        printf '%s' "$decoded"
        return 0
    fi
    if decoded=$(printf '%s' "$compact" | base64 --decode 2>/dev/null); then
        printf '%s' "$decoded"
        return 0
    fi
    return 1
}

parse_vless_ws_argo_source() {
    local source="${1-}"
    local parsed_output decoded

    if parsed_output=$(parse_vless_ws_argo_link "$source" 2>/dev/null); then
        printf '%s\n' "$parsed_output"
        return 0
    fi

    if parsed_output=$(parse_first_vless_ws_argo_from_text "$source" 2>/dev/null); then
        printf '%s\n' "$parsed_output"
        return 0
    fi

    if decoded=$(decode_subscription_content "$source" 2>/dev/null); then
        if parsed_output=$(parse_first_vless_ws_argo_from_text "$decoded" 2>/dev/null); then
            printf '%s\n' "$parsed_output"
            return 0
        fi
    fi

    return 1
}

parse_vless_ws_argo_candidates_from_text() {
    local text="${1-}"
    local line candidate parsed_output idx=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ "$line" == *vless://* ]] || continue
        candidate="vless://${line#*vless://}"
        if parsed_output=$(parse_vless_ws_argo_link "$candidate" 2>/dev/null); then
            idx=$((idx + 1))
            printf '__CANDIDATE__\t%s\n' "$idx"
            printf '%s\n' "$parsed_output"
        fi
    done <<< "$text"

    (( idx > 0 ))
}

parse_vless_ws_argo_candidates_from_source() {
    local source="${1-}"
    local decoded

    if [[ "$source" == vless://* ]]; then
        parse_vless_ws_argo_candidates_from_text "$source"
        return $?
    fi

    if parse_vless_ws_argo_candidates_from_text "$source" 2>/dev/null; then
        return 0
    fi

    if decoded=$(decode_subscription_content "$source" 2>/dev/null); then
        parse_vless_ws_argo_candidates_from_text "$decoded"
        return $?
    fi

    return 1
}

select_relay_candidate_from_source() {
    local source="${1-}"
    local candidates_output=""
    local line key value input selected_index selected_block=""
    local current_index=0 total=0
    local server="" host="" path="" name=""

    candidates_output=$(parse_vless_ws_argo_candidates_from_source "$source" 2>/dev/null) || return 1

    while IFS= read -r line || [[ -n "$line" ]]; do
        key="${line%%$'\t'*}"
        value="${line#*$'\t'}"
        if [[ "$key" == "__CANDIDATE__" ]]; then
            current_index="$value"
            total=$((total + 1))
            server=""
            host=""
            path=""
            name=""
            continue
        fi
        case "$key" in
            UPSTREAM_SERVER) server="$value" ;;
            UPSTREAM_HOST) host="$value" ;;
            UPSTREAM_WS_PATH) path="$value" ;;
            RELAY_NAME) name="$value" ;;
        esac
        if [[ "$key" == "RELAY_NAME" ]]; then
            echo -e "  ${BOLD}${current_index})${NC} ${name:-relay-node}"
            echo -e "     server: ${server}"
            echo -e "     host:   ${host}"
            echo -e "     path:   ${path}"
        fi
    done <<< "$candidates_output"

    if (( total == 1 )); then
        selected_index=1
        info "只识别到 1 条可用 Argo 节点，已自动选择"
    else
        echo ""
        prompt_read input "  请选择要使用的节点 [1]: " || return 1
        selected_index=${input:-1}
        [[ "$selected_index" =~ ^[0-9]+$ ]] || return 1
    fi

    current_index=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        key="${line%%$'\t'*}"
        if [[ "$key" == "__CANDIDATE__" ]]; then
            value="${line#*$'\t'}"
            current_index="$value"
            continue
        fi
        if [[ "$current_index" == "$selected_index" ]]; then
            selected_block+="$line"$'\n'
        fi
    done <<< "$candidates_output"

    [[ -n "$selected_block" ]] || return 1
    printf '%s' "$selected_block"
}

validate_relay_inputs() {
    local upstream_server="${1-}"
    local upstream_host="${2-}"
    local upstream_uuid="${3-}"
    local upstream_ws_path="${4-}"
    local relay_port="${5-}"
    local relay_sni="${6-}"

    [[ -n "$upstream_server" ]] || {
        warn "主节点接入地址不能为空"
        return 1
    }
    [[ -n "$upstream_host" ]] || {
        warn "主节点 Argo Host / SNI 不能为空"
        return 1
    }
    if ! is_valid_uuid_basic "$upstream_uuid"; then
        warn "上游 UUID 格式无效: ${upstream_uuid}"
        return 1
    fi
    [[ -n "$upstream_ws_path" ]] || {
        warn "上游 WS Path 不能为空"
        return 1
    }
    [[ "$upstream_ws_path" == /* ]] || {
        warn "上游 WS Path 必须以 / 开头"
        return 1
    }
    validate_port "$relay_port" "线路机监听" || return 1
    [[ -n "$relay_sni" ]] || {
        warn "线路机 Reality 伪装域名不能为空"
        return 1
    }
    return 0
}

collect_relay_install_inputs() {
    local input install_mode parsed_output parsed_port relay_port relay_sni relay_name action_hint
    local upstream_server=""
    local upstream_host=""
    local upstream_uuid=""
    local upstream_ws_path=""

    relay_port="443"
    relay_sni="${REALITY_SNI:-www.microsoft.com}"
    relay_name="relay-node"

    echo ""
    echo -e "${CYAN}${BOLD}── 线路机 / 落地机快速引导 ──${NC}"
    echo -e "  ${DIM}推荐顺序: 先粘贴现有 Argo 节点链接或订阅内容，脚本会尽量自动识别。${NC}"
    echo -e "  1) 粘贴节点链接 / 订阅内容自动识别 ${GREEN}推荐${NC}"
    echo -e "  2) 手动输入全部参数"
    prompt_read install_mode "  请选择 [1]: " || return 1
    install_mode=${install_mode:-1}

    case "$install_mode" in
        1)
            echo ""
            echo -e "  ${DIM}可直接粘贴以下任意一种内容:${NC}"
            echo -e "  ${DIM}- 单条 VLESS+WS+Argo 链接${NC}"
            echo -e "  ${DIM}- 多行订阅文本${NC}"
            echo -e "  ${DIM}- base64 订阅内容${NC}"
            prompt_multiline input "  请输入内容:" "  粘贴完成后直接输入空行结束" || return 1
            if parsed_output=$(select_relay_candidate_from_source "$input"); then
                while IFS=$'\t' read -r key value; do
                    case "$key" in
                        UPSTREAM_SERVER) upstream_server="$value" ;;
                        UPSTREAM_SERVER_PORT) parsed_port="$value" ;;
                        UPSTREAM_HOST) upstream_host="$value" ;;
                        UPSTREAM_UUID) upstream_uuid="$value" ;;
                        UPSTREAM_WS_PATH) upstream_ws_path="$value" ;;
                        RELAY_NAME) [[ -n "$value" ]] && relay_name="$value" ;;
                    esac
                done <<< "$parsed_output"

                if [[ -n "$parsed_port" && "$parsed_port" != "443" ]]; then
                    warn "检测到上游链接端口为 ${parsed_port}，当前线路机仍按 Argo 标准 443 入口处理"
                fi
                [[ -n "$upstream_ws_path" ]] && upstream_ws_path=$(normalize_relay_ws_path "$upstream_ws_path")
                success "已自动识别上游参数，下面只需要确认或补充少量内容"
            else
                warn "自动识别失败，下面将切换为手动补全模式"
            fi
            ;;
        2) ;;
        *) warn "无效选项，按手动补全继续" ;;
    esac

    echo ""
    echo -e "${CYAN}${BOLD}── 上游参数确认 ──${NC}"
    action_hint="留空则使用已识别的值"
    echo -e "  ${DIM}${action_hint}${NC}"
    prompt_read input "  主节点接入地址 [${upstream_server}]: " || return 1
    [[ -n "$input" ]] && upstream_server="$input"
    prompt_read input "  主节点 Argo Host / SNI [${upstream_host}]: " || return 1
    [[ -n "$input" ]] && upstream_host="$input"
    prompt_read input "  主节点 UUID [${upstream_uuid}]: " || return 1
    [[ -n "$input" ]] && upstream_uuid="$input"
    prompt_read input "  主节点 WS Path [${upstream_ws_path}]: " || return 1
    [[ -n "$input" ]] && upstream_ws_path="$input"
    upstream_ws_path=$(normalize_relay_ws_path "$upstream_ws_path" 2>/dev/null || true)

    echo ""
    echo -e "${CYAN}${BOLD}── 本机参数 ──${NC}"
    prompt_read input "  本机监听端口 [${relay_port}]: " || return 1
    [[ -n "$input" ]] && relay_port="$input"
    prompt_read input "  本机 Reality 伪装域名 [${relay_sni}]: " || return 1
    [[ -n "$input" ]] && relay_sni="$input"
    prompt_read input "  节点名称 [${relay_name}]: " || return 1
    [[ -n "$input" ]] && relay_name="$input"

    if [[ "$relay_name" == "relay-node" && -n "$upstream_host" ]]; then
        relay_name="${upstream_host}-Relay"
    fi

    if ! validate_relay_inputs "$upstream_server" "$upstream_host" "$upstream_uuid" "$upstream_ws_path" "$relay_port" "$relay_sni"; then
        return 1
    fi

    echo ""
    echo -e "${CYAN}${BOLD}── 参数确认 ──${NC}"
    echo -e "  主节点接入地址: ${BOLD}${upstream_server}${NC}"
    echo -e "  主节点 Argo Host: ${BOLD}${upstream_host}${NC}"
    echo -e "  主节点 UUID: ${BOLD}${upstream_uuid}${NC}"
    echo -e "  主节点 WS Path: ${BOLD}${upstream_ws_path}${NC}"
    echo -e "  本机监听端口: ${BOLD}${relay_port}${NC}/TCP"
    echo -e "  本机伪装域名: ${BOLD}${relay_sni}${NC}"
    echo -e "  节点名称: ${BOLD}${relay_name}${NC}"
    echo -e "  ${DIM}说明: 线路机只开放本机 Reality 监听端口，回源仍走上游 Argo / CF 入口。${NC}"

    RELAY_INSTALL_UPSTREAM_SERVER="$upstream_server"
    RELAY_INSTALL_UPSTREAM_HOST="$upstream_host"
    RELAY_INSTALL_UPSTREAM_UUID="$upstream_uuid"
    RELAY_INSTALL_UPSTREAM_WS_PATH="$upstream_ws_path"
    RELAY_INSTALL_PORT="$relay_port"
    RELAY_INSTALL_SNI="$relay_sni"
    RELAY_INSTALL_NAME="$relay_name"
    return 0
}

write_relay_install_script() {
    local relay_script="$1"
    local relay_port="$2"
    local relay_sni="$3"
    local upstream_server="$4"
    local upstream_host="$5"
    local relay_name="$6"
    local upstream_uuid="${7:-${UUID:-}}"
    local upstream_ws_path="${8:-${WS_PATH:-}}"

    [[ -n "$relay_script" && -n "$relay_port" && -n "$relay_sni" ]] || return 1
    [[ -n "$upstream_server" && -n "$upstream_host" && -n "$upstream_uuid" && -n "$upstream_ws_path" ]] || return 1

    cat > "$relay_script" <<'RELAY_EOF'
#!/usr/bin/env sh
if [ -z "${BASH_VERSION:-}" ]; then
    set -e
    if ! command -v bash >/dev/null 2>&1; then
        if command -v apk >/dev/null 2>&1; then
            apk update
            apk add --no-cache bash
        elif command -v apt-get >/dev/null 2>&1; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y
            apt-get install -y bash
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y bash
        elif command -v yum >/dev/null 2>&1; then
            yum install -y bash
        else
            echo "[ERROR] 未检测到 Bash 或可用包管理器" >&2
            exit 1
        fi
    fi
    exec bash "$0" "$@"
fi

set -euo pipefail

RELAY_PORT="__RELAY_PORT__"
RELAY_SNI="__RELAY_SNI__"
UPSTREAM_SERVER="__UPSTREAM_SERVER__"
UPSTREAM_HOST="__UPSTREAM_HOST__"
UPSTREAM_UUID="__UPSTREAM_UUID__"
UPSTREAM_WS_PATH="__UPSTREAM_WS_PATH__"
RELAY_NAME="__RELAY_NAME__"

info() { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || err "请使用 root 权限运行"

package_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        echo apt
    elif command -v dnf >/dev/null 2>&1; then
        echo dnf
    elif command -v yum >/dev/null 2>&1; then
        echo yum
    elif command -v apk >/dev/null 2>&1; then
        echo apk
    else
        echo none
    fi
}

install_deps() {
    case "$(package_manager)" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y
            apt-get install -y curl ca-certificates
            ;;
        dnf) dnf install -y curl ca-certificates ;;
        yum) yum install -y curl ca-certificates ;;
        apk)
            apk update
            apk add --no-cache curl ca-certificates openrc tar
            ;;
        *) err "未识别系统包管理器" ;;
    esac
}

singbox_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo amd64 ;;
        aarch64|arm64) echo arm64 ;;
        armv7l|armv7) echo armv7 ;;
        *) echo amd64 ;;
    esac
}

latest_singbox_version() {
    local latest_url
    latest_url=$(curl -fsSIL -o /dev/null -w '%{url_effective}' https://github.com/SagerNet/sing-box/releases/latest)
    printf '%s' "${latest_url##*/v}"
}

install_singbox_from_musl_tarball() {
    local version arch url archive_member tmp_bin

    version=$(latest_singbox_version)
    arch=$(singbox_arch)
    url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-${arch}-musl.tar.gz"
    archive_member="sing-box-${version}-linux-${arch}-musl/sing-box"
    tmp_bin="/usr/local/bin/.sing-box.${$}.tmp"

    mkdir -p /usr/local/bin
    if ! curl -fL "$url" | tar -xzO "$archive_member" > "$tmp_bin"; then
        rm -f "$tmp_bin"
        err "sing-box 二进制下载失败"
    fi
    chmod +x "$tmp_bin"
    mv -f "$tmp_bin" /usr/local/bin/sing-box
}

install_singbox() {
    command -v sing-box >/dev/null 2>&1 && return 0

    case "$(package_manager)" in
        apk) apk add --no-cache sing-box 2>/dev/null || install_singbox_from_musl_tarball ;;
        apt|dnf|yum) bash <(curl -fsSL https://sing-box.app/install.sh) || true ;;
    esac

    command -v sing-box >/dev/null 2>&1 || err "sing-box 安装失败"
}

format_host() {
    case "$1" in
        *:*) printf '[%s]' "$1" ;;
        *) printf '%s' "$1" ;;
    esac
}

urlencode() {
    python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1" 2>/dev/null || printf '%s' "$1"
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

public_ip() {
    curl -fsS4 https://api.ipify.org 2>/dev/null || curl -fsS6 https://api64.ipify.org 2>/dev/null || printf 'YOUR_RELAY_IP'
}

open_firewall_port() {
    local port="$1"

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi active; then
        ufw allow "${port}/tcp" >/dev/null 2>&1 || true
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
}

write_service() {
    local sing_box_bin
    sing_box_bin=$(command -v sing-box)

    if command -v rc-service >/dev/null 2>&1; then
        cat > /etc/init.d/sing-box <<EOF
#!/sbin/openrc-run
name="sing-box"
command="${sing_box_bin}"
command_args="run -c /etc/sing-box/config.json"
command_background="yes"
pidfile="/run/sing-box.pid"
supervisor=supervise-daemon
supervise_daemon_args="--respawn-max 0 --respawn-delay 5"
depend() { need net; }
EOF
        chmod +x /etc/init.d/sing-box
        rc-update add sing-box default
        rc-service sing-box restart
    elif command -v systemctl >/dev/null 2>&1; then
        cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${sing_box_bin} run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
SystemCallArchitectures=native

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now sing-box
    else
        err "未检测到 systemd 或 OpenRC"
    fi
}

install_deps
install_singbox

RELAY_UUID=$(sing-box generate uuid)
REALITY_KEYS=$(sing-box generate reality-keypair)
REALITY_PRIVATE_KEY=$(printf '%s\n' "$REALITY_KEYS" | awk '/PrivateKey/ {print $NF; exit}')
REALITY_PUBLIC_KEY=$(printf '%s\n' "$REALITY_KEYS" | awk '/PublicKey/ {print $NF; exit}')
REALITY_SHORT_ID=$(sing-box generate rand 8 --hex 2>/dev/null || od -An -N 4 -tx1 /dev/urandom 2>/dev/null | tr -d '[:space:]')

[[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" && -n "$REALITY_SHORT_ID" ]] || err "Reality 密钥生成失败"

mkdir -p /etc/sing-box
json_relay_uuid=$(json_string "$RELAY_UUID")
json_relay_sni=$(json_string "$RELAY_SNI")
json_reality_private_key=$(json_string "$REALITY_PRIVATE_KEY")
json_reality_short_id=$(json_string "$REALITY_SHORT_ID")
json_upstream_server=$(json_string "$UPSTREAM_SERVER")
json_upstream_uuid=$(json_string "$UPSTREAM_UUID")
json_upstream_host=$(json_string "$UPSTREAM_HOST")
json_upstream_ws_path=$(json_string "$UPSTREAM_WS_PATH")
cat > /etc/sing-box/config.json <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "relay-in",
      "listen": "::",
      "listen_port": ${RELAY_PORT},
      "sniff": true,
      "users": [
        {
          "uuid": ${json_relay_uuid},
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": ${json_relay_sni},
        "reality": {
          "enabled": true,
          "handshake": {
            "server": ${json_relay_sni},
            "server_port": 443
          },
          "private_key": ${json_reality_private_key},
          "short_id": [
            ${json_reality_short_id}
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "main-argo-out",
      "server": ${json_upstream_server},
      "server_port": 443,
      "uuid": ${json_upstream_uuid},
      "tls": {
        "enabled": true,
        "server_name": ${json_upstream_host},
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        }
      },
      "transport": {
        "type": "ws",
        "path": ${json_upstream_ws_path},
        "headers": {
          "Host": ${json_upstream_host}
        }
      }
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "inbound": "relay-in",
        "outbound": "main-argo-out"
      }
    ]
  }
}
EOF

open_firewall_port "$RELAY_PORT"
write_service

RELAY_PUBLIC_IP=$(public_ip)
RELAY_HOST=$(format_host "$RELAY_PUBLIC_IP")
RELAY_REMARK=$(urlencode "$RELAY_NAME")
RELAY_URI="vless://${RELAY_UUID}@${RELAY_HOST}:${RELAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${RELAY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp#${RELAY_REMARK}"

printf '%s\n' "$RELAY_URI" > /etc/sing-box/relay-link.txt
chmod 600 /etc/sing-box/relay-link.txt

echo ""
info "线路机部署完成"
echo "$RELAY_URI"
echo ""
info "链接保存位置: /etc/sing-box/relay-link.txt"
RELAY_EOF

    replace_file_token "$relay_script" "__RELAY_PORT__" "$relay_port"
    replace_file_token "$relay_script" "__RELAY_SNI__" "$relay_sni"
    replace_file_token "$relay_script" "__UPSTREAM_SERVER__" "$upstream_server"
    replace_file_token "$relay_script" "__UPSTREAM_HOST__" "$upstream_host"
    replace_file_token "$relay_script" "__UPSTREAM_UUID__" "$upstream_uuid"
    replace_file_token "$relay_script" "__UPSTREAM_WS_PATH__" "$upstream_ws_path"
    replace_file_token "$relay_script" "__RELAY_NAME__" "$relay_name"
    chmod 700 "$relay_script"
}

check_upstream_tcp_reachability() {
    local host="${1-}"
    local port="${2:-443}"

    [[ -n "$host" ]] || return 1

    if command -v bash >/dev/null 2>&1; then
        timeout 5 bash -lc "</dev/tcp/${host}/${port}" >/dev/null 2>&1
        return $?
    fi

    if command -v nc >/dev/null 2>&1; then
        nc -z -w 5 "$host" "$port" >/dev/null 2>&1
        return $?
    fi

    return 2
}

show_relay_troubleshooting() {
    local relay_port="${RELAY_INSTALL_PORT:-}"
    local config_check_output=""
    local listener_output=""
    local recent_logs=""
    local diagnosis=()
    local log_lc=""
    local upstream_host="${RELAY_INSTALL_UPSTREAM_SERVER:-}"
    local reachability_result=2
    local dns_lookup_output=""

    echo ""
    echo -e "${YELLOW}${BOLD}── 线路机 / 落地机排障提示 ──${NC}"

    if [[ -f "$CONFIG_FILE" ]]; then
        echo -e "  ${GREEN}•${NC} 已检测到本机配置文件: ${BOLD}${CONFIG_FILE}${NC}"
    else
        echo -e "  ${YELLOW}•${NC} 未检测到配置文件，安装过程可能在写入配置前就失败了"
        diagnosis+=("更像是安装流程在写配置或写服务前就中断了")
    fi

    if command -v sing-box >/dev/null 2>&1 && [[ -f "$CONFIG_FILE" ]]; then
        if config_check_output=$(sing-box check -c "$CONFIG_FILE" 2>&1); then
            echo -e "  ${GREEN}•${NC} sing-box 配置语法检查通过"
        else
            echo -e "  ${YELLOW}•${NC} sing-box 配置语法检查未通过，请重点检查上游参数"
            echo "$config_check_output" | head -n 8
            diagnosis+=("更像是配置内容有误，优先检查 UUID / Host / WS Path / 传输类型")
        fi
    fi

    if service_exists sing-box; then
        if service_is_active sing-box; then
            echo -e "  ${GREEN}•${NC} sing-box 服务当前正在运行"
        else
            echo -e "  ${YELLOW}•${NC} sing-box 服务未正常运行，可重点检查最近日志"
            recent_logs=$(service_logs sing-box 15 2>/dev/null || true)
            [[ -n "$recent_logs" ]] && printf '%s\n' "$recent_logs" | head -n 15
            diagnosis+=("更像是 sing-box 服务启动失败")
        fi
    else
        echo -e "  ${YELLOW}•${NC} 当前未检测到 sing-box 服务文件，安装可能在写服务前中断"
        diagnosis+=("更像是服务文件未成功写入或安装脚本提前中断")
    fi

    if [[ -n "$relay_port" ]]; then
        listener_output=$(get_port_listeners "$relay_port" tcp 2>/dev/null || true)
        if [[ -n "$listener_output" ]]; then
            echo -e "  ${GREEN}•${NC} 本机 TCP ${relay_port} 端口已有监听"
        else
            echo -e "  ${YELLOW}•${NC} 本机 TCP ${relay_port} 端口暂未检测到监听"
            diagnosis+=("更像是 sing-box 没有真正监听成功，或服务尚未启动")
        fi
    fi

    if [[ -n "$upstream_host" ]]; then
        if dns_lookup_output=$(getent hosts "$upstream_host" 2>/dev/null); then
            echo -e "  ${GREEN}•${NC} 上游接入地址可解析: ${BOLD}${upstream_host}${NC}"
        else
            echo -e "  ${YELLOW}•${NC} 上游接入地址暂未解析成功: ${BOLD}${upstream_host}${NC}"
            diagnosis+=("更像是本机无法解析上游接入地址")
        fi

        check_upstream_tcp_reachability "$upstream_host" 443
        reachability_result=$?
        if [[ "$reachability_result" == "0" ]]; then
            echo -e "  ${GREEN}•${NC} 本机到上游 ${upstream_host}:443 的 TCP 连通性正常"
        elif [[ "$reachability_result" == "1" ]]; then
            echo -e "  ${YELLOW}•${NC} 本机到上游 ${upstream_host}:443 的 TCP 连通性失败"
            diagnosis+=("更像是本机到上游网络不通，或上游 443 不可达")
        else
            echo -e "  ${DIM}•${NC} 当前环境无法完成上游 TCP 连通性检测"
        fi
    fi

    if [[ -n "$recent_logs" ]]; then
        log_lc=$(printf '%s' "$recent_logs" | tr '[:upper:]' '[:lower:]')
        if [[ "$log_lc" == *"uuid"* ]]; then
            diagnosis+=("更像是上游 UUID 不匹配或格式异常")
        fi
        if [[ "$log_lc" == *"path"* || "$log_lc" == *"ws"* ]]; then
            diagnosis+=("更像是 WS Path 或 WebSocket 相关参数不匹配")
        fi
        if [[ "$log_lc" == *"host"* || "$log_lc" == *"sni"* || "$log_lc" == *"tls"* ]]; then
            diagnosis+=("更像是 Host / SNI / TLS 相关参数不匹配")
        fi
        if [[ "$log_lc" == *"address already in use"* || "$log_lc" == *"bind"* ]]; then
            diagnosis+=("更像是本机监听端口被占用或绑定失败")
        fi
    fi

    echo ""
    echo -e "${PURPLE}${BOLD}自动诊断结论:${NC}"
    if [[ ${#diagnosis[@]} -eq 0 ]]; then
        echo -e "  ${DIM}暂未识别出单一明显原因，建议先核对上游参数，再查看服务日志。${NC}"
    else
        local seen="|" item
        for item in "${diagnosis[@]}"; do
            [[ "$seen" == *"|${item}|"* ]] && continue
            seen+="${item}|"
            echo -e "  ${YELLOW}→${NC} ${item}"
        done
    fi

    echo ""
    echo -e "${CYAN}${BOLD}建议优先检查以下项目:${NC}"
    echo -e "  1) 主节点接入地址是否正确: ${BOLD}${RELAY_INSTALL_UPSTREAM_SERVER:-<未填写>}${NC}"
    echo -e "  2) 主节点 Argo Host / SNI 是否正确: ${BOLD}${RELAY_INSTALL_UPSTREAM_HOST:-<未填写>}${NC}"
    echo -e "  3) 主节点 UUID 是否与上游节点一致: ${BOLD}${RELAY_INSTALL_UPSTREAM_UUID:-<未填写>}${NC}"
    echo -e "  4) 主节点 WS Path 是否正确: ${BOLD}${RELAY_INSTALL_UPSTREAM_WS_PATH:-<未填写>}${NC}"
    echo -e "  5) 本机监听端口是否已对公网放行: ${BOLD}${RELAY_INSTALL_PORT:-<未填写>}/TCP${NC}"
    echo -e "  6) 如果是从订阅中选择的节点，请确认选中的那一条本身在客户端可正常使用"
    echo -e "  7) 若服务启动失败，可执行: ${BOLD}sbm status${NC} 或 ${BOLD}sbm logs${NC} 继续排查"
}

show_relay_success_self_check() {
    local relay_port="${RELAY_INSTALL_PORT:-}"
    local config_check_output=""
    local listener_output=""
    local all_good=true
    local upstream_host="${RELAY_INSTALL_UPSTREAM_SERVER:-}"
    local reachability_result=2

    echo ""
    echo -e "${GREEN}${BOLD}── 线路机 / 落地机部署后自检 ──${NC}"

    if [[ -f "$CONFIG_FILE" ]]; then
        echo -e "  ${GREEN}•${NC} 已生成配置文件: ${BOLD}${CONFIG_FILE}${NC}"
    else
        echo -e "  ${YELLOW}•${NC} 未检测到配置文件"
        all_good=false
    fi

    if command -v sing-box >/dev/null 2>&1 && [[ -f "$CONFIG_FILE" ]]; then
        if config_check_output=$(sing-box check -c "$CONFIG_FILE" 2>&1); then
            echo -e "  ${GREEN}•${NC} sing-box 配置语法检查通过"
        else
            echo -e "  ${YELLOW}•${NC} sing-box 配置语法检查未通过"
            echo "$config_check_output" | head -n 8
            all_good=false
        fi
    fi

    if service_exists sing-box; then
        if service_is_active sing-box; then
            echo -e "  ${GREEN}•${NC} sing-box 服务当前正在运行"
        else
            echo -e "  ${YELLOW}•${NC} sing-box 服务当前未处于运行状态"
            all_good=false
        fi
    else
        echo -e "  ${YELLOW}•${NC} 当前未检测到 sing-box 服务文件"
        all_good=false
    fi

    if [[ -n "$relay_port" ]]; then
        listener_output=$(get_port_listeners "$relay_port" tcp 2>/dev/null || true)
        if [[ -n "$listener_output" ]]; then
            echo -e "  ${GREEN}•${NC} 本机 TCP ${relay_port} 端口已监听"
        else
            echo -e "  ${YELLOW}•${NC} 本机 TCP ${relay_port} 端口暂未检测到监听"
            all_good=false
        fi
    fi

    if [[ -f "${CONFIG_DIR}/relay-link.txt" ]]; then
        echo -e "  ${GREEN}•${NC} 已生成线路机链接文件: ${BOLD}${CONFIG_DIR}/relay-link.txt${NC}"
    else
        echo -e "  ${YELLOW}•${NC} 未检测到线路机链接文件 ${BOLD}${CONFIG_DIR}/relay-link.txt${NC}"
        all_good=false
    fi

    if [[ -n "$upstream_host" ]]; then
        check_upstream_tcp_reachability "$upstream_host" 443
        reachability_result=$?
        if [[ "$reachability_result" == "0" ]]; then
            echo -e "  ${GREEN}•${NC} 本机到上游 ${upstream_host}:443 的 TCP 连通性正常"
        elif [[ "$reachability_result" == "1" ]]; then
            echo -e "  ${YELLOW}•${NC} 本机到上游 ${upstream_host}:443 的 TCP 连通性失败"
            all_good=false
        else
            echo -e "  ${DIM}•${NC} 当前环境无法完成上游 TCP 连通性检测"
        fi
    fi

    echo ""
    if [[ "$all_good" == "true" ]]; then
        echo -e "${GREEN}${BOLD}自检结论: 关键项已通过，可优先先本机确认后再给用户使用。${NC}"
    else
        echo -e "${YELLOW}${BOLD}自检结论: 部署已完成，但仍有项目未通过，建议先执行 sbm status / sbm logs 排查后再交付使用。${NC}"
    fi
}


install_relay_from_inputs() {
    local relay_script_path

    relay_script_path=$(new_relay_script_path) || return 1
    if ! write_relay_install_script \
        "$relay_script_path" \
        "$RELAY_INSTALL_PORT" \
        "$RELAY_INSTALL_SNI" \
        "$RELAY_INSTALL_UPSTREAM_SERVER" \
        "$RELAY_INSTALL_UPSTREAM_HOST" \
        "$RELAY_INSTALL_NAME" \
        "$RELAY_INSTALL_UPSTREAM_UUID" \
        "$RELAY_INSTALL_UPSTREAM_WS_PATH"; then
        rm -f "$relay_script_path"
        return 1
    fi

    info "开始部署当前机器为线路机 / 落地机..."
    if bash "$relay_script_path"; then
        rm -f "$relay_script_path"
        return 0
    fi

    warn "线路机 / 落地机部署失败，已保留临时脚本以便排查: ${relay_script_path}"
    return 1
}
do_relay_install() {
    echo ""
    info "开始部署线路机 / 落地机..."
    separator

    ensure_time_sync || true

    if ! collect_relay_install_inputs; then
        warn "参数收集失败，请检查输入后重试"
        press_enter
        return
    fi

    local confirm
    prompt_read confirm "  按 Enter 开始部署，输入 r 返回重填: " || {
        press_enter
        return
    }
    if [[ "$confirm" =~ ^[Rr]$ ]]; then
        warn "已取消本次部署"
        press_enter
        return
    fi

    if install_relay_from_inputs; then
        success "当前机器已完成线路机 / 落地机部署"
        show_relay_success_self_check
    else
        warn "当前机器线路机 / 落地机部署未完成"
        show_relay_troubleshooting
    fi
    press_enter
}

do_generate_relay_script() {
    load_params || { warn "未找到主节点配置，请先安装"; press_enter; return; }

    refresh_argo_domain_if_needed
    build_share_links >/dev/null

    if [[ -z "${ARGO_DOMAIN:-}" ]]; then
        warn "Argo 域名未就绪，暂不能生成线路机脚本"
        press_enter
        return
    fi

    local relay_port relay_sni upstream_server relay_name input

    upstream_server="${ARGO_BEST_CF_DOMAIN:-${ARGO_BEST_CF_DOMAIN_IPV4:-${ARGO_DOMAIN}}}"
    relay_sni="${REALITY_SNI:-www.microsoft.com}"
    relay_name="${NODE_NAME}-Relay"

    echo ""
    echo -e "${CYAN}${BOLD}── 线路机部署脚本 ──${NC}"
    echo -e "  主节点接入地址: ${BOLD}${upstream_server}${NC}"
    echo -e "  主节点 Argo Host: ${BOLD}${ARGO_DOMAIN}${NC}"
    prompt_read relay_port "  线路机监听端口 [443]: "
    relay_port=${relay_port:-443}
    prompt_read input "  线路机 Reality 伪装域名 [${relay_sni}]: "
    [[ -n "$input" ]] && relay_sni="$input"

    if ! validate_port "$relay_port" "线路机监听"; then
        press_enter
        return
    fi

    local relay_script_path
    relay_script_path=$(new_relay_script_path) || {
        warn "线路机脚本临时文件创建失败"
        press_enter
        return
    }

    if ! write_relay_install_script "$relay_script_path" "$relay_port" "$relay_sni" "$upstream_server" "$ARGO_DOMAIN" "$relay_name"; then
        rm -f "$relay_script_path"
        warn "线路机脚本生成失败"
        press_enter
        return
    fi

    echo ""
    success "线路机脚本已生成: $relay_script_path"
    echo -e "  在线路机执行: ${BOLD}sh $relay_script_path${NC}"
    echo ""
    echo "--------------------"
    cat "$relay_script_path"
    echo "--------------------"
    press_enter
}
# ════════════════════════════════════════════════════════════
#  菜单功能
# ════════════════════════════════════════════════════════════

# ─── 完整安装 ────────────────────────────────────────────────
do_primary_install() {
    echo ""
    info "开始完整安装..."
    separator

    install_deps
    ensure_time_sync || true
    install_singbox
    generate_params

    while true; do
        # 询问端口模式
        echo ""
        echo -e "${CYAN}${BOLD}── 端口配置 ──${NC}"
        echo -e "  1) 极简单端口模式 (Reality & Hysteria2 共用 443/TCP+UDP) ${GREEN}推荐${NC}"
        echo -e "  2) 自定义分端口模式 (手动设置各个协议端口)"
        prompt_read port_mode "  请选择 [1]: "
        port_mode=${port_mode:-1}

        if [[ "$port_mode" == "1" ]]; then
            REALITY_PORT=443
            HY2_PORT=443
            info "已选择单端口模式: 443"
        else
            prompt_port_value REALITY_PORT "Reality" "$REALITY_PORT" "  Reality 端口 [${REALITY_PORT}]: " || error "端口读取失败"
            prompt_port_value HY2_PORT "Hysteria2" "$HY2_PORT" "  Hysteria2 端口 [${HY2_PORT}]: " || error "端口读取失败"
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

    prompt_read input "  Reality 伪装域名 [${REALITY_SNI}]: "
    [[ -n "$input" ]] && REALITY_SNI="$input"

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

    # 询问 Argo 模式
    echo ""
    echo -e "${CYAN}${BOLD}── Argo 隧道配置 ──${NC}"
    echo -e "  1) 不启用 Argo ${GREEN}推荐${NC}"
    echo -e "  2) 固定域名模式 (需提供 Cloudflare Tunnel Token)"
    prompt_read argo_choice "  请选择 [1]: "
    argo_choice=${argo_choice:-1}
    if [[ "$argo_choice" == "2" ]]; then
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
            warn "Token 或域名为空，Argo 将保持关闭"
            ARGO_TOKEN=""
            ARGO_DOMAIN=""
        else
            install_cloudflared
            validate_service_ports "" "" "" false || error "固定域名 Argo 端口配置无效"
        fi
    else
        ARGO_TOKEN=""
        ARGO_DOMAIN=""
    fi

    write_singbox_config
    write_singbox_service
    argo_fixed_enabled && write_argo_service

    # 启动 sing-box
    info "启动 sing-box..."
    service_enable_now sing-box
    sleep 2
    if service_is_active sing-box; then
        success "sing-box 已启动"
    else
        error "sing-box 启动失败，请查看服务日志"
    fi

    ensure_subscription_service_if_enabled || warn "订阅服务启动失败，可稍后执行 sbm restart 重试"

    if argo_fixed_enabled; then
        info "启动固定域名 Argo 隧道..."
        service_enable_now argo-tunnel
        success "Argo 域名: $ARGO_DOMAIN"
    fi

    # 保存参数
    save_params

    echo ""
    if argo_fixed_enabled; then
        echo -e "${GREEN}${BOLD}✅ 部署完成！HTTPS 订阅地址可导入 v2rayN / v2rayNG。${NC}"
    else
        echo -e "${GREEN}${BOLD}✅ 部署完成！请导入下方 Reality 直连链接。${NC}"
    fi

    # 显示链接
    generate_and_show_links
    show_subscription_url

    press_enter
}

do_install() {
    echo ""
    echo -e "${CYAN}${BOLD}── 部署目标 ──${NC}"
    echo -e "  1) 主节点完整部署 ${GREEN}推荐${NC}"
    echo -e "  2) 只搭建线路机 / 落地机"
    echo -e "  3) 生成线路机部署脚本"
    echo -e "  0) 返回"
    prompt_read target "  请选择 [1]: "
    target=${target:-1}

    case "$target" in
        1) do_primary_install ;;
        2) do_relay_install ;;
        3) do_generate_relay_script ;;
        0) return ;;
        *) warn "无效选项"; sleep 0.5 ;;
    esac
}

# ─── 修改配置 ────────────────────────────────────────────────
do_modify_config() {
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
        clear
        echo -e "${CYAN}${BOLD}"
        echo "  ── 修改配置 ──"
        echo -e "${NC}"
        echo -e "  1) 修改 Reality 端口       ${DIM}(当前: ${REALITY_PORT})${NC}"
        echo -e "  2) 修改伪装域名            ${DIM}(当前: ${REALITY_SNI})${NC}"
        echo -e "  3) 重新生成 UUID           ${DIM}(当前: ${UUID:0:8}...)${NC}"
        echo -e "  4) 重新生成 Reality 密钥对"
        echo -e "  5) 修改节点名称            ${DIM}(当前: ${NODE_NAME})${NC}"
        echo -e "  6) 重新优选伪装域名"
        echo -e "  7) 修改 Hysteria2 端口     ${DIM}(当前: ${HY2_PORT})${NC}"
        echo -e "  8) 重新生成 Hysteria2 密码"
        echo -e "  9) 切换为单端口模式 (443)  ${GREEN}推荐${NC}"
        echo -e "  10) 修改 Argo 隧道 (Token/域名)"
        echo -e "  11) 更新 Argo 订阅链接"
        echo -e "  12) 修改订阅服务端口       ${DIM}(当前: ${SUBSCRIPTION_PORT})${NC}"
        echo -e "  13) 修改 IPv4 链接策略     ${DIM}(当前: $(link_ipv4_selection_label))${NC}"
        echo -e "  14) 修改直连公网 IPv4 覆盖 ${DIM}(当前: $(public_ipv4_override_label))${NC}"
        echo -e "  15) 修改 NAT 公网映射       ${DIM}(当前: $(nat_mode_enabled && echo '已启用' || echo '未启用'))${NC}"
        echo -e "  0) 返回主菜单"
        echo ""
        prompt_read choice "  请选择 [0-15]: "

        local changed=false
        local ports_changed=false
        local restart_singbox=false
        local restart_argo=false
        local links_only_changed=false
        case "$choice" in
            1)
                local new_reality_port
                prompt_port_value new_reality_port "Reality" "$REALITY_PORT" "  新端口 [${REALITY_PORT}]: " || continue
                if [[ "$new_reality_port" != "$REALITY_PORT" ]]; then
                    REALITY_PORT="$new_reality_port"
                    changed=true
                    ports_changed=true
                    restart_singbox=true
                fi
                ;;
            2)
                prompt_read input "  新伪装域名: "
                if [[ -n "$input" ]]; then
                    REALITY_SNI="$input"
                    changed=true
                    restart_singbox=true
                fi
                ;;
            3)
                UUID=$(sing-box generate uuid)
                info "新 UUID: $UUID"
                changed=true
                restart_singbox=true
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
                ;;
            10)
                echo -e "\n  当前模式: $( argo_fixed_enabled && echo "固定域名" || echo "未启用" )"
                echo -e "  1) 关闭 Argo"
                echo -e "  2) 切换为/修改固定域名 Token 模式"
                prompt_read sub_choice "  请选择 [2]: "
                sub_choice=${sub_choice:-2}
                if [[ "$sub_choice" == "2" ]]; then
                    local old_argo_domain="${ARGO_DOMAIN:-}"
                    local old_argo_token="${ARGO_TOKEN:-}"
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
                    if [[ "${ARGO_DOMAIN:-}" != "$old_argo_domain" || "${ARGO_TOKEN:-}" != "$old_argo_token" ]]; then
                        clear_argo_best_cf_cache
                    fi
                else
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
                echo -e "  1) 启用/修改 NAT 公网映射"
                echo -e "  2) 关闭 NAT 公网映射"
                prompt_read sub_choice "  请选择 [1]: "
                sub_choice=${sub_choice:-1}
                if [[ "$sub_choice" == "2" ]]; then
                    NAT_MODE="false"
                    REALITY_PUBLIC_PORT="${REALITY_PORT}"
                    HY2_PUBLIC_PORT="${HY2_PORT}"
                else
                    local nat_public_ip nat_reality_port nat_hy2_port
                    nat_public_ip="${PUBLIC_IPV4_OVERRIDE:-${PUBLIC_IPV4:-}}"
                    nat_reality_port="${REALITY_PUBLIC_PORT:-${REALITY_PORT}}"
                    nat_hy2_port="${HY2_PUBLIC_PORT:-${HY2_PORT}}"
                    if ! nat_mode_enabled; then
                        nat_reality_port="${REALITY_PORT}"
                        nat_hy2_port="${HY2_PORT}"
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
                    NAT_MODE="true"
                    PUBLIC_IPV4_OVERRIDE="$nat_public_ip"
                    REALITY_PUBLIC_PORT="$nat_reality_port"
                    HY2_PUBLIC_PORT="$nat_hy2_port"
                    LINK_IPV4_SELECTION="all"
                    reset_public_ip_cache
                fi
                changed=true
                links_only_changed=true
                ;;
            0) return ;;
            *) continue ;;
        esac

        if [[ "$changed" == "true" ]]; then
            if [[ "$links_only_changed" != "true" ]] && ! validate_service_ports "$old_reality_port" "$old_hy2_port" "$old_subscription_port" false; then
                restore_runtime_params "$old_uuid" "$old_short_id" "$old_private_key" "$old_public_key" \
                    "$old_reality_port" "$old_reality_sni" "$old_ws_port" "$old_ws_path" \
                    "$old_node_name" "$old_hy2_port" "$old_hy2_password" "$old_hy2_sni" \
                    "$old_hy2_masquerade_url" \
                    "$old_subscription_port" "$old_argo_domain" "$old_argo_token" \
                    "$old_argo_best_cf_domain" "$old_argo_best_cf_domain_ipv4" "$old_argo_best_cf_domain_ipv6" \
                    "$old_link_ipv4_selection" "$old_public_ipv4_override" \
                    "$old_nat_mode" "$old_reality_public_port" "$old_hy2_public_port"
                warn "端口检查未通过，已保留原配置"
                press_enter
                continue
            fi
            if [[ "$ports_changed" == "true" ]] && ! confirm_port_selection; then
                restore_runtime_params "$old_uuid" "$old_short_id" "$old_private_key" "$old_public_key" \
                    "$old_reality_port" "$old_reality_sni" "$old_ws_port" "$old_ws_path" \
                    "$old_node_name" "$old_hy2_port" "$old_hy2_password" "$old_hy2_sni" \
                    "$old_hy2_masquerade_url" \
                    "$old_subscription_port" "$old_argo_domain" "$old_argo_token" \
                    "$old_argo_best_cf_domain" "$old_argo_best_cf_domain_ipv4" "$old_argo_best_cf_domain_ipv6" \
                    "$old_link_ipv4_selection" "$old_public_ipv4_override" \
                    "$old_nat_mode" "$old_reality_public_port" "$old_hy2_public_port"
                warn "已取消端口修改"
                press_enter
                continue
            fi
            if [[ "$links_only_changed" != "true" ]] && ! open_service_ports; then
                restore_runtime_params "$old_uuid" "$old_short_id" "$old_private_key" "$old_public_key" \
                    "$old_reality_port" "$old_reality_sni" "$old_ws_port" "$old_ws_path" \
                    "$old_node_name" "$old_hy2_port" "$old_hy2_password" "$old_hy2_sni" \
                    "$old_hy2_masquerade_url" \
                    "$old_subscription_port" "$old_argo_domain" "$old_argo_token" \
                    "$old_argo_best_cf_domain" "$old_argo_best_cf_domain_ipv4" "$old_argo_best_cf_domain_ipv6" \
                    "$old_link_ipv4_selection" "$old_public_ipv4_override" \
                    "$old_nat_mode" "$old_reality_public_port" "$old_hy2_public_port"
                warn "端口放行失败，已保留原配置"
                press_enter
                continue
            fi

            if [[ "$restart_singbox" == "true" ]]; then
                # 确保 TLS 证书存在 (Hysteria2 需要)
                generate_tls_cert
                write_singbox_config
                write_singbox_service
                save_params
                ensure_time_sync || true
                info "重启 sing-box..."
                if ! service_restart sing-box; then
                    restore_runtime_params "$old_uuid" "$old_short_id" "$old_private_key" "$old_public_key" \
                        "$old_reality_port" "$old_reality_sni" "$old_ws_port" "$old_ws_path" \
                        "$old_node_name" "$old_hy2_port" "$old_hy2_password" "$old_hy2_sni" \
                        "$old_hy2_masquerade_url" \
                        "$old_subscription_port" "$old_argo_domain" "$old_argo_token" \
                        "$old_argo_best_cf_domain" "$old_argo_best_cf_domain_ipv4" "$old_argo_best_cf_domain_ipv6" \
                        "$old_link_ipv4_selection" "$old_public_ipv4_override" \
                        "$old_nat_mode" "$old_reality_public_port" "$old_hy2_public_port"
                    write_singbox_config
                    write_singbox_service
                    save_params
                    warn "sing-box 重启失败，正在恢复旧端口配置..."
                    service_restart sing-box 2>/dev/null || true
                    press_enter
                    continue
                fi
                sleep 2
                if service_is_active sing-box; then
                    success "配置已更新并重启"
                else
                    restore_runtime_params "$old_uuid" "$old_short_id" "$old_private_key" "$old_public_key" \
                        "$old_reality_port" "$old_reality_sni" "$old_ws_port" "$old_ws_path" \
                        "$old_node_name" "$old_hy2_port" "$old_hy2_password" "$old_hy2_sni" \
                        "$old_hy2_masquerade_url" \
                        "$old_subscription_port" "$old_argo_domain" "$old_argo_token" \
                        "$old_argo_best_cf_domain" "$old_argo_best_cf_domain_ipv4" "$old_argo_best_cf_domain_ipv6" \
                        "$old_link_ipv4_selection" "$old_public_ipv4_override" \
                        "$old_nat_mode" "$old_reality_public_port" "$old_hy2_public_port"
                    write_singbox_config
                    write_singbox_service
                    save_params
                    warn "sing-box 未成功启动，正在恢复旧端口配置..."
                    service_restart sing-box 2>/dev/null || true
                    press_enter
                    continue
                fi
            else
                save_params
                success "配置已更新"
            fi

            if [[ "$restart_argo" == "true" ]]; then
                if ! refresh_argo_runtime; then
                    restore_runtime_params "$old_uuid" "$old_short_id" "$old_private_key" "$old_public_key" \
                        "$old_reality_port" "$old_reality_sni" "$old_ws_port" "$old_ws_path" \
                        "$old_node_name" "$old_hy2_port" "$old_hy2_password" "$old_hy2_sni" \
                        "$old_hy2_masquerade_url" \
                        "$old_subscription_port" "$old_argo_domain" "$old_argo_token" \
                        "$old_argo_best_cf_domain" "$old_argo_best_cf_domain_ipv4" "$old_argo_best_cf_domain_ipv6" \
                        "$old_link_ipv4_selection" "$old_public_ipv4_override" \
                        "$old_nat_mode" "$old_reality_public_port" "$old_hy2_public_port"
                    save_params
                    if argo_fixed_enabled; then
                        write_argo_service
                        service_enable_now argo-tunnel 2>/dev/null || true
                    else
                        service_stop argo-tunnel 2>/dev/null || true
                        service_disable argo-tunnel 2>/dev/null || true
                    fi
                    warn "Argo 配置更新失败，已恢复原配置"
                    press_enter
                    continue
                fi
            fi
            generate_and_show_links
            ensure_subscription_service_if_enabled || warn "订阅服务启动失败，请检查 python3 或服务日志"
            show_subscription_url
            press_enter
        fi
    done
}

# ─── 查看链接 ────────────────────────────────────────────────
do_show_links() {
    load_params || { warn "未找到配置，请先安装"; press_enter; return; }
    ensure_time_sync || true

    refresh_argo_domain_if_needed

    generate_and_show_links
    ensure_subscription_service_if_enabled || warn "订阅服务未成功启动"
    show_subscription_url
    press_enter
}

# ─── 启动 / 停止 / 重启 ──────────────────────────────────────
do_start() {
    info "启动服务..."
    ensure_time_sync || true
    service_start sing-box && success "sing-box 已启动" || warn "sing-box 启动失败"
    if load_params; then
        if argo_fixed_enabled; then
            service_start argo-tunnel && success "argo-tunnel 已启动" || warn "argo-tunnel 启动失败"
        fi
        save_params
        build_share_links
        write_subscription_assets
        ensure_subscription_service_if_enabled || warn "订阅服务启动失败"
    fi
    press_enter
}

do_stop() {
    info "停止服务..."
    service_stop sing-box && success "sing-box 已停止" || warn "sing-box 停止失败"
    service_stop argo-tunnel && success "argo-tunnel 已停止" || warn "argo-tunnel 停止失败"
    service_stop sbm-subscription && success "订阅服务已停止" || warn "订阅服务停止失败"
    press_enter
}

do_restart() {
    info "重启服务..."
    ensure_time_sync || true
    service_restart sing-box && success "sing-box 已重启" || warn "sing-box 重启失败"
    if load_params; then
        if argo_fixed_enabled; then
            service_restart argo-tunnel && success "argo-tunnel 已重启" || warn "argo-tunnel 重启失败"
        fi
        save_params
        build_share_links
        write_subscription_assets
        ensure_subscription_service_if_enabled || warn "订阅服务重启失败"
        argo_fixed_enabled && info "Argo 域名: ${ARGO_DOMAIN}"
    fi
    press_enter
}

# ─── 重新优选 Reality 伪装域名 ───────────────────────────────
do_reoptimize_reality_sni() {
    if ! load_params; then
        warn "未安装，无法重新优选 Reality 伪装域名"
        return 1
    fi

    if xray_managed_reality; then
        warn "当前 Reality 由 Xray 管理，已禁止 sing-box 重写 SNI，避免与 Hysteria2 共用端口冲突"
        return 1
    fi

    local old_sni="${REALITY_SNI:-}"
    local prev_sni="${REALITY_SNI_PREV:-}"
    info "当前 Reality 伪装域名: ${old_sni:-未设置}，开始重新优选（自动避开当前与上一次域名）..."

    # 清空后触发实测筛选；通过 REALITY_SNI_EXCLUDE 排除当前与上一次域名，
    # 确保重新优选的结果一定不同，否则就失去了重新优选的意义。
    REALITY_SNI=""
    REALITY_SNI_EXCLUDE="${old_sni} ${prev_sni}"
    select_reality_sni
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

    info "新伪装域名: ${REALITY_SNI}，正在写入配置并重启 sing-box..."
    generate_tls_cert
    write_singbox_config
    write_singbox_service
    save_params
    ensure_time_sync || true

    if ! service_restart sing-box; then
        warn "sing-box 重启失败，正在回滚到原伪装域名: ${old_sni}"
        REALITY_SNI="$old_sni"
        REALITY_SNI_PREV="$prev_sni"
        write_singbox_config
        save_params
        service_restart sing-box 2>/dev/null || true
        return 1
    fi

    sleep 2
    if ! service_is_active sing-box; then
        warn "sing-box 未成功启动，正在回滚到原伪装域名: ${old_sni}"
        REALITY_SNI="$old_sni"
        REALITY_SNI_PREV="$prev_sni"
        write_singbox_config
        save_params
        service_restart sing-box 2>/dev/null || true
        return 1
    fi

    success "Reality 伪装域名已更新为: ${REALITY_SNI}"
    refresh_argo_domain_if_needed
    generate_and_show_links
    ensure_subscription_service_if_enabled || warn "订阅服务启动失败"
    show_subscription_url
    return 0
}

# ─── 应用当前版本配置 (一键同步) ─────────────────────────────
# 用当前已保存的凭证 (UUID / 端口 / 域名 / 密钥均不变) 按新版本模板
# 重写服务端配置并重启，再按新格式重新生成链接。适用于升级脚本后
# 让服务端配置与当前稳定链接格式同步生效。
do_apply_latest() {
    if ! load_params; then
        warn "未安装，无法应用配置更新"
        return 1
    fi

    info "正在按 v${SCRIPT_VERSION} 模板重写配置 (UUID / 端口 / 域名 / 密钥保持不变)..."
    ensure_time_sync || true
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

    success "配置已按 v${SCRIPT_VERSION} 同步并重启"
    refresh_argo_runtime || return 1
    generate_and_show_links
    ensure_subscription_service_if_enabled || warn "订阅服务启动失败"
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
    echo ""
    echo -e "${CYAN}${BOLD}── sing-box 状态 ──${NC}"
    service_status sing-box || warn "sing-box 未安装"
    separator
    echo -e "${CYAN}${BOLD}── argo-tunnel 状态 ──${NC}"
    service_status argo-tunnel || warn "argo-tunnel 未安装"
    separator
    echo -e "${CYAN}${BOLD}── 订阅服务状态 ──${NC}"
    service_status sbm-subscription || warn "订阅服务未安装"
    press_enter
}

# ─── 查看日志 ────────────────────────────────────────────────
do_logs() {
    echo ""
    echo -e "  1) sing-box 日志"
    echo -e "  2) argo-tunnel 日志"
    echo -e "  3) 订阅服务日志"
    echo -e "  0) 返回"
    prompt_read choice "  请选择: "
    case "$choice" in
        1) service_logs sing-box 50 || warn "未找到 sing-box 日志" ;;
        2) service_logs argo-tunnel 50 || warn "未找到 argo-tunnel 日志" ;;
        3) service_logs sbm-subscription 50 || warn "未找到订阅服务日志" ;;
    esac
    press_enter
}

# ─── 开机自启设置 ──────────────────────────────────────────────
do_boot_manage() {
    echo ""
    echo -e "  1) 开启 sing-box 及已配置附加服务的开机自启"
    echo -e "  2) 关闭全部服务的开机自启"
    echo -e "  0) 返回"
    prompt_read choice "  请选择: "
    case "$choice" in
        1)
            service_enable sing-box 2>/dev/null || true
            load_params 2>/dev/null && argo_fixed_enabled && service_enable argo-tunnel 2>/dev/null || true
            load_params 2>/dev/null && argo_fixed_enabled && service_enable sbm-subscription 2>/dev/null || true
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
    echo ""
    echo -e "  1) 更新 sing-box"
    echo -e "  2) 更新 cloudflared"
    echo -e "  3) 更新此管理脚本"
    echo -e "  0) 返回"
    prompt_read choice "  请选择: "
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
            if ! load_params || ! argo_fixed_enabled; then
                warn "当前未启用固定域名 Argo，无需更新 cloudflared"
                press_enter
                return
            fi
            install_cloudflared_binary || error "cloudflared 更新失败。请检查网络、磁盘空间或 GitHub 访问"
            service_restart argo-tunnel 2>/dev/null || true
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
                    refresh_argo_domain_if_needed
                    generate_and_show_links
                    ensure_subscription_service_if_enabled || warn "订阅服务未成功启动"
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
    echo ""
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
    echo -e "  ${CYAN}部署 & 配置${NC}"
    echo -e "   ${BOLD}1)${NC} 部署 / 安装节点"
    echo -e "   ${BOLD}2)${NC} 修改配置 ${DIM}(端口 / 域名 / UUID / SNI)${NC}"
    echo -e "   ${BOLD}3)${NC} 节点链接与订阅"
    echo ""
    echo -e "  ${CYAN}服务管理${NC}"
    echo -e "   ${BOLD}4)${NC} 启动     ${BOLD}5)${NC} 停止     ${BOLD}6)${NC} 重启"
    echo -e "   ${BOLD}7)${NC} 状态     ${BOLD}8)${NC} 日志     ${BOLD}9)${NC} 自启"
    echo ""
    echo -e "  ${CYAN}系统维护${NC}"
    echo -e "  ${BOLD}10)${NC} 更新     ${BOLD}11)${NC} 卸载     ${BOLD}0)${NC} 退出"
    echo ""
}

main_menu() {
    get_public_ip 2>/dev/null || true

    while true; do
        show_banner
        show_menu
        if ! prompt_read choice "  请选择 [0-11]: "; then
            echo ""
            warn "未检测到交互式终端，请在服务器终端直接执行: sbm"
            exit 1
        fi
        case "$choice" in
            1)  do_install ;;
            2)  do_modify_config ;;
            3)  do_show_links ;;
            4)  do_start ;;
            5)  do_stop ;;
            6)  do_restart ;;
            7)  do_status ;;
            8)  do_logs ;;
            9)  do_boot_manage ;;
            10) do_upgrade ;;
            11) do_uninstall ;;
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
        install)       do_primary_install ;;
        relay-install) do_relay_install ;;
        relay)         do_generate_relay_script ;;
        links|sub)   load_params && { ensure_time_sync || true; refresh_argo_domain_if_needed; generate_and_show_links; ensure_subscription_service_if_enabled || warn "订阅服务未成功启动"; show_subscription_url; } || warn "未安装" ;;
        start)       do_start ;;
        stop)        do_stop ;;
        restart)     do_restart ;;
        resni|reality-sni) do_reoptimize_reality_sni || warn "Reality 伪装域名优选未完成" ;;
        apply|sync)  do_apply_latest || warn "配置同步未完成" ;;
        cfopt|refresh-cf|cfopt-auto) warn "固定域名 Argo 不再使用第三方 CF 优选域名" ;;
        status)      do_status ;;
        uninstall)   do_uninstall ;;
        --help|-h)
            echo "用法: bash $0 [命令]"
            echo ""
            echo "命令:"
            echo "  (无参数)        交互式管理菜单"
            echo "  install         直接安装主节点"
            echo "  relay-install   直接部署当前机器为线路机 / 落地机"
            echo "  relay           生成线路机部署脚本"
            echo "  links           显示分享链接与订阅地址"
            echo "  sub             同 links"
            echo "  start           启动服务"
            echo "  stop            停止服务"
            echo "  restart         重启服务"
            echo "  resni           重新优选 Reality 伪装域名(SNI)并重启生效"
            echo "  apply           按当前版本模板重写配置并重启 (升级后一键同步)"
            echo "  status          查看状态"
            echo "  uninstall       卸载"
            exit 0
            ;;
        *)  main_menu ;;
    esac
}

if [[ "${SBM_TEST_MODE:-}" != "1" ]]; then
    main "$@"
fi
