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
SCRIPT_VERSION="2.6.23"
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
PARAMS_FILE="${CONFIG_DIR}/.params"
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
SINGBOX_OPENRC_SERVICE="/etc/init.d/sing-box"
HY2_DEFAULT_PORT=8443
HY2_DEFAULT_SNI="bing.com"
HY2_DEFAULT_MASQUERADE_URL="https://www.bing.com"
TIME_SKEW_THRESHOLD=30
LOW_MEMORY_SWAP_FILE="/swapfile.sbm-install"
LOW_MEMORY_SWAP_CREATED=false

# Reality 伪装域名候选列表
# Reality 更看重目标站点兼容性，不是单纯 HTTPS 连通或延迟最低即可。
# 这里保留相对稳定、证书和 TLS 表现更保守的候选，避免自动选到兼容性差的站点。
REALITY_SNI_LIST=(
    "www.microsoft.com"
    "www.apple.com"
    "www.amazon.com"
    "www.intel.com"
    "www.ibm.com"
    "www.oracle.com"
    "www.nvidia.com"
    "www.amd.com"
    "www.hp.com"
    "www.dell.com"
    "www.lenovo.com"
    "www.asus.com"
)

# ================== CF 优选域名列表 ==================
CF_DOMAINS=(
    "cf.090227.xyz"
    "cf.877774.xyz"
    "cf.130519.xyz"
    "cf.008500.xyz"
    "store.ubi.com"
    "saas.sin.fan"
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
    PUBLIC_IPV4=$(printf '%s\n' "$PUBLIC_IPV4_LIST" | head -n 1)
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

    if [[ "${IP_STACK_MODE:-}" == "dual-stack" ]]; then
        echo "dual-stack"
        return 0
    fi

    if has_public_ip_on_interface; then
        echo "direct"
        return 0
    fi

    if is_private_ipv4 "$PUBLIC_IP"; then
        echo "nat"
        return 0
    fi

    echo "panel"
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
    UUID SHORT_ID PRIVATE_KEY PUBLIC_KEY REALITY_PORT REALITY_SNI WS_PORT WS_PATH NODE_NAME
    SUB_TOKEN SUBSCRIPTION_PORT ARGO_DOMAIN ARGO_TOKEN ARGO_BEST_CF_DOMAIN
    ARGO_BEST_CF_DOMAIN_IPV4 ARGO_BEST_CF_DOMAIN_IPV6 LINK_IPV4_SELECTION PUBLIC_IPV4_OVERRIDE
    HY2_PORT HY2_PASSWORD HY2_SNI HY2_MASQUERADE_URL
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
            HY2_PASSWORD=$(openssl rand -base64 16)
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
            SUB_TOKEN=$(openssl rand -hex 16)
            need_save=true
        fi
        if [[ -z "${SUBSCRIPTION_PORT:-}" ]]; then
            SUBSCRIPTION_PORT=24630
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
    local missing=()

    command -v curl &>/dev/null || missing+=(curl)
    command -v openssl &>/dev/null || missing+=(openssl)
    [[ ${#missing[@]} -eq 0 ]] && return 0

    warn "缺少关键依赖: ${missing[*]}"
    install_packages_low_resource "${missing[@]}"
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
    local version arch tmp_dir archive url bin_path

    arch=$(get_singbox_release_arch) || return 1
    version=$(get_latest_singbox_version) || return 1
    tmp_dir=$(mktemp -d)
    archive="${tmp_dir}/sing-box.tar.gz"
    url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-${arch}-musl.tar.gz"

    info "下载 sing-box 官方二进制: v${version} (${arch}-musl)"
    if ! curl -fL --retry 3 --connect-timeout 15 -o "$archive" "$url"; then
        rm -rf "$tmp_dir"
        return 1
    fi

    if ! tar -xzf "$archive" -C "$tmp_dir"; then
        rm -rf "$tmp_dir"
        return 1
    fi

    bin_path=$(find "$tmp_dir" -type f -name sing-box | head -n 1 || true)
    if [[ -z "$bin_path" || ! -f "$bin_path" ]]; then
        rm -rf "$tmp_dir"
        return 1
    fi

    if command -v install &>/dev/null; then
        install -m 0755 "$bin_path" /usr/local/bin/sing-box
    else
        cp "$bin_path" /usr/local/bin/sing-box
        chmod 755 /usr/local/bin/sing-box
    fi

    hash -r 2>/dev/null || true
    if ! singbox_binary_available && [[ -x /usr/local/bin/sing-box ]]; then
        ln -sf /usr/local/bin/sing-box /usr/bin/sing-box 2>/dev/null || true
        hash -r 2>/dev/null || true
    fi

    rm -rf "$tmp_dir"
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
    install_missing_required_deps || error "关键依赖安装失败: curl openssl。请检查系统内存、磁盘空间或软件源"
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
    install_cloudflared_binary || error "cloudflared 安装失败。请检查网络、磁盘空间或 GitHub 访问"
    success "cloudflared 安装完成"
}

write_singbox_service() {
    [[ "$(service_manager)" == "openrc" ]] || return 0

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
}

# ─── 生成参数 ────────────────────────────────────────────────
generate_params() {
    info "生成安全参数..."
    UUID=$(sing-box generate uuid)
    SHORT_ID=$(openssl rand -hex 4)

    local keypair
    keypair=$(sing-box generate reality-keypair)
    PRIVATE_KEY=$(echo "$keypair" | grep -i "PrivateKey" | awk '{print $NF}')
    PUBLIC_KEY=$(echo "$keypair" | grep -i "PublicKey"  | awk '{print $NF}')

    REALITY_PORT=${REALITY_PORT:-443}
    REALITY_SNI="" # 在配置时通过测速自动选择
    WS_PORT=8080
    WS_PATH="/${SHORT_ID}"
    NODE_NAME=${NODE_NAME:-"sing-box-vps"}
    SUB_TOKEN=$(openssl rand -hex 16)
    SUBSCRIPTION_PORT=${SUBSCRIPTION_PORT:-24630}
    ARGO_DOMAIN=""
    ARGO_TOKEN=""
    ARGO_BEST_CF_DOMAIN=""
    ARGO_BEST_CF_DOMAIN_IPV4=""
    ARGO_BEST_CF_DOMAIN_IPV6=""
    LINK_IPV4_SELECTION="all"
    PUBLIC_IPV4_OVERRIDE=""

    # Hysteria2 参数
    HY2_PORT=${HY2_PORT:-${HY2_DEFAULT_PORT}}
    HY2_PASSWORD=$(openssl rand -base64 16)
    HY2_SNI="${HY2_DEFAULT_SNI}"
    HY2_MASQUERADE_URL="${HY2_DEFAULT_MASQUERADE_URL}"

    success "参数生成完成"
}

# ─── TLS 证书生成 (Hysteria2) ────────────────────────────────
generate_tls_cert() {
    local key_file="${CONFIG_DIR}/server.key"
    local cert_file="${CONFIG_DIR}/server.crt"

    if [[ -f "$key_file" && -f "$cert_file" ]]; then
        info "TLS 证书已存在，跳过生成"
        return
    fi

    info "生成自签 TLS 证书 (Hysteria2)..."
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$key_file" -out "$cert_file" \
        -days 3650 -nodes -subj "/CN=${HY2_SNI}" 2>/dev/null
    chmod 600 "$key_file" "$cert_file"
    success "TLS 自签证书已生成 (有效期 10 年)"
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
    if [[ -n "${HY2_PORT:-}" && "${HY2_PORT}" != "${REALITY_PORT:-}" ]]; then
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
    validate_port "${WS_PORT:-}" "VLESS-WS" || return 1
    validate_port "${HY2_PORT:-}" "Hysteria2" || return 1
    validate_port "${SUBSCRIPTION_PORT:-}" "订阅服务" || return 1

    if [[ "${REALITY_PORT}" == "${WS_PORT}" ]]; then
        warn "Reality 端口 ${REALITY_PORT}/TCP 与 VLESS-WS 内部端口 ${WS_PORT}/TCP 冲突"
        return 1
    fi
    if [[ "${SUBSCRIPTION_PORT}" == "${REALITY_PORT}" || "${SUBSCRIPTION_PORT}" == "${WS_PORT}" ]]; then
        warn "订阅服务端口 ${SUBSCRIPTION_PORT}/TCP 与现有 TCP 服务端口冲突"
        return 1
    fi

    if [[ -z "$old_reality_port" || "$REALITY_PORT" != "$old_reality_port" ]]; then
        assert_port_available "$REALITY_PORT" "tcp" "Reality" || return 1
    else
        info "Reality 端口未变化，跳过占用检查"
    fi

    if [[ -z "$old_hy2_port" || "$HY2_PORT" != "$old_hy2_port" ]]; then
        assert_port_available "$HY2_PORT" "udp" "Hysteria2" || return 1
    else
        info "Hysteria2 端口未变化，跳过占用检查"
    fi

    if [[ -z "$old_reality_port" ]]; then
        assert_port_available "$WS_PORT" "tcp" "VLESS-WS" || return 1
    fi

    if [[ -z "$old_subscription_port" || "$SUBSCRIPTION_PORT" != "$old_subscription_port" ]]; then
        assert_port_available "$SUBSCRIPTION_PORT" "tcp" "订阅服务" || return 1
    else
        info "订阅服务端口未变化，跳过占用检查"
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
    if [[ "${HY2_PORT}" == "${REALITY_PORT}" ]]; then
        echo -e "  Hysteria2:    ${BOLD}${HY2_PORT}/UDP${NC} ${DIM}(与 Reality 共用端口号，协议不同)${NC}"
    else
        echo -e "  Hysteria2:    ${BOLD}${HY2_PORT}/UDP${NC}"
    fi
    echo -e "  订阅服务:     ${BOLD}${SUBSCRIPTION_PORT}/TCP${NC} ${DIM}(仅本机/Argo 使用)${NC}"
    echo -e "  需要外部放行: ${BOLD}${REALITY_PORT}/TCP${NC}, ${BOLD}${HY2_PORT}/UDP${NC}"
    echo -e "  不需要外部放行: ${BOLD}${SUBSCRIPTION_PORT}/TCP${NC}"
    echo ""
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
            echo -e "  检测到 IPv6-only VPS，当前仅生成 Argo 节点链接。"
            echo -e "  Argo 的 ${WS_PORT}/TCP 仅供本机回环/隧道使用，一般不需要在外部面板放行。"
            echo -e "  Subscription: ${BOLD}HTTPS Argo 域名${NC} ${DIM}(本机 ${SUBSCRIPTION_PORT}/TCP 不需要外部放行)${NC}"
            echo ""
            return
            ;;
        dual-stack)
            echo -e "  检测到 IPv4 + IPv6 双栈 VPS，直连节点仅使用 IPv4，Argo 会分别输出 IPv4 / IPv6 接入链接。"
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
    if [[ "${HY2_PORT}" == "${REALITY_PORT}" ]]; then
        echo -e "  Hysteria2:    ${BOLD}${HY2_PORT}/UDP${NC} ${DIM}(与 Reality 共用端口号，但协议不同)${NC}"
    else
        echo -e "  Hysteria2:    ${BOLD}${HY2_PORT}/UDP${NC}"
    fi
    echo -e "  Subscription: ${BOLD}HTTPS Argo 域名${NC} ${DIM}(本机 ${SUBSCRIPTION_PORT}/TCP 不需要外部放行)${NC}"
    echo -e "  ${DIM}Argo 和订阅网关均仅供本机回环/隧道使用，一般不需要在外部面板放行。${NC}"
    if [[ "$access_mode" != "direct" && "$access_mode" != "ipv6-only" && "$access_mode" != "dual-stack" ]]; then
        echo -e "  ${DIM}注意: 当前脚本默认外部端口与本机监听端口相同；如果面板做了不同端口号的 NAT 映射，生成的节点链接和订阅地址需要按外部端口另行适配。${NC}"
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
    [[ -z "${WS_PORT:-}" ]]     && missing+="WS_PORT "
    [[ -z "${WS_PATH:-}" ]]     && missing+="WS_PATH "
    [[ -z "${HY2_PORT:-}" ]]    && missing+="HY2_PORT "
    [[ -z "${HY2_PASSWORD:-}" ]] && missing+="HY2_PASSWORD "
    [[ -z "${HY2_SNI:-}" ]]     && missing+="HY2_SNI "
    [[ -z "${HY2_MASQUERADE_URL:-}" ]] && missing+="HY2_MASQUERADE_URL "
    if [[ -n "$missing" ]]; then
        error "配置生成失败: 以下关键变量为空: ${missing}"
    fi

    local json_uuid json_reality_sni json_private_key json_short_id json_ws_path
    local json_hy2_password json_hy2_sni json_key_path json_cert_path json_hy2_masquerade_url

    json_uuid=$(json_string "$UUID")
    json_reality_sni=$(json_string "$REALITY_SNI")
    json_private_key=$(json_string "$PRIVATE_KEY")
    json_short_id=$(json_string "$SHORT_ID")
    json_ws_path=$(json_string "$WS_PATH")
    json_hy2_password=$(json_string "$HY2_PASSWORD")
    json_hy2_sni=$(json_string "$HY2_SNI")
    json_key_path=$(json_string "${CONFIG_DIR}/server.key")
    json_cert_path=$(json_string "${CONFIG_DIR}/server.crt")
    json_hy2_masquerade_url=$(json_string "$HY2_MASQUERADE_URL")

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
        },
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
        },
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
    cloudflared_bin=$(command -v cloudflared 2>/dev/null || echo "/usr/local/bin/cloudflared")
    argo_origin_url="http://127.0.0.1:${SUBSCRIPTION_PORT}"

    if [[ -n "${ARGO_TOKEN:-}" ]]; then
        info "使用 Token 模式启动 Argo 隧道 (固定域名)"
        info "Cloudflare Public Hostname 需转发至 ${argo_origin_url}"
        write_env_file "$ARGO_ENV_FILE" ARGO_TOKEN "$ARGO_TOKEN" TUNNEL_TOKEN "$ARGO_TOKEN"
        exec_cmd="tunnel --protocol http2 --no-autoupdate run"
    else
        info "使用临时隧道模式 (trycloudflare.com)"
        exec_cmd="tunnel --url ${argo_origin_url} --no-autoupdate --protocol http2"
    fi

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
        if [[ -n "${ARGO_TOKEN:-}" ]]; then
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
        fi
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
    [[ -n "${ARGO_TOKEN:-}" ]] && printf 'EnvironmentFile=%s\n' "$ARGO_ENV_FILE" >> "$ARGO_SERVICE"
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
    parser.add_argument("--listen", default="0.0.0.0")
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

# ─── 获取 Argo 域名 ──────────────────────────────────────────
fetch_argo_domain() {
    if [[ -n "${ARGO_TOKEN:-}" ]]; then
        # Token 模式下，如果用户没填域名，提醒一下
        if [[ -z "${ARGO_DOMAIN:-}" ]]; then
            warn "检测到 Token 模式但未配置自定义域名，分享链接将不包含 Argo 节点。"
            return 1
        fi
        return 0
    fi

    # 临时域名模式获取逻辑
    local max=10 i=0
    local previous_domain="${ARGO_DOMAIN:-}"
    ARGO_DOMAIN=""
    while [[ $i -lt $max ]]; do
        ARGO_DOMAIN=$(service_logs argo-tunnel 300 2>/dev/null | \
                      grep -Eo 'https://[[:alnum:]-]+\.trycloudflare\.com' | \
                      tail -1 | sed 's|https://||')
        if [[ -n "$ARGO_DOMAIN" ]]; then
            if [[ -n "$previous_domain" && "$ARGO_DOMAIN" != "$previous_domain" ]]; then
                clear_argo_best_cf_cache
                info "检测到新的 Argo 临时域名，已清空缓存的优选接入域名"
            fi
            return 0
        fi
        i=$((i + 1))
        sleep 3
    done
    return 1
}

refresh_argo_domain_if_needed() {
    if [[ -z "${ARGO_DOMAIN:-}" ]] && service_is_active argo-tunnel; then
        fetch_argo_domain 2>/dev/null || true
        [[ -n "${ARGO_DOMAIN:-}" ]] && save_params
    fi
}

refresh_argo_runtime() {
    if [[ -n "${ARGO_TOKEN:-}" && -z "${ARGO_DOMAIN:-}" ]]; then
        warn "固定域名模式缺少 Argo 域名，无法生成 Argo 订阅链接"
        return 1
    fi

    if [[ -z "${ARGO_TOKEN:-}" ]]; then
        ARGO_DOMAIN=""
        clear_argo_best_cf_cache
    fi

    write_argo_service
    if ! service_restart argo-tunnel; then
        warn "argo-tunnel 重启失败，无法更新 Argo 订阅链接"
        return 1
    fi

    if [[ -z "${ARGO_TOKEN:-}" ]]; then
        sleep 5
        if ! fetch_argo_domain; then
            warn "未获取到新的 Argo 临时域名，订阅链接未更新"
            return 1
        fi
    fi

    save_params
    return 0
}

update_argo_subscription_links() {
    refresh_argo_runtime || return 1
    generate_and_show_links
    ensure_subscription_service || warn "订阅服务启动失败，请检查 python3 或服务日志"
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

probe_reality_sni_candidate() {
    local idx="$1" sni="$2" result_file="$3"
    local time_s ms

    time_s=$(curl -o /dev/null -s -w '%{time_connect}' --connect-timeout 2 --tlsv1.3 "https://${sni}" 2>/dev/null || true)
    if [[ "$time_s" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        ms=$(awk -v t="$time_s" 'BEGIN {printf "%d", t * 1000}' 2>/dev/null || echo "9999")
    else
        ms=9999
    fi

    if [[ "$ms" =~ ^[0-9]+$ && "$ms" -gt 0 && "$ms" -lt 9999 ]]; then
        echo "$idx $ms $sni" >> "$result_file"
    fi
    return 0
}

select_reality_sni() {
    if [[ -n "${REALITY_SNI:-}" ]]; then
        info "当前已设定伪装域名: $REALITY_SNI，跳过测速"
        return
    fi
    local probe_parallelism
    probe_parallelism=$(get_reality_probe_parallelism)
    info "正在按兼容性优先顺序探测 ${#REALITY_SNI_LIST[@]} 个 Reality 候选域名，并发数: ${probe_parallelism}"

    local tmp_dir
    if ! tmp_dir=$(mktemp -d); then
        REALITY_SNI="${REALITY_SNI_LIST[0]}"
        warn "创建临时目录失败，使用默认伪装域名: ${REALITY_SNI}"
        return 0
    fi

    # Reality 目标站优先保证兼容性和稳定性，其次才是连接时间。
    local active_jobs=0
    for idx in "${!REALITY_SNI_LIST[@]}"; do
        local sni="${REALITY_SNI_LIST[$idx]}"
        probe_reality_sni_candidate "$idx" "$sni" "${tmp_dir}/results.txt" &
        active_jobs=$((active_jobs + 1))
        if (( active_jobs >= probe_parallelism )); then
            wait || true
            active_jobs=0
        fi
    done
    wait || true

    local best_sni="" best_time=9999
    if [[ -f "${tmp_dir}/results.txt" ]]; then
        local best
        best=$(sort -k1,1n -k2,2n "${tmp_dir}/results.txt" | head -1)
        best_time=$(echo "$best" | awk '{print $2}')
        best_sni=$(echo "$best" | awk '{print $3}')
    fi

    rm -rf "$tmp_dir"

    if [[ -n "$best_sni" ]]; then
        REALITY_SNI="$best_sni"
        success "已选择稳定优先的 Reality 域名: ${REALITY_SNI} (握手延迟: ${best_time}ms)"
    else
        REALITY_SNI="${REALITY_SNI_LIST[0]}"
        warn "所有域名测速均失败，使用默认伪装域名: ${REALITY_SNI}"
    fi
}

# ================== CF 优选：随机选择可用域名 ==================
select_random_cf_domain() {
    local available=()
    local curl_ip_arg=()
    [[ "${IP_STACK_MODE:-}" == "ipv6-only" ]] && curl_ip_arg=(-6)

    for domain in "${CF_DOMAINS[@]}"; do
        if curl "${curl_ip_arg[@]}" -s --max-time 2 -o /dev/null "https://$domain" 2>/dev/null; then
            available+=("$domain")
        fi
    done
    if [[ ${#available[@]} -gt 0 ]]; then
        echo "${available[$((RANDOM % ${#available[@]}))]}"
    fi
    return 0
}

select_random_cf_domain_by_family() {
    local family="$1"
    local available=()
    local curl_ip_arg=()

    case "$family" in
        ipv4) curl_ip_arg=(-4) ;;
        ipv6) curl_ip_arg=(-6) ;;
    esac

    for domain in "${CF_DOMAINS[@]}"; do
        if curl "${curl_ip_arg[@]}" -s --max-time 2 -o /dev/null "https://$domain" 2>/dev/null; then
            available+=("$domain")
        fi
    done
    if [[ ${#available[@]} -gt 0 ]]; then
        echo "${available[$((RANDOM % ${#available[@]}))]}"
    fi
    return 0
}

check_cf_domain_available_by_family() {
    local domain="$1"
    local family="$2"
    local curl_ip_arg=()

    [[ -n "$domain" ]] || return 1
    case "$family" in
        ipv4) curl_ip_arg=(-4) ;;
        ipv6) curl_ip_arg=(-6) ;;
    esac
    curl "${curl_ip_arg[@]}" -s --max-time 2 -o /dev/null "https://$domain" 2>/dev/null
}

check_cf_domain_available() {
    local domain="$1"
    local curl_ip_arg=()
    [[ -n "$domain" ]] || return 1
    [[ "${IP_STACK_MODE:-}" == "ipv6-only" ]] && curl_ip_arg=(-6)
    curl "${curl_ip_arg[@]}" -s --max-time 2 -o /dev/null "https://$domain" 2>/dev/null
}

resolve_argo_best_cf_domain() {
    [[ -n "${ARGO_DOMAIN:-}" ]] || return 1

    if check_cf_domain_available "${ARGO_BEST_CF_DOMAIN:-}"; then
        return 0
    fi

    local previous_domain="${ARGO_BEST_CF_DOMAIN:-}"
    local next_domain=""
    next_domain="$(select_random_cf_domain)"

    if [[ -z "$next_domain" ]]; then
        if [[ "${IP_STACK_MODE:-}" == "ipv6-only" ]]; then
            ARGO_BEST_CF_DOMAIN="${ARGO_DOMAIN}"
            warn "未探测到可用的 IPv6 CF 优选域名，使用 Argo 域名作为接入地址"
            save_params
            return 0
        fi

        if [[ -n "$previous_domain" ]]; then
            warn "原 Argo 优选域名当前不可用，且未找到新的可用域名，暂时保留原链接地址"
            ARGO_BEST_CF_DOMAIN="$previous_domain"
            return 0
        fi

        ARGO_BEST_CF_DOMAIN="${CF_DOMAINS[0]}"
        warn "未探测到可用的 CF 优选域名，首次生成链接时使用默认地址: ${ARGO_BEST_CF_DOMAIN}"
        save_params
        return 0
    fi

    ARGO_BEST_CF_DOMAIN="$next_domain"

    if [[ "${ARGO_BEST_CF_DOMAIN}" != "$previous_domain" ]]; then
        if [[ -n "$previous_domain" ]]; then
            warn "原 Argo 优选域名不可用，已切换为: ${ARGO_BEST_CF_DOMAIN}"
        else
            info "已为 Argo 选择并缓存优选域名: ${ARGO_BEST_CF_DOMAIN}"
        fi
        save_params
    fi

    return 0
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

hy2_share_link_available() {
    [[ -f "${CONFIG_DIR}/server.crt" && -n "${HY2_PORT:-}" ]] || return 1
    [[ -f "$CONFIG_FILE" ]] || return 1
    grep -q '"type"[[:space:]]*:[[:space:]]*"hysteria2"' "$CONFIG_FILE"
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
    append_reality_link "vless://${UUID}@${host}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${remark}"

    if hy2_share_link_available; then
        local hy2_remark hy2_pass_enc hy2_name
        if [[ -n "$family_label" ]]; then
            hy2_name="${NODE_NAME}-${family_label}-Hysteria2"
        else
            hy2_name="${NODE_NAME}-Hysteria2"
        fi
        hy2_remark=$(urlencode "$hy2_name")
        hy2_pass_enc=$(urlencode "${HY2_PASSWORD}")
        append_hy2_link "hysteria2://${hy2_pass_enc}@${host}:${HY2_PORT}?insecure=1&sni=${HY2_SNI}#${hy2_remark}"
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
    local best_cf_domain="$1"
    local family_label="$2"
    local argo_name argo_remark

    [[ -n "$best_cf_domain" ]] || return

    if [[ -n "$family_label" ]]; then
        argo_name="${NODE_NAME}-${family_label}-Argo"
    else
        argo_name="${NODE_NAME}-Argo"
    fi
    argo_remark=$(urlencode "$argo_name")
    append_argo_link "vless://${UUID}@${best_cf_domain}:443?encryption=none&security=tls&sni=${ARGO_DOMAIN}&type=ws&host=${ARGO_DOMAIN}&path=${WS_PATH}&fp=chrome#${argo_remark}"
}

# ─── 链接与订阅生成 ──────────────────────────────────────────
build_share_links() {
    GENERATED_REALITY_LINKS=""
    GENERATED_ARGO_LINKS=""
    GENERATED_HY2_LINKS=""
    GENERATED_SUBSCRIPTION_RAW=""
    ARGO_BEST_CF_DOMAIN_IPV4=""
    ARGO_BEST_CF_DOMAIN_IPV6=""

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
            warn "检测到 IPv6-only VPS，仅生成 Argo 节点链接。"
            ;;
        unknown)
            ;;
        *)
            build_direct_share_links_for_selected_ipv4s
            ;;
    esac

    if [[ -n "${ARGO_DOMAIN:-}" ]]; then
        if [[ "${IP_STACK_MODE:-}" == "dual-stack" ]]; then
            local old_cf_v4="${ARGO_BEST_CF_DOMAIN_IPV4:-}"
            local old_cf_v6="${ARGO_BEST_CF_DOMAIN_IPV6:-}"

            if ! check_cf_domain_available_by_family "${ARGO_BEST_CF_DOMAIN_IPV4:-}" ipv4; then
                ARGO_BEST_CF_DOMAIN_IPV4=$(select_random_cf_domain_by_family ipv4)
            fi
            if ! check_cf_domain_available_by_family "${ARGO_BEST_CF_DOMAIN_IPV6:-}" ipv6; then
                ARGO_BEST_CF_DOMAIN_IPV6=$(select_random_cf_domain_by_family ipv6)
            fi
            if [[ -z "$ARGO_BEST_CF_DOMAIN_IPV4" ]]; then
                ARGO_BEST_CF_DOMAIN_IPV4="${ARGO_BEST_CF_DOMAIN:-${CF_DOMAINS[0]}}"
                warn "未探测到可用的 IPv4 CF 优选域名，使用默认/缓存地址: ${ARGO_BEST_CF_DOMAIN_IPV4}"
            fi
            if [[ -z "$ARGO_BEST_CF_DOMAIN_IPV6" ]]; then
                ARGO_BEST_CF_DOMAIN_IPV6="${ARGO_DOMAIN}"
                warn "未探测到可用的 IPv6 CF 优选域名，使用 Argo 域名作为 IPv6 接入地址"
            fi
            ARGO_BEST_CF_DOMAIN="$ARGO_BEST_CF_DOMAIN_IPV4"
            if [[ "$ARGO_BEST_CF_DOMAIN_IPV4" != "$old_cf_v4" || "$ARGO_BEST_CF_DOMAIN_IPV6" != "$old_cf_v6" ]]; then
                save_params
            fi
            build_argo_link_for_domain "$ARGO_BEST_CF_DOMAIN_IPV4" "IPv4"
            build_argo_link_for_domain "$ARGO_BEST_CF_DOMAIN_IPV6" "IPv6"
        else
            resolve_argo_best_cf_domain
            local best_cf_domain="${ARGO_BEST_CF_DOMAIN:-}"
            build_argo_link_for_domain "$best_cf_domain" ""
        fi
    elif [[ "${IP_STACK_MODE:-}" == "ipv6-only" ]]; then
        warn "Argo 域名未就绪，暂无法生成 Argo 节点链接。"
    fi
}

write_subscription_assets() {
    local subscription_base64

    subscription_base64=$(printf '%s' "${GENERATED_SUBSCRIPTION_RAW}" | base64 | tr -d '\r\n')
    printf '%s' "${subscription_base64}" > "$SUBSCRIPTION_FILE"
    chmod 600 "$SUBSCRIPTION_FILE"
}

subscription_https_url() {
    [[ -n "${ARGO_DOMAIN:-}" && -n "${SUB_TOKEN:-}" ]] || return 1
    echo "https://${ARGO_DOMAIN}/sub/${SUB_TOKEN}"
}

subscription_local_url() {
    [[ -n "${SUB_TOKEN:-}" ]] || return 1
    echo "http://127.0.0.1:${SUBSCRIPTION_PORT}/sub/${SUB_TOKEN}"
}

show_subscription_url() {
    local public_subscription_url local_subscription_url

    [[ -n "${GENERATED_SUBSCRIPTION_RAW:-}" ]] || return

    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║                      订阅地址                       ║${NC}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    if public_subscription_url=$(subscription_https_url); then
        echo -e "${GREEN}${BOLD}HTTPS 订阅（导入 v2rayN / v2rayNG）${NC}"
        echo -e "${YELLOW}${BOLD}${public_subscription_url}${NC}"
    else
        echo -e "${YELLOW}Argo 域名未就绪，稍后执行 sbm links 重新生成 HTTPS 订阅地址。${NC}"
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
        echo -e "  Reality 端口:  ${BOLD}${REALITY_PORT}${NC}"
        echo -e "  Reality SNI:   ${BOLD}${REALITY_SNI}${NC}"
        echo -e "  Public Key:    ${BOLD}${PUBLIC_KEY}${NC}"
        echo -e "  Short ID:      ${BOLD}${SHORT_ID}${NC}"
    fi
    echo -e "  订阅端口:      ${BOLD}${SUBSCRIPTION_PORT}${NC}"
    if [[ -n "${ARGO_TOKEN:-}" ]]; then
        echo -e "  Argo 模式:     ${GREEN}固定域名 (Token)${NC}"
        echo -e "  Argo 域名:     ${BOLD}${ARGO_DOMAIN:-未配置}${NC}"
    else
        echo -e "  Argo 模式:     ${YELLOW}临时域名 (Quick)${NC}"
        [[ -n "${ARGO_DOMAIN:-}" ]] && echo -e "  Argo 域名:     ${BOLD}${ARGO_DOMAIN}${NC}"
    fi
    echo -e "  WS Path:       ${BOLD}${WS_PATH}${NC}"
    if [[ "${IP_STACK_MODE:-}" != "ipv6-only" && "${IP_STACK_MODE:-}" != "unknown" ]]; then
        echo -e "  Hysteria2 端口: ${BOLD}${HY2_PORT}${NC}"
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
        if [[ "${IP_STACK_MODE:-}" == "dual-stack" ]]; then
            echo -e "  IPv4 优选域名(ADDR): ${BOLD}${ARGO_BEST_CF_DOMAIN_IPV4}${NC}"
            echo -e "  IPv6 优选域名(ADDR): ${BOLD}${ARGO_BEST_CF_DOMAIN_IPV6}${NC}"
        else
            echo -e "  优选域名(ADDR): ${BOLD}${ARGO_BEST_CF_DOMAIN}${NC}"
        fi
        echo -e "${YELLOW}${GENERATED_ARGO_LINKS}${NC}"
        echo ""
    elif [[ "${IP_STACK_MODE:-}" == "ipv6-only" ]]; then
        echo -e "${YELLOW}  Argo 域名未就绪，稍后执行 sbm links 重新生成。${NC}"
        echo ""
    fi

    if [[ -n "${GENERATED_HY2_LINKS}" ]]; then
        echo -e "${PURPLE}${BOLD}── Hysteria2 (QUIC/UDP 高速) ──${NC}"
        echo -e "${YELLOW}${GENERATED_HY2_LINKS}${NC}"
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
        if [[ -n "${GENERATED_SUBSCRIPTION_RAW:-}" ]]; then
            echo ""
            echo "# Subscription"
            local subscription_url
            if subscription_url=$(subscription_https_url); then
                echo "$subscription_url"
            else
                echo "# Argo domain is not ready. Run: sbm links"
            fi
        fi
    } > "$LINK_FILE"
    chmod 600 "$LINK_FILE"

    echo -e "${DIM}链接已保存至: ${LINK_FILE}${NC}"
}

json_string() {
    local value="${1-}"
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$value"
        return
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
    local value

    value=$(escape_sed_replacement "$3")
    sed -i "s|${token}|${value}|g" "$file"
}

write_relay_install_script() {
    local relay_script="$1"
    local relay_port="$2"
    local relay_sni="$3"
    local upstream_server="$4"
    local upstream_host="$5"
    local relay_name="$6"

    [[ -n "$relay_script" && -n "$relay_port" && -n "$relay_sni" ]] || return 1
    [[ -n "$upstream_server" && -n "$upstream_host" && -n "${UUID:-}" && -n "${WS_PATH:-}" ]] || return 1

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
            apt-get install -y curl ca-certificates openssl
            ;;
        dnf) dnf install -y curl ca-certificates openssl ;;
        yum) yum install -y curl ca-certificates openssl ;;
        apk)
            apk update
            apk add --no-cache curl ca-certificates openssl openrc tar
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
    local version arch tmp url archive bin_path

    version=$(latest_singbox_version)
    arch=$(singbox_arch)
    tmp=$(mktemp -d)
    archive="${tmp}/sing-box.tar.gz"
    url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-${arch}-musl.tar.gz"

    curl -fL "$url" -o "$archive"
    tar -xzf "$archive" -C "$tmp"
    bin_path=$(find "$tmp" -type f -name sing-box | head -n 1)
    [[ -n "$bin_path" ]] || err "未找到 sing-box 二进制"
    cp "$bin_path" /usr/local/bin/sing-box
    chmod +x /usr/local/bin/sing-box
    rm -rf "$tmp"
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
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$value"
        return
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
REALITY_SHORT_ID=$(sing-box generate rand 8 --hex 2>/dev/null || openssl rand -hex 4)

[[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" ]] || err "Reality 密钥生成失败"

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
    replace_file_token "$relay_script" "__UPSTREAM_UUID__" "$UUID"
    replace_file_token "$relay_script" "__UPSTREAM_WS_PATH__" "$WS_PATH"
    replace_file_token "$relay_script" "__RELAY_NAME__" "$relay_name"
    chmod 700 "$relay_script"
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
    install_cloudflared
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

        prompt_port_value SUBSCRIPTION_PORT "订阅服务" "$SUBSCRIPTION_PORT" "  订阅服务端口 [${SUBSCRIPTION_PORT}]: " || error "端口读取失败"

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

    prompt_read input "  伪装域名 (留空自动测速优选): "
    [[ -n "$input" ]] && REALITY_SNI="$input"

    prompt_read input "  节点名称 [${NODE_NAME}]: "
    [[ -n "$input" ]] && NODE_NAME="$input"
    echo ""
    if ! refresh_public_ip_stack; then
        warn "未能自动获取公网 IP。"
        warn "如需生成 Reality/Hysteria2 直连链接，可手动填写公网 IPv4；留空则本次尽量仅生成 Argo 链接。"
        prompt_public_ipv4_override_optional || true
    fi
    prompt_ipv4_link_selection_if_multiple || true

    # 自动优选伪装域名
    select_reality_sni

    # 生成 TLS 自签证书 (Hysteria2 需要)
    generate_tls_cert

    # 询问 Argo 模式
    echo ""
    echo -e "${CYAN}${BOLD}── Argo 隧道配置 ──${NC}"
    echo -e "  1) 临时域名模式 (无需自定义域名，域名随机且会变)"
    echo -e "  2) 固定域名模式 (需提供 Cloudflare Tunnel Token) ${GREEN}推荐${NC}"
    prompt_read argo_choice "  请选择 [1]: "
    argo_choice=${argo_choice:-1}
    if [[ "$argo_choice" == "2" ]]; then
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
        [[ -z "$ARGO_TOKEN" || -z "$ARGO_DOMAIN" ]] && warn "Token 或域名为空，将降级为临时域名模式" && ARGO_TOKEN="" && ARGO_DOMAIN=""
    else
        ARGO_TOKEN=""
        ARGO_DOMAIN=""
    fi

    write_singbox_config
    write_singbox_service
    write_argo_service

    # 启动 sing-box
    info "启动 sing-box..."
    service_enable_now sing-box
    sleep 2
    if service_is_active sing-box; then
        success "sing-box 已启动"
    else
        error "sing-box 启动失败，请查看服务日志"
    fi

    ensure_subscription_service || warn "订阅服务启动失败，可稍后执行 sbm restart 重试"

    # 启动 Argo
    info "启动 Argo 隧道..."
    service_enable_now argo-tunnel
    info "等待 Argo 隧道分配域名..."
    sleep 5

    if fetch_argo_domain; then
        success "Argo 域名: $ARGO_DOMAIN"
    else
        warn "未获取到 Argo 域名，可稍后重试"
    fi

    # 保存参数
    save_params

    echo ""
    echo -e "${GREEN}${BOLD}✅ 部署完成！最后展示的 HTTPS 订阅地址可导入 v2rayN / v2rayNG。${NC}"

    # 显示链接
    generate_and_show_links
    show_subscription_url
    press_enter
}

do_install() {
    echo ""
    echo -e "${CYAN}${BOLD}── 部署目标 ──${NC}"
    echo -e "  1) 主节点完整部署 ${GREEN}推荐${NC}"
    echo -e "  2) 生成线路机部署脚本"
    echo -e "  0) 返回"
    prompt_read target "  请选择 [1]: "
    target=${target:-1}

    case "$target" in
        1) do_primary_install ;;
        2) do_generate_relay_script ;;
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
        echo -e "  0) 返回主菜单"
        echo ""
        prompt_read choice "  请选择 [0-14]: "

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
                SHORT_ID=$(openssl rand -hex 4)
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
                REALITY_SNI=""
                select_reality_sni
                changed=true
                restart_singbox=true
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
                HY2_PASSWORD=$(openssl rand -base64 16)
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
                echo -e "\n  当前模式: $( [[ -n "$ARGO_TOKEN" ]] && echo "固定域名" || echo "临时域名" )"
                echo -e "  1) 切换为/修改临时域名模式"
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
                    "$old_link_ipv4_selection" "$old_public_ipv4_override"
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
                    "$old_link_ipv4_selection" "$old_public_ipv4_override"
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
                    "$old_link_ipv4_selection" "$old_public_ipv4_override"
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
                        "$old_link_ipv4_selection" "$old_public_ipv4_override"
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
                        "$old_link_ipv4_selection" "$old_public_ipv4_override"
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
                        "$old_link_ipv4_selection" "$old_public_ipv4_override"
                    save_params
                    write_argo_service
                    service_restart argo-tunnel 2>/dev/null || true
                    warn "Argo 配置更新失败，已恢复原配置"
                    press_enter
                    continue
                fi
            fi
            generate_and_show_links
            ensure_subscription_service || warn "订阅服务启动失败，请检查 python3 或服务日志"
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
    ensure_subscription_service || warn "订阅服务未成功启动"
    show_subscription_url
    press_enter
}

# ─── 启动 / 停止 / 重启 ──────────────────────────────────────
do_start() {
    info "启动服务..."
    ensure_time_sync || true
    service_start sing-box && success "sing-box 已启动" || warn "sing-box 启动失败"
    service_start argo-tunnel && success "argo-tunnel 已启动" || warn "argo-tunnel 启动失败"
    if load_params; then
        sleep 3
        fetch_argo_domain 2>/dev/null || true
        save_params
        build_share_links
        write_subscription_assets
        ensure_subscription_service || warn "订阅服务启动失败"
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
    service_restart argo-tunnel && success "argo-tunnel 已重启" || warn "argo-tunnel 重启失败"

    sleep 5
    if load_params; then
        fetch_argo_domain 2>/dev/null || true
        save_params
        build_share_links
        write_subscription_assets
        ensure_subscription_service || warn "订阅服务重启失败"
        info "Argo 域名: ${ARGO_DOMAIN:-获取中...}"
    fi
    press_enter
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
    echo -e "  1) 开启 sing-box / argo-tunnel / 订阅服务 开机自启"
    echo -e "  2) 关闭 sing-box / argo-tunnel / 订阅服务 开机自启"
    echo -e "  0) 返回"
    prompt_read choice "  请选择: "
    case "$choice" in
        1)
            service_enable sing-box 2>/dev/null || true
            service_enable argo-tunnel 2>/dev/null || true
            service_enable sbm-subscription 2>/dev/null || true
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
                info "如需启用 Hysteria2 等新功能，请使用 [1) 重新安装] 或 [2) 修改配置]。"
                # 仅刷新链接显示 (不重写配置、不重启)
                if load_params; then
                    refresh_argo_domain_if_needed
                    generate_and_show_links
                    ensure_subscription_service || warn "订阅服务未成功启动"
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
    rm -f "$ARGO_SERVICE"
    rm -f "$ARGO_OPENRC_SERVICE"
    rm -f "$SUBSCRIPTION_SERVICE"
    rm -f "$SUBSCRIPTION_OPENRC_SERVICE"
    rm -f "$SINGBOX_OPENRC_SERVICE"
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
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════════════╗"
    echo "  ║     sing-box 管理面板  v${SCRIPT_VERSION}              ║"
    echo "  ╚══════════════════════════════════════════════╝"
    echo -e "${NC}"

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
    local installed=false
    [[ -f "$CONFIG_FILE" ]] && installed=true

    echo -e "  ${BOLD} 1)${NC} 部署目标选择"
    echo -e "  ${BOLD} 2)${NC} 修改配置 ${DIM}(端口/域名/UUID)${NC}"
    echo -e "  ${BOLD} 3)${NC} 查看节点链接"
    separator
    echo -e "  ${BOLD} 4)${NC} 启动服务"
    echo -e "  ${BOLD} 5)${NC} 停止服务"
    echo -e "  ${BOLD} 6)${NC} 重启服务"
    echo -e "  ${BOLD} 7)${NC} 查看运行状态"
    echo -e "  ${BOLD} 8)${NC} 查看日志"
    echo -e "  ${BOLD} 9)${NC} 开机自启设置"
    separator
    echo -e "  ${BOLD}10)${NC} 更新 (sing-box/cloudflared/脚本)"
    echo -e "  ${BOLD}11)${NC} 卸载"
    echo -e "  ${BOLD} 0)${NC} 退出"
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
        install)     do_primary_install ;;
        relay)       do_generate_relay_script ;;
        links|sub)   load_params && { ensure_time_sync || true; refresh_argo_domain_if_needed; generate_and_show_links; ensure_subscription_service || warn "订阅服务未成功启动"; show_subscription_url; } || warn "未安装" ;;
        start)       do_start ;;
        stop)        do_stop ;;
        restart)     do_restart ;;
        status)      do_status ;;
        uninstall)   do_uninstall ;;
        --help|-h)
            echo "用法: bash $0 [命令]"
            echo ""
            echo "命令:"
            echo "  (无参数)   交互式管理菜单"
            echo "  install    直接安装"
            echo "  relay      生成线路机部署脚本"
            echo "  links      显示分享链接与订阅地址"
            echo "  sub        同 links"
            echo "  start      启动服务"
            echo "  stop       停止服务"
            echo "  restart    重启服务"
            echo "  status     查看状态"
            echo "  uninstall  卸载"
            exit 0
            ;;
        *)  main_menu ;;
    esac
}

if [[ "${SBM_TEST_MODE:-}" != "1" ]]; then
    main "$@"
fi
