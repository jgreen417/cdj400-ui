import AppKit
import Combine

/// State shared by the main window and the menu bar: the plugged-in sticks and
/// the one job runner.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var sticks: [Stick] = []
    @Published private(set) var isScanning = false
    @Published var selection: String?
    @Published private(set) var syncState: [String: SyncState] = [:]
    /// Mirrors `runner.isRunning`. Views that only need to know whether a job
    /// is running read this, so they don't redraw on every line of output;
    /// views that show the output observe `runner` themselves.
    @Published private(set) var isJobRunning = false
    let runner = CommandRunner()

    private var subscriptions: Set<AnyCancellable> = []
    /// Sticks the running job writes to, and when each stick last finished an app job.
    private var writing: Set<String> = []
    private var lastAppWrite: [String: Date] = [:]
    /// A refresh or sync check asked for while one was already in flight.
    private var rescanQueued = false
    private var recheckQueued: Set<String> = []

    init() {
        runner.$isRunning
            .sink { [weak self] in self?.isJobRunning = $0 }
            .store(in: &subscriptions)
        runner.$lastExit
            .compactMap { $0 }
            .sink { [weak self] _ in self?.jobFinished() }
            .store(in: &subscriptions)

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            workspace.publisher(for: name)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.refresh() }
                .store(in: &subscriptions)
        }

        Notifier.requestPermission()
        refresh()
    }

    var selectedStick: Stick? { sticks.first { $0.path == selection } }

    func refresh() {
        guard !isScanning else {
            rescanQueued = true
            return
        }
        isScanning = true
        Task {
            let found = await Task.detached { StickScanner.scan() }.value
            sticks = found
            if selection == nil || !found.contains(where: { $0.path == selection }) {
                selection = found.first?.path
            }
            isScanning = false
            if rescanQueued {
                rescanQueued = false
                refresh()
            }
        }
    }

    private func jobFinished() {
        for path in writing { lastAppWrite[path] = Date() }
        writing = []
        refresh()
        for (path, state) in syncState {
            switch state {
            case .checked: checkSync(path: path)
            case .checking: recheckQueued.insert(path)
            case .failed: break
            }
        }
    }

    /// Compares every playlist folder on a lean stick with the live Rekordbox library.
    func checkSync(_ stick: Stick) { checkSync(path: stick.path) }

    private func checkSync(path: String) {
        if case .checking = syncState[path] { return }
        syncState[path] = .checking
        Task {
            let result = await Shell.output(StickCommands.syncStatus(path: path))
            if result.status == 0 {
                let rows = result.text.split(separator: "\n").compactMap(PlaylistSync.init(statusLine:))
                syncState[path] = .checked(Dictionary(rows.map { ($0.folder, $0) },
                                                      uniquingKeysWith: { first, _ in first }))
            } else {
                syncState[path] = .failed(result.text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            // A job finished while this check ran, so its answer may be stale.
            if recheckQueued.remove(path) != nil { checkSync(path: path) }
        }
    }

    func run(_ job: Job, on stick: Stick) {
        guard !runner.isRunning else { return }
        writing = [stick.path]
        if case .copy(let target) = job { writing.insert(target.path) }
        runner.run(title: job.title(on: stick), command: job.command(on: stick))
    }

    /// True when something other than this app wrote to the stick in the last
    /// 90 seconds, which usually means Rekordbox is syncing it. The app's own
    /// jobs don't count; macOS keeps touching the stick's housekeeping files
    /// for a little while after a write, hence the grace period.
    func changedOutsideApp(_ stick: Stick) -> Bool {
        guard stick.isRecentlyChanged, let changed = stick.lastChange else { return false }
        if writing.contains(stick.path) { return false }
        if let ours = lastAppWrite[stick.path], changed <= ours.addingTimeInterval(30) { return false }
        return true
    }

    /// Sticks a lean stick's playlists can be copied onto.
    func copyTargets(for stick: Stick) -> [Stick] {
        guard stick.mode == .lean, !stick.playlists.isEmpty else { return [] }
        return sticks.filter { $0.path != stick.path && $0.mode == .lean }
    }
}
