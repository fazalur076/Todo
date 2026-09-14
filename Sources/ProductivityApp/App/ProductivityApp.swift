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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
