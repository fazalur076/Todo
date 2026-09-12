import SwiftUI
import SwiftData
import ProductivityCore

public struct TaskEditSheet: View {
    @Bindable var task: TaskItem
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var notes: String
    @State private var status: TaskStatus
    @State private var scheduledDate: Date

    public init(task: TaskItem) {
        self.task = task
        _title = State(initialValue: task.title)
        _notes = State(initialValue: task.notes ?? "")
        _status = State(initialValue: task.status)
        _scheduledDate = State(initialValue: task.scheduledDate)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(task.workspace == .work ? Color.blue : Color.green)
                            .frame(width: 8, height: 8)
                        Text(task.workspace.displayName.uppercased())
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(task.workspace == .work ? .blue : .green)
                    }

                    Text("Edit Task")
                        .font(.system(size: 18, weight: .bold))
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()

            // Form Area
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Task Title
                    VStack(alignment: .leading, spacing: 6) {
                        Text("TITLE")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)

                        TextField("Task title...", text: $title)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14, weight: .medium))
                            .padding(10)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                            )
                    }

                    // Status Pills
                    VStack(alignment: .leading, spacing: 8) {
                        Text("STATUS")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 10) {
                            statusPill(for: .pending, label: "Pending", icon: "circle", color: .secondary)
                            statusPill(for: .inProgress, label: "In Progress", icon: "circle.dotted", color: .blue)
                            statusPill(for: .completed, label: "Completed", icon: "checkmark.circle.fill", color: .green)
                        }
                    }

                    // Schedule Date & Quick Buttons
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SCHEDULE")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            DatePicker("", selection: $scheduledDate, displayedComponents: .date)
                                .labelsHidden()

                            Button {
                                scheduledDate = Calendar.current.startOfDay(for: Date())
                            } label: {
                                Text("Today")
                                    .font(.system(size: 11, weight: .medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(isToday ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05))
                                    .foregroundStyle(isToday ? Color.accentColor : .primary)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)

                            Button {
                                let cal = Calendar.current
                                if let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) {
                                    scheduledDate = tomorrow
                                }
                            } label: {
                                Text("Tomorrow")
                                    .font(.system(size: 11, weight: .medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(isTomorrow ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05))
                                    .foregroundStyle(isTomorrow ? Color.accentColor : .primary)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)

                            Spacer()
                        }
                    }

                    // Notes Field
                    VStack(alignment: .leading, spacing: 6) {
                        Text("NOTES")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)

                        TextEditor(text: $notes)
                            .font(.system(size: 13))
                            .frame(height: 90)
                            .padding(8)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                            )
                    }

                    // Focus stats if any
                    if task.focusMinutes > 0 {
                        HStack(spacing: 6) {
                            Image(systemName: "timer")
                                .foregroundStyle(.orange)
                            Text("Focus time logged: \(task.focusMinutes) minutes (\(task.pomodoroCount) sessions)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }

            Divider()

            // Footer Actions
            HStack(spacing: 12) {
                Button(role: .destructive) {
                    modelContext.delete(task)
                    try? modelContext.save()
                    NotesSyncService.shared.autoSync(context: modelContext)
                    dismiss()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                        Text("Delete")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save Changes") {
                    saveChanges()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(Color.primary.opacity(0.02))
        }
        .frame(width: 500, height: 480)
    }

    private var isToday: Bool {
        Calendar.current.isDateInToday(scheduledDate)
    }

    private var isTomorrow: Bool {
        Calendar.current.isDateInTomorrow(scheduledDate)
    }

    private func statusPill(for s: TaskStatus, label: String, icon: String, color: Color) -> some View {
        let isSelected = status == s
        return Button {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                status = s
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                Text(label)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? color : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(isSelected ? color.opacity(0.14) : Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? color.opacity(0.4) : Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func saveChanges() {
        task.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        task.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
        task.status = status
        task.scheduledDate = scheduledDate
        task.updatedAt = Date()
        try? modelContext.save()
        NotesSyncService.shared.autoSync(context: modelContext)
    }
}
