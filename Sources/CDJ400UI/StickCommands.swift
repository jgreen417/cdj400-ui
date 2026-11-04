import Foundation

/// Builds the shell commands this app runs. All real work lives in the
/// cdj400-* tools (`tools/` in the repo); the app is a front-end, not a second
/// implementation.
enum StickCommands {
    /// Where the tools live: `$CDJ400_TOOLS`, else the copy build.sh bundles
    /// into the app, else ~/bin.
    static let toolsDirectory: String = {
        if let dir = ProcessInfo.processInfo.environment["CDJ400_TOOLS"], !dir.isEmpty { return dir }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("tools"),
           FileManager.default.fileExists(atPath: bundled.path) { return bundled.path }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("bin").path
    }()

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func tool(_ name: String) -> String { quote(toolsDirectory + "/" + name) }

    /// A device-scoped XML regenerated from the live rekordbox library every
    /// run, so the folder set always matches this stick's own manifest.
    static func xmlPath(for stick: Stick) -> String {
        AppSupport.directory.appendingPathComponent("\(stick.name)-device.xml").path
    }

    private static func export(stick: Stick) -> String {
        "\(tool("cdj400-dbexport")) --device \(quote(stick.path)) -o \(quote(xmlPath(for: stick)))"
    }

    /// Exports this stick's Rekordbox manifest, then rebuilds Playlists/ from
    /// it; without `execute` the adopt step only previews.
    static func makeLean(stick: Stick, execute: Bool) -> String {
        let adopt = "\(tool("cdj400-adopt")) \(quote(xmlPath(for: stick))) \(quote(stick.path))"
        return export(stick: stick) + " && " + (execute ? adopt + " --execute" : adopt)
    }

    static func restore(stick: Stick) -> String {
        "\(tool("cdj400-restore")) \(quote(stick.path))"
    }

    static func addPlaylist(stick: Stick, name: String, execute: Bool) -> String {
        let base = "\(tool("cdj400-addplaylist")) \(quote(stick.path)) \(quote(name))"
        return execute ? base + " --execute" : base
    }

    static func syncStatus(path: String) -> String {
        "\(tool("cdj400-addplaylist")) \(quote(path)) --status"
    }

    static func updatePlaylist(stick: Stick, _ sync: PlaylistSync) -> String {
        let base = "\(tool("cdj400-addplaylist")) \(quote(stick.path)) \(quote(sync.playlist ?? sync.folder)) --execute"
        return sync.toRemove > 0 ? base + " --prune" : base
    }

    static func sort(stick: Stick, folders: [String], by order: SortOrder) -> String {
        let flags = folders.map { "--folder \(quote($0))" }.joined(separator: " ")
        return "\(tool("cdj400-sort")) \(quote(stick.path)) --by \(order.rawValue) \(flags) --execute"
    }

    static func removeSidecars(stick: Stick) -> String {
        "set -o pipefail; count=$(find \(quote(stick.path)) -name '._*' -type f -print -delete | wc -l | tr -d ' ')"
            + " && echo \"removed $count sidecar files from \"\(quote(stick.name))"
    }

    /// Spotlight settings need admin rights, so macOS asks for your password.
    static func disableSpotlight(stick: Stick) -> String {
        let script = """
            on run argv
            do shell script "mdutil -i off " & quoted form of (item 1 of argv) & " && (mdutil -X " & quoted form of (item 1 of argv) & " >/dev/null 2>&1 || true)" with administrator privileges
            end run
            """
        return "osascript -e \(quote(script)) \(quote(stick.path)) && echo \(quote("Spotlight indexing is off for \(stick.name)"))"
    }

    static func listAddablePlaylists(stick: Stick) -> String {
        "\(tool("cdj400-addplaylist")) \(quote(stick.path)) --list"
    }

    static func copyStick(from source: Stick, to target: Stick) -> String {
        "\(tool("cdj400-copystick")) \(quote(source.path)) \(quote(target.path)) --execute"
    }

    static func removePlaylist(stick: Stick, name: String) -> String {
        let folder = stick.path + "/Playlists/" + name
        let sidecar = stick.path + "/Playlists/._" + name
        return "rm -rf -- \(quote(folder)) && rm -f -- \(quote(sidecar)) && echo \(quote("removed Playlists/\(name)/ from \(stick.name)"))"
    }

    static func eject(stick: Stick) -> String {
        "diskutil eject \(quote(stick.path))"
    }
}

/// Everything the app can run against a stick.
enum Job: Hashable {
    case action(StickAction)
    case addPlaylists([String], execute: Bool)
    case update([PlaylistSync])
    case sort([String], by: SortOrder)
    case removeSidecars
    case disableSpotlight
    case removePlaylist(String)
    case copy(to: Stick)
    case eject

    var title: String {
        switch self {
        case .action(let action): action.title
        case .addPlaylists(let names, let execute):
            names.count == 1
                ? (execute ? "Add playlist \(names[0])" : "Preview playlist \(names[0])")
                : (execute ? "Add \(names.count) playlists" : "Preview \(names.count) playlists")
        case .update(let syncs): syncs.count == 1 ? "Update \(syncs[0].folder)" : "Update \(syncs.count) playlists"
        case .sort(let folders, let order):
            folders.count == 1 ? "Sort \(folders[0]) by \(order.label)" : "Sort \(folders.count) playlists by \(order.label)"
        case .removeSidecars: "Remove sidecars"
        case .disableSpotlight: "Turn off Spotlight"
        case .removePlaylist(let name): "Remove \(name)"
        case .copy(let target): "Copy to \(target.name)"
        case .eject: "Eject"
        }
    }

    func title(on stick: Stick) -> String { "\(title) — \(stick.name)" }

    var isDestructive: Bool {
        switch self {
        case .action(let action): action.isDestructive
        case .removePlaylist: true
        case .update(let syncs): syncs.contains { $0.toRemove > 0 }
        case .removeSidecars: true
        case .addPlaylists, .copy, .eject, .disableSpotlight, .sort: false
        }
    }

    /// Text for the confirmation dialog, or nil when the job runs straight away.
    func confirmation(on stick: Stick) -> String? {
        switch self {
        case .eject, .addPlaylists, .removeSidecars, .disableSpotlight, .sort:
            return nil
        case .update(let syncs):
            let removing = syncs.reduce(0) { $0 + $1.toRemove }
            guard removing > 0 else { return nil }
            let copying = syncs.reduce(0) { $0 + $1.toCopy }
            return "Copies \(copying) new track\(copying == 1 ? "" : "s") and deletes \(removing) track\(removing == 1 ? "" : "s") from \(stick.name) that are no longer in the Rekordbox playlist. Those files stay on your Mac."
        case .action(let action):
            return action.confirmation(name: stick.name)
        case .removePlaylist(let name):
            let tracks = stick.playlists.first { $0.name == name }?.tracks ?? 0
            return "Deletes Playlists/\(name)/ (\(tracks) tracks) from \(stick.name). The MP3s stay in your Rekordbox library, so you can add it back later."
        case .copy(let target):
            return "Copies \(stick.name)'s \(stick.playlists.count) playlists (\(stick.tracks) tracks) into Playlists/ on \(target.name). Files already there are kept and nothing on \(target.name) is deleted."
        }
    }

    func command(on stick: Stick) -> String {
        switch self {
        case .action(.dryRun):
            StickCommands.makeLean(stick: stick, execute: false)
        case .action(.makeLean):
            StickCommands.makeLean(stick: stick, execute: true)
        case .action(.restore):
            StickCommands.restore(stick: stick)
        case .addPlaylists(let names, let execute):
            names.map { StickCommands.addPlaylist(stick: stick, name: $0, execute: execute) }
                .joined(separator: " && ")
        case .update(let syncs):
            syncs.map { StickCommands.updatePlaylist(stick: stick, $0) }.joined(separator: " && ")
        case .sort(let folders, let order):
            StickCommands.sort(stick: stick, folders: folders, by: order)
        case .removeSidecars:
            StickCommands.removeSidecars(stick: stick)
        case .disableSpotlight:
            StickCommands.disableSpotlight(stick: stick)
        case .removePlaylist(let name):
            StickCommands.removePlaylist(stick: stick, name: name)
        case .copy(let target):
            StickCommands.copyStick(from: stick, to: target)
        case .eject:
            StickCommands.eject(stick: stick)
        }
    }
}
