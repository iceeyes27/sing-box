#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_FILE="${1:-${ROOT_DIR}/install.sh}"
SRC_DIR="${ROOT_DIR}/src"

modules=(
    00-header.sh
    01-core.sh
    02-install.sh
    03-config.sh
    04-argo-subscription.sh
    05-links.sh
    06-actions-menu.sh
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
    cat "$path" >> "$tmp_file"
done

chmod +x "$tmp_file"
mv "$tmp_file" "$OUT_FILE"
trap - EXIT
