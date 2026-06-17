#!/bin/bash
# 打通用二进制 + 压成可发布的 zip（上传 GitHub Release 用）。
# 用法: ./release.sh [版本号]   例: ./release.sh 1.0.0
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-1.0.0}"

# 通用二进制（arm64+x86_64）需完整 Xcode 的 xcbuild；仅命令行工具时退回原生架构。
echo "==> 构建 + 打包 Pasta.app"
if [[ -x "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild" ]]; then
  PASTA_UNIVERSAL=1 ./build.sh
else
  echo "    (未装完整 Xcode，编原生架构；Intel 用户请从源码构建)"
  ./build.sh
fi

echo "==> 架构校验"
lipo -info Pasta.app/Contents/MacOS/Pasta || true

mkdir -p dist
ZIP="dist/Pasta-${VERSION}.zip"
rm -f "$ZIP"
ditto -c -k --keepParent Pasta.app "$ZIP"

echo ""
echo "==> 产物: ${ZIP}"
echo "    大小:   $(du -h "$ZIP" | cut -f1)"
echo "    sha256: $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo ""
echo "下一步："
echo "  1. 把 ${ZIP} 传到 GitHub Release（tag v${VERSION}）"
echo "  2. 用户下载解压后，首次打开需「右键 → 打开」，"
echo "     或执行: xattr -dr com.apple.quarantine Pasta.app"
