#!/usr/bin/env python3
"""Render the actual SwiftUI views with synthetic data, without running AppDelegate."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
output = root / 'build/ui-previews'
output.mkdir(parents=True, exist_ok=True)
files = ['Experience.swift', 'Pomodoro.swift', 'FocusStats.swift', 'SystemApps.swift',
         'NowPlaying.swift', 'LyricsSources.swift', 'ArtistAliases.swift', 'DockPlacement.swift']
source = '\n'.join((root / name).read_text() for name in files)
source += '\n' + (root / 'main.swift').read_text().split('\nlet app = NSApplication.shared')[0]
source += '\n' + (root / 'tests/ui/render.swift').read_text()
with tempfile.TemporaryDirectory(prefix='notch-ui-') as temp:
    entry = Path(temp) / 'main.swift'
    entry.write_text(source)
    binary = Path(temp) / 'render-ui'
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', '/private/tmp/notch-balls-swift-cache',
                    '-target', 'arm64-apple-macosx14.0', str(entry), '-o', str(binary),
                    '-F', str(root / 'vendor'), '-framework', 'Sparkle', '-framework', 'AppKit',
                    '-framework', 'AVFoundation', '-lsqlite3', '-Xlinker', '-rpath', '-Xlinker',
                    str(root / 'vendor')], check=True)
    subprocess.run([str(binary), str(output)], check=True)
print(output)
