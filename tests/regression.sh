#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/install.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local label="$3"
    [[ "$actual" == "$expected" ]] || fail "${label}: expected '${expected}', got '${actual}'"
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local label="$3"
    [[ "$haystack" == *"$needle"* ]] || fail "${label}: missing '${needle}'"
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local label="$3"
    [[ "$haystack" != *"$needle"* ]] || fail "${label}: unexpected '${needle}'"
}

make_cmd() {
    local path="$1"
    local body="$2"
    printf '%s\n' "$body" > "$path"
    chmod +x "$path"
}

bash -n "$SCRIPT"

export SBM_TEST_MODE=1
# shellcheck source=../install.sh
source "$SCRIPT"

test_service_manager_systemd() {
    local tmp result
    tmp=$(mktemp -d)
    make_cmd "${tmp}/systemctl" '#!/usr/bin/env bash
[[ "${1:-}" == "list-unit-files" ]] && exit 0
exit 0'
    PATH="${tmp}:$PATH" result=$(PATH="${tmp}:$PATH" service_manager)
    rm -rf "$tmp"
    assert_eq "systemd" "$result" "service_manager systemd detection"
}

test_service_manager_openrc() {
    local tmp result
    tmp=$(mktemp -d)
    make_cmd "${tmp}/systemctl" '#!/usr/bin/env bash
exit 1'
    make_cmd "${tmp}/rc-service" '#!/usr/bin/env bash
exit 0'
    PATH="${tmp}:$PATH" result=$(PATH="${tmp}:$PATH" service_manager)
    rm -rf "$tmp"
    assert_eq "openrc" "$result" "service_manager openrc detection"
}

test_package_manager_priority() {
    local tmp result
    tmp=$(mktemp -d)
    make_cmd "${tmp}/apt-get" '#!/usr/bin/env bash
exit 0'
    make_cmd "${tmp}/dnf" '#!/usr/bin/env bash
exit 0'
    make_cmd "${tmp}/yum" '#!/usr/bin/env bash
exit 0'
    make_cmd "${tmp}/apk" '#!/usr/bin/env bash
exit 0'
    result=$(PATH="${tmp}:$PATH" package_manager)
    rm -rf "$tmp"
    assert_eq "apt" "$result" "package_manager priority"
}

test_package_manager_alpine() {
    local tmp result
    tmp=$(mktemp -d)
    make_cmd "${tmp}/apk" '#!/usr/bin/env bash
exit 0'
    result=$(PATH="${tmp}" package_manager)
    rm -rf "$tmp"
    assert_eq "apk" "$result" "package_manager Alpine detection"
}

test_legacy_params_migration() {
    local tmp
    tmp=$(mktemp -d)
    PARAMS_FILE="${tmp}/params"
    CONFIG_DIR="$tmp"
    openssl() {
        case "$*" in
            "rand -base64 16") echo "legacy-hy2-password" ;;
            "rand -hex 16") echo "legacy-sub-token" ;;
            *) return 1 ;;
        esac
    }
    cat > "$PARAMS_FILE" <<'EOF'
UUID="uuid-1"
SHORT_ID="abcd1234"
PRIVATE_KEY="private"
PUBLIC_KEY="public"
REALITY_PORT="443"
REALITY_SNI="www.microsoft.com"
WS_PORT="18080"
WS_PATH="/abcd1234"
NODE_NAME="node"
ARGO_DOMAIN="argo.example.com"
ARGO_TOKEN=""
ARGO_BEST_CF_DOMAIN="cf.example.com"
EOF
    load_params
    assert_eq "8443" "$HY2_PORT" "legacy HY2_PORT migration"
    assert_eq "legacy-hy2-password" "$HY2_PASSWORD" "legacy HY2 password migration"
    assert_eq "https://www.bing.com" "$HY2_MASQUERADE_URL" "legacy HY2 masquerade migration"
    assert_eq "legacy-sub-token" "$SUB_TOKEN" "legacy subscription token migration"
    assert_eq "24630" "$SUBSCRIPTION_PORT" "legacy subscription port migration"
    assert_eq "cf.example.com" "$ARGO_BEST_CF_DOMAIN_IPV4" "legacy Argo IPv4 cache migration"
    assert_eq "" "$PUBLIC_IPV4_OVERRIDE" "legacy public IPv4 override migration"
    rm -rf "$tmp"
}

test_params_parser_is_safe_and_round_trips() {
    local tmp marker
    tmp=$(mktemp -d)
    PARAMS_FILE="${tmp}/params"
    CONFIG_DIR="$tmp"
    marker="${tmp}/executed"

    cat > "$PARAMS_FILE" <<EOF
UUID="uuid old"
SHORT_ID='sid old'
PRIVATE_KEY=private\\ value
PUBLIC_KEY=public
REALITY_PORT=443
REALITY_SNI=www.microsoft.com
WS_PORT=18080
WS_PATH=/old
NODE_NAME=\$(touch "$marker")
UNEXPECTED=value
ARGO_TOKEN=token\;touch "$marker"
EOF

    load_params
    [[ ! -e "$marker" ]] || fail "params parser executed file content"
    assert_eq '$(touch "'${marker}'")' "$NODE_NAME" "params command substitution is literal"
    assert_eq 'token\;touch "'${marker}'"' "$ARGO_TOKEN" "params semicolon is literal"

    UUID='uuid "quoted"'
    SHORT_ID="sid\\backslash"
    PRIVATE_KEY="private key"
    PUBLIC_KEY="public key"
    REALITY_PORT="443"
    REALITY_SNI="www.microsoft.com"
    WS_PORT="18080"
    WS_PATH='/path with spaces'
    NODE_NAME='node # one'
    SUB_TOKEN='sub token $value'
    SUBSCRIPTION_PORT="24630"
    ARGO_DOMAIN="argo.example.com"
    ARGO_TOKEN='argo token `literal`'
    ARGO_BEST_CF_DOMAIN="cf.example.com"
    ARGO_BEST_CF_DOMAIN_IPV4="cf4.example.com"
    ARGO_BEST_CF_DOMAIN_IPV6="cf6.example.com"
    LINK_IPV4_SELECTION="all"
    HY2_PORT="8443"
    HY2_PASSWORD='hy2 pass "quoted"'
    HY2_SNI="bing.com"
    HY2_MASQUERADE_URL="https://www.bing.com/a b"
    PUBLIC_IPV4_OVERRIDE="198.51.100.99"
    save_params

    UUID=""; SHORT_ID=""; PRIVATE_KEY=""; PUBLIC_KEY=""; REALITY_PORT=""; REALITY_SNI=""
    WS_PORT=""; WS_PATH=""; NODE_NAME=""; SUB_TOKEN=""; SUBSCRIPTION_PORT=""
    ARGO_DOMAIN=""; ARGO_TOKEN=""; ARGO_BEST_CF_DOMAIN=""; ARGO_BEST_CF_DOMAIN_IPV4=""
    ARGO_BEST_CF_DOMAIN_IPV6=""; LINK_IPV4_SELECTION=""; PUBLIC_IPV4_OVERRIDE=""
    HY2_PORT=""; HY2_PASSWORD=""; HY2_SNI=""; HY2_MASQUERADE_URL=""

    load_params
    assert_eq 'uuid "quoted"' "$UUID" "params UUID round trip"
    assert_eq 'sid\backslash' "$SHORT_ID" "params short id round trip"
    assert_eq '/path with spaces' "$WS_PATH" "params WS path round trip"
    assert_eq 'node # one' "$NODE_NAME" "params node name round trip"
    assert_eq 'sub token $value' "$SUB_TOKEN" "params token round trip"
    assert_eq 'argo token `literal`' "$ARGO_TOKEN" "params argo token round trip"
    assert_eq '198.51.100.99' "$PUBLIC_IPV4_OVERRIDE" "params public IPv4 override round trip"
    assert_eq 'hy2 pass "quoted"' "$HY2_PASSWORD" "params HY2 password round trip"

    rm -rf "$tmp"
}

test_params_cjk_and_legacy_ansi_c_round_trip() {
    local tmp
    tmp=$(mktemp -d)
    PARAMS_FILE="${tmp}/params"
    CONFIG_DIR="$tmp"

    # 旧版本 printf %q 会把非 ASCII 值写成 $'...' 八进制形式，
    # 解析端必须能还原(否则升级后中文节点名变成字面 $'\346...' 乱码)。
    cat > "$PARAMS_FILE" <<'EOF'
UUID=plain-uuid
NODE_NAME=$'\346\210\221\347\232\204 \350\212\202\347\202\271'
REALITY_SNI=www.microsoft.com
EOF
    NODE_NAME=""
    load_params
    assert_eq '我的 节点' "$NODE_NAME" "legacy ANSI-C quoted CJK node name decodes"

    # 中文 + 空格节点名 save/load 必须逐字还原
    UUID="uuid"; SHORT_ID="sid"; PRIVATE_KEY="pk"; PUBLIC_KEY="pub"
    REALITY_PORT="443"; REALITY_SNI="www.microsoft.com"; REALITY_SNI_PREV=""
    WS_PORT="18080"; WS_PATH="/p"; NODE_NAME="香港 VPS-01 节点"
    SUB_TOKEN="tok"; SUBSCRIPTION_PORT="24630"
    ARGO_DOMAIN=""; ARGO_TOKEN=""; ARGO_BEST_CF_DOMAIN=""
    ARGO_BEST_CF_DOMAIN_IPV4=""; ARGO_BEST_CF_DOMAIN_IPV6=""
    LINK_IPV4_SELECTION="all"; PUBLIC_IPV4_OVERRIDE=""
    HY2_PORT="8443"; HY2_PASSWORD="pw"; HY2_SNI="bing.com"
    HY2_MASQUERADE_URL="https://www.bing.com"
    save_params
    NODE_NAME=""
    load_params
    assert_eq '香港 VPS-01 节点' "$NODE_NAME" "CJK node name round trip"

    rm -rf "$tmp"
}

test_probe_available_cf_domains_keeps_order() {
    local result parallelism_def
    local -a cf_domains_backup=("${CF_DOMAINS[@]}")

    CF_DOMAINS=("cf1.example.com" "cf2.example.com" "cf3.example.com")
    curl() {
        local url
        for url in "$@"; do :; done
        case "$url" in
            *cf1*|*cf3*) return 0 ;;
            *) return 1 ;;
        esac
    }

    result=$(probe_available_cf_domains "")
    assert_eq $'cf1.example.com\ncf3.example.com' "$result" "parallel CF probe filters and keeps order"

    # 低配路径:并发度 1 时走串行探测，结果必须一致
    parallelism_def=$(declare -f get_reality_probe_parallelism)
    get_reality_probe_parallelism() { echo 1; }
    result=$(probe_available_cf_domains "")
    assert_eq $'cf1.example.com\ncf3.example.com' "$result" "serial CF probe filters and keeps order"

    unset -f curl get_reality_probe_parallelism
    eval "$parallelism_def"
    CF_DOMAINS=("${cf_domains_backup[@]}")
}

test_wait_for_service_active_polls_until_ready() {
    local tmp active_def
    tmp=$(mktemp -d)
    active_def=$(declare -f service_is_active)

    SBM_TEST_ACTIVE_COUNT_FILE="${tmp}/count"
    service_is_active() {
        local count=0
        [[ -f "$SBM_TEST_ACTIVE_COUNT_FILE" ]] && count=$(<"$SBM_TEST_ACTIVE_COUNT_FILE")
        count=$((count + 1))
        printf '%s' "$count" > "$SBM_TEST_ACTIVE_COUNT_FILE"
        (( count >= 3 ))
    }
    wait_for_service_active dummy 5 || fail "wait_for_service_active should succeed once service becomes active"
    assert_eq "3" "$(<"$SBM_TEST_ACTIVE_COUNT_FILE")" "service polled until active"

    service_is_active() { return 1; }
    if wait_for_service_active dummy 1; then
        fail "wait_for_service_active should fail when service never activates"
    fi

    unset -f service_is_active
    eval "$active_def"
    unset SBM_TEST_ACTIVE_COUNT_FILE
    rm -rf "$tmp"
}

test_hysteria2_bandwidth_is_optional() {
    local tmp config chown_def
    tmp=$(mktemp -d)

    chown_def=$(declare -f chown 2>/dev/null || true)
    chown() { return 0; }
    sing-box() {
        [[ "${1:-}" == "check" ]] && return 0
        return 1
    }
    CONFIG_DIR="$tmp"
    CONFIG_FILE="${tmp}/config.json"
    UUID="uuid-1"
    REALITY_PORT="443"
    REALITY_SNI="www.microsoft.com"
    PRIVATE_KEY="private"
    SHORT_ID="abcd1234"
    WS_PORT="18080"
    WS_PATH="/abcd1234"
    HY2_PORT="443"
    HY2_PASSWORD="hy2-password"
    HY2_SNI="bing.com"
    HY2_MASQUERADE_URL="https://www.bing.com"

    HY2_UP_MBPS=""
    HY2_DOWN_MBPS=""
    write_singbox_config >/dev/null
    config=$(<"$CONFIG_FILE")
    assert_not_contains "$config" '"up_mbps"' "HY2 defaults to no bandwidth cap (BBR)"
    assert_not_contains "$config" '"down_mbps"' "HY2 defaults to no down cap"

    HY2_UP_MBPS="50"
    HY2_DOWN_MBPS="200"
    write_singbox_config >/dev/null
    config=$(<"$CONFIG_FILE")
    assert_contains "$config" '"up_mbps": 50,' "HY2 up_mbps applied"
    assert_contains "$config" '"down_mbps": 200,' "HY2 down_mbps applied"

    HY2_UP_MBPS=""
    HY2_DOWN_MBPS=""
    unset -f chown sing-box
    [[ -n "$chown_def" ]] && eval "$chown_def"
    rm -rf "$tmp"
}

test_hop_range_validation() {
    validate_hop_range "20000:40000" || fail "valid range rejected"
    validate_hop_range "1:65535" || fail "boundary range rejected"
    validate_hop_range "40000:20000" && fail "reversed range accepted"
    validate_hop_range "20000" && fail "single port accepted as range"
    validate_hop_range "0:100" && fail "port 0 accepted"
    validate_hop_range "100:70000" && fail "out-of-range end accepted"
    validate_hop_range "" && fail "empty range accepted"
    validate_hop_range "abc:def" && fail "non-numeric accepted"
    return 0
}

test_hy2_mport_suffix_reflects_hop_range() {
    HY2_HOP_RANGE="20000:40000"
    assert_eq "&mport=20000-40000" "$(hy2_mport_suffix)" "mport suffix built from enabled range"
    HY2_HOP_RANGE=""
    assert_eq "" "$(hy2_mport_suffix)" "mport suffix empty when disabled"
    HY2_HOP_RANGE="bad"
    assert_eq "" "$(hy2_mport_suffix)" "mport suffix empty for invalid range"
    HY2_HOP_RANGE=""
    return 0
}

test_apply_and_remove_hy2_port_hopping() {
    local tmp log
    tmp=$(mktemp -d)
    log="${tmp}/ipt.log"
    make_cmd "${tmp}/iptables" "#!/usr/bin/env bash
printf '%s\n' \"\$*\" >> '${log}'
# -C 探测规则是否存在:返回不存在使 -A 分支执行
[[ \" \$* \" == *' -C '* ]] && exit 1
exit 0"
    make_cmd "${tmp}/ip6tables" "#!/usr/bin/env bash
printf 'v6 %s\n' \"\$*\" >> '${log}'
[[ \" \$* \" == *' -C '* ]] && exit 1
exit 0"
    make_cmd "${tmp}/iptables-save" '#!/usr/bin/env bash
exit 0'
    make_cmd "${tmp}/netfilter-persistent" '#!/usr/bin/env bash
[[ "${1:-}" == "save" ]] && exit 0
exit 1'

    CONFIG_DIR="$tmp"
    HY2_PORT="443"
    HY2_HOP_RANGE="20000:40000"
    PATH="${tmp}:$PATH" apply_hy2_port_hopping >/dev/null 2>&1 || fail "apply_hy2_port_hopping failed"

    local rules; rules=$(<"$log")
    assert_contains "$rules" "-t nat -A PREROUTING -p udp --dport 20000:40000 -j DNAT --to-destination :443" "v4 DNAT rule added"
    assert_contains "$rules" "v6 -t nat -A PREROUTING -p udp --dport 20000:40000 -j DNAT --to-destination :443" "v6 DNAT rule added"
    [[ -f "${tmp}/hy2-hop.state" ]] || fail "state file not written"
    assert_eq "20000:40000" "$(sed -n '1p' "${tmp}/hy2-hop.state")" "state records range"
    assert_eq "443" "$(sed -n '2p' "${tmp}/hy2-hop.state")" "state records target port"

    : > "$log"
    PATH="${tmp}:$PATH" remove_hy2_port_hopping >/dev/null 2>&1 || fail "remove_hy2_port_hopping failed"
    rules=$(<"$log")
    assert_contains "$rules" "-t nat -D PREROUTING -p udp --dport 20000:40000 -j DNAT --to-destination :443" "v4 DNAT rule deleted with recorded values"
    [[ -f "${tmp}/hy2-hop.state" ]] && fail "state file not cleaned up"

    HY2_HOP_RANGE=""
    rm -rf "$tmp"
}

test_persist_iptables_rules_uses_netfilter_persistent() {
    local tmp
    tmp=$(mktemp -d)
    make_cmd "${tmp}/iptables-save" '#!/usr/bin/env bash
exit 0'
    make_cmd "${tmp}/netfilter-persistent" '#!/usr/bin/env bash
[[ "${1:-}" == "save" ]] && exit 0
exit 1'
    PATH="${tmp}:$PATH" persist_iptables_rules || fail "netfilter-persistent save should persist rules"

    if PATH="${tmp}-missing" persist_iptables_rules 2>/dev/null; then
        fail "persist_iptables_rules should fail without iptables-save"
    fi
    rm -rf "$tmp"
}

test_apply_install_env_overrides_sets_values() {
    REALITY_PORT="443"; HY2_PORT="8443"; SUBSCRIPTION_PORT="24630"
    REALITY_SNI=""; NODE_NAME="sing-box-vps"
    ARGO_TOKEN=""; ARGO_DOMAIN=""; PUBLIC_IPV4_OVERRIDE=""

    SBM_REALITY_PORT="9443"
    SBM_HY2_PORT="9444"
    SBM_SUBSCRIPTION_PORT="24631"
    SBM_REALITY_SNI="www.apple.com"
    SBM_NODE_NAME="hk-01"
    SBM_PUBLIC_IPV4="198.51.100.10"
    SBM_ARGO_TOKEN="eyJtoken"
    SBM_ARGO_DOMAIN="https://v2.example.com/"
    SBM_HY2_UP_MBPS="30"
    SBM_HY2_DOWN_MBPS="300"
    HY2_UP_MBPS=""; HY2_DOWN_MBPS=""
    apply_install_env_overrides

    assert_eq "9443" "$REALITY_PORT" "env override Reality port"
    assert_eq "9444" "$HY2_PORT" "env override HY2 port"
    assert_eq "24631" "$SUBSCRIPTION_PORT" "env override subscription port"
    assert_eq "www.apple.com" "$REALITY_SNI" "env override Reality SNI"
    assert_eq "hk-01" "$NODE_NAME" "env override node name"
    assert_eq "198.51.100.10" "$PUBLIC_IPV4_OVERRIDE" "env override public IPv4"
    assert_eq "eyJtoken" "$ARGO_TOKEN" "env override Argo token"
    assert_eq "v2.example.com" "$ARGO_DOMAIN" "env override Argo domain normalized"
    assert_eq "30" "$HY2_UP_MBPS" "env override HY2 up mbps"
    assert_eq "300" "$HY2_DOWN_MBPS" "env override HY2 down mbps"

    unset SBM_REALITY_PORT SBM_HY2_PORT SBM_SUBSCRIPTION_PORT SBM_REALITY_SNI
    unset SBM_NODE_NAME SBM_PUBLIC_IPV4 SBM_ARGO_TOKEN SBM_ARGO_DOMAIN
    unset SBM_HY2_UP_MBPS SBM_HY2_DOWN_MBPS
    HY2_UP_MBPS=""; HY2_DOWN_MBPS=""
}

test_apply_install_env_overrides_rejects_invalid_values() {
    PUBLIC_IPV4_OVERRIDE=""; ARGO_TOKEN=""; ARGO_DOMAIN=""

    SBM_PUBLIC_IPV4="192.168.1.5"
    SBM_ARGO_TOKEN="eyJonly"
    SBM_HY2_UP_MBPS="abc"
    SBM_HY2_DOWN_MBPS="100"
    HY2_UP_MBPS=""; HY2_DOWN_MBPS=""
    apply_install_env_overrides

    assert_eq "" "$PUBLIC_IPV4_OVERRIDE" "private IPv4 env override ignored"
    assert_eq "" "$ARGO_TOKEN" "Argo token without domain ignored"
    assert_eq "" "$ARGO_DOMAIN" "Argo domain stays empty without pair"
    assert_eq "" "$HY2_UP_MBPS" "non-numeric HY2 bandwidth ignored"
    assert_eq "" "$HY2_DOWN_MBPS" "paired HY2 bandwidth ignored when invalid"

    unset SBM_PUBLIC_IPV4 SBM_ARGO_TOKEN SBM_HY2_UP_MBPS SBM_HY2_DOWN_MBPS
}

test_fetch_public_ip_parallel_prefers_endpoint_order() {
    local result

    curl() {
        local url
        for url in "$@"; do :; done
        case "$url" in
            *ifconfig.me*) printf '198.51.100.10' ;;
            *api.ipify.org*) printf '203.0.113.20' ;;
            *) return 1 ;;
        esac
    }
    result=$(fetch_public_ipv4)
    assert_eq "198.51.100.10" "$result" "parallel IPv4 fetch prefers first endpoint"

    curl() {
        local url
        for url in "$@"; do :; done
        case "$url" in
            *api6.ipify.org*) printf '2001:db8::1' ;;
            *) printf 'not-an-ip' ;;
        esac
    }
    result=$(fetch_public_ipv6)
    assert_eq "2001:db8::1" "$result" "parallel IPv6 fetch validates result"

    curl() { return 1; }
    if fetch_public_ipv4 >/dev/null; then
        fail "IPv4 fetch should fail when all endpoints fail"
    fi

    unset -f curl
}

test_ipv4_public_link_validation() {
    is_valid_public_ipv4_for_link "198.51.100.10" || fail "valid public IPv4 was rejected"
    if is_valid_public_ipv4_for_link "999.1.1.1"; then fail "out-of-range IPv4 accepted"; fi
    if is_valid_public_ipv4_for_link "192.168.1.1"; then fail "private IPv4 accepted"; fi
    if is_valid_public_ipv4_for_link "100.64.1.1"; then fail "CGNAT IPv4 accepted"; fi
    if is_valid_public_ipv4_for_link "127.0.0.1"; then fail "loopback IPv4 accepted"; fi
    if is_valid_public_ipv4_for_link "224.0.0.1"; then fail "multicast IPv4 accepted"; fi
}

test_ipv4_override_takes_priority() {
    PUBLIC_IPV4_OVERRIDE="198.51.100.88"
    PUBLIC_IPV4=""
    PUBLIC_IPV4_LIST=""
    PUBLIC_IP=""
    PUBLIC_IPV6=""
    IP_STACK_MODE=""
    fetch_public_ipv4() {
        echo "203.0.113.20"
    }
    fetch_public_ipv6() {
        return 1
    }

    refresh_public_ip_stack
    assert_eq "198.51.100.88" "$PUBLIC_IPV4" "override PUBLIC_IPV4"
    assert_eq "198.51.100.88" "$PUBLIC_IPV4_LIST" "override PUBLIC_IPV4_LIST"
    assert_eq "198.51.100.88" "$PUBLIC_IP" "override PUBLIC_IP"
    assert_eq "ipv4-only" "$IP_STACK_MODE" "override IP stack mode"
}

test_ipv4_override_generates_direct_links() {
    local hy2_available_def hy2_pin_def
    UUID="uuid-1"
    NODE_NAME="node"
    REALITY_PORT="443"
    REALITY_SNI="www.microsoft.com"
    PUBLIC_KEY="public"
    SHORT_ID="abcd1234"
    WS_PATH="/abcd1234"
    HY2_PORT="443"
    HY2_PASSWORD="hy2"
    HY2_SNI="bing.com"
    ARGO_DOMAIN=""
    ARGO_TOKEN=""
    ARGO_BEST_CF_DOMAIN=""
    PUBLIC_IPV4_OVERRIDE="198.51.100.88"
    LINK_IPV4_SELECTION="all"

    fetch_public_ipv6() {
        return 1
    }
    urlencode() {
        echo "$1"
    }
    hy2_available_def=$(declare -f hy2_share_link_available)
    hy2_pin_def=$(declare -f get_hy2_cert_pin_sha256)
    hy2_share_link_available() { return 0; }
    get_hy2_cert_pin_sha256() { printf 'ab12'; }

    build_share_links >/dev/null
    assert_contains "$GENERATED_REALITY_LINKS" "vless://uuid-1@198.51.100.88:443" "override Reality link"
    assert_contains "$GENERATED_HY2_LINKS" "hysteria2://hy2@198.51.100.88:443" "override Hysteria2 link"

    unset -f hy2_share_link_available get_hy2_cert_pin_sha256
    eval "$hy2_available_def"
    eval "$hy2_pin_def"
}

test_ip_detection_failure_keeps_argo_link_generation() {
    UUID="uuid-1"
    NODE_NAME="node"
    REALITY_PORT="443"
    REALITY_SNI="www.microsoft.com"
    PUBLIC_KEY="public"
    SHORT_ID="abcd1234"
    WS_PATH="/abcd1234"
    HY2_PORT="443"
    HY2_PASSWORD="hy2"
    HY2_SNI="bing.com"
    ARGO_DOMAIN="argo.example.com"
    ARGO_TOKEN=""
    ARGO_BEST_CF_DOMAIN="cf.example.com"
    PUBLIC_IPV4_OVERRIDE=""

    refresh_public_ip_stack() {
        return 1
    }
    resolve_argo_best_cf_domain() {
        ARGO_BEST_CF_DOMAIN="cf.example.com"
    }
    urlencode() {
        echo "$1"
    }

    build_share_links >/dev/null
    assert_eq "unknown" "$IP_STACK_MODE" "IP detection failure stack mode"
    assert_not_contains "$GENERATED_REALITY_LINKS" "vless://" "no direct links after IP failure"
    assert_contains "$GENERATED_ARGO_LINKS" "vless://uuid-1@cf.example.com:443" "Argo link after IP failure"
}

test_ipv6_only_links_are_argo_only() {
    UUID="uuid-1"
    NODE_NAME="node"
    REALITY_PORT="443"
    REALITY_SNI="www.microsoft.com"
    PUBLIC_KEY="public"
    SHORT_ID="abcd1234"
    WS_PATH="/abcd1234"
    HY2_PORT="443"
    HY2_PASSWORD="hy2"
    HY2_SNI="bing.com"
    ARGO_DOMAIN="argo.example.com"
    ARGO_BEST_CF_DOMAIN="cf.example.com"

    refresh_public_ip_stack() {
        IP_STACK_MODE="ipv6-only"
        PUBLIC_IP="2001:db8::1"
        PUBLIC_IPV4=""
        PUBLIC_IPV6="2001:db8::1"
    }
    resolve_argo_best_cf_domain() {
        ARGO_BEST_CF_DOMAIN="cf.example.com"
    }
    urlencode() {
        echo "$1"
    }

    build_share_links >/dev/null
    assert_contains "$GENERATED_ARGO_LINKS" "vless://uuid-1@cf.example.com:443" "IPv6-only Argo link"
    assert_not_contains "$GENERATED_REALITY_LINKS" "vless://" "IPv6-only Reality suppression"
    assert_not_contains "$GENERATED_HY2_LINKS" "hysteria2://" "IPv6-only Hysteria2 suppression"
}

test_multiple_ipv4_direct_links_follow_selection() {
    UUID="uuid-1"
    NODE_NAME="node"
    REALITY_PORT="443"
    REALITY_SNI="www.microsoft.com"
    PUBLIC_KEY="public"
    SHORT_ID="abcd1234"
    WS_PATH="/abcd1234"
    ARGO_DOMAIN=""
    ARGO_TOKEN=""
    ARGO_BEST_CF_DOMAIN=""

    refresh_public_ip_stack() {
        IP_STACK_MODE="ipv4-only"
        PUBLIC_IP="198.51.100.10"
        PUBLIC_IPV4="198.51.100.10"
        PUBLIC_IPV4_LIST=$'198.51.100.10\n203.0.113.20'
        PUBLIC_IPV6=""
    }
    urlencode() {
        echo "$1"
    }

    LINK_IPV4_SELECTION="all"
    build_share_links >/dev/null
    assert_contains "$GENERATED_REALITY_LINKS" "vless://uuid-1@198.51.100.10:443" "first IPv4 direct link"
    assert_contains "$GENERATED_REALITY_LINKS" "vless://uuid-1@203.0.113.20:443" "second IPv4 direct link"

    LINK_IPV4_SELECTION="203.0.113.20"
    build_share_links >/dev/null
    assert_not_contains "$GENERATED_REALITY_LINKS" "vless://uuid-1@198.51.100.10:443" "unselected IPv4 direct link"
    assert_contains "$GENERATED_REALITY_LINKS" "vless://uuid-1@203.0.113.20:443" "selected IPv4 direct link"
}

test_single_ipv4_falls_back_without_candidate_list() {
    UUID="uuid-1"
    NODE_NAME="node"
    REALITY_PORT="443"
    REALITY_SNI="www.microsoft.com"
    PUBLIC_KEY="public"
    SHORT_ID="abcd1234"
    ARGO_DOMAIN=""
    ARGO_TOKEN=""
    ARGO_BEST_CF_DOMAIN=""

    refresh_public_ip_stack() {
        IP_STACK_MODE="ipv4-only"
        PUBLIC_IP="198.51.100.10"
        PUBLIC_IPV4="198.51.100.10"
        PUBLIC_IPV4_LIST=""
        PUBLIC_IPV6=""
    }
    urlencode() {
        echo "$1"
    }

    LINK_IPV4_SELECTION="all"
    build_share_links >/dev/null
    assert_contains "$GENERATED_REALITY_LINKS" "vless://uuid-1@198.51.100.10:443" "single IPv4 fallback direct link"
}

test_rtc_epoch_uses_timedatectl_without_hwclock() {
    local tmp result
    tmp=$(mktemp -d)
    make_cmd "${tmp}/hwclock" '#!/usr/bin/env bash
exit 1'
    make_cmd "${tmp}/date" '#!/usr/bin/env bash
if [[ "$*" == "-u -d 2026-05-27 02:00:03 UTC +%s" ]]; then
    echo 1779847203
    exit 0
fi
exec /bin/date "$@"'
    make_cmd "${tmp}/timedatectl" '#!/usr/bin/env bash
cat <<'"'"'EOF'"'"'
               Local time: Wed 2026-05-27 10:00:03 CST
           Universal time: Wed 2026-05-27 02:00:03 UTC
                 RTC time: Wed 2026-05-27 02:00:03
                Time zone: Asia/Shanghai (CST, +0800)
System clock synchronized: yes
              NTP service: active
          RTC in local TZ: no
EOF'

    result=$(PATH="${tmp}:/usr/bin:/bin" get_rtc_utc_epoch)
    rm -rf "$tmp"
    assert_eq "1779847203" "$result" "timedatectl RTC epoch fallback"
}

test_busybox_ntpd_can_step_system_time() {
    local tmp log
    tmp=$(mktemp -d)
    log="${tmp}/ntpd.log"
    make_cmd "${tmp}/ntpd" '#!/usr/bin/env bash
printf '\''%s\n'\'' "$*" >> "${NTPD_LOG}"
[[ "$*" == *"-d -n -q -p time.cloudflare.com"* ]]'

    PATH="${tmp}:/usr/bin:/bin" NTPD_LOG="$log" step_system_time_with_ntp
    assert_contains "$(<"$log")" "-d -n -q -p time.cloudflare.com" "BusyBox ntpd one-shot step"
    rm -rf "$tmp"
}

test_runtime_param_restore_is_complete() {
    UUID="uuid-old"
    SHORT_ID="sid-old"
    PRIVATE_KEY="private-old"
    PUBLIC_KEY="public-old"
    REALITY_PORT="443"
    REALITY_SNI="www.microsoft.com"
    REALITY_SNI_PREV="www.apple.com"
    WS_PORT="18080"
    WS_PATH="/sid-old"
    NODE_NAME="node-old"
    HY2_PORT="8443"
    HY2_PASSWORD="hy2-old"
    HY2_SNI="bing.com"
    HY2_MASQUERADE_URL="https://www.bing.com"
    SUB_TOKEN="sub-old"
    SUBSCRIPTION_PORT="24630"
    ARGO_DOMAIN="argo.old.example.com"
    ARGO_TOKEN="token-old"
    ARGO_BEST_CF_DOMAIN="cf-old.example.com"
    ARGO_BEST_CF_DOMAIN_IPV4="cf4-old.example.com"
    ARGO_BEST_CF_DOMAIN_IPV6="cf6-old.example.com"
    LINK_IPV4_SELECTION="all"
    PUBLIC_IPV4_OVERRIDE="198.51.100.77"
    snapshot_runtime_params

    UUID="uuid-new"
    SHORT_ID="sid-new"
    PRIVATE_KEY="private-new"
    PUBLIC_KEY="public-new"
    REALITY_PORT="444"
    REALITY_SNI="www.apple.com"
    WS_PORT="18081"
    WS_PATH="/sid-new"
    NODE_NAME="node-new"
    HY2_PORT="8444"
    HY2_PASSWORD="hy2-new"
    HY2_SNI="example.com"
    HY2_MASQUERADE_URL="https://example.com"
    SUBSCRIPTION_PORT="24631"
    ARGO_DOMAIN="argo.new.example.com"
    ARGO_TOKEN="token-new"
    ARGO_BEST_CF_DOMAIN="cf-new.example.com"
    ARGO_BEST_CF_DOMAIN_IPV4="cf4-new.example.com"
    ARGO_BEST_CF_DOMAIN_IPV6="cf6-new.example.com"
    LINK_IPV4_SELECTION="203.0.113.20"
    REALITY_SNI_PREV="www.dell.com"
    SUB_TOKEN="sub-new"
    PUBLIC_IPV4_OVERRIDE="203.0.113.99"

    restore_runtime_params

    assert_eq "uuid-old" "$UUID" "restore UUID"
    assert_eq "sid-old" "$SHORT_ID" "restore Short ID"
    assert_eq "private-old" "$PRIVATE_KEY" "restore private key"
    assert_eq "public-old" "$PUBLIC_KEY" "restore public key"
    assert_eq "443" "$REALITY_PORT" "restore Reality port"
    assert_eq "www.microsoft.com" "$REALITY_SNI" "restore Reality SNI"
    assert_eq "18080" "$WS_PORT" "restore WS port"
    assert_eq "/sid-old" "$WS_PATH" "restore WS path"
    assert_eq "node-old" "$NODE_NAME" "restore node name"
    assert_eq "8443" "$HY2_PORT" "restore HY2 port"
    assert_eq "hy2-old" "$HY2_PASSWORD" "restore HY2 password"
    assert_eq "bing.com" "$HY2_SNI" "restore HY2 SNI"
    assert_eq "https://www.bing.com" "$HY2_MASQUERADE_URL" "restore HY2 masquerade URL"
    assert_eq "24630" "$SUBSCRIPTION_PORT" "restore subscription port"
    assert_eq "argo.old.example.com" "$ARGO_DOMAIN" "restore Argo domain"
    assert_eq "token-old" "$ARGO_TOKEN" "restore Argo token"
    assert_eq "cf-old.example.com" "$ARGO_BEST_CF_DOMAIN" "restore Argo cache"
    assert_eq "cf4-old.example.com" "$ARGO_BEST_CF_DOMAIN_IPV4" "restore Argo IPv4 cache"
    assert_eq "cf6-old.example.com" "$ARGO_BEST_CF_DOMAIN_IPV6" "restore Argo IPv6 cache"
    assert_eq "all" "$LINK_IPV4_SELECTION" "restore IPv4 link selection"
    assert_eq "www.apple.com" "$REALITY_SNI_PREV" "restore previous Reality SNI"
    assert_eq "sub-old" "$SUB_TOKEN" "restore subscription token"
    assert_eq "198.51.100.77" "$PUBLIC_IPV4_OVERRIDE" "restore public IPv4 override"
}

test_hysteria2_config_uses_masquerade_proxy() {
    local tmp config chown_def
    tmp=$(mktemp -d)

    chown_def=$(declare -f chown 2>/dev/null || true)
    chown() { return 0; }
    sing-box() {
        [[ "${1:-}" == "check" ]] && return 0
        return 1
    }
    CONFIG_DIR="$tmp"
    CONFIG_FILE="${tmp}/config.json"
    UUID="uuid-1"
    REALITY_PORT="443"
    REALITY_SNI="www.microsoft.com"
    PRIVATE_KEY="private"
    SHORT_ID="abcd1234"
    WS_PORT="18080"
    WS_PATH="/abcd1234"
    HY2_PORT="443"
    HY2_PASSWORD="hy2-password"
    HY2_SNI="bing.com"
    HY2_MASQUERADE_URL="https://www.bing.com"

    write_singbox_config >/dev/null
    unset -f chown sing-box
    [[ -n "$chown_def" ]] && eval "$chown_def"
    config=$(<"$CONFIG_FILE")
    rm -rf "$tmp"

    assert_contains "$config" '"masquerade": {' "HY2 masquerade block"
    assert_contains "$config" '"type": "proxy"' "HY2 masquerade proxy type"
    assert_contains "$config" '"url": "https://www.bing.com"' "HY2 masquerade proxy URL"
    assert_contains "$config" '"rewrite_host": true' "HY2 masquerade rewrite host"
}

test_relay_script_generation_uses_argo_upstream() {
    local tmp relay_script script_body

    tmp=$(mktemp -d)
    relay_script="${tmp}/relay-install.sh"
    UUID="uuid-main"
    WS_PATH="/ws-main"

    write_relay_install_script \
        "$relay_script" \
        "443" \
        "www.microsoft.com" \
        "cf.example.com" \
        "argo.example.com" \
        "node-Relay"

    bash -n "$relay_script"
    script_body=$(<"$relay_script")
    assert_contains "$script_body" '#!/usr/bin/env sh' "relay script sh bootstrap"
    assert_contains "$script_body" 'exec bash "$0" "$@"' "relay script bash exec"
    assert_contains "$script_body" 'install_singbox_from_musl_tarball' "relay Alpine musl fallback"
    assert_contains "$script_body" 'RELAY_PORT="443"' "relay port"
    assert_contains "$script_body" 'RELAY_SNI="www.microsoft.com"' "relay Reality SNI"
    assert_contains "$script_body" 'UPSTREAM_SERVER="cf.example.com"' "relay upstream server"
    assert_contains "$script_body" 'UPSTREAM_HOST="argo.example.com"' "relay upstream host"
    assert_contains "$script_body" 'UPSTREAM_UUID="uuid-main"' "relay upstream UUID"
    assert_contains "$script_body" 'UPSTREAM_WS_PATH="/ws-main"' "relay upstream WS path"
    assert_contains "$script_body" '"outbound": "main-argo-out"' "relay route"
    assert_not_contains "$script_body" "__UPSTREAM_SERVER__" "relay placeholders replaced"

    rm -rf "$tmp"
}

test_relay_script_requires_argo_upstream() {
    local tmp relay_script

    tmp=$(mktemp -d)
    relay_script="${tmp}/relay-install.sh"
    UUID="uuid-main"
    WS_PATH="/ws-main"

    if write_relay_install_script "$relay_script" "443" "www.microsoft.com" "" "argo.example.com" "node-Relay"; then
        fail "relay script accepted empty upstream server"
    fi

    rm -rf "$tmp"
}

test_parse_vless_ws_argo_link_extracts_required_fields() {
    local parsed_output

    parsed_output=$(parse_vless_ws_argo_link 'vless://123e4567-e89b-12d3-a456-426614174000@cf.example.com:443?encryption=none&type=ws&host=argo.example.com&path=%2Fws-main#Relay%20Node')
    assert_contains "$parsed_output" $'UPSTREAM_UUID\t123e4567-e89b-12d3-a456-426614174000' "parsed relay UUID"
    assert_contains "$parsed_output" $'UPSTREAM_SERVER\tcf.example.com' "parsed relay server"
    assert_contains "$parsed_output" $'UPSTREAM_HOST\targo.example.com' "parsed relay host"
    assert_contains "$parsed_output" $'UPSTREAM_WS_PATH\t/ws-main' "parsed relay ws path"
    assert_contains "$parsed_output" $'RELAY_NAME\tRelay Node' "parsed relay name"
}

test_parse_vless_ws_argo_link_falls_back_to_sni() {
    local parsed_output

    parsed_output=$(parse_vless_ws_argo_link 'vless://123e4567-e89b-12d3-a456-426614174000@cf.example.com:443?encryption=none&type=ws&sni=argo.example.com&path=%2Frelay')
    assert_contains "$parsed_output" $'UPSTREAM_HOST\targo.example.com' "parsed relay host fallback to sni"
}

test_parse_first_vless_ws_argo_from_text_uses_first_supported_link() {
    local parsed_output multiline

    multiline=$'ss://ignored\nvless://123e4567-e89b-12d3-a456-426614174000@cf.example.com:443?encryption=none&type=ws&host=argo.example.com&path=%2Frelay#Relay\nvless://11111111-1111-1111-1111-111111111111@example.com:443?type=tcp'
    parsed_output=$(parse_first_vless_ws_argo_from_text "$multiline")
    assert_contains "$parsed_output" $'UPSTREAM_SERVER\tcf.example.com' "text parser first supported server"
}

test_parse_vless_ws_argo_candidates_from_text_lists_all_supported_links() {
    local candidates_output multiline

    multiline=$'vless://123e4567-e89b-12d3-a456-426614174000@cf1.example.com:443?encryption=none&type=ws&host=argo1.example.com&path=%2Fone#Relay1\nvmess://ignored\nvless://123e4567-e89b-12d3-a456-426614174001@cf2.example.com:443?encryption=none&type=ws&host=argo2.example.com&path=%2Ftwo#Relay2'
    candidates_output=$(parse_vless_ws_argo_candidates_from_text "$multiline")
    assert_contains "$candidates_output" $'__CANDIDATE__\t1' "candidate list first marker"
    assert_contains "$candidates_output" $'UPSTREAM_SERVER\tcf1.example.com' "candidate list first server"
    assert_contains "$candidates_output" $'__CANDIDATE__\t2' "candidate list second marker"
    assert_contains "$candidates_output" $'UPSTREAM_SERVER\tcf2.example.com' "candidate list second server"
}

test_parse_vless_ws_argo_source_supports_base64_subscription_content() {
    local raw parsed_output encoded

    raw=$'vmess://ignored\nvless://123e4567-e89b-12d3-a456-426614174000@cf.example.com:443?encryption=none&type=ws&host=argo.example.com&path=%2Frelay#Relay'
    encoded=$(printf '%s' "$raw" | base64 | tr -d '\r\n')
    parsed_output=$(parse_vless_ws_argo_source "$encoded")
    assert_contains "$parsed_output" $'UPSTREAM_SERVER\tcf.example.com' "base64 subscription parser server"
    assert_contains "$parsed_output" $'UPSTREAM_WS_PATH\t/relay' "base64 subscription parser path"
}

test_select_relay_candidate_from_source_can_choose_second_candidate() {
    local multiline parsed_output prompt_read_def

    multiline=$'vless://123e4567-e89b-12d3-a456-426614174000@cf1.example.com:443?encryption=none&type=ws&host=argo1.example.com&path=%2Fone#Relay1\nvless://123e4567-e89b-12d3-a456-426614174001@cf2.example.com:443?encryption=none&type=ws&host=argo2.example.com&path=%2Ftwo#Relay2'
    prompt_read_def=$(declare -f prompt_read)
    prompt_read() {
        local __var_name="$1"
        printf -v "$__var_name" '%s' "2"
    }

    parsed_output=$(select_relay_candidate_from_source "$multiline")
    assert_contains "$parsed_output" $'UPSTREAM_SERVER\tcf2.example.com' "selected second candidate server"
    assert_contains "$parsed_output" $'UPSTREAM_HOST\targo2.example.com' "selected second candidate host"

    unset -f prompt_read
    eval "$prompt_read_def"
}

test_normalize_relay_ws_path_adds_leading_slash() {
    assert_eq "/relay" "$(normalize_relay_ws_path 'relay')" "relay ws path leading slash"
}

test_validate_relay_inputs_rejects_empty_upstream_server() {
    if validate_relay_inputs "" "argo.example.com" "123e4567-e89b-12d3-a456-426614174000" "/relay" "443" "www.microsoft.com"; then
        fail "relay inputs accepted empty upstream server"
    fi
}

test_validate_relay_inputs_accepts_valid_values() {
    validate_relay_inputs "cf.example.com" "argo.example.com" "123e4567-e89b-12d3-a456-426614174000" "/relay" "443" "www.microsoft.com" || fail "relay inputs rejected valid values"
}

test_relay_install_help_mentions_relay_install() {
    local output check_root_def detect_os_def install_manager_command_def

    check_root_def=$(declare -f check_root)
    detect_os_def=$(declare -f detect_os)
    install_manager_command_def=$(declare -f install_manager_command)

    check_root() { :; }
    detect_os() { :; }
    install_manager_command() { :; }

    output=$(main --help)
    assert_contains "$output" "relay-install" "help mentions relay-install"

    unset -f check_root detect_os install_manager_command
    eval "$check_root_def"
    eval "$detect_os_def"
    eval "$install_manager_command_def"
}


test_alpine_package_fallback() {
    local tmp fallback_file
    local run_low_resource_def package_manager_def install_singbox_from_official_tarball_def
    tmp=$(mktemp -d)
    fallback_file="${tmp}/fallback"
    run_low_resource_def=$(declare -f run_low_resource)
    package_manager_def=$(declare -f package_manager)
    install_singbox_from_official_tarball_def=$(declare -f install_singbox_from_official_tarball)
    make_cmd "${tmp}/apk" '#!/usr/bin/env bash
exit 1'
    run_low_resource() {
        "$@"
    }
    package_manager() {
        echo "apk"
    }
    install_singbox_from_official_tarball() {
        echo "used" > "$fallback_file"
        make_cmd "${tmp}/sing-box" '#!/usr/bin/env bash
exit 0'
    }
    PATH="${tmp}:$PATH" install_or_upgrade_singbox_package false
    [[ -f "$fallback_file" ]] || fail "Alpine fallback was not used"
    unset -f run_low_resource package_manager install_singbox_from_official_tarball
    eval "$run_low_resource_def"
    eval "$package_manager_def"
    eval "$install_singbox_from_official_tarball_def"
    rm -rf "$tmp"
}

test_non_alpine_package_verifies_binary() {
    local tmp
    tmp=$(mktemp -d)
    package_manager() {
        echo "none"
    }
    curl() {
        cat <<EOF
#!/usr/bin/env sh
cat > "${tmp}/sing-box" <<'SH'
#!/usr/bin/env sh
exit 0
SH
chmod +x "${tmp}/sing-box"
EOF
    }
    PATH="${tmp}:$PATH" install_or_upgrade_singbox_package false
    rm -rf "$tmp"
}

test_low_memory_without_swap_skips_optional_deps() {
    local install_called=false
    local get_resource_profile_def is_low_memory_without_swap_def install_packages_low_resource_def
    get_resource_profile_def=$(declare -f get_resource_profile)
    is_low_memory_without_swap_def=$(declare -f is_low_memory_without_swap)
    install_packages_low_resource_def=$(declare -f install_packages_low_resource)

    get_resource_profile() {
        echo "low-noswap"
    }
    is_low_memory_without_swap() {
        return 0
    }
    install_packages_low_resource() {
        install_called=true
    }

    install_optional_deps >/dev/null
    [[ "$install_called" == "false" ]] || fail "low-noswap optional deps should be skipped"

    unset -f get_resource_profile is_low_memory_without_swap install_packages_low_resource
    eval "$get_resource_profile_def"
    eval "$is_low_memory_without_swap_def"
    eval "$install_packages_low_resource_def"
}

test_low_cpu_uses_low_priority_runner() {
    local tmp log
    tmp=$(mktemp -d)
    log="${tmp}/runner.log"

    make_cmd "${tmp}/ionice" "#!/usr/bin/env bash
echo \"\$*\" > '${log}'
exit 0"
    make_cmd "${tmp}/nice" '#!/usr/bin/env bash
exit 0'
    PATH="${tmp}:$PATH" run_low_resource true
    assert_contains "$(<"$log")" "-c 3 nice -n 19 true" "low priority ionice runner"

    rm -rf "$tmp"
}

test_alpine_cloudflared_prefers_apk() {
    local tmp apk_log
    local package_manager_def run_low_resource_def install_cloudflared_binary_def
    tmp=$(mktemp -d)
    apk_log="${tmp}/apk.log"
    package_manager_def=$(declare -f package_manager)
    run_low_resource_def=$(declare -f run_low_resource)
    install_cloudflared_binary_def=$(declare -f install_cloudflared_binary)

    package_manager() {
        echo "apk"
    }
    run_low_resource() {
        "$@"
    }
    apk() {
        [[ "$*" == "add --no-cache cloudflared" ]] || return 1
        echo "$*" > "$apk_log"
        make_cmd "${tmp}/cloudflared" '#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && exit 0
exit 0'
    }
    install_cloudflared_binary() {
        fail "cloudflared binary fallback was used despite apk success"
    }

    PATH="${tmp}:$PATH" install_cloudflared >/dev/null
    [[ -f "$apk_log" ]] || fail "cloudflared apk install was not attempted"

    unset -f package_manager run_low_resource apk install_cloudflared_binary
    eval "$package_manager_def"
    eval "$run_low_resource_def"
    eval "$install_cloudflared_binary_def"
    rm -rf "$tmp"
}

test_alpine_cloudflared_falls_back_to_binary() {
    local tmp fallback_file
    local package_manager_def run_low_resource_def install_cloudflared_binary_def
    tmp=$(mktemp -d)
    fallback_file="${tmp}/fallback"
    package_manager_def=$(declare -f package_manager)
    run_low_resource_def=$(declare -f run_low_resource)
    install_cloudflared_binary_def=$(declare -f install_cloudflared_binary)

    package_manager() {
        echo "apk"
    }
    run_low_resource() {
        "$@"
    }
    apk() {
        return 1
    }
    install_cloudflared_binary() {
        echo "used" > "$fallback_file"
        make_cmd "${tmp}/cloudflared" '#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && exit 0
exit 0'
    }

    PATH="${tmp}:$PATH" install_cloudflared >/dev/null
    [[ -f "$fallback_file" ]] || fail "cloudflared binary fallback was not used"

    unset -f package_manager run_low_resource apk install_cloudflared_binary
    eval "$package_manager_def"
    eval "$run_low_resource_def"
    eval "$install_cloudflared_binary_def"
    rm -rf "$tmp"
}

test_reality_sni_probe_failure_uses_default() {
    REALITY_SNI=""
    REALITY_SNI_LIST=("www.microsoft.com" "www.apple.com")
    get_reality_probe_parallelism() {
        echo 1
    }
    curl() {
        return 7
    }

    select_reality_sni >/dev/null
    assert_eq "www.microsoft.com" "$REALITY_SNI" "Reality SNI default after probe failure"
    unset -f curl get_reality_probe_parallelism
}

test_reality_client_check_config_matches_share_link_params() {
    local tmp cfg
    tmp=$(mktemp -d)
    cfg="${tmp}/client.json"

    UUID="11111111-2222-3333-4444-555555555555"
    REALITY_SNI="www.apple.com"
    PUBLIC_KEY="test-public-key"
    SHORT_ID="abcd1234"

    # 自检客户端配置必须与分享链接参数一一对应，否则回环自检会误报“链接错误”。
    write_reality_client_check_config "$cfg" "127.0.0.1" "8443" "20808"

    local content
    content=$(cat "$cfg")
    assert_contains "$content" '"server_port": 8443' "client check uses reality port"
    assert_contains "$content" '"listen_port": 20808' "client check uses socks port"
    assert_contains "$content" "\"server\": \"127.0.0.1\"" "client check targets given server"
    assert_contains "$content" "\"uuid\": \"${UUID}\"" "client check carries uuid"
    assert_contains "$content" "\"server_name\": \"${REALITY_SNI}\"" "client check carries sni"
    assert_contains "$content" "\"public_key\": \"${PUBLIC_KEY}\"" "client check carries public key"
    assert_contains "$content" "\"short_id\": \"${SHORT_ID}\"" "client check carries short id"
    assert_contains "$content" '"flow": "xtls-rprx-vision"' "client check uses vision flow"
    assert_contains "$content" '"fingerprint": "chrome"' "client check uses chrome fingerprint"

    rm -rf "$tmp"
}

test_reality_check_command_is_dispatched() {
    # check/selfcheck 子命令必须绑定到 do_reality_check，避免自检功能悬空无法调用。
    assert_contains "$(declare -f main)" "do_reality_check" "check command dispatches self-check"
}

test_manager_command_rejects_empty_source() {
    local tmp empty_script valid_script old_manager old_alias old_system old_system_alias old_bin old_bin_alias
    local symlink_probe_target symlink_probe_link symlink_supported=false

    tmp=$(mktemp -d)
    empty_script="${tmp}/empty"
    valid_script="${tmp}/install.sh"
    old_manager="$MANAGER_COMMAND"
    old_alias="$MANAGER_ALIAS_COMMAND"
    old_system="$MANAGER_SYSTEM_COMMAND"
    old_system_alias="$MANAGER_SYSTEM_ALIAS_COMMAND"
    old_bin="$MANAGER_BIN_COMMAND"
    old_bin_alias="$MANAGER_BIN_ALIAS_COMMAND"
    MANAGER_COMMAND="${tmp}/sbm"
    MANAGER_ALIAS_COMMAND="${tmp}/sing-box-manager"
    MANAGER_SYSTEM_COMMAND="${tmp}/sbm-system"
    MANAGER_SYSTEM_ALIAS_COMMAND="${tmp}/sing-box-manager-system"
    MANAGER_BIN_COMMAND="${tmp}/sbm-bin"
    MANAGER_BIN_ALIAS_COMMAND="${tmp}/sing-box-manager-bin"
    symlink_probe_target="${tmp}/probe-target"
    symlink_probe_link="${tmp}/probe-link"

    : > "$empty_script"
    cp "$SCRIPT" "$valid_script"
    : > "$symlink_probe_target"
    if ln -sf "$symlink_probe_target" "$symlink_probe_link" 2>/dev/null && [[ -L "$symlink_probe_link" ]]; then
        symlink_supported=true
    fi
    rm -f "$symlink_probe_link" "$symlink_probe_target"

    if install_manager_from_file "$empty_script" 2>/dev/null; then
        fail "manager command accepted empty source"
    fi
    install_manager_from_file "$valid_script" || fail "manager command rejected valid script"
    manager_script_valid "$MANAGER_COMMAND" || fail "installed manager command is invalid"
    if [[ "$symlink_supported" == "true" ]]; then
        [[ -L "$MANAGER_ALIAS_COMMAND" ]] || fail "manager alias link was not created"
        [[ -L "$MANAGER_SYSTEM_COMMAND" ]] || fail "system manager link was not created"
        [[ -L "$MANAGER_SYSTEM_ALIAS_COMMAND" ]] || fail "system manager alias link was not created"
        [[ -L "$MANAGER_BIN_COMMAND" ]] || fail "bin manager link was not created"
        [[ -L "$MANAGER_BIN_ALIAS_COMMAND" ]] || fail "bin manager alias link was not created"
        assert_eq "$MANAGER_COMMAND" "$(readlink "$MANAGER_SYSTEM_COMMAND")" "system manager link target"
        assert_eq "$MANAGER_COMMAND" "$(readlink "$MANAGER_BIN_COMMAND")" "bin manager link target"
        is_manager_source "$MANAGER_SYSTEM_COMMAND" || fail "system manager link was not recognized as manager source"
    fi
    if is_manager_source "$valid_script"; then
        fail "separate source script was mistaken for installed manager"
    fi

    MANAGER_COMMAND="$old_manager"
    MANAGER_ALIAS_COMMAND="$old_alias"
    MANAGER_SYSTEM_COMMAND="$old_system"
    MANAGER_SYSTEM_ALIAS_COMMAND="$old_system_alias"
    MANAGER_BIN_COMMAND="$old_bin"
    MANAGER_BIN_ALIAS_COMMAND="$old_bin_alias"
    rm -rf "$tmp"
}

test_refresh_argo_runtime_renews_temporary_domain() {
    local tmp
    local write_argo_service_def service_restart_def service_logs_def sleep_def domain_alive_def
    tmp=$(mktemp -d)
    write_argo_service_def=$(declare -f write_argo_service || true)
    service_restart_def=$(declare -f service_restart || true)
    service_logs_def=$(declare -f service_logs || true)
    sleep_def=$(declare -f sleep || true)
    domain_alive_def=$(declare -f argo_quick_domain_alive || true)

    PARAMS_FILE="${tmp}/params"
    CONFIG_DIR="$tmp"
    UUID="uuid-1"
    SHORT_ID="abcd1234"
    PRIVATE_KEY="private"
    PUBLIC_KEY="public"
    REALITY_PORT="443"
    REALITY_SNI="www.microsoft.com"
    WS_PORT="18080"
    WS_PATH="/abcd1234"
    NODE_NAME="node"
    SUB_TOKEN="sub-token"
    SUBSCRIPTION_PORT="24630"
    ARGO_TOKEN=""
    ARGO_DOMAIN="old.trycloudflare.com"
    ARGO_BEST_CF_DOMAIN="cf-old.example.com"
    ARGO_BEST_CF_DOMAIN_IPV4="cf4-old.example.com"
    ARGO_BEST_CF_DOMAIN_IPV6="cf6-old.example.com"
    HY2_PORT="443"
    HY2_PASSWORD="hy2"
    HY2_SNI="bing.com"

    write_argo_service() {
        :
    }
    service_restart() {
        [[ "$1" == "argo-tunnel" ]]
    }
    service_logs() {
        echo "https://new.trycloudflare.com"
    }
    sleep() {
        :
    }
    # 避免测试对 trycloudflare 真实发起连通性探测
    argo_quick_domain_alive() {
        return 0
    }

    refresh_argo_runtime >/dev/null
    assert_eq "new.trycloudflare.com" "$ARGO_DOMAIN" "temporary Argo domain renew"
    assert_eq "" "$ARGO_BEST_CF_DOMAIN" "temporary Argo cache clear"
    assert_contains "$(<"$PARAMS_FILE")" 'ARGO_DOMAIN="new.trycloudflare.com"' "temporary Argo params save"

    unset -f write_argo_service service_restart service_logs sleep argo_quick_domain_alive
    eval "$write_argo_service_def"
    eval "$service_restart_def"
    eval "$service_logs_def"
    eval "$sleep_def"
    eval "$domain_alive_def"
    rm -rf "$tmp"
}

test_refresh_argo_domain_if_needed_tracks_temp_restart() {
    local service_is_active_def fetch_argo_domain_def save_params_def saved

    service_is_active_def=$(declare -f service_is_active || true)
    fetch_argo_domain_def=$(declare -f fetch_argo_domain || true)
    save_params_def=$(declare -f save_params || true)

    service_is_active() { [[ "$1" == "argo-tunnel" ]]; }

    # 临时隧道重启后域名变化：应抓取新域名并持久化
    ARGO_TOKEN=""
    ARGO_DOMAIN="old.trycloudflare.com"
    saved=false
    fetch_argo_domain() { ARGO_DOMAIN="new.trycloudflare.com"; return 0; }
    save_params() { saved=true; }
    refresh_argo_domain_if_needed
    assert_eq "new.trycloudflare.com" "$ARGO_DOMAIN" "temp domain refreshed after restart"
    [[ "$saved" == "true" ]] || fail "refresh did not persist new temp domain"

    # 抓取失败时回退到缓存域名，避免链接消失
    ARGO_DOMAIN="cached.trycloudflare.com"
    fetch_argo_domain() { ARGO_DOMAIN=""; return 1; }
    refresh_argo_domain_if_needed
    assert_eq "cached.trycloudflare.com" "$ARGO_DOMAIN" "temp domain falls back to cache on fetch failure"

    # 固定域名(Token)模式不从日志抓取
    ARGO_TOKEN="token"
    ARGO_DOMAIN="fixed.example.com"
    fetch_argo_domain() { fail "token mode must not fetch temp domain from logs"; }
    refresh_argo_domain_if_needed
    assert_eq "fixed.example.com" "$ARGO_DOMAIN" "token mode keeps fixed domain"

    # 域名未变化时必须返回 0：本函数在 set -e 下被裸调用，
    # 返回非零会终止整个脚本 (v2.6.36 「任意菜单操作后退出」回归)
    ARGO_TOKEN=""
    ARGO_DOMAIN="same.trycloudflare.com"
    saved=false
    fetch_argo_domain() { ARGO_DOMAIN="same.trycloudflare.com"; return 0; }
    refresh_argo_domain_if_needed || fail "unchanged temp domain must return 0"
    [[ "$saved" == "false" ]] || fail "unchanged temp domain should not re-save params"

    # 抓取失败(回退缓存)路径同样必须返回 0
    fetch_argo_domain() { ARGO_DOMAIN=""; return 1; }
    refresh_argo_domain_if_needed || fail "fetch failure fallback must return 0"

    # argo-tunnel 未运行时必须返回 0
    service_is_active() { return 1; }
    refresh_argo_domain_if_needed || fail "inactive argo-tunnel must return 0"

    unset -f service_is_active fetch_argo_domain save_params
    [[ -n "$service_is_active_def" ]] && eval "$service_is_active_def"
    [[ -n "$fetch_argo_domain_def" ]] && eval "$fetch_argo_domain_def"
    [[ -n "$save_params_def" ]] && eval "$save_params_def"
}

test_ensure_time_sync_skips_when_already_checked() {
    local out get_time_skew_def

    get_time_skew_def=$(declare -f get_time_skew_seconds)

    # 同一进程内第二次调用直接短路：不再探测 RTC，也不输出任何内容
    TIME_SYNC_CHECKED=true
    get_time_skew_seconds() { echo "PROBED" >&2; return 1; }
    out=$(ensure_time_sync 2>&1) || fail "cached ensure_time_sync must return 0"
    assert_eq "" "$out" "cached ensure_time_sync produces no output"

    TIME_SYNC_CHECKED=false
    eval "$get_time_skew_def"
}

test_ensure_time_sync_trusts_network_time_over_broken_rtc() {
    local out
    local skew_def net_skew_def verifiable_def synced_def attempt_def

    skew_def=$(declare -f get_time_skew_seconds)
    net_skew_def=$(declare -f get_network_time_skew_seconds)
    verifiable_def=$(declare -f time_sync_status_verifiable)
    synced_def=$(declare -f is_time_synchronized)
    attempt_def=$(declare -f attempt_time_sync)

    # 宿主机 RTC 乱值(偏差数十年)但系统时间与网络时间一致：
    # 不应触发同步修复，更不能返回非零 (v2.6.36 Alpine NAT VPS 回归)
    TIME_SYNC_CHECKED=false
    get_time_skew_seconds() { echo 1783050943; }
    get_network_time_skew_seconds() { echo 2; }
    time_sync_status_verifiable() { return 1; }
    is_time_synchronized() { return 1; }
    attempt_time_sync() { echo "SYNC_TRIGGERED"; }
    out=$(ensure_time_sync 2>&1) || fail "broken RTC with sane network time must return 0"
    assert_contains "$out" "宿主机 RTC 异常" "broken RTC is reported as host RTC issue"
    assert_not_contains "$out" "SYNC_TRIGGERED" "broken RTC must not trigger sync attempts"

    # 无法验证同步状态(busybox ntpd)且 RTC 正常：不应反复触发修复
    TIME_SYNC_CHECKED=false
    get_time_skew_seconds() { echo 3; }
    out=$(ensure_time_sync 2>&1) || fail "unverifiable env with sane clock must return 0"
    assert_not_contains "$out" "SYNC_TRIGGERED" "unverifiable env must not force sync"

    TIME_SYNC_CHECKED=false
    eval "$skew_def"
    eval "$net_skew_def"
    eval "$verifiable_def"
    eval "$synced_def"
    eval "$attempt_def"
}

test_get_http_date_epoch_parses_rfc7231_date() {
    local epoch curl_def

    curl_def=$(declare -f curl || true)
    curl() { printf 'HTTP/1.1 200 OK\r\nDate: Thu, 03 Jul 2026 04:35:43 GMT\r\n\r\n'; }
    epoch=$(get_http_date_epoch) || fail "get_http_date_epoch failed on valid Date header"
    assert_eq "1783053343" "$epoch" "RFC 7231 Date header epoch"

    # 拿不到 Date 头时必须失败而不是输出垃圾
    curl() { printf 'HTTP/1.1 200 OK\r\n\r\n'; }
    if epoch=$(get_http_date_epoch); then
        fail "get_http_date_epoch must fail without Date header"
    fi

    unset -f curl
    [[ -n "$curl_def" ]] && eval "$curl_def"
    return 0
}

test_subscription_gateway_uses_local_https_origin() {
    local tmp service_body argo_body server_body
    local service_manager_def service_daemon_reload_def

    tmp=$(mktemp -d)
    service_manager_def=$(declare -f service_manager)
    service_daemon_reload_def=$(declare -f service_daemon_reload)

    SUBSCRIPTION_SERVER="${tmp}/sbm-subscription-server.py"
    SUBSCRIPTION_SERVICE="${tmp}/sbm-subscription.service"
    SUBSCRIPTION_OPENRC_SERVICE="${tmp}/sbm-subscription"
    SUBSCRIPTION_FILE="${tmp}/subscription.txt"
    SUBSCRIPTION_ENV_FILE="${tmp}/sbm-subscription.env"
    ARGO_SERVICE="${tmp}/argo.service"
    ARGO_OPENRC_SERVICE="${tmp}/argo"
    ARGO_ENV_FILE="${tmp}/argo.env"
    SUB_TOKEN="sub-token"
    SUBSCRIPTION_PORT="24630"
    WS_PORT="18080"
    ARGO_TOKEN=""

    service_manager() {
        echo "systemd"
    }
    service_daemon_reload() {
        :
    }

    write_subscription_server
    write_subscription_service
    write_argo_service

    service_body=$(<"$SUBSCRIPTION_SERVICE")
    argo_body=$(<"$ARGO_SERVICE")
    server_body=$(<"$SUBSCRIPTION_SERVER")
    assert_contains "$service_body" "--listen 127.0.0.1" "subscription local listen"
    assert_contains "$service_body" "--upstream-port 18080" "subscription WS upstream"
    assert_contains "$service_body" "User=nobody" "subscription drops privileges"
    assert_contains "$argo_body" "--url http://127.0.0.1:24630" "Argo HTTPS origin"
    assert_contains "$argo_body" "User=nobody" "argo drops privileges"
    assert_not_contains "$argo_body" "Group=nogroup" "argo avoids Debian-only nogroup"
    assert_contains "$server_body" "def proxy_to_upstream" "subscription gateway proxy"

    unset -f service_manager service_daemon_reload
    eval "$service_manager_def"
    eval "$service_daemon_reload_def"
    rm -rf "$tmp"
}

test_subscription_url_prefers_https_argo() {
    local output

    GENERATED_SUBSCRIPTION_RAW="vless://uuid@example.com:443"
    ARGO_DOMAIN="sub.example.com"
    SUB_TOKEN="sub-token"
    SUBSCRIPTION_PORT="24630"
    PUBLIC_IP="198.51.100.10"
    IP_STACK_MODE="ipv4-only"

    output=$(show_subscription_url)
    assert_contains "$output" "https://sub.example.com/sub/sub-token" "HTTPS subscription URL"
    assert_contains "$output" "http://127.0.0.1:24630/sub/sub-token" "local debug subscription URL"
    assert_not_contains "$output" "http://198.51.100.10:24630" "public HTTP subscription URL"
}

test_subscription_service_does_not_open_firewall() {
    local tmp
    local service_manager_def service_daemon_reload_def service_enable_now_def open_firewall_def

    tmp=$(mktemp -d)
    service_manager_def=$(declare -f service_manager)
    service_daemon_reload_def=$(declare -f service_daemon_reload)
    service_enable_now_def=$(declare -f service_enable_now)
    open_firewall_def=$(declare -f open_firewall)

    SUBSCRIPTION_SERVER="${tmp}/sbm-subscription-server.py"
    SUBSCRIPTION_SERVICE="${tmp}/sbm-subscription.service"
    SUBSCRIPTION_OPENRC_SERVICE="${tmp}/sbm-subscription"
    SUBSCRIPTION_FILE="${tmp}/subscription.txt"
    SUBSCRIPTION_ENV_FILE="${tmp}/sbm-subscription.env"
    SUB_TOKEN="sub-token"
    SUBSCRIPTION_PORT="24630"
    WS_PORT="18080"

    service_manager() {
        echo "systemd"
    }
    service_daemon_reload() {
        :
    }
    service_enable_now() {
        [[ "$1" == "sbm-subscription" ]]
    }
    open_firewall() {
        fail "subscription service opened firewall"
    }

    ensure_subscription_service

    unset -f service_manager service_daemon_reload service_enable_now open_firewall
    eval "$service_manager_def"
    eval "$service_daemon_reload_def"
    eval "$service_enable_now_def"
    eval "$open_firewall_def"
    rm -rf "$tmp"
}

test_port_validation_can_skip_firewall_changes() {
    local assert_port_available_def open_service_ports_def

    assert_port_available_def=$(declare -f assert_port_available)
    open_service_ports_def=$(declare -f open_service_ports)

    REALITY_PORT="443"
    WS_PORT="18080"
    HY2_PORT="443"
    SUBSCRIPTION_PORT="24630"

    assert_port_available() {
        :
    }
    open_service_ports() {
        fail "port confirmation changed firewall before approval"
    }

    validate_service_ports "" "" "" false

    unset -f assert_port_available open_service_ports
    eval "$assert_port_available_def"
    eval "$open_service_ports_def"
}

test_show_relay_troubleshooting_reports_core_hints() {
    local output service_exists_def service_is_active_def get_port_listeners_def service_logs_def check_upstream_tcp_reachability_def

    service_exists_def=$(declare -f service_exists)
    service_is_active_def=$(declare -f service_is_active)
    get_port_listeners_def=$(declare -f get_port_listeners)
    service_logs_def=$(declare -f service_logs)
    check_upstream_tcp_reachability_def=$(declare -f check_upstream_tcp_reachability)

    service_exists() { [[ "$1" == "sing-box" ]]; }
    service_is_active() { return 1; }
    get_port_listeners() { return 1; }
    service_logs() { echo "mock service log with uuid mismatch and ws path error"; }
    check_upstream_tcp_reachability() { return 1; }

    CONFIG_FILE="/tmp/mock-relay-config.json"
    : > "$CONFIG_FILE"
    RELAY_INSTALL_UPSTREAM_SERVER="cf.example.com"
    RELAY_INSTALL_UPSTREAM_HOST="argo.example.com"
    RELAY_INSTALL_UPSTREAM_UUID="123e4567-e89b-12d3-a456-426614174000"
    RELAY_INSTALL_UPSTREAM_WS_PATH="/relay"
    RELAY_INSTALL_PORT="443"

    output=$(show_relay_troubleshooting)
    assert_contains "$output" "线路机 / 落地机排障提示" "relay troubleshooting header"
    assert_contains "$output" "cf.example.com" "relay troubleshooting server hint"
    assert_contains "$output" "argo.example.com" "relay troubleshooting host hint"
    assert_contains "$output" "mock service log with uuid mismatch and ws path error" "relay troubleshooting log excerpt"
    assert_contains "$output" "自动诊断结论" "relay troubleshooting diagnosis heading"
    assert_contains "$output" "更像是上游 UUID 不匹配或格式异常" "relay troubleshooting uuid diagnosis"
    assert_contains "$output" "更像是 WS Path 或 WebSocket 相关参数不匹配" "relay troubleshooting ws diagnosis"
    assert_contains "$output" "更像是本机到上游网络不通，或上游 443 不可达" "relay troubleshooting reachability diagnosis"

    rm -f "$CONFIG_FILE"
    unset -f service_exists service_is_active get_port_listeners service_logs check_upstream_tcp_reachability
    eval "$service_exists_def"
    eval "$service_is_active_def"
    eval "$get_port_listeners_def"
    eval "$service_logs_def"
    eval "$check_upstream_tcp_reachability_def"
}

test_show_relay_success_self_check_reports_core_passes() {
    local output service_exists_def service_is_active_def get_port_listeners_def check_upstream_tcp_reachability_def

    service_exists_def=$(declare -f service_exists)
    service_is_active_def=$(declare -f service_is_active)
    get_port_listeners_def=$(declare -f get_port_listeners)
    check_upstream_tcp_reachability_def=$(declare -f check_upstream_tcp_reachability)

    service_exists() { [[ "$1" == "sing-box" ]]; }
    service_is_active() { return 0; }
    get_port_listeners() { echo "LISTEN 0 128 *:443 *:*"; }
    check_upstream_tcp_reachability() { return 0; }

    CONFIG_DIR="/tmp/relay-self-check"
    CONFIG_FILE="${CONFIG_DIR}/config.json"
    mkdir -p "$CONFIG_DIR"
    : > "$CONFIG_FILE"
    : > "${CONFIG_DIR}/relay-link.txt"
    RELAY_INSTALL_PORT="443"
    RELAY_INSTALL_UPSTREAM_SERVER="cf.example.com"

    output=$(show_relay_success_self_check)
    assert_contains "$output" "线路机 / 落地机部署后自检" "relay self-check header"
    assert_contains "$output" "sing-box 服务当前正在运行" "relay self-check service active"
    assert_contains "$output" "本机 TCP 443 端口已监听" "relay self-check listener"
    assert_contains "$output" "本机到上游 cf.example.com:443 的 TCP 连通性正常" "relay self-check upstream reachability"
    assert_contains "$output" "自检结论: 关键项已通过" "relay self-check success conclusion"

    rm -rf "$CONFIG_DIR"
    unset -f service_exists service_is_active get_port_listeners check_upstream_tcp_reachability
    eval "$service_exists_def"
    eval "$service_is_active_def"
    eval "$get_port_listeners_def"
    eval "$check_upstream_tcp_reachability_def"
}

test_subscription_page_is_final_section() {
    local output subscription_line config_line
    local tmp
    local build_share_links_def show_external_access_requirements_def write_subscription_assets_def

    tmp=$(mktemp -d)
    build_share_links_def=$(declare -f build_share_links)
    show_external_access_requirements_def=$(declare -f show_external_access_requirements)
    write_subscription_assets_def=$(declare -f write_subscription_assets)

    UUID="uuid-1"
    REALITY_PORT="443"
    REALITY_SNI="www.microsoft.com"
    PUBLIC_KEY="public"
    SHORT_ID="abcd1234"
    SUBSCRIPTION_PORT="24630"
    ARGO_TOKEN=""
    ARGO_DOMAIN="sub.example.com"
    WS_PATH="/abcd1234"
    HY2_PORT="443"
    HY2_PASSWORD="hy2-password"
    SUB_TOKEN="sub-token"
    LINK_FILE="${tmp}/share-links.txt"

    build_share_links() {
        IP_STACK_MODE="ipv4-only"
        PUBLIC_IP="198.51.100.10"
        GENERATED_SUBSCRIPTION_RAW="vless://uuid@example.com:443"
        GENERATED_REALITY_LINKS="vless://direct"
        GENERATED_ARGO_LINKS=""
        GENERATED_HY2_LINKS=""
    }
    show_external_access_requirements() {
        echo "external access"
    }
    write_subscription_assets() {
        :
    }

    output=$(generate_and_show_links; echo "deployment complete"; show_subscription_url)
    subscription_line=$(printf '%s\n' "$output" | grep -n "订阅地址" | tail -n1 | cut -d: -f1)
    config_line=$(printf '%s\n' "$output" | grep -n "配置信息" | cut -d: -f1)

    [[ -n "$subscription_line" && -n "$config_line" ]] || fail "subscription-final output markers missing"
    (( config_line < subscription_line )) || fail "subscription URL page is not shown last"
    [[ "$(printf '%s\n' "$output" | tail -n1)" == *"http://127.0.0.1:24630/sub/sub-token"* ]] || fail "subscription page is not the final output"

    unset -f build_share_links show_external_access_requirements write_subscription_assets
    eval "$build_share_links_def"
    eval "$show_external_access_requirements_def"
    eval "$write_subscription_assets_def"
    rm -rf "$tmp"
}

test_service_manager_systemd
test_service_manager_openrc
test_package_manager_priority
test_package_manager_alpine
test_legacy_params_migration
test_params_parser_is_safe_and_round_trips
test_params_cjk_and_legacy_ansi_c_round_trip
test_apply_install_env_overrides_sets_values
test_apply_install_env_overrides_rejects_invalid_values
test_fetch_public_ip_parallel_prefers_endpoint_order
test_probe_available_cf_domains_keeps_order
test_wait_for_service_active_polls_until_ready
test_hysteria2_bandwidth_is_optional
test_hop_range_validation
test_hy2_mport_suffix_reflects_hop_range
test_apply_and_remove_hy2_port_hopping
test_persist_iptables_rules_uses_netfilter_persistent
test_ipv4_public_link_validation
test_ipv4_override_takes_priority
test_ipv4_override_generates_direct_links
test_ip_detection_failure_keeps_argo_link_generation
test_ipv6_only_links_are_argo_only
test_multiple_ipv4_direct_links_follow_selection
test_single_ipv4_falls_back_without_candidate_list
test_rtc_epoch_uses_timedatectl_without_hwclock
test_busybox_ntpd_can_step_system_time
test_runtime_param_restore_is_complete
test_hysteria2_config_uses_masquerade_proxy
test_relay_script_generation_uses_argo_upstream
test_relay_script_requires_argo_upstream
test_parse_vless_ws_argo_link_extracts_required_fields
test_parse_vless_ws_argo_link_falls_back_to_sni
test_parse_first_vless_ws_argo_from_text_uses_first_supported_link
test_parse_vless_ws_argo_candidates_from_text_lists_all_supported_links
test_parse_vless_ws_argo_source_supports_base64_subscription_content
test_select_relay_candidate_from_source_can_choose_second_candidate
test_normalize_relay_ws_path_adds_leading_slash
test_validate_relay_inputs_rejects_empty_upstream_server
test_validate_relay_inputs_accepts_valid_values
test_relay_install_help_mentions_relay_install
test_alpine_package_fallback
test_non_alpine_package_verifies_binary
test_low_memory_without_swap_skips_optional_deps
test_low_cpu_uses_low_priority_runner
test_alpine_cloudflared_prefers_apk
test_alpine_cloudflared_falls_back_to_binary
test_reality_sni_probe_failure_uses_default
test_reality_client_check_config_matches_share_link_params
test_reality_check_command_is_dispatched
test_manager_command_rejects_empty_source
test_refresh_argo_runtime_renews_temporary_domain
test_subscription_gateway_uses_local_https_origin
test_subscription_url_prefers_https_argo
test_subscription_service_does_not_open_firewall
test_port_validation_can_skip_firewall_changes
test_show_relay_troubleshooting_reports_core_hints
test_show_relay_success_self_check_reports_core_passes
test_subscription_page_is_final_section
test_refresh_argo_domain_if_needed_tracks_temp_restart
test_ensure_time_sync_skips_when_already_checked
test_ensure_time_sync_trusts_network_time_over_broken_rtc
test_get_http_date_epoch_parses_rfc7231_date

echo "OK: regression tests passed"
