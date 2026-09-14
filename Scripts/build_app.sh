#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

echo "🔨 Building To Do (Release)..."
/usr/bin/swift build -c release --product Todo

BIN_PATH="$DIR/.build/release/Todo"
APP_BUNDLE="$DIR/Todo.app"
rm -rf "$DIR/ProductivityApp.app" "$DIR/Cadence.app"

echo "📦 Assembling $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/Todo"
if [ -f "$DIR/Sources/ProductivityCore/Resources/note_extractor.py" ]; then
    cp "$DIR/Sources/ProductivityCore/Resources/note_extractor.py" "$APP_BUNDLE/Contents/Resources/note_extractor.py"
    chmod +x "$APP_BUNDLE/Contents/Resources/note_extractor.py"
fi
if [ -f "$DIR/Sources/ProductivityApp/Resources/AppIcon.icns" ]; then
    cp "$DIR/Sources/ProductivityApp/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

cat << 'EOF' > "$APP_BUNDLE/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIdentifier</key>
    <string>com.todo.macos</string>
    <key>CFBundleName</key>
    <string>To Do</string>
    <key>CFBundleDisplayName</key>
    <string>To Do</string>
    <key>CFBundleExecutable</key>
    <string>Todo</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
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
    <string>To Do mirrors your daily tasks with Apple Notes seamlessly in the background.</string>
</dict>
</plist>
EOF

echo "✍️ Signing $APP_BUNDLE with designated identifier..."
codesign --force --deep -s - -i com.todo.macos -r='designated => identifier "com.todo.macos"' "$APP_BUNDLE" 2>/dev/null || true

echo "✅ Successfully built: $APP_BUNDLE"
