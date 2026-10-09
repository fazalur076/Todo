import SwiftUI
import AppKit
import SwiftData
import ProductivityCore

@main
struct TodoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(onClose: {
                // Closed
            })
            .modelContainer(PersistenceController.shared.container)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize menu bar item and popovers
        MenuBarController.shared.setup()

        // Set activation policy to accessory so it lives in the menu bar without a Dock icon
        NSApp.setActivationPolicy(.accessory)

        // This app owns its settings presentation inside the floating panel.
        // A standalone SwiftUI Settings scene can be restored by macOS and
        // appear as soon as the menu-bar app launches.
        DispatchQueue.main.async {
            NSApp.windows.forEach { $0.orderOut(nil) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
