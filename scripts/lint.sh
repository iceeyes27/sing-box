#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v shellcheck >/dev/null 2>&1; then
    echo "shellcheck not installed; skipped" >&2
    exit 0
fi

# install.sh is generated from src/, so lint the generated release artifact plus tests/tooling.
# Use error-level gating first; warning-level cleanup can be tightened once legacy findings are triaged.
shellcheck -S error install.sh tests/regression.sh scripts/*.sh
