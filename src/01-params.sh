# ─── 参数持久化 ──────────────────────────────────────────────
PARAM_KEYS=(
    UUID SHORT_ID PRIVATE_KEY PUBLIC_KEY REALITY_PORT REALITY_SNI REALITY_SNI_PREV REALITY_BACKEND WS_PORT WS_PATH NODE_NAME
    SUB_TOKEN SUBSCRIPTION_PORT ARGO_ENABLED ARGO_DOMAIN ARGO_TOKEN ARGO_BEST_CF_DOMAIN
    ARGO_BEST_CF_DOMAIN_IPV4 ARGO_BEST_CF_DOMAIN_IPV6 ARGO_CF_CACHE_DOMAIN ARGO_CF_CACHE_VERSION
    LINK_IPV4_SELECTION PUBLIC_IPV4_OVERRIDE
    HY2_PORT HY2_PASSWORD HY2_SNI HY2_MASQUERADE_URL HY2_ENABLED
    SOCKS_PORT SOCKS_USERNAME SOCKS_PASSWORD SOCKS_ENABLED
    NAT_MODE REALITY_PUBLIC_PORT HY2_PUBLIC_PORT SOCKS_PUBLIC_PORT
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
        if ! validate_port "${HY2_PUBLIC_PORT:-}" "NAT Hysteria2 公网映射" >/dev/null 2>&1; then
            HY2_PUBLIC_PORT="${HY2_PORT}"
            need_save=true
        fi
        if ! validate_port "${SOCKS_PUBLIC_PORT:-}" "NAT SOCKS5 公网映射" >/dev/null 2>&1; then
            SOCKS_PUBLIC_PORT="${SOCKS_PORT}"
            need_save=true
        fi
        [[ "$need_save" == "true" ]] && save_params
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
    HY2_PUBLIC_PORT="${24:-${HY2_PORT}}"
    ARGO_ENABLED="${25:-false}"
    HY2_ENABLED="${26:-false}"
    SOCKS_PORT="${27:-}"
    SOCKS_USERNAME="${28:-}"
    SOCKS_PASSWORD="${29:-}"
    SOCKS_ENABLED="${30:-false}"
    SOCKS_PUBLIC_PORT="${31:-${SOCKS_PORT}}"
    reset_public_ip_cache
}
