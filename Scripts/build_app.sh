#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

echo "🔨 Building ProductivityApp (Release)..."
/usr/bin/swift build -c release --product ProductivityApp

BIN_PATH="$DIR/.build/release/ProductivityApp"
APP_BUNDLE="$DIR/ProductivityApp.app"

echo "📦 Assembling $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/ProductivityApp"
if [ -f "$DIR/Sources/ProductivityCore/Resources/note_extractor.py" ]; then
    cp "$DIR/Sources/ProductivityCore/Resources/note_extractor.py" "$APP_BUNDLE/Contents/Resources/note_extractor.py"
    chmod +x "$APP_BUNDLE/Contents/Resources/note_extractor.py"
fi

cat << 'EOF' > "$APP_BUNDLE/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIdentifier</key>
    <string>com.productivity.app</string>
    <key>CFBundleName</key>
    <string>Productivity</string>
    <key>CFBundleDisplayName</key>
    <string>Productivity</string>
    <key>CFBundleExecutable</key>
    <string>ProductivityApp</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSAppleScriptEnabled</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Productivity needs permission to mirror your daily tasks to Apple Notes.</string>
</dict>
</plist>
EOF

echo "✍️ Signing $APP_BUNDLE with stable designated identifier..."
codesign --force --deep -s - -i com.productivity.app -r='designated => identifier "com.productivity.app"' "$APP_BUNDLE" 2>/dev/null || true

echo "✅ Successfully built: $APP_BUNDLE"
