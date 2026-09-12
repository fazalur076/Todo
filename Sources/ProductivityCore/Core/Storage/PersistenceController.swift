import Foundation
import SwiftData

@MainActor
public final class PersistenceController {
    public static let shared = PersistenceController()

    public let container: ModelContainer

    public var mainContext: ModelContext {
        container.mainContext
    }

    public init(inMemory: Bool = false) {
        let schema = Schema([
            TaskItem.self,
            FocusSession.self,
            EODSnapshot.self
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory
        )
        do {
            self.container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to initialize SwiftData ModelContainer: \(error)")
        }
    }

    public static var preview: PersistenceController = {
        let controller = PersistenceController(inMemory: true)
        let context = controller.mainContext

        let task1 = TaskItem(title: "Fix report pagination bug", notes: "Ensure offset calculation handles edge cases", workspace: .work, status: .inProgress)
        let task2 = TaskItem(title: "Deploy API v2 updates", notes: "Run smoke tests before rollout", workspace: .work, status: .pending)
        let task3 = TaskItem(title: "Code review for authentication PR", notes: "Check token expiration", workspace: .work, status: .completed)

        let task4 = TaskItem(title: "Morning 5k run", notes: "Lakeside path", workspace: .personal, status: .completed)
        let task5 = TaskItem(title: "Read architecture chapter", notes: "Chapter 4: Concurrency", workspace: .personal, status: .pending)

        context.insert(task1)
        context.insert(task2)
        context.insert(task3)
        context.insert(task4)
        context.insert(task5)

        try? context.save()
        return controller
    }()
}
