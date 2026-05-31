#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

scripts/build-install.sh
bash -n install.sh
bash -n tests/regression.sh

case "${SBM_SKIP_REGRESSION:-0}" in
    1|true|yes)
        echo "SBM_SKIP_REGRESSION=${SBM_SKIP_REGRESSION}; skipped full regression tests"
        ;;
    *)
        bash tests/regression.sh
        ;;
esac
