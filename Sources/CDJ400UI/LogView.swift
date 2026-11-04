import SwiftUI

/// The output pane: the running job's log, or an earlier run picked from History.
struct LogView: View {
    @ObservedObject var runner: CommandRunner

    @State private var showCopied = false
    @State private var viewing: RunRecord?

    private let bottomID = "log-bottom"
    private var isRunning: Bool { runner.isRunning }
    private var history: [RunRecord] { runner.history }
    private var shownText: String { viewing?.log ?? runner.log }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            output
        }
        .background(.background)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Output")
                .font(.headline)
            if let viewing {
                Text("\(viewing.title) · \(viewing.date.formatted(.relative(presentation: .named)))")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("Back to Latest") { self.viewing = nil }
                    .buttonStyle(.link)
            }
            if isRunning {
                ProgressView().controlSize(.mini)
                    .transaction { $0.animation = nil }
            }
            Spacer()
            if isRunning {
                Button("Stop", systemImage: "stop.fill", role: .destructive) { runner.stop() }
                    .foregroundStyle(.red)
                    .keyboardShortcut(.escape, modifiers: .command)
                    .help("Stop the running job (⌘⎋)")
            }
            if !history.isEmpty {
                Menu("History", systemImage: "clock.arrow.circlepath") {
                    ForEach(history) { record in
                        Button {
                            viewing = record
                        } label: {
                            Label("\(record.title) · \(record.date.formatted(.relative(presentation: .named)))",
                                  systemImage: record.succeeded ? "checkmark.circle" : "xmark.circle")
                        }
                    }
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Output from earlier runs")
            }
            Button(showCopied ? "Copied" : "Copy", systemImage: showCopied ? "checkmark" : "doc.on.doc") { copyLog() }
                .disabled(isRunning || shownText.isEmpty)
                .help("Copy the output")
            Button("Clear", systemImage: "trash") { runner.clear() }
                .disabled(isRunning)
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .help("Clear the output (⇧⌘K)")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var output: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(shownText.isEmpty ? "Nothing yet." : shownText)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(shownText.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .id(bottomID)
            }
            .onChange(of: runner.log) {
                viewing = nil
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        }
    }

    private func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shownText, forType: .string)
        showCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showCopied = false
        }
    }
}
