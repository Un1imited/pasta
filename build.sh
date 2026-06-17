#!/bin/bash
# 构建 Pasta 并打包成 Pasta.app（菜单栏 App）。
set -euo pipefail
cd "$(dirname "$0")"

APP="Pasta.app"
BIN_NAME="Pasta"

# PASTA_UNIVERSAL=1 时编通用二进制（arm64 + x86_64，兼容 Intel），用于发布
ARCH_FLAGS=()
if [[ "${PASTA_UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
  echo "==> swift build -c release（通用二进制）"
else
  echo "==> swift build -c release"
fi
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}

BIN="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/${BIN_NAME}"
if [[ ! -f "$BIN" ]]; then
  echo "构建产物不存在: $BIN" >&2
  exit 1
fi

echo "==> 组装 ${APP}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/${BIN_NAME}"

# App 图标
if [[ -f "Resources/AppIcon.icns" ]]; then
  cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Pasta</string>
    <key>CFBundleDisplayName</key>     <string>Pasta</string>
    <key>CFBundleIdentifier</key>      <string>com.local.pasta</string>
    <key>CFBundleExecutable</key>      <string>Pasta</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key><string>Local clipboard manager</string>
</dict>
</plist>
PLIST

# 用固定的自签名证书签名：代码身份（DR）跨重建保持稳定，
# 「辅助功能」授权只需给一次，以后重新构建不会再失效。
# 没有该证书的机器自动回退 ad-hoc。
IDENTITY="Pasta Self Signed"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  echo "==> 用证书签名: $IDENTITY"
  codesign --force --deep --sign "$IDENTITY" "$APP" >/dev/null 2>&1 || true
else
  echo "==> 证书不存在，回退 ad-hoc 签名（授权会在重建后失效）"
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
fi

echo "==> 完成: $(pwd)/${APP}"
echo "    运行: open ${APP}"
