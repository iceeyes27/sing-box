# ─── 管理命令 (sbm) ─────────────────────────────────────────
ensure_command_aliases() {
    [[ -f "$MANAGER_COMMAND" ]] || return 0
    ensure_command_link "$MANAGER_COMMAND" "$MANAGER_ALIAS_COMMAND"
    ensure_command_link "$MANAGER_COMMAND" "$MANAGER_SYSTEM_COMMAND"
    ensure_command_link "$MANAGER_COMMAND" "$MANAGER_SYSTEM_ALIAS_COMMAND"
    ensure_command_link "$MANAGER_COMMAND" "$MANAGER_BIN_COMMAND"
    ensure_command_link "$MANAGER_COMMAND" "$MANAGER_BIN_ALIAS_COMMAND"
}

resolve_existing_path() {
    local path="$1"
    local dir base

    if command -v readlink >/dev/null 2>&1; then
        readlink -f "$path" 2>/dev/null && return 0
    fi

    dir="$(dirname "$path")"
    base="$(basename "$path")"
    (cd "$dir" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$base")
}

is_manager_source() {
    local source_path="$1"
    local resolved_source resolved_manager

    [[ "$source_path" == "$MANAGER_COMMAND" ]] && return 0
    [[ -e "$source_path" && -e "$MANAGER_COMMAND" ]] || return 1

    resolved_source="$(resolve_existing_path "$source_path" 2>/dev/null || true)"
    resolved_manager="$(resolve_existing_path "$MANAGER_COMMAND" 2>/dev/null || true)"
    [[ -n "$resolved_source" && "$resolved_source" == "$resolved_manager" ]]
}

ensure_command_link() {
    local target="$1"
    local link_path="$2"
    local link_dir existing_target

    link_dir="$(dirname "$link_path")"
    [[ -d "$link_dir" ]] || return 0

    if [[ -e "$link_path" || -L "$link_path" ]]; then
        [[ -L "$link_path" ]] || return 0
        existing_target="$(readlink "$link_path" 2>/dev/null || true)"
        [[ "$existing_target" == "$target" ]] && return 0
        [[ -n "$existing_target" && -e "$existing_target" ]] && manager_script_valid "$existing_target" && return 0
        rm -f "$link_path" 2>/dev/null || return 0
    fi

    ln -sf "$target" "$link_path" 2>/dev/null || true
}

remove_manager_link() {
    local link_path="$1"
    local target="$2"

    if [[ -L "$link_path" ]]; then
        [[ "$(readlink "$link_path" 2>/dev/null)" == "$target" ]] && rm -f "$link_path"
        return 0
    fi

    [[ "$link_path" == "$target" ]] && rm -f "$link_path"
}

manager_script_valid() {
    local script_path="$1"
    [[ -f "$script_path" && -s "$script_path" ]] || return 1
    grep -q '^SCRIPT_VERSION=' "$script_path" 2>/dev/null || return 1
    grep -q 'main "$@"' "$script_path" 2>/dev/null || return 1
    bash -n "$script_path" || return 1
    if [[ -e "$SBM_STATE_DIR/engine.json" || -e "$SBM_STATE_DIR/pending.json" ]]; then
        grep -qx 'SBM_STATE_SCHEMA_MIN=1' "$script_path" || return 1
        grep -qx 'SBM_STATE_SCHEMA_MAX=1' "$script_path" || return 1
        grep -qx 'SBM_PENDING_RECOVERY=1' "$script_path" || return 1
    fi
    return 0
}

install_manager_from_file() {
    local source_path="$1"
    if [[ "${SBM_LOCK_HELD:-}" != "$BASHPID" && "${SBM_TEST_MODE:-}" != 1 ]]; then
        sbm_with_lock install_manager_from_file "$source_path"
        return $?
    fi

    manager_script_valid "$source_path" || return 1
    mkdir -p "$(dirname "$MANAGER_COMMAND")" 2>/dev/null || return 1

    local staged
    staged=$(mktemp "${MANAGER_COMMAND}.new.XXXXXX") || return 1
    if ! cp "$source_path" "$staged" || ! chmod 755 "$staged" || ! manager_script_valid "$staged"; then
        rm -f "$staged"; return 1
    fi
    if [[ -f "$MANAGER_COMMAND" ]] && manager_script_valid "$MANAGER_COMMAND"; then
        cp -p "$MANAGER_COMMAND" "${MANAGER_COMMAND}.previous" || { rm -f "$staged"; return 1; }
    fi
    mv -f "$staged" "$MANAGER_COMMAND" || { rm -f "$staged"; return 1; }

    manager_script_valid "$MANAGER_COMMAND" || return 1
    chmod +x "$MANAGER_COMMAND" 2>/dev/null || true
    ensure_command_aliases
    hash -r 2>/dev/null || true
    return 0
}

download_manager_command() {
    local tmp_file result=0
    tmp_file=$(mktemp) || return 1
    if engine_python manager-download "$tmp_file" && manager_script_valid "$tmp_file"; then
        install_manager_from_file "$tmp_file" || result=$?
    else result=1; fi
    rm -f "$tmp_file"
    return "$result"
}

install_manager_command() {
    if [[ "${SBM_LOCK_HELD:-}" != "$BASHPID" && "${SBM_TEST_MODE:-}" != 1 ]]; then
        sbm_with_lock install_manager_command
        return $?
    fi
    is_manager_source "${BASH_SOURCE[0]:-}" && {
        ensure_command_aliases
        return 0
    }

    local source_path
    source_path="${BASH_SOURCE[0]:-}"
    install_manager_from_file "$source_path" 2>/dev/null && return 0
    download_manager_command && return 0

    warn "未能安装 sbm 命令，当前安装流程继续；请稍后重新执行在线安装命令修复"
    return 0
}
