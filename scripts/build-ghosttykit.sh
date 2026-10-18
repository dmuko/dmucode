#!/usr/bin/env bash
# Builds GhosttyKit.xcframework (and Ghostty's resources) from the
# vendor/ghostty submodule.
#
# Ghostty requires an exact Zig minor version (0.16.x as of Oct 2026). The
# Homebrew keg `zig@0.16` is used when installed; set ZIG=/path/to/zig to
# override.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f vendor/ghostty/build.zig ]; then
  git submodule update --init vendor/ghostty
fi

zig="${ZIG:-}"
if [ -z "$zig" ]; then
  for candidate in /opt/homebrew/opt/zig@0.16/bin/zig /usr/local/opt/zig@0.16/bin/zig zig; do
    if command -v "$candidate" >/dev/null 2>&1; then
      zig="$candidate"
      break
    fi
  done
fi
echo "Using $zig ($("$zig" version))"

cd vendor/ghostty
"$zig" build \
  -Doptimize=ReleaseFast \
  -Demit-xcframework=true \
  -Dxcframework-target=native \
  -Demit-macos-app=false
