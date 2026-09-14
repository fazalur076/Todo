import SwiftUI
import SwiftData
import ProductivityCore

public struct TaskListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TaskItem.sortOrder) private var allTasks: [TaskItem]

    var appState = AppState.shared
    var focusService = FocusService.shared
    var onClose: (() -> Void)?

    @State private var selectedTaskId: UUID?
    @State private var draggingTaskId: UUID? = nil
    @State private var taskToEdit: TaskItem?
    @State private var newTaskTitle: String = ""
    @State private var filterStatus: TaskStatus? = nil
    @State private var isAddingInline: Bool = false
    @FocusState private var isInlineAddFocused: Bool

    @State private var showMoveUnfinishedConfirmation: Bool = false
    @State private var showFocusSheet: Bool = false
    @State private var showEODSheet: Bool = false
    @State private var showSettingsSheet: Bool = false

    @State private var isSyncingNotes: Bool = false
    @State private var notesToastMessage: String? = nil
    @State private var showAccessibilityInfoSheet: Bool = false

    public init(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
    }

    // Strictly isolated to current workspace only and sorted: idle/active tasks on top, completed tasks at the bottom
    private var workspaceTasks: [TaskItem] {
        allTasks
            .filter { $0.workspace == appState.currentWorkspace }
            .sorted { a, b in
                let aCompleted = (a.status == .completed)
                let bCompleted = (b.status == .completed)
                if aCompleted != bCompleted {
                    return !aCompleted
                }
                return a.sortOrder < b.sortOrder
            }
    }

    private var pendingTasks: [TaskItem] {
        workspaceTasks.filter { $0.status == .pending }
    }

    private var inProgressTasks: [TaskItem] {
        workspaceTasks.filter { $0.status == .inProgress }
    }

    private var completedTasks: [TaskItem] {
        workspaceTasks.filter { $0.status == .completed }
    }

    private var unfinishedTasks: [TaskItem] {
        workspaceTasks.filter { $0.status == .pending || $0.status == .inProgress }
    }

    private var displayedTasks: [TaskItem] {
        if let filter = filterStatus {
            return workspaceTasks.filter { $0.status == filter }
        }
        return workspaceTasks
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            headerView

            // Accessibility missing warning banner
            if !NotesSyncService.isAccessibilityGranted {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 11))
                    Text("Notes update option not allowed. Please grant Accessibility permission.")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    Button {
                        showAccessibilityInfoSheet = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showAccessibilityInfoSheet) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Why Accessibility?", systemImage: "hand.raised.circle")
                                .font(.headline)
                            Text("Productivity only uses accessibility shortcuts (⇧⌘L and ⇧⌘U) to format interactive checklist circles in Apple Notes.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("We do not access, monitor, log, or store your keystrokes, screen, or any other apps.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Open System Settings...") {
                                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                                NSWorkspace.shared.open(url)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .padding(.top, 4)
                        }
                        .padding()
                        .frame(width: 280)
                    }
                    Button("Settings") {
                        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                        NSWorkspace.shared.open(url)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(Color.orange.opacity(0.12))
            }

            // Toast feedback banner
            if let toast = notesToastMessage {
                HStack(spacing: 6) {
                    Image(systemName: toast.contains("error") ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(toast.contains("error") ? .red : .green)
                        .font(.system(size: 11))
                    Text(toast)
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.06))
                .transition(.opacity)
            }

            Divider()

            // Inline quick entry
            inlineAddView

            // Filter segmented control
            filterSegmentView

            // Tasks List
            tasksScrollArea

            Divider()

            // Bottom Status / Action Toolbar
            footerToolbar
        }
        .frame(width: 480, height: 580)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .task {
            // Silently pull any new or updated tasks from Apple Notes
            _ = try? await NotesSyncService.shared.pullFromNotes(context: modelContext)
        }
        .onAppear {
            appState.performDailyRolloverIfNeeded(context: modelContext)
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            appState.performDailyRolloverIfNeeded(context: modelContext)
        }
        .onChange(of: appState.panelOpenCount) {
            resetToFirstView()
            appState.performDailyRolloverIfNeeded(context: modelContext)
        }
        .onChange(of: appState.isMainPanelPresented) { _, isPresented in
            if !isPresented {
                resetToFirstView()
            }
        }
        .onChange(of: appState.isSettingsPresented) { _, isPresented in
            if isPresented {
                withAnimation(.easeInOut(duration: 0.16)) {
                    showSettingsSheet = true
                }
            }
        }
        .overlay {
            if showSettingsSheet {
                ZStack {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.16)) { showSettingsSheet = false }
                        }
                    SettingsView(onClose: {
                        withAnimation(.easeInOut(duration: 0.16)) { showSettingsSheet = false }
                    })
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else if showFocusSheet {
                ZStack {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.16)) { showFocusSheet = false }
                        }
                    FocusView(onClose: {
                        withAnimation(.easeInOut(duration: 0.16)) { showFocusSheet = false }
                    })
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else if showEODSheet {
                ZStack {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.16)) { showEODSheet = false }
                        }
                    EODView(onClose: {
                        withAnimation(.easeInOut(duration: 0.16)) { showEODSheet = false }
                    })
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else if let task = taskToEdit {
                ZStack {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.16)) { taskToEdit = nil }
                        }
                    TaskEditSheet(task: task, onClose: {
                        withAnimation(.easeInOut(duration: 0.16)) { taskToEdit = nil }
                    })
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .confirmationDialog(
            "Move all unfinished tasks to tomorrow?",
            isPresented: $showMoveUnfinishedConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move \(unfinishedTasks.count) tasks to Tomorrow") {
                moveUnfinishedToTomorrow()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will reschedule all \(unfinishedTasks.count) unfinished tasks to tomorrow.")
        }
    }

    // MARK: - Header
    private var headerView: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("Today")
                    .font(.system(size: 17, weight: .bold, design: .default))
                    .tracking(-0.35)
                    .foregroundStyle(.primary)

                Text(Date().formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .font(.system(size: 12, weight: .medium, design: .default))
                    .foregroundStyle(.secondary.opacity(0.8))
            }

            Spacer()

            HStack(spacing: 8) {
                // Focus session shortcut
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showFocusSheet = true
                    }
                } label: {
                    Image(systemName: "timer")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("Focus Timer (⌥⌘F)")

                // More Menu
                Menu {
                    Menu("Switch Division") {
                        ForEach(appState.workspaces) { ws in
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    appState.currentWorkspace = Workspace(rawValue: ws.id)
                                }
                            } label: {
                                HStack {
                                    Text(ws.name)
                                    if let key = ws.shortcutKey, !key.isEmpty {
                                        Text("(⌥⌘\(key))")
                                    }
                                    if appState.currentWorkspace.rawValue == ws.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Sync with Notes Now") {
                        triggerNotesSync()
                    }
                    Button("Generate EOD Report...") {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            showEODSheet = true
                        }
                    }
                    Divider()
                    Button("Move Unfinished to Tomorrow...") {
                        showMoveUnfinishedConfirmation = true
                    }
                    .disabled(unfinishedTasks.isEmpty)
                    Divider()
                    Button("Settings...") {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            showSettingsSheet = true
                        }
                    }
                    if let onClose = onClose {
                        Divider()
                        Button("Close Window") {
                            onClose()
                        }
                    }
                    Button("Quit") {
                        NSApp.terminate(nil)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Circle())
                        .contentShape(Circle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .focusEffectDisabled()
                .frame(width: 30, height: 30)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Inline Add
    private var inlineAddView: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)

            TextField("Add a task...", text: $newTaskTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isInlineAddFocused)
                .onSubmit {
                    submitInlineTask()
                }

            if !newTaskTitle.isEmpty {
                Button {
                    submitInlineTask()
                } label: {
                    Text("Add")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.03))
    }

    // MARK: - Filter Segment
    private var filterSegmentView: some View {
        HStack(spacing: 6) {
            filterButton(title: "All", count: workspaceTasks.count, status: nil)
            filterButton(title: "Pending", count: pendingTasks.count, status: .pending)
            filterButton(title: "In Progress", count: inProgressTasks.count, status: .inProgress)
            filterButton(title: "Completed", count: completedTasks.count, status: .completed)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.015))
    }

    private func filterButton(title: String, count: Int, status: TaskStatus?) -> some View {
        let isSelected = filterStatus == status
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                filterStatus = status
            }
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                Text("\(count)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(isSelected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06))
                    .clipShape(Capsule())
            }
            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    // MARK: - Tasks Scroll / List Area with Drag-and-Drop Reordering
    private var tasksScrollArea: some View {
        Group {
            if displayedTasks.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No \(filterStatus?.displayName.lowercased() ?? "") tasks")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Press ⌘N or ⌥ Space to add a task")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 48)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(displayedTasks) { task in
                            TaskRowView(
                                task: task,
                                isSelected: selectedTaskId == task.id,
                                onSelect: { selectedTaskId = task.id },
                                onEdit: { taskToEdit = task },
                                onStartFocus: {
                                    focusService.startFocus(for: task)
                                    showFocusSheet = true
                                },
                                onDelete: {
                                    modelContext.delete(task)
                                    try? modelContext.save()
                                    NotesSyncService.shared.autoSync(context: modelContext)
                                },
                                onMoveUp: { moveTaskUp(task) },
                                onMoveDown: { moveTaskDown(task) }
                            )
                            .opacity(draggingTaskId == task.id ? 0.35 : 1.0)
                            .onDrag {
                                self.draggingTaskId = task.id
                                return NSItemProvider(object: task.id.uuidString as NSString)
                            }
                            .onDrop(of: [.text], delegate: TaskDropDelegate(
                                destinationTask: task,
                                displayedTasks: displayedTasks,
                                draggingTaskId: $draggingTaskId,
                                onMove: { src, dst in
                                    reorderTask(source: src, destination: dst)
                                }
                            ))
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.automatic)
            }
        }
    }

    // MARK: - Task Re-ordering Logic
    private func reorderTask(source: TaskItem, destination: TaskItem) {
        guard let fromIndex = displayedTasks.firstIndex(where: { $0.id == source.id }),
              let toIndex = displayedTasks.firstIndex(where: { $0.id == destination.id }),
              fromIndex != toIndex else { return }

        var mutable = displayedTasks
        let moved = mutable.remove(at: fromIndex)
        mutable.insert(moved, at: toIndex)

        for (index, task) in mutable.enumerated() {
            task.sortOrder = index
        }
        try? modelContext.save()
        NotesSyncService.shared.autoSync(context: modelContext)
    }

    private func moveTaskUp(_ task: TaskItem) {
        guard let idx = displayedTasks.firstIndex(where: { $0.id == task.id }), idx > 0 else { return }
        let other = displayedTasks[idx - 1]
        let temp = task.sortOrder
        task.sortOrder = other.sortOrder
        other.sortOrder = temp
        try? modelContext.save()
        NotesSyncService.shared.autoSync(context: modelContext)
    }

    private func moveTaskDown(_ task: TaskItem) {
        guard let idx = displayedTasks.firstIndex(where: { $0.id == task.id }), idx < displayedTasks.count - 1 else { return }
        let other = displayedTasks[idx + 1]
        let temp = task.sortOrder
        task.sortOrder = other.sortOrder
        other.sortOrder = temp
        try? modelContext.save()
        NotesSyncService.shared.autoSync(context: modelContext)
    }

    // MARK: - Footer
    private var footerToolbar: some View {
        HStack(spacing: 10) {
            // Pomodoro status indicator
            Button {
                showFocusSheet = true
            } label: {
                HStack(spacing: 6) {
                    if focusService.isRunning || focusService.state != .idle {
                        Text(focusService.menuBarDisplayString)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.orange)
                    } else {
                        Image(systemName: "timer")
                            .font(.system(size: 12))
                        Text("Focus")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.12))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("Open Focus / Pomodoro timer")

            Spacer()

            // Apple Notes Sync & Reveal button
            Button {
                triggerNotesSync()
            } label: {
                HStack(spacing: 4) {
                    if isSyncingNotes {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "note.text")
                            .font(.system(size: 11))
                    }
                    Text("Notes")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(isSyncingNotes ? Color.accentColor : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(isSyncingNotes)
            .help("Two-way sync with Apple Notes")

            // EOD generator
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    showEODSheet = true
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 11))
                    Text("EOD")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("Generate End-of-Day summary")

            // Quick Move to Tomorrow button
            if !unfinishedTasks.isEmpty {
                Button {
                    showMoveUnfinishedConfirmation = true
                } label: {
                    Image(systemName: "arrow.right.to.line")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("Move unfinished tasks to tomorrow")
            }

            // Settings button
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    showSettingsSheet = true
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)
            .focusEffectDisabled()
            .help("Preferences (⌘,)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.02))
    }

    private func triggerNotesSync() {
        isSyncingNotes = true
        Task {
            do {
                let result = try await NotesSyncService.shared.syncTwoWay(context: modelContext, openNotes: false)
                withAnimation {
                    if result.added > 0 || result.updated > 0 {
                        notesToastMessage = "Synced with Notes! (+\(result.added) new, \(result.updated) updated) 📝"
                    } else {
                        notesToastMessage = "Synced with Apple Notes! 📝"
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                    withAnimation { notesToastMessage = nil }
                }
            } catch {
                withAnimation {
                    notesToastMessage = "Notes error: \(error.localizedDescription)"
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    withAnimation { notesToastMessage = nil }
                }
            }
            isSyncingNotes = false
        }
    }

    private func submitInlineTask() {
        let trimmed = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let nextOrder = (displayedTasks.map(\.sortOrder).max() ?? 0) + 1
        let task = TaskItem(
            title: trimmed,
            workspace: appState.currentWorkspace,
            status: .pending,
            scheduledDate: Calendar.current.startOfDay(for: Date()),
            sortOrder: nextOrder
        )
        modelContext.insert(task)
        try? modelContext.save()
        NotesSyncService.shared.autoSync(context: modelContext)
        newTaskTitle = ""
    }

    private func moveUnfinishedToTomorrow() {
        for task in unfinishedTasks {
            task.moveToTomorrow()
        }
        try? modelContext.save()
        NotesSyncService.shared.autoSync(context: modelContext)
    }

    private func resetToFirstView() {
        showSettingsSheet = false
        showFocusSheet = false
        showEODSheet = false
        showMoveUnfinishedConfirmation = false
        showAccessibilityInfoSheet = false
        taskToEdit = nil
        selectedTaskId = nil
        appState.isSettingsPresented = false
    }
}

// MARK: - Task Drop Delegate for Real-Time Drag-and-Drop Reordering
struct TaskDropDelegate: DropDelegate {
    let destinationTask: TaskItem
    let displayedTasks: [TaskItem]
    @Binding var draggingTaskId: UUID?
    let onMove: (TaskItem, TaskItem) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggingId = draggingTaskId,
              draggingId != destinationTask.id,
              let sourceTask = displayedTasks.first(where: { $0.id == draggingId }) else { return }

        withAnimation(.easeInOut(duration: 0.18)) {
            onMove(sourceTask, destinationTask)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingTaskId = nil
        return true
    }
}
