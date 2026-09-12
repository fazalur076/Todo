import Foundation
import SwiftData

@Model
public final class FocusSession {
    @Attribute(.unique) public var id: UUID
    public var taskId: UUID?
    public var taskTitle: String?
    public var workspaceRaw: String
    public var durationMinutes: Int
    public var startedAt: Date
    public var completedAt: Date

    public var workspace: Workspace {
        get { Workspace(rawValue: workspaceRaw) ?? .work }
        set { workspaceRaw = newValue.rawValue }
    }

    public init(
        id: UUID = UUID(),
        taskId: UUID? = nil,
        taskTitle: String? = nil,
        workspace: Workspace = .work,
        durationMinutes: Int,
        startedAt: Date,
        completedAt: Date = Date()
    ) {
        self.id = id
        self.taskId = taskId
        self.taskTitle = taskTitle
        self.workspaceRaw = workspace.rawValue
        self.durationMinutes = durationMinutes
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}
