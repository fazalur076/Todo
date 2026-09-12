import SwiftUI
import SwiftData
import ProductivityCore

public struct EODView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \EODSnapshot.createdAt, order: .reverse) private var pastSnapshots: [EODSnapshot]

    @State private var currentReportText: String = ""
    @State private var isCopied: Bool = false
    @State private var isSaved: Bool = false
    @State private var selectedTab: Int = 0 // 0 = Today, 1 = History

    var onClose: () -> Void

    public init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Label("End of Day Summary", systemImage: "doc.text.fill")
                    .font(.headline)

                Spacer()

                Picker("", selection: $selectedTab) {
                    Text("Today's EOD").tag(0)
                    Text("History (\(pastSnapshots.count))").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
            }
            .padding(16)

            Divider()

            if selectedTab == 0 {
                todayEODView
            } else {
                historyEODView
            }
        }
        .frame(width: 480, height: 500)
        .background(.ultraThinMaterial)
        .onAppear {
            loadTodayReport()
        }
    }

    private var todayEODView: some View {
        VStack(spacing: 12) {
            Text("Generated automatically from Work tasks completed, active, and carried forward today.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 10)

            TextEditor(text: $currentReportText)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 16)

            HStack(spacing: 12) {
                Button {
                    loadTodayReport()
                } label: {
                    Label("Regenerate", systemImage: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                Button {
                    saveSnapshot()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isSaved ? "checkmark" : "square.and.arrow.down")
                        Text(isSaved ? "Saved" : "Save Snapshot")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)

                Button {
                    copyToClipboard()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        Text(isCopied ? "Copied!" : "Copy EOD")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private var historyEODView: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if pastSnapshots.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
                        Text("No saved snapshots yet")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 40)
                } else {
                    ForEach(pastSnapshots) { snapshot in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(snapshot.date, style: .date)
                                    .font(.system(size: 13, weight: .bold))
                                Spacer()
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(snapshot.content, forType: .string)
                                } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderless)
                            }

                            Text(snapshot.content)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(6)
                        }
                        .padding(12)
                        .background(Color.primary.opacity(0.03))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding(16)
        }
    }

    private func loadTodayReport() {
        let report = EODService.shared.generateReport(from: modelContext)
        currentReportText = report.formattedText
        isCopied = false
        isSaved = false
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentReportText, forType: .string)
        withAnimation {
            isCopied = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            isCopied = false
        }
    }

    private func saveSnapshot() {
        let report = EODService.shared.generateReport(from: modelContext)
        _ = EODService.shared.saveSnapshot(report: report, context: modelContext)
        withAnimation {
            isSaved = true
        }
    }
}
