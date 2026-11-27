import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var pending: PendingJob?
    @AppStorage("outputHeight") private var outputHeight = 250.0
    /// The output pane is open; otherwise it's a one-line status bar.
    @AppStorage("outputOpen") private var outputOpen = false
    @State private var dragStartHeight: Double?

    private var runner: CommandRunner { model.runner }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            GeometryReader { geo in
                let maxOutput = max(120, geo.size.height - 220)
                let height = min(max(outputHeight, 120), maxOutput)
                VStack(spacing: 0) {
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if outputOpen {
                        outputDivider(currentHeight: height, maxHeight: maxOutput)
                        LogView(runner: runner, onHide: { setOutput(open: false) })
                            .frame(height: height)
                            .transition(.move(edge: .bottom))
                    } else {
                        Divider()
                        StatusBar(runner: runner, onShow: { setOutput(open: true) })
                    }
                }
            }
            .frame(minWidth: 600)
        }
        // A job opens the output so its progress and Stop button are in view.
        .onChange(of: model.isJobRunning) { _, running in
            if running { setOutput(open: true) }
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

    private func setOutput(open: Bool) {
        withAnimation(.easeOut(duration: 0.2)) { outputOpen = open }
    }

    @ViewBuilder
    private var detail: some View {
        if let stick = model.selectedStick {
            StickDetailView(stick: stick, runner: runner, isRunning: model.isJobRunning,
                            isWorkingOnThisStick: model.jobStick == stick.path,
                            changedOutsideApp: model.changedOutsideApp(stick),
                            copyTargets: model.copyTargets(for: stick),
                            sync: model.syncState[stick.path],
                            onCheckSync: { model.checkSync(stick) },
                            onJob: { request($0, on: stick) })
        } else {
            ContentUnavailableView("No Stick Selected", systemImage: "externaldrive",
                                   description: Text("Plug in a Rekordbox stick. It shows up here on its own."))
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
                        outputHeight = min(max(start - drag.translation.height, 120), maxHeight)
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
                    ProgressView("Looking for sticks…")
                } else {
                    ContentUnavailableView("No Sticks", systemImage: "externaldrive.badge.questionmark",
                                           description: Text("Plug in a Rekordbox stick."))
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button { openWindow(id: "backups") } label: {
                HStack(spacing: 9) {
                    Image(systemName: "archivebox")
                    Text("Restore Backups")
                    Spacer()
                    if let bytes = model.backupBytes, bytes > 0 {
                        Text(bytes.fileSize)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .help("See and clean up the restore backups on your Mac")
        }
        .toolbar {
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isScanning)
                    .help("Look for sticks again (⌘R)")
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

    @State private var hovering = false

    var body: some View {
        let issues = stick.issues.count + (changedOutsideApp ? 1 : 0)
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.fill")
                .font(.title3)
                .foregroundStyle(stick.mode.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(stick.name)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if hovering {
                        Button("Eject \(stick.name)", systemImage: "eject.fill", action: onEject)
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .disabled(ejectDisabled)
                            .help("Eject \(stick.name)")
                    } else if issues > 0 {
                        Text("\(issues)")
                            .font(.caption2.bold())
                            .foregroundStyle(.black)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.orange, in: Capsule())
                            .help(stick.issues.map(\.title).joined(separator: "\n"))
                            .accessibilityLabel("\(issues) need\(issues == 1 ? "s" : "") attention")
                    }
                }
                HStack(spacing: 8) {
                    MiniCapacityBar(fraction: stick.usedFraction,
                                    tint: stick.isNearlyFull ? .orange : .primary.opacity(0.75))
                    Text(stick.mode == .lean && stick.tracks == 0 ? "Empty" : "\(stick.freeDescription) free")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(stick.name), \(stick.mode.label), \(stick.freeDescription) free")
        .contextMenu {
            Button("Eject", systemImage: "eject", action: onEject)
                .disabled(ejectDisabled)
        }
    }
}

/// The output pane closed: the last job's result on one line.
private struct StatusBar: View {
    @ObservedObject var runner: CommandRunner
    let onShow: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let last = runner.history.first {
                Image(systemName: last.succeeded ? "checkmark" : "xmark")
                    .fontWeight(.bold)
                    .foregroundStyle(last.succeeded ? .green : .red)
                    .accessibilityHidden(true)
                Text("\(last.title), \(last.date.formatted(.relative(presentation: .named)))")
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Jobs you run show their output here.")
            }
            Spacer()
            Button(action: onShow) {
                HStack(spacing: 4) {
                    Text("Show Output")
                    Image(systemName: "chevron.up").font(.caption2.bold())
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: 32)
        .background(.bar)
    }
}
