#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
destination="${1:-$root/out}"
"$root/scripts/macos/build-swift-ui.sh" "$destination"
app="$(cd "$destination" && pwd)/CloudRedirect.app"
ditto -c -k --keepParent "$app" "$(dirname "$app")/CloudRedirect-macOS-arm64.zip"
