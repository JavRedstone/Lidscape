#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TASK_ICON=$(mktemp -d /tmp/lidscape-icon.XXXXXX)
trap 'rm -rf "$TASK_ICON"' EXIT
sed '/@main struct LidscapeApp/,$d' Sources/Lidscape.swift > "$TASK_ICON/Support.swift"
swiftc -O -parse-as-library -module-cache-path "$TASK_ICON/cache" "$TASK_ICON/Support.swift" scripts/render-icon.swift -o "$TASK_ICON/render"
"$TASK_ICON/render"
