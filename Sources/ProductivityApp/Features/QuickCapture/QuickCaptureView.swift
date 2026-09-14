import SwiftUI
import SwiftData
import ProductivityCore

public struct QuickCaptureView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var taskTitle: String = ""
    @State private var taskNotes: String = ""
    @State private var isNotesExpanded: Bool = false
    @FocusState private var isInputFocused: Bool

    var appState = AppState.shared
    var onDismiss: () -> Void

    public init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header: Action hint
            HStack {
                Text("QUICK CAPTURE")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .tracking(1.2)

                Spacer()

                Button {
                    isNotesExpanded.toggle()
                } label: {
                    Label(isNotesExpanded ? "Hide notes" : "Add notes", systemImage: "note.text")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 8)

            // Primary input
            HStack(spacing: 12) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                TextField("What needs doing?", text: $taskTitle)
                    .font(.system(size: 18, weight: .medium, design: .default))
                    .textFieldStyle(.plain)
                    .focused($isInputFocused)
                    .onSubmit {
                        submitTask()
                    }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)

            // Optional expanded notes field
            if isNotesExpanded {
                TextField("Add details or notes (optional)...", text: $taskNotes, axis: .vertical)
                    .lineLimit(2...4)
                    .font(.system(size: 13))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider()
                .opacity(0.5)

            // Footer with metadata and keyboard hints
            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                        .font(.system(size: 11))
                    Text("Today")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.secondary)

                Menu {
                    ForEach(appState.workspaces) { ws in
                        Button {
                            appState.currentWorkspace = Workspace(rawValue: ws.id)
                        } label: {
                            HStack {
                                Text(ws.name)
                                if appState.currentWorkspace.rawValue == ws.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(appState.currentWorkspace.accentColor)
                            .frame(width: 6, height: 6)
                        Text(appState.currentWorkspace.displayName)
                            .font(.system(size: 12, weight: .medium))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(Capsule())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .focusEffectDisabled()

                Spacer()

                HStack(spacing: 12) {
                    Text("esc to cancel")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Button {
                        submitTask()
                    } label: {
                        HStack(spacing: 4) {
                            Text("Add")
                                .font(.system(size: 12, weight: .semibold))
                            Text("↵")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            taskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? Color.gray.opacity(0.4)
                            : Color.accentColor
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .disabled(taskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color.primary.opacity(0.02))
        }
        .frame(width: 480)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 24, x: 0, y: 12)
        .onAppear {
            isInputFocused = true
        }
    }

    private func submitTask() {
        let trimmed = taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let trimmedNotes = taskNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTask = TaskItem(
            title: trimmed,
            notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
            workspace: appState.currentWorkspace,
            status: .pending,
            scheduledDate: Calendar.current.startOfDay(for: Date())
        )

        modelContext.insert(newTask)
        try? modelContext.save()
        NotesSyncService.shared.autoSync(context: modelContext)

        taskTitle = ""
        taskNotes = ""
        onDismiss()
    }
}
