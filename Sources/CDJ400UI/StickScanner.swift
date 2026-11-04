import Foundation

/// Finds Rekordbox sticks under /Volumes and reads what's on them.
/// Blocking file IO: call it off the main thread.
enum StickScanner {
    static func scan() -> [Stick] {
        if ProcessInfo.processInfo.environment["CDJ_DEMO"] != nil { return demoSticks }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/Volumes") else { return [] }

        return names.sorted().compactMap { name in
            let root = URL(fileURLWithPath: "/Volumes/\(name)")
            let values = try? root.resourceValues(forKeys: [.volumeIsLocalKey])
            guard values?.volumeIsLocal ?? false else { return nil }
            return stick(at: root, name: name)
        }
    }

    private static func stick(at root: URL, name: String) -> Stick? {
        let fm = FileManager.default
        let contents = root.appendingPathComponent("Contents")
        let playlists = root.appendingPathComponent("Playlists")
        let hasContents = fm.fileExists(atPath: contents.path)
        let hasPlaylists = fm.fileExists(atPath: playlists.path)
        let hasPioneer = fm.fileExists(atPath: root.appendingPathComponent("PIONEER").path)

        // Only surfaces volumes that look like rekordbox media.
        guard hasContents || hasPlaylists || hasPioneer else { return nil }
        let mode: StickMode = hasContents || hasPioneer ? .full : .lean

        let inPlaylists = hasPlaylists ? FileTally(walking: playlists) : nil
        let inContents = mode == .full ? FileTally(walking: contents) : nil
        let folders = inPlaylists.map { folderList(in: playlists, tally: $0) } ?? []
        let volume = volumeInfo(path: root.path)

        return Stick(
            path: root.path,
            name: name,
            mode: mode,
            playlists: folders,
            tracks: mode == .lean ? folders.reduce(0) { $0 + $1.tracks } : inContents?.mp3s ?? 0,
            sidecars: (inPlaylists ?? inContents)?.sidecars ?? 0,
            freeBytes: volume.free,
            totalBytes: volume.total,
            lastChange: newestModification(in: root),
            fileSystem: volume.fileSystem,
            unplayable: inPlaylists?.otherAudio ?? 0,
            spotlightIndexing: isSpotlightIndexing(path: root.path)
        )
    }

    /// One walk of a folder tree, counting what the stick's health checks need.
    private struct FileTally {
        private static let otherAudio: Set<String> = ["m4a", "aac", "flac", "wav", "aif", "aiff", "alac", "ogg", "opus"]

        var mp3s = 0
        var otherAudio = 0
        var sidecars = 0
        /// MP3 names without extension, keyed by the top-level folder they're in.
        var tracksByFolder: [String: [String]] = [:]

        init(walking directory: URL) {
            guard let walker = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: nil) else { return }
            let depth = directory.pathComponents.count
            for case let url as URL in walker {
                if url.lastPathComponent.hasPrefix("._") {
                    sidecars += 1
                    continue
                }
                let ext = url.pathExtension.lowercased()
                if ext == "mp3" {
                    mp3s += 1
                    let parts = url.pathComponents
                    if parts.count > depth + 1 {
                        tracksByFolder[parts[depth], default: []].append(url.deletingPathExtension().lastPathComponent)
                    }
                } else if Self.otherAudio.contains(ext) {
                    otherAudio += 1
                }
            }
        }
    }

    private static func folderList(in playlists: URL, tally: FileTally) -> [Playlist] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: playlists.path) else { return [] }
        return names.sorted().compactMap { name in
            let directory = playlists.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            let order = sortOrder(in: directory)
            let tracks = (tally.tracksByFolder[name] ?? []).sorted().map { order.original[$0] ?? $0 }
            return Playlist(name: name, tracks: tracks.count, trackNames: tracks, sortedBy: order.by)
        }
    }

    /// These FAT volumes report 0 for every URLResourceValues capacity, so ask
    /// the filesystem directly via statfs; these are the numbers `df` prints.
    private static func volumeInfo(path: String) -> (free: Int64, total: Int64, fileSystem: String) {
        var stats = statfs()
        guard statfs(path, &stats) == 0 else { return (0, 0, "msdos") }
        let fileSystem = withUnsafeBytes(of: stats.f_fstypename) {
            String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
        }
        return (Int64(stats.f_bavail) * Int64(stats.f_bsize),
                Int64(stats.f_blocks) * Int64(stats.f_bsize),
                fileSystem)
    }

    /// What cdj400-sort left in `.cdj400-order.json`: the order and each
    /// prefixed file's original name (both without the .mp3 extension).
    private static func sortOrder(in directory: URL) -> (by: SortOrder?, original: [String: String]) {
        struct File: Decodable {
            let by: String
            let original: [String: String]
        }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(".cdj400-order.json")),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return (nil, [:]) }
        let stem = { (name: String) in (name as NSString).deletingPathExtension }
        return (SortOrder(rawValue: file.by),
                Dictionary(file.original.map { (stem($0.key), stem($0.value)) }, uniquingKeysWith: { a, _ in a }))
    }

    /// Asks Spotlight itself, as `cdj400-usb --check` does. A leftover
    /// .Spotlight-V100 folder is harmless once indexing is off, and macOS
    /// protects it from deletion, so the folder is not the signal.
    private static func isSpotlightIndexing(path: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/mdutil")
        task.arguments = ["-s", path]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(decoding: data, as: UTF8.self).contains("Indexing enabled")
    }

    /// Newest modification date among the volume's top-level entries.
    private static func newestModification(in root: URL) -> Date? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return nil }
        return names.compactMap { name in
            try? root.appendingPathComponent(name)
                .resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
        }.max()
    }

    /// Sample sticks for previewing the UI without hardware (`CDJ_DEMO=1`).
    private static let demoSticks: [Stick] = [
        Stick(path: "/Volumes/DECK A", name: "DECK A", mode: .lean,
              playlists: [
                  Playlist(name: "Warmup Grooves", tracks: 42,
                           trackNames: ["Sunrise Dub", "Late Bus Home", "Tidal"]),
                  Playlist(name: "Peak Time Techno", tracks: 118,
                           trackNames: ["Pressure Drop", "Warehouse 9", "Sunrise Edit"],
                           sortedBy: .bpm),
                  Playlist(name: "Disco Edits", tracks: 67,
                           trackNames: ["Mirrorball", "Night Shift"]),
                  Playlist(name: "Closing Set", tracks: 23,
                           trackNames: ["Last Call", "Lights Up"]),
                  Playlist(name: "Acapellas & Tools", tracks: 15,
                           trackNames: ["Vox Loop 1", "Kick Tool"]),
              ],
              tracks: 265, sidecars: 0,
              freeBytes: 9_400_000_000, totalBytes: 31_900_000_000, lastChange: nil),
        Stick(path: "/Volumes/DECK B", name: "DECK B", mode: .full,
              playlists: [], tracks: 812, sidecars: 14,
              freeBytes: 1_400_000_000, totalBytes: 15_900_000_000, lastChange: Date(),
              spotlightIndexing: true),
        Stick(path: "/Volumes/SPARE", name: "SPARE", mode: .lean,
              playlists: [], tracks: 0, sidecars: 0,
              freeBytes: 7_700_000_000, totalBytes: 7_900_000_000, lastChange: nil),
    ]
}
