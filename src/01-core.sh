# ─── 常量 ─────────────────────────────────────────────────────
SCRIPT_VERSION="2.6.33"
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
# Reality 伪装域名候选池。挑选标准:
#   1) 在受审查地区「未被封锁」(否则伪装目标本身被墙，反而暴露);
#   2) 稳定支持 TLS 1.3 + HTTP/2(Reality 转发所需，运行时还会再实测校验);
#   3) 境外高信誉站点，封锁代价高，借用其 TLS 身份更可信;
#   4) 避免国内可解析 / 国内 CDN 落地的站点(如 lenovo/asus)。
# 运行时 select_reality_sni 会对每个域名实测 TLS1.3+h2 能力并按握手延迟择优，
# 不合规的会被自动剔除，因此这里只需提供「方向正确」的候选。
REALITY_SNI_LIST=(
    "www.microsoft.com"
    "www.apple.com"
    "gateway.icloud.com"
    "itunes.apple.com"
    "www.amazon.com"
    "www.swift.com"
    "www.tesla.com"
    "addons.mozilla.org"
    "www.intel.com"
    "www.nvidia.com"
    "www.amd.com"
    "www.ibm.com"
)

# ================== CF 优选域名列表 ==================
# 这些是「三网分流」智能 DNS 优选域名:客户端解析时会按其所在运营商自动
# 返回对应的最优 Cloudflare 边缘 IP(电信用户拿到电信最优 IP，移动拿到移动
# 最优 IP)。因此优选发生在「客户端侧」,链接里对所有人是同一个域名。
#
# 选取侧重「电信」、其次「移动」(不针对联通),全部为三网分流优选域名,
# 任意命中都对电信/移动有优化;来源 DustinWin/BestCF 优选域名聚合
# (CMLiussss / VPS789 / CFYes / 微测网),已校验为存活的 Cloudflare 边缘。
#
# ⚠ 社区优选域名会随时间失效,建议定期对照下列来源更新,并最好用电信网络
#   实测后再定:https://github.com/DustinWin/BestCF (release: bestcf-domain.txt)
CF_DOMAINS=(
    "cf.090227.xyz"      # CMLiussss 三网分流，电信/移动口碑最佳
    "cf.877774.xyz"      # 三网分流优选
    "cf.008500.xyz"      # 三网分流优选
    "bestcf.030101.xyz"  # BestCF 聚合（电信/移动）
    "cdn.2020111.xyz"    # BestCF 聚合（电信/移动）
    "cf.0sm.com"         # 三网分流优选
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
    UUID SHORT_ID PRIVATE_KEY PUBLIC_KEY REALITY_PORT REALITY_SNI REALITY_SNI_PREV WS_PORT WS_PATH NODE_NAME
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

