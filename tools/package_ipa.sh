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

# Each packaging invocation consumes a new shared build number, including failed builds.
# Never reuse a published number or overwrite an earlier IPA/archive.
APP_BUILD="$(python3 - <<'PY'
from pathlib import Path
import re

root = Path.cwd()
configuration = root / "Config/Project.xcconfig"
text = configuration.read_text(encoding="utf-8")
pattern = r"^CURRENT_PROJECT_VERSION\s*=\s*([0-9]+)[ \t]*$"
matches = list(re.finditer(pattern, text, re.M))
if len(matches) != 1:
    raise SystemExit("Expected one numeric CURRENT_PROJECT_VERSION in Config/Project.xcconfig.")
used = [int(matches[0].group(1))]
for artifact in (root / "build").glob("AutoDarkShift-*-build*-resign.ipa"):
    match = re.search(r"-build([0-9]+)-resign\.ipa$", artifact.name)
    if match:
        used.append(int(match.group(1)))
for directory in (root / "build").glob("build[0-9]*"):
    match = re.fullmatch(r"build([0-9]+)", directory.name)
    if match:
        used.append(int(match.group(1)))
number = max(used) + 1
configuration.write_text(re.sub(pattern, f"CURRENT_PROJECT_VERSION = {number}", text, count=1, flags=re.M), encoding="utf-8")
print(number)
PY
)"
APP_VERSION="$(sed -nE 's/^MARKETING_VERSION[[:space:]]*=[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+)[[:space:]]*$/\1/p' Config/Project.xcconfig)"
if [[ -z "$APP_VERSION" ]]; then
    echo "Expected a numeric marketing version in Config/Project.xcconfig." >&2
    exit 1
fi
BUILD_ROOT="$PROJECT_ROOT/build/build$APP_BUILD"
ARCHIVE_PATH="$BUILD_ROOT/AutoDarkShift.xcarchive"
IPA_PATH="$PROJECT_ROOT/build/AutoDarkShift-$APP_VERSION-build$APP_BUILD-resign.ipa"
if [[ -e "$BUILD_ROOT" || -e "$IPA_PATH" || -e "$IPA_PATH.sha256" ]]; then
    echo "Build $APP_BUILD output already exists; refusing to overwrite it." >&2
    exit 1
fi
mkdir "$BUILD_ROOT"
echo "Building $APP_VERSION / build $APP_BUILD; log: $BUILD_ROOT/unsigned-build.log"
if ! /usr/bin/xcodebuild -quiet \
    -project AutoDarkShift.xcodeproj -scheme AutoDarkShift \
    -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath "$BUILD_ROOT/DerivedData" -archivePath "$ARCHIVE_PATH" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
    MARKETING_VERSION="$APP_VERSION" CURRENT_PROJECT_VERSION="$APP_BUILD" \
    ARCHS=arm64 archive >"$BUILD_ROOT/unsigned-build.log" 2>&1; then
    tail -n 60 "$BUILD_ROOT/unsigned-build.log" >&2
    exit 1
fi

PACKAGE_STAGE="$(/usr/bin/mktemp -d "$BUILD_ROOT/ipa-stage.XXXXXX")"
trap 'rm -rf "$PACKAGE_STAGE"' EXIT
mkdir -p "$PACKAGE_STAGE/Payload" "$BUILD_ROOT/Signing"
/usr/bin/ditto --norsrc --noextattr --noqtn \
    "$ARCHIVE_PATH/Products/Applications/AutoDarkShift.app" \
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
    /usr/bin/plutil -create xml1 "$BUILD_ROOT/Signing/$ENTITLEMENT_FILE.entitlements"
    /usr/libexec/PlistBuddy \
        -c 'Add :com.apple.developer.networking.networkextension array' \
        -c 'Add :com.apple.developer.networking.networkextension:0 string packet-tunnel-provider' \
        -c 'Add :com.apple.security.application-groups array' \
        -c "Add :com.apple.security.application-groups:0 string $APP_GROUP_ID" \
        "$BUILD_ROOT/Signing/$ENTITLEMENT_FILE.entitlements"
done
/usr/bin/codesign --force --sign - --timestamp=none \
    --entitlements "$BUILD_ROOT/Signing/PacketTunnel.entitlements" "$EXTENSION_PATH"
/usr/bin/codesign --force --sign - --timestamp=none \
    --entitlements "$BUILD_ROOT/Signing/AutoDarkShift.entitlements" "$APP_PATH"
/usr/bin/codesign --verify --deep --strict "$APP_PATH"

for BUNDLE_PATH in "$APP_PATH" "$EXTENSION_PATH"; do
    ACTUAL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUNDLE_PATH/Info.plist")"
    ACTUAL_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$BUNDLE_PATH/Info.plist")"
    if [[ "$ACTUAL_VERSION" != "$APP_VERSION" || "$ACTUAL_BUILD" != "$APP_BUILD" ]]; then
        echo "Packaged bundle version differs from the reserved build number." >&2
        exit 1
    fi
done
/usr/bin/ditto -c -k --norsrc --noextattr --noqtn --keepParent \
    "$PACKAGE_STAGE/Payload" "$IPA_PATH"
/usr/bin/unzip -tq "$IPA_PATH"
/usr/bin/shasum -a 256 "$IPA_PATH" >"$IPA_PATH.sha256"
echo "Ready for certificate re-signing: $IPA_PATH"
