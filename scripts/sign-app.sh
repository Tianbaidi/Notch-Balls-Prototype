#!/bin/bash
set -eo pipefail
app="$1"
identity="${CODE_SIGN_IDENTITY:--}"
framework="$app/Contents/Frameworks/Sparkle.framework"
options=(--force --sign "$identity")
if [[ "$identity" != '-' ]]; then
  [[ "$identity" == 'Developer ID Application: '* ]] || { echo 'Developer ID Application identity required' >&2; exit 1; }
  options+=(--options runtime --timestamp)
fi
# Inside out, per Sparkle's manual distribution signing instructions.
for component in XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app; do
  extra=()
  if [[ "$component" == XPCServices/Downloader.xpc ]]; then
    extra+=(--preserve-metadata=entitlements)
  fi
  codesign "${options[@]}" "${extra[@]}" "$framework/Versions/B/$component"
done
codesign "${options[@]}" "$framework"
# Ad-hoc development must not enable hardened runtime library validation.
codesign "${options[@]}" "$app"
codesign --verify --deep --strict "$app"
