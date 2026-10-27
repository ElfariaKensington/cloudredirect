#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
destination="${1:-$root/outputs/native}"
"$root/scripts/macos/stage-runtime.sh" "$destination"
swift build --package-path "$root/ui-macos/swift-app" -c release
app="$(cd "$destination" && pwd)/CloudRedirect.app"
cp "$root/ui-macos/swift-app/.build/release/CloudRedirectSwift" "$app/Contents/MacOS/CloudRedirect"
xcrun actool --compile "$app/Contents/Resources" --platform macosx --minimum-deployment-target 15 "$root/ui-macos/swift-app/Assets.xcassets"
/usr/libexec/PlistBuddy -c 'Add :NSAccentColorName string AccentColor' "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
python3 "$root/scripts/macos/validate-bundle.py" "$app"
echo "Built $app"
