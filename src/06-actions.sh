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
# 本机自检无法确认服务商防火墙、NAT 映射或线路封锁，交给外部 TCP 探测判断。
show_connectivity_guide() {
    menu_header "服务管理 / 公网连通性排查"
    load_params || { warn "未找到配置，请先安装"; return 1; }
    [[ -n "${PUBLIC_IPV4:-}${PUBLIC_IPV4_OVERRIDE:-}" ]] || refresh_public_ip_stack >/dev/null 2>&1 || true

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
    echo -e "  ${RED}全部红色${NC}      外部均无法连接：先执行「协议自检」，再检查安全组 / 防火墙 / NAT 面板映射"
    echo -e "  ${YELLOW}仅中国红色${NC}    端口疑似被封：在「协议设置 → Reality → 修改端口」更换端口后重新导入节点"
    echo ""
    echo -e "  ${DIM}Hysteria2 使用 UDP，不适用此 TCP 检测；Argo 经 Cloudflare 转发，无需检测端口。${NC}"
}

do_connectivity_guide() {
    show_connectivity_guide || true
    press_enter
}

# ─── 启动 / 停止 / 重启 ──────────────────────────────────────
do_start() {
    menu_header "服务管理 / 启动服务"
    info "启动服务..."
    local core_ready=true
    service_start sing-box && success "sing-box 已启动" || { core_ready=false; warn "sing-box 启动失败"; }
    if load_params; then
        # 临时隧道的域名检查会访问源站，订阅网关必须先就绪。
        local subscription_ready=true
        ensure_subscription_service_if_enabled || { subscription_ready=false; warn "订阅服务启动失败"; }
        if argo_enabled; then
            if [[ "$subscription_ready" == "true" && "$core_ready" == "true" ]]; then
                service_start argo-tunnel && success "argo-tunnel 已启动" || warn "argo-tunnel 启动失败"
                refresh_argo_domain_if_needed
            else
                warn "sing-box 或订阅网关未就绪，未启动 Argo 隧道"
            fi
        fi
        save_params
        build_share_links
        write_subscription_assets
    fi
    press_enter
}

do_stop() {
    menu_header "服务管理 / 停止服务"
    info "停止服务..."
    service_stop sing-box && success "sing-box 已停止" || warn "sing-box 停止失败"
    service_stop argo-tunnel && success "argo-tunnel 已停止" || warn "argo-tunnel 停止失败"
    service_stop sbm-subscription && success "订阅服务已停止" || warn "订阅服务停止失败"
    press_enter
}

do_restart() {
    menu_header "服务管理 / 重启服务"
    info "重启服务..."
    local core_ready=true
    service_restart sing-box && success "sing-box 已重启" || { core_ready=false; warn "sing-box 重启失败"; }
    if load_params; then
        local subscription_ready=true
        ensure_subscription_service_if_enabled || { subscription_ready=false; warn "订阅服务重启失败"; }
        if argo_enabled; then
            if [[ "$subscription_ready" == "true" && "$core_ready" == "true" ]]; then
                service_restart argo-tunnel && success "argo-tunnel 已重启" || warn "argo-tunnel 重启失败"
                if argo_quick_enabled; then
                    sleep 3
                    fetch_argo_domain || warn "Argo 已重启，但尚未取得新的临时域名"
                fi
            else
                warn "sing-box 或订阅网关未就绪，未重启 Argo 隧道"
            fi
        fi
        save_params
        build_share_links
        write_subscription_assets
        argo_enabled && [[ -n "${ARGO_DOMAIN:-}" ]] && info "Argo 域名: ${ARGO_DOMAIN}"
    fi
    press_enter
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
do_reoptimize_reality_sni() {
    menu_header "协议设置 / Reality / 优选伪装域名"
    if ! load_params; then
        warn "未安装，无法重新优选 Reality 伪装域名"
        return 1
    fi

    local old_sni="${REALITY_SNI:-}"
    local prev_sni="${REALITY_SNI_PREV:-}"
    local reality_service="sing-box"
    xray_managed_reality && reality_service="xray"
    info "当前 Reality 伪装域名: ${old_sni:-未设置}，开始重新优选（自动避开当前与上一次域名）..."

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
    if ! select_reality_sni; then
        REALITY_SNI="$old_sni"
        REALITY_SNI_EXCLUDE=""
        warn "未能优选到可用域名，已保留原伪装域名: ${old_sni:-未设置}"
        return 1
    fi
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

    info "新伪装域名: ${REALITY_SNI}，正在写入配置并重启 ${reality_service}..."
    if [[ "$reality_service" == "xray" ]]; then
        if ! write_xray_reality_sni "$REALITY_SNI"; then
            warn "Xray Reality 配置更新失败，已保留原伪装域名: ${old_sni}"
            REALITY_SNI="$old_sni"
            REALITY_SNI_PREV="$prev_sni"
            return 1
        fi
    else
        generate_tls_cert
        write_singbox_config
        write_singbox_service
    fi
    save_params

    if ! service_restart "$reality_service"; then
        warn "${reality_service} 重启失败，正在回滚到原伪装域名: ${old_sni}"
        REALITY_SNI="$old_sni"
        REALITY_SNI_PREV="$prev_sni"
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
    ensure_subscription_service_if_enabled || warn "订阅服务启动失败"
    refresh_argo_domain_if_needed
    generate_and_show_links
    show_subscription_url
    return 0
}

# ─── 应用当前版本配置 (一键同步) ─────────────────────────────
# 用当前已保存的凭证 (UUID / 端口 / 域名 / 密钥均不变) 按新版本模板
# 重写服务端配置并重启，再按新格式重新生成链接。适用于升级脚本后
# 让服务端配置与当前稳定链接格式同步生效。
do_apply_latest() {
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
    menu_header "服务管理 / 日志"
    menu_section "选择服务"
    menu_item 1 "sing-box 日志"
    menu_item 2 "argo-tunnel 日志"
    menu_item 3 "订阅服务日志"
    menu_back
    prompt_read choice "  请选择: " || return
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
    menu_header "服务管理 / 开机自启"
    menu_section "服务设置"
    menu_item 1 "开启" "sing-box 及已配置附加服务"
    menu_item 2 "关闭" "全部服务"
    menu_back
    prompt_read choice "  请选择: " || return
    [[ "$choice" == 0 ]] && return
    case "$choice" in
        1)
            service_enable sing-box 2>/dev/null || true
            load_params 2>/dev/null && argo_enabled && service_enable argo-tunnel 2>/dev/null || true
            load_params 2>/dev/null && argo_enabled && service_enable sbm-subscription 2>/dev/null || true
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

# ─── 更新组件 ────────────────────────────────────────────────
do_upgrade_singbox() {
    menu_header "系统维护 / 更新 sing-box"
    install_or_upgrade_singbox_package true || error "sing-box 更新失败。请检查网络、磁盘空间或 GitHub 访问"
    write_singbox_service
    service_restart sing-box 2>/dev/null || true
    success "sing-box 已更新并重启"
    press_enter
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
    # 仅刷新链接显示 (不重写配置、不重启)
    show_links || true
    echo ""
    prompt_read _ "按 Enter 重启面板并进入新版本..." || true
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
