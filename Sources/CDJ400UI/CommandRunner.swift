import Foundation
import UserNotifications

/// One finished job, kept so its output can be read again later.
struct RunRecord: Codable, Identifiable, Hashable {
    let id: UUID
    let title: String
    let date: Date
    let exit: Int32
    let log: String

    var succeeded: Bool { exit == 0 }
}

/// Finished jobs, newest first, saved in AppSupport.directory.
enum RunHistory {
    static let limit = 25
    private static let file = AppSupport.directory.appendingPathComponent("history.json")

    static func load() -> [RunRecord] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([RunRecord].self, from: data)) ?? []
    }

    static func save(_ records: [RunRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: file, options: .atomic)
    }
}

/// Posts a banner when a job finishes. Needs a real app bundle, so a bare
/// `swift run` binary skips it.
enum Notifier {
    private static var available: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// Bytes copied so far, parsed from the tools' `PROGRESS <done> <total>` lines.
struct TransferProgress: Equatable {
    let done: Int64
    let total: Int64
    let bytesPerSecond: Double

    var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }

    var secondsRemaining: Double? {
        guard bytesPerSecond > 0, total > done else { return nil }
        return Double(total - done) / bytesPerSecond
    }
}

/// Runs one long job at a time (usually a cdj400-* tool) and streams its
/// output into `log`.
@MainActor
final class CommandRunner: ObservableObject {
    @Published private(set) var log = ""
    @Published private(set) var isRunning = false
    @Published private(set) var lastExit: Int32?
    @Published private(set) var progress: TransferProgress?
    @Published private(set) var history: [RunRecord] = RunHistory.load()

    private var process: Process?
    /// Output after the last newline, kept as bytes so a UTF-8 character split
    /// across two reads is decoded whole.
    private var partialLine = Data()
    private var progressStart: Date?
    private var currentTitle = ""
    private var isStopping = false

    func run(title: String, command: String) {
        guard !isRunning else { return }

        log = "$ \(title)\n"
        currentTitle = title
        lastExit = nil
        progress = nil
        partialLine = Data()
        progressStart = nil
        isStopping = false
        isRunning = true

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-lc", command]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        // The job normally finishes when its output reaches EOF, so the last
        // lines (usually the ones that say what went wrong) are never dropped.
        // If a stray grandchild keeps the pipe open after the shell exits, the
        // termination handler finishes it a second later instead.
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                task.waitUntilExit()
                let status = task.terminationStatus
                Task { @MainActor [weak self] in self?.finish(task, exit: status) }
            } else {
                Task { @MainActor [weak self] in self?.ingest(data) }
            }
        }
        task.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.finish(task, exit: status)
            }
        }

        process = task
        do {
            try task.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            log += "could not launch: \(error.localizedDescription)\n"
            finish(task, exit: 127)
        }
    }

    /// Splits output into lines: `PROGRESS` lines drive the progress bar and stay
    /// out of the log (one per file would bury everything else).
    func ingest(_ data: Data) {
        partialLine.append(data)
        guard let newline = partialLine.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let complete = String(decoding: partialLine[..<newline], as: UTF8.self)
        partialLine = Data(partialLine[partialLine.index(after: newline)...])

        var appended = ""
        for line in complete.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("PROGRESS ") {
                updateProgress(from: line)
            } else {
                appended += line + "\n"
            }
        }
        if !appended.isEmpty { log += appended }
    }

    private func updateProgress(from line: Substring) {
        let parts = line.split(separator: " ")
        guard parts.count >= 3, let done = Int64(parts[1]), let total = Int64(parts[2]) else { return }
        let now = Date()
        let start = progressStart ?? now
        progressStart = start
        let elapsed = now.timeIntervalSince(start)
        let rate = elapsed > 0.5 ? Double(done) / elapsed : 0
        progress = TransferProgress(done: done, total: total, bytesPerSecond: rate)
    }

    /// Wraps up `task`'s run; a no-op if that run was already wrapped up.
    private func finish(_ task: Process, exit: Int32) {
        guard process === task else { return }
        if !partialLine.isEmpty {
            log += String(decoding: partialLine, as: UTF8.self)
            partialLine = Data()
        }
        log += "\n[finished — exit \(exit)]\n"
        progress = nil
        process = nil
        isRunning = false
        record(exit: exit)
        lastExit = exit
    }

    func stop() {
        guard let process, isRunning, !isStopping else { return }
        isStopping = true
        log += "\n[stopping…]\n"

        // Kill this job's process tree (zsh → python tool → rsync). A blanket
        // `pkill -f cdj400-` would also kill unrelated cdj400 work on the
        // machine, so collect the descendants first and only kill those.
        let pid = process.processIdentifier
        let killer = Process()
        killer.executableURL = URL(fileURLWithPath: "/bin/sh")
        killer.arguments = ["-c", """
            kids=$(pgrep -P \(pid))
            grand=$(for p in $kids; do pgrep -P "$p"; done)
            kill -TERM $grand $kids \(pid) 2>/dev/null
            exit 0
            """]
        try? killer.run()
    }

    private func record(exit: Int32) {
        let entry = RunRecord(id: UUID(), title: currentTitle, date: Date(),
                              exit: exit, log: String(log.suffix(40_000)))
        history = Array(([entry] + history).prefix(RunHistory.limit))
        RunHistory.save(history)

        let summary = log.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty && !$0.hasPrefix("[finished") } ?? ""
        Notifier.post(title: exit == 0 ? "Done: \(currentTitle)" : "Failed: \(currentTitle)",
                      body: summary)
    }

    func clear() {
        guard !isRunning else { return }
        log = ""
        lastExit = nil
    }
}
