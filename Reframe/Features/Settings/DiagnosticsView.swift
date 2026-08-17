import ReframeKit
import SwiftUI

/// The screen that substitutes for a debugger.
///
/// This project is built on Windows with no Mac, so there is no Xcode console, no breakpoints
/// and no Instruments. A run that fails on the device would otherwise report as "it broke".
/// Here the user taps **Export Log** and sends a text file that says exactly which stage ran,
/// how long it took, what it produced and where it stopped.
struct DiagnosticsView: View {

    @State private var entries: [DiagnosticsLog.Entry] = []
    @State private var shareURL: URL?
    @State private var showsCopied = false

    var body: some View {
        List {
            Section {
                Text(DeviceInfo.summary())
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.Palette.secondaryText)
                    .textSelection(.enabled)
            } header: {
                Text("Device")
            }

            Section {
                Button {
                    export()
                } label: {
                    Label("Export Log", systemImage: "square.and.arrow.up")
                }

                Button {
                    UIPasteboard.general.string = DiagnosticsLog.shared.formattedReport()
                    showsCopied = true
                    Haptics.success()
                } label: {
                    Label(showsCopied ? "Copied" : "Copy to Clipboard", systemImage: "doc.on.doc")
                }

                Button(role: .destructive) {
                    DiagnosticsLog.shared.clear()
                    refresh()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
            } footer: {
                Text("The log records what ran, how long it took and where it stopped. It contains no photos and no personal content — only stage names, timings and measurements.")
            }

            Section {
                if entries.isEmpty {
                    Text("Nothing recorded yet. Run an analysis or an export, then come back.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.tertiaryText)
                } else {
                    // Newest first: when something has just gone wrong, the tail is the part
                    // you want, and scrolling to the bottom of 3,000 lines on a phone is
                    // nobody's idea of a good time.
                    ForEach(Array(entries.reversed().enumerated()), id: \.offset) { _, entry in
                        EntryRow(entry: entry)
                    }
                }
            } header: {
                HStack {
                    Text("Log")
                    Spacer()
                    Text("\(entries.count) entries")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.tertiaryText)
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh")
            }
        }
        .task { refresh() }
        .sheet(item: $shareURL) { url in
            DiagnosticsShareSheet(items: [url])
        }
    }

    private func refresh() {
        entries = DiagnosticsLog.shared.snapshot()
        showsCopied = false
    }

    private func export() {
        do {
            shareURL = try DiagnosticsLog.shared.writeReport()
        } catch {
            // Falling back to the clipboard rather than failing: the point of this screen is
            // that the user can always get the log out somehow.
            UIPasteboard.general.string = DiagnosticsLog.shared.formattedReport()
            showsCopied = true
        }
    }
}

private struct EntryRow: View {
    let entry: DiagnosticsLog.Entry

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Text(String(format: "%.2f", entry.elapsed))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Theme.Palette.tertiaryText)
                .frame(width: 46, alignment: .trailing)

            Text(entry.level.marker)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(color)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.message)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.Palette.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(entry.category) · \(Int(entry.memoryMB)) MB")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.Palette.tertiaryText)
            }
        }
        .padding(.vertical, 1)
    }

    private var color: Color {
        switch entry.level {
        case .info: return Theme.Palette.tertiaryText
        case .timing: return Theme.Palette.accent
        case .warning: return Theme.Palette.warning
        case .failure: return Theme.Palette.danger
        }
    }
}

private struct DiagnosticsShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
