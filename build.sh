#!/bin/bash

# Exit immediately if any command fails.
set -euo pipefail

APP_NAME="FanCurve"
APP_EXECUTABLE="FanCurve"
HELPER_EXECUTABLE="fancurve-helper"
# Default is ad-hoc signing: anyone can build and run the result locally, and
# the control daemon accepts ad-hoc clients by their signing identifier. To sign
# releases with your own Developer ID, override it on the command line:
#   SIGNING_IDENTITY="Developer ID Application: You (TEAMID)" ./build.sh
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"

# Identity, in exactly one place: the bundle's `CFBundleShortVersionString`, the DMG
# volume name and the Finder-visible name all come from these two variables, so a disk
# image can never advertise a version the bundle does not have.
APP_VERSION="${APP_VERSION:-1.0.0}"
# `APP_BUILD` becomes `CFBundleVersion`. It defaults to a UTC stamp of *this* build so
# every binary advertises something distinguishable: with a constant "1", a fresh build
# and a week-old installed copy both read "1.0.0 (1)" and nothing in the UI can tell you
# which one you are running. Override for a reproducible release build.
APP_BUILD="${APP_BUILD:-$(date -u +%Y%m%d%H%M)}"
# The ONE identifier: `HelperConstants.appBundleIdentifier` (which the daemon trusts
# for client authentication and which decides the UserDefaults domain the saved curve
# lives in), `PRODUCT_BUNDLE_IDENTIFIER` in project.yml and the plist written here must
# all agree. A disagreement is silent — an app reading a different domain just looks like
# it lost the user's settings — so the build refuses instead of shipping the drift.
BUNDLE_ID="com.local.fancurve.app"
HELPER_ID="com.local.fancurve.app.helper"

APP_DIR="${APP_NAME}.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

BUILD_DIR="${BUILD_DIR:-.build}"
PRODUCTS_DIR="$BUILD_DIR/products"
MODULE_CACHE_DIR="${MODULE_CACHE_DIR:-$BUILD_DIR/module-cache}"

MACOS_DEPLOYMENT_TARGET="${MACOS_DEPLOYMENT_TARGET:-13.0}"
ARCHS="${ARCHS:-arm64 x86_64}"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"

# Target file lists live in sources.sh so tools/typecheck.sh cannot drift from the
# build. The helper is a standalone binary: exactly the SMC transport, the fan-
# ownership layer, the shared value types and the protocol — no SwiftUI, no AppKit,
# no UserDefaults.
# shellcheck source=sources.sh
. "$(dirname "$0")/sources.sh"

export MACOSX_DEPLOYMENT_TARGET="$MACOS_DEPLOYMENT_TARGET"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR"

create_universal_binary() {
    local output="$1"
    shift

    if [ "$#" -eq 1 ]; then
        cp "$1" "$output"
    else
        lipo -create "$@" -output "$output"
    fi

    chmod +x "$output"
}

echo "=== Building FanCurve App Bundle ==="
echo "Deployment target: macOS $MACOS_DEPLOYMENT_TARGET"
echo "Architectures: $ARCHS"
echo "Version: $APP_VERSION ($APP_BUILD)  identifier: $BUNDLE_ID"

# Identifier drift check (see BUNDLE_ID above). Deliberately a hard stop: the
# failure it prevents is silent, not loud.
grep -q "appBundleIdentifier = \"$BUNDLE_ID\"" Shared/FanCurveHelperProtocol.swift || {
    echo "ERROR: HelperConstants.appBundleIdentifier != $BUNDLE_ID — align it with build.sh." >&2; exit 1; }
grep -qE "PRODUCT_BUNDLE_IDENTIFIER: $BUNDLE_ID$" project.yml || {
    echo "ERROR: project.yml app identifier != $BUNDLE_ID — align it with build.sh." >&2; exit 1; }
grep -qE "PRODUCT_BUNDLE_IDENTIFIER: $HELPER_ID$" project.yml || {
    echo "ERROR: project.yml helper identifier != $HELPER_ID — the daemon authenticates clients by it." >&2; exit 1; }
grep -qE "MARKETING_VERSION: \"$APP_VERSION\"" project.yml || {
    echo "ERROR: project.yml MARKETING_VERSION != $APP_VERSION — Xcode and script builds would advertise different versions." >&2; exit 1; }
# The helper's file list is repeated in project.yml (xcodegen cannot read sources.sh).
# A file missing there compiles in the script build and is absent from the Xcode build,
# which fails at link time in the *other* path — so catch it here instead.
for src in "${HELPER_SOURCES[@]}"; do
    grep -qxF "      - $src" project.yml || {
        echo "ERROR: $src is in sources.sh but not in project.yml's fancurve-helper target." >&2; exit 1; }
done

rm -rf "$APP_DIR" "$PRODUCTS_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$PRODUCTS_DIR" "$MODULE_CACHE_DIR"

app_slices=()
helper_slices=()

for arch in $ARCHS; do
    target="${arch}-apple-macosx${MACOS_DEPLOYMENT_TARGET}"
    arch_dir="$PRODUCTS_DIR/$arch"
    helper_output="$arch_dir/$HELPER_EXECUTABLE"
    app_output="$arch_dir/$APP_EXECUTABLE"

    mkdir -p "$arch_dir"

    echo "Compiling $HELPER_EXECUTABLE for $arch..."
    # -O: the shipping binary must not be built at -Onone (it was: the shipped
    # arm64 slice matched an unoptimized build byte-for-byte in size).
    swiftc \
        -O \
        -target "$target" \
        -sdk "$SDK_PATH" \
        -o "$helper_output" \
        "${HELPER_SOURCES[@]}"

    echo "Compiling $APP_EXECUTABLE for $arch..."
    swiftc \
        -O \
        -parse-as-library \
        -target "$target" \
        -sdk "$SDK_PATH" \
        -o "$app_output" \
        -framework Cocoa \
        -framework SwiftUI \
        -framework IOKit \
        "${APP_SOURCES[@]}"

    helper_slices+=("$helper_output")
    app_slices+=("$app_output")
done

echo "Creating app bundle binaries..."
create_universal_binary "$MACOS_DIR/$HELPER_EXECUTABLE" "${helper_slices[@]}"
create_universal_binary "$MACOS_DIR/$APP_EXECUTABLE" "${app_slices[@]}"

echo "Writing Info.plist..."
cat <<EOF > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_EXECUTABLE</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$APP_BUILD</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
    </array>
    <key>LSMinimumSystemVersion</key>
    <string>$MACOS_DEPLOYMENT_TARGET</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
EOF

# Icon: `CFBundleIconFile` says "AppIcon", so the bundle needs Resources/AppIcon.icns.
# The loose 1024px PNG is the master art and the .icns is derived from it, so the PNG
# wins whenever it is present. Preferring the checked-in .icns instead means a replaced
# PNG silently ships the previous icon — the exact failure where a rebuilt app looks
# like the old build. The .icns is only the fallback (and the source for the Xcode path).
if [ -f "AppIcon.png" ] || [ -f "app_icon.png" ]; then
    ICON_SRC="AppIcon.png"; [ -f "$ICON_SRC" ] || ICON_SRC="app_icon.png"
    echo "Building AppIcon.icns from $ICON_SRC..."
    ICONSET="$BUILD_DIR/AppIcon.iconset"
    rm -rf "$ICONSET"; mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z "$double" "$double" "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$RESOURCES_DIR/AppIcon.icns"
    rm -rf "$ICONSET"
    # Keep the checked-in copy in step, so the Xcode path and the next build from a
    # clean tree cannot disagree with this one.
    cp "$RESOURCES_DIR/AppIcon.icns" "App/AppIcon.icns"
elif [ -f "App/AppIcon.icns" ]; then
    echo "Copying application icon (App/AppIcon.icns)..."
    cp "App/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
else
    echo "Warning: no AppIcon.png or App/AppIcon.icns; the bundle will use the generic icon."
fi

if [ -d "Localization" ]; then
    echo "Copying localizations..."
    for localization_dir in Localization/*.lproj; do
        [ -d "$localization_dir" ] || continue
        cp -R "$localization_dir" "$RESOURCES_DIR/"
    done
fi

if [ -f "Helper/fancurve-helper.plist" ]; then
    echo "Copying control-service launchd template..."
    mkdir -p "$CONTENTS_DIR/Library/LaunchDaemons"
    cp "Helper/fancurve-helper.plist" "$CONTENTS_DIR/Library/LaunchDaemons/$HELPER_ID.plist"
fi

echo "$APP_EXECUTABLE architectures: $(lipo -archs "$MACOS_DIR/$APP_EXECUTABLE")"
echo "$HELPER_EXECUTABLE architectures: $(lipo -archs "$MACOS_DIR/$HELPER_EXECUTABLE")"
echo "$APP_EXECUTABLE deployment targets:"
vtool -show-build "$MACOS_DIR/$APP_EXECUTABLE" | grep "minos"
echo "$HELPER_EXECUTABLE deployment targets:"
vtool -show-build "$MACOS_DIR/$HELPER_EXECUTABLE" | grep "minos"

# 7. Codesign app bundle and binaries
# If the configured Developer ID identity is not in this keychain, fall back
# to ad-hoc signing: the app is for this machine, and an unbuildable signature
# must never block a working local install.
if [ "$SIGNING_IDENTITY" != "-" ] && ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGNING_IDENTITY"; then
    echo "Note: '$SIGNING_IDENTITY' not found in keychain — using ad-hoc signing."
    SIGNING_IDENTITY="-"
fi
echo "Codesigning app and binaries (identity: $SIGNING_IDENTITY)..."
# The helper is a standalone Mach-O, so without --identifier an ad-hoc signature
# derives its signing identifier from the *file name* plus a hash (measured:
# "fancurve-helper-555549443eda…"), which changes on every rebuild. The daemon
# authenticates clients by signing identifier, so ours must be stable and explicit.
codesign --force --sign "$SIGNING_IDENTITY" --identifier "$HELPER_ID" --options runtime "$MACOS_DIR/$HELPER_EXECUTABLE"
codesign --force --sign "$SIGNING_IDENTITY" --options runtime "$MACOS_DIR/$APP_EXECUTABLE"
codesign --force --sign "$SIGNING_IDENTITY" --options runtime "$APP_DIR"

# 8. Create a drag-and-drop DMG when possible. Some managed, sandboxed, or
# headless environments cannot provide the device service required by hdiutil;
# in that case, preserve the signed app in a Finder-installable ZIP instead.
echo "Packaging to DMG..."
rm -f "$APP_NAME.dmg"
rm -f "$APP_NAME.zip"
rm -rf dist
mkdir -p dist
cp -R "$APP_DIR" dist/
# Add a symbolic link to /Applications for easy drag-and-drop installation
ln -s /Applications dist/Applications

if hdiutil create -volname "$APP_NAME v$APP_VERSION ($APP_BUILD)" -srcfolder dist -ov -format UDZO "$APP_NAME.dmg"; then
    rm -rf dist
    echo "Codesigning DMG..."
    codesign --force --sign "$SIGNING_IDENTITY" "FanCurve.dmg"
    echo "=== Build and Packaging Complete: 'FanCurve.dmg' created successfully ==="
else
    rm -f "FanCurve.dmg"
    rm -rf dist

    echo "Warning: DMG packaging failed; creating a ZIP fallback..."
    ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$APP_NAME.zip"
    echo "=== Build and Packaging Complete: 'FanCurve.zip' created successfully ==="
fi
