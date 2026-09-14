import Foundation
import SwiftData
import AppKit

@MainActor
public final class NotesSyncService {
    public static let shared = NotesSyncService()

    public var isSyncing: Bool = false
    public var lastSyncTime: Date?
    public var lastSyncError: String?

    private var autoSyncTask: Task<Void, Never>?
    private var backgroundPullTimer: Timer?
    private var lastRecreationAttempt: Date? = nil
    private var hasPendingSyncRequest: Bool = false
    private var lastSyncFinishedAt: Date? = nil

    /// Tracks the most recent local mutation to prevent background pull race conditions
    public static var lastLocalMutationTime: Date = Date.distantPast

    /// Persistent deletion tombstones (keyed by "\(workspaceRaw)::\(lowercaseTitle)")
    /// Stored with a 10-minute expiry to ensure deleted tasks are never resurrected by background pulls
    private var deletedTaskTombstones: [String: Date] {
        get {
            let dict = UserDefaults.standard.dictionary(forKey: "deletedTaskTombstones") as? [String: TimeInterval] ?? [:]
            let cutoff = Date().timeIntervalSince1970 - 600
            return dict.filter { $0.value > cutoff }.reduce(into: [String: Date]()) { res, pair in
                res[pair.key] = Date(timeIntervalSince1970: pair.value)
            }
        }
        set {
            let cutoff = Date().timeIntervalSince1970 - 600
            let mapped = newValue.filter { $0.value.timeIntervalSince1970 > cutoff }.reduce(into: [String: TimeInterval]()) { res, pair in
                res[pair.key] = pair.value.timeIntervalSince1970
            }
            UserDefaults.standard.set(mapped, forKey: "deletedTaskTombstones")
        }
    }

    public func recordTaskDeletion(title: String, workspace: Workspace) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let key = "\(workspace.rawValue)::\(clean)"
        var current = deletedTaskTombstones
        current[key] = Date()
        current["*::\(clean)"] = Date()
        deletedTaskTombstones = current
        Self.lastLocalMutationTime = Date()
    }

    public func isTaskDeleted(title: String, workspace: Workspace) -> Bool {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let key = "\(workspace.rawValue)::\(clean)"
        if let date = deletedTaskTombstones[key], Date().timeIntervalSince(date) < 600 {
            return true
        }
        if let date = deletedTaskTombstones["*::\(clean)"], Date().timeIntervalSince(date) < 600 {
            return true
        }
        return false
    }

    /// Safely deletes a task from SwiftData, records a tombstone, and schedules a Notes sync after idle.
    public func deleteTask(_ task: TaskItem, context: ModelContext) {
        let title = task.title
        let workspace = task.workspace
        recordTaskDeletion(title: title, workspace: workspace)
        context.delete(task)
        try? context.save()

        // Schedule sync after 15s idle (tombstones prevent pull resurrection during the window)
        autoSync(context: context)
    }

    /// Moves a task to a different division, updates mutation timestamps, and schedules a Notes sync after idle.
    public func moveTask(_ task: TaskItem, to newWorkspace: Workspace, context: ModelContext) {
        task.workspace = newWorkspace
        task.updatedAt = Date()
        try? context.save()

        // Schedule sync after 15s idle (includes native checklist formatting)
        autoSync(context: context)
    }

    private init() {
        startBackgroundPullTimer()
    }

    public func startBackgroundPullTimer() {
        backgroundPullTimer?.invalidate()
        backgroundPullTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                _ = try? await self?.pullFromNotes(context: PersistenceController.shared.container.mainContext)
            }
        }
    }

    public func buildNotesContent(from context: ModelContext) -> (title: String, plainText: String, htmlBody: String) {
        let noteTitle = AppState.shared.notesNoteTitle
        let taskDescriptor = FetchDescriptor<TaskItem>(
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        let allTasks = (try? context.fetch(taskDescriptor)) ?? []

        let activeWorkspaces = AppState.shared.workspaces
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        let updatedTime = timeFormatter.string(from: Date())

        // Plain text version with clean circular checklist symbols
        var plain: [String] = []
        plain.append(noteTitle)
        plain.append("")

        var html = "<div><b><h1>\(escapeHtml(noteTitle))</h1></b></div><div><br></div>"

        for wsDef in activeWorkspaces {
            let wsTasks = allTasks.filter {
                $0.workspaceRaw == wsDef.id &&
                ($0.isScheduledForToday || $0.status == .inProgress || $0.isOverdue || ($0.completedAt.map { Calendar.current.isDateInToday($0) } ?? false))
            }.sorted { a, b in
                let aCompleted = (a.status == .completed)
                let bCompleted = (b.status == .completed)
                if aCompleted != bCompleted {
                    return !aCompleted
                }
                return a.sortOrder < b.sortOrder
            }

            let heading = wsDef.name.uppercased()
            plain.append(heading)
            html += "<div><h2>\(heading)</h2></div>"

            if wsTasks.isEmpty {
                plain.append("No active tasks")
                html += "<div><i><font color=\"#8E8E93\">No active tasks</font></i></div>"
            } else {
                for task in wsTasks {
                    let mark = task.status == .completed ? "✓" : (task.status == .inProgress ? "◐" : "○")
                    plain.append("\(mark) \(task.title)")
                    if task.status == .completed {
                        html += "<div><strike><font color=\"#8E8E93\">\(escapeHtml(task.title))</font></strike></div>"
                    } else {
                        html += "<div>\(escapeHtml(task.title))</div>"
                    }
                }
            }
            plain.append("")
            html += "<div><br></div>"
        }

        plain.append("Updated \(updatedTime)")
        let plainText = plain.joined(separator: "\n")
        return (noteTitle, plainText, html)
    }

    /// Pushes changes made in the app to Apple Notes after 15 seconds of user inactivity.
    /// Each new call resets the timer. Native checklist formatting is applied in this path.
    public func autoSync(context: ModelContext) {
        autoSyncTask?.cancel()
        Self.lastLocalMutationTime = Date()
        autoSyncTask = Task { @MainActor in
            // 15 seconds debounce: Only push to Notes after user stops interacting
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            guard self.needsPushToNotes(context: context) else { return }
            do {
                try await self.syncToNotes(from: context, openNotes: false, applyChecklist: true)
            } catch {
                print("Auto-sync to Notes error: \(error)")
            }
        }
    }

    /// Pulls items from Apple Notes into SwiftData (Reverse Sync)
    @discardableResult
    public func pullFromNotes(context: ModelContext) async throws -> (added: Int, updated: Int) {
        // Guard against race conditions during active local mutations
        guard Date().timeIntervalSince(Self.lastLocalMutationTime) >= 2.0 else {
            return (0, 0)
        }

        // If the note was deleted or does not exist in Apple Notes, recreate it from the app!
        if !noteExistsInNotes() {
            let allTasksDescriptor = FetchDescriptor<TaskItem>()
            let existingTasks = (try? context.fetch(allTasksDescriptor)) ?? []
            if !existingTasks.isEmpty {
                let shouldRecreate = lastRecreationAttempt == nil || Date().timeIntervalSince(lastRecreationAttempt!) > 5
                if shouldRecreate {
                    lastRecreationAttempt = Date()
                    try? await syncToNotes(from: context, openNotes: false)
                }
            }
            return (0, 0)
        }

        // Step 1: Attempt to read native checklist states directly from NoteStore.sqlite
        var parsedItems = fetchItemsFromNoteStore()

        // Step 2: Fallback to AppleScript HTML body if SQLite parser found no items
        let noteTitle = AppState.shared.notesNoteTitle
        if parsedItems.isEmpty {
            let scriptSource = """
            tell application "Notes"
                set activeNotes to {}
                set targetTitle to "\(escapeAppleScript(noteTitle))"
                repeat with n in (notes whose name is targetTitle)
                    try
                        set c to container of n
                        if (name of c) is not "Recently Deleted" then
                            set end of activeNotes to n
                        end if
                    end try
                end repeat
                if (count of activeNotes) = 0 then
                    repeat with n in (notes whose name is "TASKS — TODAY")
                        try
                            set c to container of n
                            if (name of c) is not "Recently Deleted" then
                                set end of activeNotes to n
                            end if
                        end try
                    end repeat
                end if
                if (count of activeNotes) > 0 then
                    return body of item 1 of activeNotes
                else
                    return ""
                end if
            end tell
            """

            let bodyText: String = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    var errorDict: NSDictionary?
                    guard let script = NSAppleScript(source: scriptSource) else {
                        continuation.resume(returning: "")
                        return
                    }
                    let descriptor = script.executeAndReturnError(&errorDict)
                    if let error = errorDict {
                        let msg = error[NSAppleScript.errorMessage] as? String ?? "AppleScript error"
                        continuation.resume(throwing: NSError(domain: "NotesPull", code: 1, userInfo: [NSLocalizedDescriptionKey: msg]))
                    } else {
                        continuation.resume(returning: descriptor.stringValue ?? "")
                    }
                }
            }

            if !bodyText.isEmpty {
                parsedItems = parseNotesBody(bodyText)
            }
        }

        let allTasksDescriptor = FetchDescriptor<TaskItem>()
        let existingTasks = (try? context.fetch(allTasksDescriptor)) ?? []

        let notesTitles = Set(parsedItems.map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        var reservedHeaders: Set<String> = ["WORK", "PERSONAL", "FREELANCE", "TASKS — TODAY", "TASKS - TODAY", "NO ACTIVE TASKS", "TASKS", noteTitle.uppercased()]
        for ws in AppState.shared.workspaces {
            reservedHeaders.insert(ws.name.uppercased())
            reservedHeaders.insert(ws.id.uppercased())
        }

        // 0. Deduplicate any duplicate tasks across workspaces in SwiftData (keep the one most recently updated)
        var purgedAny = false
        var seenCleanTitles: [String: TaskItem] = [:]
        for task in existingTasks {
            let clean = task.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !clean.isEmpty else { continue }
            if let existing = seenCleanTitles[clean] {
                // Duplicate detected across workspaces: keep newer, delete older duplicate
                let keep = task.updatedAt >= existing.updatedAt ? task : existing
                let remove = task.updatedAt >= existing.updatedAt ? existing : task
                context.delete(remove)
                seenCleanTitles[clean] = keep
                purgedAny = true
            } else {
                seenCleanTitles[clean] = task
            }
        }

        // 1. Purge corrupted tasks and synchronize deletions from Apple Notes
        var validExistingTasks: [TaskItem] = []
        for task in seenCleanTitles.values {
            let clean = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanLower = clean.lowercased()
            let upper = clean.uppercased()

            // Delete headers or multiline corruption immediately
            if reservedHeaders.contains(upper) || upper.contains(noteTitle.uppercased()) || upper.contains("TASKS — TODAY") || upper.contains("TASKS - TODAY") || clean.contains("\n") || clean.contains("\r") {
                context.delete(task)
                purgedAny = true
                continue
            }

            let isTodayScope = task.isScheduledForToday || task.status == .inProgress || task.isOverdue || (task.completedAt.map { Calendar.current.isDateInToday($0) } ?? false)

            // If a task in today's scope is no longer in Apple Notes at all (across any division), and wasn't just created/edited locally, remove it
            if isTodayScope && !notesTitles.contains(cleanLower) {
                let isRecentlyCreatedLocally = Date().timeIntervalSince(task.createdAt) < 10.0
                let isRecentlyModifiedLocally = Date().timeIntervalSince(task.updatedAt) < 10.0
                if !isRecentlyCreatedLocally && !isRecentlyModifiedLocally {
                    context.delete(task)
                    purgedAny = true
                    continue
                }
            }

            validExistingTasks.append(task)
        }
        if purgedAny {
            try? context.save()
        }

        if parsedItems.isEmpty {
            // If the note was deleted and not found in Notes, recreate it from the app!
            if !validExistingTasks.isEmpty {
                let shouldRecreate = lastRecreationAttempt == nil || Date().timeIntervalSince(lastRecreationAttempt!) > 5
                if shouldRecreate && !noteExistsInNotes() {
                    lastRecreationAttempt = Date()
                    try? await syncToNotes(from: context, openNotes: false)
                }
            }
            return (0, 0)
        }

        var addedCount = 0
        var updatedCount = 0
        var seenKeys = Set(validExistingTasks.map { "\($0.workspace.rawValue)::\($0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())" })
        var seenTitlesGlobal = Set(validExistingTasks.map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })

        for item in parsedItems {
            let cleanTitle = item.title.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanTitle.isEmpty else { continue }
            let cleanLower = cleanTitle.lowercased()
            let upper = cleanTitle.uppercased()
            if reservedHeaders.contains(upper) || upper.contains(noteTitle.uppercased()) || upper.contains("TASKS — TODAY") || upper.contains("TASKS - TODAY") {
                continue
            }

            let key = "\(item.workspace.rawValue)::\(cleanLower)"

            // Match by title across ANY workspace to prevent duplicate cross-division creation
            let matching = validExistingTasks.first {
                $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == cleanLower
            }

            if let task = matching {
                if task.workspace == item.workspace {
                    // Same workspace: check status updates
                    let isRecentlyModifiedLocally = Date().timeIntervalSince(task.updatedAt) < 3.0
                    if !isRecentlyModifiedLocally {
                        if item.isCompleted && task.status != .completed {
                            task.status = .completed
                            task.completedAt = Date()
                            updatedCount += 1
                        } else if !item.isCompleted && task.status == .completed {
                            task.status = .pending
                            task.completedAt = nil
                            updatedCount += 1
                        }
                    }
                } else {
                    // Different workspace: task exists in another division
                    let isRecentlyModifiedLocally = Date().timeIntervalSince(task.updatedAt) < 15.0 || Date().timeIntervalSince(Self.lastLocalMutationTime) < 15.0
                    if !isRecentlyModifiedLocally {
                        // User moved the task in Apple Notes on their phone/Mac: update app's division to match
                        task.workspace = item.workspace
                        task.updatedAt = Date()
                        updatedCount += 1
                    }
                    // If recently moved locally in the app, the app is authoritative — preserve task.workspace!
                }
                seenKeys.insert(key)
                seenTitlesGlobal.insert(cleanLower)
            } else if !seenKeys.contains(key) && !seenTitlesGlobal.contains(cleanLower) {
                // Check deletion tombstone: if task was deleted locally, under no circumstances resurrect it!
                if let deletedAt = deletedTaskTombstones[key], Date().timeIntervalSince(deletedAt) < 600 {
                    continue
                }
                if let deletedAt = deletedTaskTombstones["*::\(cleanLower)"], Date().timeIntervalSince(deletedAt) < 600 {
                    continue
                }
                // New task discovered in Notes: insert once, avoiding double/triple entry
                seenKeys.insert(key)
                seenTitlesGlobal.insert(cleanLower)
                let nextOrder = (validExistingTasks.filter { $0.workspace == item.workspace }.map(\.sortOrder).max() ?? 0) + addedCount
                let newTask = TaskItem(
                    title: cleanTitle,
                    workspace: item.workspace,
                    status: item.isCompleted ? .completed : .pending,
                    sortOrder: nextOrder + 1
                )
                context.insert(newTask)
                validExistingTasks.append(newTask)
                addedCount += 1
            }
        }

        if addedCount > 0 || updatedCount > 0 {
            try? context.save()
        }

        return (addedCount, updatedCount)
    }

    /// Fetches native checklist states from NoteStore.sqlite via note_extractor.py
    private func fetchItemsFromNoteStore() -> [(title: String, workspace: Workspace, isCompleted: Bool)] {
        var candidates: [String] = []
        if let resPath = Bundle.main.resourcePath {
            candidates.append("\(resPath)/note_extractor.py")
        }
        let currentDir = FileManager.default.currentDirectoryPath
        candidates.append("\(currentDir)/Sources/ProductivityCore/Resources/note_extractor.py")
        candidates.append("\(currentDir)/Todo.app/Contents/Resources/note_extractor.py")

        let divMap = AppState.shared.workspaces.reduce(into: [String: String]()) { dict, ws in
            dict[ws.name.uppercased()] = ws.id
        }
        let divJson = (try? String(data: JSONEncoder().encode(divMap), encoding: .utf8)) ?? "{}"

        for path in candidates {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [path, divJson, AppState.shared.notesNoteTitle]
            let pipe = Pipe()
            process.standardOutput = pipe
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                struct ExtractedItem: Codable {
                    let title: String
                    let workspace: String
                    let completed: Bool
                }
                if let items = try? JSONDecoder().decode([ExtractedItem].self, from: data), !items.isEmpty {
                    return items.map {
                        ($0.title, Workspace(rawValue: $0.workspace), $0.completed)
                    }
                }
            } catch {
                continue
            }
        }
        return []
    }

    /// Compares local tasks with Apple Notes to avoid unnecessary note rewrites and mobile conflicts
    public func needsPushToNotes(context: ModelContext) -> Bool {
        let taskDescriptor = FetchDescriptor<TaskItem>(
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        let allTasks = (try? context.fetch(taskDescriptor)) ?? []

        let activeWorkspaces = AppState.shared.workspaces
        var localTasksByWs: [String: [TaskItem]] = [:]
        for ws in activeWorkspaces {
            let tasks = allTasks.filter {
                $0.workspace.rawValue == ws.id &&
                ($0.isScheduledForToday || $0.status == .inProgress || $0.isOverdue || ($0.completedAt.map { Calendar.current.isDateInToday($0) } ?? false))
            }
            localTasksByWs[ws.id] = tasks
        }

        let hasAnyLocalTasks = localTasksByWs.values.contains { !$0.isEmpty }

        if !noteExistsInNotes() {
            return hasAnyLocalTasks
        }

        let notesItems = fetchCurrentNotesItems()
        if notesItems.isEmpty {
            return hasAnyLocalTasks
        }

        // If Apple Notes still contains any task that was deleted locally, we must push immediately to wipe it out:
        for item in notesItems {
            let key = "\(item.workspace.rawValue)::\(item.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
            if let deletedAt = deletedTaskTombstones[key], Date().timeIntervalSince(deletedAt) < 600 {
                return true
            }
        }

        for ws in activeWorkspaces {
            let localTasks = localTasksByWs[ws.id] ?? []
            let notesTasks = notesItems.filter { $0.workspace.rawValue == ws.id }

            if localTasks.count != notesTasks.count {
                return true
            }

            for local in localTasks {
                guard let match = notesTasks.first(where: {
                    $0.title.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(local.title.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
                }) else {
                    return true
                }
                if match.isCompleted != (local.status == .completed) {
                    return true
                }
            }
        }

        return false
    }

    private func fetchCurrentNotesItems() -> [(title: String, workspace: Workspace, isCompleted: Bool)] {
        let storeItems = fetchItemsFromNoteStore()
        if !storeItems.isEmpty {
            return storeItems
        }

        let noteTitle = AppState.shared.notesNoteTitle
        let scriptSource = """
        tell application "Notes"
            set activeNotes to {}
            set targetTitle to "\(escapeAppleScript(noteTitle))"
            repeat with n in (notes whose name is targetTitle)
                try
                    set c to container of n
                    if (name of c) is not "Recently Deleted" then
                        set end of activeNotes to n
                    end if
                end try
            end repeat
            if (count of activeNotes) = 0 then
                repeat with n in (notes whose name is "TASKS — TODAY")
                    try
                        set c to container of n
                        if (name of c) is not "Recently Deleted" then
                            set end of activeNotes to n
                        end if
                    end try
                end repeat
            end if
            if (count of activeNotes) > 0 then
                return body of item 1 of activeNotes
            else
                return ""
            end if
        end tell
        """
        var errorDict: NSDictionary?
        guard let script = NSAppleScript(source: scriptSource) else { return [] }
        let descriptor = script.executeAndReturnError(&errorDict)
        if let body = descriptor.stringValue, !body.isEmpty {
            return parseNotesBody(body)
        }
        return []
    }

    /// Checks whether an active (non-deleted) target note exists in Apple Notes
    public func noteExistsInNotes() -> Bool {
        let noteTitle = AppState.shared.notesNoteTitle
        let scriptSource = """
        tell application "Notes"
            set activeNotes to {}
            set targetTitle to "\(escapeAppleScript(noteTitle))"
            repeat with n in (notes whose name is targetTitle)
                try
                    set c to container of n
                    if (name of c) is not "Recently Deleted" then
                        set end of activeNotes to n
                    end if
                end try
            end repeat
            if (count of activeNotes) = 0 then
                repeat with n in (notes whose name is "TASKS — TODAY")
                    try
                        set c to container of n
                        if (name of c) is not "Recently Deleted" then
                            set end of activeNotes to n
                        end if
                    end try
                end repeat
            end if
            return (count of activeNotes) > 0
        end tell
        """
        var errorDict: NSDictionary?
        guard let script = NSAppleScript(source: scriptSource) else { return false }
        let descriptor = script.executeAndReturnError(&errorDict)
        return descriptor.booleanValue
    }

    /// Two-way sync: Pulls user edits from Apple Notes first, and only pushes if local changes exist.
    @discardableResult
    public func syncTwoWay(context: ModelContext, openNotes: Bool = false) async throws -> (added: Int, updated: Int) {
        // Step 1: Pull from Notes first so mobile edits are preserved in the Mac app
        let result = (try? await pullFromNotes(context: context)) ?? (0, 0)

        // Step 2: Push back if local differences exist or if explicitly requested via openNotes
        if needsPushToNotes(context: context) || openNotes {
            try await syncToNotes(from: context, openNotes: openNotes)
        }

        return result
    }

    public static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    public static func requestAccessibilityPermission() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let promptOption = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(promptOption)
    }

    public func syncToNotes(from context: ModelContext, openNotes: Bool = false, applyChecklist: Bool = false) async throws {
        // Concurrency Guard: Prevent parallel colliding sync requests
        if isSyncing {
            hasPendingSyncRequest = true
            return
        }

        // Calm-down cooldown window: ensure 3s calm after the last sync before starting another
        if let lastFinish = lastSyncFinishedAt, Date().timeIntervalSince(lastFinish) < 3.0 {
            try? await Task.sleep(nanoseconds: UInt64((3.0 - Date().timeIntervalSince(lastFinish)) * 1_000_000_000))
        }

        isSyncing = true
        lastSyncError = nil
        defer {
            isSyncing = false
            lastSyncFinishedAt = Date()
            if hasPendingSyncRequest {
                hasPendingSyncRequest = false
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    try? await self.syncToNotes(from: context, openNotes: false)
                }
            }
        }

        let content = buildNotesContent(from: context)

        // Collect task titles per workspace and completed titles
        let taskDescriptor = FetchDescriptor<TaskItem>(
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        let allTasks = (try? context.fetch(taskDescriptor)) ?? []
        
        let activeTasks = allTasks.filter {
            $0.isScheduledForToday || $0.status == .inProgress || $0.isOverdue || ($0.completedAt.map { Calendar.current.isDateInToday($0) } ?? false)
        }

        let allTaskTitles = activeTasks.map(\.title)
        let completedTitles = activeTasks.filter { $0.status == .completed }.map(\.title)
        let divisionHeadings = AppState.shared.workspaces.map { $0.name.uppercased() }

        try await syncDirectlyToNotes(
            htmlBody: content.htmlBody,
            allTaskTitles: allTaskTitles,
            divisionHeadings: divisionHeadings,
            completedTitles: completedTitles,
            openNotes: openNotes,
            applyChecklist: applyChecklist || openNotes
        )
        self.lastSyncTime = Date()
    }

    /// Pure backend AppleScript sync: updates Apple Notes atomically, then applies native checklist format via System Events.
    private func syncDirectlyToNotes(
        htmlBody: String,
        allTaskTitles: [String] = [],
        divisionHeadings: [String] = [],
        completedTitles: [String] = [],
        openNotes: Bool = false,
        applyChecklist: Bool = false
    ) async throws {
        var scriptLines: [String] = []
        scriptLines.append("""
        tell application "Notes"
            set noteTitle to "\(escapeAppleScript(AppState.shared.notesNoteTitle))"
            set activeNotes to {}
            repeat with n in (notes whose name is noteTitle)
                try
                    set c to container of n
                    if (name of c) is not "Recently Deleted" then
                        set end of activeNotes to n
                    end if
                end try
            end repeat

            if (count of activeNotes) = 0 then
                try
                    make new note at default account with properties {body:"\(escapeAppleScript(htmlBody))"}
                on error
                    make new note with properties {body:"\(escapeAppleScript(htmlBody))"}
                end try
            else
                set theNote to item 1 of activeNotes
                set body of theNote to "\(escapeAppleScript(htmlBody))"
            end if
        """)

        if openNotes {
            scriptLines.append("""
            show item 1 of (notes whose name is noteTitle)
            """)
        }

        scriptLines.append("""
        end tell
        """)

        try await executeScript(scriptLines.joined(separator: "\n"))

        // Apply native checklist format only when triggered by user mutation (15s idle) or explicit "Open in Notes".
        // Pull-timer-triggered pushes skip this entirely.
        if applyChecklist {
            let axGranted = Self.isAccessibilityGranted
            if !axGranted {
                Self.requestAccessibilityPermission()
                NSLog("⚠️ NotesSyncService: Accessibility NOT granted, requesting permission...")
            }
            do {
                try await applyNativeChecklist(
                    openNotes: openNotes,
                    allTaskTitles: allTaskTitles,
                    divisionHeadings: divisionHeadings,
                    completedTitles: completedTitles
                )
                NSLog("✅ NotesSyncService: Native checklist format applied after idle")
            } catch {
                NSLog("⚠️ NotesSyncService: Native checklist format error: %@", error.localizedDescription)
                self.lastSyncError = error.localizedDescription
            }
        }
    }

    /// Briefly activates Notes, applies Checklist format ONLY to task lines (ensuring division headings are strictly Headings),
    /// marks completed tasks as checked, then restores previous app.
    private func applyNativeChecklist(
        openNotes: Bool,
        allTaskTitles: [String],
        divisionHeadings: [String],
        completedTitles: [String]
    ) async throws {
        let origApp = NSWorkspace.shared.frontmostApplication

        // 1. Activate Notes and show note
        let noteTitle = AppState.shared.notesNoteTitle
        let showScript = """
        tell application "Notes"
            set activeNotes to {}
            set targetTitle to "\(escapeAppleScript(noteTitle))"
            repeat with n in (notes whose name is targetTitle)
                try
                    set c to container of n
                    if (name of c) is not "Recently Deleted" then
                        set end of activeNotes to n
                    end if
                end try
            end repeat
            if (count of activeNotes) = 0 then
                repeat with n in (notes whose name is "TASKS — TODAY")
                    try
                        set c to container of n
                        if (name of c) is not "Recently Deleted" then
                            set end of activeNotes to n
                        end if
                    end try
                end repeat
            end if
            if (count of activeNotes) > 0 then
                activate
                show item 1 of activeNotes
            end if
        end tell
        """
        try await executeScript(showScript)
        try await Task.sleep(nanoseconds: 350_000_000)

        // 2. Find Notes AXTextArea
        guard let notesApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Notes").first else {
            return
        }
        let appElement = AXUIElementCreateApplication(notesApp.processIdentifier)

        func findTextArea(in element: AXUIElement) -> AXUIElement? {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
            if let role = roleRef as? String, role == "AXTextArea" { return element }
            var childrenRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
            if let children = childrenRef as? [AXUIElement] {
                for child in children {
                    if let found = findTextArea(in: child) { return found }
                }
            }
            return nil
        }

        var targetTA: AXUIElement?
        for _ in 1...6 {
            var windowsRef: CFTypeRef?
            AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
            if let windows = windowsRef as? [AXUIElement] {
                for w in windows {
                    if let ta = findTextArea(in: w) { targetTA = ta; break }
                }
            }
            if targetTA != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        guard let ta = targetTA else {
            NSLog("⚠️ NotesSyncService: AXTextArea not found in Notes window.")
            return
        }

        func selectRange(loc: Int, len: Int) {
            var cfRange = CFRange(location: loc, length: len)
            if let axRange = AXValueCreate(.cfRange, &cfRange) {
                AXUIElementSetAttributeValue(ta, kAXSelectedTextRangeAttribute as CFString, axRange)
                usleep(25_000)
            }
        }

        func getText() -> String {
            var valRef: CFTypeRef?
            AXUIElementCopyAttributeValue(ta, kAXValueAttribute as CFString, &valRef)
            return valRef as? String ?? ""
        }

        // Cache Format menu items via AX for ultra-fast native clicking
        var formatMenuItems: [String: AXUIElement] = [:]
        var menuBarRef: CFTypeRef?
        AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &menuBarRef)
        if let menuBar = menuBarRef {
            var menuBarItemsRef: CFTypeRef?
            AXUIElementCopyAttributeValue(menuBar as! AXUIElement, kAXChildrenAttribute as CFString, &menuBarItemsRef)
            if let menuBarItems = menuBarItemsRef as? [AXUIElement] {
                for item in menuBarItems {
                    var titleRef: CFTypeRef?
                    AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &titleRef)
                    if let title = titleRef as? String, title == "Format" {
                        var menuRef: CFTypeRef?
                        AXUIElementCopyAttributeValue(item, kAXChildrenAttribute as CFString, &menuRef)
                        if let menus = menuRef as? [AXUIElement], let formatMenu = menus.first {
                            var itemsRef: CFTypeRef?
                            AXUIElementCopyAttributeValue(formatMenu, kAXChildrenAttribute as CFString, &itemsRef)
                            if let items = itemsRef as? [AXUIElement] {
                                for mi in items {
                                    var miTitleRef: CFTypeRef?
                                    AXUIElementCopyAttributeValue(mi, kAXTitleAttribute as CFString, &miTitleRef)
                                    if let miTitle = miTitleRef as? String, !miTitle.isEmpty {
                                        formatMenuItems[miTitle] = mi
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        func triggerFormatMenuItem(named name: String) {
            if let mi = formatMenuItems[name] {
                let res = AXUIElementPerformAction(mi, kAXPressAction as CFString)
                if res == .success {
                    usleep(25_000)
                    return
                }
            }
            let script = "tell application \"System Events\" to tell process \"Notes\" to click menu item \"\(name)\" of menu \"Format\" of menu bar 1"
            var err: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&err)
            usleep(30_000)
        }

        // Focus text area
        AXUIElementSetAttributeValue(ta, kAXFocusedAttribute as CFString, true as CFTypeRef)
        usleep(40_000)

        func findRangeOfLine(matching target: String, in text: String) -> (loc: Int, len: Int)? {
            var currentLoc = 0
            let lines = text.components(separatedBy: "\n")
            for line in lines {
                let nsLine = line as NSString
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let clean = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "✓☑○◯⚪️•*-[ ] \t\u{00A0}"))
                if clean == target || clean.caseInsensitiveCompare(target) == .orderedSame {
                    let offsetInLine = (line as NSString).range(of: trimmed).location
                    return (currentLoc + offsetInLine, (trimmed as NSString).length)
                }
                currentLoc += nsLine.length + 1
            }
            return nil
        }

        // 1. Convert ONLY individual task lines to Checklist circles (NEVER the whole document!)
        for title in allTaskTitles {
            let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            let curText = getText()
            if let (loc, len) = findRangeOfLine(matching: clean, in: curText) {
                selectRange(loc: loc, len: len)
                triggerFormatMenuItem(named: "Checklist")
            }
        }

        // 2. Format all division headings strictly as Headings to guarantee NO checklist circles
        for heading in divisionHeadings {
            let curText = getText()
            if let (loc, len) = findRangeOfLine(matching: heading, in: curText) {
                selectRange(loc: loc, len: len)
                triggerFormatMenuItem(named: "Heading")
            }
        }
        let tTitle = getText()
        if let (loc, len) = findRangeOfLine(matching: AppState.shared.notesNoteTitle, in: tTitle) {
            selectRange(loc: loc, len: len)
            triggerFormatMenuItem(named: "Title")
        } else if let (loc, len) = findRangeOfLine(matching: "TASKS — TODAY", in: tTitle) {
            selectRange(loc: loc, len: len)
            triggerFormatMenuItem(named: "Title")
        }

        // 3. Mark completed tasks as checked natively via AX
        let tCompleted = getText()
        for title in completedTitles {
            let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            if let (loc, len) = findRangeOfLine(matching: clean, in: tCompleted) {
                selectRange(loc: loc, len: len)
                triggerFormatMenuItem(named: "Mark as Checked")
            }
        }
        selectRange(loc: 0, len: 0)

        // 4. Always restore previous app unless user explicitly wants Notes open
        if !openNotes, let orig = origApp {
            // Hide Notes window to avoid lingering, then immediately restore
            let hideScript = "tell application \"System Events\" to set visible of process \"Notes\" to false"
            var hErr: NSDictionary?
            NSAppleScript(source: hideScript)?.executeAndReturnError(&hErr)
            usleep(50_000)
            orig.activate()
        }
    }

    private func executeScript(_ source: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var errorDict: NSDictionary?
                guard let script = NSAppleScript(source: source) else {
                    continuation.resume(throwing: NSError(domain: "NotesSync", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create AppleScript."]))
                    return
                }

                script.executeAndReturnError(&errorDict)
                if let error = errorDict {
                    let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
                    continuation.resume(throwing: NSError(domain: "NotesSync", code: 2, userInfo: [NSLocalizedDescriptionKey: message]))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    public func parseNotesBody(_ raw: String) -> [(title: String, workspace: Workspace, isCompleted: Bool)] {
        var results: [(String, Workspace, Bool)] = []
        var currentWorkspace: Workspace = .work
        let noteTitle = AppState.shared.notesNoteTitle.uppercased()
        var reservedHeaders: Set<String> = ["WORK", "PERSONAL", "FREELANCE", "TASKS — TODAY", "TASKS - TODAY", "NO ACTIVE TASKS", "TASKS", noteTitle]
        
        let wsDefs = AppState.shared.workspaces
        var nameToWorkspace: [String: Workspace] = [:]
        for ws in wsDefs {
            let upper = ws.name.uppercased()
            reservedHeaders.insert(upper)
            reservedHeaders.insert(ws.id.uppercased())
            nameToWorkspace[upper] = Workspace(rawValue: ws.id)
            nameToWorkspace[ws.id.uppercased()] = Workspace(rawValue: ws.id)
        }

        var seenTitles: Set<String> = []

        let normalized = raw
            .replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<br/>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "</div>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "</li>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "</p>", with: "\n", options: .caseInsensitive)

        let lines = normalized.components(separatedBy: "\n")
        let checkPrefixes = ["☑", "●", "[x]", "[X]", "✓", "✔"]
        let uncheckPrefixes = ["☐", "○", "◯", "⚪️", "◐", "[ ]", "-", "*", "•"]

        for rawLine in lines {
            let isStrike = rawLine.localizedCaseInsensitiveContains("<strike>") ||
                           rawLine.localizedCaseInsensitiveContains("line-through") ||
                           rawLine.localizedCaseInsensitiveContains("<s>") ||
                           rawLine.localizedCaseInsensitiveContains("<del>")

            var line = rawLine.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            var isCompleted = isStrike
            var cleanTitle = line

            for p in checkPrefixes {
                if cleanTitle.hasPrefix(p) {
                    isCompleted = true
                    cleanTitle = String(cleanTitle.dropFirst(p.count))
                    break
                }
            }
            for p in uncheckPrefixes {
                if cleanTitle.hasPrefix(p) {
                    cleanTitle = String(cleanTitle.dropFirst(p.count))
                    break
                }
            }

            cleanTitle = cleanTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanTitle.isEmpty { continue }

            let upper = cleanTitle.uppercased()

            // Check division header matches
            var matchedWs: Workspace?
            if let direct = nameToWorkspace[upper] {
                matchedWs = direct
            } else {
                for (name, ws) in nameToWorkspace {
                    if upper == "\(name):" || upper == "\(name) TASKS" {
                        matchedWs = ws
                        break
                    }
                }
            }

            if let ws = matchedWs {
                currentWorkspace = ws
                continue
            }

            if reservedHeaders.contains(upper) || upper.contains(noteTitle) || upper.contains("TASKS — TODAY") || upper.contains("TASKS - TODAY") || upper.contains("UPDATED ") || upper.hasPrefix("NO ACTIVE") {
                continue
            }

            // Check bracketed prefix like [Work], [Personal], [Freelance] or [Custom]
            for (name, ws) in nameToWorkspace {
                let prefix = "[\(name.lowercased())]"
                if cleanTitle.lowercased().hasPrefix(prefix) {
                    currentWorkspace = ws
                    cleanTitle = String(cleanTitle.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }

            if cleanTitle.isEmpty || reservedHeaders.contains(cleanTitle.uppercased()) {
                continue
            }

            let dedupKey = "\(currentWorkspace.rawValue)::\(cleanTitle.lowercased())"
            if seenTitles.contains(dedupKey) {
                continue
            }
            seenTitles.insert(dedupKey)

            results.append((cleanTitle, currentWorkspace, isCompleted))
        }
        return results
    }

    private func escapeHtml(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func escapeAppleScript(_ str: String) -> String {
        return str.replacingOccurrences(of: "\\", with: "\\\\")
                  .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
