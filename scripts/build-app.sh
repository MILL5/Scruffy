#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP="$PWD/dist/Scruffy.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Helpers"
cp .build/release/Scruffy "$APP/Contents/MacOS/Scruffy"
cp .build/release/ScruffyStorageHelper "$APP/Contents/Helpers/ScruffyStorageHelper"
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
<key>CFBundleShortVersionString</key><string>0.3.2</string>
<key>CFBundleVersion</key><string>5</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSMultipleInstancesProhibited</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSDownloadsFolderUsageDescription</key><string>Scruffy reviews your downloads for old and duplicate files. Nothing is removed without your selection and confirmation.</string>
<key>NSDocumentsFolderUsageDescription</key><string>Scruffy scans folders you choose for duplicate and large files.</string>
<key>NSDesktopFolderUsageDescription</key><string>Scruffy scans folders you choose for duplicate and large files.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP/Contents/Helpers/ScruffyStorageHelper"
codesign --force --sign - "$APP"
printf 'Built %s\n' "$APP"
