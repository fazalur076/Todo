#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

INSTALLER_APP="$DIR/Install To Do.app"
COMMAND_FILE="$DIR/Install.command"

echo "📦 Assembling Install To Do.app..."
rm -rf "$INSTALLER_APP"
mkdir -p "$INSTALLER_APP/Contents/MacOS"
mkdir -p "$INSTALLER_APP/Contents/Resources"

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

# Executable launcher
cat << 'EOF' > "$INSTALLER_APP/Contents/MacOS/installer"
#!/bin/bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
exec "$DIR/Scripts/install.sh" --gui
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

echo "✅ Created:"
echo "  • $INSTALLER_APP (Double-click in Finder to install with native GUI)"
echo "  • $COMMAND_FILE (Double-click in Finder to install via Terminal)"
