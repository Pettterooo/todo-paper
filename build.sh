#!/bin/zsh
set -e
cd "$(dirname "$0")"
export DEVELOPER_DIR=/Applications/Xcode-27.1.0.app/Contents/Developer
SDK=$(xcrun --sdk macosx --show-sdk-path)
APP="TODO paper.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Welcome.txt "$APP/Contents/Resources/Welcome.txt"
swiftc -parse-as-library -Onone -g \
  -target arm64-apple-macos26.0 -sdk "$SDK" \
  -plugin-path "$(xcrun --find swift-frontend | xargs dirname)/../lib/swift/host/plugins" \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/TODOPaper" \
  -framework SwiftUI -framework AppKit
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "built: $PWD/$APP"
