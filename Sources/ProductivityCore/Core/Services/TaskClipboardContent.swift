import Foundation

/// Defines the exact user-facing text copied from a task row.
public enum TaskClipboardContent {
    public static func title(for task: TaskItem) -> String {
        task.title
    }
}
