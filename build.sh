#!/bin/sh
# Builds CaffeinateCat.app (optimised, universal) into ./build, then optionally signs and notarizes it.
#
#   sh build.sh                                  ad-hoc signed; fine for your own Mac
#   IDENTITY="Developer ID Application: …" sh build.sh
#                                                signed with hardened runtime, ready to notarize
#   IDENTITY="…" NOTARY_PROFILE=<profile> sh build.sh
#                                                also notarizes and staples. Create the profile once
#                                                with `xcrun notarytool store-credentials <profile>`.
set -eu

cd "$(dirname "$0")"

NAME=CaffeinateCat
VERSION=${VERSION:-1.3.0}
BUILD=${BUILD:-3}            # CFBundleVersion: an integer that goes up with every release (Sparkle compares it)
# The already-shipped, notarized 1.2.0 uses this ID. Keep it: Sparkle refuses updates that change it,
# and preferences are stored under it.
BUNDLE_ID=${BUNDLE_ID:-com.mcebrian.caffeinateCat}
IDENTITY=${IDENTITY:--}
NOTARY_PROFILE=${NOTARY_PROFILE:-}
MIN_MACOS=12.0

. tools/sparkle.conf
SU_PUBLIC_ED_KEY=$(tr -d '[:space:]' < tools/sparkle_public_key.txt)
SPARKLE_DIR=$(sh tools/fetch-sparkle.sh)

OUT=build
APP="$OUT/$NAME.app"
rm -rf "$APP" "$OUT/obj"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUT/obj"

echo "▸ Compiling"
for arch in arm64 x86_64; do
    swiftc -O -whole-module-optimization \
        -target "$arch-apple-macos$MIN_MACOS" \
        -F "$SPARKLE_DIR" -framework Sparkle \
        -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
        -o "$OUT/obj/$NAME-$arch" ./*.swift
done
lipo -create -output "$APP/Contents/MacOS/$NAME" "$OUT/obj/$NAME-arm64" "$OUT/obj/$NAME-x86_64"

echo "▸ Sparkle $SPARKLE_VERSION"
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
# Not sandboxed, so Sparkle's XPC helpers are unnecessary. Remove the real folder and the symlink to it.
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
       "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"

echo "▸ Icon"
ICONSET="$OUT/obj/$NAME.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256; do
    sips -z $size $size docs/assets/icon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    [ $double -le 256 ] && sips -z $double $double docs/assets/icon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/$NAME.icns"

ATS=""
case "$FEED_URL" in
    http://*) ATS="<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>" ;;
esac

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$NAME</string>
    <key>CFBundleIconFile</key><string>$NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>© 2026 Prem Poddar · Noxdrop Systems</string>
    <key>SUFeedURL</key><string>$FEED_URL</string>
    <key>SUPublicEDKey</key><string>$SU_PUBLIC_ED_KEY</string>
    <key>SUEnableAutomaticChecks</key><true/>
    $ATS
</dict>
</plist>
EOF

echo "▸ Signing ($IDENTITY)"
sign() {
    if [ "$IDENTITY" = "-" ]; then
        codesign --force --sign - "$@"
    else
        codesign --force --options runtime --timestamp --sign "$IDENTITY" "$@"
    fi
}
# Inside-out, no --deep: Sparkle's helpers, then the framework, then the app.
FW="$APP/Contents/Frameworks/Sparkle.framework"
sign "$FW/Versions/B/Autoupdate"
sign "$FW/Versions/B/Updater.app"
sign "$FW"
sign "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

if [ "$IDENTITY" != "-" ]; then
    # An .xcarchive wrapping the signed app, so it can be notarized by hand from Xcode's Organizer
    # (Distribute App → Direct Distribution). Also copied into Xcode's archive folder so it shows up.
    echo "▸ Archiving"
    ARCHIVE="$OUT/$NAME.xcarchive"
    rm -rf "$ARCHIVE"
    mkdir -p "$ARCHIVE/Products/Applications"
    ditto "$APP" "$ARCHIVE/Products/Applications/$NAME.app"
    TEAM=$(echo "$IDENTITY" | sed -n 's/.*(\([A-Z0-9]*\))$/\1/p')
    cat > "$ARCHIVE/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>ApplicationProperties</key>
    <dict>
        <key>ApplicationPath</key><string>Applications/$NAME.app</string>
        <key>Architectures</key><array><string>arm64</string><string>x86_64</string></array>
        <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
        <key>CFBundleShortVersionString</key><string>$VERSION</string>
        <key>CFBundleVersion</key><string>$BUILD</string>
        <key>SigningIdentity</key><string>$IDENTITY</string>
        <key>Team</key><string>$TEAM</string>
    </dict>
    <key>ArchiveVersion</key><integer>2</integer>
    <key>CreationDate</key><date>$(date -u +%Y-%m-%dT%H:%M:%SZ)</date>
    <key>Name</key><string>$NAME</string>
    <key>SchemeName</key><string>$NAME</string>
</dict>
</plist>
EOF
    XCODE_ARCHIVES="$HOME/Library/Developer/Xcode/Archives/$(date +%Y-%m-%d)"
    mkdir -p "$XCODE_ARCHIVES"
    DEST="$XCODE_ARCHIVES/$NAME $VERSION $(date +%H.%M.%S).xcarchive"
    ditto "$ARCHIVE" "$DEST"
    echo "▸ Archive in Xcode Organizer: $DEST"

    # A signed zip too, for notarytool or Transporter if you'd rather not use Organizer.
    ditto -c -k --keepParent "$APP" "$OUT/$NAME-$VERSION-signed.zip"
fi

if [ -n "$NOTARY_PROFILE" ]; then
    [ "$IDENTITY" = "-" ] && { echo "Notarization needs a Developer ID identity (set IDENTITY)"; exit 1; }
    echo "▸ Notarizing"
    ZIP="$OUT/$NAME-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    spctl --assess --type execute --verbose "$APP"
    # Re-zip so the distributed archive carries the stapled ticket.
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "▸ Ready to ship: $ZIP"
fi

rm -rf "$OUT/obj"
echo "▸ Built $APP"
