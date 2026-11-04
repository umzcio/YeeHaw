#!/bin/bash
# Usage: scripts/build-app.sh [--install]
# Builds dist/YeeHaw.app (team-signed). --install copies it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM_ID="V2P99VF75Q"
IDENTITY="${YEEHAW_SIGNING_IDENTITY:-$TEAM_ID}"

swift build -c release --disable-sandbox
BIN_DIR="$(swift build -c release --show-bin-path --disable-sandbox)"
APP="$PWD/dist/YeeHaw.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/YeeHaw" "$APP/Contents/MacOS/YeeHaw"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# The app icon: Assets.car (the macOS 27 icon, from the Icon Composer file) plus AppIcon.icns.
xcrun actool --compile "$APP/Contents/Resources" --platform macosx --minimum-deployment-target 27.2 \
    --app-icon AppIcon --output-partial-info-plist "$(mktemp -t yeehaw-icon)" Resources/AppIcon.icon >/dev/null

# Sparkle, which installs updates, goes in Contents/Frameworks (Package.swift adds that rpath). Its
# helpers are signed inside out with the same certificate, keeping their entitlements.
SPARKLE=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE" "$FRAMEWORK"
cp .build/checkouts/Sparkle/LICENSE "$APP/Contents/Resources/Sparkle-LICENSE.txt"
for component in XPCServices/Downloader.xpc XPCServices/Installer.xpc Autoupdate Updater.app; do
    codesign --force --sign "$IDENTITY" --options runtime --timestamp --preserve-metadata=entitlements \
        "$FRAMEWORK/Versions/B/$component"
done
codesign --force --sign "$IDENTITY" --options runtime --timestamp "$FRAMEWORK"

codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP"

# Dev builds must be team-signed so the Accessibility grant survives rebuilds.
SIGNED_INFO="$(codesign -dvv "$APP" 2>&1)"
if ! grep -qx "TeamIdentifier=$TEAM_ID" <<<"$SIGNED_INFO"; then
    echo "error: $APP is not signed by team $TEAM_ID" >&2
    exit 1
fi
codesign --verify --deep --strict "$APP"
printf 'Built %s\n' "$APP"

if [[ "${1:-}" == "--install" ]]; then
    DEST="$HOME/Applications/YeeHaw.app"
    mkdir -p "$HOME/Applications"
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    printf 'Installed %s\n' "$DEST"
fi
