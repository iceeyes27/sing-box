#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

mkdir -p dist
if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 install.sh > dist/install.sh.sha256
elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum install.sh > dist/install.sh.sha256
else
    echo "sha256 tool not found" >&2
    exit 1
fi
cat dist/install.sh.sha256
