#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SBM_TEST_MODE=1
# shellcheck source=../install.sh
source "$ROOT_DIR/install.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'"; }

test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT
SBM_STATE_DIR="$test_root/sbm-state"
SBM_ENGINE_ROOT="$test_root/sbm-engines"
SBM_LOCK_FILE="$test_root/sbm-lock"
SBM_ENGINE_DROPIN="$test_root/50-sbm-engine.conf"
resolve_singbox_binary() { printf '%s\n' '/usr/bin/sing-box'; }
mkdir "$test_root/bin"
cat > "$test_root/bin/rc-service" <<'MOCK'
#!/usr/bin/env bash
set -eu
state=$(<"$OPENRC_TEST_DIR/state")
mode=$(<"$OPENRC_TEST_DIR/mode")
printf '%s\n' "$2" >> "$OPENRC_TEST_DIR/calls"
case "$2" in
    status)
        [[ "$mode" != hang-status ]] || sleep 3
        case "$state" in
            running) echo ' * status: started'; exit 0 ;;
            stopped) echo ' * status: stopped'; exit 3 ;;
            crashed) echo ' * status: crashed'; exit 32 ;;
            unsupervised) echo ' * status: unsupervised'; exit 64 ;;
            misleading) echo ' * status: started'; exit 32 ;;
            missing) echo ' * service does not exist'; exit 1 ;;
            starting) echo ' * status: starting'; exit 8 ;;
        esac
        ;;
    stop)
        [[ "$mode" != hang-stop ]] || sleep 3
        [[ "$mode" != slow-recovery ]] || sleep 0.7
        if [[ -n "${OPENRC_LEGACY_FILE:-}" ]] && grep -q 'supervise-daemon' "$OPENRC_LEGACY_FILE"; then
            echo 'new definition replaced a running legacy service' >&2
            exit 1
        fi
        if [[ "$state" == running ]]; then echo stopped > "$OPENRC_TEST_DIR/state"; exit 0; fi
        exit 1
        ;;
    zap)
        [[ "$mode" != zap-fails ]] || exit 1
        [[ "$mode" != slow-recovery ]] || sleep 0.7
        case "$state" in
            crashed|unsupervised|misleading) echo stopped > "$OPENRC_TEST_DIR/state" ;;
            *) echo 'unexpected zap' >&2; exit 1 ;;
        esac
        ;;
    start|restart)
        [[ "$mode" != "hang-$2" ]] || sleep 3
        [[ "$state" != crashed && "$state" != unsupervised ]] || exit 0
        if [[ "$mode" == exits-immediately ]]; then
            echo crashed > "$OPENRC_TEST_DIR/state"
        else
            echo running > "$OPENRC_TEST_DIR/state"
        fi
        ;;
esac
MOCK
chmod +x "$test_root/bin/rc-service"
export PATH="$test_root/bin:$PATH"
export OPENRC_TEST_DIR="$test_root"
service_manager() { echo openrc; }

reset_case() {
    printf '%s\n' "$1" > "$test_root/state"
    printf '%s\n' "${2:-normal}" > "$test_root/mode"
    : > "$test_root/calls"
}
assert_called() { grep -qx "$1" "$test_root/calls" || fail "$2"; }
assert_not_called() { if grep -qx "$1" "$test_root/calls"; then fail "$2"; fi; }

# 复现服务器的残留 started 标记；需要清理后启动，而不是接受假成功。
for state in crashed unsupervised; do
    reset_case "$state"
    service_start sing-box >/dev/null
    assert_eq running "$(<"$test_root/state")" "$state service recovered"
    assert_called zap "$state service was not reset"
    assert_called start "$state service was not started"
    assert_not_called restart "$state service restarted before reset"
done

reset_case running
service_start sing-box >/dev/null
assert_not_called stop 'starting a healthy service stopped it'
assert_not_called zap 'healthy service state was removed'
assert_not_called start 'healthy service was launched twice'

reset_case running
service_restart sing-box >/dev/null
assert_called restart 'healthy service restart was skipped'
assert_not_called zap 'healthy restart cleared state'

for state in missing starting; do
    reset_case "$state"
    if service_start sing-box >/dev/null; then fail "$state service reported success"; fi
    assert_not_called zap "$state service state was removed"
    assert_not_called start "$state service received an unsafe start"
done

reset_case stopped exits-immediately
if service_start sing-box >/dev/null; then fail 'immediate process exit reported success'; fi

(
    reset_case stopped
    openrc_service_child_active() { return 1; }
    if service_start sing-box >/dev/null; then fail 'supervisor without live child reported success'; fi
    if service_is_active sing-box; then fail 'supervisor without live child reported active'; fi
)

reset_case misleading
if service_is_active sing-box; then fail 'nonzero status with started text was accepted'; fi

reset_case crashed zap-fails
if service_start sing-box >/dev/null; then fail 'failed state reset reported success'; fi
assert_not_called start 'failed state reset still launched service'

(
    reset_case crashed
    openrc_service_pid_alive() { return 0; }
    if service_start sing-box >/dev/null; then fail 'live PID was discarded'; fi
    assert_not_called zap 'live PID lost its service state'
    assert_not_called start 'live PID was duplicated'
)

# status、恢复、重启和检查必须遵守同一次超时，超时后不再尝试 start。
for scenario in 'running hang-restart' 'crashed hang-stop' 'crashed slow-recovery' 'stopped hang-status'; do
    read -r state mode <<< "$scenario"
    reset_case "$state" "$mode"
    result=0
    service_restart_bounded sing-box 1 >/dev/null || result=$?
    [[ "$result" == 124 || "$result" == 137 ]] || fail "$mode did not preserve timeout exit code: $result"
    assert_not_called start "$mode started again after timeout"
done

reset_case stopped
service_restart_bounded sing-box 5 >/dev/null
assert_eq running "$(<"$test_root/state")" 'bounded restart did not start stopped service'
if service_restart_bounded sing-box 0 >/dev/null; then fail 'zero timeout accepted'; fi

# 旧进程必须在替换启动脚本前停止；已使用监督器的服务不应被重复停止。
(
    reset_case running
    SINGBOX_OPENRC_SERVICE="$test_root/sing-box"
    printf 'command_background=true\n' > "$SINGBOX_OPENRC_SERVICE"
    export OPENRC_LEGACY_FILE="$SINGBOX_OPENRC_SERVICE"
    write_singbox_service
    assert_called stop 'legacy process was not stopped before migration'
    grep -qF 'supervisor="supervise-daemon"' "$SINGBOX_OPENRC_SERVICE" || fail 'sing-box supervisor missing'
    bash -n "$SINGBOX_OPENRC_SERVICE"
    reset_case running
    write_singbox_service
    assert_not_called stop 'rewriting supervised service stopped it'
)

(
    reset_case crashed
    SINGBOX_OPENRC_SERVICE="$test_root/live-sing-box"
    printf 'command_background=true\n' > "$SINGBOX_OPENRC_SERVICE"
    openrc_service_pid_alive() { return 0; }
    if write_singbox_service >/dev/null; then fail 'unsafe migration reported success'; fi
    assert_eq command_background=true "$(<"$SINGBOX_OPENRC_SERVICE")" 'failed migration replaced old definition'
)

# 三个服务均使用监督器；固定隧道继续从环境文件读取凭证。
(
    reset_case stopped
    ARGO_ENABLED=true; ARGO_TOKEN=fixed-token; ARGO_DOMAIN=sub.example.com
    ARGO_OPENRC_SERVICE="$test_root/argo-tunnel"
    ARGO_ENV_FILE="$test_root/argo.env"
    SUB_TOKEN=sub-token
    WS_PORT=8080; SUBSCRIPTION_PORT=24630
    SUBSCRIPTION_OPENRC_SERVICE="$test_root/sbm-subscription"
    SUBSCRIPTION_ENV_FILE="$test_root/sub.env"
    write_argo_service >/dev/null
    write_subscription_service
    for service_file in "$ARGO_OPENRC_SERVICE" "$SUBSCRIPTION_OPENRC_SERVICE"; do
        bash -n "$service_file"
        grep -qF 'supervisor="supervise-daemon"' "$service_file" || fail 'supervisor missing'
        grep -qF 'respawn_delay=5' "$service_file" || fail 'restart backoff missing'
        grep -qF 'respawn_max=5' "$service_file" || fail 'restart limit missing'
        if grep -q 'command_background=true' "$service_file"; then fail 'supervised command uses legacy background mode'; fi
    done
    grep -qF "env_file=\"$ARGO_ENV_FILE\"" "$ARGO_OPENRC_SERVICE" || fail 'fixed tunnel environment lost'
    if grep -q fixed-token "$ARGO_OPENRC_SERVICE"; then fail 'tunnel token embedded in service arguments'; fi
    ARGO_TOKEN=""; ARGO_DOMAIN=""
    write_argo_service >/dev/null
    if grep -q '^env_file=' "$ARGO_OPENRC_SERVICE"; then fail 'quick tunnel kept fixed token environment'; fi
)

# CLI 必须把核心、网关和隧道失败传递给调用方，且不读取失败隧道的旧域名。
(
    ARGO_ENABLED=true; ARGO_TOKEN=""; ARGO_DOMAIN=quick.trycloudflare.com
    load_params() { :; }
    ensure_subscription_service_if_enabled() { :; }
    refresh_argo_domain_if_needed() { :; }
    fetch_argo_domain() { fail 'failed tunnel attempted domain refresh'; }
    save_params() { :; }
    build_share_links() { fail 'failed service rewrote share links'; }
    write_subscription_assets() { fail 'failed service rewrote subscription'; }
    press_enter() { :; }; sleep() { :; }
    service_start() { [[ "$1" != argo-tunnel ]]; }
    service_restart() { [[ "$1" != argo-tunnel ]]; }
    if do_start >/dev/null; then fail 'CLI ignored tunnel startup failure'; fi
    if do_restart >/dev/null; then fail 'CLI ignored tunnel restart failure'; fi
    service_start() { return 1; }; service_restart() { return 1; }
    if do_start >/dev/null; then fail 'CLI ignored core startup failure'; fi
    if do_restart >/dev/null; then fail 'CLI ignored core restart failure'; fi
    service_start() { :; }; service_restart() { :; }
    load_params() { return 1; }
    if do_start >/dev/null; then fail 'CLI ignored missing saved parameters'; fi
    load_params() { :; }
    ARGO_ENABLED=false
    build_share_links() { return 1; }
    if do_start >/dev/null; then fail 'CLI ignored share-link write failure'; fi
    if do_restart >/dev/null; then fail 'CLI ignored share-link write failure on restart'; fi
)

(
    do_start() { return 1; }
    do_restart() { return 1; }
    do_start_menu
    do_restart_menu
)

printf 'OK: OpenRC recovery, supervision and failure tests passed\n'
