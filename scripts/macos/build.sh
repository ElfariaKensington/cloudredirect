#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEST="${1:-$ROOT/out}"
mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd)"
cmake -S "$ROOT" -B "$ROOT/build-macos" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64
cmake --build "$ROOT/build-macos" --parallel 6
ctest --test-dir "$ROOT/build-macos" --output-on-failure
swift build --package-path "$ROOT/ui-macos" -c release
APP="$DEST/CloudRedirect.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/runtime"
cp "$ROOT/ui-macos/.build/release/CloudRedirect" "$APP/Contents/MacOS/CloudRedirect"
cp "$ROOT/build-macos/cloud_redirect.dylib" "$ROOT/build-macos/cloud_redirect_cli" "$APP/Contents/Resources/runtime/"
ICONSET="$ROOT/build-macos/CloudRedirect.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    cp "$ROOT/flatpak/icons/${size}x${size}/apps/cloudredirect.png" "$ICONSET/icon_${size}x${size}.png"
done
for size in 16 32 128 256; do
    double=$((size * 2))
    cp "$ROOT/flatpak/icons/${double}x${double}/apps/cloudredirect.png" "$ICONSET/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/CloudRedirect.icns"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
cp "$ROOT/UPSTREAM.md" "$APP/Contents/Resources/UPSTREAM.md"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.elfariakensington.cloudredirect</string>
<key>CFBundleIconFile</key><string>CloudRedirect.icns</string>
<key>CFBundleName</key><string>CloudRedirect</string>
<key>CFBundleDisplayName</key><string>CloudRedirect</string>
<key>CFBundleExecutable</key><string>CloudRedirect</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP/Contents/Resources/runtime/cloud_redirect.dylib"
codesign --force --sign - "$APP/Contents/Resources/runtime/cloud_redirect_cli"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
ditto -c -k --keepParent "$APP" "$DEST/CloudRedirect-macOS-arm64.zip"
echo "Built $APP"
