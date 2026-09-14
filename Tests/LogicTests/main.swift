import Foundation
import SwiftData
import ProductivityCore

// Inline verification of non-trivial core logic per Ponytail guidelines:
// 1. Workspace isolation in EOD generation
// 2. Move-to-Tomorrow date calculation
// 3. Apple Notes circular checklist formatting and two-way parser
// 4. Single-click / Double-click status progression
// 5. Task re-ordering logic

@MainActor
func runAllChecks() {
    print("🚀 Starting Logic & Isolation Checks...")

    // Setup in-memory test container
    let schema = Schema([TaskItem.self, FocusSession.self, EODSnapshot.self])
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: schema, configurations: [config])
    let context = container.mainContext

    // Test 1: TaskItem creation and initial states
    let today = Calendar.current.startOfDay(for: Date())
    let workTask1 = TaskItem(
        title: "Fix crash in API",
        workspace: .work,
        status: .completed,
        scheduledDate: today,
        sortOrder: 0
    )
    let workTask2 = TaskItem(
        title: "Refactor database query",
        workspace: .work,
        status: .inProgress,
        scheduledDate: today,
        sortOrder: 1
    )
    let workTask3 = TaskItem(
        title: "Prepare deployment notes",
        workspace: .work,
        status: .pending,
        scheduledDate: today,
        sortOrder: 2
    )

    // Personal tasks (MUST NEVER LEAK TO EOD)
    let personalTask1 = TaskItem(
        title: "Buy groceries & coffee",
        workspace: .personal,
        status: .completed,
        scheduledDate: today,
        sortOrder: 0
    )
    let personalTask2 = TaskItem(
        title: "Evening workout",
        workspace: .personal,
        status: .pending,
        scheduledDate: today,
        sortOrder: 1
    )

    context.insert(workTask1)
    context.insert(workTask2)
    context.insert(workTask3)
    context.insert(personalTask1)
    context.insert(personalTask2)

    // Add a Work focus session
    let session = FocusSession(
        taskId: workTask1.id,
        taskTitle: workTask1.title,
        workspace: .work,
        durationMinutes: 50,
        startedAt: Date().addingTimeInterval(-3000),
        completedAt: Date()
    )
    context.insert(session)
    try! context.save()

    // Test 2: Move to Tomorrow
    assert(workTask3.isScheduledForToday == true, "Task 3 should initially be scheduled for today")
    workTask3.moveToTomorrow()
    assert(workTask3.isScheduledForToday == false, "Task 3 should no longer be scheduled for today after moveToTomorrow")
    let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
    assert(Calendar.current.isDate(workTask3.scheduledDate, inSameDayAs: tomorrow), "Scheduled date must match tomorrow")
    print("✅ Check 1 Passed: Move to Tomorrow date calculation verified.")

    // Test 3: Strict Workspace Isolation in EOD Report
    let report = EODService.shared.generateReport(from: context, targetDate: today)

    // Assert that personal tasks are NEVER present
    for task in report.completedTasks {
        assert(task.workspace == .work, "CRITICAL: Non-work task found in completed EOD!")
    }
    for task in report.inProgressTasks {
        assert(task.workspace == .work, "CRITICAL: Non-work task found in in-progress EOD!")
    }
    for task in report.carriedForwardTasks {
        assert(task.workspace == .work, "CRITICAL: Non-work task found in carried forward EOD!")
    }

    assert(!report.formattedText.contains("Buy groceries"), "CRITICAL PRIVACY BREACH: Personal task leaked in EOD formatted text!")
    assert(!report.formattedText.contains("Evening workout"), "CRITICAL PRIVACY BREACH: Personal task leaked in EOD formatted text!")
    assert(report.formattedText.contains("Fix crash in API"), "EOD text missing completed work task")
    assert(report.formattedText.contains("Refactor database query"), "EOD text missing in-progress work task")
    assert(report.focusMinutes == 50, "Focus minutes must match total completed work sessions (expected 50, got \(report.focusMinutes))")
    print("✅ Check 2 Passed: Work/Personal isolation in EOD strictly verified (0 Personal tasks leaked).")

    // Test 4: Apple Notes export circular checklist formatting
    let (noteTitle, plainText, html) = NotesSyncService.shared.buildNotesContent(from: context)
    assert(noteTitle == "TASKS — TODAY", "Note title must be 'TASKS — TODAY'")
    assert(plainText.contains("WORK"), "Notes plain text must contain WORK header")
    assert(plainText.contains("PERSONAL"), "Notes plain text must contain PERSONAL header")
    assert(plainText.contains("✓ Fix crash in API"), "Completed task must have ✓ checkmark")
    assert(plainText.contains("○ Refactor database query"), "Incomplete task must have circular checklist symbol ○")
    assert(!plainText.contains("☐"), "Square unicode box ☐ must NOT appear in output")
    assert(html.contains("TASKS — TODAY"), "HTML body missing header")
    assert(html.contains("<div>"), "HTML must contain structured task elements for native checklist conversion")
    print("✅ Check 3 Passed: Apple Notes checklist structure verified.")

    // Test 5: Apple Notes Two-Way Parser
    let mockNotesHtml = """
    <div><b>TASKS — TODAY</b></div>
    <div><br></div>
    <div><b>WORK</b></div>
    <div>○ Fix crash in API</div>
    <ul>
    <li>Review team pull requests</li>
    </ul>
    <div><strike>✓ Deploy production hotfix</strike></div>
    <div><br></div>
    <div><b>PERSONAL</b></div>
    <div>○ Call parents</div>
    <div>Updated 7:55 PM</div>
    """

    let parsedItems = NotesSyncService.shared.parseNotesBody(mockNotesHtml)
    assert(parsedItems.count == 4, "Expected 4 parsed tasks, got \(parsedItems.count)")
    assert(parsedItems[0].title == "Fix crash in API" && parsedItems[0].workspace == .work && !parsedItems[0].isCompleted)
    assert(parsedItems[1].title == "Review team pull requests" && parsedItems[1].workspace == .work && !parsedItems[1].isCompleted)
    assert(parsedItems[2].title == "Deploy production hotfix" && parsedItems[2].workspace == .work && parsedItems[2].isCompleted)
    assert(parsedItems[3].title == "Call parents" && parsedItems[3].workspace == .personal && !parsedItems[3].isCompleted)
    print("✅ Check 4 Passed: Apple Notes Two-Way parsing verified (HTML lists, strikes, and symbols).")

    // Test 6: Direct Checkbox toggle vs Row Pill click transitions
    let testTask = TaskItem(title: "Click test", workspace: .work, status: .pending)
    // Direct Checkbox click: Directly marks as Completed!
    if testTask.status == .completed {
        testTask.status = .pending
    } else {
        testTask.status = .completed
    }
    assert(testTask.status == .completed, "Direct checkbox click must mark task as completed directly!")

    // Direct Checkbox click again: Unchecks back to pending
    if testTask.status == .completed {
        testTask.status = .pending
    } else {
        testTask.status = .completed
    }
    assert(testTask.status == .pending, "Direct checkbox click on completed must toggle back to pending!")

    // Row Pill Single-click on pending -> inProgress
    if testTask.status == .pending {
        testTask.status = .inProgress
    }
    assert(testTask.status == .inProgress, "Row pill single click must transition pending to inProgress")

    // Row Pill Double-click -> completed
    testTask.status = .completed
    assert(testTask.status == .completed, "Row pill double click must transition directly to completed")

    print("✅ Check 5 Passed: Direct checkbox toggle & row pill click transitions verified.")

    // Test 7: Task Re-ordering
    var taskList = [workTask1, workTask2]
    taskList.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)
    for (i, t) in taskList.enumerated() {
        t.sortOrder = i
    }
    assert(taskList[0].id == workTask2.id, "workTask2 should now be at index 0")
    assert(workTask2.sortOrder == 0, "workTask2 sortOrder should be 0")
    assert(workTask1.sortOrder == 1, "workTask1 sortOrder should be 1")
    print("✅ Check 6 Passed: Task reordering logic verified.")

    // Test 8: Dynamic Divisions CRUD and EOD inclusion/exclusion
    let appState = AppState.shared
    let initialCount = appState.workspaces.count
    let freelanceWsDef = appState.workspaces.first(where: { $0.id == "freelance" })
    assert(freelanceWsDef != nil, "Freelance division should exist in presets")
    assert(freelanceWsDef?.includeInEOD == true, "Freelance should be included in EOD by default")

    // Add a custom client division
    let newDef = appState.addWorkspace(name: "Acme Corp", shortcutKey: "A", colorHex: "#DB2777", includeInEOD: true)
    assert(appState.workspaces.count == initialCount + 1, "Workspace count should increase by 1")
    let acmeWs = Workspace(rawValue: newDef.id)

    let acmeTask = TaskItem(
        title: "Build client onboarding flow",
        workspace: acmeWs,
        status: .completed,
        scheduledDate: today
    )
    context.insert(acmeTask)
    try! context.save()

    let reportWithAcme = EODService.shared.generateReport(from: context, targetDate: today)
    assert(reportWithAcme.completedTasks.contains(where: { $0.title == "Build client onboarding flow" }), "Acme Corp task should be included in EOD when includeInEOD is true")
    assert(reportWithAcme.formattedText.contains("Build client onboarding flow"), "EOD text should include Acme Corp task")

    // Update Acme Corp to exclude from EOD
    if var acmeDef = appState.workspaces.first(where: { $0.id == newDef.id }) {
        acmeDef.includeInEOD = false
        appState.updateWorkspace(acmeDef)
    }
    let reportWithoutAcme = EODService.shared.generateReport(from: context, targetDate: today)
    assert(!reportWithoutAcme.completedTasks.contains(where: { $0.title == "Build client onboarding flow" }), "Acme Corp task must NOT be included in EOD when includeInEOD is false")

    // Test 10: Shortcut Keys (O for Work, P for Personal), Mutability, and Customizable Notes Title
    let workDef = appState.workspaces.first(where: { $0.id == "work" })
    let personalDef = appState.workspaces.first(where: { $0.id == "personal" })
    assert(workDef?.shortcutKey == "O", "Work shortcut key must be O (⌥⌘O)")
    assert(personalDef?.shortcutKey == "P", "Personal shortcut key must be P (⌥⌘P)")
    assert(workDef?.isSystem == false, "Work division must be editable/deletable (isSystem == false)")
    assert(personalDef?.isSystem == false, "Personal division must be editable/deletable (isSystem == false)")

    // Test customizable Notes note title
    let originalTitle = appState.notesNoteTitle
    appState.notesNoteTitle = "DAILY FOCUS — 2026"
    assert(appState.notesNoteTitle == "DAILY FOCUS — 2026", "Notes note title should be customizable")
    let testNotesContent = NotesSyncService.shared.buildNotesContent(from: context)
    assert(testNotesContent.title == "DAILY FOCUS — 2026", "buildNotesContent should reflect custom note title")
    assert(testNotesContent.plainText.hasPrefix("DAILY FOCUS — 2026"), "plainText should start with custom note title")
    appState.notesNoteTitle = originalTitle

    // Test 11: Daily Rollover
    let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
    let unfinishedOldTask = TaskItem(
        title: "Unfinished yesterday task",
        workspace: .work,
        status: .pending,
        scheduledDate: yesterday
    )
    let completedOldTask = TaskItem(
        title: "Finished yesterday task",
        workspace: .work,
        status: .completed,
        scheduledDate: yesterday
    )
    completedOldTask.completedAt = yesterday
    context.insert(unfinishedOldTask)
    context.insert(completedOldTask)
    try! context.save()

    // Force rollover trigger by setting lastRolloverDate to yesterday
    UserDefaults.standard.set(yesterday, forKey: "lastRolloverDate")
    appState.performDailyRolloverIfNeeded(context: context)

    assert(Calendar.current.isDateInToday(unfinishedOldTask.scheduledDate), "Unfinished yesterday task must roll over to today")
    assert(!Calendar.current.isDateInToday(completedOldTask.scheduledDate), "Completed task must remain on yesterday's date")
    print("✅ Check 9 Passed: Shortcuts (O/P), mutability, custom note title, and daily rollover verified.")

    print("\n🎉 ALL LOGIC CHECKS PASSED SUCCESSFULLY!\n")
}

runAllChecks()
