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

        // HTML version for Apple Notes: uses <h1> and <h2> semantic headers so Notes displays clean headings without checklist circles
        var html = "<div><b><h1>TASKS — TODAY</h1></b></div><div><br></div>"
        html += "<div><h2>WORK</h2></div>"
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
        html += "<div><h2>PERSONAL</h2></div>"
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
            // 3 seconds debounce: Responsive background sync without thrashing or lag
            try? await Task.sleep(nanoseconds: 3_000_000_000)
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

        let notesKeys = Set(parsedItems.map { "\($0.workspace.rawValue)::\($0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())" })
        let reservedHeaders: Set<String> = ["WORK", "PERSONAL", "TASKS — TODAY", "TASKS - TODAY", "NO ACTIVE TASKS", "TASKS"]

        // 1. Purge corrupted tasks and synchronize deletions from Apple Notes
        var purgedAny = false
        var validExistingTasks: [TaskItem] = []
        for task in existingTasks {
            let clean = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let upper = clean.uppercased()

            // Delete headers or multiline corruption immediately
            if reservedHeaders.contains(upper) || upper.contains("TASKS — TODAY") || upper.contains("TASKS - TODAY") || clean.contains("\n") || clean.contains("\r") {
                context.delete(task)
                purgedAny = true
                continue
            }

            let key = "\(task.workspace.rawValue)::\(clean.lowercased())"
            let isTodayScope = task.isScheduledForToday || task.status == .inProgress || task.isOverdue || (task.completedAt.map { Calendar.current.isDateInToday($0) } ?? false)

            // If a task in today's scope is no longer in Apple Notes, and wasn't just created/edited locally, remove it
            if isTodayScope && !notesKeys.contains(key) {
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
        var seenTitles = Set(validExistingTasks.map { "\($0.workspace.rawValue)::\($0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())" })

        for item in parsedItems {
            let cleanTitle = item.title.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanTitle.isEmpty else { continue }
            let upper = cleanTitle.uppercased()
            if reservedHeaders.contains(upper) || upper.contains("TASKS — TODAY") || upper.contains("TASKS - TODAY") {
                continue
            }

            let key = "\(item.workspace.rawValue)::\(cleanTitle.lowercased())"

            let matching = validExistingTasks.first {
                $0.workspace == item.workspace &&
                $0.title.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(cleanTitle) == .orderedSame
            }

            if let task = matching {
                // ProductivityApp is the primary Proof DB:
                // Protect tasks modified locally in the app within the last 3 seconds from being overwritten
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
            } else if !seenTitles.contains(key) {
                // New task discovered in Notes: insert once, avoiding double/triple entry
                seenTitles.insert(key)
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

        // Collect task titles per workspace and completed titles
        let taskDescriptor = FetchDescriptor<TaskItem>(
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        let allTasks = (try? context.fetch(taskDescriptor)) ?? []
        
        let workTasks = allTasks.filter { $0.workspace == .work && ($0.isScheduledForToday || $0.status == .inProgress || $0.isOverdue || ($0.completedAt.map { Calendar.current.isDateInToday($0) } ?? false)) }
        let personalTasks = allTasks.filter { $0.workspace == .personal && ($0.isScheduledForToday || $0.status == .inProgress || $0.isOverdue || ($0.completedAt.map { Calendar.current.isDateInToday($0) } ?? false)) }

        var completedTitles: [String] = []
        for task in (workTasks + personalTasks) where task.status == .completed {
            completedTitles.append(task.title)
        }

        try await syncDirectlyToNotes(
            htmlBody: content.htmlBody,
            workTaskTitles: workTasks.map(\.title),
            personalTaskTitles: personalTasks.map(\.title),
            completedTitles: completedTitles,
            openNotes: openNotes
        )
        self.lastSyncTime = Date()
    }

    /// Pure backend AppleScript sync: updates Apple Notes atomically, then applies native checklist format via System Events.
    private func syncDirectlyToNotes(
        htmlBody: String,
        workTaskTitles: [String] = [],
        personalTaskTitles: [String] = [],
        completedTitles: [String] = [],
        openNotes: Bool = false
    ) async throws {
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

        // Apply native checklist format via System Events & Accessibility
        do {
            try await applyNativeChecklist(
                openNotes: openNotes,
                workTaskTitles: workTaskTitles,
                personalTaskTitles: personalTaskTitles,
                completedTitles: completedTitles
            )
            NSLog("✅ NotesSyncService: Native checklist format applied successfully!")
        } catch {
            NSLog("⚠️ NotesSyncService: Native checklist format error: %@", error.localizedDescription)
            self.lastSyncError = error.localizedDescription
        }
    }

    /// Briefly activates Notes, applies Checklist format ONLY to task lines (ensuring WORK and PERSONAL are strictly Headings),
    /// marks completed tasks as checked, then restores previous app.
    private func applyNativeChecklist(
        openNotes: Bool,
        workTaskTitles: [String],
        personalTaskTitles: [String],
        completedTitles: [String]
    ) async throws {
        let origApp = NSWorkspace.shared.frontmostApplication

        // 1. Activate Notes and show note
        let showScript = """
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
                usleep(30_000)
            }
        }

        func getText() -> String {
            var valRef: CFTypeRef?
            AXUIElementCopyAttributeValue(ta, kAXValueAttribute as CFString, &valRef)
            return valRef as? String ?? ""
        }

        func triggerFormatMenuItem(named name: String) {
            let script = "tell application \"System Events\" to tell process \"Notes\" to click menu item \"\(name)\" of menu \"Format\" of menu bar 1"
            var err: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&err)
            usleep(40_000)
        }

        // Focus text area
        AXUIElementSetAttributeValue(ta, kAXFocusedAttribute as CFString, true as CFTypeRef)
        usleep(50_000)

        func findRangeOfLine(matching target: String, in text: String) -> (loc: Int, len: Int)? {
            var currentLoc = 0
            let lines = text.components(separatedBy: "\n")
            for line in lines {
                let nsLine = line as NSString
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let clean = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "✓☑○◯⚪️•*-[ ] \t"))
                if clean == target || clean.caseInsensitiveCompare(target) == .orderedSame {
                    let offsetInLine = (line as NSString).range(of: trimmed).location
                    return (currentLoc + offsetInLine, (trimmed as NSString).length)
                }
                currentLoc += nsLine.length + 1
            }
            return nil
        }

        // 1. Convert ONLY individual task lines to Checklist circles (NEVER the whole document!)
        let allTaskTitles = workTaskTitles + personalTaskTitles
        for title in allTaskTitles {
            let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            let curText = getText()
            if let (loc, len) = findRangeOfLine(matching: clean, in: curText) {
                selectRange(loc: loc, len: len)
                triggerFormatMenuItem(named: "Checklist")
            }
        }

        // 2. Format WORK and PERSONAL strictly as Headings to guarantee NO checklist circles
        let tHeadings = getText()
        if let (loc, len) = findRangeOfLine(matching: "WORK", in: tHeadings) {
            selectRange(loc: loc, len: len)
            triggerFormatMenuItem(named: "Heading")
        }
        let tHeadings2 = getText()
        if let (loc, len) = findRangeOfLine(matching: "PERSONAL", in: tHeadings2) {
            selectRange(loc: loc, len: len)
            triggerFormatMenuItem(named: "Heading")
        }
        let tHeadings3 = getText()
        if let (loc, len) = findRangeOfLine(matching: "TASKS — TODAY", in: tHeadings3) {
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

        // 4. Restore previous app if openNotes is false
        if !openNotes, let orig = origApp {
            usleep(100_000)
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
