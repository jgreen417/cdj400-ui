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

@Suite struct DisableSpotlight {
    /// A stick folder plus a fake `mdutil` whose `-s` reports `status`, so the
    /// test never touches real Spotlight settings.
    private func run(status: String) async throws -> (result: (text: String, status: Int32), stick: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cdj400-test-\(UUID().uuidString)")
        let bin = dir.appendingPathComponent("bin"), usb = dir.appendingPathComponent("Josh's USB")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: usb, withIntermediateDirectories: true)
        try Data().write(to: usb.appendingPathComponent("._.metadata_never_index"))
        let fake = bin.appendingPathComponent("mdutil")
        try "#!/bin/sh\n[ \"$1\" = -s ] && printf '%s:\\n\\t%s\\n' \"$2\" '\(status)'\nexit 0\n"
            .write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let command = StickCommands.disableSpotlight(stick: stick(path: usb.path, name: "Josh's USB"))
        return (await zsh("PATH=\(StickCommands.quote(bin.path)):$PATH; \(command)"), usb)
    }

    @Test func reportsOffOnlyWhenMdutilConfirmsIt() async throws {
        let (result, usb) = try await run(status: "Indexing disabled.")
        defer { try? FileManager.default.removeItem(at: usb.deletingLastPathComponent()) }
        #expect(result.status == 0)
        #expect(result.text == "Spotlight indexing is off for Josh's USB\n")
        #expect(FileManager.default.fileExists(atPath: usb.appendingPathComponent(".metadata_never_index").path))
        #expect(!FileManager.default.fileExists(atPath: usb.appendingPathComponent("._.metadata_never_index").path))
    }

    @Test func failsWhenIndexingIsStillOn() async throws {
        let (result, usb) = try await run(status: "Indexing enabled.")
        defer { try? FileManager.default.removeItem(at: usb.deletingLastPathComponent()) }
        #expect(result.status == 1)
        #expect(result.text.contains("Spotlight is still indexing Josh's USB"))
    }
}

@Suite struct VendoredTools {
    /// The tests run with the default lookup, so point at the repo's copy explicitly.
    private let tools = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("tools")

    @Test(arguments: ["cdj400-addplaylist", "cdj400-adopt", "cdj400-backups", "cdj400-copystick",
                      "cdj400-dbexport", "cdj400-rename", "cdj400-restore", "cdj400-sort"])
    func everyToolTheAppCallsRuns(_ name: String) async {
        let result = await zsh("\(StickCommands.quote(tools.appendingPathComponent(name).path)) --help")
        #expect(result.status == 0, "\(name): \(result.text)")
        #expect(result.text.contains("usage: \(name)"))
    }

    /// Tests/tools/test_tools.py: Make Lean, tidy names, sort, update and
    /// restore against a fake stick and library.
    @Test func pythonEndToEndTests() async {
        let suite = tools.deletingLastPathComponent().appendingPathComponent("Tests/tools").path
        let result = await zsh("python3 -m unittest discover -s \(StickCommands.quote(suite)) 2>&1")
        #expect(result.status == 0, "\(result.text)")
    }
}

@Suite struct TidyNames {
    @Test func makeLeanPassesTheSetting() {
        #expect(StickCommands.makeLean(stick: stick(), execute: true, tidy: true).contains("--tidy-names --execute"))
        #expect(!StickCommands.makeLean(stick: stick(), execute: false, tidy: false).contains("--tidy-names"))
    }

    @Test func renameCommand() {
        #expect(StickCommands.rename(stick: stick(), tidy: true).hasSuffix("'/Volumes/TEST' --tidy --execute"))
        #expect(StickCommands.rename(stick: stick(), tidy: false).hasSuffix("'/Volumes/TEST' --original --execute"))
        #expect(Job.rename(tidy: true).confirmation(on: stick()) == nil)
    }

    @Test func orderFileWithTidySortedNames() {
        let json = #"{"names": "tidy", "by": "bpm", "original": {"001 - A - B.mp3": "messy.mp3"}, "prefixed": ["001 - A - B.mp3"]}"#
        let order = StickScanner.parseOrderFile(Data(json.utf8))
        #expect(order.tidy)
        #expect(order.by == .bpm)
        #expect(order.prefixed == ["001 - A - B"])
        #expect(StickScanner.stripSortPrefix("001 - A - B") == "A - B")
        #expect(StickScanner.stripSortPrefix("A - B") == "A - B")
    }

    @Test func orderFileFromOlderSort() {
        let json = #"{"by": "key", "original": {"002 - x.mp3": "x.mp3"}}"#
        let order = StickScanner.parseOrderFile(Data(json.utf8))
        #expect(!order.tidy)
        #expect(order.by == .key)
        #expect(order.prefixed == ["002 - x"])
    }

    @Test func tidyOnlyFolderHasNoSortOrder() {
        let json = #"{"names": "tidy", "by": null, "original": {"A - B.mp3": "messy.mp3"}, "prefixed": []}"#
        let order = StickScanner.parseOrderFile(Data(json.utf8))
        #expect(order.tidy)
        #expect(order.by == nil)
        #expect(order.prefixed.isEmpty)
    }

    @Test func newPlaylistsFollowTheStick() {
        let tidyStick = Stick(path: "/Volumes/TEST", name: "TEST", mode: .lean,
                              playlists: [Playlist(name: "A", tracks: 1, tidyNames: true)], tracks: 1,
                              sidecars: 0, freeBytes: 0, totalBytes: 0, lastChange: nil)
        #expect(tidyStick.hasTidyNames)
        #expect(tidyStick.addsTidyNames)
        #expect(Job.addPlaylists(["B"], execute: true).command(on: tidyStick).contains("--tidy-names"))
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

@Suite struct BackupListing {
    @Test func parsesEveryStatus() throws {
        let inUse = try #require(Backup(listLine: "DECK-20261127-150000\tDECK\t1795752000\t1048576\tlean\tin-use\tUUID-1"))
        #expect(inUse.stick == "DECK")
        #expect(inUse.kind == .lean)
        #expect(!inUse.canDelete)
        #expect(!inUse.isUnneeded)
        #expect(inUse.made != nil)
        let old = try #require(Backup(listLine: "DECK-20200101-000000\tDECK\t0\t5\tfull\tolder\t"))
        #expect(old.isUnneeded)
        #expect(old.made == nil)
        #expect(Backup(listLine: "x\tDECK\t0\t5\tfull\tmystery\t") == nil)
        #expect(Backup(listLine: "too\tfew") == nil)
    }

    @Test func deleteQuotesEveryName() {
        let command = StickCommands.deleteBackups(["Josh's-20261127-150000", "B-20200101-000000"])
        #expect(command.hasSuffix("--delete 'Josh'\\''s-20261127-150000' 'B-20200101-000000' --execute"))
    }
}
