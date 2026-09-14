import Foundation
import SwiftUI
import ServiceManagement
import SwiftData

@Observable
@MainActor
public final class AppState {
    public static let shared = AppState()

    // Default workspace presets (Work on ⌥⌘O, Personal on ⌥⌘P)
    public static let defaultWorkspaces: [WorkspaceDefinition] = [
        WorkspaceDefinition(id: "work", name: "Work", iconName: "briefcase.fill", colorHex: "#3B82F6", shortcutKey: "O", includeInEOD: true, isSystem: false, sortOrder: 0),
        WorkspaceDefinition(id: "personal", name: "Personal", iconName: "person.fill", colorHex: "#10B981", shortcutKey: "P", includeInEOD: false, isSystem: false, sortOrder: 1),
        WorkspaceDefinition(id: "freelance", name: "Freelance", iconName: "laptopcomputer", colorHex: "#8B5CF6", shortcutKey: "F", includeInEOD: true, isSystem: false, sortOrder: 2)
    ]

    // Workspaces configuration
    public var workspaces: [WorkspaceDefinition] {
        didSet {
            saveWorkspaces()
            ShortcutService.shared.reloadDynamicHotkeys(workspaces: workspaces)
        }
    }

    // Workspace state
    public var currentWorkspace: Workspace {
        didSet {
            UserDefaults.standard.set(currentWorkspace.rawValue, forKey: "lastActiveWorkspace")
        }
    }

    // Customizable Apple Notes Note Title
    public var notesNoteTitle: String {
        didSet {
            let trimmed = notesNoteTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalTitle = trimmed.isEmpty ? "TASKS — TODAY" : trimmed
            UserDefaults.standard.set(finalTitle, forKey: "notesNoteTitle")
        }
    }

    // Settings
    public var alwaysLaunchInWork: Bool {
        didSet { UserDefaults.standard.set(alwaysLaunchInWork, forKey: "alwaysLaunchInWork") }
    }

    public var syncNotesEnabled: Bool {
        didSet { UserDefaults.standard.set(syncNotesEnabled, forKey: "syncNotesEnabled") }
    }

    public var onAppearanceChange: ((String) -> Void)? = nil

    public var appearanceMode: String {
        didSet {
            UserDefaults.standard.set(appearanceMode, forKey: "appearanceMode")
            onAppearanceChange?(appearanceMode)
        }
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
        // Load custom workspaces or defaults
        var loadedWorkspaces: [WorkspaceDefinition]
        if let data = UserDefaults.standard.data(forKey: "customWorkspaces"),
           let decoded = try? JSONDecoder().decode([WorkspaceDefinition].self, from: data),
           !decoded.isEmpty {
            loadedWorkspaces = decoded
        } else {
            loadedWorkspaces = AppState.defaultWorkspaces
        }

        // Migrate Work from previous 'W' to requested 'O' if still using default W
        if let wIdx = loadedWorkspaces.firstIndex(where: { $0.id == "work" && ($0.shortcutKey == "W" || $0.shortcutKey == nil) }) {
            loadedWorkspaces[wIdx].shortcutKey = "O"
        }
        // Unlock all system divisions so user can edit and delete everything
        for i in 0..<loadedWorkspaces.count {
            loadedWorkspaces[i].isSystem = false
        }
        self.workspaces = loadedWorkspaces

        let alwaysWork = UserDefaults.standard.bool(forKey: "alwaysLaunchInWork")
        self.alwaysLaunchInWork = alwaysWork

        if alwaysWork {
            self.currentWorkspace = .work
        } else if let savedWorkspace = UserDefaults.standard.string(forKey: "lastActiveWorkspace"),
                  loadedWorkspaces.contains(where: { $0.id == savedWorkspace }) {
            self.currentWorkspace = Workspace(rawValue: savedWorkspace)
        } else {
            self.currentWorkspace = Workspace(rawValue: loadedWorkspaces.first?.id ?? "work")
        }

        self.notesNoteTitle = UserDefaults.standard.string(forKey: "notesNoteTitle") ?? "TASKS — TODAY"
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

        ShortcutService.shared.onSwitchToWorkspace = { [weak self] wsId in
            self?.switchToWorkspace(Workspace(rawValue: wsId))
            self?.openMainPanelHandler?()
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

        // Register initial dynamic shortcuts
        ShortcutService.shared.reloadDynamicHotkeys(workspaces: workspaces)
    }

    public func workspaceDefinition(for workspace: Workspace) -> WorkspaceDefinition? {
        workspaces.first { $0.id == workspace.rawValue }
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

    // MARK: - Workspace Management CRUD
    @discardableResult
    public func addWorkspace(
        name: String,
        shortcutKey: String? = nil,
        colorHex: String = "#10B981",
        iconName: String = "folder.fill",
        includeInEOD: Bool = true
    ) -> WorkspaceDefinition {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var slug = cleanName.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
        if slug.isEmpty { slug = "division_\(Int.random(in: 100...999))" }

        var candidate = slug
        var counter = 2
        while workspaces.contains(where: { $0.id == candidate }) {
            candidate = "\(slug)_\(counter)"
            counter += 1
        }

        let newDef = WorkspaceDefinition(
            id: candidate,
            name: cleanName,
            iconName: iconName,
            colorHex: colorHex,
            shortcutKey: shortcutKey?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
            includeInEOD: includeInEOD,
            isSystem: false,
            sortOrder: (workspaces.map(\.sortOrder).max() ?? 0) + 1
        )
        workspaces.append(newDef)
        saveWorkspaces()
        ShortcutService.shared.reloadDynamicHotkeys(workspaces: workspaces)
        return newDef
    }

    @discardableResult
    public func addWorkspace(
        name: String,
        shortcutKey: Character?,
        colorHex: String = "#10B981",
        iconName: String = "folder.fill",
        includeInEOD: Bool = true
    ) -> WorkspaceDefinition {
        addWorkspace(
            name: name,
            shortcutKey: shortcutKey.map { String($0) },
            colorHex: colorHex,
            iconName: iconName,
            includeInEOD: includeInEOD
        )
    }

    public func updateWorkspace(_ definition: WorkspaceDefinition) {
        if let idx = workspaces.firstIndex(where: { $0.id == definition.id }) {
            workspaces[idx] = definition
            saveWorkspaces()
            ShortcutService.shared.reloadDynamicHotkeys(workspaces: workspaces)
        }
    }

    public func deleteWorkspace(id: String) {
        guard workspaces.count > 1 else { return } // Keep at least 1 division
        guard let idx = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces.remove(at: idx)
        if currentWorkspace.rawValue == id, let first = workspaces.first {
            currentWorkspace = Workspace(rawValue: first.id)
        }
        saveWorkspaces()
        ShortcutService.shared.reloadDynamicHotkeys(workspaces: workspaces)
    }

    public func performDailyRolloverIfNeeded(context: ModelContext) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let todayString = ISO8601DateFormatter().string(from: today)
        let lastDayString = UserDefaults.standard.string(forKey: "lastRolloverDateKey")

        let descriptor = FetchDescriptor<TaskItem>(
            predicate: #Predicate<TaskItem> { item in
                item.statusRaw != "completed" && item.scheduledDate < today
            }
        )

        var didRollover = false
        if let overdueTasks = try? context.fetch(descriptor), !overdueTasks.isEmpty {
            for task in overdueTasks {
                task.scheduledDate = today
                task.updatedAt = Date()
            }
            try? context.save()
            didRollover = true
        }

        if didRollover || lastDayString != todayString {
            UserDefaults.standard.set(todayString, forKey: "lastRolloverDateKey")
            NotesSyncService.shared.autoSync(context: context)
        }
    }

    private func saveWorkspaces() {
        if let encoded = try? JSONEncoder().encode(workspaces) {
            UserDefaults.standard.set(encoded, forKey: "customWorkspaces")
        }
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
                print("Failed to toggle Launch at Login: \(error.localizedDescription)")
            }
        }
    }
}
