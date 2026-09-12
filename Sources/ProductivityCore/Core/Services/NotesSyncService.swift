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

        let workTasks = allTasks.filter { $0.workspace == .work && ($0.isScheduledForToday || $0.status == .inProgress || $0.isOverdue) }
        let personalTasks = allTasks.filter { $0.workspace == .personal && ($0.isScheduledForToday || $0.status == .inProgress || $0.isOverdue) }

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

        // HTML version for Apple Notes formatted cleanly under WORK and PERSONAL
        var html = "<div><b><span style=\"font-size: 22px;\">TASKS — TODAY</span></b></div><div><br></div>"
        html += "<div><b>WORK</b></div>"
        if workTasks.isEmpty {
            html += "<div><i><font color=\"#8E8E93\">No active tasks</font></i></div>"
        } else {
            for task in workTasks {
                if task.status == .completed {
                    html += "<div><strike><font color=\"#8E8E93\"><span style=\"color: #34C759;\">✓ </span>\(escapeHtml(task.title))</font></strike></div>"
                } else {
                    html += "<div><font color=\"#8E8E93\">○ </font>\(escapeHtml(task.title))</div>"
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
                    html += "<div><strike><font color=\"#8E8E93\"><span style=\"color: #34C759;\">✓ </span>\(escapeHtml(task.title))</font></strike></div>"
                } else {
                    html += "<div><font color=\"#8E8E93\">○ </font>\(escapeHtml(task.title))</div>"
                }
            }
        }

        return (noteTitle, plainText, html)
    }

    /// Directly pushes changes made in the app to Apple Notes with minimal latency
    public func autoSync(context: ModelContext) {
        autoSyncTask?.cancel()
        autoSyncTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            do {
                try await syncToNotes(from: context, openNotes: false)
            } catch {
                print("Auto-sync to Notes error: \(error)")
            }
        }
    }

    /// Pulls items from Apple Notes into SwiftData (Reverse Sync)
    @discardableResult
    public func pullFromNotes(context: ModelContext) async throws -> (added: Int, updated: Int) {
        // Step 1: Attempt to read native checklist states directly from NoteStore.sqlite
        var parsedItems = fetchItemsFromNoteStore()

        // Step 2: Fallback to AppleScript HTML body if SQLite parser found no items
        if parsedItems.isEmpty {
            let scriptSource = """
            tell application "Notes"
                set targetNotes to (notes whose name is "TASKS — TODAY")
                if (count of targetNotes) > 0 then
                    return body of item 1 of targetNotes
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

        guard !parsedItems.isEmpty else { return (0, 0) }

        let allTasksDescriptor = FetchDescriptor<TaskItem>()
        let existingTasks = (try? context.fetch(allTasksDescriptor)) ?? []

        var addedCount = 0
        var updatedCount = 0

        for item in parsedItems {
            let matching = existingTasks.first {
                $0.workspace == item.workspace &&
                $0.title.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(item.title) == .orderedSame
            }

            if let task = matching {
                // Protect tasks modified locally in the app within the last 20 seconds from being reverted by stale notes
                let isRecentlyModifiedLocally = Date().timeIntervalSince(task.updatedAt) < 20
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
                // New task discovered in Notes! Add it to SwiftData.
                let nextOrder = existingTasks.filter { $0.workspace == item.workspace }.map(\.sortOrder).max() ?? 0
                let newTask = TaskItem(
                    title: item.title,
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

    /// Two-way sync: Pulls user edits from Apple Notes first, then pushes unified state back.
    @discardableResult
    public func syncTwoWay(context: ModelContext, openNotes: Bool = false) async throws -> (added: Int, updated: Int) {
        isSyncing = true
        lastSyncError = nil
        defer { isSyncing = false }

        // Step 1: Pull from Notes to avoid erasing user additions
        let result = (try? await pullFromNotes(context: context)) ?? (0, 0)

        // Step 2: Push unified state back to Notes
        try await syncToNotes(from: context, openNotes: openNotes)

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

    public func syncToNotes(from context: ModelContext, openNotes: Bool = true) async throws {
        let taskDescriptor = FetchDescriptor<TaskItem>(
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        let allTasks = (try? context.fetch(taskDescriptor)) ?? []

        let workTasks = allTasks.filter { $0.workspace == .work && ($0.isScheduledForToday || $0.status == .inProgress || $0.isOverdue) }
        let personalTasks = allTasks.filter { $0.workspace == .personal && ($0.isScheduledForToday || $0.status == .inProgress || $0.isOverdue) }

        if !AXIsProcessTrusted() {
            Self.requestAccessibilityPermission()
            try await syncViaHTML(from: context)
            self.lastSyncTime = Date()
            return
        }

        do {
            try await syncViaKeystrokes(workTasks: workTasks, personalTasks: personalTasks)
        } catch {
            Self.requestAccessibilityPermission()
            try await syncViaHTML(from: context)
        }

        self.lastSyncTime = Date()
    }

    private func syncViaHTML(from context: ModelContext) async throws {
        let (_, _, htmlBody) = buildNotesContent(from: context)
        let escapedBody = htmlBody.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let scriptSource = """
        tell application "Notes"
            reopen
            activate
            set noteTitle to "TASKS — TODAY"
            set noteHTML to "\(escapedBody)"
            set targetNotes to (notes of folder "Notes" of default account whose name is noteTitle)
            if (count of targetNotes) = 0 then
                set targetNotes to (notes of default account whose name is noteTitle)
            end if
            if (count of targetNotes) = 0 then
                try
                    make new note at default account with properties {name:noteTitle, body:noteHTML}
                on error
                    make new note with properties {name:noteTitle, body:noteHTML}
                end try
            else
                set body of item 1 of targetNotes to noteHTML
            end if
            show item 1 of (notes of default account whose name is noteTitle)
        end tell
        """
        try await executeScript(scriptSource)
    }

    private func syncViaKeystrokes(workTasks: [TaskItem], personalTasks: [TaskItem]) async throws {
        let escapeAppleScript: (String) -> String = { str in
            str.replacingOccurrences(of: "\\", with: "\\\\")
               .replacingOccurrences(of: "\"", with: "\\\"")
        }

        var scriptLines: [String] = []
        scriptLines.append("""
        tell application "Notes"
            reopen
            activate
            set noteTitle to "TASKS — TODAY"
            set targetNotes to (notes of folder "Notes" of default account whose name is noteTitle)
            if (count of targetNotes) = 0 then
                set targetNotes to (notes of default account whose name is noteTitle)
            end if
            if (count of targetNotes) = 0 then
                try
                    make new note at default account with properties {name:noteTitle, body:""}
                on error
                    make new note with properties {name:noteTitle, body:""}
                end try
                set targetNotes to (notes of default account whose name is noteTitle)
            end if
            show item 1 of targetNotes
        end tell

        delay 0.6

        tell application "System Events"
            tell process "Notes"
                repeat with w in (every window whose role is "AXWindow")
                    set targetTA to missing value
                    try
                        set taList to (every text area of scroll area 3 of splitter group 1 of w)
                        if (count of taList) > 0 then
                            set targetTA to item 1 of taList
                        end if
                    end try
                    if targetTA is missing value then
                        try
                            set taList to (every text area of scroll area 2 of splitter group 1 of w)
                            if (count of taList) > 0 then
                                set targetTA to item 1 of taList
                            end if
                        end try
                    end if

                    if targetTA is not missing value then
                        set focused of targetTA to true
                        delay 0.1
                        keystroke "a" using {command down}
                        key code 51 -- delete
                        delay 0.05

                        -- Title
                        keystroke "TASKS — TODAY"
                        key code 36
                        key code 36

                        -- WORK Section
                        keystroke "WORK"
                        key code 36
        """)

        if workTasks.isEmpty {
            scriptLines.append("""
                        keystroke "No active tasks"
                        key code 36
                        key code 36
            """)
        } else {
            scriptLines.append("""
                        delay 0.1
                        keystroke "l" using {shift down, command down} -- Start checklist
                        delay 0.1
            """)
            for task in workTasks {
                let escaped = escapeAppleScript(task.title)
                scriptLines.append("""
                        keystroke "\(escaped)"
                """)
                if task.status == .completed {
                    scriptLines.append("""
                        delay 0.05
                        keystroke "u" using {shift down, command down} -- Mark as Checked
                        delay 0.05
                    """)
                }
                scriptLines.append("""
                        key code 36
                        delay 0.08
                """)
            }
            scriptLines.append("""
                        delay 0.1
                        keystroke "l" using {shift down, command down} -- Stop checklist
                        delay 0.1
                        key code 36
            """)
        }

        scriptLines.append("""
                        -- PERSONAL Section
                        keystroke "PERSONAL"
                        key code 36
        """)

        if personalTasks.isEmpty {
            scriptLines.append("""
                        keystroke "No active tasks"
                        key code 36
            """)
        } else {
            scriptLines.append("""
                        delay 0.1
                        keystroke "l" using {shift down, command down} -- Start checklist
                        delay 0.1
            """)
            for task in personalTasks {
                let escaped = escapeAppleScript(task.title)
                scriptLines.append("""
                        keystroke "\(escaped)"
                """)
                if task.status == .completed {
                    scriptLines.append("""
                        delay 0.05
                        keystroke "u" using {shift down, command down} -- Mark as Checked
                        delay 0.05
                    """)
                }
                scriptLines.append("""
                        key code 36
                        delay 0.08
                """)
            }
            scriptLines.append("""
                        delay 0.1
                        keystroke "l" using {shift down, command down} -- Stop checklist
            """)
        }

        scriptLines.append("""
                        exit repeat
                    end if
                end repeat
            end tell
        end tell
        """)

        try await executeScript(scriptLines.joined(separator: "\n"))
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

        let normalized = raw
            .replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<br/>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "</div>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "</li>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "</p>", with: "\n", options: .caseInsensitive)

        let lines = normalized.components(separatedBy: "\n")
        for rawLine in lines {
            let isStrike = rawLine.localizedCaseInsensitiveContains("<strike>") ||
                           rawLine.localizedCaseInsensitiveContains("line-through") ||
                           rawLine.localizedCaseInsensitiveContains("<s>") ||
                           rawLine.localizedCaseInsensitiveContains("<del>")

            var line = rawLine.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            let upper = line.uppercased()
            if upper == "TASKS — TODAY" || upper.contains("UPDATED ") { continue }
            if upper == "WORK" {
                currentWorkspace = .work
                continue
            }
            if upper == "PERSONAL" {
                currentWorkspace = .personal
                continue
            }
            if upper == "NO ACTIVE TASKS" {
                continue
            }

            var isCompleted = isStrike
            var cleanTitle = line

            let checkPrefixes = ["☑", "●", "[x]", "[X]", "✓", "✔"]
            let uncheckPrefixes = ["☐", "○", "◯", "⚪️", "[ ]", "-", "*", "•"]

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
            if cleanTitle.hasPrefix("[Work]") || cleanTitle.hasPrefix("[work]") {
                currentWorkspace = .work
                cleanTitle = String(cleanTitle.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if cleanTitle.hasPrefix("[Personal]") || cleanTitle.hasPrefix("[personal]") {
                currentWorkspace = .personal
                cleanTitle = String(cleanTitle.dropFirst(10)).trimmingCharacters(in: .whitespacesAndNewlines)
            }

            if !cleanTitle.isEmpty {
                results.append((cleanTitle, currentWorkspace, isCompleted))
            }
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
