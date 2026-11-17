#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_FILE="${1:-${ROOT_DIR}/install.sh}"
SRC_DIR="${ROOT_DIR}/src"

modules=(
    00-header.sh
    01-core.sh
    01-system.sh
    01-network.sh
    01-params.sh
    01-engine.sh
    01-manager.sh
    02-install.sh
    02-upgrade.sh
    03-config.sh
    04-argo-subscription.sh
    05-links.sh
    05-verify.sh
    05-doctor.sh
    06-install.sh
    06-modify.sh
    06-actions.sh
    07-menu.sh
)

tmp_file=$(mktemp "${OUT_FILE}.XXXXXX")
cleanup() {
    rm -f "$tmp_file"
}
trap cleanup EXIT

: > "$tmp_file"
for module in "${modules[@]}"; do
    path="${SRC_DIR}/${module}"
    [[ -f "$path" ]] || {
        echo "missing source module: ${path}" >&2
        exit 1
    }
    if [[ "$module" == 01-engine.sh ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" == '# @SBM_ENGINE_PYTHON@' ]]; then
                cat "${SRC_DIR}/engine.py" >> "$tmp_file"
            else
                printf '%s\n' "$line" >> "$tmp_file"
            fi
        done < "$path"
    else
        cat "$path" >> "$tmp_file"
    fi
done

chmod +x "$tmp_file"
mv "$tmp_file" "$OUT_FILE"
trap - EXIT
