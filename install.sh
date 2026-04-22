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

set -euo pipefail

# ─── 常量 ─────────────────────────────────────────────────────
SCRIPT_VERSION="2.6.0"
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
PARAMS_FILE="${CONFIG_DIR}/.params"
LINK_FILE="${CONFIG_DIR}/share-links.txt"
SUBSCRIPTION_FILE="${CONFIG_DIR}/subscription.txt"
SUBSCRIPTION_SERVER="/usr/local/bin/sbm-subscription-server.py"
SUBSCRIPTION_SERVICE="/etc/systemd/system/sbm-subscription.service"
SUBSCRIPTION_PORT=24630
ARGO_SERVICE="/etc/systemd/system/argo-tunnel.service"
HY2_DEFAULT_PORT=8443
HY2_DEFAULT_SNI="bing.com"
TIME_SKEW_THRESHOLD=30

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
    read -rp "按 Enter 返回主菜单..." _
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

fetch_public_ipv4() {
    local endpoint ip
    for endpoint in \
        "https://ifconfig.me" \
        "https://api.ipify.org" \
        "https://icanhazip.com"; do
        ip=$(curl -4 -s --max-time 4 "$endpoint" 2>/dev/null | tr -d '[:space:]' || true)
        if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
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

refresh_public_ip_stack() {
    if [[ -n "${IP_STACK_MODE:-}" && -n "${PUBLIC_IP:-}" ]]; then
        return 0
    fi

    PUBLIC_IPV4=$(fetch_public_ipv4 || true)
    PUBLIC_IPV6=$(fetch_public_ipv6 || true)

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

is_private_ipv4() {
    local ip=$1
    [[ "$ip" =~ ^10\. ]] && return 0
    [[ "$ip" =~ ^192\.168\. ]] && return 0
    [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
    [[ "$ip" =~ ^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\. ]] && return 0
    [[ "$ip" =~ ^169\.254\. ]] && return 0
    return 1
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
        echo "direct"
        return 0
    fi

    if is_private_ipv4 "$PUBLIC_IP"; then
        echo "nat"
        return 0
    fi

    echo "panel"
}

# ─── 参数持久化 ──────────────────────────────────────────────
save_params() {
    cat > "$PARAMS_FILE" << EOF
UUID="${UUID}"
SHORT_ID="${SHORT_ID}"
PRIVATE_KEY="${PRIVATE_KEY}"
PUBLIC_KEY="${PUBLIC_KEY}"
REALITY_PORT="${REALITY_PORT}"
REALITY_SNI="${REALITY_SNI}"
WS_PORT="${WS_PORT}"
WS_PATH="${WS_PATH}"
NODE_NAME="${NODE_NAME}"
SUB_TOKEN="${SUB_TOKEN:-}"
ARGO_DOMAIN="${ARGO_DOMAIN:-}"
ARGO_TOKEN="${ARGO_TOKEN:-}"
ARGO_BEST_CF_DOMAIN="${ARGO_BEST_CF_DOMAIN:-}"
HY2_PORT="${HY2_PORT}"
HY2_PASSWORD="${HY2_PASSWORD}"
HY2_SNI="${HY2_SNI}"
EOF
    chmod 600 "$PARAMS_FILE"
}

load_params() {
    if [[ -f "$PARAMS_FILE" ]]; then
        source "$PARAMS_FILE"
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
        if [[ -z "${ARGO_TOKEN:-}" ]]; then
            ARGO_TOKEN=""
            # need_save 不标记，除非有实质性变化
        fi
        if [[ -z "${ARGO_BEST_CF_DOMAIN:-}" ]]; then
            ARGO_BEST_CF_DOMAIN=""
        fi
        if [[ -z "${SUB_TOKEN:-}" ]]; then
            SUB_TOKEN=$(openssl rand -hex 16)
            need_save=true
        fi
        [[ "$need_save" == "true" ]] && save_params
        return 0
    fi
    return 1
}

# ─── 安装组件 ────────────────────────────────────────────────
install_deps() {
    info "安装基础依赖..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq 2>/dev/null
        apt-get install -y -qq curl wget jq openssl python3 > /dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y -q curl wget jq openssl python3 > /dev/null 2>&1
    fi
    success "依赖就绪"
}

get_rtc_utc_epoch() {
    command -v hwclock &>/dev/null || return 1
    local rtc_raw
    rtc_raw=$(hwclock --utc --show 2>/dev/null | sed 's/  \..*$//')
    [[ -n "$rtc_raw" ]] || return 1
    date -u -d "$rtc_raw" +%s 2>/dev/null
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
    else
        return 1
    fi
}

start_time_sync_service() {
    for svc in systemd-timesyncd chrony chronyd; do
        if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1; then
            systemctl enable --now "${svc}" 2>/dev/null || systemctl restart "${svc}" 2>/dev/null || true
        fi
    done
}

install_time_sync_service() {
    if systemctl list-unit-files systemd-timesyncd.service >/dev/null 2>&1 || command -v chronyc &>/dev/null; then
        return 0
    fi

    if command -v apt-get &>/dev/null; then
        info "安装时间同步服务 systemd-timesyncd..."
        apt-get update -qq 2>/dev/null
        if apt-get install -y -qq systemd-timesyncd > /dev/null 2>&1; then
            return 0
        fi
        info "systemd-timesyncd 安装失败，回退安装 chrony..."
        apt-get install -y -qq chrony > /dev/null 2>&1 || return 1
    elif command -v yum &>/dev/null; then
        info "安装时间同步服务 chrony..."
        yum install -y -q chrony > /dev/null 2>&1 || return 1
    else
        return 1
    fi
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
        curl -fsSL https://sing-box.app/install.sh | sh
        success "sing-box 安装完成"
    fi
    mkdir -p "$CONFIG_DIR"
}

install_cloudflared() {
    if command -v cloudflared &>/dev/null; then
        info "cloudflared 已安装"
        return
    fi
    info "安装 cloudflared..."
    curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH_CF}" \
        -o /usr/local/bin/cloudflared
    chmod +x /usr/local/bin/cloudflared
    success "cloudflared 安装完成"
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
    ARGO_DOMAIN=""
    ARGO_TOKEN=""
    ARGO_BEST_CF_DOMAIN=""

    # Hysteria2 参数
    HY2_PORT=${HY2_PORT:-${HY2_DEFAULT_PORT}}
    HY2_PASSWORD=$(openssl rand -base64 16)
    HY2_SNI="${HY2_DEFAULT_SNI}"

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

    validate_port "${REALITY_PORT:-}" "Reality" || return 1
    validate_port "${WS_PORT:-}" "VLESS-WS" || return 1
    validate_port "${HY2_PORT:-}" "Hysteria2" || return 1

    if [[ "${REALITY_PORT}" == "${WS_PORT}" ]]; then
        warn "Reality 端口 ${REALITY_PORT}/TCP 与 VLESS-WS 内部端口 ${WS_PORT}/TCP 冲突"
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

    open_service_ports || return 1
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
            echo -e "  Subscription: ${BOLD}${SUBSCRIPTION_PORT}/TCP${NC} ${DIM}(订阅内容仅包含 Argo 节点)${NC}"
            echo ""
            return
            ;;
        direct)
            echo -e "  本机检测到公网 IP 直接挂载在网卡上。若仍有安全组/云防火墙，请同步放行以下端口。"
            ;;
        nat)
            echo -e "  检测到当前环境疑似 NAT / 转发型 VPS。仅修改本机防火墙通常不够，必须在面板额外放行或映射端口。"
            ;;
        panel)
            echo -e "  当前环境未检测到公网 IP 直接挂载在本机网卡，可能经过宿主机、防火墙面板或云安全组。请在外部面板同步放行。"
            ;;
        unknown)
            echo -e "  未能检测公网地址，请按实际网络环境放行端口。"
            ;;
    esac
    echo -e "  Reality:      ${BOLD}${REALITY_PORT}/TCP${NC}"
    if [[ "${HY2_PORT}" == "${REALITY_PORT}" ]]; then
        echo -e "  Hysteria2:    ${BOLD}${HY2_PORT}/UDP${NC} ${DIM}(与 Reality 共用端口号，但协议不同)${NC}"
    else
        echo -e "  Hysteria2:    ${BOLD}${HY2_PORT}/UDP${NC}"
    fi
    echo -e "  Subscription: ${BOLD}${SUBSCRIPTION_PORT}/TCP${NC}"
    echo -e "  ${DIM}Argo 的 ${WS_PORT}/TCP 仅供本机回环/隧道使用，一般不需要在外部面板放行。${NC}"
    if [[ "$access_mode" != "direct" ]]; then
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
    if [[ -n "$missing" ]]; then
        error "配置生成失败: 以下关键变量为空: ${missing}"
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
                    "uuid": "${UUID}",
                    "flow": "xtls-rprx-vision"
                }
            ],
            "tls": {
                "enabled": true,
                "server_name": "${REALITY_SNI}",
                "reality": {
                    "enabled": true,
                    "handshake": {
                        "server": "${REALITY_SNI}",
                        "server_port": 443
                    },
                    "private_key": "${PRIVATE_KEY}",
                    "short_id": [
                        "${SHORT_ID}"
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
                    "uuid": "${UUID}"
                }
            ],
            "transport": {
                "type": "ws",
                "path": "${WS_PATH}"
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
                    "password": "${HY2_PASSWORD}"
                }
            ],
            "tls": {
                "enabled": true,
                "server_name": "${HY2_SNI}",
                "key_path": "${CONFIG_DIR}/server.key",
                "certificate_path": "${CONFIG_DIR}/server.crt"
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

# ─── Argo 服务 ───────────────────────────────────────────────
write_argo_service() {
    local exec_cmd
    if [[ -n "${ARGO_TOKEN:-}" ]]; then
        info "使用 Token 模式启动 Argo 隧道 (固定域名)"
        exec_cmd="/usr/local/bin/cloudflared tunnel --protocol http2 --no-autoupdate run --token ${ARGO_TOKEN}"
    else
        info "使用临时隧道模式 (trycloudflare.com)"
        exec_cmd="/usr/local/bin/cloudflared tunnel --url http://127.0.0.1:${WS_PORT} --no-autoupdate --protocol http2"
    fi

    cat > "$ARGO_SERVICE" << EOF
[Unit]
Description=Cloudflare Argo Tunnel
After=network.target sing-box.service
Wants=sing-box.service

[Service]
Type=simple
User=nobody
Group=nogroup
ExecStart=${exec_cmd}
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# ─── 订阅服务 ────────────────────────────────────────────────
write_subscription_server() {
    cat > "$SUBSCRIPTION_SERVER" << 'PYEOF'
#!/usr/bin/env python3
import argparse
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


def build_handler(token: str, data_file: str):
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
                self.send_response(404)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.end_headers()
                self.wfile.write(b"Not Found\n")
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

        def log_message(self, format, *args):
            return

    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", default="0.0.0.0")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--token", required=True)
    parser.add_argument("--file", required=True)
    args = parser.parse_args()

    class Server(ThreadingHTTPServer):
        address_family = socket.AF_INET6 if ":" in args.listen else socket.AF_INET

    server = Server((args.listen, args.port), build_handler(args.token, args.file))
    server.serve_forever()


if __name__ == "__main__":
    main()
PYEOF
    chmod 755 "$SUBSCRIPTION_SERVER"
}

subscription_listen_host() {
    if refresh_public_ip_stack 2>/dev/null && [[ "${IP_STACK_MODE:-}" == "ipv6-only" ]]; then
        echo "::"
    else
        echo "0.0.0.0"
    fi
}

write_subscription_service() {
    local listen_host
    listen_host=$(subscription_listen_host)

    cat > "$SUBSCRIPTION_SERVICE" << EOF
[Unit]
Description=SBM Subscription Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/env python3 ${SUBSCRIPTION_SERVER} --listen ${listen_host} --port ${SUBSCRIPTION_PORT} --token ${SUB_TOKEN} --file ${SUBSCRIPTION_FILE}
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

ensure_subscription_service() {
    local backend

    validate_port "${SUBSCRIPTION_PORT}" "订阅服务" || return 1
    if ! command -v python3 &>/dev/null; then
        warn "未检测到 python3，无法启动订阅服务"
        return 1
    fi

    write_subscription_server
    write_subscription_service

    backend=$(detect_firewall_backend)
    open_firewall "${SUBSCRIPTION_PORT}" "$backend" tcp || return 1

    systemctl enable sbm-subscription --now 2>/dev/null || systemctl restart sbm-subscription
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
        ARGO_DOMAIN=$(journalctl -u argo-tunnel --output cat --no-pager 2>/dev/null | \
                      grep -oP 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' | \
                      tail -1 | sed 's|https://||')
        if [[ -n "$ARGO_DOMAIN" ]]; then
            if [[ -n "$previous_domain" && "$ARGO_DOMAIN" != "$previous_domain" ]]; then
                ARGO_BEST_CF_DOMAIN=""
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
    if [[ -z "${ARGO_DOMAIN:-}" ]] && systemctl is-active --quiet argo-tunnel 2>/dev/null; then
        fetch_argo_domain 2>/dev/null || true
        [[ -n "${ARGO_DOMAIN:-}" ]] && save_params
    fi
}

# ─── Reality 优选 SNI ────────────────────────────────────────
select_reality_sni() {
    if [[ -n "${REALITY_SNI:-}" ]]; then
        info "当前已设定伪装域名: $REALITY_SNI，跳过测速"
        return
    fi
    info "正在按兼容性优先顺序探测 ${#REALITY_SNI_LIST[@]} 个 Reality 候选域名..."

    local tmp_dir
    tmp_dir=$(mktemp -d)

    # Reality 目标站优先保证兼容性和稳定性，其次才是连接时间。
    for idx in "${!REALITY_SNI_LIST[@]}"; do
        local sni="${REALITY_SNI_LIST[$idx]}"
        (
            local time_ms
            time_ms=$(curl -o /dev/null -s -w '%{time_connect}' --connect-timeout 2 --tlsv1.3 "https://${sni}" 2>/dev/null || echo "9999")
            local ms
            ms=$(awk -v t="$time_ms" 'BEGIN {printf "%d", t * 1000}' 2>/dev/null || echo "9999")
            if [[ "$ms" -gt 0 && "$ms" -lt 9999 ]]; then
                echo "$idx $ms $sni" >> "${tmp_dir}/results.txt"
            fi
        ) &
    done
    wait

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

# ─── 链接与订阅生成 ──────────────────────────────────────────
build_share_links() {
    get_public_ip

    GENERATED_REALITY_LINK=""
    GENERATED_ARGO_LINK=""
    GENERATED_HY2_LINK=""
    GENERATED_SUBSCRIPTION_RAW=""

    if [[ "${IP_STACK_MODE:-}" == "ipv6-only" ]]; then
        warn "检测到 IPv6-only VPS，仅生成 Argo 节点链接。"
    else
        local remark
        remark=$(urlencode "${NODE_NAME}-Reality")
        GENERATED_REALITY_LINK="vless://${UUID}@${PUBLIC_IP}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${remark}"

        if [[ -f "${CONFIG_DIR}/server.crt" && -n "${HY2_PORT:-}" ]]; then
            local hy2_remark hy2_pass_enc
            hy2_remark=$(urlencode "${NODE_NAME}-Hysteria2")
            hy2_pass_enc=$(urlencode "${HY2_PASSWORD}")
            GENERATED_HY2_LINK="hysteria2://${hy2_pass_enc}@${PUBLIC_IP}:${HY2_PORT}?insecure=1&sni=${HY2_SNI}#${hy2_remark}"
        fi
    fi

    if [[ -n "${ARGO_DOMAIN:-}" ]]; then
        local argo_remark
        argo_remark=$(urlencode "${NODE_NAME}-Argo")

        resolve_argo_best_cf_domain
        local best_cf_domain="${ARGO_BEST_CF_DOMAIN:-}"

        GENERATED_ARGO_LINK="vless://${UUID}@${best_cf_domain}:443?encryption=none&security=tls&sni=${ARGO_DOMAIN}&type=ws&host=${ARGO_DOMAIN}&path=${WS_PATH}&fp=chrome#${argo_remark}"
    elif [[ "${IP_STACK_MODE:-}" == "ipv6-only" ]]; then
        warn "Argo 域名未就绪，暂无法生成 IPv6-only 可导入链接。"
    fi

    local link
    for link in "$GENERATED_REALITY_LINK" "$GENERATED_ARGO_LINK" "$GENERATED_HY2_LINK"; do
        [[ -z "$link" ]] && continue
        if [[ -z "$GENERATED_SUBSCRIPTION_RAW" ]]; then
            GENERATED_SUBSCRIPTION_RAW="$link"
        else
            GENERATED_SUBSCRIPTION_RAW+=$'\n'"$link"
        fi
    done
}

write_subscription_assets() {
    local subscription_base64

    subscription_base64=$(printf '%s' "${GENERATED_SUBSCRIPTION_RAW}" | base64 | tr -d '\r\n')
    printf '%s' "${subscription_base64}" > "$SUBSCRIPTION_FILE"
    chmod 600 "$SUBSCRIPTION_FILE"
}

show_subscription_url() {
    [[ -n "${GENERATED_SUBSCRIPTION_RAW:-}" ]] || return

    local public_host
    public_host=$(format_url_host "$PUBLIC_IP")

    echo -e "${CYAN}${BOLD}── 订阅地址 ──${NC}"
    echo -e "  ${BOLD}http://${public_host}:${SUBSCRIPTION_PORT}/sub/${SUB_TOKEN}${NC}"
    echo -e "  ${DIM}兼容写法: http://${public_host}:${SUBSCRIPTION_PORT}/sub?token=${SUB_TOKEN}${NC}"
    echo ""
}

generate_and_show_links() {
    build_share_links
    local is_ipv6_only=false
    [[ "${IP_STACK_MODE:-}" == "ipv6-only" ]] && is_ipv6_only=true

    echo ""
    echo -e "${PURPLE}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${PURPLE}${BOLD}║              📋 配置信息 & 分享链接                 ║${NC}"
    echo -e "${PURPLE}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""

    echo -e "${CYAN}${BOLD}── 基本信息 ──${NC}"
    if [[ "$is_ipv6_only" == "true" ]]; then
        echo -e "  公网类型:      ${BOLD}IPv6-only${NC}"
        echo -e "  服务器 IPv6:   ${BOLD}${PUBLIC_IP}${NC}"
    else
        echo -e "  服务器 IP:     ${BOLD}${PUBLIC_IP}${NC}"
    fi
    echo -e "  UUID:          ${BOLD}${UUID}${NC}"
    if [[ "$is_ipv6_only" != "true" ]]; then
        echo -e "  Reality 端口:  ${BOLD}${REALITY_PORT}${NC}"
        echo -e "  Reality SNI:   ${BOLD}${REALITY_SNI}${NC}"
        echo -e "  Public Key:    ${BOLD}${PUBLIC_KEY}${NC}"
        echo -e "  Short ID:      ${BOLD}${SHORT_ID}${NC}"
    fi
    if [[ -n "${ARGO_TOKEN:-}" ]]; then
        echo -e "  Argo 模式:     ${GREEN}固定域名 (Token)${NC}"
        echo -e "  Argo 域名:     ${BOLD}${ARGO_DOMAIN:-未配置}${NC}"
    else
        echo -e "  Argo 模式:     ${YELLOW}临时域名 (Quick)${NC}"
        [[ -n "${ARGO_DOMAIN:-}" ]] && echo -e "  Argo 域名:     ${BOLD}${ARGO_DOMAIN}${NC}"
    fi
    echo -e "  WS Path:       ${BOLD}${WS_PATH}${NC}"
    if [[ "$is_ipv6_only" != "true" ]]; then
        echo -e "  Hysteria2 端口: ${BOLD}${HY2_PORT}${NC}"
        echo -e "  Hysteria2 密码: ${BOLD}${HY2_PASSWORD}${NC}"
    fi
    echo ""

    if [[ -n "${GENERATED_REALITY_LINK}" ]]; then
        echo -e "${GREEN}${BOLD}── VLESS + Reality (直连) ──${NC}"
        echo -e "${YELLOW}${GENERATED_REALITY_LINK}${NC}"
        echo -e "  ${DIM}提示: Reality 请使用 Xray-core / sing-box 内核；若 v2rayN 当前使用 v2fly core，请先切换到 Xray core。${NC}"
        echo ""
    fi

    if [[ -n "${GENERATED_ARGO_LINK}" ]]; then
        echo -e "${BLUE}${BOLD}── VLESS + WS + Argo (CDN) ──${NC}"
        echo -e "  伪装域名(SNI): ${BOLD}${ARGO_DOMAIN}${NC}"
        echo -e "  优选域名(ADDR): ${BOLD}${ARGO_BEST_CF_DOMAIN}${NC}"
        echo -e "${YELLOW}${GENERATED_ARGO_LINK}${NC}"
        echo ""
    elif [[ "$is_ipv6_only" == "true" ]]; then
        echo -e "${YELLOW}  Argo 域名未就绪，稍后执行 sbm links 重新生成。${NC}"
        echo ""
    fi

    if [[ -n "${GENERATED_HY2_LINK}" ]]; then
        echo -e "${PURPLE}${BOLD}── Hysteria2 (QUIC/UDP 高速) ──${NC}"
        echo -e "${YELLOW}${GENERATED_HY2_LINK}${NC}"
        echo ""
    elif [[ "$is_ipv6_only" != "true" ]]; then
        echo -e "${DIM}  Hysteria2: 未启用 (重新安装即可自动启用)${NC}"
        echo ""
    fi

    show_subscription_url
    show_external_access_requirements
    write_subscription_assets

    {
        if [[ "$is_ipv6_only" == "true" ]]; then
            [[ -n "$GENERATED_ARGO_LINK" ]] && echo "$GENERATED_ARGO_LINK"
        else
            echo "# sing-box 分享链接 - $(date '+%Y-%m-%d %H:%M:%S')"
            echo ""
            if [[ -n "$GENERATED_REALITY_LINK" ]]; then
                echo "# VLESS + Reality (直连)"
                echo "$GENERATED_REALITY_LINK"
            fi
            if [[ -n "$GENERATED_ARGO_LINK" ]]; then
                echo ""
                echo "# VLESS + WS + Argo (CDN)"
                echo "$GENERATED_ARGO_LINK"
            fi
            if [[ -n "$GENERATED_HY2_LINK" ]]; then
                echo ""
                echo "# Hysteria2 (QUIC/UDP 高速)"
                echo "$GENERATED_HY2_LINK"
            fi
            if [[ -n "${GENERATED_SUBSCRIPTION_RAW:-}" ]]; then
                local public_host
                public_host=$(format_url_host "$PUBLIC_IP")
                echo ""
                echo "# Subscription"
                echo "http://${public_host}:${SUBSCRIPTION_PORT}/sub/${SUB_TOKEN}"
            fi
        fi
    } > "$LINK_FILE"
    chmod 600 "$LINK_FILE"

    echo -e "${DIM}链接已保存至: ${LINK_FILE}${NC}"
}

# ════════════════════════════════════════════════════════════
#  菜单功能
# ════════════════════════════════════════════════════════════

# ─── 完整安装 ────────────────────────────────────────────────
do_install() {
    echo ""
    info "开始完整安装..."
    separator

    install_deps
    ensure_time_sync || true
    install_singbox
    install_cloudflared
    generate_params

    # 询问端口模式
    echo ""
    echo -e "${CYAN}${BOLD}── 端口配置 ──${NC}"
    echo -e "  1) 极简单端口模式 (Reality & Hysteria2 共用 443/TCP+UDP) ${GREEN}推荐${NC}"
    echo -e "  2) 自定义分端口模式 (手动设置各个协议端口)"
    read -rp "  请选择 [1]: " port_mode
    port_mode=${port_mode:-1}

    if [[ "$port_mode" == "1" ]]; then
        REALITY_PORT=443
        HY2_PORT=443
        info "已选择单端口模式: 443"
    else
        read -rp "  Reality 端口 [${REALITY_PORT}]: " input
        [[ -n "$input" ]] && REALITY_PORT="$input"

        read -rp "  Hysteria2 端口 [${HY2_PORT}]: " input
        [[ -n "$input" ]] && HY2_PORT="$input"
    fi

    read -rp "  伪装域名 (留空自动测速优选): " input
    [[ -n "$input" ]] && REALITY_SNI="$input"

    read -rp "  节点名称 [${NODE_NAME}]: " input
    [[ -n "$input" ]] && NODE_NAME="$input"
    echo ""

    if ! validate_service_ports "" ""; then
        error "端口检查失败，请调整端口后重试"
    fi

    # 自动优选伪装域名
    select_reality_sni

    # 生成 TLS 自签证书 (Hysteria2 需要)
    generate_tls_cert

    # 询问 Argo 模式
    echo ""
    echo -e "${CYAN}${BOLD}── Argo 隧道配置 ──${NC}"
    echo -e "  1) 临时域名模式 (无需自定义域名，域名随机且会变)"
    echo -e "  2) 固定域名模式 (需提供 Cloudflare Tunnel Token) ${GREEN}推荐${NC}"
    read -rp "  请选择 [1]: " argo_choice
    argo_choice=${argo_choice:-1}
    if [[ "$argo_choice" == "2" ]]; then
        echo -e "\n  ${YELLOW}提示: 请前往 Cloudflare Zero Trust -> Networks -> Tunnels 创建隧道${NC}"
        echo -e "  并将 Public Hostname 转发至 ${GREEN}http://127.0.0.1:${WS_PORT}${NC}"
        echo -e "  并获取其对应的 Token ${YELLOW}(以 eyJ 开头的一长串字符)。${NC}"
        echo -e "  ${RED}注意: 千万不要把 Tunnel ID (连接器 ID) 错当成 Token！${NC}"
        read -rp "  请输入 Tunnel Token: " ARGO_TOKEN
        read -rp "  请输入该隧道绑定的域名 (如 v2.example.com): " ARGO_DOMAIN
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
    write_argo_service

    # 启动 sing-box
    info "启动 sing-box..."
    systemctl enable sing-box --now 2>/dev/null || systemctl restart sing-box
    sleep 2
    if systemctl is-active --quiet sing-box; then
        success "sing-box 已启动"
    else
        error "sing-box 启动失败: journalctl -u sing-box --output cat -e"
    fi

    # 启动 Argo
    info "启动 Argo 隧道..."
    systemctl enable argo-tunnel --now 2>/dev/null || systemctl restart argo-tunnel
    info "等待 Argo 隧道分配域名..."
    sleep 5

    if fetch_argo_domain; then
        success "Argo 域名: $ARGO_DOMAIN"
    else
        warn "未获取到 Argo 域名，可稍后重试"
    fi

    # 保存参数
    save_params

    # 显示链接
    generate_and_show_links
    ensure_subscription_service || warn "订阅服务启动失败，可稍后执行 sbm restart 重试"

    echo ""
    echo -e "${GREEN}${BOLD}✅ 部署完成！复制上方链接导入 v2rayN / v2rayNG 即可使用。${NC}"
    press_enter
}

# ─── 修改配置 ────────────────────────────────────────────────
do_modify_config() {
    load_params || { warn "未找到配置，请先安装"; press_enter; return; }

    while true; do
        local old_reality_port="${REALITY_PORT}"
        local old_hy2_port="${HY2_PORT}"
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
        echo -e "  0) 返回主菜单"
        echo ""
        read -rp "  请选择 [0-10]: " choice

        local changed=false
        case "$choice" in
            1)
                read -rp "  新端口: " input
                if [[ -n "$input" && "$input" =~ ^[0-9]+$ ]]; then
                    REALITY_PORT="$input"
                    changed=true
                fi
                ;;
            2)
                read -rp "  新伪装域名: " input
                if [[ -n "$input" ]]; then
                    REALITY_SNI="$input"
                    changed=true
                fi
                ;;
            3)
                UUID=$(sing-box generate uuid)
                info "新 UUID: $UUID"
                changed=true
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
                ;;
            5)
                read -rp "  新节点名称: " input
                if [[ -n "$input" ]]; then
                    NODE_NAME="$input"
                    changed=true
                fi
                ;;
            6)
                REALITY_SNI=""
                select_reality_sni
                changed=true
                ;;
            7)
                read -rp "  新 Hysteria2 端口: " input
                if [[ -n "$input" && "$input" =~ ^[0-9]+$ ]]; then
                    HY2_PORT="$input"
                    changed=true
                fi
                ;;
            8)
                HY2_PASSWORD=$(openssl rand -base64 16)
                info "新 Hysteria2 密码: $HY2_PASSWORD"
                changed=true
                ;;
            9)
                REALITY_PORT=443
                HY2_PORT=443
                info "已切换为单端口模式: 443"
                changed=true
                ;;
            10)
                echo -e "\n  当前模式: $( [[ -n "$ARGO_TOKEN" ]] && echo "固定域名" || echo "临时域名" )"
                echo -e "  1) 切换为/修改临时域名模式"
                echo -e "  2) 切换为/修改固定域名 Token 模式"
                read -rp "  请选择 [2]: " sub_choice
                sub_choice=${sub_choice:-2}
                if [[ "$sub_choice" == "2" ]]; then
                    local old_argo_domain="${ARGO_DOMAIN:-}"
                    local old_argo_token="${ARGO_TOKEN:-}"
                    echo -e "  ${YELLOW}提示: 请确保在 Cloudflare 仪表盘中将该域名转发至 http://127.0.0.1:${WS_PORT}${NC}"
                    echo -e "  ${RED}注意: 请填写完整的 Token (以 eyJ 开头)，千万不要误填为 Tunnel ID。${NC}"
                    read -rp "  新 Tunnel Token [${ARGO_TOKEN:0:10}...]: " input
                    [[ -n "$input" ]] && ARGO_TOKEN="$input"
                    read -rp "  新自定义域名 [${ARGO_DOMAIN}]: " input
                    if [[ -n "$input" ]]; then
                        ARGO_DOMAIN="$input"
                        ARGO_DOMAIN="${ARGO_DOMAIN#http://}"
                        ARGO_DOMAIN="${ARGO_DOMAIN#https://}"
                        ARGO_DOMAIN="${ARGO_DOMAIN%/}"
                    fi
                    if [[ "${ARGO_DOMAIN:-}" != "$old_argo_domain" || "${ARGO_TOKEN:-}" != "$old_argo_token" ]]; then
                        ARGO_BEST_CF_DOMAIN=""
                    fi
                else
                    ARGO_TOKEN=""
                    ARGO_DOMAIN=""
                    ARGO_BEST_CF_DOMAIN=""
                fi
                write_argo_service
                systemctl restart argo-tunnel 2>/dev/null
                changed=true
                ;;
            0) return ;;
            *) continue ;;
        esac

        if [[ "$changed" == "true" ]]; then
            if ! validate_service_ports "$old_reality_port" "$old_hy2_port"; then
                REALITY_PORT="$old_reality_port"
                HY2_PORT="$old_hy2_port"
                warn "端口检查未通过，已保留原配置"
                press_enter
                continue
            fi

            # 确保 TLS 证书存在 (Hysteria2 需要)
            generate_tls_cert
            write_singbox_config
            # 注意: 不重写 argo service，不重启 argo，不刷新 argo 域名
            save_params
            ensure_time_sync || true
            info "重启 sing-box..."
            if ! systemctl restart sing-box 2>/dev/null; then
                REALITY_PORT="$old_reality_port"
                HY2_PORT="$old_hy2_port"
                write_singbox_config
                save_params
                warn "sing-box 重启失败，正在回滚到旧端口配置..."
                systemctl restart sing-box 2>/dev/null || true
                press_enter
                continue
            fi
            sleep 2
            if systemctl is-active --quiet sing-box 2>/dev/null; then
                success "配置已更新并重启"
            else
                REALITY_PORT="$old_reality_port"
                HY2_PORT="$old_hy2_port"
                write_singbox_config
                save_params
                warn "sing-box 未成功启动，正在回滚到旧端口配置..."
                systemctl restart sing-box 2>/dev/null || true
                press_enter
                continue
            fi
            generate_and_show_links
            ensure_subscription_service || warn "订阅服务启动失败，请检查 python3 或 systemd 日志"
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
    press_enter
}

# ─── 启动 / 停止 / 重启 ──────────────────────────────────────
do_start() {
    info "启动服务..."
    ensure_time_sync || true
    systemctl start sing-box 2>/dev/null && success "sing-box 已启动" || warn "sing-box 启动失败"
    systemctl start argo-tunnel 2>/dev/null && success "argo-tunnel 已启动" || warn "argo-tunnel 启动失败"
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
    systemctl stop sing-box 2>/dev/null && success "sing-box 已停止" || warn "sing-box 停止失败"
    systemctl stop argo-tunnel 2>/dev/null && success "argo-tunnel 已停止" || warn "argo-tunnel 停止失败"
    systemctl stop sbm-subscription 2>/dev/null && success "订阅服务已停止" || warn "订阅服务停止失败"
    press_enter
}

do_restart() {
    info "重启服务..."
    ensure_time_sync || true
    systemctl restart sing-box 2>/dev/null && success "sing-box 已重启" || warn "sing-box 重启失败"
    systemctl restart argo-tunnel 2>/dev/null && success "argo-tunnel 已重启" || warn "argo-tunnel 重启失败"

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
    systemctl status sing-box --no-pager -l 2>/dev/null | head -15 || warn "sing-box 未安装"
    separator
    echo -e "${CYAN}${BOLD}── argo-tunnel 状态 ──${NC}"
    systemctl status argo-tunnel --no-pager -l 2>/dev/null | head -15 || warn "argo-tunnel 未安装"
    separator
    echo -e "${CYAN}${BOLD}── 订阅服务状态 ──${NC}"
    systemctl status sbm-subscription --no-pager -l 2>/dev/null | head -15 || warn "订阅服务未安装"
    press_enter
}

# ─── 查看日志 ────────────────────────────────────────────────
do_logs() {
    echo ""
    echo -e "  1) sing-box 日志"
    echo -e "  2) argo-tunnel 日志"
    echo -e "  3) 订阅服务日志"
    echo -e "  0) 返回"
    read -rp "  请选择: " choice
    case "$choice" in
        1) journalctl -u sing-box --output cat --no-pager -n 50 ;;
        2) journalctl -u argo-tunnel --output cat --no-pager -n 50 ;;
        3) journalctl -u sbm-subscription --output cat --no-pager -n 50 ;;
    esac
    press_enter
}

# ─── 开机自启设置 ──────────────────────────────────────────────
do_boot_manage() {
    echo ""
    echo -e "  1) 开启 sing-box / argo-tunnel / 订阅服务 开机自启"
    echo -e "  2) 关闭 sing-box / argo-tunnel / 订阅服务 开机自启"
    echo -e "  0) 返回"
    read -rp "  请选择: " choice
    case "$choice" in
        1)
            systemctl enable sing-box 2>/dev/null
            systemctl enable argo-tunnel 2>/dev/null
            systemctl enable sbm-subscription 2>/dev/null
            success "已开启开机自启"
            ;;
        2)
            systemctl disable sing-box 2>/dev/null
            systemctl disable argo-tunnel 2>/dev/null
            systemctl disable sbm-subscription 2>/dev/null
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
    read -rp "  请选择: " choice
    case "$choice" in
        1)
            info "更新 sing-box..."
            curl -fsSL https://sing-box.app/install.sh | sh
            systemctl restart sing-box 2>/dev/null
            success "sing-box 已更新并重启"
            ;;
        2)
            info "更新 cloudflared..."
            curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH_CF}" \
                -o /usr/local/bin/cloudflared
            chmod +x /usr/local/bin/cloudflared
            systemctl restart argo-tunnel 2>/dev/null
            success "cloudflared 已更新并重启"
            ;;
        3)
            info "更新管理脚本..."
            local script_url="https://raw.githubusercontent.com/iceeyes27/sing-box/main/install.sh"
            if curl -fsSL "$script_url" -o /usr/local/bin/sbm; then
                chmod +x /usr/local/bin/sbm
                ln -sf /usr/local/bin/sbm /usr/local/bin/sing-box-manager
                hash -r 2>/dev/null || true
                # 从新下载的脚本中提取版本号
                local new_ver
                new_ver=$(grep -m1 '^SCRIPT_VERSION=' /usr/local/bin/sbm | cut -d'"' -f2 2>/dev/null || echo "未知")
                success "脚本已更新: v${SCRIPT_VERSION} → v${new_ver}"
                echo ""
                info "当前配置和服务未受影响，不会重写配置或重启服务。"
                info "如需启用 Hysteria2 等新功能，请使用 [1) 重新安装] 或 [2) 修改配置]。"
                # 仅刷新链接显示 (不重写配置、不重启)
                if load_params; then
                    refresh_argo_domain_if_needed
                    generate_and_show_links
                    ensure_subscription_service || warn "订阅服务未成功启动"
                fi
                echo ""
                read -rp "按 Enter 重启面板并进入新版本..." _
                exec bash /usr/local/bin/sbm
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
    read -rp "  确认卸载？(y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { info "已取消"; press_enter; return; }

    systemctl stop sing-box 2>/dev/null || true
    systemctl disable sing-box 2>/dev/null || true
    systemctl stop argo-tunnel 2>/dev/null || true
    systemctl disable argo-tunnel 2>/dev/null || true
    systemctl stop sbm-subscription 2>/dev/null || true
    systemctl disable sbm-subscription 2>/dev/null || true
    rm -f "$ARGO_SERVICE"
    rm -f "$SUBSCRIPTION_SERVICE"
    systemctl daemon-reload

    if command -v apt-get &>/dev/null; then
        apt-get remove -y sing-box 2>/dev/null || true
    elif command -v yum &>/dev/null; then
        yum remove -y sing-box 2>/dev/null || true
    fi

    rm -f /usr/local/bin/cloudflared
    rm -f /usr/local/bin/sbm
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
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        sb_status="${GREEN}● 运行中${NC}"
    else
        sb_status="${RED}○ 未运行${NC}"
    fi
    if systemctl is-active --quiet argo-tunnel 2>/dev/null; then
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

    echo -e "  ${BOLD} 1)${NC} 安装 / 重新安装"
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
        read -rp "  请选择 [0-11]: " choice
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

check_root
detect_os

# 安装脚本副本到系统路径（方便后续直接调用 sbm）
if [[ "${BASH_SOURCE[0]:-}" != "/usr/local/bin/sbm" ]]; then
    curl -fsSL "https://raw.githubusercontent.com/iceeyes27/sing-box/main/install.sh" -o /usr/local/bin/sbm 2>/dev/null || true
    chmod +x /usr/local/bin/sbm 2>/dev/null || true
    # 为在线初次安装的用户顺便清一下 hash 缓存
    hash -r 2>/dev/null || true
fi

# 命令行快捷参数
# 若用户使用了旧命令名通过兼容链接启动，提示其换用新命令
if [[ "$(basename "$0")" == "sing-box-manager" ]]; then
    warn "sing-box-manager 命令已更名，推荐后续直接输入: sbm"
    sleep 1
fi

case "${1:-}" in
    install)     do_install ;;
    links|sub)   load_params && { ensure_time_sync || true; refresh_argo_domain_if_needed; generate_and_show_links; ensure_subscription_service || warn "订阅服务未成功启动"; } || warn "未安装" ;;
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
