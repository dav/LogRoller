#!/bin/bash
set -euo pipefail

# Build, sign, notarize, and package LogRoller
# Prerequisites:
#   - Developer ID Application certificate in keychain
#   - Notarization credentials stored: xcrun notarytool store-credentials "LogRoller"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
BUILD_DIR="/tmp/LogRollerBuild"
ARCHIVE_PATH="$BUILD_DIR/LogRoller.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
DMG_PATH="$BUILD_DIR/LogRoller.dmg"
NOTARY_PROFILE="LogRoller"
APP_NAME="LogRoller.app"

echo "=== LogRoller Release Build ==="
echo ""

# Step 0: Regenerate Xcode project
echo "→ Generating Xcode project..."
cd "$PROJECT_DIR"
xcodegen generate

# Step 1: Clean build directory
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Step 2: Archive
echo "→ Building release archive..."
xcodebuild archive \
    -project "$PROJECT_DIR/LogRoller.xcodeproj" \
    -scheme LogRollerApp \
    -destination 'platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    -configuration Release \
    2>&1 | tee /tmp/xcodebuild-archive.log | tail -3

if [ ! -d "$ARCHIVE_PATH" ]; then
    echo "❌ Archive failed — see /tmp/xcodebuild-archive.log"
    exit 1
fi
echo "✓ Archive created"

# Step 3: Export with Developer ID signing
echo "→ Exporting with Developer ID signing..."
cat > "$BUILD_DIR/ExportOptions.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>8U7J5S7RGC</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
    2>&1 | tail -3

if [ ! -d "$EXPORT_PATH/$APP_NAME" ]; then
    echo "❌ Export failed"
    exit 1
fi
echo "✓ App exported and signed"

# Step 4: Verify code signing
echo "→ Verifying code signature..."
codesign -dv --verbose=2 "$EXPORT_PATH/$APP_NAME" 2>&1 | grep -E 'Authority|TeamIdentifier|Runtime'
echo ""

# Step 5: Build CLI tool
echo "→ Building CLI tool..."
xcodebuild \
    -project "$PROJECT_DIR/LogRoller.xcodeproj" \
    -scheme logroller \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$BUILD_DIR/cli-derived" \
    build \
    2>&1 | tee /tmp/xcodebuild-cli.log | tail -3

CLI_BIN="$BUILD_DIR/cli-derived/Build/Products/Release/logroller"
if [ ! -f "$CLI_BIN" ]; then
    echo "❌ CLI build failed — see /tmp/xcodebuild-cli.log"
    exit 1
fi
echo "✓ CLI tool built"

# Step 6: Create DMG
echo "→ Creating DMG..."
rm -f "$DMG_PATH"

STAGING="$BUILD_DIR/dmg-staging"
mkdir -p "$STAGING"
cp -R "$EXPORT_PATH/$APP_NAME" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
cp "$CLI_BIN" "$STAGING/logroller"
cp "$PROJECT_DIR/Scripts/install.sh" "$STAGING/"
cp "$PROJECT_DIR/skills/logroller-client-integration/SKILL.md" "$STAGING/"

# Sign the CLI binary with Developer ID
echo "→ Signing CLI binary..."
codesign --force --options runtime --sign "Developer ID Application: Dav Yaginuma (8U7J5S7RGC)" "$STAGING/logroller"
echo "✓ CLI binary signed"

hdiutil create \
    -volname "LogRoller" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG_PATH" \
    2>&1 | tail -2

rm -rf "$STAGING"

if [ ! -f "$DMG_PATH" ]; then
    echo "❌ DMG creation failed"
    exit 1
fi
echo "✓ DMG created"

# Step 7: Sign the DMG
echo "→ Signing DMG..."
codesign --force --sign "Developer ID Application: Dav Yaginuma (8U7J5S7RGC)" "$DMG_PATH"
echo "✓ DMG signed"

# Step 8: Notarize
echo "→ Submitting for notarization (this may take a few minutes)..."
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

# Step 9: Staple
echo "→ Stapling notarization ticket..."
xcrun stapler staple "$DMG_PATH"

# Step 10: Verify
echo "→ Verifying notarization..."
spctl -a -t open --context context:primary-signature -v "$DMG_PATH" 2>&1

echo ""
echo "=== Done ==="
echo "DMG ready at: $DMG_PATH"
echo "Size: $(du -h "$DMG_PATH" | cut -f1)"
