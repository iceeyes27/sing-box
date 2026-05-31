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
    assert_eq 'sid\\backslash' "$SHORT_ID" "params short id round trip"
    assert_eq '/path with spaces' "$WS_PATH" "params WS path round trip"
    assert_eq 'node # one' "$NODE_NAME" "params node name round trip"
    assert_eq 'sub token $value' "$SUB_TOKEN" "params token round trip"
    assert_eq 'argo token `literal`' "$ARGO_TOKEN" "params argo token round trip"
    assert_eq '198.51.100.99' "$PUBLIC_IPV4_OVERRIDE" "params public IPv4 override round trip"
    assert_eq 'hy2 pass "quoted"' "$HY2_PASSWORD" "params HY2 password round trip"

    rm -rf "$tmp"
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

    build_share_links >/dev/null
    assert_contains "$GENERATED_REALITY_LINKS" "vless://uuid-1@198.51.100.88:443" "override Reality link"
    assert_contains "$GENERATED_HY2_LINKS" "hysteria2://hy2@198.51.100.88:443" "override Hysteria2 link"
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

test_runtime_param_restore_is_complete() {
    restore_runtime_params \
        "uuid-old" "sid-old" "private-old" "public-old" \
        "443" "www.microsoft.com" "18080" "/sid-old" \
        "node-old" "8443" "hy2-old" "bing.com" "https://www.bing.com" \
        "24630" "argo.old.example.com" "token-old" \
        "cf-old.example.com" "cf4-old.example.com" "cf6-old.example.com" "all"

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

    restore_runtime_params \
        "uuid-old" "sid-old" "private-old" "public-old" \
        "443" "www.microsoft.com" "18080" "/sid-old" \
        "node-old" "8443" "hy2-old" "bing.com" "https://www.bing.com" \
        "24630" "argo.old.example.com" "token-old" \
        "cf-old.example.com" "cf4-old.example.com" "cf6-old.example.com" "all"

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

test_alpine_package_fallback() {
    local tmp fallback_file
    tmp=$(mktemp -d)
    fallback_file="${tmp}/fallback"
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

test_manager_command_rejects_empty_source() {
    local tmp empty_script valid_script stale_target old_manager old_alias old_system old_system_alias old_bin old_bin_alias

    tmp=$(mktemp -d)
    empty_script="${tmp}/empty"
    valid_script="${tmp}/install.sh"
    stale_target="${tmp}/stale-sbm"
    old_manager="$MANAGER_COMMAND"
    old_alias="$MANAGER_ALIAS_COMMAND"
    old_system="$MANAGER_SYSTEM_COMMAND"
    old_system_alias="$MANAGER_SYSTEM_ALIAS_COMMAND"
    old_bin="$MANAGER_BIN_COMMAND"
    old_bin_alias="$MANAGER_BIN_ALIAS_COMMAND"
    MANAGER_COMMAND="${tmp}/usr-local/bin/sbm"
    MANAGER_ALIAS_COMMAND="${tmp}/usr-local/bin/sing-box-manager"
    MANAGER_SYSTEM_COMMAND="${tmp}/usr/bin/sbm"
    MANAGER_SYSTEM_ALIAS_COMMAND="${tmp}/usr/bin/sing-box-manager"
    MANAGER_BIN_COMMAND="${tmp}/bin/sbm"
    MANAGER_BIN_ALIAS_COMMAND="${tmp}/bin/sing-box-manager"
    mkdir -p "${tmp}/usr/bin"
    mkdir -p "${tmp}/bin"

    : > "$empty_script"
    cp "$SCRIPT" "$valid_script"
    ln -sf "$stale_target" "$MANAGER_SYSTEM_COMMAND"

    if install_manager_from_file "$empty_script" 2>/dev/null; then
        fail "manager command accepted empty source"
    fi
    install_manager_from_file "$valid_script" || fail "manager command rejected valid script"
    manager_script_valid "$MANAGER_COMMAND" || fail "installed manager command is invalid"
    [[ -L "$MANAGER_ALIAS_COMMAND" ]] || fail "manager alias link was not created"
    [[ -L "$MANAGER_SYSTEM_COMMAND" ]] || fail "system manager link was not created"
    [[ -L "$MANAGER_SYSTEM_ALIAS_COMMAND" ]] || fail "system manager alias link was not created"
    [[ -L "$MANAGER_BIN_COMMAND" ]] || fail "bin manager link was not created"
    [[ -L "$MANAGER_BIN_ALIAS_COMMAND" ]] || fail "bin manager alias link was not created"
    assert_eq "$MANAGER_COMMAND" "$(readlink "$MANAGER_SYSTEM_COMMAND")" "system manager link target"
    assert_eq "$MANAGER_COMMAND" "$(readlink "$MANAGER_BIN_COMMAND")" "bin manager link target"
    is_manager_source "$MANAGER_SYSTEM_COMMAND" || fail "system manager link was not recognized as manager source"
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
    local write_argo_service_def service_restart_def service_logs_def sleep_def
    tmp=$(mktemp -d)
    write_argo_service_def=$(declare -f write_argo_service || true)
    service_restart_def=$(declare -f service_restart || true)
    service_logs_def=$(declare -f service_logs || true)
    sleep_def=$(declare -f sleep || true)

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

    refresh_argo_runtime >/dev/null
    assert_eq "new.trycloudflare.com" "$ARGO_DOMAIN" "temporary Argo domain renew"
    assert_eq "" "$ARGO_BEST_CF_DOMAIN" "temporary Argo cache clear"
    assert_contains "$(<"$PARAMS_FILE")" 'ARGO_DOMAIN=new.trycloudflare.com' "temporary Argo params save"

    unset -f write_argo_service service_restart service_logs sleep
    eval "$write_argo_service_def"
    eval "$service_restart_def"
    eval "$service_logs_def"
    eval "$sleep_def"
    rm -rf "$tmp"
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
    assert_contains "$argo_body" "--url http://127.0.0.1:24630" "Argo HTTPS origin"
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
test_ipv6_only_links_are_argo_only
test_multiple_ipv4_direct_links_follow_selection
test_single_ipv4_falls_back_without_candidate_list
test_rtc_epoch_uses_timedatectl_without_hwclock
test_runtime_param_restore_is_complete
test_hysteria2_config_uses_masquerade_proxy
test_relay_script_generation_uses_argo_upstream
test_relay_script_requires_argo_upstream
test_alpine_package_fallback
test_non_alpine_package_verifies_binary
test_reality_sni_probe_failure_uses_default
test_manager_command_rejects_empty_source
test_refresh_argo_runtime_renews_temporary_domain
test_subscription_gateway_uses_local_https_origin
test_subscription_url_prefers_https_argo
test_subscription_service_does_not_open_firewall
test_port_validation_can_skip_firewall_changes
test_subscription_page_is_final_section

echo "OK: regression tests passed"
