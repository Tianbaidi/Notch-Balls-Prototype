#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
export NB_INFO_PATH="$(mktemp /private/tmp/notch-build-info.XXXXXX)"
trap 'rm -f "$NB_INFO_PATH"' EXIT
python3 - <<'PY'
import os
import base64
import re
import plistlib
from pathlib import Path
from urllib.parse import urlparse
from urllib.request import urlopen
from xml.etree import ElementTree

feed = os.environ.get("SU_FEED_URL", "")
key = os.environ.get("SU_PUBLIC_ED_KEY", "")
if os.environ.get("ENABLE_UPDATES", "1") != "0":
    with Path("UpdateConfig.plist").open("rb") as handle:
        config = plistlib.load(handle)
    feed = feed or config["SUFeedURL"]
    key = key or config["SUPublicEDKey"]
if bool(feed) != bool(key):
    raise SystemExit("Set both SU_FEED_URL and SU_PUBLIC_ED_KEY, or neither.")
if feed:
    if len(base64.b64decode(key, validate=True)) != 32:
        raise SystemExit("SUPublicEDKey must be an Ed25519 public key")
    parsed = urlparse(feed)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        raise SystemExit("SU_FEED_URL must be a public HTTPS URL.")
    if os.environ.get("VERIFY_UPDATE_FEED") == "1":
        try:
            with urlopen(feed, timeout=15) as response:
                appcast = response.read(5_000_001)
            if len(appcast) > 5_000_000 or ElementTree.fromstring(appcast).tag != "rss":
                raise ValueError("Invalid Sparkle appcast")
        except Exception as error:
            raise SystemExit(f"Update feed is not published or invalid: {error}")
with Path("Info.plist").open("rb") as handle:
    info = plistlib.load(handle)
for field, variable in (("CFBundleShortVersionString", "APP_VERSION"), ("CFBundleVersion", "APP_BUILD")):
    if os.environ.get(variable):
        info[field] = os.environ[variable]
if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", info["CFBundleShortVersionString"]):
    raise SystemExit("APP_VERSION must be numeric (e.g. 0.36)")
if not re.fullmatch(r"[1-9][0-9]*", info["CFBundleVersion"]):
    raise SystemExit("APP_BUILD must be a positive, increasing integer")
info["LSMinimumSystemVersion"] = "14.0"
info["NBReleaseMode"] = os.environ.get("RELEASE_MODE", "development")
info["SUVerifyUpdateBeforeExtraction"] = True
info["SUAutomaticallyUpdate"] = False
info.pop("SUFeedURL", None)
info.pop("SUPublicEDKey", None)
if feed:
    info["SUFeedURL"] = feed
    info["SUPublicEDKey"] = key
with Path(os.environ["NB_INFO_PATH"]).open("wb") as handle:
    plistlib.dump(info, handle)
PY
# Build into a clean temporary bundle, never package local application data.
export NB_BUILD_DIR="$(mktemp -d /private/tmp/notch-build.XXXXXX)"
trap 'rm -f "$NB_INFO_PATH"; rm -rf "$NB_BUILD_DIR"' EXIT
APP="$NB_BUILD_DIR/Notch Balls Prototype.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
python3 generate_noise.py
CLANG_MODULE_CACHE_PATH=/private/tmp/notch-balls-clang-cache SWIFT_MODULE_CACHE_PATH=/private/tmp/notch-balls-swift-cache xcrun swiftc -target arm64-apple-macosx14.0 -O main.swift Timeline.swift Experience.swift Pomodoro.swift FocusStats.swift SystemApps.swift NowPlaying.swift LyricsSources.swift ArtistAliases.swift DockPlacement.swift -o "$APP/Contents/MacOS/NotchBalls" -F vendor -framework Sparkle -framework AppKit -framework AVFoundation -lsqlite3 -Xlinker -rpath -Xlinker '@executable_path/../Frameworks'
cp "$NB_INFO_PATH" "$APP/Contents/Info.plist"
ditto vendor/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"
cp scene.json now-playing.jxa white-noise.wav deep-noise.wav audio/rain.wav audio/ocean.wav audio/stream.wav "$APP/Contents/Resources/"
cp audio/CREDITS.md "$APP/Contents/Resources/AUDIO-CREDITS.md"
./scripts/sign-app.sh "$APP"
# Only replace the known build output after compilation and signing succeed.
NB_OUTPUT_APP='Notch Balls Prototype.app'
if [[ "${BUILD_PREVIEW:-0}" == "1" ]]; then
    mkdir -p build
    NB_OUTPUT_APP='build/Notch Balls Prototype Preview.app'
fi
rm -rf "$NB_OUTPUT_APP"
ditto "$APP" "$NB_OUTPUT_APP"
echo "Built $NB_OUTPUT_APP (arm64, macOS 14.0+)"
