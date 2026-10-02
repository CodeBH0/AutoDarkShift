#!/bin/bash
# Build an iPhone archive and package it for certificate signing on another device.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

# Prefer an explicit developer directory, then the selected Xcode installation.
# This machine also has a complete Xcode in Downloads.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    SELECTED_DEVELOPER_DIR="$(/usr/bin/xcode-select -p)"
    if [[ -d "$SELECTED_DEVELOPER_DIR/Platforms/iPhoneOS.platform" ]]; then
        export DEVELOPER_DIR="$SELECTED_DEVELOPER_DIR"
    elif [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
        export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    elif [[ -d "$HOME/Downloads/Xcode.app/Contents/Developer" ]]; then
        export DEVELOPER_DIR="$HOME/Downloads/Xcode.app/Contents/Developer"
    else
        echo "A complete Xcode with the iPhoneOS SDK is required. Set DEVELOPER_DIR to its Contents/Developer directory." >&2
        exit 1
    fi
fi

/usr/bin/xcrun --sdk iphoneos --show-sdk-path >/dev/null
mkdir -p build
echo "Building iPhone Release archive; log: build/unsigned-build.log"
if ! /usr/bin/xcodebuild -quiet \
    -project AutoDarkShift.xcodeproj -scheme AutoDarkShift \
    -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath build/DerivedData -archivePath build/AutoDarkShift.xcarchive \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
    ARCHS=arm64 archive >build/unsigned-build.log 2>&1; then
    tail -n 60 build/unsigned-build.log >&2
    exit 1
fi

PACKAGE_STAGE="$(/usr/bin/mktemp -d "$PROJECT_ROOT/build/ipa-stage.XXXXXX")"
trap 'rm -rf "$PACKAGE_STAGE"' EXIT
mkdir -p "$PACKAGE_STAGE/Payload" build/Signing
/usr/bin/ditto --norsrc --noextattr --noqtn \
    build/AutoDarkShift.xcarchive/Products/Applications/AutoDarkShift.app \
    "$PACKAGE_STAGE/Payload/AutoDarkShift.app"

APP_PATH="$PACKAGE_STAGE/Payload/AutoDarkShift.app"
EXTENSION_PATH="$APP_PATH/PlugIns/PacketTunnel.appex"
APP_GROUP_ID="$(/usr/libexec/PlistBuddy -c 'Print :AppGroupIdentifier' "$APP_PATH/Info.plist")"
EXTENSION_APP_GROUP_ID="$(/usr/libexec/PlistBuddy -c 'Print :AppGroupIdentifier' "$EXTENSION_PATH/Info.plist")"
if [[ "$APP_GROUP_ID" != "$EXTENSION_APP_GROUP_ID" ]]; then
    echo "App and extension App Group identifiers do not match." >&2
    exit 1
fi

# Preserve the app's requested capabilities in a local ad-hoc signature so
# re-signing tools can read them. This signature cannot authorize installation.
for ENTITLEMENT_FILE in AutoDarkShift PacketTunnel; do
    /usr/bin/plutil -create xml1 "build/Signing/$ENTITLEMENT_FILE.entitlements"
    /usr/libexec/PlistBuddy \
        -c 'Add :com.apple.developer.networking.networkextension array' \
        -c 'Add :com.apple.developer.networking.networkextension:0 string packet-tunnel-provider' \
        -c 'Add :com.apple.security.application-groups array' \
        -c "Add :com.apple.security.application-groups:0 string $APP_GROUP_ID" \
        "build/Signing/$ENTITLEMENT_FILE.entitlements"
done
/usr/bin/codesign --force --sign - --timestamp=none \
    --entitlements build/Signing/PacketTunnel.entitlements "$EXTENSION_PATH"
/usr/bin/codesign --force --sign - --timestamp=none \
    --entitlements build/Signing/AutoDarkShift.entitlements "$APP_PATH"
/usr/bin/codesign --verify --deep --strict "$APP_PATH"

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Info.plist")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Info.plist")"
IPA_PATH="$PROJECT_ROOT/build/AutoDarkShift-$APP_VERSION-build$APP_BUILD-resign.ipa"
/usr/bin/ditto -c -k --norsrc --noextattr --noqtn --keepParent \
    "$PACKAGE_STAGE/Payload" "$IPA_PATH"
/usr/bin/unzip -tq "$IPA_PATH"
/usr/bin/shasum -a 256 "$IPA_PATH" >"$IPA_PATH.sha256"
echo "Ready for certificate re-signing: $IPA_PATH"
