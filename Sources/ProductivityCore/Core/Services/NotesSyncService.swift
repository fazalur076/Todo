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
        let noteTitle = "TASKS — TODAY"

        let taskDescriptor = FetchDescriptor<TaskItem>(
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        let allTasks = (try? context.fetch(taskDescriptor)) ?? []

        let workTasks = allTasks.filter { $0.workspace == .work && ($0.isScheduledForToday || $0.status == .inProgress || $0.isOverdue || ($0.completedAt.map { Calendar.current.isDateInToday($0) } ?? false)) }
        let personalTasks = allTasks.filter { $0.workspace == .personal && ($0.isScheduledForToday || $0.status == .inProgress || $0.isOverdue || ($0.completedAt.map { Calendar.current.isDateInToday($0) } ?? false)) }

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        let updatedTime = timeFormatter.string(from: Date())

        // Plain text version with clean circular checklist symbols
        var plain: [String] = []
        plain.append("TASKS — TODAY")
        plain.append("")
        plain.append("WORK")
        if workTasks.isEmpty {
            plain.append("No active tasks")
        } else {
            for task in workTasks {
                let mark = task.status == .completed ? "✓" : "○"
                plain.append("\(mark) \(task.title)")
            }
        }
        plain.append("")
        plain.append("PERSONAL")
        if personalTasks.isEmpty {
            plain.append("No active tasks")
        } else {
            for task in personalTasks {
                let mark = task.status == .completed ? "✓" : "○"
                plain.append("\(mark) \(task.title)")
            }
        }
        plain.append("")
        plain.append("Updated \(updatedTime)")

        let plainText = plain.joined(separator: "\n")

        // HTML version for Apple Notes: uses <div> lines so ⇧⌘L directly formats into native checklists
        var html = "<div><b><span style=\"font-size: 20px;\">TASKS — TODAY</span></b></div><div><br></div>"
        html += "<div><b>WORK</b></div>"
        if workTasks.isEmpty {
            html += "<div><i><font color=\"#8E8E93\">No active tasks</font></i></div>"
        } else {
            for task in workTasks {
                if task.status == .completed {
                    html += "<div><strike><font color=\"#8E8E93\">\(escapeHtml(task.title))</font></strike></div>"
                } else {
                    html += "<div>\(escapeHtml(task.title))</div>"
                }
            }
        }
        html += "<div><br></div>"
        html += "<div><b>PERSONAL</b></div>"
        if personalTasks.isEmpty {
            html += "<div><i><font color=\"#8E8E93\">No active tasks</font></i></div>"
        } else {
            for task in personalTasks {
                if task.status == .completed {
                    html += "<div><strike><font color=\"#8E8E93\">\(escapeHtml(task.title))</font></strike></div>"
                } else {
                    html += "<div>\(escapeHtml(task.title))</div>"
                }
            }
        }

        return (noteTitle, plainText, html)
    }

    /// Pushes changes made in the app to Apple Notes after a 15-second background debounce window
    public func autoSync(context: ModelContext) {
        autoSyncTask?.cancel()
        autoSyncTask = Task { @MainActor in
            // 15 seconds debounce: Calm background sync without thrashing or interrupting user flow
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            guard self.needsPushToNotes(context: context) else { return }
            do {
                try await self.syncToNotes(from: context, openNotes: false)
            } catch {
                print("Auto-sync to Notes error: \(error)")
            }
        }
    }

    /// Pulls items from Apple Notes into SwiftData (Reverse Sync)
    @discardableResult
    public func pullFromNotes(context: ModelContext) async throws -> (added: Int, updated: Int) {
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
        if parsedItems.isEmpty {
            let scriptSource = """
            tell application "Notes"
                set activeNotes to {}
                repeat with n in (notes whose name is "TASKS — TODAY")
                    try
                        set c to container of n
                        if (name of c) is not "Recently Deleted" then
                            set end of activeNotes to n
                        end if
                    end try
                end repeat
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

        // Purge any corrupted header tasks that might have previously slipped into the DB
        var purgedAny = false
        for task in existingTasks {
            let clean = task.title.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if clean == "TASKS — TODAY" || clean == "WORK" || clean == "PERSONAL" || clean == "NO ACTIVE TASKS" || clean.contains("TASKS — TODAY") {
                context.delete(task)
                purgedAny = true
            }
        }
        if purgedAny {
            try? context.save()
        }

        if parsedItems.isEmpty {
            // If the note was deleted and not found in Notes, recreate it from the app!
            if !existingTasks.isEmpty {
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
        var seenTitles = Set(existingTasks.map { "\($0.workspace.rawValue)::\($0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())" })
        let reservedHeaders: Set<String> = ["WORK", "PERSONAL", "TASKS — TODAY", "TASKS - TODAY", "NO ACTIVE TASKS", "TASKS"]

        for item in parsedItems {
            let cleanTitle = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanTitle.isEmpty else { continue }
            let upper = cleanTitle.uppercased()
            if reservedHeaders.contains(upper) || upper.contains("TASKS — TODAY") || upper.contains("TASKS - TODAY") {
                continue
            }

            let key = "\(item.workspace.rawValue)::\(cleanTitle.lowercased())"

            let matching = existingTasks.first {
                $0.workspace == item.workspace &&
                $0.title.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(cleanTitle) == .orderedSame
            }

            if let task = matching {
                // ProductivityApp is the primary Proof DB:
                // Protect tasks modified locally in the app within the last 15 seconds from being overwritten
                let isRecentlyModifiedLocally = Date().timeIntervalSince(task.updatedAt) < 15.0
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
            } else if !seenTitles.contains(key) {
                // New task discovered in Notes: insert once, avoiding double/triple entry
                seenTitles.insert(key)
                let nextOrder = (existingTasks.filter { $0.workspace == item.workspace }.map(\.sortOrder).max() ?? 0) + addedCount
                let newTask = TaskItem(
                    title: cleanTitle,
                    workspace: item.workspace,
                    status: item.isCompleted ? .completed : .pending,
                    sortOrder: nextOrder + 1
                )
                context.insert(newTask)
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
        let candidates = [
            Bundle.main.resourcePath.map { "\($0)/note_extractor.py" },
            "/Users/fazalurrahman/Desktop/Projects/Todo/Sources/ProductivityCore/Resources/note_extractor.py",
            "/Users/fazalurrahman/Desktop/Projects/Todo/ProductivityApp.app/Contents/Resources/note_extractor.py"
        ].compactMap { $0 }

        for path in candidates {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [path]
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
                        ($0.title, Workspace(rawValue: $0.workspace) ?? .work, $0.completed)
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

        let localWorkTasks = allTasks.filter { $0.workspace == .work && ($0.isScheduledForToday || $0.status == .inProgress || $0.isOverdue || ($0.completedAt.map { Calendar.current.isDateInToday($0) } ?? false)) }
        let localPersonalTasks = allTasks.filter { $0.workspace == .personal && ($0.isScheduledForToday || $0.status == .inProgress || $0.isOverdue || ($0.completedAt.map { Calendar.current.isDateInToday($0) } ?? false)) }

        if !noteExistsInNotes() {
            return !localWorkTasks.isEmpty || !localPersonalTasks.isEmpty
        }

        let notesItems = fetchCurrentNotesItems()
        if notesItems.isEmpty {
            return !localWorkTasks.isEmpty || !localPersonalTasks.isEmpty
        }

        let notesWork = notesItems.filter { $0.workspace == .work }
        let notesPersonal = notesItems.filter { $0.workspace == .personal }

        if localWorkTasks.count != notesWork.count || localPersonalTasks.count != notesPersonal.count {
            return true
        }

        for local in localWorkTasks {
            guard let match = notesWork.first(where: {
                $0.title.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(local.title.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
            }) else {
                return true
            }
            if match.isCompleted != (local.status == .completed) {
                return true
            }
        }

        for local in localPersonalTasks {
            guard let match = notesPersonal.first(where: {
                $0.title.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(local.title.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
            }) else {
                return true
            }
            if match.isCompleted != (local.status == .completed) {
                return true
            }
        }

        return false
    }

    private func fetchCurrentNotesItems() -> [(title: String, workspace: Workspace, isCompleted: Bool)] {
        let storeItems = fetchItemsFromNoteStore()
        if !storeItems.isEmpty {
            return storeItems
        }

        let scriptSource = """
        tell application "Notes"
            set activeNotes to {}
            repeat with n in (notes whose name is "TASKS — TODAY")
                try
                    set c to container of n
                    if (name of c) is not "Recently Deleted" then
                        set end of activeNotes to n
                    end if
                end try
            end repeat
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

    /// Checks whether an active (non-deleted) TASKS — TODAY note exists in Apple Notes
    public func noteExistsInNotes() -> Bool {
        let scriptSource = """
        tell application "Notes"
            set activeNotes to {}
            repeat with n in (notes whose name is "TASKS — TODAY")
                try
                    set c to container of n
                    if (name of c) is not "Recently Deleted" then
                        set end of activeNotes to n
                    end if
                end try
            end repeat
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

    public func syncToNotes(from context: ModelContext, openNotes: Bool = false) async throws {
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
        try await syncDirectlyToNotes(htmlBody: content.htmlBody, openNotes: openNotes)
        self.lastSyncTime = Date()
    }

    /// Pure backend AppleScript sync: updates Apple Notes atomically, then applies native checklist format via System Events.
    private func syncDirectlyToNotes(htmlBody: String, openNotes: Bool = false) async throws {
        let escapeAppleScript: (String) -> String = { str in
            str.replacingOccurrences(of: "\\", with: "\\\\")
               .replacingOccurrences(of: "\"", with: "\\\"")
        }

        var scriptLines: [String] = []
        scriptLines.append("""
        tell application "Notes"
            set noteTitle to "TASKS — TODAY"
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

        // Apply native checklist format via System Events (brief stealth focus switch < 1s)
        do {
            try await applyNativeChecklist(openNotes: openNotes)
            NSLog("✅ NotesSyncService: Native checklist format applied successfully!")
        } catch {
            NSLog("⚠️ NotesSyncService: Native checklist format error: %@", error.localizedDescription)
            self.lastSyncError = error.localizedDescription
        }
    }

    /// Briefly activates Notes, selects all, applies Checklist format (⌘⇧L), formats title, then restores previous app if not openNotes.
    /// Requires Accessibility permission.
    private func applyNativeChecklist(openNotes: Bool) async throws {
        let checklistScript = """
        -- Remember the current frontmost app
        tell application "System Events"
            set origApp to name of first application process whose frontmost is true
        end tell

        -- Open the note in Notes
        tell application "Notes"
            set activeNotes to {}
            repeat with n in (notes whose name is "TASKS — TODAY")
                try
                    set c to container of n
                    if (name of c) is not "Recently Deleted" then
                        set end of activeNotes to n
                    end if
                end try
            end repeat
            if (count of activeNotes) > 0 then
                activate
                show item 1 of activeNotes
            else
                return
            end if
        end tell

        delay 0.5

        -- Select all and apply checklist format
        tell application "System Events"
            tell process "Notes"
                repeat with attempt from 1 to 5
                    set targetTA to missing value
                    try
                        set taList to (every text area of scroll area 3 of splitter group 1 of window 1)
                        if (count of taList) > 0 then
                            set targetTA to item 1 of taList
                        end if
                    end try
                    if targetTA is missing value then
                        try
                            set taList to (every text area of scroll area 2 of splitter group 1 of window 1)
                            if (count of taList) > 0 then
                                set targetTA to item 1 of taList
                            end if
                        end try
                    end if

                    if targetTA is not missing value then
                        set focused of targetTA to true
                        delay 0.1
                        keystroke "a" using {command down}
                        delay 0.15
                        keystroke "l" using {command down, shift down}
                        delay 0.1
                        -- Move cursor to top and format first line as Title so header is clean
                        key code 126 using {command down}
                        delay 0.1
                        keystroke "t" using {command down, shift down}
                        exit repeat
                    else
                        delay 0.2
                    end if
                end repeat
            end tell
        end tell

        delay 0.2

        -- Restore previous app if openNotes is false
        if not \(openNotes) then
            tell application origApp to activate
        end if
        """

        try await executeScript(checklistScript)
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
        let reservedHeaders: Set<String> = ["WORK", "PERSONAL", "TASKS — TODAY", "TASKS - TODAY", "NO ACTIVE TASKS", "TASKS"]
        var seenTitles: Set<String> = []

        let normalized = raw
            .replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<br/>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "</div>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "</li>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "</p>", with: "\n", options: .caseInsensitive)

        let lines = normalized.components(separatedBy: "\n")
        let checkPrefixes = ["☑", "●", "[x]", "[X]", "✓", "✔"]
        let uncheckPrefixes = ["☐", "○", "◯", "⚪️", "[ ]", "-", "*", "•"]

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
            if upper == "WORK" || upper.hasPrefix("WORK:") || upper == "WORK TASKS" {
                currentWorkspace = .work
                continue
            }
            if upper == "PERSONAL" || upper.hasPrefix("PERSONAL:") || upper == "PERSONAL TASKS" {
                currentWorkspace = .personal
                continue
            }
            if reservedHeaders.contains(upper) || upper.contains("TASKS — TODAY") || upper.contains("TASKS - TODAY") || upper.contains("UPDATED ") || upper.hasPrefix("NO ACTIVE") {
                continue
            }

            if cleanTitle.hasPrefix("[Work]") || cleanTitle.hasPrefix("[work]") {
                currentWorkspace = .work
                cleanTitle = String(cleanTitle.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if cleanTitle.hasPrefix("[Personal]") || cleanTitle.hasPrefix("[personal]") {
                currentWorkspace = .personal
                cleanTitle = String(cleanTitle.dropFirst(10)).trimmingCharacters(in: .whitespacesAndNewlines)
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
}
