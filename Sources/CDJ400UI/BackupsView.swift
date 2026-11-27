import SwiftUI

/// One restore backup in ~/Music/DJ.CDJ400-BACKUPS, as `cdj400-backups --list` reports it.
struct Backup: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        /// Made by Make Lean: PIONEER/, unused Contents/ files and restore-map.json.
        case lean
        /// Older style: all of PIONEER/ and Contents/.
        case full
        /// Interrupted: no .complete marker.
        case partial
    }

    enum Status: String, Sendable {
        case inUse = "in-use", latest, older, notNeeded = "not-needed", incomplete
    }

    var id: String { name }
    let name: String
    let stick: String
    let made: Date?
    let bytes: Int64
    let kind: Kind
    let status: Status

    /// Parses one line: name, stick, made, bytes, kind, status, volume UUID (tab-separated).
    init?(listLine line: Substring) {
        let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard cols.count == 7, let made = Double(cols[2]), let bytes = Int64(cols[3]),
              let kind = Kind(rawValue: String(cols[4])),
              let status = Status(rawValue: String(cols[5])) else { return nil }
        name = String(cols[0])
        stick = String(cols[1])
        self.made = made > 0 ? Date(timeIntervalSince1970: made) : nil
        self.bytes = bytes
        self.kind = kind
        self.status = status
    }

    /// A plugged-in stick restores from it, so the tool refuses to delete it.
    var canDelete: Bool { status != .inUse }

    /// Nothing will ever restore from it.
    var isUnneeded: Bool { status == .older || status == .notNeeded || status == .incomplete }

    var statusText: String {
        switch status {
        case .inUse: "\(stick) is plugged in and restores from this one"
        case .latest: "The newest for a stick that isn’t plugged in"
        case .older: "Replaced by a newer backup"
        case .notNeeded: "\(stick) is back in Rekordbox mode"
        case .incomplete: "Interrupted, so it can’t be restored from"
        }
    }

    var symbol: String {
        switch status {
        case .inUse: "lock.fill"
        case .latest: "clock"
        case .older, .notNeeded: "checkmark.circle"
        case .incomplete: "exclamationmark.triangle"
        }
    }

    var tint: Color {
        switch status {
        case .inUse: .green
        case .latest: .primary
        case .older, .notNeeded: .secondary
        case .incomplete: .orange
        }
    }

    var kindText: String {
        switch kind {
        case .lean: "Make Lean"
        case .full: "Full export"
        case .partial: "Partial"
        }
    }
}

/// Every restore backup on the Mac, grouped by whether anything will restore
/// from it, with how much space each takes.
struct BackupsView: View {
    @EnvironmentObject private var model: AppModel

    @State private var backups: [Backup] = []
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var pendingDelete: [Backup] = []
    @State private var isDeleting = false
    @State private var resultText: String?

    private enum Bucket: CaseIterable {
        case needed, keep, unneeded

        var title: String {
            switch self {
            case .needed: "Needed"
            case .keep: "Worth keeping"
            case .unneeded: "Safe to delete"
            }
        }

        var color: Color {
            switch self {
            case .needed: .green
            case .keep: .gray
            case .unneeded: .primary.opacity(0.22)
            }
        }

        func contains(_ backup: Backup) -> Bool {
            switch self {
            case .needed: backup.status == .inUse
            case .keep: backup.status == .latest
            case .unneeded: backup.isUnneeded
            }
        }
    }

    var body: some View {
        content
            .navigationTitle("Restore Backups")
            .toolbar {
                ToolbarItem {
                    Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.open(StickCommands.backupsFolder) }
                        .help("Open the backups folder in Finder")
                }
                ToolbarItem {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }
                        .disabled(isLoading)
                }
            }
            .task { await load() }
            .onChange(of: model.sticks) { Task { await load() } }
            .confirmationDialog(deleteTitle,
                                isPresented: Binding(get: { !pendingDelete.isEmpty },
                                                     set: { if !$0 { pendingDelete = [] } }),
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    let names = pendingDelete.map(\.name)
                    pendingDelete = []
                    Task { await delete(names) }
                }
                Button("Cancel", role: .cancel) { pendingDelete = [] }
            } message: {
                Text(deleteMessage)
            }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && backups.isEmpty {
            ProgressView("Measuring backups…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorText {
            ContentUnavailableView("Couldn’t Read the Backups", systemImage: "exclamationmark.triangle",
                                   description: Text(errorText))
        } else if backups.isEmpty {
            ContentUnavailableView("No Backups", systemImage: "archivebox",
                                   description: Text("Make Lean saves one here before it changes a stick."))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    summary
                    ForEach(Bucket.allCases, id: \.self) { group in
                        let rows = backups.filter(group.contains)
                        if !rows.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                SectionHeader(group.title)
                                Card {
                                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, backup in
                                        if index > 0 { CardDivider() }
                                        BackupRow(backup: backup, disabled: isDeleting,
                                                  onDelete: { pendingDelete = [backup] })
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
            }
        }
    }

    private var unneeded: [Backup] { backups.filter(\.isUnneeded) }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(total(backups).fileSize) of backups on your Mac")
                        .font(.system(size: 22, weight: .bold))
                    Text(resultText ?? (unneeded.isEmpty
                         ? "Restore to Rekordbox uses these."
                         : "Restore to Rekordbox uses these. \(total(unneeded).fileSize) of them nothing will ever restore from."))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if !unneeded.isEmpty {
                    Button("Delete Unneeded (\(total(unneeded).fileSize))…") { pendingDelete = unneeded }
                        .buttonStyle(.borderedProminent)
                        .disabled(isDeleting)
                }
            }
            StorageBar(segments: Bucket.allCases.map { group in
                StorageBar.Segment(id: group.title, label: group.title,
                                   bytes: total(backups.filter(group.contains)), color: group.color)
            }.filter { $0.bytes > 0 }, totalBytes: total(backups), height: 12)
            HStack(spacing: 18) {
                ForEach(Bucket.allCases, id: \.self) { group in
                    let bytes = total(backups.filter(group.contains))
                    if bytes > 0 {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 3).fill(group.color).frame(width: 9, height: 9)
                            Text("\(group.title) \(bytes.fileSize)")
                        }
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }

    // MARK: - Actions

    private var deleteTitle: String {
        "Delete \(pendingDelete.count) backup\(pendingDelete.count == 1 ? "" : "s") (\(total(pendingDelete).fileSize))?"
    }

    private var deleteMessage: String {
        let latest = pendingDelete.filter { $0.status == .latest }.map(\.stick)
        var text = "They’re deleted from your Mac straight away, not moved to the Bin."
        if !latest.isEmpty {
            let sticks = Array(Set(latest)).sorted().joined(separator: ", ")
            text += " \(sticks) will no longer be able to Restore to Rekordbox; you’d re-sync instead."
        }
        return text
    }

    private func total(_ list: [Backup]) -> Int64 { list.reduce(0) { $0 + $1.bytes } }

    private func load() async {
        isLoading = true
        let result = await Shell.output(StickCommands.listBackups())
        isLoading = false
        guard result.status == 0 else {
            errorText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }
        errorText = nil
        backups = result.text.split(separator: "\n").compactMap(Backup.init(listLine:))
    }

    private func delete(_ names: [String]) async {
        isDeleting = true
        let result = await Shell.output(StickCommands.deleteBackups(names))
        isDeleting = false
        resultText = result.text.split(separator: "\n").last.map(String.init)
        await load()
        model.refreshBackups()
    }
}

private struct BackupRow: View {
    let backup: Backup
    let disabled: Bool
    let onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: backup.symbol)
                .foregroundStyle(backup.status == .incomplete ? AnyShapeStyle(.orange)
                                 : backup.status == .inUse ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(backup.stick)
                .fontWeight(.medium)
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)
            Text(backup.statusText)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 12)
            if backup.canDelete {
                Button("Delete backup", systemImage: "trash", action: onDelete)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .opacity(hovering ? 1 : 0)
                    .disabled(disabled)
                    .help("Delete this backup")
            }
            Text(backup.made?.shortStamp ?? "")
                .foregroundStyle(.secondary)
            Text(backup.bytes.fileSize)
                .frame(width: 64, alignment: .trailing)
        }
        .monospacedDigit()
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(backup.name)
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [StickCommands.backupsFolder.appendingPathComponent(backup.name)])
            }
            if backup.canDelete {
                Divider()
                Button("Delete…", role: .destructive, action: onDelete)
            }
        }
    }
}
