import Foundation
import AppKit
import SwiftUI
import SwiftData
import Combine
import ProductivityCore

@MainActor
public final class MenuBarController: NSObject {
    public static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private var mainPanel: FloatingPanel<AnyView>?
    private var quickCapturePanel: FloatingPanel<AnyView>?
    private var cancellables = Set<AnyCancellable>()

    private override init() {
        super.init()
    }

    public func setup() {
        // Create status bar item
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            updateStatusItemAppearance(button: button)
        }
        self.statusItem = item

        // Periodic status item updater for Pomodoro display
        Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshStatusItem()
            }
            .store(in: &cancellables)

        // Setup global hotkey callbacks from AppState
        AppState.shared.toggleQuickCaptureHandler = { [weak self] in
            self?.toggleQuickCapture()
        }

        AppState.shared.toggleMainPanelHandler = { [weak self] in
            self?.toggleMainPanel()
        }

        AppState.shared.openMainPanelHandler = { [weak self] in
            self?.openMainPanel()
        }

        // Auto-close when swiping 4 fingers to switch desktops / spaces
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.closeMainPanel()
            }
        }
    }

    public var statusItemButtonScreenRect: NSRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        let buttonRect = button.convert(button.bounds, to: nil)
        return window.convertToScreen(buttonRect)
    }

    public func toggleMainPanel() {
        if let panel = mainPanel, panel.isVisible {
            closeMainPanel()
        } else {
            openMainPanel()
        }
    }

    public func openMainPanel() {
        if mainPanel == nil {
            let rootView = TaskListView(onClose: { [weak self] in
                self?.closeMainPanel()
            })
            .modelContainer(PersistenceController.shared.container)
            .preferredColorScheme(colorSchemeForMode(AppState.shared.appearanceMode))

            let panel = FloatingPanel(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 580),
                isMovable: true,
                rootView: AnyView(rootView)
            )
            panel.ignoredClickScreenRectProvider = { [weak self] in
                self?.statusItemButtonScreenRect
            }
            panel.onPanelClosed = {
                AppState.shared.isMainPanelPresented = false
            }
            self.mainPanel = panel
        }

        AppState.shared.panelOpenCount += 1
        AppState.shared.isMainPanelPresented = true

        Task { @MainActor in
            _ = try? await NotesSyncService.shared.pullFromNotes(context: PersistenceController.shared.container.mainContext)
        }

        guard let panel = mainPanel, let button = statusItem?.button, let window = button.window else { return }

        // Position directly below status item with a 6px gap
        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = window.convertToScreen(buttonRect)
        let panelWidth: CGFloat = 480
        let panelHeight: CGFloat = 580
        var x = screenRect.midX - (panelWidth / 2)

        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            if x + panelWidth > visible.maxX - 10 {
                x = visible.maxX - panelWidth - 10
            }
            if x < visible.minX + 10 {
                x = visible.minX + 10
            }
        }

        let y = screenRect.minY - panelHeight - 6
        panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func closeMainPanel() {
        mainPanel?.orderOut(nil)
        // Keep panel instance cached for instant 0ms opening without reconstruction
    }

    public func showQuickCapture() {
        if quickCapturePanel == nil {
            let captureView = QuickCaptureView { [weak self] in
                self?.hideQuickCapture()
            }
            .modelContainer(PersistenceController.shared.container)
            .preferredColorScheme(colorSchemeForMode(AppState.shared.appearanceMode))

            let panel = FloatingPanel(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 160),
                isMovable: true,
                rootView: AnyView(captureView)
            )
            self.quickCapturePanel = panel
        }

        guard let panel = quickCapturePanel else { return }

        // Position slightly above center (Spotlight style)
        if let screen = NSScreen.main {
            let screenRect = screen.visibleFrame
            let x = screenRect.midX - (panel.frame.width / 2)
            let y = screenRect.midY + (screenRect.height * 0.12) - (panel.frame.height / 2)
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func hideQuickCapture() {
        quickCapturePanel?.orderOut(nil)
        quickCapturePanel = nil
    }

    public func toggleQuickCapture() {
        if let panel = quickCapturePanel, panel.isVisible {
            hideQuickCapture()
        } else {
            showQuickCapture()
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            // Right-click options
            let menu = NSMenu()
            menu.autoenablesItems = false

            let itemMain = NSMenuItem(title: "Toggle Main Panel (⌥⌘T)", action: #selector(toggleMainPanelAction), keyEquivalent: "")
            itemMain.target = self
            menu.addItem(itemMain)

            let itemCapture = NSMenuItem(title: "Quick Capture (⌥ Space)", action: #selector(triggerQuickCaptureAction), keyEquivalent: "")
            itemCapture.target = self
            menu.addItem(itemCapture)

            menu.addItem(NSMenuItem.separator())

            let itemWork = NSMenuItem(title: "Switch to Work (⌥⌘W)", action: #selector(switchToWorkAction), keyEquivalent: "")
            itemWork.target = self
            menu.addItem(itemWork)

            let itemPersonal = NSMenuItem(title: "Switch to Personal (⌥⌘P)", action: #selector(switchToPersonalAction), keyEquivalent: "")
            itemPersonal.target = self
            menu.addItem(itemPersonal)

            menu.addItem(NSMenuItem.separator())

            let itemQuit = NSMenuItem(title: "Quit", action: #selector(quitAction), keyEquivalent: "q")
            itemQuit.target = self
            menu.addItem(itemQuit)

            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil // restore normal click behavior
        } else {
            toggleMainPanel()
        }
    }

    @objc private func toggleMainPanelAction() {
        toggleMainPanel()
    }

    @objc private func triggerQuickCaptureAction() {
        showQuickCapture()
    }

    @objc private func switchToWorkAction() {
        AppState.shared.switchToWorkspace(.work)
        openMainPanel()
    }

    @objc private func switchToPersonalAction() {
        AppState.shared.switchToWorkspace(.personal)
        openMainPanel()
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }

    private func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        updateStatusItemAppearance(button: button)
    }

    private func updateStatusItemAppearance(button: NSStatusBarButton) {
        let focusService = FocusService.shared

        if focusService.isRunning || focusService.state != .idle {
            button.image = NSImage(systemSymbolName: "timer", accessibilityDescription: "Focus Timer")
            button.title = " \(focusService.formattedTimeRemaining)"
        } else {
            button.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "Productivity")
            button.title = ""
        }
    }

    private func colorSchemeForMode(_ mode: String) -> ColorScheme? {
        switch mode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}
