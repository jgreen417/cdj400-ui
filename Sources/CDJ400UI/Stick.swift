import SwiftUI

enum StickMode: Sendable {
    /// Only Playlists/: the plain-folder layout a CDJ-400 browses fastest.
    case lean
    /// Rekordbox's own export layout (PIONEER/ and/or Contents/).
    case full

    var label: String {
        switch self {
        case .lean: "CDJ-400 clean"
        case .full: "Rekordbox / full mode"
        }
    }
}

/// One folder under a lean stick's Playlists/.
struct Playlist: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let tracks: Int
    var trackNames: [String] = []
    var sortedBy: SortOrder?
}

/// How cdj400-sort ordered a playlist folder.
enum SortOrder: String, CaseIterable, Identifiable, Hashable, Sendable {
    case bpm, key, name

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bpm: "BPM"
        case .key: "Key"
        case .name: "Name"
        }
    }

    var detail: String {
        switch self {
        case .bpm: "Slowest first"
        case .key: "Camelot wheel, slowest first in each key"
        case .name: "A to Z, removes the number prefixes"
        }
    }
}

/// Something about a stick that can stop a CDJ-400 reading it cleanly.
enum StickIssue: Hashable, Identifiable, Sendable {
    case sidecars(Int)
    case unplayable(Int)
    case nearlyFull
    case spotlightIndex
    case notFAT(String)

    var id: String { title }

    var title: String {
        switch self {
        case .sidecars(let n): "\(n) ._ sidecar file\(n == 1 ? "" : "s")"
        case .unplayable(let n): "\(n) track\(n == 1 ? "" : "s") the CDJ-400 can't play"
        case .nearlyFull: "Almost full"
        case .spotlightIndex: "Spotlight is indexing this stick"
        case .notFAT(let fs): "Not FAT32 (\(fs))"
        }
    }

    /// The job that clears this issue, when the app can fix it itself.
    var fix: Job? {
        switch self {
        case .sidecars: .removeSidecars
        case .spotlightIndex: .disableSpotlight
        case .unplayable, .nearlyFull, .notFAT: nil
        }
    }

    var detail: String {
        switch self {
        case .sidecars:
            "macOS metadata files that can confuse the deck."
        case .unplayable:
            "Files in Playlists/ that aren't MP3. The CDJ-400 skips them."
        case .nearlyFull:
            "Less than 10% free. Remove a playlist or use a bigger stick."
        case .spotlightIndex:
            "Spotlight keeps writing to this stick and regrows sidecars. Turning it off asks for your Mac password."
        case .notFAT:
            "The CDJ-400 only reads FAT32 sticks. Reformat it as MS-DOS (FAT) in Disk Utility."
        }
    }
}

struct Stick: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    let name: String
    let mode: StickMode
    let playlists: [Playlist]
    let tracks: Int
    let sidecars: Int
    let freeBytes: Int64
    let totalBytes: Int64
    let lastChange: Date?
    var fileSystem = "msdos"
    var unplayable = 0
    var spotlightIndexing = false

    var usedBytes: Int64 { totalBytes - freeBytes }

    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes)
    }

    /// Something wrote to this volume in the last 90 seconds. AppModel.changedOutsideApp
    /// decides whether that was Rekordbox or this app's own job.
    var isRecentlyChanged: Bool {
        guard let lastChange else { return false }
        return Date().timeIntervalSince(lastChange) < 90
    }

    var canGoLean: Bool { mode == .full && tracks > 0 }

    var issues: [StickIssue] {
        var found: [StickIssue] = []
        if fileSystem != "msdos" { found.append(.notFAT(fileSystem)) }
        if sidecars > 0 { found.append(.sidecars(sidecars)) }
        if unplayable > 0 { found.append(.unplayable(unplayable)) }
        if usedFraction >= 0.9 { found.append(.nearlyFull) }
        if spotlightIndexing { found.append(.spotlightIndex) }
        return found
    }

    var freeDescription: String { freeBytes.fileSize }
    var usedDescription: String { usedBytes.fileSize }
    var totalDescription: String { totalBytes.fileSize }
}

/// How one playlist folder on a lean stick compares with Rekordbox.
struct PlaylistSync: Hashable, Sendable {
    let folder: String
    /// The Rekordbox playlist the folder belongs to; nil when Rekordbox has none.
    let playlist: String?
    let toCopy: Int
    let toRemove: Int

    var isCurrent: Bool { playlist != nil && toCopy == 0 && toRemove == 0 }
    var needsUpdate: Bool { playlist != nil && !isCurrent }

    var summary: String {
        guard playlist != nil else { return "Not in Rekordbox" }
        if isCurrent { return "Up to date" }
        var parts: [String] = []
        if toCopy > 0 { parts.append("\(toCopy) new") }
        if toRemove > 0 { parts.append("\(toRemove) removed") }
        return parts.joined(separator: " · ")
    }

    /// Parses one `cdj400-addplaylist --status` line:
    /// folder, playlist, to copy, to remove, bytes (tab-separated).
    init?(statusLine line: Substring) {
        let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard cols.count == 5, let copy = Int(cols[2]), let remove = Int(cols[3]),
              Int64(cols[4]) != nil else { return nil }
        folder = String(cols[0])
        playlist = cols[1].isEmpty ? nil : String(cols[1])
        toCopy = max(copy, 0)
        toRemove = max(remove, 0)
    }
}

enum SyncState {
    case checking
    case checked([String: PlaylistSync])
    case failed(String)
}

enum StickAction: String, Identifiable, CaseIterable {
    case dryRun
    case makeLean
    case restore

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dryRun: "Dry Run"
        case .makeLean: "Make Lean"
        case .restore: "Restore to Rekordbox"
        }
    }

    var symbol: String {
        switch self {
        case .dryRun: "doc.text.magnifyingglass"
        case .makeLean: "arrow.down.to.line"
        case .restore: "arrow.uturn.backward"
        }
    }

    var isDestructive: Bool { self != .dryRun }

    var keyboardShortcut: KeyboardShortcut? {
        switch self {
        case .dryRun: KeyboardShortcut("d", modifiers: .command)
        case .makeLean: KeyboardShortcut("l", modifiers: [.command, .shift])
        case .restore: nil
        }
    }

    /// Text for the confirmation dialog, or nil when the action is read-only.
    func confirmation(name: String) -> String? {
        switch self {
        case .dryRun:
            nil
        case .makeLean:
            "\(name): rebuilds Playlists/ from the playlists synced to this stick, then deletes PIONEER/ and Contents/ once every file verifies. Make sure Rekordbox is not syncing this stick."
        case .restore:
            "\(name): returns the stick to Rekordbox mode. Without a backup this means re-syncing it in Rekordbox's Sync Manager."
        }
    }
}

extension Int64 {
    /// "1.4 GB", the way Finder writes file sizes.
    var fileSize: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
