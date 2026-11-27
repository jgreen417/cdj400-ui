import SwiftUI

/// Everything about the selected stick: what's on it and how full it is,
/// anything that needs attention, its playlists, and what can be done to it.
struct StickDetailView: View {
    let stick: Stick
    /// Not observed here: only the storage bar follows a copy's progress live.
    let runner: CommandRunner
    let isRunning: Bool
    /// A job is running on this stick.
    let isWorkingOnThisStick: Bool
    let changedOutsideApp: Bool
    let copyTargets: [Stick]
    let sync: SyncState?
    let onCheckSync: () -> Void
    let onJob: (Job) -> Void

    @State private var showAddPlaylist = false
    @State private var query = ""
    @AppStorage(AppSettings.tidyNamesKey) private var tidyNames = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                hero
                if changedOutsideApp || !stick.issues.isEmpty { attention }
                switch stick.mode {
                case .lean:
                    playlistSection
                    thisStick
                case .full:
                    getReady
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 26)
            .padding(.bottom, 32)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(stick.name)
        .toolbar(removing: .title)
        .toolbar { toolbar }
        .searchable(text: $query, placement: .toolbar, prompt: "Playlists and tracks")
        .sheet(isPresented: $showAddPlaylist) {
            AddPlaylistSheet(stick: stick) { names, execute in
                onJob(.addPlaylists(names, execute: execute))
            }
        }
        .onChange(of: stick.path) { query = "" }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if stick.mode == .lean {
            ToolbarItem {
                Button("Add Playlist", systemImage: "plus") { showAddPlaylist = true }
                    .labelStyle(.titleAndIcon)
                    .disabled(isRunning)
                    .help("Copy Rekordbox playlists onto this stick, no sync needed")
            }
            ToolbarItem {
                Menu("Sort", systemImage: "arrow.up.arrow.down") {
                    Section("Sort Every Playlist By") {
                        ForEach(SortOrder.allCases) { order in
                            Button("\(order.label): \(order.detail)") {
                                onJob(.sort(stick.playlists.map(\.name), by: order))
                            }
                        }
                    }
                }
                .disabled(isRunning || stick.playlists.isEmpty)
                .help("Order the tracks in every playlist by Rekordbox BPM, key or name")
            }
            if !copyTargets.isEmpty {
                ToolbarItem {
                    Menu("Copy to", systemImage: "doc.on.doc") {
                        Section("Copy Every Playlist To") {
                            ForEach(copyTargets) { target in
                                Button("\(target.name) (\(target.freeDescription) free)") { onJob(.copy(to: target)) }
                            }
                        }
                    }
                    .disabled(isRunning)
                    .help("Copy every playlist on \(stick.name) onto another stick")
                }
            }
        }
        ToolbarItem {
            Button("Eject", systemImage: "eject") { onJob(.eject) }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(isRunning)
                .help("Safely eject \(stick.name) (⌘E)")
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(stick.name)
                        .font(.system(size: 28, weight: .bold))
                        .lineLimit(1)
                    // Drops facts from the end rather than truncating any of them.
                    ViewThatFits(in: .horizontal) {
                        statusLine(facts)
                        statusLine(Array(facts.prefix(1)))
                        statusLine([])
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(stick.freeDescription) free")
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .foregroundStyle(stick.isNearlyFull ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                    Text("of \(stick.totalDescription)")
                        .foregroundStyle(.secondary)
                }
                .monospacedDigit()
            }
            ArrivingStorageBar(runner: runner, segments: segments, totalBytes: stick.totalBytes,
                               showsArriving: isWorkingOnThisStick)
        }
    }

    private func statusLine(_ shown: [String]) -> some View {
        HStack(spacing: 14) {
            Label(stick.mode.label, systemImage: stick.mode.symbol)
                .foregroundStyle(stick.mode.tint)
                .fontWeight(.semibold)
            ForEach(shown, id: \.self) { Text($0) }
        }
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
    }

    /// The short facts after the mode in the hero line.
    private var facts: [String] {
        switch stick.mode {
        case .lean:
            var found = [stick.playlists.isEmpty
                         ? "No playlists yet"
                         : "\(count(stick.playlists.count, "playlist")), \(count(stick.tracks, "track"))"]
            if stick.hasTidyNames { found.append("Artist - Title names") }
            return found
        case .full:
            return ["\(count(stick.tracks, "track")) in the Rekordbox export"]
        }
    }

    private func count(_ n: Int, _ noun: String) -> String {
        "\(n.formatted()) \(noun)\(n == 1 ? "" : "s")"
    }

    private var segments: [StorageBar.Segment] {
        var found: [StorageBar.Segment] = []
        switch stick.mode {
        case .lean:
            for (index, playlist) in stick.playlists.enumerated() where playlist.bytes > 0 {
                found.append(.init(id: playlist.name, label: playlist.name, bytes: playlist.bytes,
                                   color: .playlist(index)))
            }
        case .full:
            let export = stick.exportBytes > 0 ? stick.exportBytes : stick.usedBytes
            found.append(.init(id: "export", label: "Rekordbox export", bytes: export, color: .blue))
        }
        // Anything else on the stick: Rekordbox's database, other files, FAT overhead.
        let other = stick.usedBytes - found.reduce(0) { $0 + $1.bytes }
        if Double(other) > Double(stick.totalBytes) * 0.01 {
            found.append(.init(id: "other", label: "Other files", bytes: other, color: .gray))
        }
        return found
    }

    // MARK: - Needs attention

    private var attention: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Needs attention")
            Card {
                if changedOutsideApp {
                    attentionRow(title: "Changed in the last 90 seconds",
                                 detail: "If Rekordbox is syncing this stick, let that finish first.",
                                 fix: nil)
                    if !stick.issues.isEmpty { CardDivider() }
                }
                ForEach(Array(stick.issues.enumerated()), id: \.element.id) { index, issue in
                    if index > 0 { CardDivider() }
                    attentionRow(title: issue.title, detail: issue.detail, fix: issue.fix)
                }
            }
        }
    }

    private func attentionRow(title: String, detail: String, fix: Job?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .accessibilityHidden(true)
            RowLabel(title: title, detail: detail)
            Spacer(minLength: 12)
            if let fix {
                Button(fix.fixTitle) { onJob(fix) }
                    .disabled(isRunning)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Playlists

    private struct PlaylistMatch: Identifiable {
        let playlist: Playlist
        let color: Color
        let tracks: [String]
        var id: String { playlist.id }
    }

    private var matches: [PlaylistMatch] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return stick.playlists.enumerated().compactMap { index, pl in
            guard !q.isEmpty else { return PlaylistMatch(playlist: pl, color: .playlist(index), tracks: []) }
            let tracks = pl.trackNames.filter { $0.localizedCaseInsensitiveContains(q) }
            guard pl.name.localizedCaseInsensitiveContains(q) || !tracks.isEmpty else { return nil }
            return PlaylistMatch(playlist: pl, color: .playlist(index), tracks: tracks)
        }
    }

    private var checkedSync: [String: PlaylistSync]? {
        if case .checked(let rows) = sync { return rows }
        return nil
    }

    private var stale: [PlaylistSync] {
        (checkedSync?.values.filter(\.needsUpdate) ?? []).sorted { $0.folder < $1.folder }
    }

    @ViewBuilder
    private var playlistSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Playlists") { syncStatus }
            if stick.playlists.isEmpty {
                Card {
                    HStack(spacing: 12) {
                        Image(systemName: "music.note.list")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        RowLabel(title: "No playlists on \(stick.name) yet",
                                 detail: "Add Rekordbox playlists and their MP3s are copied straight on, no sync needed.")
                        Spacer(minLength: 12)
                        Button("Add Playlist…") { showAddPlaylist = true }
                            .disabled(isRunning)
                    }
                    .padding(14)
                }
            } else {
                let found = matches
                Card {
                    ForEach(Array(found.enumerated()), id: \.element.id) { index, match in
                        if index > 0 { CardDivider() }
                        PlaylistRow(playlist: match.playlist, color: match.color,
                                    matchingTracks: match.tracks,
                                    sync: checkedSync?[match.playlist.name],
                                    canEdit: !isRunning,
                                    onUpdate: { onJob(.update([$0])) },
                                    onSort: { onJob(.sort([match.playlist.name], by: $0)) },
                                    onRemove: { onJob(.removePlaylist(match.playlist.name)) })
                    }
                    if found.isEmpty {
                        Text("Nothing on \(stick.name) matches “\(query)”.")
                            .foregroundStyle(.secondary)
                            .padding(14)
                    }
                }
            }
        }
    }

    /// Whether the playlists still match Rekordbox, next to the section title.
    @ViewBuilder
    private var syncStatus: some View {
        if !stick.playlists.isEmpty {
            HStack(spacing: 12) {
                switch sync {
                case .checking:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Comparing with Rekordbox…")
                    }
                    .foregroundStyle(.secondary)
                case .failed(let message):
                    Label("Couldn’t compare with Rekordbox", systemImage: "xmark.octagon.fill")
                        .symbolRenderingMode(.multicolor)
                        .foregroundStyle(.secondary)
                        .help(message)
                case .checked:
                    if stale.isEmpty {
                        Label("All match Rekordbox", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        HStack(spacing: 6) {
                            Circle().fill(.orange).frame(width: 7, height: 7)
                            Text("\(stale.count) changed in Rekordbox")
                        }
                        .foregroundStyle(.secondary)
                        if stale.count > 1 {
                            Button("Update All") { onJob(.update(stale)) }
                                .buttonStyle(.link)
                                .disabled(isRunning)
                        }
                    }
                case nil:
                    EmptyView()
                }
                Button(checkedSync == nil ? "Compare with Rekordbox" : "Check again", action: onCheckSync)
                    .buttonStyle(.link)
                    .disabled(isChecking)
            }
        }
    }

    private var isChecking: Bool {
        if case .checking = sync { return true }
        return false
    }

    // MARK: - This stick (lean)

    private var thisStick: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("This stick")
            Card {
                if !stick.playlists.isEmpty {
                    HStack(spacing: 16) {
                        RowLabel(title: "File names", detail: fileNamesDetail)
                        Spacer(minLength: 12)
                        Picker("File names", selection: Binding(
                            get: { stick.hasTidyNames },
                            set: { tidy in if tidy != stick.hasTidyNames { onJob(.rename(tidy: tidy)) } }
                        )) {
                            Text("Artist - Title").tag(true)
                            Text("Original").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .disabled(isRunning)
                        .help("Renames the files on the stick. Your Mac files keep their names.")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    CardDivider()
                }
                HStack(spacing: 16) {
                    RowLabel(title: "Restore to Rekordbox", detail: restoreDetail)
                    Spacer(minLength: 12)
                    Button("Restore…") { onJob(.action(.restore)) }
                        .disabled(isRunning)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    private var fileNamesDetail: String {
        if stick.hasTidyNames, let example = stick.nameExample {
            return "\(example.mac) shows on the deck as \(example.shown)"
        }
        return stick.hasTidyNames
            ? "Named from Rekordbox's artist and title, so they're easy to read on the deck"
            : "The names the files have on your Mac"
    }

    private var restoreDetail: String {
        if let date = stick.restoreBackupDate {
            return "Puts back the export from the backup made \(date.shortStamp)"
        }
        return "Uses the backup made when this stick went lean. Without one, you'd re-sync it in Rekordbox."
    }

    // MARK: - Get ready (Rekordbox mode)

    private var getReady: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Get it ready for the CDJ-400")
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Make Lean turns the playlists synced to this stick into plain folders the CDJ-400 browses fast, then removes Rekordbox's database. It backs everything up to your Mac first, so you can restore it later.")
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                        .frame(maxWidth: 620, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle(isOn: $tidyNames) {
                        RowLabel(title: "Name files “Artist - Title”",
                                 detail: "From Rekordbox's artist and title, so they're readable on the deck's screen. Your Mac files keep their names.")
                    }
                    .toggleStyle(.switch)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    HStack(spacing: 10) {
                        if !stick.canGoLean {
                            Text("This stick has no tracks to make lean.")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Preview") { onJob(.action(.dryRun)) }
                            .keyboardShortcut("d", modifiers: .command)
                            .help("See what Make Lean would do, without changing anything (⌘D)")
                        Button("Make Lean…") { onJob(.action(.makeLean)) }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut("l", modifiers: [.command, .shift])
                            .disabled(!stick.canGoLean)
                    }
                    .disabled(isRunning)
                }
                .padding(16)
            }
        }
    }
}

extension Job {
    /// The label on a "Needs attention" row's fix button.
    var fixTitle: String {
        switch self {
        case .removeSidecars: "Remove"
        case .disableSpotlight: "Turn Off"
        default: "Fix"
        }
    }
}

/// The hero's storage bar. Observes the runner so only the bar redraws as a
/// copy onto this stick progresses: the incoming bytes show as a striped segment.
private struct ArrivingStorageBar: View {
    @ObservedObject var runner: CommandRunner
    let segments: [StorageBar.Segment]
    let totalBytes: Int64
    let showsArriving: Bool

    var body: some View {
        StorageBar(segments: allSegments, totalBytes: totalBytes)
    }

    private var allSegments: [StorageBar.Segment] {
        guard showsArriving, let progress = runner.progress, progress.total > 0 else { return segments }
        // The stick was last scanned before the job started, so the whole
        // transfer is still to come out of its free space.
        return segments + [.init(id: "arriving", label: "Being copied", bytes: progress.total,
                                 color: .green, arriving: true)]
    }
}

private struct PlaylistRow: View {
    let playlist: Playlist
    let color: Color
    let matchingTracks: [String]
    let sync: PlaylistSync?
    let canEdit: Bool
    let onUpdate: (PlaylistSync) -> Void
    let onSort: (SortOrder) -> Void
    let onRemove: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(color)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            RowLabel(title: playlist.name, detail: detail.text, detailColor: detail.color)
                .lineLimit(1)
            Spacer(minLength: 12)
            if let sync, sync.needsUpdate {
                Button("Update") { onUpdate(sync) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!canEdit)
                    .help("Copy what changed in Rekordbox onto the stick")
            }
            Button("Remove \(playlist.name)", systemImage: "minus.circle.fill", action: onRemove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .opacity(canEdit && hovering ? 1 : 0)
                .disabled(!canEdit)
                .help("Remove \(playlist.name) from this stick")
            Text("\(playlist.tracks) tracks")
                .foregroundStyle(.secondary)
            Text(playlist.bytes.fileSize)
                .foregroundStyle(.tertiary)
                .frame(width: 70, alignment: .trailing)
        }
        .monospacedDigit()
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            if canEdit {
                if let sync, sync.needsUpdate {
                    Button("Update from Rekordbox") { onUpdate(sync) }
                }
                Menu("Sort Tracks By") {
                    ForEach(SortOrder.allCases) { order in
                        Button("\(order.label): \(order.detail)") { onSort(order) }
                    }
                }
                Divider()
                Button("Remove from Stick…", role: .destructive, action: onRemove)
            }
        }
    }

    /// The line under the name: search matches, then what changed in
    /// Rekordbox, then how it's sorted.
    private var detail: (text: String?, color: Color) {
        if !matchingTracks.isEmpty {
            let shown = matchingTracks.prefix(3).joined(separator: ", ")
            let more = matchingTracks.count > 3 ? " and \(matchingTracks.count - 3) more" : ""
            return (shown + more, .accentColor)
        }
        if let sync, sync.needsUpdate {
            var parts: [String] = []
            if sync.toCopy > 0 { parts.append("\(sync.toCopy) new") }
            if sync.toRemove > 0 { parts.append("\(sync.toRemove) removed") }
            return (parts.joined(separator: ", ") + " in Rekordbox", .orange)
        }
        if let order = playlist.sortedBy { return ("Sorted by \(order.label)", .secondary) }
        if let sync, sync.isCurrent { return ("Matches Rekordbox", .secondary) }
        return (nil, .secondary)
    }
}
