#!/bin/zsh
set -e
cd "${0:A:h}"
export NB_INFO_PATH="$(mktemp /private/tmp/notch-build-info.XXXXXX)"
trap 'rm -f "$NB_INFO_PATH"' EXIT
python3 - <<'PY'
import os
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
if feed:
    info["SUFeedURL"] = feed
    info["SUPublicEDKey"] = key
with Path(os.environ["NB_INFO_PATH"]).open("wb") as handle:
    plistlib.dump(info, handle)
PY
mkdir -p 'Notch Balls Prototype.app/Contents/MacOS' 'Notch Balls Prototype.app/Contents/Resources'
mkdir -p 'Notch Balls Prototype.app/Contents/Frameworks'
python3 generate_noise.py
CLANG_MODULE_CACHE_PATH=/private/tmp/notch-balls-clang-cache SWIFT_MODULE_CACHE_PATH=/private/tmp/notch-balls-swift-cache xcrun swiftc main.swift Pomodoro.swift FocusStats.swift SystemApps.swift NowPlaying.swift LyricsSources.swift ArtistAliases.swift DockPlacement.swift -o 'Notch Balls Prototype.app/Contents/MacOS/NotchBalls' -F vendor -framework Sparkle -framework AppKit -framework AVFoundation -lsqlite3 -Xlinker -rpath -Xlinker '@executable_path/../Frameworks'
cp "$NB_INFO_PATH" 'Notch Balls Prototype.app/Contents/Info.plist'
rm -rf 'Notch Balls Prototype.app/Contents/Frameworks/Sparkle.framework'
ditto vendor/Sparkle.framework 'Notch Balls Prototype.app/Contents/Frameworks/Sparkle.framework'
cp scene.json 'Notch Balls Prototype.app/Contents/Resources/scene.json'
cp now-playing.jxa 'Notch Balls Prototype.app/Contents/Resources/now-playing.jxa'
cp white-noise.wav 'Notch Balls Prototype.app/Contents/Resources/white-noise.wav'
cp deep-noise.wav 'Notch Balls Prototype.app/Contents/Resources/deep-noise.wav'
cp audio/rain.wav audio/ocean.wav audio/stream.wav 'Notch Balls Prototype.app/Contents/Resources/'
cp audio/CREDITS.md 'Notch Balls Prototype.app/Contents/Resources/AUDIO-CREDITS.md'
codesign --force --deep --sign - 'Notch Balls Prototype.app'
echo 'Built Notch Balls Prototype.app'
