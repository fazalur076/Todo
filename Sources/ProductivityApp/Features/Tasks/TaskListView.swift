import SwiftUI
import SwiftData
import ProductivityCore

public struct TaskListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var allTasks: [TaskItem]

    var appState = AppState.shared
    var focusService = FocusService.shared
    var onClose: (() -> Void)?

    @State private var selectedTaskId: UUID?
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

    public init(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
    }

    // Strictly isolated to current workspace only
    private var workspaceTasks: [TaskItem] {
        allTasks.filter { $0.workspace == appState.currentWorkspace }
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
        .sheet(item: $taskToEdit) { task in
            TaskEditSheet(task: task)
        }
        .sheet(isPresented: $showFocusSheet) {
            FocusView(onClose: { showFocusSheet = false })
        }
        .sheet(isPresented: $showEODSheet) {
            EODView(onClose: { showEODSheet = false })
        }
        .sheet(isPresented: $showSettingsSheet) {
            SettingsView(onClose: { showSettingsSheet = false })
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
            Text("This will reschedule all \(unfinishedTasks.count) pending and in-progress \(appState.currentWorkspace.displayName) tasks to tomorrow.")
        }
    }

    // MARK: - Header
    private var headerView: some View {
        HStack(alignment: .center) {
            HStack(spacing: 8) {
                Image(systemName: appState.currentWorkspace.iconName)
                    .font(.system(size: 13, weight: .bold))
                Text(appState.currentWorkspace.displayName.uppercased())
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .tracking(1.5)
            }
            .foregroundStyle(appState.currentWorkspace.accentColor)

            Spacer()

            // Workspace toggle switcher
            Picker("", selection: Binding(
                get: { appState.currentWorkspace },
                set: { newWorkspace in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        appState.currentWorkspace = newWorkspace
                    }
                }
            )) {
                ForEach(Workspace.allCases, id: \.self) { ws in
                    Text(ws.displayName).tag(ws)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 140)

            HStack(spacing: 6) {
                // Focus session shortcut
                Button {
                    showFocusSheet = true
                } label: {
                    Image(systemName: "timer")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(5)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("Focus Timer (⌥⌘F)")

                // More Menu
                Menu {
                    Button("Work Workspace (⌥⌘W)") {
                        appState.currentWorkspace = .work
                    }
                    Button("Personal Workspace (⌥⌘P)") {
                        appState.currentWorkspace = .personal
                    }
                    Divider()
                    Button("Sync with Notes Now") {
                        triggerNotesSync()
                    }
                    if appState.currentWorkspace == .work {
                        Button("Generate EOD Report...") {
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
                        showSettingsSheet = true
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
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(5)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Circle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .focusEffectDisabled()
                .frame(width: 26, height: 26)
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
                .foregroundStyle(appState.currentWorkspace.accentColor)

            TextField("Add a task to \(appState.currentWorkspace.displayName)...", text: $newTaskTitle)
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
                        .background(appState.currentWorkspace.accentColor)
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
        HStack(spacing: 8) {
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
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                Text("\(count)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(isSelected ? appState.currentWorkspace.accentColor.opacity(0.2) : Color.primary.opacity(0.06))
                    .clipShape(Capsule())
            }
            .foregroundStyle(isSelected ? appState.currentWorkspace.accentColor : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? appState.currentWorkspace.accentColor.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
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
                    Text("No \(filterStatus?.displayName.lowercased() ?? "") tasks in \(appState.currentWorkspace.displayName)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Press ⌘N or ⌥ Space to add a task")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 48)
            } else {
                List {
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
                        .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                    .onMove(perform: reorderTasks)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    // MARK: - Task Re-ordering Logic
    private func reorderTasks(from source: IndexSet, to destination: Int) {
        var mutableTasks = displayedTasks
        mutableTasks.move(fromOffsets: source, toOffset: destination)
        for (index, task) in mutableTasks.enumerated() {
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
                .foregroundStyle(isSyncingNotes ? appState.currentWorkspace.accentColor : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(isSyncingNotes)
            .help("Two-way sync with Apple Notes")

            // EOD generator (Work workspace only)
            if appState.currentWorkspace == .work {
                Button {
                    showEODSheet = true
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
            }

            // Quick Move to Tomorrow button
            if !unfinishedTasks.isEmpty {
                Button {
                    showMoveUnfinishedConfirmation = true
                } label: {
                    Image(systemName: "arrow.right.to.line")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(5)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("Move unfinished tasks to tomorrow")
            }

            // Settings button
            Button {
                showSettingsSheet = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(5)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("Preferences")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.02))
    }

    private func triggerNotesSync() {
        isSyncingNotes = true
        Task {
            do {
                let result = try await NotesSyncService.shared.syncTwoWay(context: modelContext, openNotes: true)
                withAnimation {
                    if !NotesSyncService.isAccessibilityGranted {
                        notesToastMessage = "Synced! (Tip: Enable Accessibility in System Settings for native checklist circles ◯)"
                    } else if result.added > 0 || result.updated > 0 {
                        notesToastMessage = "Synced with Notes! (+\(result.added) new, \(result.updated) updated) 📝"
                    } else {
                        notesToastMessage = "Synced with Apple Notes! (Native Checklists ◯)"
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
}
