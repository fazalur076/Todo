import Foundation
import SwiftData

public enum TaskStatus: String, CaseIterable, Codable, Sendable {
    case pending = "pending"
    case inProgress = "inProgress"
    case completed = "completed"

    public var displayName: String {
        switch self {
        case .pending:
            return "Pending"
        case .inProgress:
            return "In Progress"
        case .completed:
            return "Completed"
        }
    }

    public var iconName: String {
        switch self {
        case .pending:
            return "circle"
        case .inProgress:
            return "circle.dotted"
        case .completed:
            return "checkmark.circle.fill"
        }
    }
}

@Model
public final class TaskItem {
    @Attribute(.unique) public var id: UUID
    public var title: String
    public var notes: String?
    public var workspaceRaw: String
    public var statusRaw: String
    public var createdAt: Date
    public var updatedAt: Date
    public var scheduledDate: Date
    public var completedAt: Date?
    public var sortOrder: Int
    public var focusMinutes: Int
    public var pomodoroCount: Int

    public var workspace: Workspace {
        get { Workspace(rawValue: workspaceRaw) ?? .work }
        set { workspaceRaw = newValue.rawValue; updatedAt = Date() }
    }

    public var status: TaskStatus {
        get { TaskStatus(rawValue: statusRaw) ?? .pending }
        set {
            statusRaw = newValue.rawValue
            updatedAt = Date()
            if newValue == .completed {
                completedAt = Date()
            } else {
                completedAt = nil
            }
        }
    }

    public init(
        id: UUID = UUID(),
        title: String,
        notes: String? = nil,
        workspace: Workspace = .work,
        status: TaskStatus = .pending,
        scheduledDate: Date = Calendar.current.startOfDay(for: Date()),
        sortOrder: Int = 0,
        focusMinutes: Int = 0,
        pomodoroCount: Int = 0
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.workspaceRaw = workspace.rawValue
        self.statusRaw = status.rawValue
        self.createdAt = Date()
        self.updatedAt = Date()
        self.scheduledDate = scheduledDate
        self.completedAt = (status == .completed) ? Date() : nil
        self.sortOrder = sortOrder
        self.focusMinutes = focusMinutes
        self.pomodoroCount = pomodoroCount
    }

    public var isScheduledForToday: Bool {
        Calendar.current.isDateInToday(scheduledDate)
    }

    public var isOverdue: Bool {
        status != .completed && scheduledDate < Calendar.current.startOfDay(for: Date())
    }

    public func moveToTomorrow() {
        let calendar = Calendar.current
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) {
            self.scheduledDate = tomorrow
            self.updatedAt = Date()
        }
    }
}
