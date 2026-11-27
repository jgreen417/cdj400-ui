import SwiftUI

/// The output pane: the running job with its progress, or the latest (or an
/// earlier) run's log.
struct LogView: View {
    @ObservedObject var runner: CommandRunner
    let onHide: () -> Void

    @State private var showCopied = false
    @State private var viewing: RunRecord?

    private let bottomID = "log-bottom"
    private var isRunning: Bool { runner.isRunning }
    private var history: [RunRecord] { runner.history }
    /// An earlier run picked from History, else the running or last job's
    /// log, else (after a relaunch) the newest saved run's.
    private var shownText: String {
        viewing?.log ?? (runner.log.isEmpty && !isRunning ? history.first?.log ?? "" : runner.log)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isRunning, let progress = runner.progress {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                    .tint(.green)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 4)
                    .accessibilityLabel("Copy progress")
            }
            output
        }
        .background(.background)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subline {
                    Text(subline)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            if viewing != nil {
                Button("Back to Latest") { viewing = nil }
                    .buttonStyle(.link)
            }
            Spacer()
            if isRunning {
                Button("Stop", role: .destructive) { runner.stop() }
                    .keyboardShortcut(.escape, modifiers: .command)
                    .help("Stop the running job (⌘⎋)")
            }
            HStack(spacing: 10) {
                if !history.isEmpty {
                    Menu("History", systemImage: "clock.arrow.circlepath") {
                        ForEach(history) { record in
                            Button {
                                viewing = record
                            } label: {
                                Label("\(record.title), \(record.date.formatted(.relative(presentation: .named)))",
                                      systemImage: record.succeeded ? "checkmark.circle" : "xmark.circle")
                            }
                        }
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Output from earlier jobs")
                }
                Button(showCopied ? "Copied" : "Copy", systemImage: showCopied ? "checkmark" : "doc.on.doc") { copyLog() }
                    .disabled(isRunning || shownText.isEmpty)
                    .help("Copy the output")
                Button("Clear", systemImage: "trash") { runner.clear() }
                    .disabled(isRunning)
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                    .help("Clear the output (⇧⌘K)")
                Button("Hide Output", systemImage: "chevron.down", action: onHide)
                    .help("Shrink the output to the status bar")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var headline: String {
        if let viewing { return viewing.title }
        if isRunning { return runner.runningTitle }
        return history.first?.title ?? "Output"
    }

    /// Progress while copying; when an earlier run is shown, when it ran.
    private var subline: String? {
        if let viewing {
            return "\(viewing.succeeded ? "Finished" : "Failed") \(viewing.date.formatted(.relative(presentation: .named)))"
        }
        guard isRunning else { return nil }
        guard let progress = runner.progress else { return "Running…" }
        var parts = ["\(progress.done.fileSize) of \(progress.total.fileSize)"]
        if progress.bytesPerSecond > 0 { parts.append(String(format: "%.0f MB/s", progress.bytesPerSecond / 1e6)) }
        if let left = progress.secondsRemaining { parts.append("about \(duration(left)) left") }
        return parts.joined(separator: " · ")
    }

    private func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 60 ? "\(s / 60) min \(s % 60) s" : "\(s) s"
    }

    private var output: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(shownText.isEmpty ? "Nothing yet." : shownText)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineSpacing(3)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
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
