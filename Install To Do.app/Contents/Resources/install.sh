#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

MODE="cli"
if [ "$1" == "--gui" ]; then
    MODE="gui"
elif [ "$1" == "--cli" ]; then
    MODE="cli"
elif [ -z "$TERM" ] || [ "$TERM" == "dumb" ]; then
    MODE="gui"
fi

# Dynamically locate bundle resources (supports both standalone Install To Do.app and repo checkout)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ICON_PATH="$DIR/Sources/ProductivityApp/Resources/AppIcon.icns"
if [ -f "$SCRIPT_DIR/AppIcon.icns" ]; then
    ICON_PATH="$SCRIPT_DIR/AppIcon.icns"
elif [ -f "$SCRIPT_DIR/../Resources/AppIcon.icns" ]; then
    ICON_PATH="$SCRIPT_DIR/../Resources/AppIcon.icns"
fi

TARGET="/Applications/Todo.app"

# Locate source Todo.app (bundled inside installer or compiled locally)
APP_SOURCE=""
if [ -d "$SCRIPT_DIR/Todo.app" ]; then
    APP_SOURCE="$SCRIPT_DIR/Todo.app"
elif [ -d "$SCRIPT_DIR/../Resources/Todo.app" ]; then
    APP_SOURCE="$SCRIPT_DIR/../Resources/Todo.app"
elif [ -d "$DIR/Todo.app" ] && [ -f "$DIR/Todo.app/Contents/MacOS/Todo" ]; then
    APP_SOURCE="$DIR/Todo.app"
fi

show_dialog() {
    local text="$1"
    local title="$2"
    local default_btn="$3"
    shift 3
    local buttons=("$@")

    local btn_list=""
    for b in "${buttons[@]}"; do
        if [ -n "$btn_list" ]; then
            btn_list="$btn_list, \"$b\""
        else
            btn_list="\"$b\""
        fi
    done

    osascript -e "
    set iconFile to POSIX file \"$ICON_PATH\"
    try
        set res to button returned of (display dialog \"$text\" with title \"$title\" buttons {$btn_list} default button \"$default_btn\" with icon iconFile)
        return res
    on error
        return \"Cancel\"
    end try
    " 2>/dev/null
}

if [ "$MODE" == "gui" ]; then
    choice=$(show_dialog "Welcome to To Do for macOS!\n\nThis installer will:\n• Install To Do into your /Applications folder\n• Clear security quarantine flags\n• Configure Apple Notes automation permissions\n• Launch To Do directly into your menu bar\n\nReady to proceed?" "To Do Installer" "Install Now" "Quit" "Install Now")
    if [ "$choice" != "Install Now" ]; then
        exit 0
    fi
else
    echo "=================================================="
    echo "            To Do macOS Installer"
    echo "=================================================="
fi

# Step 1: Ensure release bundle exists
if [ -z "$APP_SOURCE" ] || [ ! -f "$APP_SOURCE/Contents/MacOS/Todo" ]; then
    if [ -f "$DIR/Scripts/build_app.sh" ]; then
        if [ "$MODE" == "gui" ]; then
            osascript -e 'display notification "Building release bundle..." with title "To Do Installer"' 2>/dev/null || true
        else
            echo "🔨 [1/5] Building release package..."
        fi
        "$DIR/Scripts/build_app.sh"
        APP_SOURCE="$DIR/Todo.app"
    else
        if [ "$MODE" == "gui" ]; then
            show_dialog "Could not find pre-built Todo.app inside installer package." "Error" "Quit" "Quit"
        else
            echo "❌ Error: Could not find Todo.app."
        fi
        exit 1
    fi
else
    if [ "$MODE" == "cli" ]; then
        echo "✅ [1/5] Release bundle ready ($APP_SOURCE)."
    fi
fi

# Step 2: Terminate existing instances
if [ "$MODE" == "cli" ]; then
    echo "🛑 [2/5] Closing any previous instances..."
fi
pkill -f "/Applications/Todo.app/Contents/MacOS/Todo" 2>/dev/null || true
pkill -f "$DIR/Todo.app/Contents/MacOS/Todo" 2>/dev/null || true
pkill -f "ProductivityApp" 2>/dev/null || true
pkill -f "Cadence" 2>/dev/null || true
sleep 0.5

# Step 3: Copy to /Applications
if [ "$MODE" == "cli" ]; then
    echo "📦 [3/5] Installing to $TARGET..."
fi
if [ -w "/Applications" ]; then
    rm -rf "$TARGET"
    cp -R "$APP_SOURCE" "$TARGET"
else
    osascript -e "do shell script \"rm -rf '$TARGET' && cp -R '$APP_SOURCE' '$TARGET'\" with administrator privileges"
fi

# Step 4: Gatekeeper quarantine removal and ad-hoc code-signing
if [ "$MODE" == "cli" ]; then
    echo "🔒 [4/5] Clearing quarantine and verifying security..."
fi
xattr -cr "$TARGET" 2>/dev/null || true
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
codesign --force --deep -s - -i com.todo.macos -r='designated => identifier "com.todo.macos"' "$TARGET" 2>/dev/null || true

# Step 5: Test & warmup Apple Notes Automation permission
notes_permission="granted"
if ! osascript -e 'tell application "Notes" to get name of default account' >/dev/null 2>&1; then
    notes_permission="prompted"
    # Open System Settings pane if user needs to manually verify
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation" 2>/dev/null || true
fi

# Step 6: Launch installed application
if [ "$MODE" == "cli" ]; then
    echo "🚀 [5/5] Launching To Do in menu bar..."
fi
open "$TARGET"
sleep 1

# Step 7: Completion Notice
if [ "$MODE" == "gui" ]; then
    perm_note=""
    if [ "$notes_permission" == "prompted" ]; then
        perm_note="\n\nNote: If prompted, please allow To Do to access Notes in System Settings -> Privacy & Security -> Automation."
    fi

    finish_choice=$(show_dialog "To Do is now installed and active in your menu bar!$perm_note\n\nShortcuts:\n• ⌥⌘T — Open / Close Dashboard\n• ⌥ Space — Quick Task Capture\n• ⌥⌘O — Work Division\n• ⌥⌘P — Personal Division\n\nWould you like to open the dashboard now?" "Installation Successful" "Open Dashboard" "Done" "Open Dashboard")
    if [ "$finish_choice" == "Open Dashboard" ]; then
        osascript -e 'tell application "System Events" to key code 17 using {command down, option down}' 2>/dev/null || true
    fi
else
    echo ""
    echo "=================================================="
    echo "          🎉 Installation Successful!"
    echo "=================================================="
    echo "To Do is now running in your menu bar."
    echo ""
    echo "Keyboard Shortcuts:"
    echo "  ⌥⌘T       Open / Close Daily Dashboard"
    echo "  ⌥ Space   Quick Capture Task anywhere"
    echo "  ⌥⌘O       Switch to Work Division"
    echo "  ⌥⌘P       Switch to Personal Division"
    echo "  ⌥⌘F       Switch to Freelance Division"
    echo "=================================================="
    echo ""
fi
