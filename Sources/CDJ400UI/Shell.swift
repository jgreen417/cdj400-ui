import Foundation

/// Runs a short read-only command off the main thread and returns its output.
/// Long jobs that need progress and a Stop button go through CommandRunner.
enum Shell {
    static func output(_ command: String) async -> (text: String, status: Int32) {
        await Task.detached {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/zsh")
            task.arguments = ["-lc", command]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            do { try task.run() } catch { return (error.localizedDescription, 1) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return (String(decoding: data, as: UTF8.self), task.terminationStatus)
        }.value
    }
}

/// ~/Library/Application Support/CDJ400UI: run history and per-stick XML exports.
enum AppSupport {
    static let directory: URL = {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CDJ400UI", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()
}
