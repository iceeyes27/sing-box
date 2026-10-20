#!/usr/bin/env bash
# 用 SagerNet 官方 release 的 musl 包刷新 vendor/sing-box/，并同步脚本内置版本号。
# 用法: scripts/update-vendored-singbox.sh [版本号，默认取最新正式版]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="${ROOT_DIR}/vendor/sing-box"
ARCHES=(amd64 arm64 armv7 386)

version="${1:-}"
if [[ -z "$version" ]]; then
    version=$(curl -fsSL --connect-timeout 10 --max-time 30 \
        https://api.github.com/repos/SagerNet/sing-box/releases/latest \
        | awk -F'"' '/"tag_name"/ { gsub(/^v/, "", $4); print $4; exit }')
fi
version="${version#v}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "invalid sing-box version: ${version:-<empty>}" >&2
    exit 1
}

if [[ "$(cat "${VENDOR_DIR}/VERSION" 2>/dev/null || true)" == "$version" && "${FORCE:-0}" != "1" ]]; then
    echo "vendor/sing-box is already v${version}; set FORCE=1 to re-download"
    exit 0
fi

stage_dir=$(mktemp -d)
trap 'rm -rf "$stage_dir"' EXIT

for arch in "${ARCHES[@]}"; do
    name="sing-box-${version}-linux-${arch}-musl"
    echo "downloading ${name}.tar.gz"
    curl -fL --retry 3 --connect-timeout 15 -o "${stage_dir}/${name}.tar.gz" \
        "https://github.com/SagerNet/sing-box/releases/download/v${version}/${name}.tar.gz"
    tar -tzf "${stage_dir}/${name}.tar.gz" "${name}/sing-box" >/dev/null
done

mkdir -p "$VENDOR_DIR"
rm -f "${VENDOR_DIR}"/sing-box-*-linux-*-musl.tar.gz
mv "${stage_dir}"/*.tar.gz "$VENDOR_DIR"/
printf '%s\n' "$version" > "${VENDOR_DIR}/VERSION"
sed -i "s/^VENDORED_SINGBOX_VERSION=\".*\"/VENDORED_SINGBOX_VERSION=\"${version}\"/" "${ROOT_DIR}/src/01-core.sh"
bash "${ROOT_DIR}/scripts/build-install.sh"
bash "${ROOT_DIR}/scripts/checksum.sh" >/dev/null

echo "vendor/sing-box updated to v${version}"
