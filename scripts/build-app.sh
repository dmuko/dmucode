#!/usr/bin/env bash
# Builds dmucode and wraps it into build/dmucode.app with Ghostty's resources
# (terminfo, shell integration, themes) where libghostty expects them.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

swift build -c release
bin="$(swift build -c release --show-bin-path)/dmucode"

app="build/dmucode.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/dmucode"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp -R vendor/ghostty/zig-out/share/terminfo "$app/Contents/Resources/terminfo"
cp -R vendor/ghostty/zig-out/share/ghostty "$app/Contents/Resources/ghostty"
cp vendor/ghostty/LICENSE "$app/Contents/Resources/LICENSE-ghostty"
codesign --force --sign - "$app" >/dev/null
echo "Built $app"
