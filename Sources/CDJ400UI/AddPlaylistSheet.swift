import SwiftUI

/// A Rekordbox playlist that isn't on the stick yet.
struct AddablePlaylist: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let tracks: Int
    let bytes: Int64?

    /// Parses one `cdj400-addplaylist --list` line: name, tracks, bytes (optional).
    init?(listLine line: Substring) {
        let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard cols.count >= 2, let tracks = Int(cols[1]) else { return nil }
        name = String(cols[0])
        self.tracks = tracks
        bytes = cols.count >= 3 ? Int64(cols[2]) : nil
    }

    /// The headroom cdj400-addplaylist insists on before copying: 5% plus 50 MB.
    static func fits(_ bytes: Int64, in freeBytes: Int64) -> Bool {
        Double(bytes) * 1.05 + Double(50 << 20) <= Double(freeBytes)
    }

    func fits(freeBytes: Int64) -> Bool {
        bytes.map { Self.fits($0, in: freeBytes) } ?? true
    }
}

/// Lists Rekordbox playlists that are not on the lean stick yet and lets you
/// preview or copy one of them into Playlists/.
struct AddPlaylistSheet: View {
    let stick: Stick
    let onRun: (_ names: [String], _ execute: Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var playlists: [AddablePlaylist] = []
    @State private var selection: Set<String> = []
    @State private var isLoading = true
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add Playlists to \(stick.name)")
                    .font(.title3.bold())
                Text("Choose one or more Rekordbox playlists. Their MP3s are copied into Playlists/, no sync needed.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Group {
                if isLoading {
                    ProgressView("Reading your Rekordbox library…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorText {
                    ContentUnavailableView("Couldn’t Read the Library", systemImage: "exclamationmark.triangle",
                                           description: Text(errorText))
                } else if playlists.isEmpty {
                    ContentUnavailableView("Nothing to Add", systemImage: "checkmark.circle",
                                           description: Text("Every Rekordbox playlist is already on this stick."))
                } else {
                    List(playlists) { pl in
                        playlistRow(pl)
                    }
                    .listStyle(.bordered)
                    .alternatingRowBackgrounds()
                }
            }
            .frame(minHeight: 240)

            if !selection.isEmpty { forecast }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Preview") { run(execute: false) }
                    .disabled(selection.isEmpty)
                Button(selection.count > 1 ? "Add \(selection.count) to Stick" : "Add to Stick") { run(execute: true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(selection.isEmpty || !chosenFit)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(20)
        .frame(width: 520, height: 560)
        .task { await load() }
    }

    private var chosen: [AddablePlaylist] {
        playlists.filter { selection.contains($0.name) }
    }

    private var chosenBytes: Int64 { chosen.reduce(0) { $0 + ($1.bytes ?? 0) } }

    private var chosenFit: Bool { AddablePlaylist.fits(chosenBytes, in: stick.freeBytes) }

    private var forecast: some View {
        let total = Double(max(stick.totalBytes, 1))
        let usedAfter = Double(stick.usedBytes + chosenBytes)
        let freeAfter = stick.freeBytes - chosenBytes
        let tint: Color = chosenFit ? .capacity(usedAfter / total) : .red
        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(chosen.count) playlist\(chosen.count == 1 ? "" : "s") · \(chosenBytes.fileSize)")
                        .fontWeight(.semibold)
                    Spacer()
                    Text(chosenFit
                         ? "\(freeAfter.fileSize) free after"
                         : "Won’t fit: \(stick.freeDescription) free")
                        .fontWeight(chosenFit ? .regular : .semibold)
                        .foregroundStyle(chosenFit ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                }
                .monospacedDigit()
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(tint.opacity(0.45))
                            .frame(width: geo.size.width * min(usedAfter / total, 1))
                        Capsule().fill(.secondary)
                            .frame(width: geo.size.width * min(Double(stick.usedBytes) / total, 1))
                    }
                }
                .frame(height: 6)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(Int(min(usedAfter / total, 1) * 100)) percent used after adding")
                HStack(spacing: 14) {
                    legend(AnyShapeStyle(.secondary), "On the stick now")
                    legend(AnyShapeStyle(tint.opacity(0.45)), "These playlists")
                }
            }
            .padding(4)
        }
    }

    private func legend(_ style: AnyShapeStyle, _ label: String) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(style).frame(width: 12, height: 6)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func playlistRow(_ pl: AddablePlaylist) -> some View {
        let fits = pl.fits(freeBytes: stick.freeBytes)
        let isOn = Binding(
            get: { selection.contains(pl.name) },
            set: { if $0 { selection.insert(pl.name) } else { selection.remove(pl.name) } }
        )
        return HStack(spacing: 10) {
            Toggle(pl.name, isOn: isOn)
                .toggleStyle(.checkbox)
                .lineLimit(1)
            Spacer()
            if !fits {
                Text("Won’t fit")
                    .foregroundStyle(.red)
            }
            Text("\(pl.tracks) tracks")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if let bytes = pl.bytes {
                Text(bytes.fileSize)
                    .foregroundStyle(fits ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    .monospacedDigit()
                    .frame(width: 64, alignment: .trailing)
            }
        }
        .padding(.vertical, 2)
    }

    private func run(execute: Bool) {
        let names = playlists.map(\.name).filter(selection.contains)
        guard !names.isEmpty else { return }
        onRun(names, execute)
        dismiss()
    }

    private func load() async {
        let result = await Shell.output(StickCommands.listAddablePlaylists(stick: stick))
        isLoading = false
        guard result.status == 0 else {
            errorText = "Could not read the library:\n" + result.text
            return
        }
        playlists = result.text.split(separator: "\n").compactMap(AddablePlaylist.init(listLine:))
    }
}
