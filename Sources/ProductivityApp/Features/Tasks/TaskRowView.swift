import SwiftUI
import SwiftData
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
    @Environment(\.modelContext) private var modelContext

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
            // Reorder drag indicator on hover
            if isHovered {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
            }

            // Checkbox button on left: Directly toggles between Completed and Pending
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                    toggleCheckboxDirectly()
                }
            } label: {
                Image(systemName: task.status == .completed ? "checkmark.circle.fill" : (task.status == .inProgress ? "circle.dotted" : "circle"))
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(statusColor)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(task.status == .completed ? "Mark as pending" : "Mark as completed")

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

            // Badges (Focus minutes, Overdue, Tomorrow)
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

                if task.isOverdue {
                    Text("Overdue")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.red.opacity(0.12))
                        .clipShape(Capsule())
                } else if !task.isScheduledForToday && task.status != .completed {
                    Text("Tomorrow")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(Capsule())
                }
            }

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

                        Button {
                            task.moveToTomorrow()
                            try? modelContext.save()
                            NotesSyncService.shared.autoSync(context: modelContext)
                        } label: {
                            Image(systemName: "arrow.right.circle")
                                .font(.system(size: 15))
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 24)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Move to tomorrow")
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
        .contentShape(Rectangle())
        // Double-click on row/pill: Transition directly to Completed
        .onTapGesture(count: 2) {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                task.status = .completed
                try? modelContext.save()
                NotesSyncService.shared.autoSync(context: modelContext)
            }
        }
        // Single-click on row/pill: Advance Pending to In Progress (or toggle back to Pending)
        .onTapGesture(count: 1) {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                onSelect()
                if task.status == .pending {
                    task.status = .inProgress
                } else if task.status == .inProgress {
                    task.status = .pending
                } else if task.status == .completed {
                    task.status = .pending
                }
                try? modelContext.save()
                NotesSyncService.shared.autoSync(context: modelContext)
            }
        }
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

            Divider()

            Button("Move to Tomorrow") {
                task.moveToTomorrow()
                try? modelContext.save()
                NotesSyncService.shared.autoSync(context: modelContext)
            }

            Button("Edit Task...") {
                onEdit()
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

    /// When user clicks the checkbox icon on the left, it directly toggles Completed
    private func toggleCheckboxDirectly() {
        if task.status == .completed {
            task.status = .pending
        } else {
            task.status = .completed
        }
        try? modelContext.save()
        NotesSyncService.shared.autoSync(context: modelContext)
    }
}
