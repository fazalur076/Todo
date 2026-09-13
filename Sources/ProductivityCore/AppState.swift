import Foundation
import SwiftUI
import ServiceManagement

@Observable
@MainActor
public final class AppState {
    public static let shared = AppState()

    // Workspace state
    public var currentWorkspace: Workspace {
        didSet {
            UserDefaults.standard.set(currentWorkspace.rawValue, forKey: "lastActiveWorkspace")
        }
    }

    // Settings
    public var alwaysLaunchInWork: Bool {
        didSet { UserDefaults.standard.set(alwaysLaunchInWork, forKey: "alwaysLaunchInWork") }
    }

    public var syncNotesEnabled: Bool {
        didSet { UserDefaults.standard.set(syncNotesEnabled, forKey: "syncNotesEnabled") }
    }

    public var appearanceMode: String {
        didSet { UserDefaults.standard.set(appearanceMode, forKey: "appearanceMode") }
    }

    public var launchAtLogin: Bool {
        didSet {
            updateLaunchAtLogin(launchAtLogin)
        }
    }

    // Modal & sheet states
    public var isQuickCapturePresented: Bool = false
    public var isMainPanelPresented: Bool = false
    public var selectedTaskForEdit: TaskItem? = nil
    public var isEODPresented: Bool = false
    public var isSettingsPresented: Bool = false
    public var isMoveUnfinishedAlertPresented: Bool = false
    public var toggleQuickCaptureHandler: (() -> Void)? = nil
    public var toggleMainPanelHandler: (() -> Void)? = nil
    public var openMainPanelHandler: (() -> Void)? = nil
    public var panelOpenCount: Int = 0

    private init() {
        let alwaysWork = UserDefaults.standard.bool(forKey: "alwaysLaunchInWork")
        self.alwaysLaunchInWork = alwaysWork

        if alwaysWork {
            self.currentWorkspace = .work
        } else if let savedWorkspace = UserDefaults.standard.string(forKey: "lastActiveWorkspace"),
                  let ws = Workspace(rawValue: savedWorkspace) {
            self.currentWorkspace = ws
        } else {
            self.currentWorkspace = .work
        }

        self.syncNotesEnabled = UserDefaults.standard.bool(forKey: "syncNotesEnabled")
        self.appearanceMode = UserDefaults.standard.string(forKey: "appearanceMode") ?? "system"

        if #available(macOS 13.0, *) {
            self.launchAtLogin = (SMAppService.mainApp.status == .enabled)
        } else {
            self.launchAtLogin = false
        }

        setupShortcuts()
    }

    private func setupShortcuts() {
        ShortcutService.shared.onQuickCapture = { [weak self] in
            self?.toggleQuickCapture()
        }

        ShortcutService.shared.onSwitchToWork = { [weak self] in
            self?.switchToWorkspace(.work)
            self?.openMainPanelHandler?()
        }

        ShortcutService.shared.onSwitchToPersonal = { [weak self] in
            self?.switchToWorkspace(.personal)
            self?.openMainPanelHandler?()
        }

        ShortcutService.shared.onToggleMainPanel = { [weak self] in
            self?.toggleMainPanelHandler?()
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.productivity.openSettings"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isSettingsPresented = true
            }
        }
    }

    public func switchToWorkspace(_ workspace: Workspace) {
        withAnimation(.easeInOut(duration: 0.15)) {
            self.currentWorkspace = workspace
        }
    }

    public func toggleQuickCapture() {
        isQuickCapturePresented.toggle()
        toggleQuickCaptureHandler?()
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else {
                    if SMAppService.mainApp.status == .enabled {
                        try SMAppService.mainApp.unregister()
                    }
                }
            } catch {
                print("Failed to update Launch at Login: \(error)")
            }
        }
    }
}
