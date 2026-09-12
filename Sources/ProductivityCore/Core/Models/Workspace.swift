import Foundation
import SwiftUI

public enum Workspace: String, CaseIterable, Identifiable, Codable, Sendable {
    case work = "work"
    case personal = "personal"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .work:
            return "Work"
        case .personal:
            return "Personal"
        }
    }

    public var iconName: String {
        switch self {
        case .work:
            return "briefcase.fill"
        case .personal:
            return "person.fill"
        }
    }

    public var shortcutHint: String {
        switch self {
        case .work:
            return "⌥⌘W"
        case .personal:
            return "⌥⌘P"
        }
    }

    public var accentColor: Color {
        switch self {
        case .work:
            return Color(red: 0.25, green: 0.45, blue: 0.95) // Indigo/Blue
        case .personal:
            return Color(red: 0.15, green: 0.70, blue: 0.50) // Emerald/Green
        }
    }
}
