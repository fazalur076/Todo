import Foundation
import SwiftData

@MainActor
public final class EODService {
    public static let shared = EODService()

    private init() {}

    public struct EODReport {
        public let date: Date
        public let completedTasks: [TaskItem]
        public let inProgressTasks: [TaskItem]
        public let carriedForwardTasks: [TaskItem]
        public let focusMinutes: Int
        public let formattedText: String
    }

    public func generateReport(from context: ModelContext, targetDate: Date = Date()) -> EODReport {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: targetDate)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? targetDate

        // Fetch tasks: strictly filter by WORK only
        let workRaw = Workspace.work.rawValue
        let taskDescriptor = FetchDescriptor<TaskItem>(
            predicate: #Predicate<TaskItem> { item in
                item.workspaceRaw == workRaw
            },
            sortBy: [SortDescriptor(\.sortOrder)]
        )

        let allWorkTasks = (try? context.fetch(taskDescriptor)) ?? []

        // Completed today
        let completed = allWorkTasks.filter { task in
            task.status == .completed &&
            (task.completedAt.map { $0 >= startOfDay && $0 < endOfDay } ?? task.isScheduledForToday)
        }

        // In Progress
        let inProgress = allWorkTasks.filter { task in
            task.status == .inProgress
        }

        // Carried Forward / Pending today or overdue
        let carriedForward = allWorkTasks.filter { task in
            task.status == .pending && (task.scheduledDate <= endOfDay)
        }

        // Fetch today's Work focus sessions
        let sessionDescriptor = FetchDescriptor<FocusSession>(
            predicate: #Predicate<FocusSession> { session in
                session.workspaceRaw == workRaw
            }
        )
        let allSessions = (try? context.fetch(sessionDescriptor)) ?? []
        let todaySessions = allSessions.filter { session in
            session.completedAt >= startOfDay && session.completedAt < endOfDay
        }
        let totalFocusMinutes = todaySessions.reduce(0) { $0 + $1.durationMinutes }

        let formattedDateString = Self.dateFormatter.string(from: targetDate)
        var lines: [String] = []
        lines.append("EOD — \(formattedDateString)")
        lines.append("")

        lines.append("Completed")
        if completed.isEmpty {
            lines.append("• (None)")
        } else {
            for task in completed {
                lines.append("• \(task.title)")
            }
        }
        lines.append("")

        lines.append("In Progress")
        if inProgress.isEmpty {
            lines.append("• (None)")
        } else {
            for task in inProgress {
                lines.append("• \(task.title)")
            }
        }
        lines.append("")

        lines.append("Carried Forward")
        if carriedForward.isEmpty {
            lines.append("• (None)")
        } else {
            for task in carriedForward {
                lines.append("• \(task.title)")
            }
        }
        lines.append("")

        lines.append("Focus Time")
        let hours = totalFocusMinutes / 60
        let mins = totalFocusMinutes % 60
        if hours > 0 {
            lines.append("\(hours)h \(String(format: "%02dm", mins))")
        } else {
            lines.append("\(mins)m")
        }

        let fullText = lines.joined(separator: "\n")

        return EODReport(
            date: targetDate,
            completedTasks: completed,
            inProgressTasks: inProgress,
            carriedForwardTasks: carriedForward,
            focusMinutes: totalFocusMinutes,
            formattedText: fullText
        )
    }

    public func saveSnapshot(report: EODReport, context: ModelContext) -> EODSnapshot {
        let snapshot = EODSnapshot(
            date: report.date,
            completedCount: report.completedTasks.count,
            inProgressCount: report.inProgressTasks.count,
            carriedForwardCount: report.carriedForwardTasks.count,
            focusMinutes: report.focusMinutes,
            content: report.formattedText,
            createdAt: Date()
        )
        context.insert(snapshot)
        try? context.save()
        return snapshot
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter
    }()
}
