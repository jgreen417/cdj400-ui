import SwiftUI

/// Everything about the selected stick: health, capacity, playlists and the
/// actions that can run on it.
struct StickDetailView: View {
    let stick: Stick
    /// Not observed here: only the progress section follows the runner live.
    let runner: CommandRunner
    let isRunning: Bool
    let changedOutsideApp: Bool
    let copyTargets: [Stick]
    let sync: SyncState?
    let onCheckSync: () -> Void
    let onJob: (Job) -> Void

    @State private var shownFraction = 0.0
    @State private var showAddPlaylist = false
    @State private var query = ""

    private var capacity: Color { .capacity(stick.usedFraction) }

    var body: some View {
        Form {
            overview
            if changedOutsideApp { warning }
            if !stick.issues.isEmpty { health }
            TransferProgressSection(runner: runner)
            playlistSection
            actionSection
        }
        .formStyle(.grouped)
        .navigationTitle(stick.name)
        .navigationSubtitle(stick.mode.label)
        .searchable(text: $query, placement: .toolbar, prompt: "Playlists and Tracks")
        .toolbar { toolbar }
        .sheet(isPresented: $showAddPlaylist) {
            AddPlaylistSheet(stick: stick) { names, execute in
                onJob(.addPlaylists(names, execute: execute))
            }
        }
        .onChange(of: stick.path) {
            query = ""
            animateCapacity()
        }
        .onChange(of: stick.usedFraction) { animateCapacity() }
        .onAppear { animateCapacity() }
    }

    private func animateCapacity() {
        shownFraction = 0
        withAnimation(.easeOut(duration: 0.7).delay(0.05)) {
            shownFraction = stick.usedFraction
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button("Add Playlist", systemImage: "plus") { showAddPlaylist = true }
                .disabled(stick.mode != .lean || isRunning)
                .help(stick.mode == .lean
                      ? "Copy Rekordbox playlists onto this stick (no sync needed)"
                      : "Only for a lean stick (CDJ-400 clean)")
            if stick.mode == .lean {
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
                .help("Order the tracks in every folder by Rekordbox BPM, key or name")
            }
            if !copyTargets.isEmpty {
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
        ToolbarSpacer(.fixed)
        ToolbarItem {
            if isRunning {
                // ⌘⎋ lives on the output pane's Stop button.
                Button("Stop", systemImage: "stop.fill", role: .destructive) { runner.stop() }
                    .help("Stop the running job")
            } else {
                Button("Eject", systemImage: "eject") { onJob(.eject) }
                    .keyboardShortcut("e", modifiers: .command)
                    .help("Safely eject \(stick.name) (⌘E)")
            }
        }
    }

    // MARK: - Overview

    private var overview: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "externaldrive.fill")
                    .font(.system(.largeTitle))
                    .foregroundStyle(stick.mode.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(stick.name)
                        .font(.title2.bold())
                        .lineLimit(1)
                    Text(stick.path)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(stick.usedDescription) of \(stick.totalDescription) used")
                    Spacer()
                    Text("\(stick.freeDescription) free")
                        .foregroundStyle(.secondary)
                }
                .monospacedDigit()
                Gauge(value: shownFraction) {}
                    .gaugeStyle(.linearCapacity)
                    .tint(capacity)
                    .accessibilityLabel("\(Int((stick.usedFraction * 100).rounded())) percent used")
            }
            .padding(.vertical, 2)

            LabeledContent("Mode") {
                Label(stick.mode.label, systemImage: "circle.fill")
                    .labelStyle(TintedDotLabelStyle(tint: stick.mode.tint))
            }
            LabeledContent("Playlists", value: stick.playlists.count, format: .number)
            LabeledContent("Tracks", value: stick.tracks, format: .number)
            LabeledContent("Sidecar Files") {
                Text(stick.sidecars, format: .number)
                    .foregroundStyle(stick.sidecars > 0 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
        }
    }

    // MARK: - Health

    private var warning: some View {
        Section {
            Label("This stick changed in the last 90 seconds. If Rekordbox is syncing it, let that finish first.",
                  systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
        }
    }

    private var health: some View {
        Section("Needs Attention") {
            ForEach(stick.issues) { issue in
                LabeledContent {
                    if let fix = issue.fix {
                        Button("Fix") { onJob(fix) }
                            .disabled(isRunning)
                            .help(fix.title)
                    }
                } label: {
                    Label {
                        Text(issue.title)
                        Text(issue.detail)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                    }
                }
            }
        }
    }

    // MARK: - Playlists

    private struct PlaylistMatch: Identifiable {
        let playlist: Playlist
        let tracks: [String]
        var id: String { playlist.id }
    }

    private var matches: [PlaylistMatch] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return stick.playlists.map { PlaylistMatch(playlist: $0, tracks: []) } }
        return stick.playlists.compactMap { pl in
            let tracks = pl.trackNames.filter { $0.localizedCaseInsensitiveContains(q) }
            guard pl.name.localizedCaseInsensitiveContains(q) || !tracks.isEmpty else { return nil }
            return PlaylistMatch(playlist: pl, tracks: tracks)
        }
    }

    @ViewBuilder
    private var playlistSection: some View {
        if !stick.playlists.isEmpty {
            let found = matches
            Section("Playlists") {
                if stick.mode == .lean { syncRow }
                ForEach(found) { match in
                    PlaylistRow(playlist: match.playlist, matchingTracks: match.tracks,
                                sync: checkedSync?[match.playlist.name],
                                canEdit: stick.mode == .lean && !isRunning,
                                onUpdate: { sync in onJob(.update([sync])) },
                                onSort: { order in onJob(.sort([match.playlist.name], by: order)) },
                                onRemove: { onJob(.removePlaylist(match.playlist.name)) })
                }
                if found.isEmpty {
                    Text("Nothing on \(stick.name) matches “\(query)”.")
                        .foregroundStyle(.secondary)
                }
            }
        } else if stick.mode == .full {
            Section("Playlists") {
                Text("Run Dry Run to see which playlists are synced to this stick.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var checkedSync: [String: PlaylistSync]? {
        if case .checked(let rows) = sync { return rows }
        return nil
    }

    private var isChecking: Bool {
        if case .checking = sync { return true }
        return false
    }

    private var syncRow: some View {
        let stale = (checkedSync?.values.filter(\.needsUpdate) ?? []).sorted { $0.folder < $1.folder }
        return LabeledContent {
            HStack {
                if stale.count > 1 {
                    Button("Update All") { onJob(.update(stale)) }
                        .disabled(isRunning)
                }
                Button(checkedSync == nil ? "Check" : "Recheck", action: onCheckSync)
                    .disabled(isChecking)
            }
        } label: {
            switch sync {
            case .checking:
                Label {
                    Text("Comparing with Rekordbox…")
                } icon: {
                    ProgressView().controlSize(.small)
                }
            case .failed(let message):
                Label("Couldn’t compare with Rekordbox", systemImage: "xmark.octagon.fill")
                    .symbolRenderingMode(.multicolor)
                    .help(message)
            case .checked:
                if stale.isEmpty {
                    Label("Every playlist matches Rekordbox", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("\(stale.count) playlist\(stale.count == 1 ? "" : "s") changed in Rekordbox",
                          systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.orange)
                }
            case nil:
                Label("Check whether these playlists still match Rekordbox", systemImage: "arrow.triangle.2.circlepath")
            }
        }
    }

    // MARK: - Actions

    private var actionSection: some View {
        Section("Stick Layout") {
            ForEach(StickAction.allCases) { action in
                LabeledContent {
                    Button(buttonTitle(action), role: action == .makeLean ? .destructive : nil) {
                        onJob(.action(action))
                    }
                    .disabled((action == .makeLean && !stick.canGoLean) || isRunning)
                    .keyboardShortcut(action.keyboardShortcut)
                } label: {
                    Label {
                        Text(action.title)
                        Text(actionHelp(action))
                    } icon: {
                        Image(systemName: action.symbol)
                    }
                }
            }
        }
    }

    private func buttonTitle(_ action: StickAction) -> String {
        switch action {
        case .dryRun: "Preview"
        case .makeLean: "Make Lean…"
        case .restore: "Restore…"
        }
    }

    private func actionHelp(_ action: StickAction) -> String {
        switch action {
        case .dryRun:
            "Preview what Make Lean would do (read-only)"
        case .makeLean:
            stick.canGoLean
                ? "Rebuild Playlists from this stick's rekordbox export, then strip PIONEER/Contents/"
                : "Only possible on a stick currently in Rekordbox export mode"
        case .restore:
            "Re-sync this stick in Rekordbox Sync Manager (or restore from a backup)"
        }
    }
}

/// A small colored dot before the label's title.
private struct TintedDotLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
                .font(.system(size: 7))
                .foregroundStyle(tint)
            configuration.title
        }
    }
}

private struct PlaylistRow: View {
    let playlist: Playlist
    let matchingTracks: [String]
    let sync: PlaylistSync?
    let canEdit: Bool
    let onUpdate: (PlaylistSync) -> Void
    let onSort: (SortOrder) -> Void
    let onRemove: () -> Void

    @State private var hovering = false

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                if let sync { syncBadge(sync) }
                Text("\(playlist.tracks) tracks")
                    .monospacedDigit()
                Button("Remove \(playlist.name)", systemImage: "minus.circle.fill", action: onRemove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .opacity(canEdit && hovering ? 1 : 0)
                    .disabled(!canEdit)
                    .help("Remove \(playlist.name) from this stick")
            }
        } label: {
            Text(playlist.name)
                .lineLimit(1)
            if !matchingTracks.isEmpty {
                let shown = matchingTracks.prefix(3).joined(separator: ", ")
                let more = matchingTracks.count > 3 ? " +\(matchingTracks.count - 3) more" : ""
                Text(shown + more)
                    .foregroundStyle(.tint)
                    .lineLimit(1)
            } else if let order = playlist.sortedBy {
                Text("Sorted by \(order.label)")
            }
        }
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

    @ViewBuilder
    private func syncBadge(_ sync: PlaylistSync) -> some View {
        if sync.needsUpdate {
            Text(sync.summary)
                .foregroundStyle(.orange)
            Button("Update") { onUpdate(sync) }
                .controlSize(.small)
                .disabled(!canEdit)
                .help("Copy what changed in Rekordbox onto the stick")
        } else {
            Text(sync.summary)
                .foregroundStyle(sync.isCurrent ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
        }
    }
}

/// Percent, MB/s and time remaining for the running transfer. Observes the
/// runner itself so only this section redraws as progress lines arrive.
private struct TransferProgressSection: View {
    @ObservedObject var runner: CommandRunner

    var body: some View {
        if let progress = runner.progress {
            Section("Copying") {
                ProgressView(value: progress.fraction) {
                    HStack {
                        Text("\(progress.done.fileSize) of \(progress.total.fileSize)")
                        Spacer()
                        Text(progress.fraction, format: .percent.precision(.fractionLength(0)))
                    }
                    .monospacedDigit()
                } currentValueLabel: {
                    HStack {
                        if progress.bytesPerSecond > 0 {
                            Text(String(format: "%.1f MB/s", progress.bytesPerSecond / 1e6))
                        }
                        Spacer()
                        Text(progress.secondsRemaining.map { "\(duration($0)) left" } ?? "Estimating…")
                    }
                    .monospacedDigit()
                }
            }
        }
    }

    private func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 60 ? "\(s / 60) min \(s % 60) s" : "\(s) s"
    }
}
