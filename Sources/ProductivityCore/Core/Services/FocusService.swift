import Foundation
import SwiftUI
import SwiftData
import Combine

public enum FocusMode: String, CaseIterable, Codable, Sendable {
    case focus = "Focus"
    case shortBreak = "Short Break"
    case longBreak = "Long Break"

    public var iconName: String {
        switch self {
        case .focus: return "brain.head.profile"
        case .shortBreak: return "cup.and.saucer.fill"
        case .longBreak: return "figure.walk"
        }
    }
}

public enum PomodoroState: Equatable, Sendable {
    case idle
    case running(mode: FocusMode, targetEnd: Date, totalSeconds: TimeInterval)
    case paused(mode: FocusMode, remainingSeconds: TimeInterval, totalSeconds: TimeInterval)
}

@Observable
@MainActor
public final class FocusService {
    public static let shared = FocusService()

    public var state: PomodoroState = .idle
    public var currentMode: FocusMode = .focus
    public var timeRemaining: TimeInterval = 25 * 60
    public var totalDuration: TimeInterval = 25 * 60
    public var isRunning: Bool = false

    // Attached task info
    public var activeTaskId: UUID?
    public var activeTaskTitle: String?
    public var activeWorkspace: Workspace = .work

    // Configurations
    public var focusDurationMinutes: Int = 25
    public var shortBreakMinutes: Int = 5
    public var longBreakMinutes: Int = 15

    // Daily stats
    public var todayFocusMinutes: Int = 0
    public var completedSessionsToday: Int = 0

    private var timerCancellable: AnyCancellable?
    private var sessionStartDate: Date?

    private init() {
        self.timeRemaining = TimeInterval(focusDurationMinutes * 60)
        self.totalDuration = self.timeRemaining
        startHeartbeat()
    }

    public var formattedTimeRemaining: String {
        let minutes = max(0, Int(timeRemaining) / 60)
        let seconds = max(0, Int(timeRemaining) % 60)
        return String(format: "%02d:%02d", minutes, seconds)
    }

    public var menuBarDisplayString: String {
        switch state {
        case .running:
            return "🍅 \(formattedTimeRemaining)"
        case .paused:
            return "⏸ \(formattedTimeRemaining)"
        case .idle:
            return ""
        }
    }

    public var progress: Double {
        guard totalDuration > 0 else { return 0 }
        let elapsed = totalDuration - timeRemaining
        return min(max(elapsed / totalDuration, 0), 1.0)
    }

    public func startFocus(for task: TaskItem? = nil, mode: FocusMode = .focus) {
        self.currentMode = mode
        let durationMinutes: Int
        switch mode {
        case .focus:
            durationMinutes = focusDurationMinutes
        case .shortBreak:
            durationMinutes = shortBreakMinutes
        case .longBreak:
            durationMinutes = longBreakMinutes
        }

        let seconds = TimeInterval(durationMinutes * 60)
        self.totalDuration = seconds
        self.timeRemaining = seconds
        let targetEnd = Date().addingTimeInterval(seconds)

        if let task = task {
            self.activeTaskId = task.id
            self.activeTaskTitle = task.title
            self.activeWorkspace = task.workspace
        } else if mode == .focus && activeTaskId == nil {
            self.activeTaskTitle = "General Focus"
        }

        self.sessionStartDate = Date()
        self.state = .running(mode: mode, targetEnd: targetEnd, totalSeconds: seconds)
        self.isRunning = true
    }

    public func pause() {
        guard case let .running(mode, targetEnd, total) = state else { return }
        let remaining = max(0, targetEnd.timeIntervalSince(Date()))
        self.state = .paused(mode: mode, remainingSeconds: remaining, totalSeconds: total)
        self.timeRemaining = remaining
        self.isRunning = false
    }

    public func resume() {
        guard case let .paused(mode, remaining, total) = state else { return }
        let targetEnd = Date().addingTimeInterval(remaining)
        self.state = .running(mode: mode, targetEnd: targetEnd, totalSeconds: total)
        self.isRunning = true
    }

    public func stop() {
        self.state = .idle
        self.isRunning = false
        self.timeRemaining = TimeInterval(focusDurationMinutes * 60)
        self.totalDuration = self.timeRemaining
        self.sessionStartDate = nil
    }

    public func finishEarly(context: ModelContext) {
        guard isRunning || state != .idle else { return }
        completeSession(context: context, early: true)
    }

    private func startHeartbeat() {
        timerCancellable = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.tick()
            }
    }

    private func tick() {
        guard case let .running(_, targetEnd, total) = state else { return }
        let remaining = targetEnd.timeIntervalSince(Date())

        if remaining <= 0 {
            self.timeRemaining = 0
            completeSession(context: PersistenceController.shared.mainContext, early: false)
        } else {
            self.timeRemaining = remaining
            self.totalDuration = total
        }
    }

    private func completeSession(context: ModelContext, early: Bool) {
        let completedMode = currentMode
        let startDate = sessionStartDate ?? Date()
        let endDate = Date()
        let elapsedMinutes = max(1, Int(endDate.timeIntervalSince(startDate) / 60))

        if completedMode == .focus {
            let session = FocusSession(
                taskId: activeTaskId,
                taskTitle: activeTaskTitle,
                workspace: activeWorkspace,
                durationMinutes: elapsedMinutes,
                startedAt: startDate,
                completedAt: endDate
            )
            context.insert(session)

            if let taskId = activeTaskId {
                let descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskId })
                if let matchedTask = (try? context.fetch(descriptor))?.first {
                    matchedTask.focusMinutes += elapsedMinutes
                    matchedTask.pomodoroCount += 1
                    matchedTask.updatedAt = Date()
                }
            }

            try? context.save()
            todayFocusMinutes += elapsedMinutes
            completedSessionsToday += 1

            NotificationService.shared.sendNotification(
                title: "Focus Session Finished! 🍅",
                body: "Great job! Take a well-deserved \(shortBreakMinutes)-minute break."
            )
        } else {
            NotificationService.shared.sendNotification(
                title: "Break Completed! ⚡️",
                body: "Ready to jump back in? Start your next focus block."
            )
        }

        stop()
    }
}
