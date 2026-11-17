# 活动内核只读解析；结构化服务/状态检查由内嵌 Python 标准库实现。
SBM_ENGINE_ROOT="/usr/local/libexec/sbm/sing-box"
SBM_STATE_DIR="/var/lib/sbm"
SBM_LOCK_FILE="/run/sbm/maintenance.lock"
SBM_ENGINE_DROPIN="/etc/systemd/system/sing-box.service.d/50-sbm-engine.conf"
# Read as literal capability declarations by manager_script_valid.
# shellcheck disable=SC2034
SBM_STATE_SCHEMA_MIN=1
# shellcheck disable=SC2034
SBM_STATE_SCHEMA_MAX=1
# shellcheck disable=SC2034
SBM_PENDING_RECOVERY=1

engine_python() {
    command -v python3 >/dev/null 2>&1 || return 2
    SBM_INHERITED_LOCK_FD="${SBM_LOCK_FD:-}" python3 - "$SBM_ENGINE_ROOT" "$SBM_STATE_DIR" "$CONFIG_FILE" "$PARAMS_FILE" \
        "$SINGBOX_OPENRC_SERVICE" "$SBM_ENGINE_DROPIN" "$SBM_LOCK_FILE" "$@" <<'SBM_ENGINE_PY'
# @SBM_ENGINE_PYTHON@
SBM_ENGINE_PY
}

sbm_flock_available() { command -v flock >/dev/null 2>&1; }

# Installation may need flock before it can take the normal maintenance lock.
# A private atomic directory prevents two first-install bootstraps from racing.
sbm_prepare_install_lock() (
    sbm_flock_available && return 0
    local lock_dir="${SBM_LOCK_FILE%/*}" bootstrap_dir package
    umask 077
    mkdir -p "$lock_dir" || return 1
    [[ -d "$lock_dir" && ! -L "$lock_dir" && -O "$lock_dir" && "$(stat -c %a "$lock_dir")" == 700 ]] || return 1
    bootstrap_dir="${lock_dir}/install-bootstrap.lock"
    if ! mkdir -m 700 "$bootstrap_dir" 2>/dev/null; then
        warn "安装依赖初始化正在进行，或存在未清理的初始化锁: ${bootstrap_dir}"
        return 1
    fi
    trap 'rmdir "$bootstrap_dir" 2>/dev/null || true' EXIT
    case "$(package_manager)" in
        apk) package=flock ;;
        apt|dnf|yum) package=util-linux ;;
        *) warn "缺少 flock，且无法识别系统包管理器"; return 1 ;;
    esac
    info "安装首次部署所需的 flock..."
    install_packages_low_resource "$package" || return 1
    hash -r 2>/dev/null || true
    sbm_flock_available || { warn "flock 安装后仍不可用"; return 1; }
)

sbm_lock_acquire() {
    [[ "${SBM_LOCK_HELD:-}" == "$BASHPID" ]] && return 0
    sbm_flock_available || { warn "缺少 flock，未执行修改"; return 1; }
    if [[ ! -e "$(dirname "$SBM_LOCK_FILE")" ]]; then
        (umask 077; mkdir -m 700 "$(dirname "$SBM_LOCK_FILE")") || return 1
    fi
    [[ -d "$(dirname "$SBM_LOCK_FILE")" && ! -L "$SBM_LOCK_FILE" ]] || return 1
    [[ ! -L "$(dirname "$SBM_LOCK_FILE")" && -O "$(dirname "$SBM_LOCK_FILE")" && "$(stat -c %a "$(dirname "$SBM_LOCK_FILE")")" == 700 ]] || return 1
    exec {SBM_LOCK_FD}>>"$SBM_LOCK_FILE" || return 1
    if ! flock -n "$SBM_LOCK_FD"; then
        exec {SBM_LOCK_FD}>&-
        warn "另一个管理操作正在执行，请稍后重试"
        return 1
    fi
    SBM_LOCK_HELD="$BASHPID"
}

sbm_lock_release() {
    [[ "${SBM_LOCK_HELD:-}" == "$BASHPID" ]] || return 0
    flock -u "$SBM_LOCK_FD" || true
    exec {SBM_LOCK_FD}>&-
    unset SBM_LOCK_HELD SBM_LOCK_FD
}

sbm_with_lock() {
    if [[ "${SBM_LOCK_HELD:-}" == "$BASHPID" ]]; then "$@"; return $?; fi
    if [[ "${1:-}" == do_primary_install ]] && ! sbm_flock_available; then
        sbm_prepare_install_lock || return 1
    fi
    sbm_lock_acquire || return 1
    local result=0
    if [[ -e "$SBM_STATE_DIR/pending.json" ]]; then
        if [[ "${1:-}" == engine_rollback ]]; then
            "$@" || result=$?
        else
            warn "有未完成的版本操作，请先执行 sbm rollback sing-box --yes"
            result=1
        fi
    elif [[ -e "$SBM_STATE_DIR/engine.json" ]] && ! engine_python compatible; then
        result=1
    else
        "$@" || result=$?
    fi
    sbm_lock_release
    return "$result"
}

resolve_singbox_binary() {
    if [[ -e "$SBM_STATE_DIR/engine.json" || -e "$SBM_STATE_DIR/pending.json" || -L "$SBM_ENGINE_ROOT/current" ]]; then
        engine_python resolve
    else
        command -v sing-box 2>/dev/null || { [[ -x "$SINGBOX_BIN_PATH" ]] && printf '%s\n' "$SINGBOX_BIN_PATH"; }
    fi
}

run_singbox() {
    local binary
    binary=$(resolve_singbox_binary) || return 1
    "$binary" "$@"
}

# timeout 只能执行真实程序，不能执行 Bash 函数。
run_singbox_bounded() {
    local seconds="$1" binary
    shift
    binary=$(resolve_singbox_binary) || return 1
    command -v timeout >/dev/null 2>&1 || return 1
    timeout -k 1 "$seconds" "$binary" "$@"
}

engine_finish_start() {
    [[ -f "$SBM_STATE_DIR/engine.json" ]] || return 0
    engine_python validate-start
}

engine_refresh_after_change() {
    [[ -f "$SBM_STATE_DIR/engine.json" ]] || return 0
    engine_python refresh
}

sbm_mutation_guard() {
    [[ ! -e "$SBM_STATE_DIR/pending.json" ]] || { warn "有未完成的版本操作，请先恢复"; return 1; }
}

engine_config_guard() {
    [[ -f "$SBM_STATE_DIR/engine.json" ]] || return 0
    engine_python writable-config
}
