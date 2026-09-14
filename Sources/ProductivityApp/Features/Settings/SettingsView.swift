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

    @State private var showingAddDivisionSheet: Bool = false
    @State private var newDivisionName: String = ""
    @State private var newDivisionKey: String = ""
    @State private var newDivisionColor: String = "#10B981"
    @State private var newDivisionIncludeInEOD: Bool = true
    @State private var newDivisionError: String?

    @State private var editingDivision: WorkspaceDefinition? = nil
    @State private var editDivisionName: String = ""
    @State private var editDivisionKey: String = ""
    @State private var editDivisionColor: String = "#3B82F6"
    @State private var editDivisionIncludeInEOD: Bool = true
    @State private var editDivisionError: String?

    private let presetColors = [
        "#0D9488", "#2563EB", "#7C3AED", "#DB2777",
        "#EA580C", "#16A34A", "#0891B2", "#4F46E5",
        "#64748B", "#D97706"
    ]

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

                divisionsSettingsTab
                    .tabItem {
                        Label("Divisions", systemImage: "square.grid.2x2")
                    }

                focusSettingsTab
                    .tabItem {
                        Label("Focus", systemImage: "timer")
                    }

                notesSettingsTab
                    .tabItem {
                        Label("Notes", systemImage: "note.text")
                    }
            }
            .padding(16)
        }
        .frame(width: 440, height: 490)
        .background(.ultraThinMaterial)
    }

    // MARK: - General
    private var generalSettingsTab: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: Binding(
                    get: { appState.appearanceMode },
                    set: { appState.appearanceMode = $0 }
                )) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
            }

            Section("Startup & Behavior") {
                Toggle("Launch at Login", isOn: Binding(
                    get: { appState.launchAtLogin },
                    set: { appState.launchAtLogin = $0 }
                ))

                Toggle("Always launch in first division", isOn: Binding(
                    get: { appState.alwaysLaunchInWork },
                    set: { appState.alwaysLaunchInWork = $0 }
                ))
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

                ForEach(appState.workspaces) { ws in
                    if let key = ws.shortcutKey {
                        HStack {
                            Text("Switch to \(ws.name)")
                            Spacer()
                            Text("⌥⌘\(key)")
                                .font(.system(size: 11, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
            } header: {
                Text("Global Keyboard Shortcuts")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Divisions
    private var divisionsSettingsTab: some View {
        ZStack {
            VStack(spacing: 0) {
                List {
                    Section {
                        ForEach(appState.workspaces) { ws in
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(Color(hex: ws.colorHex) ?? Color.blue)
                                    .frame(width: 10, height: 10)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ws.name)
                                        .font(.system(size: 13, weight: .medium))
                                    Text(ws.includeInEOD ? "Included in EOD Report" : "Excluded from EOD Report")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if let key = ws.shortcutKey {
                                    Text("⌥⌘\(key)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Color.primary.opacity(0.06))
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                }

                                Toggle("", isOn: Binding(
                                    get: { ws.includeInEOD },
                                    set: { newValue in
                                        var updated = ws
                                        updated.includeInEOD = newValue
                                        appState.updateWorkspace(updated)
                                    }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.mini)

                                // Edit button
                                Button {
                                    editingDivision = ws
                                    editDivisionName = ws.name
                                    editDivisionKey = ws.shortcutKey ?? ""
                                    editDivisionColor = ws.colorHex
                                    editDivisionIncludeInEOD = ws.includeInEOD
                                    editDivisionError = nil
                                } label: {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Edit Division")

                                // Delete button (allowed on any division as long as at least 1 remains)
                                if appState.workspaces.count > 1 {
                                    Button {
                                        appState.deleteWorkspace(id: ws.id)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.red.opacity(0.8))
                                    }
                                    .buttonStyle(.plain)
                                    .help("Delete Division")
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    } header: {
                        HStack {
                            Text("Active Divisions")
                            Spacer()
                            Text("EOD Report")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("Divisions organize your tasks (e.g. Work, Personal, Freelance, or client projects). Customize names, colors, and shortcuts as needed.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))

                Divider()

                HStack {
                    Spacer()
                    Button {
                        newDivisionName = ""
                        newDivisionKey = ""
                        newDivisionColor = presetColors.randomElement() ?? "#10B981"
                        newDivisionIncludeInEOD = true
                        newDivisionError = nil
                        withAnimation(.easeInOut(duration: 0.16)) {
                            showingAddDivisionSheet = true
                        }
                    } label: {
                        Label("Add Division", systemImage: "plus")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(10)
                }
            }

            if showingAddDivisionSheet {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            showingAddDivisionSheet = false
                        }
                    }

                VStack(alignment: .leading, spacing: 14) {
                    Text("New Division")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Division Name")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("e.g. Freelance, Acme Corp, Client X", text: $newDivisionName)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Keyboard Shortcut Key (⌥⌘ + Key)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Single Letter (e.g. F, C, X)", text: Binding(
                            get: { newDivisionKey },
                            set: { newDivisionKey = String($0.prefix(1)).uppercased() }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Color")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            ForEach(presetColors, id: \.self) { hex in
                                ColorSwatchButton(
                                    hex: hex,
                                    isSelected: newDivisionColor == hex,
                                    onSelect: { newDivisionColor = hex }
                                )
                            }
                        }
                    }

                    Toggle("Include in EOD Report Summary", isOn: $newDivisionIncludeInEOD)
                        .font(.caption)

                    if let error = newDivisionError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    HStack {
                        Button("Cancel") {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                showingAddDivisionSheet = false
                            }
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Button("Create Division") {
                            let trimmed = newDivisionName.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else {
                                newDivisionError = "Name cannot be empty"
                                return
                            }
                            if appState.workspaces.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                                newDivisionError = "Division with this name already exists"
                                return
                            }
                            let keyStr = newDivisionKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                            if !keyStr.isEmpty, appState.workspaces.contains(where: { $0.shortcutKey == keyStr }) {
                                newDivisionError = "Shortcut ⌥⌘\(keyStr) is already in use"
                                return
                            }

                            appState.addWorkspace(
                                name: trimmed,
                                shortcutKey: keyStr.isEmpty ? nil : keyStr,
                                colorHex: newDivisionColor,
                                includeInEOD: newDivisionIncludeInEOD
                            )
                            withAnimation(.easeInOut(duration: 0.16)) {
                                showingAddDivisionSheet = false
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(.top, 6)
                }
                .padding(18)
                .frame(width: 320)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.35), radius: 20, y: 10)
                .transition(.scale(scale: 0.95).combined(with: .opacity))
            }

            if let editing = editingDivision {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            editingDivision = nil
                        }
                    }

                VStack(alignment: .leading, spacing: 14) {
                    Text("Edit Division")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Division Name")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("e.g. Work, Personal, Client X", text: $editDivisionName)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Keyboard Shortcut Key (⌥⌘ + Key)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Single Letter (e.g. O, P, F)", text: Binding(
                            get: { editDivisionKey },
                            set: { editDivisionKey = String($0.prefix(1)).uppercased() }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Color")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            ForEach(presetColors, id: \.self) { hex in
                                ColorSwatchButton(
                                    hex: hex,
                                    isSelected: editDivisionColor == hex,
                                    onSelect: { editDivisionColor = hex }
                                )
                            }
                        }
                    }

                    Toggle("Include in EOD Report Summary", isOn: $editDivisionIncludeInEOD)
                        .font(.caption)

                    if let error = editDivisionError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    HStack {
                        Button("Cancel") {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                editingDivision = nil
                            }
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Button("Save Changes") {
                            let trimmed = editDivisionName.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else {
                                editDivisionError = "Name cannot be empty"
                                return
                            }
                            if appState.workspaces.contains(where: { $0.id != editing.id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                                editDivisionError = "Division with this name already exists"
                                return
                            }
                            let keyStr = editDivisionKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                            if !keyStr.isEmpty, appState.workspaces.contains(where: { $0.id != editing.id && $0.shortcutKey == keyStr }) {
                                editDivisionError = "Shortcut ⌥⌘\(keyStr) is already in use"
                                return
                            }

                            var updated = editing
                            updated.name = trimmed
                            updated.shortcutKey = keyStr.isEmpty ? nil : keyStr
                            updated.colorHex = editDivisionColor
                            updated.includeInEOD = editDivisionIncludeInEOD
                            appState.updateWorkspace(updated)

                            withAnimation(.easeInOut(duration: 0.16)) {
                                editingDivision = nil
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(.top, 6)
                }
                .padding(18)
                .frame(width: 320)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.35), radius: 20, y: 10)
                .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
        }
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

                VStack(alignment: .leading, spacing: 6) {
                    Text("Note Title in Apple Notes")
                        .font(.system(size: 13, weight: .medium))
                    HStack {
                        TextField("TASKS — TODAY", text: Binding(
                            get: { appState.notesNoteTitle },
                            set: { appState.notesNoteTitle = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)

                        if appState.notesNoteTitle != "TASKS — TODAY" {
                            Button("Reset") {
                                appState.notesNoteTitle = "TASKS — TODAY"
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        }
                    }
                    Text("Daily tasks and sections will sync to this note in Apple Notes.")
                        .font(.system(size: 10))
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

private struct ColorSwatchButton: View {
    let hex: String
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            Circle()
                .fill(Color(hex: hex) ?? Color.blue)
                .frame(width: 20, height: 20)
                .overlay(
                    Circle()
                        .stroke(Color.primary, lineWidth: isSelected ? 2 : 0)
                )
        }
        .buttonStyle(.plain)
    }
}

