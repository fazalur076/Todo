import SwiftUI
import SwiftData
import ServiceManagement
import ProductivityCore

public struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    var appState = AppState.shared
    var focusService = FocusService.shared
    var notesSyncService = NotesSyncService.shared

    @State private var syncStatusMessage: String?
    @State private var isSyncingNotes: Bool = false
    @State private var showAccessibilityInfoPopover: Bool = false
    var onClose: () -> Void

    public init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Label("Preferences", systemImage: "gearshape")
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
            .padding(16)

            Divider()

            TabView {
                generalSettingsTab
                    .tabItem {
                        Label("General", systemImage: "switch.2")
                    }

                focusSettingsTab
                    .tabItem {
                        Label("Focus", systemImage: "timer")
                    }

                notesSettingsTab
                    .tabItem {
                        Label("Notes", systemImage: "note.text")
                    }

                appearanceSettingsTab
                    .tabItem {
                        Label("Appearance", systemImage: "paintpalette")
                    }
            }
            .padding(12)
        }
        .frame(width: 440, height: 380)
        .background(.ultraThinMaterial)
    }

    // MARK: - General
    private var generalSettingsTab: some View {
        Form {
            Section {
                Toggle("Launch at Login", isOn: Binding(
                    get: { appState.launchAtLogin },
                    set: { appState.launchAtLogin = $0 }
                ))

                Toggle("Always launch in Work mode", isOn: Binding(
                    get: { appState.alwaysLaunchInWork },
                    set: { appState.alwaysLaunchInWork = $0 }
                ))
            } header: {
                Text("Startup & Behavior")
            }

            Section {
                HStack {
                    Text("Toggle Main Panel")
                    Spacer()
                    Text("⌥⌘T")
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                HStack {
                    Text("Quick Capture")
                    Spacer()
                    Text("⌥ Space")
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                HStack {
                    Text("Switch to Work")
                    Spacer()
                    Text("⌥⌘W")
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                HStack {
                    Text("Switch to Personal")
                    Spacer()
                    Text("⌥⌘P")
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            } header: {
                Text("Global Keyboard Shortcuts")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Focus
    private var focusSettingsTab: some View {
        Form {
            Section("Pomodoro Durations") {
                Stepper("Focus Duration: \(focusService.focusDurationMinutes) min", value: Binding(
                    get: { focusService.focusDurationMinutes },
                    set: { focusService.focusDurationMinutes = $0 }
                ), in: 5...90, step: 5)

                Stepper("Short Break: \(focusService.shortBreakMinutes) min", value: Binding(
                    get: { focusService.shortBreakMinutes },
                    set: { focusService.shortBreakMinutes = $0 }
                ), in: 1...30, step: 1)

                Stepper("Long Break: \(focusService.longBreakMinutes) min", value: Binding(
                    get: { focusService.longBreakMinutes },
                    set: { focusService.longBreakMinutes = $0 }
                ), in: 5...60, step: 5)
            }

            Section("Notifications") {
                Button("Request Notification Permission") {
                    NotificationService.shared.requestAuthorization()
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Notes
    private var notesSettingsTab: some View {
        Form {
            Section("Apple Notes Mirror") {
                Toggle("Sync task overview to Apple Notes", isOn: Binding(
                    get: { appState.syncNotesEnabled },
                    set: { appState.syncNotesEnabled = $0 }
                ))

                HStack {
                    Text("Target Note Name")
                    Spacer()
                    Text("Tasks — Today")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    triggerNotesSync()
                } label: {
                    HStack {
                        if isSyncingNotes {
                            ProgressView()
                                .controlSize(.small)
                            Text("Syncing...")
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Sync Now")
                        }
                    }
                }
                .disabled(isSyncingNotes)

                if let message = syncStatusMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(message.contains("Error") ? .red : .green)
                }
            }

            Section("Apple Notes Checklist Automation") {
                if !NotesSyncService.isAccessibilityGranted {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.system(size: 14))

                            VStack(alignment: .leading, spacing: 3) {
                                Text("Notes update option not allowed. Please grant Accessibility permission.")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.primary)
                            }

                            Spacer()

                            Button {
                                showAccessibilityInfoPopover = true
                            } label: {
                                Image(systemName: "info.circle")
                                    .foregroundStyle(.blue)
                                    .font(.system(size: 14))
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: $showAccessibilityInfoPopover) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label("Why Accessibility?", systemImage: "hand.raised.circle")
                                        .font(.headline)
                                    Text("Productivity only uses macOS accessibility shortcuts (⇧⌘L and ⇧⌘U) to format interactive checklist circles in Apple Notes.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("We do not access, monitor, log, or store your keystrokes, screen, or any other applications.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding()
                                .frame(width: 280)
                            }
                        }

                        Button("Open System Settings...") {
                            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                            NSWorkspace.shared.open(url)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    HStack {
                        Text("Accessibility Permission")
                        Spacer()
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                    Text("Granted for Productivity to automate native Apple Notes checklist circles (◯). Tasks appear with interactive checkboxes.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Appearance
    private var appearanceSettingsTab: some View {
        Form {
            Section("Color Scheme") {
                Picker("Appearance", selection: Binding(
                    get: { appState.appearanceMode },
                    set: { appState.appearanceMode = $0 }
                )) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.inline)
            }
        }
        .formStyle(.grouped)
    }

    private func triggerNotesSync() {
        isSyncingNotes = true
        syncStatusMessage = nil
        Task {
            do {
                try await notesSyncService.syncToNotes(from: modelContext)
                syncStatusMessage = "Successfully mirrored to Apple Notes! (\(Date().formatted(date: .omitted, time: .shortened)))"
            } catch {
                syncStatusMessage = "Sync error: \(error.localizedDescription)"
            }
            isSyncingNotes = false
        }
    }
}
