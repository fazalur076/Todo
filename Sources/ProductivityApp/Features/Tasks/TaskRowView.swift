import SwiftUI
import SwiftData
import AppKit
import ProductivityCore

public struct TaskRowView: View {
    @Bindable var task: TaskItem
    var isSelected: Bool
    var onSelect: () -> Void
    var onEdit: () -> Void
    var onStartFocus: () -> Void
    var onDelete: () -> Void
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?

    @State private var isHovered: Bool = false
    @State private var didCopy: Bool = false
    @Environment(\.modelContext) private var modelContext
    private var appState = AppState.shared

    public init(
        task: TaskItem,
        isSelected: Bool,
        onSelect: @escaping () -> Void,
        onEdit: @escaping () -> Void,
        onStartFocus: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onMoveUp: (() -> Void)? = nil,
        onMoveDown: (() -> Void)? = nil
    ) {
        self.task = task
        self.isSelected = isSelected
        self.onSelect = onSelect
        self.onEdit = onEdit
        self.onStartFocus = onStartFocus
        self.onDelete = onDelete
        self.onMoveUp = onMoveUp
        self.onMoveDown = onMoveDown
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Reorder drag indicator: always visible for stable layout and clear affordance
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .opacity(isHovered ? 0.9 : 0.4)
                .frame(width: 12)

            // Primary clickable area (checkbox + title + notes + spacer + badges)
            // Single-click on this area instantly cycles status:
            // 1 click: Pending (unchecked) -> In Progress (blue dotted)
            // 2 clicks: In Progress -> Completed (green checkmark)
            // Next click: Completed -> Pending (unchecked mark)
            HStack(alignment: .center, spacing: 10) {
                // Checkbox icon on left
                Image(systemName: task.status == .completed ? "checkmark.circle.fill" : (task.status == .inProgress ? "circle.dotted" : "circle"))
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(statusColor)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())

                // Title and notes excerpt
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title)
                        .font(.system(size: 13, weight: .regular))
                        .strikethrough(task.status == .completed, color: .secondary)
                        .foregroundStyle(task.status == .completed ? .secondary : .primary)
                        .lineLimit(2)

                    if let notes = task.notes, !notes.isEmpty {
                        Text(notes)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Badges (Focus minutes)
                HStack(spacing: 6) {
                    if task.focusMinutes > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "timer")
                                .font(.system(size: 10))
                            Text("\(task.focusMinutes)m")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                        }
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(Capsule())
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onSelect()
                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                    task.cycleStatus()
                    try? modelContext.save()
                    NotesSyncService.shared.autoSync(context: modelContext)
                }
            }

            Button {
                copyTaskTitle()
            } label: {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(didCopy ? .green : .secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(isHovered || didCopy ? 1 : 0.45)
            .help(didCopy ? "Copied task title" : "Copy task title")

            // Quick actions on hover
            if isHovered {
                HStack(spacing: 6) {
                    if let onMoveUp {
                        Button {
                            onMoveUp()
                        } label: {
                            Image(systemName: "chevron.up")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Move task up")
                    }

                    if let onMoveDown {
                        Button {
                            onMoveDown()
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Move task down")
                    }

                    if task.status != .completed {
                        Button {
                            onStartFocus()
                        } label: {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(.orange)
                                .frame(width: 24, height: 24)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Start focus session")
                    }

                    Button {
                        onEdit()
                    } label: {
                        Image(systemName: "pencil.circle")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Edit task")
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : (isHovered ? Color.primary.opacity(0.04) : Color.clear))
        )
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            if let onMoveUp {
                Button("Move Up") {
                    onMoveUp()
                }
            }

            if let onMoveDown {
                Button("Move Down") {
                    onMoveDown()
                }
            }

            Divider()

            Button("Start Focus Session") {
                onStartFocus()
            }

            Divider()

            if task.status != .pending {
                Button("Mark as Pending") {
                    task.status = .pending
                    try? modelContext.save()
                    NotesSyncService.shared.autoSync(context: modelContext)
                }
            }

            if task.status != .inProgress {
                Button("Mark as In Progress") {
                    task.status = .inProgress
                    try? modelContext.save()
                    NotesSyncService.shared.autoSync(context: modelContext)
                }
            }

            if task.status != .completed {
                Button("Mark as Completed") {
                    task.status = .completed
                    try? modelContext.save()
                    NotesSyncService.shared.autoSync(context: modelContext)
                }
            }



            Button("Edit Task...") {
                onEdit()
            }

            Menu("Move to Division") {
                ForEach(appState.workspaces) { ws in
                    if ws.id != task.workspace.rawValue {
                        Button {
                            withAnimation {
                                NotesSyncService.shared.moveTask(task, to: Workspace(rawValue: ws.id), context: modelContext)
                            }
                        } label: {
                            HStack {
                                Text(ws.name)
                                if let key = ws.shortcutKey, !key.isEmpty {
                                    Text("(⌥⌘\(key))")
                                }
                            }
                        }
                    }
                }
            }

            Divider()

            Button(role: .destructive) {
                onDelete()
            } label: {
                Text("Delete Task")
            }
        }
    }

    private var statusColor: Color {
        switch task.status {
        case .pending:
            return .secondary
        case .inProgress:
            return .blue
        case .completed:
            return .green
        }
    }

    /// When user clicks the checkbox icon on the left, it cycles status
    private func toggleCheckboxDirectly() {
        task.cycleStatus()
        try? modelContext.save()
        NotesSyncService.shared.autoSync(context: modelContext)
    }

    private func copyTaskTitle() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(TaskClipboardContent.title(for: task), forType: .string)
        withAnimation(.easeInOut(duration: 0.15)) {
            didCopy = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeInOut(duration: 0.15)) {
                didCopy = false
            }
        }
    }
}
