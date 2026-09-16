#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${LIDSCAPE_VERSION:-0.1.0}"
BUILD_NUMBER="${LIDSCAPE_BUILD_NUMBER:-1}"
if [[ ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
    echo "Expected LIDSCAPE_VERSION=x.y.z and a positive LIDSCAPE_BUILD_NUMBER" >&2
    exit 1
fi
APP="$PWD/build/Lidscape.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" build/module-cache
swiftc -parse-as-library -O -module-cache-path "$PWD/build/module-cache" -target arm64-apple-macos14.0 Sources/Lidscape.swift -o "$APP/Contents/MacOS/Lidscape"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Lidscape</string>
<key>CFBundleIdentifier</key><string>local.macfold.app</string>
<key>CFBundleName</key><string>Lidscape</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSScreenCaptureUsageDescription</key><string>Lidscape captures your desktop to animate it as you fold the lid. Captures stay in memory.</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources/Models"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
for asset in Resources/Models/*.usdz; do
    [[ -f "$asset" ]] || continue
    cp "$asset" "$APP/Contents/Resources/Models/"
done
mkdir -p "$APP/Contents/Resources/Wallpapers"
for wallpaper in Resources/Wallpapers/*.png; do
    [[ -f "$wallpaper" ]] || continue
    cp "$wallpaper" "$APP/Contents/Resources/Wallpapers/"
done
# Preserve the existing bundle identifier so upgrades retain their app identity.
# Prefer a supplied ICNS; otherwise generate all standard sizes from a square PNG.
ICON_SOURCE="$PWD/Resources/AppIcon"
ICON_DEST="$APP/Contents/Resources/AppIcon.icns"
rm -f "$ICON_DEST"
if [[ -f "$ICON_SOURCE/AppIcon.icns" ]]; then
    cp "$ICON_SOURCE/AppIcon.icns" "$ICON_DEST"
elif [[ -f "$ICON_SOURCE/AppIcon.png" ]]; then
    ICONSET="$PWD/build/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" "$ICON_SOURCE/AppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z "$double" "$double" "$ICON_SOURCE/AppIcon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$ICON_DEST"
fi
if [[ -f "$ICON_DEST" ]]; then
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon' "$APP/Contents/Info.plist"
fi
# Prefer a stable development identity so rebuilds retain their signing identity.
SIGN_IDENTITY="${LIDSCAPE_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning | awk '/"Apple Development:/ { print $2; exit }')
fi
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"
