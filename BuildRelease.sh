#!/bin/sh
set -e

# Builds Disk Inventory X and its dependencies. Expects the dependency repos
# as siblings of this one:
#   ../TreeMapView   https://github.com/<fork>/TreeMapView (arm64-modern-macos)
#   ../OmniGroup     https://github.com/<fork>/OmniGroup   (arm64-modern-xcode-2022)
#
# Usage:
#   ./BuildRelease.sh            local build, ad-hoc signed (not distributable)
#   ./BuildRelease.sh --release  Developer ID signed + notarized + stapled +
#                                zipped; the identity and the notarytool
#                                profile are discovered in the keychain
#
# Environment (each overrides the keychain discovery in --release mode):
#   CODESIGN_IDENTITY  identity for the app and embedded frameworks
#   NOTARY_PROFILE     notarytool keychain profile name; when set, the signed
#                      app is notarized, stapled, and zipped for distribution.
#                      One-time setup: xcrun notarytool store-credentials
#   FORCE_DEPS=1       rebuild dependency frameworks even if they exist

if [ "$1" = "--release" ]; then
    if [ -z "$CODESIGN_IDENTITY" ]; then
        CODESIGN_IDENTITY=$(security find-identity -v -p codesigning \
            | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
        [ -n "$CODESIGN_IDENTITY" ] || { echo "error: no Developer ID Application identity in the keychain" >&2; exit 1; }
        echo "Signing as: $CODESIGN_IDENTITY"
    fi
    NOTARY_PROFILE="${NOTARY_PROFILE:-DIX}"
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" > /dev/null 2>&1 \
        || { echo "error: notarytool profile '$NOTARY_PROFILE' not usable; run: xcrun notarytool store-credentials $NOTARY_PROFILE" >&2; exit 1; }
    echo "Notarizing with profile: $NOTARY_PROFILE"
fi

# arm64 only: the locally built Omni/TreeMapView frameworks are arm64-only
DEP_SETTINGS="ARCHS=arm64 CODE_SIGN_IDENTITY=- MACOSX_DEPLOYMENT_TARGET=12.0 \
    GCC_TREAT_WARNINGS_AS_ERRORS=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=NO \
    RUN_CLANG_STATIC_ANALYZER=NO"

OMNI=../OmniGroup
for fw in OmniBase OmniFoundation OmniAppKit; do
    if [ -n "$FORCE_DEPS" ] || [ ! -d "$OMNI/Build/Release/$fw.framework" ]; then
        echo "=== Building $fw ==="
        xcodebuild -project "$OMNI/Frameworks/$fw/$fw.xcodeproj" -target $fw \
            -configuration Release SYMROOT="$PWD/$OMNI/Build" $DEP_SETTINGS -quiet
    fi
done

TMV=../TreeMapView
if [ -n "$FORCE_DEPS" ] || [ ! -d "$TMV/build/Release/TreeMapView.framework" ]; then
    echo "=== Building TreeMapView ==="
    xcodebuild -project "$TMV/TreeMapView.xcodeproj" -target TreeMapView \
        -configuration Release SYMROOT="$PWD/$TMV/build" $DEP_SETTINGS -quiet
fi

echo "=== Building Disk Inventory X ==="
xcodebuild -project Disk\ Inventory\ X.xcodeproj -configuration Release ARCHS=arm64 \
    CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= -quiet

# Re-sign embedded frameworks and the app with one identity, or dyld
# refuses to load frameworks signed in their own builds (Team ID mismatch).
# With a real identity, sign for notarization: hardened runtime + secure
# timestamp (ad-hoc signatures can't get timestamps).
APP="build/Release/Disk Inventory X.app"
IDENTITY="${CODESIGN_IDENTITY:--}"
SIGN_FLAGS=""
if [ "$IDENTITY" != "-" ]; then
    SIGN_FLAGS="--options runtime --timestamp"
fi
for f in "$APP/Contents/Frameworks"/*.framework; do
    codesign --force --sign "$IDENTITY" $SIGN_FLAGS "$f"
done
codesign --force --sign "$IDENTITY" $SIGN_FLAGS "$APP"
codesign --verify --deep --strict "$APP"

if [ -n "$NOTARY_PROFILE" ]; then
    VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
    ZIP="build/Release/Disk-Inventory-X-$VERSION.zip"
    echo "=== Notarizing ==="
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    # re-zip so the published archive contains the stapled ticket
    rm "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "Ready for upload: $ZIP"
fi
