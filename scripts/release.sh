#!/bin/bash
# Builds a Developer ID-signed Scruffy.dmg with a drag-to-Applications layout.
#   scripts/release.sh             build, sign, notarize, staple, verify
#   scripts/release.sh --publish   also create the GitHub release for the built version
# NOTARY_PROFILE names a notarytool Keychain profile. Create one with:
#   xcrun notarytool store-credentials ScruffyNotarize --team-id FS6453639M
# NOTARIZE=0 skips notarization; Gatekeeper then blocks the download until the user allows it.
set -euo pipefail
cd "$(dirname "$0")/.."
IDENTITY="${SCRUFFY_SIGN_IDENTITY:-Developer ID Application: MILL5, LLC (FS6453639M)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-ScruffyNotarize}"
OUT="$PWD/dist/release"
APP="$OUT/Scruffy.app"
DMG="$OUT/Scruffy.dmg"

rm -rf "$OUT"; mkdir -p "$OUT"
SCRUFFY_APP_PATH="$APP" SCRUFFY_SIGN_IDENTITY="$IDENTITY" ./scripts/build-app.sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
codesign --verify --deep --strict --verbose "$APP"
codesign -dvv "$APP" 2>&1 | grep -F "Authority=$IDENTITY"

swift scripts/make-dmg-background.swift "$OUT/dmg-background.png"
STAGE=$(mktemp -d); trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
create-dmg --volname "Scruffy" --background "$OUT/dmg-background.png" --window-pos 200 120 --window-size 660 400 \
    --icon-size 100 --icon "Scruffy.app" 175 190 --app-drop-link 485 190 --text-size 14 --no-internet-enable \
    "$DMG" "$STAGE"
codesign --sign "$IDENTITY" --timestamp "$DMG"
codesign --verify --strict --verbose "$DMG"

if [[ "${NOTARIZE:-1}" == 1 ]]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 15m
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
    NOTE="Signed with Developer ID and notarized by Apple."
else
    NOTE="Signed with Developer ID. Not notarized: macOS will ask you to allow it in System Settings > Privacy & Security."
fi
(cd "$OUT" && shasum -a 256 Scruffy.dmg > SHA256SUMS)
printf 'Built %s (%s)\n%s\n' "$DMG" "$VERSION" "$NOTE"

if [[ "${1:-}" == "--publish" ]]; then
    NOTES="docs/releases/$VERSION.md"
    test -f "$NOTES"
    { cat "$NOTES"; printf '\n%s Requires macOS 26 or later on a Mac with Apple silicon.\n' "$NOTE"; } > "$OUT/notes.md"
    gh release create "v$VERSION" "$DMG" "$OUT/SHA256SUMS" --target main --title "Scruffy $VERSION" --notes-file "$OUT/notes.md"
fi
