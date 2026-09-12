import Foundation
import SwiftData

@Model
public final class EODSnapshot {
    @Attribute(.unique) public var id: UUID
    public var date: Date
    public var completedCount: Int
    public var inProgressCount: Int
    public var carriedForwardCount: Int
    public var focusMinutes: Int
    public var content: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        completedCount: Int,
        inProgressCount: Int,
        carriedForwardCount: Int,
        focusMinutes: Int,
        content: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.date = date
        self.completedCount = completedCount
        self.inProgressCount = inProgressCount
        self.carriedForwardCount = carriedForwardCount
        self.focusMinutes = focusMinutes
        self.content = content
        self.createdAt = createdAt
    }
}
