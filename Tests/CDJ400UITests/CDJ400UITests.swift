import Foundation
import Testing
@testable import CDJ400UI

private func stick(path: String = "/Volumes/TEST", name: String = "TEST") -> Stick {
    Stick(path: path, name: name, mode: .lean, playlists: [], tracks: 0, sidecars: 0,
          freeBytes: 0, totalBytes: 0, lastChange: nil)
}

/// Runs `command` the way the app does and returns its combined output.
private func zsh(_ command: String) async -> (text: String, status: Int32) {
    await Shell.output(command)
}

@Suite struct ShellQuoting {
    @Test(arguments: ["plain", "two words", "Josh's USB", "'; rm -rf ~; '", "$HOME `id` \"q\""])
    func quoteSurvivesTheShell(_ value: String) async {
        let result = await zsh("printf %s \(StickCommands.quote(value))")
        #expect(result.status == 0)
        #expect(result.text == value)
    }

    @Test func removeSidecarsHandlesApostrophesInTheStickName() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cdj400-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("._track.mp3"))
        try Data().write(to: dir.appendingPathComponent("track.mp3"))

        let result = await zsh(StickCommands.removeSidecars(stick: stick(path: dir.path, name: "Josh's")))

        #expect(result.status == 0)
        #expect(result.text == "removed 1 sidecar files from Josh's\n")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("._track.mp3").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("track.mp3").path))
    }
}

@Suite struct VendoredTools {
    /// The tests run with the default lookup, so point at the repo's copy explicitly.
    private let tools = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("tools")

    @Test(arguments: ["cdj400-addplaylist", "cdj400-adopt", "cdj400-copystick", "cdj400-dbexport", "cdj400-sort"])
    func everyToolTheAppCallsRuns(_ name: String) async {
        let result = await zsh("\(StickCommands.quote(tools.appendingPathComponent(name).path)) --help")
        #expect(result.status == 0, "\(name): \(result.text)")
        #expect(result.text.contains("usage: \(name)"))
    }
}

@Suite struct ToolOutputParsing {
    @Test func statusLine() throws {
        let sync = try #require(PlaylistSync(statusLine: "Warmup\tWarmup Grooves\t3\t1\t1048576"))
        #expect(sync.folder == "Warmup")
        #expect(sync.playlist == "Warmup Grooves")
        #expect(sync.needsUpdate)
        #expect(sync.summary == "3 new · 1 removed")
    }

    @Test func statusLineWithoutPlaylist() throws {
        let sync = try #require(PlaylistSync(statusLine: "Old\t\t0\t0\t0"))
        #expect(sync.playlist == nil)
        #expect(!sync.needsUpdate)
        #expect(sync.summary == "Not in Rekordbox")
    }

    @Test(arguments: ["", "a\tb\t1\t2", "a\tb\tx\t2\t3"])
    func malformedStatusLine(_ line: String) {
        #expect(PlaylistSync(statusLine: Substring(line)) == nil)
    }

    @Test func listLine() throws {
        let withSize = try #require(AddablePlaylist(listLine: "Disco\t12\t50000000"))
        #expect(withSize.tracks == 12)
        #expect(withSize.bytes == 50_000_000)
        let withoutSize = try #require(AddablePlaylist(listLine: "Disco\t12"))
        #expect(withoutSize.bytes == nil)
        #expect(AddablePlaylist(listLine: "Disco") == nil)
    }

    @Test func fitLeavesHeadroom() {
        let mb: Int64 = 1 << 20
        #expect(AddablePlaylist.fits(100 * mb, in: 200 * mb))
        #expect(!AddablePlaylist.fits(100 * mb, in: 150 * mb))
    }
}

@MainActor @Suite struct RunnerOutput {
    @Test func progressLinesStayOutOfTheLog() throws {
        let runner = CommandRunner()
        runner.ingest(Data("copying\nPROGRESS 5 10\ndone\n".utf8))
        #expect(runner.log == "copying\ndone\n")
        let progress = try #require(runner.progress)
        #expect(progress.fraction == 0.5)
    }

    @Test func multibyteCharacterSplitAcrossReads() {
        let runner = CommandRunner()
        let bytes = Array("Café Remix\n".utf8)
        let split = bytes.firstIndex(of: 0xC3)! + 1  // between the two bytes of "é"
        runner.ingest(Data(bytes[..<split]))
        #expect(runner.log == "")
        runner.ingest(Data(bytes[split...]))
        #expect(runner.log == "Café Remix\n")
    }
}

@Suite struct Confirmations {
    @Test func dryRunNeedsNoConfirmation() {
        #expect(Job.action(.dryRun).confirmation(on: stick()) == nil)
        #expect(Job.action(.makeLean).confirmation(on: stick()) != nil)
    }

    @Test func updateConfirmsOnlyWhenItDeletes() throws {
        let adding = try #require(PlaylistSync(statusLine: "A\tA\t2\t0\t0"))
        let pruning = try #require(PlaylistSync(statusLine: "B\tB\t1\t3\t0"))
        #expect(Job.update([adding]).confirmation(on: stick()) == nil)
        #expect(Job.update([adding, pruning]).confirmation(on: stick())?.contains("deletes 3 tracks") == true)
    }
}
