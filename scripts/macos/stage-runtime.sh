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
if [ -d "$APP" ]; then rm -rf "$APP"; fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/runtime"
cp "$ROOT/ui-macos/.build/release/CloudRedirect" "$APP/Contents/Resources/CloudRedirectNative"
cp "$ROOT/build-macos/cloud_redirect_credentials" "$APP/Contents/Resources/runtime/"
codesign --force --sign - "$APP/Contents/Resources/runtime/cloud_redirect_credentials"
cp "$ROOT/build-macos/cloud760_tool" "$APP/Contents/Resources/runtime/"
codesign --force --sign - "$APP/Contents/Resources/runtime/cloud760_tool"
cp "$ROOT/build-macos/cloud_redirect.dylib" "$ROOT/build-macos/cloud_redirect_cli" "$APP/Contents/Resources/runtime/"
ICONSET="$ROOT/build-macos/CloudRedirect.iconset"
mkdir -p "$ICONSET"
ICON_SOURCE="$ROOT/ui-macos/assets/CloudRedirect-icon.png"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
done
for size in 16 32 128 256 512; do
    double=$((size * 2))
    sips -z "$double" "$double" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/CloudRedirect.icns"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
mkdir -p "$APP/Contents/Resources/licenses"
cp "$ROOT/licenses/Dobby-Apache-2.0.txt" "$APP/Contents/Resources/licenses/"
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
codesign --force --sign - "$APP/Contents/Resources/CloudRedirectNative"
