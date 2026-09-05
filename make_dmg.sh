#!/bin/bash
set -e
cd "$(dirname "$0")"

APP="build/WBMemoryMigrator.app"
VOL="WBMemoryMigrator"
DMG="build/12-WBMemoryMigrator-1.1_b38-beta-universal.dmg"
STAGING="dmg_staging"

mkdir -p build
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "$VOL" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"

echo "DMG 已生成: $DMG"
ls -lh "$DMG"
