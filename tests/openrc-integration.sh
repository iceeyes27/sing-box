#!/usr/bin/env bash
# 仅在专用 Alpine 容器或 chroot 中运行；不能在已安装节点的服务器上执行。
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
[[ "${SBM_OPENRC_INTEGRATION:-}" == 1 && -f /run/sbm-openrc-test-environment ]] || fail 'dedicated Alpine environment required'
for path in /etc/init.d/sing-box /usr/local/bin/sing-box /etc/sing-box/config.json; do
    [[ ! -e "$path" ]] || fail "existing installation must be preserved: $path"
done
command -v supervise-daemon >/dev/null || fail 'OpenRC supervise-daemon required'
mkdir -p /run/openrc/{daemons,exclusive,failed,hotplugged,inactive,options,scheduled,started,starting,stopping,tmp,wasinactive}
mkdir -p /usr/local/bin /usr/local/sbin /etc/sing-box
printf 'default\n' > /run/openrc/softlevel
# 隔离环境仅测试进程管理，跳过网卡与文件系统依赖的启动。
cat > /usr/local/sbin/rc-service <<'EOF'
#!/bin/sh
exec /sbin/rc-service --nodeps "$@"
EOF
chmod +x /usr/local/sbin/rc-service
export PATH="/usr/local/sbin:$PATH"
cat > /usr/local/bin/sing-box <<'EOF'
#!/bin/sh
[ ! -f /run/sbm-test-exit ] || exit 1
echo $$ >> /run/sbm-test-pids
while :; do sleep 1; done
EOF
chmod +x /usr/local/bin/sing-box
export SBM_TEST_MODE=1
# shellcheck source=../install.sh
source "$ROOT_DIR/install.sh"
cleanup() {
    timeout 10 rc-service sing-box stop >/dev/null 2>&1 || true
}
trap cleanup EXIT

write_legacy_service() {
    cat > /etc/init.d/sing-box <<'EOF'
#!/sbin/openrc-run
name="sing-box"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background=true
pidfile="/run/sing-box.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"
depend() { need net; }
EOF
    chmod +x /etc/init.d/sing-box
}
latest_pid() { tail -n 1 /run/sbm-test-pids; }
process_running() {
    local pid=$1 stat=""
    [[ -r "/proc/${pid}/stat" ]] || return 1
    read -r stat < "/proc/${pid}/stat" || return 1
    stat=${stat##*) }
    [[ "${stat%% *}" != Z && "${stat%% *}" != X ]] && kill -0 "$pid" 2>/dev/null
}
wait_new_pid() {
    local previous=$1 current attempt
    for ((attempt = 0; attempt < 50; attempt++)); do
        current=$(latest_pid)
        if [[ "$current" != "$previous" ]] && process_running "$current"; then return 0; fi
        sleep 0.2
    done
    fail 'supervisor did not replace the exited process'
}

# 旧后台进程切换监督器后只能剩下一个实例。
write_legacy_service
rc-service sing-box start
sleep 0.2
old_pid=$(latest_pid)
write_singbox_service
if process_running "$old_pid"; then fail 'legacy process survived supervision migration'; fi
service_restart sing-box
new_pid=$(latest_pid)
[[ "$new_pid" != "$old_pid" ]] || fail 'migration reused old process'
service_is_active sing-box || fail 'supervised service inactive'

# 使用真实 OpenRC 验证崩溃自动恢复，而非只检查生成的配置文本。
kill -9 "$new_pid"
wait_new_pid "$new_pid"
service_is_active sing-box || fail 'respawned service inactive'
echo 'OK: real OpenRC migration and automatic respawn'

# 复现旧服务进程消失但 started 标记仍在，验证恢复动作。
rc-service sing-box stop
write_legacy_service
rc-service sing-box start
sleep 0.2
old_pid=$(latest_pid)
kill -9 "$old_pid"
sleep 0.3
result=0
rc-service sing-box status >/dev/null 2>&1 || result=$?
[[ "$result" == 32 ]] || fail "expected crashed legacy state, got $result"
service_start sing-box
service_is_active sing-box || fail 'crashed legacy service was not recovered'
echo 'OK: real OpenRC stale-state recovery'

# 启动器成功但子进程立即退出时必须报告失败。
rc-service sing-box stop
write_singbox_service
touch /run/sbm-test-exit
if service_start sing-box; then fail 'immediate process exit was reported as successful startup'; fi
echo 'OK: real OpenRC immediate-exit detection'
