import Foundation
import SwiftUI

public struct WorkspaceDefinition: Identifiable, Codable, Hashable, Sendable {
    public var id: String             // Unique slug e.g. "work", "personal", "freelance"
    public var name: String           // Display name e.g. "Work", "Personal", "Freelance", "Acme Corp"
    public var iconName: String       // SF Symbol name e.g. "briefcase.fill", "person.fill", "laptopcomputer"
    public var colorHex: String       // Hex color string e.g. "#3B82F6"
    public var shortcutKey: String?   // Key for ⌥⌘<Key>, e.g. "W", "P", "F", "1", "2"
    public var includeInEOD: Bool     // Whether tasks are included in EOD report
    public var isSystem: Bool         // Optional indicator
    public var sortOrder: Int

    public init(
        id: String,
        name: String,
        iconName: String = "briefcase.fill",
        colorHex: String = "#3B82F6",
        shortcutKey: String? = nil,
        includeInEOD: Bool = true,
        isSystem: Bool = false,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.colorHex = colorHex
        self.shortcutKey = shortcutKey
        self.includeInEOD = includeInEOD
        self.isSystem = isSystem
        self.sortOrder = sortOrder
    }
}

public struct Workspace: RawRepresentable, Identifiable, Codable, Hashable, Sendable {
    public var rawValue: String
    public var id: String { rawValue }

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let work = Workspace(rawValue: "work")
    public static let personal = Workspace(rawValue: "personal")
    public static let freelance = Workspace(rawValue: "freelance")

    @MainActor public static var allCases: [Workspace] {
        AppState.shared.workspaces.map { Workspace(rawValue: $0.id) }
    }

    @MainActor public var displayName: String {
        if let def = AppState.shared.workspaceDefinition(for: self) {
            return def.name
        }
        switch rawValue {
        case "work": return "Work"
        case "personal": return "Personal"
        case "freelance": return "Freelance"
        default: return rawValue.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    @MainActor public var iconName: String {
        if let def = AppState.shared.workspaceDefinition(for: self) {
            return def.iconName
        }
        switch rawValue {
        case "work": return "briefcase.fill"
        case "personal": return "person.fill"
        case "freelance": return "laptopcomputer"
        default: return "folder.fill"
        }
    }

    @MainActor public var shortcutHint: String {
        if let def = AppState.shared.workspaceDefinition(for: self), let key = def.shortcutKey, !key.isEmpty {
            return "⌥⌘\(key.uppercased())"
        }
        switch rawValue {
        case "work": return "⌥⌘W"
        case "personal": return "⌥⌘P"
        case "freelance": return "⌥⌘F"
        default: return ""
        }
    }

    @MainActor public var accentColor: Color {
        if let def = AppState.shared.workspaceDefinition(for: self) {
            return Color(hex: def.colorHex) ?? Color(red: 0.25, green: 0.45, blue: 0.95)
        }
        switch rawValue {
        case "work": return Color(red: 0.25, green: 0.45, blue: 0.95) // Blue
        case "personal": return Color(red: 0.15, green: 0.70, blue: 0.50) // Emerald
        case "freelance": return Color(red: 0.55, green: 0.35, blue: 0.95) // Purple
        default: return Color.accentColor
        }
    }

    @MainActor public var isIncludedInEOD: Bool {
        if let def = AppState.shared.workspaceDefinition(for: self) {
            return def.includeInEOD
        }
        return rawValue != "personal"
    }
}

extension Color {
    public init?(hex: String) {
        var cleanHex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanHex.hasPrefix("#") {
            cleanHex.removeFirst()
        }
        guard cleanHex.count == 6, let intVal = UInt64(cleanHex, radix: 16) else {
            return nil
        }
        let r = Double((intVal >> 16) & 0xFF) / 255.0
        let g = Double((intVal >> 8) & 0xFF) / 255.0
        let b = Double(intVal & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }

    public func toHex() -> String {
        #if canImport(AppKit)
        let nsColor = NSColor(self)
        if let rgbColor = nsColor.usingColorSpace(.sRGB) {
            let r = Int(round(rgbColor.redComponent * 255))
            let g = Int(round(rgbColor.greenComponent * 255))
            let b = Int(round(rgbColor.blueComponent * 255))
            return String(format: "#%02X%02X%02X", r, g, b)
        }
        #endif
        return "#3B82F6"
    }
}
