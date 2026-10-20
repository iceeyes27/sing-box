#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v shellcheck >/dev/null 2>&1; then
    echo "shellcheck not installed; skipped" >&2
    exit 0
fi

# install.sh is generated from src/, so lint the generated release artifact plus tests/tooling.
# Warning-level findings fail the build; silence intentional patterns with inline directives.
shellcheck -S warning install.sh tests/regression.sh tests/protocol-integration.sh scripts/*.sh
