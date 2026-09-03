#!/bin/bash
set -e
cd "$(dirname "$0")"

APP_NAME="WBMemoryMigrator"
BUILD="build"
rm -rf "$BUILD"
mkdir -p "$BUILD/arm64" "$BUILD/x86_64"

echo "==> 编译 arm64"
swiftc -O -framework SwiftUI -framework AppKit -framework UniformTypeIdentifiers \
  -target arm64-apple-macosx12.0 Sources/*.swift -o "$BUILD/arm64/$APP_NAME"

echo "==> 编译 x86_64"
swiftc -O -framework SwiftUI -framework AppKit -framework UniformTypeIdentifiers \
  -target x86_64-apple-macosx12.0 Sources/*.swift -o "$BUILD/x86_64/$APP_NAME"

echo "==> lipo 合并 Universal"
lipo -create "$BUILD/arm64/$APP_NAME" "$BUILD/x86_64/$APP_NAME" -output "$BUILD/$APP_NAME"

echo "==> 生成 App 图标"
VENV=/Users/banqiu/.workbuddy/binaries/python/envs/default
"$VENV/bin/python" Resources/gen_icon.py

echo "==> 组装 .app"
APP="$BUILD/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP"

echo "==> 校验"
file "$APP/Contents/MacOS/$APP_NAME"
lipo -info "$APP/Contents/MacOS/$APP_NAME"
plutil -lint "$APP/Contents/Info.plist"
echo "构建完成: $APP"
