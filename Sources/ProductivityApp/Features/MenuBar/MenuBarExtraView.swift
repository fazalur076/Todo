import SwiftUI
import ProductivityCore

public struct MenuBarExtraView: View {
    var appState = AppState.shared
    var focusService = FocusService.shared

    public init() {}

    public var body: some View {
        HStack(spacing: 5) {
            Image(systemName: (focusService.isRunning || focusService.state != .idle) ? "timer" : "checklist")
                .renderingMode(.template)

            if focusService.isRunning || focusService.state != .idle {
                Text(focusService.menuBarDisplayString)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
        }
    }
}
