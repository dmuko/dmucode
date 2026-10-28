#!/usr/bin/env bash
# Builds GhosttyKit.xcframework (and Ghostty's resources) from the
# vendor/ghostty submodule.
#
# Ghostty requires an exact Zig minor version (0.17.x as of Oct 2026). The
# Homebrew keg `zig@0.17` is used when installed; set ZIG=/path/to/zig to
# override.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f vendor/ghostty/build.zig ]; then
  git submodule update --init vendor/ghostty
fi

zig="${ZIG:-}"
if [ -z "$zig" ]; then
  for candidate in /opt/homebrew/opt/zig@0.17/bin/zig /usr/local/opt/zig@0.17/bin/zig zig; do
    if command -v "$candidate" >/dev/null 2>&1; then
      zig="$candidate"
      break
    fi
  done
fi
if [ -z "$zig" ]; then
  echo "error: zig not found. Install Zig 0.17.x with 'brew install zig@0.17', or set ZIG=/path/to/zig." >&2
  exit 1
fi
zig_version="$("$zig" version)"
echo "Using $zig ($zig_version)"

case "$zig_version" in
  0.17*) ;;
  *)
    echo "error: $zig is Zig $zig_version, but Ghostty needs Zig 0.17.x." >&2
    echo "Install it with 'brew install zig@0.17', or set ZIG=/path/to/zig." >&2
    exit 1
    ;;
esac

cd vendor/ghostty
"$zig" build \
  -Doptimize=ReleaseFast \
  -Demit-xcframework=true \
  -Dxcframework-target=native \
  -Demit-macos-app=false
