#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Apple silicon only. SCRUFFY_SIGN_IDENTITY signs for distribution.
swift build -c release --arch arm64
BIN=$(swift build -c release --arch arm64 --show-bin-path)
APP="${SCRUFFY_APP_PATH:-$PWD/dist/Scruffy.app}"
# Start from an empty bundle so files from an earlier build (old icons, renamed helpers) never ship.
[[ "$APP" == *.app ]] || { echo "SCRUFFY_APP_PATH must end in .app: $APP" >&2; exit 1; }
rm -rf "$APP/Contents"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Helpers"
cp "$BIN/Scruffy" "$APP/Contents/MacOS/Scruffy"
cp "$BIN/ScruffyStorageHelper" "$APP/Contents/Helpers/ScruffyStorageHelper"
cp src/Scruffy/Resources/mill5-logo.png "$APP/Contents/Resources/mill5-logo.png"
cp src/Scruffy/Resources/scruffy-broom.png "$APP/Contents/Resources/scruffy-broom.png"
ICONSET="$PWD/dist/Scruffy.iconset"
mkdir -p "$ICONSET"
swift scripts/make-icon.swift "$PWD/dist/icon.png"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$PWD/dist/icon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$PWD/dist/icon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/ScruffyBright.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Scruffy</string>
<key>CFBundleDisplayName</key><string>Scruffy</string>
<key>CFBundleIdentifier</key><string>com.richcrane.scruffy</string>
<key>CFBundleExecutable</key><string>Scruffy</string>
<key>CFBundleIconFile</key><string>ScruffyBright.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.6.1</string>
<key>CFBundleVersion</key><string>9</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSMultipleInstancesProhibited</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSDownloadsFolderUsageDescription</key><string>Scruffy reviews your downloads for old and duplicate files. Nothing is removed without your selection and confirmation.</string>
<key>NSDocumentsFolderUsageDescription</key><string>Scruffy scans folders you choose for duplicate and large files.</string>
<key>NSDesktopFolderUsageDescription</key><string>Scruffy scans folders you choose for duplicate and large files.</string>
</dict></plist>
PLIST
if [[ -n "${SCRUFFY_SIGN_IDENTITY:-}" ]]; then
    SIGN=(--force --options runtime --timestamp --sign "$SCRUFFY_SIGN_IDENTITY")
else
    SIGN=(--force --sign -)
fi
codesign "${SIGN[@]}" "$APP/Contents/Helpers/ScruffyStorageHelper"
codesign "${SIGN[@]}" "$APP"
printf 'Built %s\n' "$APP"
