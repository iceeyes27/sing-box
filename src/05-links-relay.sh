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
    append_reality_link "vless://${UUID}@${host}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${remark}"

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
        append_hy2_link "hysteria2://${hy2_pass_enc}@${host}:${HY2_PORT}?sni=${HY2_SNI}&pinSHA256=${hy2_pin_enc}#${hy2_remark}"
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
        echo -e "  ${DIM}提示: 当前 Hysteria2 链接已使用证书固定指纹 pinSHA256，无需再开启跳过证书验证。${NC}"
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

