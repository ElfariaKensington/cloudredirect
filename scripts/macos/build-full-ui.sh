#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEST="${1:-$ROOT/out/full-ui}"
"$ROOT/scripts/macos/build.sh" "$DEST"
QT_PREFIX="${QT_PREFIX:-$(brew --prefix qt)}"
cmake -S "$ROOT/ui-macos/qt" -B "$ROOT/build-macos-ui" -DCMAKE_PREFIX_PATH="$QT_PREFIX" -DCMAKE_BUILD_TYPE=Release
cmake --build "$ROOT/build-macos-ui" --parallel 6
APP="$(cd "$DEST" && pwd)/CloudRedirect.app"
cp "$APP/Contents/MacOS/CloudRedirect" "$APP/Contents/Resources/CloudRedirectNative"
cp "$ROOT/build-macos-ui/bin/CloudRedirect" "$APP/Contents/MacOS/CloudRedirect"
# Stage the declarative modules directly. Homebrew's merged QML directory
# also contains unrelated WebEngine/3D/PDF modules, which must not be bundled.
QML_SOURCE="$(brew --prefix qtdeclarative)/share/qt/qml"
python3 "$ROOT/scripts/macos/stage-qml.py" "$QML_SOURCE" "$APP/Contents/Resources/qml"
/usr/bin/ditto "$ROOT/licenses" "$APP/Contents/Resources/licenses"
EXTRA=()
while IFS= read -r -d '' plugin; do EXTRA+=("-executable=$plugin"); done < <(find "$APP/Contents/Resources/qml" -name '*.dylib' -type f -print0)
"$QT_PREFIX/bin/macdeployqt" "$APP" "${EXTRA[@]}" -always-overwrite -libpath="$QT_PREFIX/lib" -codesign=-

codesign --force --sign - "$APP/Contents/Resources/CloudRedirectNative"
codesign --force --sign - "$APP/Contents/Resources/runtime/cloud_redirect.dylib"
codesign --force --sign - "$APP/Contents/Resources/runtime/cloud_redirect_cli"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
ditto -c -k --keepParent "$APP" "$(cd "$DEST" && pwd)/CloudRedirect-macOS-arm64.zip"
