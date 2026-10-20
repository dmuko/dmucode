#!/usr/bin/env bash
# Builds a signed and notarized dmucode for direct distribution (outside the
# App Store): build/release/dmucode-<version>.dmg.
#
# Needs a "Developer ID Application" certificate in the keychain and a
# notarytool keychain profile, stored once with:
#   xcrun notarytool store-credentials dmucode --apple-id <apple id> --team-id <team id>
# IDENTITY and NOTARY_PROFILE override the defaults below.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

identity="${IDENTITY:-Developer ID Application}"
profile="${NOTARY_PROFILE:-dmucode}"

# Submits a file for notarization and waits; prints Apple's log if rejected.
notarize() {
    local file="$1" result id status
    echo "Notarizing $(basename "$file")…"
    result="$(xcrun notarytool submit "$file" --keychain-profile "$profile" --wait --output-format json)"
    id="$(plutil -extract id raw - <<<"$result")"
    status="$(plutil -extract status raw - <<<"$result")"
    if [[ "$status" != "Accepted" ]]; then
        echo "Notarization $status ($id):" >&2
        xcrun notarytool log "$id" --keychain-profile "$profile" >&2 || true
        exit 1
    fi
}

./scripts/build-app.sh
app="build/dmucode.app"
version="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")"
out="build/release"
rm -rf "$out"
mkdir -p "$out"

# Hardened runtime and a secure timestamp are required for notarization.
codesign --force --options runtime --timestamp \
    --entitlements Resources/dmucode.entitlements --sign "$identity" "$app"
codesign --verify --strict --verbose=2 "$app"

# Notarize the app itself and staple its ticket, so it passes Gatekeeper
# offline too once copied out of the disk image. An unchanged app that was
# notarized before (e.g. by a run that failed later) already has a ticket.
if xcrun stapler staple -q "$app" 2>/dev/null; then
    echo "App already notarized; stapled its ticket."
else
    ditto -c -k --keepParent "$app" "$out/dmucode.zip"
    notarize "$out/dmucode.zip"
    xcrun stapler staple "$app"
    rm "$out/dmucode.zip"
fi

# The disk image: the app and a link to /Applications.
dmg="$out/dmucode-$version.dmg"
staging="$out/staging"
mkdir -p "$staging"
ditto "$app" "$staging/dmucode.app"
ln -s /Applications "$staging/Applications"
hdiutil create -quiet -volname "dmucode $version" -srcfolder "$staging" -format UDZO "$dmg"
rm -rf "$staging"
codesign --force --timestamp --sign "$identity" "$dmg"
notarize "$dmg"
xcrun stapler staple "$dmg"

spctl --assess --type execute --verbose "$app"
spctl --assess --type open --context context:primary-signature --verbose "$dmg"
echo "Built $dmg"
