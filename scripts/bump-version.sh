#!/usr/bin/env bash
# 一键同步版本号：更新 src/ 与 README，重建 install.sh，刷新 checksum。
# 用法: scripts/bump-version.sh <new-version>   例: scripts/bump-version.sh 2.6.36
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

NEW_VERSION="${1:-}"
if [[ -z "$NEW_VERSION" ]]; then
    echo "用法: $0 <new-version>  (例: $0 2.6.36)" >&2
    exit 1
fi
if [[ ! "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "版本号格式应为 X.Y.Z，收到: ${NEW_VERSION}" >&2
    exit 1
fi

CORE_FILE="src/01-core.sh"
README_FILE="README.md"

CURRENT_VERSION=$(grep -oE '^SCRIPT_VERSION="[^"]+"' "$CORE_FILE" | head -n1 | sed -E 's/^SCRIPT_VERSION="([^"]+)"/\1/')
if [[ -z "$CURRENT_VERSION" ]]; then
    echo "无法从 ${CORE_FILE} 读取当前 SCRIPT_VERSION" >&2
    exit 1
fi

# 权威版本号在 src/01-core.sh；README 面板示例跟随同步。
sed -i -E "s/^SCRIPT_VERSION=\"[^\"]+\"/SCRIPT_VERSION=\"${NEW_VERSION}\"/" "$CORE_FILE"
sed -i -E "s/(sing-box 管理面板  v)${CURRENT_VERSION//./\\.}/\1${NEW_VERSION}/" "$README_FILE"

bash scripts/build-install.sh
bash scripts/checksum.sh

echo "版本号已从 ${CURRENT_VERSION} 同步为 ${NEW_VERSION}（src/、README、install.sh、checksum）"
echo "接下来可执行：make test 后 git commit，push 时再 git tag v${NEW_VERSION}"
