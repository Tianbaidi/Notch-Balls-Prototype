#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/icon-tools assets/app-icon-v2
xcrun swiftc -module-cache-path /private/tmp/notch-balls-swift-cache scripts/build-icon.swift -o build/icon-tools/build-icon
build/icon-tools/build-icon assets/app-icon-v2/preview.png assets/app-icon-v2/AppIcon.png
NB_ICON_WORK="$(mktemp -d /private/tmp/notch-icon.XXXXXX)"
trap 'rm -rf "$NB_ICON_WORK"' EXIT
mkdir -p "$NB_ICON_WORK/AppIcon.iconset"
for NB_ICON_POINTS in 16 32 128 256 512; do
    for NB_ICON_SCALE in 1 2; do
        NB_ICON_SUFFIX=''
        [[ "$NB_ICON_SCALE" == 2 ]] && NB_ICON_SUFFIX='@2x'
        NB_ICON_PIXELS=$((NB_ICON_POINTS * NB_ICON_SCALE))
        sips -z "$NB_ICON_PIXELS" "$NB_ICON_PIXELS" assets/app-icon-v2/AppIcon.png \
            --out "$NB_ICON_WORK/AppIcon.iconset/icon_${NB_ICON_POINTS}x${NB_ICON_POINTS}${NB_ICON_SUFFIX}.png" >/dev/null
    done
done
iconutil -c icns "$NB_ICON_WORK/AppIcon.iconset" -o assets/app-icon-v2/AppIcon.icns
echo 'Built assets/app-icon-v2/AppIcon.icns'
