import SwiftUI

@main
struct CDJ400UIApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("CDJ-400 Sticks", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 880, minHeight: 620)
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra("CDJ-400 Sticks", systemImage: "externaldrive") {
            MenuBarContent()
                .environmentObject(model)
        }
    }
}

/// The menu bar icon's menu: each plugged-in stick with quick actions.
struct MenuBarContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.sticks.isEmpty {
            Text(model.isScanning ? "Scanning…" : "No sticks plugged in")
        }
        ForEach(model.sticks) { stick in
            Menu("\(stick.name) · \(stick.mode.label) · \(stick.freeDescription) free") {
                Button("Dry Run", systemImage: "doc.text.magnifyingglass") { model.run(.action(.dryRun), on: stick) }
                    .disabled(model.isJobRunning)
                Button("Eject", systemImage: "eject") { model.run(.eject, on: stick) }
                    .disabled(model.isJobRunning)
                Divider()
                Button("Show in Window", systemImage: "macwindow") { show(stick) }
            }
        }
        if model.isJobRunning {
            Divider()
            JobStatusText(runner: model.runner)
            Button("Stop", systemImage: "stop.fill") { model.runner.stop() }
        }
        Divider()
        Button("Open CDJ-400 Sticks") { show(nil) }
        Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func show(_ stick: Stick?) {
        if let stick { model.selection = stick.path }
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

/// The running job's progress, observed on its own so the rest of the menu
/// doesn't redraw with every line of output.
private struct JobStatusText: View {
    @ObservedObject var runner: CommandRunner

    var body: some View {
        if let progress = runner.progress {
            Text("Copying · \(Int(progress.fraction * 100))%")
        } else {
            Text("A job is running…")
        }
    }
}
