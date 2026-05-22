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
    assert_eq "legacy-sub-token" "$SUB_TOKEN" "legacy subscription token migration"
    assert_eq "24630" "$SUBSCRIPTION_PORT" "legacy subscription port migration"
    assert_eq "cf.example.com" "$ARGO_BEST_CF_DOMAIN_IPV4" "legacy Argo IPv4 cache migration"
    rm -rf "$tmp"
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

    get_public_ip() {
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

test_runtime_param_restore_is_complete() {
    restore_runtime_params \
        "uuid-old" "sid-old" "private-old" "public-old" \
        "443" "www.microsoft.com" "18080" "/sid-old" \
        "node-old" "8443" "hy2-old" "bing.com" \
        "24630" "argo.old.example.com" "token-old" \
        "cf-old.example.com" "cf4-old.example.com" "cf6-old.example.com"

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
    SUBSCRIPTION_PORT="24631"
    ARGO_DOMAIN="argo.new.example.com"
    ARGO_TOKEN="token-new"
    ARGO_BEST_CF_DOMAIN="cf-new.example.com"
    ARGO_BEST_CF_DOMAIN_IPV4="cf4-new.example.com"
    ARGO_BEST_CF_DOMAIN_IPV6="cf6-new.example.com"

    restore_runtime_params \
        "uuid-old" "sid-old" "private-old" "public-old" \
        "443" "www.microsoft.com" "18080" "/sid-old" \
        "node-old" "8443" "hy2-old" "bing.com" \
        "24630" "argo.old.example.com" "token-old" \
        "cf-old.example.com" "cf4-old.example.com" "cf6-old.example.com"

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
    assert_eq "24630" "$SUBSCRIPTION_PORT" "restore subscription port"
    assert_eq "argo.old.example.com" "$ARGO_DOMAIN" "restore Argo domain"
    assert_eq "token-old" "$ARGO_TOKEN" "restore Argo token"
    assert_eq "cf-old.example.com" "$ARGO_BEST_CF_DOMAIN" "restore Argo cache"
    assert_eq "cf4-old.example.com" "$ARGO_BEST_CF_DOMAIN_IPV4" "restore Argo IPv4 cache"
    assert_eq "cf6-old.example.com" "$ARGO_BEST_CF_DOMAIN_IPV6" "restore Argo IPv6 cache"
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
    local tmp empty_script valid_script old_manager old_alias

    tmp=$(mktemp -d)
    empty_script="${tmp}/empty"
    valid_script="${tmp}/install.sh"
    old_manager="$MANAGER_COMMAND"
    old_alias="$MANAGER_ALIAS_COMMAND"
    MANAGER_COMMAND="${tmp}/sbm"
    MANAGER_ALIAS_COMMAND="${tmp}/sing-box-manager"

    : > "$empty_script"
    cp "$SCRIPT" "$valid_script"

    if install_manager_from_file "$empty_script" 2>/dev/null; then
        fail "manager command accepted empty source"
    fi
    install_manager_from_file "$valid_script" || fail "manager command rejected valid script"
    manager_script_valid "$MANAGER_COMMAND" || fail "installed manager command is invalid"

    MANAGER_COMMAND="$old_manager"
    MANAGER_ALIAS_COMMAND="$old_alias"
    rm -rf "$tmp"
}

test_service_manager_systemd
test_service_manager_openrc
test_package_manager_priority
test_package_manager_alpine
test_legacy_params_migration
test_ipv6_only_links_are_argo_only
test_runtime_param_restore_is_complete
test_relay_script_generation_uses_argo_upstream
test_relay_script_requires_argo_upstream
test_alpine_package_fallback
test_non_alpine_package_verifies_binary
test_reality_sni_probe_failure_uses_default
test_manager_command_rejects_empty_source

echo "OK: regression tests passed"
