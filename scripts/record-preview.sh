#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TASK_RECORDING=$(mktemp -d /tmp/lidscape-recording.XXXXXX)
trap 'rm -rf "$TASK_RECORDING"' EXIT
mkdir -p docs/images
sed '/@main struct LidscapeApp/,$d' Sources/Lidscape.swift > "$TASK_RECORDING/Support.swift"
swiftc -O -parse-as-library -module-cache-path "$TASK_RECORDING/cache" "$TASK_RECORDING/Support.swift" scripts/render-preview.swift -o "$TASK_RECORDING/record"
"$TASK_RECORDING/record" "$TASK_RECORDING"
ffmpeg -hide_banner -loglevel error -y -framerate 25 -i "$TASK_RECORDING/%04d.png" -filter_complex '[0:v]split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a' -loop 0 docs/images/preview.gif
