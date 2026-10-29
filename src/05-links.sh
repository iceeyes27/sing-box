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

reality_sni_is_approved() {
    local requested="${1:-}" candidate
    is_valid_hostname "$requested" || return 1
    for candidate in "${REALITY_SNI_LIST[@]}"; do
        [[ "$requested" == "$candidate" ]] && return 0
    done
    return 1
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

probe_reality_sni_candidate() {
    local idx="$1" sni="$2" result_file="$3" require_h2="${4:-1}"
    local out http_ver appconnect remote_ip ms
    local success_count=0 total_ms=0 max_ms=0 attempts=3
    # 用 HEAD(-I) 探测：仅取响应头即可拿到协议版本与握手耗时，不下载正文，
    # 对低带宽 / 低配 VPS 更省流量和时间(h2/ALPN 是连接级，与请求方法无关)。
    local curl_opts=(-I --tlsv1.3 --connect-timeout 2 --max-time 4)
    # 仅当本机 curl 支持 h2 时才协商 h2，否则该 flag 会让 curl 直接报错。
    (( require_h2 )) && curl_opts+=(--http2)

    for _ in $(seq 1 "$attempts"); do
        # 连续取样，优先选择成功率高且平均/最大握手延迟低的目标。
        out=$(curl --noproxy '*' -o /dev/null -s -w '%{http_version} %{time_appconnect} %{remote_ip}' \
            "${curl_opts[@]}" "https://${sni}" 2>/dev/null) || continue
        read -r http_ver appconnect remote_ip <<< "$out"

        if (( require_h2 )) && [[ "$http_ver" != "2" ]]; then
            continue
        fi
        [[ "$appconnect" =~ ^[0-9]+([.][0-9]+)?$ ]] || continue
        [[ -n "$remote_ip" ]] || continue
        is_cloudflare_address "$remote_ip" && continue
        ms=$(awk -v t="$appconnect" 'BEGIN {printf "%d", t * 1000}' 2>/dev/null || echo 0)
        [[ "$ms" =~ ^[0-9]+$ && "$ms" -gt 0 && "$ms" -lt 9999 ]] || continue
        success_count=$((success_count + 1))
        total_ms=$((total_ms + ms))
        if (( ms > max_ms )); then
            max_ms=$ms
        fi
    done

    (( success_count >= 2 )) || return 0
    echo "$idx $success_count $((total_ms / success_count)) $max_ms $sni" >> "$result_file"
    return 0
}

reality_sni_runtime_usable() {
    local sni="$1" tmp
    reality_sni_is_approved "$sni" || return 1
    ensure_reality_probe_dependencies || return 1
    tmp=$(mktemp) || return 1
    probe_reality_sni_candidate 0 "$sni" "$tmp" 1
    local result=1
    [[ -s "$tmp" ]] && result=0
    rm -f "$tmp"
    return "$result"
}

select_reality_sni() {
    if [[ -n "${REALITY_SNI:-}" ]]; then
        if ! reality_sni_is_approved "$REALITY_SNI"; then
            warn "Reality 伪装域名不在审核列表中: $REALITY_SNI"
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
    # 并发数为 1 时直接前台串行探测，避免在受限机器上 fork 后台任务。
    local active_jobs=0
    for idx in "${!REALITY_SNI_LIST[@]}"; do
        local sni="${REALITY_SNI_LIST[$idx]}"
        if (( probe_parallelism <= 1 )); then
            probe_reality_sni_candidate "$idx" "$sni" "${tmp_dir}/results.txt" 1
        else
            probe_reality_sni_candidate "$idx" "$sni" "${tmp_dir}/results.txt" 1 &
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
        echo -e "  Hysteria2 端口: ${BOLD}$(hy2_share_port)${NC}$(nat_mode_enabled && printf ' (本机监听 %s)' "$HY2_PORT")"
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
