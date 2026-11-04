import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var pending: PendingJob?
    @AppStorage("outputHeight") private var outputHeight = 140.0
    @State private var dragStartHeight: Double?

    private var runner: CommandRunner { model.runner }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            GeometryReader { geo in
                let maxOutput = max(70, geo.size.height - 260)
                let height = min(max(outputHeight, 70), maxOutput)
                VStack(spacing: 0) {
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    outputDivider(currentHeight: height, maxHeight: maxOutput)
                    LogView(runner: runner)
                        .frame(height: height)
                }
            }
            .frame(minWidth: 600)
        }
        .confirmationDialog(
            pending.map { $0.job.title(on: $0.stick) } ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible
        ) {
            if let pending {
                Button(pending.job.title, role: pending.job.isDestructive ? .destructive : nil) {
                    model.run(pending.job, on: pending.stick)
                    self.pending = nil
                }
                Button("Cancel", role: .cancel) { self.pending = nil }
            }
        } message: {
            if let pending, let text = pending.job.confirmation(on: pending.stick) {
                Text(text)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let stick = model.selectedStick {
            StickDetailView(stick: stick, runner: runner, isRunning: model.isJobRunning,
                            changedOutsideApp: model.changedOutsideApp(stick),
                            copyTargets: model.copyTargets(for: stick),
                            sync: model.syncState[stick.path],
                            onCheckSync: { model.checkSync(stick) },
                            onJob: { request($0, on: stick) })
        } else {
            ContentUnavailableView("No Stick Selected", systemImage: "externaldrive",
                                   description: Text("Plug in a Rekordbox stick and press Refresh."))
                .navigationTitle("CDJ-400 Sticks")
        }
    }

    /// Hairline with a taller invisible grab area; dragging it resizes the output.
    private func outputDivider(currentHeight: Double, maxHeight: Double) -> some View {
        Divider()
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .padding(.vertical, -4)
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = dragStartHeight ?? currentHeight
                        dragStartHeight = start
                        outputHeight = min(max(start - drag.translation.height, 70), maxHeight)
                    }
                    .onEnded { _ in dragStartHeight = nil }
            )
            .zIndex(1)
            .accessibilityLabel("Resize output")
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $model.selection) {
            Section("Sticks") {
                ForEach(model.sticks) { stick in
                    StickRow(stick: stick,
                             changedOutsideApp: model.changedOutsideApp(stick),
                             ejectDisabled: model.isJobRunning,
                             onEject: { model.run(.eject, on: stick) })
                        .tag(stick.path as String?)
                }
            }
        }
        .overlay {
            if model.sticks.isEmpty {
                if model.isScanning {
                    ProgressView("Scanning…")
                } else {
                    ContentUnavailableView("No Sticks", systemImage: "externaldrive.badge.questionmark",
                                           description: Text("Plug in a Rekordbox stick."))
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isScanning)
                    .help("Rescan for sticks (⌘R)")
            }
        }
    }

    // MARK: - Jobs

    private func request(_ job: Job, on stick: Stick) {
        if job.confirmation(on: stick) == nil {
            model.run(job, on: stick)
        } else {
            pending = PendingJob(job: job, stick: stick)
        }
    }
}

struct PendingJob {
    let job: Job
    let stick: Stick
}

private struct StickRow: View {
    let stick: Stick
    let changedOutsideApp: Bool
    let ejectDisabled: Bool
    let onEject: () -> Void

    var body: some View {
        let issues = stick.issues
        HStack(spacing: 6) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(stick.name)
                        .lineLimit(1)
                    Text("\(stick.mode.label) · \(stick.freeDescription) free")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .padding(.vertical, 2)
            } icon: {
                Image(systemName: "externaldrive.fill")
                    .foregroundStyle(stick.mode.tint)
            }
            Spacer(minLength: 0)
            if changedOutsideApp {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
                    .help("Changed in the last 90 seconds")
            }
            if !issues.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .help(issues.map(\.title).joined(separator: "\n"))
                    .accessibilityLabel("\(issues.count) problems")
            }
            Button("Eject \(stick.name)", systemImage: "eject.fill", action: onEject)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(ejectDisabled)
                .help("Eject \(stick.name)")
        }
        .contextMenu {
            Button("Eject", systemImage: "eject", action: onEject)
                .disabled(ejectDisabled)
        }
    }
}
