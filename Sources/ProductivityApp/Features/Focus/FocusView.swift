import SwiftUI
import SwiftData
import ProductivityCore

public struct FocusView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var tasks: [TaskItem]

    var focusService = FocusService.shared
    var appState = AppState.shared
    var onClose: () -> Void

    public init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    private var currentWorkspaceTasks: [TaskItem] {
        tasks.filter { $0.workspace == appState.currentWorkspace && $0.status != .completed }
    }

    public var body: some View {
        VStack(spacing: 20) {
            // Top Bar
            HStack {
                Label("Focus & Pomodoro", systemImage: "brain.head.profile")
                    .font(.headline)
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Mode Selector
            Picker("Mode", selection: Binding(
                get: { focusService.currentMode },
                set: { newMode in
                    if !focusService.isRunning {
                        focusService.startFocus(mode: newMode)
                        focusService.pause()
                    }
                }
            )) {
                ForEach(FocusMode.allCases, id: \.self) { mode in
                    Label(mode.rawValue, systemImage: mode.iconName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            // Attached Task
            if let taskTitle = focusService.activeTaskTitle {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.orange)
                    Text(taskTitle)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.orange.opacity(0.1))
                .clipShape(Capsule())
            } else {
                Menu {
                    Button("No specific task") {
                        focusService.activeTaskId = nil
                        focusService.activeTaskTitle = "General Focus"
                    }
                    Divider()
                    ForEach(currentWorkspaceTasks) { task in
                        Button(task.title) {
                            focusService.activeTaskId = task.id
                            focusService.activeTaskTitle = task.title
                            focusService.activeWorkspace = task.workspace
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "link")
                            .font(.caption)
                        Text(focusService.activeTaskTitle ?? "Attach to a task...")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
            }

            // Circular Timer
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 8)
                    .frame(width: 170, height: 170)

                Circle()
                    .trim(from: 0.0, to: CGFloat(focusService.progress))
                    .stroke(
                        Color.orange,
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 170, height: 170)
                    .animation(.linear(duration: 0.5), value: focusService.progress)

                VStack(spacing: 4) {
                    Text(focusService.formattedTimeRemaining)
                        .font(.system(size: 38, weight: .bold, design: .monospaced))
                    Text(focusService.currentMode.rawValue)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8)

            // Timer Controls
            HStack(spacing: 16) {
                if !focusService.isRunning && focusService.state == .idle {
                    Button {
                        focusService.startFocus(mode: focusService.currentMode)
                    } label: {
                        Label("Start Focus", systemImage: "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.orange)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                } else if focusService.isRunning {
                    Button {
                        focusService.pause()
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.secondary.opacity(0.2))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)

                    Button {
                        focusService.finishEarly(context: modelContext)
                    } label: {
                        Label("Finish Early", systemImage: "checkmark")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.green.opacity(0.2))
                            .foregroundStyle(.green)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)

                    Button {
                        focusService.stop()
                    } label: {
                        Image(systemName: "stop.fill")
                            .padding(8)
                            .background(Color.red.opacity(0.15))
                            .foregroundStyle(.red)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        focusService.resume()
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.orange)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)

                    Button {
                        focusService.stop()
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                            .font(.system(size: 13))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            // Today's Focus Stats
            HStack(spacing: 24) {
                VStack(spacing: 2) {
                    Text("Today's Focus")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(focusService.todayFocusMinutes) min")
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                }

                VStack(spacing: 2) {
                    Text("Sessions Done")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(focusService.completedSessionsToday)")
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                }
            }
        }
        .padding(20)
        .frame(width: 360)
        .background(.ultraThinMaterial)
    }
}
