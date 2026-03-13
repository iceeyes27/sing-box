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
SCRIPT_VERSION="2.2.0"
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
PARAMS_FILE="${CONFIG_DIR}/.params"
LINK_FILE="${CONFIG_DIR}/share-links.txt"
ARGO_SERVICE="/etc/systemd/system/argo-tunnel.service"

# Reality 伪装域名候选列表 (多区域、多行业综合过滤版)
# 包含科技巨头、跨国CDN、流媒体、游戏公司等，确保不同网络环境下都有连通率高的节点
REALITY_SNI_LIST=(
    "www.microsoft.com"
    "www.apple.com"
    "www.amazon.com"
    "www.cloudflare.com"
    "www.ubuntu.com"
    "www.samsung.com"
    "www.intel.com"
    "www.cisco.com"
    "www.ibm.com"
    "www.oracle.com"
    "www.sony.com"
    "www.nintendo.com"
    "www.ea.com"
    "www.playstation.com"
    "www.xbox.com"
    "www.blizzard.com"
    "www.epicgames.com"
    "www.steampowered.com"
    "www.nvidia.com"
    "www.amd.com"
    "www.hp.com"
    "www.dell.com"
    "www.lenovo.com"
    "www.asus.com"
    "www.acer.com"
    "www.disney.com"
    "www.netflix.com"
    "www.twitch.tv"
    "www.coca-cola.com"
    "www.pepsi.com"
    "www.toyota.com"
    "www.honda.com"
    "www.mercedes-benz.com"
    "www.bmw.com"
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

get_public_ip() {
    PUBLIC_IP=$(curl -4 -s --max-time 5 https://ifconfig.me 2>/dev/null || \
                curl -4 -s --max-time 5 https://api.ipify.org 2>/dev/null || \
                curl -4 -s --max-time 5 https://icanhazip.com 2>/dev/null || \
                echo "")
    [[ -n "$PUBLIC_IP" ]] || error "无法获取公网 IP"
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
ARGO_DOMAIN="${ARGO_DOMAIN:-}"
EOF
    chmod 600 "$PARAMS_FILE"
}

load_params() {
    if [[ -f "$PARAMS_FILE" ]]; then
        source "$PARAMS_FILE"
        return 0
    fi
    return 1
}

# ─── 安装组件 ────────────────────────────────────────────────
install_deps() {
    info "安装基础依赖..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq 2>/dev/null
        apt-get install -y -qq curl wget jq openssl > /dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y -q curl wget jq openssl > /dev/null 2>&1
    fi
    success "依赖就绪"
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
    ARGO_DOMAIN=""

    success "参数生成完成"
}

# ─── sing-box 配置生成 ───────────────────────────────────────
write_singbox_config() {
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
                    ],
                    "max_time_difference": "1m"
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

    if sing-box check -c "$CONFIG_FILE" 2>/dev/null; then
        success "配置校验通过"
    else
        error "配置校验失败"
    fi
}

# ─── Argo 服务 ───────────────────────────────────────────────
write_argo_service() {
    cat > "$ARGO_SERVICE" << EOF
[Unit]
Description=Cloudflare Argo Tunnel
After=network.target sing-box.service
Wants=sing-box.service

[Service]
Type=simple
User=nobody
Group=nogroup
ExecStart=/usr/local/bin/cloudflared tunnel --url http://127.0.0.1:${WS_PORT} --no-autoupdate --protocol http2
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# ─── 获取 Argo 域名 ──────────────────────────────────────────
fetch_argo_domain() {
    local max=10 i=0
    ARGO_DOMAIN=""
    while [[ $i -lt $max ]]; do
        ARGO_DOMAIN=$(journalctl -u argo-tunnel --output cat --no-pager 2>/dev/null | \
                      grep -oP 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' | \
                      tail -1 | sed 's|https://||')
        [[ -n "$ARGO_DOMAIN" ]] && return 0
        i=$((i + 1))
        sleep 3
    done
    return 1
}

# ─── Reality 优选 SNI ────────────────────────────────────────
select_reality_sni() {
    if [[ -n "${REALITY_SNI:-}" ]]; then
        info "当前已设定伪装域名: $REALITY_SNI，跳过测速"
        return
    fi
    info "正在并发测试 ${#REALITY_SNI_LIST[@]} 个候选伪装域名 (预计 1-2 秒完成)..."
    
    local tmp_dir
    tmp_dir=$(mktemp -d)
    
    # 采用后台并发执行，极大缩短等待时间
    for sni in "${REALITY_SNI_LIST[@]}"; do
        (
            local time_ms
            time_ms=$(curl -o /dev/null -s -w '%{time_connect}' --connect-timeout 2 "https://${sni}" 2>/dev/null || echo "9999")
            local ms
            ms=$(awk -v t="$time_ms" 'BEGIN {printf "%d", t * 1000}' 2>/dev/null || echo "9999")
            if [[ "$ms" -gt 0 && "$ms" -lt 9999 ]]; then
                echo "$ms $sni" >> "${tmp_dir}/results.txt"
            fi
        ) &
    done
    wait
    
    local best_sni="" best_time=9999
    if [[ -f "${tmp_dir}/results.txt" ]]; then
        local best
        best=$(sort -n "${tmp_dir}/results.txt" | head -1)
        best_time=$(echo "$best" | awk '{print $1}')
        best_sni=$(echo "$best" | awk '{print $2}')
    fi
    
    rm -rf "$tmp_dir"

    if [[ -n "$best_sni" ]]; then
        REALITY_SNI="$best_sni"
        success "优选伪装域名: ${REALITY_SNI} (延迟: ${best_time}ms)"
    else
        REALITY_SNI="${REALITY_SNI_LIST[0]}"
        warn "所有域名测速均失败，使用默认伪装域名: ${REALITY_SNI}"
    fi
}

# ─── URL 编码 ────────────────────────────────────────────────
urlencode() {
    python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1" 2>/dev/null || echo "$1"
}

# ─── 生成并显示链接 ──────────────────────────────────────────
generate_and_show_links() {
    get_public_ip

    echo ""
    echo -e "${PURPLE}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${PURPLE}${BOLD}║              📋 配置信息 & 分享链接                 ║${NC}"
    echo -e "${PURPLE}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""

    echo -e "${CYAN}${BOLD}── 基本信息 ──${NC}"
    echo -e "  服务器 IP:     ${BOLD}${PUBLIC_IP}${NC}"
    echo -e "  UUID:          ${BOLD}${UUID}${NC}"
    echo -e "  Reality 端口:  ${BOLD}${REALITY_PORT}${NC}"
    echo -e "  Reality SNI:   ${BOLD}${REALITY_SNI}${NC}"
    echo -e "  Public Key:    ${BOLD}${PUBLIC_KEY}${NC}"
    echo -e "  Short ID:      ${BOLD}${SHORT_ID}${NC}"
    [[ -n "${ARGO_DOMAIN:-}" ]] && echo -e "  Argo 域名:     ${BOLD}${ARGO_DOMAIN}${NC}"
    echo -e "  WS Path:       ${BOLD}${WS_PATH}${NC}"
    echo ""

    # ── VLESS + Reality ──
    local remark
    remark=$(urlencode "${NODE_NAME}-Reality")
    local REALITY_LINK="vless://${UUID}@${PUBLIC_IP}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${remark}"

    echo -e "${GREEN}${BOLD}── VLESS + Reality (直连) ──${NC}"
    echo -e "${YELLOW}${REALITY_LINK}${NC}"
    echo ""

    # ── VLESS + WS + Argo ──
    local ARGO_LINK=""
    if [[ -n "${ARGO_DOMAIN:-}" ]]; then
        local argo_remark ws_path_enc
        argo_remark=$(urlencode "${NODE_NAME}-Argo")
        ws_path_enc=$(urlencode "${WS_PATH}")
        ARGO_LINK="vless://${UUID}@${ARGO_DOMAIN}:443?encryption=none&security=tls&sni=${ARGO_DOMAIN}&type=ws&host=${ARGO_DOMAIN}&path=${ws_path_enc}#${argo_remark}"

        echo -e "${BLUE}${BOLD}── VLESS + WS + Argo (CDN) ──${NC}"
        echo -e "${YELLOW}${ARGO_LINK}${NC}"
        echo ""
    fi

    # ── 保存 ──
    {
        echo "# sing-box 分享链接 - $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        echo "# VLESS + Reality (直连)"
        echo "$REALITY_LINK"
        if [[ -n "$ARGO_LINK" ]]; then
            echo ""
            echo "# VLESS + WS + Argo (CDN)"
            echo "$ARGO_LINK"
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
    install_singbox
    install_cloudflared
    generate_params

    # 询问自定义参数
    echo ""
    echo -e "${CYAN}${BOLD}── 自定义配置 (直接回车使用默认值) ──${NC}"
    read -rp "  Reality 端口 [${REALITY_PORT}]: " input
    [[ -n "$input" ]] && REALITY_PORT="$input"

    read -rp "  伪装域名 (留空自动测速优选): " input
    [[ -n "$input" ]] && REALITY_SNI="$input"

    read -rp "  节点名称 [${NODE_NAME}]: " input
    [[ -n "$input" ]] && NODE_NAME="$input"
    echo ""

    # 自动优选伪装域名
    select_reality_sni

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

    echo ""
    echo -e "${GREEN}${BOLD}✅ 部署完成！复制上方链接导入 v2rayN / v2rayNG 即可使用。${NC}"
    press_enter
}

# ─── 修改配置 ────────────────────────────────────────────────
do_modify_config() {
    load_params || { warn "未找到配置，请先安装"; press_enter; return; }

    while true; do
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
        echo -e "  0) 返回主菜单"
        echo ""
        read -rp "  请选择 [0-6]: " choice

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
            0) return ;;
            *) continue ;;
        esac

        if [[ "$changed" == "true" ]]; then
            write_singbox_config
            write_argo_service
            save_params
            info "重启服务..."
            systemctl restart sing-box 2>/dev/null
            systemctl restart argo-tunnel 2>/dev/null
            sleep 5
            fetch_argo_domain 2>/dev/null || true
            save_params
            success "配置已更新并重启"
            generate_and_show_links
            press_enter
        fi
    done
}

# ─── 查看链接 ────────────────────────────────────────────────
do_show_links() {
    load_params || { warn "未找到配置，请先安装"; press_enter; return; }

    # 尝试刷新 Argo 域名
    if systemctl is-active --quiet argo-tunnel 2>/dev/null; then
        fetch_argo_domain 2>/dev/null || true
        save_params
    fi

    generate_and_show_links
    press_enter
}

# ─── 启动 / 停止 / 重启 ──────────────────────────────────────
do_start() {
    info "启动服务..."
    systemctl start sing-box 2>/dev/null && success "sing-box 已启动" || warn "sing-box 启动失败"
    systemctl start argo-tunnel 2>/dev/null && success "argo-tunnel 已启动" || warn "argo-tunnel 启动失败"
    press_enter
}

do_stop() {
    info "停止服务..."
    systemctl stop sing-box 2>/dev/null && success "sing-box 已停止" || warn "sing-box 停止失败"
    systemctl stop argo-tunnel 2>/dev/null && success "argo-tunnel 已停止" || warn "argo-tunnel 停止失败"
    press_enter
}

do_restart() {
    info "重启服务..."
    systemctl restart sing-box 2>/dev/null && success "sing-box 已重启" || warn "sing-box 重启失败"
    systemctl restart argo-tunnel 2>/dev/null && success "argo-tunnel 已重启" || warn "argo-tunnel 重启失败"

    sleep 5
    if load_params; then
        fetch_argo_domain 2>/dev/null || true
        save_params
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
    press_enter
}

# ─── 查看日志 ────────────────────────────────────────────────
do_logs() {
    echo ""
    echo -e "  1) sing-box 日志"
    echo -e "  2) argo-tunnel 日志"
    echo -e "  0) 返回"
    read -rp "  请选择: " choice
    case "$choice" in
        1) journalctl -u sing-box --output cat --no-pager -n 50 ;;
        2) journalctl -u argo-tunnel --output cat --no-pager -n 50 ;;
    esac
    press_enter
}

# ─── 开机自启设置 ──────────────────────────────────────────────
do_boot_manage() {
    echo ""
    echo -e "  1) 开启 sing-box & argo-tunnel 开机自启"
    echo -e "  2) 关闭 sing-box & argo-tunnel 开机自启"
    echo -e "  0) 返回"
    read -rp "  请选择: " choice
    case "$choice" in
        1)
            systemctl enable sing-box 2>/dev/null
            systemctl enable argo-tunnel 2>/dev/null
            success "已开启开机自启"
            ;;
        2)
            systemctl disable sing-box 2>/dev/null
            systemctl disable argo-tunnel 2>/dev/null
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
                # 兼容老用户的习惯，创建一个软链接
                ln -sf /usr/local/bin/sbm /usr/local/bin/sing-box-manager
                # 刷新当前 shell 的 hash 表，防止旧命令缓存失效
                hash -r 2>/dev/null || true
                success "脚本已更新至最新版本"
                info "正在重启服务以获取最新 Argo 节点链接..."
                systemctl restart sing-box 2>/dev/null
                systemctl restart argo-tunnel 2>/dev/null
                sleep 5
                if load_params; then
                    fetch_argo_domain 2>/dev/null || true
                    save_params
                    generate_and_show_links
                fi
                success "服务已重启，后续您可以直接输入 sbm 来呼出管理面板"
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
    rm -f "$ARGO_SERVICE"
    systemctl daemon-reload

    if command -v apt-get &>/dev/null; then
        apt-get remove -y sing-box 2>/dev/null || true
    elif command -v yum &>/dev/null; then
        yum remove -y sing-box 2>/dev/null || true
    fi

    rm -f /usr/local/bin/cloudflared
    rm -f /usr/local/bin/sbm
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
    links)       load_params && generate_and_show_links || warn "未安装" ;;
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
        echo "  links      显示分享链接"
        echo "  start      启动服务"
        echo "  stop       停止服务"
        echo "  restart    重启服务"
        echo "  status     查看状态"
        echo "  uninstall  卸载"
        exit 0
        ;;
    *)  main_menu ;;
esac
