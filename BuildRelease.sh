#!/bin/sh

# arm64 only: the locally built Omni/TreeMapView frameworks are arm64-only
xcodebuild -project Disk\ Inventory\ X.xcodeproj -configuration Release ARCHS=arm64 \
    CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= || exit 1

# Re-sign embedded frameworks and the app with one identity, or dyld
# refuses to load frameworks signed in their own builds (Team ID mismatch).
APP="build/Release/Disk Inventory X.app"
IDENTITY="${CODESIGN_IDENTITY:--}"
for f in "$APP/Contents/Frameworks"/*.framework; do
    codesign --force --sign "$IDENTITY" "$f" || exit 1
done
codesign --force --sign "$IDENTITY" "$APP" || exit 1
codesign --verify --deep --strict "$APP"
