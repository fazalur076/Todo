#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

INSTALLER_APP="$DIR/Install To Do.app"
COMMAND_FILE="$DIR/Install.command"

echo "📦 Assembling Install To Do.app (Standalone Portable Bundle)..."
rm -rf "$INSTALLER_APP"
mkdir -p "$INSTALLER_APP/Contents/MacOS"
mkdir -p "$INSTALLER_APP/Contents/Resources"

# Ensure Todo.app is compiled
if [ ! -d "$DIR/Todo.app" ]; then
    "$DIR/Scripts/build_app.sh"
fi

# Embed Todo.app into installer resources
echo "📥 Embedding Todo.app inside installer..."
cp -R "$DIR/Todo.app" "$INSTALLER_APP/Contents/Resources/Todo.app"

# Embed install script into installer resources
cp "$DIR/Scripts/install.sh" "$INSTALLER_APP/Contents/Resources/install.sh"
chmod +x "$INSTALLER_APP/Contents/Resources/install.sh"

# Copy Icon
if [ -f "$DIR/Sources/ProductivityApp/Resources/AppIcon.icns" ]; then
    cp "$DIR/Sources/ProductivityApp/Resources/AppIcon.icns" "$INSTALLER_APP/Contents/Resources/AppIcon.icns"
fi

# Info.plist
cat << 'EOF' > "$INSTALLER_APP/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIdentifier</key>
    <string>com.todo.macos.installer</string>
    <key>CFBundleName</key>
    <string>Install To Do</string>
    <key>CFBundleDisplayName</key>
    <string>Install To Do</string>
    <key>CFBundleExecutable</key>
    <string>installer</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# Executable launcher invoking embedded install engine
cat << 'EOF' > "$INSTALLER_APP/Contents/MacOS/installer"
#!/bin/bash
BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$BUNDLE_DIR/Resources/install.sh" --gui
EOF
chmod +x "$INSTALLER_APP/Contents/MacOS/installer"

# Codesign installer app
echo "✍️ Signing Install To Do.app..."
codesign --force --deep -s - -i com.todo.macos.installer "$INSTALLER_APP" 2>/dev/null || true

# Also create double-clickable Install.command for Terminal users
cat << 'EOF' > "$COMMAND_FILE"
#!/bin/bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
exec "$DIR/Scripts/install.sh" --cli "$@"
EOF
chmod +x "$COMMAND_FILE"

# Create a zip archive on the Desktop for effortless 1-click sharing
ZIP_DEST="$HOME/Desktop/Install-To-Do.zip"
echo "🗜 Creating shareable zip: $ZIP_DEST..."
rm -f "$ZIP_DEST"
ditto -c -k --sequesterRsrc --keepParent "$INSTALLER_APP" "$ZIP_DEST"

echo "✅ Ready to share:"
echo "  • $INSTALLER_APP (Double-click in Finder)"
echo "  • $ZIP_DEST (Send this single zip file to any friend!)"
